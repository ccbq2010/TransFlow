// audio-diag.swift
// 列出所有音频输入设备 → 对每个录制 N 秒 → 写到 ~/Documents/audio-diag/<uid>.wav
// 用法：./audio-diag <seconds>
import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// Use UInt32 constants for scope, not Swift's AudioObjectPropertyScope enum
// (which doesn't expose .global/.input in this SDK context).
let SCOPE_GLOBAL = kAudioObjectPropertyScopeGlobal
let SCOPE_INPUT  = kAudioDevicePropertyScopeInput

func sysDefaultInputID() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: SCOPE_GLOBAL, mElement: kAudioObjectPropertyElementMain)
    var id: AudioDeviceID = 0
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &id)
    return id
}

func setDefaultInput(_ id: AudioDeviceID) {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: SCOPE_GLOBAL, mElement: kAudioObjectPropertyElementMain)
    var v = id
    let sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, sz, &v)
}

func deviceUID(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: SCOPE_GLOBAL, mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &ref) == noErr,
          let cf = ref?.takeRetainedValue() else { return "" }
    return cf as String
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceNameCFString,
        mScope: SCOPE_GLOBAL, mElement: kAudioObjectPropertyElementMain)
    var ref: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &ref) == noErr,
          let cf = ref?.takeRetainedValue() else { return "" }
    return cf as String
}

func inputStreamCount(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: SCOPE_INPUT, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
    let count = Int(sz) / MemoryLayout<AudioStreamID>.size
    return count
}

struct Dev { let id: AudioDeviceID; let uid: String; let name: String }

func listInputs() -> (defaultUID: String, devs: [Dev]) {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: SCOPE_GLOBAL, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr else { return ("", []) }
    let count = Int(sz) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    _ = ids.withUnsafeMutableBytes { p in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, p.baseAddress!)
    }
    let defaultId = sysDefaultInputID()
    let defaultUID = deviceUID(defaultId)
    var devs: [Dev] = []
    for id in ids where inputStreamCount(id) > 0 {
        devs.append(Dev(id: id, uid: deviceUID(id), name: deviceName(id)))
    }
    return (defaultUID, devs)
}

func record(_ seconds: Double, device: Dev) -> (n: Int, rms: Float, peak: Float, db: Float)? {
    let saved = sysDefaultInputID()
    setDefaultInput(device.id)
    defer { setDefaultInput(saved) }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let inputFormat = inputNode.outputFormat(forBus: 0)
    log("    format: \(Int(inputFormat.sampleRate))Hz × \(inputFormat.channelCount)ch")

    let lock = NSLock()
    nonisolated(unsafe) var captured: [Float] = []
    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buf, _ in
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength)
        var arr = [Float](repeating: 0, count: n)
        arr.withUnsafeMutableBufferPointer { dst in dst.baseAddress!.update(from: ch[0], count: n) }
        lock.lock(); captured.append(contentsOf: arr); lock.unlock()
    }
    do { try engine.start() } catch {
        log("    engine.start failed: \(error)"); return nil
    }
    Thread.sleep(forTimeInterval: seconds)
    inputNode.removeTap(onBus: 0)
    engine.stop()

    let all = lock.withLock { captured }
    let n = all.count
    guard n > 0 else { log("    (no samples)"); return nil }
    let rms = sqrt(all.reduce(Float(0)) { $0 + $1 * $1 } / Float(n))
    let peak = all.map(abs).max() ?? 0
    let db = 20 * log10(max(rms, 1e-9))

    // Write 16k mono WAV
    let outFmt = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let srcBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(n))!
    srcBuf.frameLength = AVAudioFrameCount(n)
    all.withUnsafeBufferPointer { p in srcBuf.floatChannelData?[0].update(from: p.baseAddress!, count: n) }
    let ratio = 16_000.0 / inputFormat.sampleRate
    let outCap = AVAudioFrameCount(Double(n) * ratio) + 1024
    let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: outCap)!
    outBuf.frameLength = outCap - 1024
    if let conv = AVAudioConverter(from: inputFormat, to: outFmt) {
        nonisolated(unsafe) var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, s in
            if fed { s.pointee = .endOfStream; return nil }
            fed = true; s.pointee = .haveData; return srcBuf
        }
    }
    let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/audio-diag")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let safe = device.uid.replacingOccurrences(of: "/", with: "_")
    let path = (dir as NSString).appendingPathComponent("\(safe).wav")
    let pathURL = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: pathURL)
    do {
        let f = try AVAudioFile(forWriting: pathURL, settings: outFmt.settings)
        try f.write(from: outBuf)
        log("    wav: \(path)")
    } catch {
        log("    wav write failed: \(error)")
    }
    return (n, rms, peak, db)
}

// ── main ──────────────────────────────────────────────────────────
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "5") ?? 5
log("audio-diag: \(Int(seconds))s per device")
log("===")

let (defaultUID, devs) = listInputs()
guard !devs.isEmpty else { log("No input devices found"); exit(1) }
log("Found \(devs.count) input device(s). System default input: \(defaultUID.isEmpty ? "?" : defaultUID)")
for d in devs {
    let tag = d.uid == defaultUID ? "  ← DEFAULT" : ""
    log("  • \(d.name)   uid=\(d.uid)\(tag)")
}
log("===")
log(">>> KEEP SPEAKING ENGLISH for the next \(Int(Double(seconds) * Double(devs.count)))s <<<")
log("===")

struct Row { let name: String; let uid: String; let db: Float; let peak: Float }
var rows: [Row] = []

for d in devs {
    log("\n── \(d.name)   uid=\(d.uid) ──")
    if let r = record(seconds, device: d) {
        let mark: String
        switch r.db {
        case ..<(-50): mark = "🔇 very quiet"
        case -50 ..< -30: mark = "🔈 quiet"
        case -30 ..< -10: mark = "🔉 ok"
        case -10 ..< 0: mark = "🔊 loud"
        default: mark = "⚠️ clipping"
        }
        log("    samples=\(r.n) RMS=\(String(format: "%.4f", r.rms)) ≈ \(String(format: "%.1f", r.db))dB peak=\(String(format: "%.3f", r.peak))  \(mark)")
        rows.append(Row(name: d.name, uid: d.uid, db: r.db, peak: r.peak))
    } else {
        rows.append(Row(name: d.name, uid: d.uid, db: -200, peak: 0))
    }
}

log("\n=== Summary (sorted by loudness) ===")
for r in rows.sorted(by: { $0.db > $1.db }) {
    let mark: String
    if r.peak < 0.001 { mark = "(silent — definitely not your mic)" }
    else if r.db > -40 { mark = "✅ likely your real mic" }
    else { mark = "(some signal, may be noisy)" }
    log(String(format: "  %6.1fdB  peak=%.3f  %@   uid=%@   %@", r.db, r.peak, r.name, r.uid, mark))
}


log("\nDone. WAVs in ~/Documents/audio-diag/")
log("Listen with:  afplay ~/Documents/audio-diag/<uid>.wav")
log("The WAV where you HEAR YOUR VOICE is the device TransFlow should be using.")
