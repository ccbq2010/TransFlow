// Standalone Apple SpeechAnalyzer test harness.
// Mode "direct":    canonical usage — feed file buffers directly in analyzer format.
// Mode "transflow": replicates TransFlow SpeechEngine exactly —
//                   16kHz Float32 chunks (100ms) -> 200ms accumulator -> AVAudioConverter
//                   -> AnalyzerInput(bufferStartTime:) with cumulative frame clock.
import Foundation
import Speech
import CoreMedia
@preconcurrency import AVFoundation

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

guard CommandLine.arguments.count >= 3 else {
    log("usage: speechtest <wav path|mic seconds> <direct|transflow|mic> [localeId]")
    exit(2)
}
let wavPath = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
let localeId = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "en_US"

let locale = Locale(identifier: localeId)

// ── Locale / asset checks ────────────────────────────────────────────────
let supported = await SpeechTranscriber.supportedLocales
log("supportedLocales: \(supported.map(\.identifier).sorted().joined(separator: ","))")
let installed = await Set(SpeechTranscriber.installedLocales)
log("installedLocales: \(installed.map(\.identifier).sorted().joined(separator: ","))")

guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
    log("FATAL: locale \(localeId) not supported")
    exit(1)
}
log("using locale: \(supportedLocale.identifier)")

let transcriber = SpeechTranscriber(
    locale: supportedLocale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: []
)

// Ensure model asset present (same responsibility the app's SpeechModelManager has)
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    log("asset not installed — downloading...")
    try await req.downloadAndInstall()
    log("asset installed")
} else {
    log("asset already installed")
}

let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
log("bestAvailableAudioFormat: \(analyzerFormat?.description ?? "nil")")
let effectiveFormat = analyzerFormat ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.prepareToAnalyze(in: effectiveFormat)
log("analyzer prepared")

// ── Result consumption ───────────────────────────────────────────────────
struct Collected: Sendable { var finals: [String] = []; var volatileCount = 0; var lastVolatile = "" }
actor Collector {
    var c = Collected()
    func addFinal(_ t: String) { c.finals.append(t) }
    func addVolatile(_ t: String) { c.volatileCount += 1; c.lastVolatile = t }
    func snapshot() -> Collected { c }
}
let collector = Collector()

let resultTask = Task(priority: .userInitiated) {
    do {
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
                await collector.addFinal(text)
                log("[FINAL] \(text)")
            } else {
                await collector.addVolatile(text)
            }
        }
    } catch {
        log("[RESULT ERROR] \(error)")
    }
}

// ── Input feeding ────────────────────────────────────────────────────────
let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
try await analyzer.start(inputSequence: inputSequence)

if mode == "mic" {
    // Replicate AudioCaptureService EXACTLY: AVAudioEngine tap -> AVAudioConverter to 16k Float32
    // -> 100ms-ish chunks -> SpeechEngine accumulator path. Also dump captured audio to WAV.
    let seconds = Double(wavPath) ?? 8
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    log("mic input format: \(inputFormat.description)")
    let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    guard let capConverter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        log("FATAL: cannot create capture converter"); exit(1)
    }
    let outputFrameCapacity: AVAudioFrameCount = 1600  // same as AudioCaptureService

    let (chunkStream, chunkCont) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(256))
    nonisolated(unsafe) var allCaptured: [Float] = []
    let capLock = NSLock()

    let fixedCapacity = ProcessInfo.processInfo.environment["FIXED_CAP"] != nil
    nonisolated(unsafe) let capConv = capConverter
    nonisolated(unsafe) var cbCount = 0
    nonisolated(unsafe) var inFrames = 0
    nonisolated(unsafe) var outFrames = 0
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
        let capConverter = capConv
        // BUGGY (TransFlow current): fixed 1600-frame capacity.
        // FIXED: capacity derived from this buffer's actual frame count.
        let capacity: AVAudioFrameCount = fixedCapacity
            ? outputFrameCapacity
            : AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        capConverter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true; outStatus.pointee = .haveData; return buffer
        }
        guard error == nil, outputBuffer.frameLength > 0, let ch = outputBuffer.floatChannelData else { return }
        let n = Int(outputBuffer.frameLength)
        capLock.lock()
        cbCount += 1; inFrames += Int(buffer.frameLength); outFrames += n
        capLock.unlock()
        let samples = Array(UnsafeBufferPointer(start: ch[0], count: n))
        capLock.lock(); allCaptured.append(contentsOf: samples); capLock.unlock()
        chunkCont.yield(samples)
    }
    try engine.start()
    log("mic capturing for \(seconds)s ... SPEAK/PLAY ENGLISH NOW")

    // SpeechEngine's exact accumulator loop, consuming live chunks
    let sourceFormat = targetFormat
    let converter: AVAudioConverter? = analyzerFormat.flatMap { AVAudioConverter(from: sourceFormat, to: $0) }
    let outputSampleRate: Double = analyzerFormat?.sampleRate ?? 16_000
    let reusableBuffer: AVAudioPCMBuffer? = analyzerFormat.map {
        AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: AVAudioFrameCount(16_000 * 0.25 * ($0.sampleRate / 16_000)) + 64)!
    }
    let feedTask = Task {
        var accumulator: [Float] = []
        let batchThreshold = Int(16_000 * 0.2)
        var cumulativeOutputFrames: Int64 = 0
        var yielded = 0
        for await chunk in chunkStream {
            accumulator.append(contentsOf: chunk)
            guard accumulator.count >= batchThreshold else { continue }
            let st = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(accumulator.count))!
            pcm.frameLength = AVAudioFrameCount(accumulator.count)
            accumulator.withUnsafeBufferPointer { p in pcm.floatChannelData![0].update(from: p.baseAddress!, count: accumulator.count) }
            if let converter, let reusableBuffer {
                let out = AVAudioPCMBuffer(pcmFormat: reusableBuffer.format, frameCapacity: reusableBuffer.frameCapacity)!
                out.frameLength = 0
                var e: NSError?
                nonisolated(unsafe) var consumed = false
                nonisolated(unsafe) let captured = pcm
                converter.convert(to: out, error: &e) { _, st2 in
                    if consumed { st2.pointee = .noDataNow; return nil }
                    consumed = true; st2.pointee = .haveData; return captured
                }
                if e == nil, out.frameLength > 0 {
                    inputBuilder.yield(AnalyzerInput(buffer: out, bufferStartTime: st))
                    cumulativeOutputFrames += Int64(out.frameLength)
                    yielded += 1
                }
            } else {
                inputBuilder.yield(AnalyzerInput(buffer: pcm, bufferStartTime: st))
                cumulativeOutputFrames += Int64(pcm.frameLength)
                yielded += 1
            }
            accumulator.removeAll(keepingCapacity: true)
        }
        log("mic feed done: yielded=\(yielded) frames=\(cumulativeOutputFrames)")
    }

    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    inputNode.removeTap(onBus: 0)
    engine.stop()
    chunkCont.finish()
    _ = await feedTask.value

    // Dump captured audio for human verification
    let dump = capLock.withLock { allCaptured }
    let dumpFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let dumpBuf = AVAudioPCMBuffer(pcmFormat: dumpFmt, frameCapacity: AVAudioFrameCount(dump.count))!
    dumpBuf.frameLength = AVAudioFrameCount(dump.count)
    dump.withUnsafeBufferPointer { p in dumpBuf.floatChannelData![0].update(from: p.baseAddress!, count: dump.count) }
    let dumpURL = URL(fileURLWithPath: "/tmp/mic_captured.wav")
    try? FileManager.default.removeItem(at: dumpURL)
    let outFile = try AVAudioFile(forWriting: dumpURL, settings: dumpFmt.settings)
    try outFile.write(from: dumpBuf)
    let rms = sqrt(dump.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(dump.count, 1)))
    let peak = dump.map(abs).max() ?? 0
    let stats = capLock.withLock { (cbCount, inFrames, outFrames) }
    let expectedOut = Double(stats.1) * 16_000 / inputFormat.sampleRate
    log("mic tap stats: callbacks=\(stats.0) inFrames=\(stats.1) outFrames=\(stats.2) expectedOut=\(Int(expectedOut)) lossRatio=\(String(format: "%.1f%%", (1 - Double(stats.2)/max(expectedOut,1)) * 100))")
    log("mic captured \(dump.count) samples (\(Double(dump.count)/16000)s), RMS=\(rms), peak=\(peak), saved /tmp/mic_captured.wav")
} else if mode == "direct" {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
    log("file: \(file.processingFormat.description), frames=\(file.length)")
    // Canonical path: convert whole file to analyzer format, feed as one buffer, no explicit start time.
    let conv = AVAudioConverter(from: file.processingFormat, to: effectiveFormat)!
    let srcCap = AVAudioFrameCount(file.length)
    let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcCap)!
    try file.read(into: srcBuf)
    let ratio = effectiveFormat.sampleRate / file.processingFormat.sampleRate
    let outBuf = AVAudioPCMBuffer(pcmFormat: effectiveFormat,
                                  frameCapacity: AVAudioFrameCount(Double(srcCap) * ratio) + 1024)!
    var err: NSError?
    nonisolated(unsafe) var fed = false
    conv.convert(to: outBuf, error: &err) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return srcBuf
    }
    if let err { log("convert error: \(err)"); exit(1) }
    log("direct: feeding \(outBuf.frameLength) frames")
    inputBuilder.yield(AnalyzerInput(buffer: outBuf))
} else {
    // TransFlow-identical path.
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: wavPath))
    log("file: \(file.processingFormat.description), frames=\(file.length)")
    // Step 1: file -> 16kHz mono Float32 samples (what AudioCaptureService produces)
    let captureFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let conv1 = AVAudioConverter(from: file.processingFormat, to: captureFormat)!
    let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: srcBuf)
    let outCap = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
    let capBuf = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: outCap)!
    var err: NSError?
    nonisolated(unsafe) var fed = false
    conv1.convert(to: capBuf, error: &err) { _, st in
        if fed { st.pointee = .endOfStream; return nil }
        fed = true; st.pointee = .haveData; return srcBuf
    }
    if let err { log("capture convert error: \(err)"); exit(1) }
    let total = Int(capBuf.frameLength)
    var samples = [Float](repeating: 0, count: total)
    samples.withUnsafeMutableBufferPointer { dst in
        dst.baseAddress!.update(from: capBuf.floatChannelData![0], count: total)
    }
    log("transflow: \(total) Float32 samples @16k (\(Double(total)/16000)s)")

    // Step 2: 100ms chunks (AudioCaptureService: 1600 samples per chunk)
    var chunks: [[Float]] = []
    var i = 0
    while i < total {
        let end = min(i + 1600, total)
        chunks.append(Array(samples[i..<end]))
        i = end
    }

    // Step 3: SpeechEngine's exact accumulator + converter loop
    let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let converter: AVAudioConverter?
    let outputSampleRate: Double
    if let analyzerFormat {
        converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        outputSampleRate = analyzerFormat.sampleRate
    } else {
        converter = nil
        outputSampleRate = 16_000
    }
    let reusableBuffer: AVAudioPCMBuffer?
    if converter != nil, let analyzerFormat {
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(16_000 * 0.25 * ratio) + 64
        reusableBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
    } else { reusableBuffer = nil }

    func convertToAnalyzerInput(_ acc: [Float], startTime: CMTime) -> (AnalyzerInput, AVAudioFrameCount)? {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        guard let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(acc.count)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(acc.count)
        acc.withUnsafeBufferPointer { p in pcm.floatChannelData![0].update(from: p.baseAddress!, count: acc.count) }
        if let converter, let reusableBuffer {
            let out = AVAudioPCMBuffer(pcmFormat: reusableBuffer.format, frameCapacity: reusableBuffer.frameCapacity)!
            out.frameLength = 0
            var e: NSError?
            nonisolated(unsafe) var consumed = false
            nonisolated(unsafe) let captured = pcm
            converter.convert(to: out, error: &e) { _, st in
                if consumed { st.pointee = .noDataNow; return nil }
                consumed = true; st.pointee = .haveData; return captured
            }
            guard e == nil, out.frameLength > 0 else {
                log("chunk convert failed: \(e?.localizedDescription ?? "0 frames")")
                return nil
            }
            return (AnalyzerInput(buffer: out, bufferStartTime: startTime), out.frameLength)
        } else {
            return (AnalyzerInput(buffer: pcm, bufferStartTime: startTime), pcm.frameLength)
        }
    }

    var accumulator: [Float] = []
    let batchThreshold = Int(16_000 * 0.2)
    var cumulativeOutputFrames: Int64 = 0
    var yielded = 0, dropped = 0
    for chunk in chunks {
        accumulator.append(contentsOf: chunk)
        guard accumulator.count >= batchThreshold else { continue }
        let st = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
        if let (input, n) = convertToAnalyzerInput(accumulator, startTime: st) {
            inputBuilder.yield(input)
            cumulativeOutputFrames += Int64(n)
            yielded += 1
        } else { dropped += 1 }
        accumulator.removeAll(keepingCapacity: true)
        // pace at ~real time/4 to approximate live feeding without taking forever
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    if !accumulator.isEmpty {
        let st = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
        if let (input, _) = convertToAnalyzerInput(accumulator, startTime: st) { inputBuilder.yield(input); yielded += 1 }
    }
    log("transflow: yielded=\(yielded) dropped=\(dropped) cumulativeFrames=\(cumulativeOutputFrames)")
}

inputBuilder.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
try? await Task.sleep(nanoseconds: 500_000_000)
resultTask.cancel()

let c = await collector.snapshot()
print("MODE=\(mode)")
print("VOLATILE_COUNT=\(c.volatileCount)")
print("LAST_VOLATILE=\(c.lastVolatile)")
print("FINALS(\(c.finals.count)):")
for f in c.finals { print("  >> \(f)") }
