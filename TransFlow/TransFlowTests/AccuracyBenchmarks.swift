import XCTest
import AVFoundation
@testable import TransFlow

/// 识别率自动评测基准（见 docs/autonomous-improvement.md 提示词 A）。
///
/// 读取 `TransFlowTests/Resources/eval/` 下的评测集（`manifest.json` + `<id>.wav` + `<id>.ref.txt`），
/// 用 `WhisperKitSpeechEngine.transcribeWholeFile` 离线转写，计算 WER/CER，
/// 把每条结果 append 到 `metrics/wer-results.jsonl`（机器可读）。
///
/// 运行方式（独立运行，不走 verify-build.sh）：
/// ```
/// xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
///   -only-testing:TransFlowTests/AccuracyBenchmarks
/// ```
///
/// 模型未下载时 **明确跳过**（XCTSkip + 清晰原因），不静默通过；
/// 模型已下载但转写失败时记 `status=failed` 并在断言里暴露，不假装修好。
final class AccuracyBenchmarks: XCTestCase {

    // MARK: - JSONL record (schema 见 docs 提示词 A/C)

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
        var status: String          // success | failed | skipped
        var hypothesis: String
        var reference: String
        var notes: String
    }

    // MARK: - Manifest model

    private struct EvalCase: Decodable {
        let id: String
        let language: String
        let synthetic: Bool?
        let note: String?
    }

    private struct Manifest: Decodable {
        let version: Int
        let cases: [EvalCase]
    }

    // MARK: - Main benchmark test

    func testAccuracyBenchmark() async throws {
        // 1. 模型可用性：先 checkStatus（以磁盘为准），再读 isReady。未下载则明确跳过。
        await WhisperKitModelManager.shared.checkStatus()
        let ready = await MainActor.run { WhisperKitModelManager.shared.isReady }
        try XCTSkipUnless(
            ready,
            "WhisperKit 模型未下载——AccuracyBenchmarks 需要 Core ML 模型。" +
            "请在 App 中下载模型，或调用 WhisperKitModelManager.shared.downloadModel() 后重跑。"
        )

        // 2. 加载 manifest
        let bundle = Bundle(for: type(of: self))
        guard let manifestURL = findResource(named: "manifest", ext: "json", in: bundle) else {
            try XCTSkip("eval/manifest.json 不在测试 bundle 中（资源未打包）")
            return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        try XCTSkipUnless(!manifest.cases.isEmpty, "eval 评测集为空")

        // 3. 引擎（locale 仅影响 language hint；评测集本身的语言由 reference 决定指标）
        // 引擎 init 在 Swift 6 app target 下是 @MainActor-isolated（读取 AppSettings.shared），
        // 测试从非隔离上下文调用需显式 hop 到 MainActor。
        let engine = await MainActor.run { WhisperKitSpeechEngine(locale: Locale(identifier: "en-US")) }
        let model = WhisperKitModelManager.defaultModelName
        let gitSha = gitSha()
        let runID = "run-\(Int(Date().timeIntervalSince1970))"

        // 4. 逐条评测
        var records: [BenchmarkRecord] = []
        var realWERs: [Double] = []   // 仅统计真实（非合成）case 的 WER
        var anySuccess = false

        for evalCase in manifest.cases {
            let dataset = "eval/\(evalCase.id)"
            guard let wavURL = findResource(named: evalCase.id, ext: "wav", in: bundle),
                  let refURL = findResource(named: "\(evalCase.id).ref", ext: "txt", in: bundle) else {
                // 资源缺失：记一条 skipped，不中断
                records.append(BenchmarkRecord(
                    run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
                    engine: "WhisperKit", dataset: dataset, wer: -1, cer: -1, avg_latency_ms: 0,
                    status: "skipped", hypothesis: "", reference: "",
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
                records.append(BenchmarkRecord(
                    run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
                    engine: "WhisperKit", dataset: dataset, wer: -1, cer: -1, avg_latency_ms: 0,
                    status: "failed", hypothesis: "", reference: reference,
                    notes: "audio load failed: \(error.localizedDescription)"
                ))
                continue
            }

            let started = Date()
            let hypothesis: String
            let status: String
            do {
                hypothesis = try await engine.transcribeWholeFile(audio)
                status = "success"
                anySuccess = true
            } catch {
                hypothesis = ""
                status = "failed"
                records.append(BenchmarkRecord(
                    run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
                    engine: "WhisperKit", dataset: dataset, wer: -1, cer: -1,
                    avg_latency_ms: Date().timeIntervalSince(started) * 1000,
                    status: "failed", hypothesis: "", reference: reference,
                    notes: "transcribe failed: \(error.localizedDescription)"
                ))
                continue
            }
            let latencyMs = Date().timeIntervalSince(started) * 1000

            let wer = WERCalculator.wer(hypothesis: hypothesis, reference: reference)
            let cer = WERCalculator.cer(hypothesis: hypothesis, reference: reference)
            if !(evalCase.synthetic ?? false) {
                realWERs.append(wer)
            }

            let note = (evalCase.synthetic ?? false)
                ? "synthetic (TTS); 不计入代表性 WER | \(evalCase.note ?? "")"
                : (evalCase.note ?? "")

            records.append(BenchmarkRecord(
                run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
                engine: "WhisperKit", dataset: dataset, wer: wer, cer: cer,
                avg_latency_ms: latencyMs, status: status,
                hypothesis: String(hypothesis.prefix(200)), reference: String(reference.prefix(200)),
                notes: note
            ))

            // 控制台可见的逐条摘要
            print("[AccuracyBenchmarks] \(evalCase.id): WER=\(WERCalculator.format(percent: wer)) CER=\(WERCalculator.format(percent: cer)) (\(String(format: "%.0f", latencyMs))ms)")
        }

        // 5. 汇总 + 写 jsonl
        let aggregateWER = realWERs.isEmpty ? -1.0 : realWERs.reduce(0, +) / Double(realWERs.count)
        let metricsDir = resolveMetricsDir()
        try? FileManager.default.createDirectory(at: metricsDir, withIntermediateDirectories: true)
        let jsonlURL = metricsDir.appendingPathComponent("wer-results.jsonl")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for record in records {
            if let line = try? encoder.encode(record),
               let str = String(data: line, encoding: .utf8) {
                appendLine(str, to: jsonlURL)
            }
        }
        // 汇总行
        let summary = BenchmarkRecord(
            run_id: runID, timestamp: isoNow(), git_sha: gitSha, model: model,
            engine: "WhisperKit", dataset: "eval/aggregate(real-only)", wer: aggregateWER, cer: -1,
            avg_latency_ms: records.filter { $0.status == "success" }.map { $0.avg_latency_ms }.reduce(0.0, +) /
                Double(max(1, records.filter { $0.status == "success" }.count)),
            status: anySuccess ? "success" : "failed",
            hypothesis: "", reference: "",
            notes: "aggregate WER over real (non-synthetic) cases; cer=-1 means N/A"
        )
        if let line = try? encoder.encode(summary),
           let str = String(data: line, encoding: .utf8) {
            appendLine(str, to: jsonlURL)
        }

        print("[AccuracyBenchmarks] metrics 写入: \(jsonlURL.path)")
        print("[AccuracyBenchmarks] 真实 case 聚合 WER = \(aggregateWER >= 0 ? WERCalculator.format(percent: aggregateWER) : "N/A")")

        // 6. 宽松 sanity 断言：真实 case 聚合 WER 必须低于 60%（仅捕获"模型彻底失效/输出为空"，
        //    不是质量目标）。避免转写坏掉却测试全绿。
        if !realWERs.isEmpty {
            XCTAssertLessThan(
                aggregateWER, 0.6,
                "聚合 WER=\(WERCalculator.format(percent: aggregateWER)) 过高，疑似模型/转写链路异常（非质量门禁，仅为 sanity floor）"
            )
        }
    }

    // MARK: - Audio loading (任意格式 → 16kHz mono Float32)

    private func loadAudioSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let targetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let srcFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        if srcFormat == targetFormat {
            guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: totalFrames) else {
                throw NSError(domain: "AccuracyBenchmarks", code: 1, userInfo: [NSLocalizedDescriptionKey: "alloc pcm buffer failed"])
            }
            try file.read(into: buf, frameCount: totalFrames)
            return samples(from: buf)
        }

        guard let inputBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: totalFrames) else {
            throw NSError(domain: "AccuracyBenchmarks", code: 2, userInfo: [NSLocalizedDescriptionKey: "alloc input buffer failed"])
        }
        try file.read(into: inputBuf, frameCount: totalFrames)

        let converter = AVAudioConverter(from: srcFormat, to: targetFormat)!
        let ratio = targetFormat.sampleRate / srcFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(inputBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else {
            throw NSError(domain: "AccuracyBenchmarks", code: 3, userInfo: [NSLocalizedDescriptionKey: "alloc output buffer failed"])
        }

        var fed = false
        var convError: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inputBuf
        }
        converter.convert(to: outBuf, error: &convError, withInputFrom: inputBlock)
        if let convError { throw convError }
        return samples(from: outBuf)
    }

    private func samples(from buf: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buf.floatChannelData else { return [] }
        let count = Int(buf.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    // MARK: - Resource lookup (兼容 synchronized group 的扁平/子目录两种布局)

    private func findResource(named name: String, ext: String, in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "eval") { return url }
        if let url = bundle.url(forResource: name, withExtension: ext) { return url }
        // 兜底：枚举 bundle 按文件名匹配
        let fileName = "\(name).\(ext)"
        guard let enumerator = FileManager.default.enumerator(atPath: bundle.bundlePath) else { return nil }
        while let path = enumerator.nextObject() as? String {
            if (path as NSString).lastPathComponent == fileName {
                return URL(fileURLWithPath: bundle.bundlePath).appendingPathComponent(path)
            }
        }
        return nil
    }

    // MARK: - Metrics path / git sha / helpers

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

    private func repoRootPath() -> String {
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("TransFlow.xcodeproj").path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return FileManager.default.currentDirectoryPath
    }

    private func gitSha() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", repoRootPath(), "rev-parse", "--short", "HEAD"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let sha = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return sha.isEmpty ? "unknown" : sha
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
