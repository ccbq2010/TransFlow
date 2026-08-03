import XCTest
import AVFoundation
@testable import TransFlow

/// 流式识别评测：把 eval wav 切成实时 AudioChunk 流，喂给
/// `WhisperKitSpeechEngine.processStream`（VAD 门控整句解码路径），
/// 验证流式 WER/CER、重复输出率和时间戳单调性。
///
/// 离线评测（AccuracyBenchmarks）走 `transcribeWholeFile`，不覆盖实时路径——
/// 实时路径的关键差异是 VAD 切句、串行转写链和事件流时序。
///
/// 运行方式：
/// ```
/// xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
///   -only-testing:TransFlowTests/StreamingAccuracyBenchmarks
/// ```
/// 可选环境变量 `TRANSFLOW_STREAMING_MAX_CASES=N` 限制评测条数（快速冒烟）。
/// 注意：shell 环境变量不会传给 xcodebuild 的测试进程，需要在 Xcode scheme 的
/// Test action 环境变量中设置才会生效。
@MainActor
final class StreamingAccuracyBenchmarks: XCTestCase {

    // MARK: - JSONL record（与 AccuracyBenchmarks 同一 schema，engine 区分）

    private struct BenchmarkRecord: Codable {
        var run_id: String
        var timestamp: String
        var git_sha: String
        var model: String
        var engine: String
        var dataset: String
        var wer: Double
        var cer: Double
        var avg_latency_ms: Double
        var status: String
        var hypothesis: String
        var reference: String
        var notes: String
    }

    private struct EvalCase: Decodable {
        let id: String
        let language: String
        let synthetic: Bool?
        let note: String?
    }

    private struct Manifest: Decodable {
        let cases: [EvalCase]
    }

    // MARK: - Main benchmark test

    func testStreamingAccuracyBenchmark() async throws {
        await WhisperKitModelManager.shared.checkStatus()
        let ready = WhisperKitModelManager.shared.isReady
        try XCTSkipUnless(
            ready,
            "WhisperKit 模型未下载——StreamingAccuracyBenchmarks 需要 Core ML 模型"
        )

        let bundle = Bundle(for: type(of: self))
        guard let manifestURL = findResource(named: "manifest", ext: "json", in: bundle) else {
            try XCTSkip("eval/manifest.json 不在测试 bundle 中")
            return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try XCTSkipUnless(!manifest.cases.isEmpty, "eval 评测集为空")

        // 可选限制条数（快速冒烟）
        let maxCases = ProcessInfo.processInfo.environment["TRANSFLOW_STREAMING_MAX_CASES"].flatMap(Int.init)
        let cases = maxCases.map { Array(manifest.cases.prefix($0)) } ?? manifest.cases

        let model = WhisperKitModelManager.defaultModelName
        let gitSha = gitSha()
        let runID = "stream-\(Int(Date().timeIntervalSince1970))"

        var records: [BenchmarkRecord] = []
        var realWERs: [Double] = []
        var duplicateRatios: [Double] = []
        var anySuccess = false

        for evalCase in cases {
            let dataset = "eval-streaming/\(evalCase.id)"
            guard let wavURL = findResource(named: evalCase.id, ext: "wav", in: bundle),
                  let refURL = findResource(named: "\(evalCase.id).ref", ext: "txt", in: bundle) else {
                records.append(makeRecord(
                    runID: runID, gitSha: gitSha, model: model, dataset: dataset,
                    wer: -1, cer: -1, status: "skipped", hypothesis: "", reference: "",
                    notes: "missing wav/ref resource in bundle"
                ))
                continue
            }

            let reference = (try? String(contentsOf: refURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let audio: [Float]
            do {
                audio = try loadAudioSamples(from: wavURL)
            } catch {
                records.append(makeRecord(
                    runID: runID, gitSha: gitSha, model: model, dataset: dataset,
                    wer: -1, cer: -1, status: "failed", hypothesis: "", reference: reference,
                    notes: "audio load failed: \(error.localizedDescription)"
                ))
                continue
            }

            let chunks = makeChunks(from: audio)
            let started = Date()
            let sentences = await transcribeStreaming(
                chunks: chunks,
                locale: Locale(identifier: evalCase.language == "zh" ? "zh-CN" : "en-US")
            )
            let latencyMs = Date().timeIntervalSince(started) * 1000

            let hypothesis = sentences.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard !sentences.isEmpty else {
                records.append(makeRecord(
                    runID: runID, gitSha: gitSha, model: model, dataset: dataset,
                    wer: 1.0, cer: 1.0, status: "empty_output", hypothesis: "", reference: reference,
                    notes: "streaming produced no sentences; latency \(Int(latencyMs))ms"
                ))
                continue
            }

            let wer = WERCalculator.wer(hypothesis: hypothesis, reference: reference)
            let cer = WERCalculator.cer(hypothesis: hypothesis, reference: reference)
            let duplicateRatio = duplicateSentenceRatio(sentences)
            let monotonic = timestampsMonotonic(sentences)
            if !(evalCase.synthetic ?? false) {
                realWERs.append(wer)
            }
            duplicateRatios.append(duplicateRatio)
            anySuccess = true

            let note = [
                "streaming sentences=\(sentences.count), dup=\(WERCalculator.format(percent: duplicateRatio))",
                "monotonic=\(monotonic)",
                (evalCase.synthetic ?? false) ? "synthetic (TTS); 不计入代表性 WER" : (evalCase.note ?? ""),
            ].filter { !$0.isEmpty }.joined(separator: " | ")

            records.append(makeRecord(
                runID: runID, gitSha: gitSha, model: model, dataset: dataset,
                wer: wer, cer: cer, status: "success", hypothesis: String(hypothesis.prefix(200)),
                reference: String(reference.prefix(200)), notes: note
            ))

            print("[StreamingAccuracyBenchmarks] \(evalCase.id): WER=\(WERCalculator.format(percent: wer)) CER=\(WERCalculator.format(percent: cer)) sentences=\(sentences.count) dup=\(WERCalculator.format(percent: duplicateRatio)) (\(String(format: "%.0f", latencyMs))ms)")
        }

        // 汇总写 jsonl
        let aggregateWER = realWERs.isEmpty ? -1.0 : realWERs.reduce(0, +) / Double(realWERs.count)
        let aggregateDup = duplicateRatios.isEmpty ? -1.0 : duplicateRatios.reduce(0, +) / Double(duplicateRatios.count)
        writeRecords(records, runID: runID, gitSha: gitSha, model: model)

        // 汇总行
        let summary = makeRecord(
            runID: runID, gitSha: gitSha, model: model, dataset: "eval-streaming/aggregate(real-only)",
            wer: aggregateWER, cer: -1, status: anySuccess ? "success" : "failed",
            hypothesis: "", reference: "",
            notes: "aggregate streaming WER over real cases; aggregate dup=\(aggregateDup >= 0 ? WERCalculator.format(percent: aggregateDup) : "N/A")"
        )
        appendSummary(summary)

        print("[StreamingAccuracyBenchmarks] 真实 case 聚合流式 WER = \(aggregateWER >= 0 ? WERCalculator.format(percent: aggregateWER) : "N/A"), 平均重复率 = \(aggregateDup >= 0 ? WERCalculator.format(percent: aggregateDup) : "N/A")")

        // sanity 断言：聚合 WER 不高于 60%（模型/链路失效兜底），重复率低于 10%（VAD 门控不产生重复输出）
        if !realWERs.isEmpty {
            XCTAssertLessThan(aggregateWER, 0.6, "流式聚合 WER=\(WERCalculator.format(percent: aggregateWER)) 过高")
        }
        if !duplicateRatios.isEmpty {
            XCTAssertLessThan(aggregateDup, 0.1, "流式重复输出率=\(WERCalculator.format(percent: aggregateDup)) 过高，VAD 门控疑似回归")
        }
    }

    // MARK: - Streaming transcription

    /// 把 chunk 流喂给 WhisperKit 引擎的 processStream（VAD 门控整句解码），收集全部句子事件。
    private func transcribeStreaming(chunks: [AudioChunk], locale: Locale) async -> [TranscriptionSentence] {
        let engine = WhisperKitSpeechEngine(locale: locale)
        let (chunkStream, continuation) = AsyncStream<AudioChunk>.makeStream(
            bufferingPolicy: .bufferingOldest(4096)
        )
        let events = engine.processStream(chunkStream)

        for chunk in chunks {
            continuation.yield(chunk)
        }
        continuation.finish()

        var sentences: [TranscriptionSentence] = []
        for await event in events {
            switch event {
            case .sentenceComplete(let sentence):
                sentences.append(sentence)
            case .error(let message):
                print("[StreamingAccuracyBenchmarks] engine error: \(message)")
            case .partial:
                break
            }
        }
        return sentences
    }

    /// 把 16kHz Float32 样本切成 ~256ms 的 AudioChunk（模拟实时捕获）。
    private func makeChunks(from samples: [Float], chunkSize: Int = 4096) -> [AudioChunk] {
        guard !samples.isEmpty else { return [] }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var chunks: [AudioChunk] = []
        var offset = 0
        var index = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            let slice = Array(samples[offset..<end])
            let rms = sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(slice.count))
            let db = 20 * log10(max(rms, 1e-10))
            let level = max(0, min(1, (db + 60) / 60))
            chunks.append(AudioChunk(
                samples: slice,
                level: level,
                timestamp: base.addingTimeInterval(Double(offset) / 16_000)
            ))
            offset += chunkSize
            index += 1
        }
        return chunks
    }

    /// 相邻句子文本完全相同的比例（VAD 门控的核心目标是无重复）。
    private func duplicateSentenceRatio(_ sentences: [TranscriptionSentence]) -> Double {
        guard sentences.count > 1 else { return 0 }
        var duplicates = 0
        var prev = sentences[0].text.trimmingCharacters(in: .whitespacesAndNewlines)
        for sentence in sentences.dropFirst() {
            let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == prev && !text.isEmpty {
                duplicates += 1
            }
            prev = text
        }
        return Double(duplicates) / Double(sentences.count)
    }

    /// 句子时间戳应单调非降（VAD 门控按采集时间排序）。
    private func timestampsMonotonic(_ sentences: [TranscriptionSentence]) -> Bool {
        var last = Date.distantPast
        for sentence in sentences {
            if sentence.startTimestamp < last { return false }
            last = sentence.startTimestamp
        }
        return true
    }

    // MARK: - Records & helpers（与 AccuracyBenchmarks 一致的落盘格式）

    private func makeRecord(
        runID: String, gitSha: String, model: String, dataset: String,
        wer: Double, cer: Double, status: String,
        hypothesis: String, reference: String, notes: String
    ) -> BenchmarkRecord {
        BenchmarkRecord(
            run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
            engine: "WhisperKit-streaming", dataset: dataset, wer: wer, cer: cer,
            avg_latency_ms: 0, status: status,
            hypothesis: hypothesis, reference: reference, notes: notes
        )
    }

    private func writeRecords(_ records: [BenchmarkRecord], runID: String, gitSha: String, model: String) {
        let metricsDir = resolveMetricsDir()
        try? FileManager.default.createDirectory(at: metricsDir, withIntermediateDirectories: true)
        let jsonlURL = metricsDir.appendingPathComponent("wer-results.jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for record in records {
            if let line = try? encoder.encode(record), let str = String(data: line, encoding: .utf8) {
                appendLine(str, to: jsonlURL)
            }
        }
    }

    private func appendSummary(_ record: BenchmarkRecord) {
        let jsonlURL = resolveMetricsDir().appendingPathComponent("wer-results.jsonl")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let line = try? encoder.encode(record), let str = String(data: line, encoding: .utf8) {
            appendLine(str, to: jsonlURL)
        }
    }

    private func loadAudioSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let srcFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        if srcFormat == targetFormat {
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
                throw NSError(domain: "StreamingAccuracyBenchmarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "alloc pcm buffer failed"])
            }
            try file.read(into: buf, frameCount: totalFrames)
            return samples(from: buf)
        }

        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "StreamingAccuracyBenchmarks", code: 2, userInfo: [NSLocalizedDescriptionKey: "alloc input buffer failed"])
        }
        try file.read(into: inputBuf, frameCount: totalFrames)

        let converter = AVAudioConverter(from: srcFormat, to: targetFormat)!
        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inputBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            throw NSError(domain: "StreamingAccuracyBenchmarks", code: 3, userInfo: [NSLocalizedDescriptionKey: "alloc output buffer failed"])
        }

        var fed = false
        var convError: NSError?
        converter.convert(to: outBuf, error: &convError, withInputFrom: { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inputBuf
        })
        if let convError { throw convError }
        return samples(from: outBuf)
    }

    private func samples(from buf: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buf.floatChannelData else { return [] }
        let count = Int(buf.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    private func findResource(named name: String, ext: String, in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "eval") { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        let fileName = "\(name).\(ext)"
        guard let enumerator = FileManager.default.enumerator(atPath: bundle.bundlePath) else { return nil }
        while let path = enumerator.nextObject() as? String {
            if (path as NSString).lastPathComponent == fileName {
                return URL(fileURLWithPath: bundle.bundlePath).appendingPathComponent(path)
            }
        }
        return nil
    }

    private func resolveMetricsDir() -> URL {
        if let env = ProcessInfo.processInfo.environment["TRANSFLOW_METRICS_DIR"] {
            return URL(fileURLWithPath: env)
        }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("TransFlow.xcodeproj").path) {
                return dir.appendingPathComponent("metrics")
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("transflow-metrics")
    }

    private func gitSha() -> String {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("TransFlow.xcodeproj").path) { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path, "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch {
            return "unknown"
        }
    }

    private func isoNow() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    private func appendLine(_ line: String, to url: URL) {
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }
}
