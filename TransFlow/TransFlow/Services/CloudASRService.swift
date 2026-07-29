import Foundation

/// OpenAI-compatible cloud ASR client (SiliconFlow TeleSpeechASR / Whisper, etc.).
///
/// Ported from the VOX project's `CloudRecognizer` and adapted for Swift 6 strict
/// concurrency. Builds a 16-bit PCM WAV from Float32 samples and POSTs a
/// multipart/form-data body to `<baseURL>` with `model` + `file` fields, mirroring
/// the VOX API contract.
struct CloudASRService: CloudASRServiceProtocol {
    let config: CloudASRConfig
    private let session: URLSession

    init(config: CloudASRConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = config.timeout
        cfg.timeoutIntervalForResource = config.timeout
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    func transcribe(samples: [Float], sampleRate: Double = 16_000) async -> String? {
        guard !samples.isEmpty else { return nil }
        let wav = Self.buildWav(samples: samples, sampleRate: sampleRate)
        return await transcribe(wavData: wav)
    }

    func transcribe(wavData: Data) async -> String? {
        guard config.isConfigured, !wavData.isEmpty else { return nil }

        // Long-audio safety net: chunk and join (VOX chunks at 7s to stay under timeout).
        let bytesPerSecond = 16_000 * 2
        let maxChunkBytes = Int(config.chunkSeconds) * bytesPerSecond
        if wavData.count > maxChunkBytes + 44 {
            return await transcribeChunked(wav: wavData, maxChunkBytes: maxChunkBytes)
        }
        return await post(wavData: wavData)
    }

    // MARK: - Networking

    private func post(wavData: Data) async -> String? {
        guard let url = URL(string: config.baseURL) else { return nil }

        let boundary = "transflow-\(UUID().uuidString.prefix(8))"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(config.model)\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("TransFlow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = config.timeout
        request.httpBody = body

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                ErrorLogger.shared.log("Cloud ASR: no HTTP response", source: "CloudASR")
                return nil
            }
            if http.statusCode != 200 {
                ErrorLogger.shared.log("Cloud ASR failed: HTTP \(http.statusCode)", source: "CloudASR")
                return nil
            }
            return Self.parseText(from: data)
        } catch {
            ErrorLogger.shared.log("Cloud ASR network error: \(error.localizedDescription)", source: "CloudASR")
            return nil
        }
    }

    private func transcribeChunked(wav: Data, maxChunkBytes: Int) async -> String? {
        let pcm = Array(wav.dropFirst(44))
        // P2-1 / P2-4 修复：分块间增加 0.5s 重叠（16kHz 16-bit mono = 16000 bytes/s），
        // 避免在单词中间硬切分导致识别质量下降
        let overlapBytes = min(16_000, maxChunkBytes / 4) // 0.5s or 25% of chunk
        let stride = max(1, maxChunkBytes - overlapBytes)
        // P2-1 修复：最小块大小保护，最后一块不足 1s 则合并到前一块
        let minLastChunkBytes = 16_000 // 1s of 16kHz 16-bit mono
        var chunks: [Data] = []
        var offset = 0
        while offset < pcm.count {
            let end = min(offset + maxChunkBytes, pcm.count)
            let chunkPCM = Data(pcm[offset..<end])
            var chunkWav = Self.buildWavHeader(pcmSize: UInt32(chunkPCM.count), sampleRate: 16_000)
            chunkWav.append(chunkPCM)
            chunks.append(chunkWav)
            if end >= pcm.count { break }
            offset += stride
        }
        // P2-1 修复：如果最后一块太小且前面有块，合并到前一块
        if chunks.count >= 2,
           let lastChunk = chunks.last,
           lastChunk.count - 44 < minLastChunkBytes {
            chunks.removeLast()
        }
        // P0-3 修复：用索引保留原始顺序，避免并发完成顺序不一致导致结果乱序
        let results = await withTaskGroup(of: (Int, String?).self) { group -> [String] in
            for (i, chunk) in chunks.enumerated() {
                group.addTask { (i, await self.post(wavData: chunk)) }
            }
            var indexed: [(Int, String)] = []
            for await (i, r) in group {
                if let r, !r.isEmpty { indexed.append((i, r)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // P2-1 修复：重叠区域重复文本去重
        // 相邻分片有 overlapBytes 的重叠，转写结果可能在重叠区域产生重复文本。
        // 简单去重：如果后一个结果的开头是前一个结果结尾的子串，则去除。
        guard !results.isEmpty else { return nil }
        if results.count == 1 { return results[0] }
        var deduped: [String] = [results[0]]
        for prevResult in results.dropFirst() {
            let prev = deduped.last!
            // 尝试找到 prev 结尾与 curr 开头的最长公共子串，去除重复部分
            let dedupedResult = Self.dedupOverlap(prev: prev, curr: prevResult)
            deduped.append(dedupedResult)
        }
        return deduped.joined(separator: " ")
    }

    /// P2-1 修复：去除相邻分片重叠区域的重复文本。
    /// 在前一个结果的尾部和后一个结果的开头之间寻找最长匹配，去除重复部分。
    private static func dedupOverlap(prev: String, curr: String) -> String {
        let prevWords = prev.components(separatedBy: .whitespaces)
        let currWords = curr.components(separatedBy: .whitespaces)
        guard !prevWords.isEmpty, !currWords.isEmpty else { return curr }

        // 限制搜索范围：最多检查前一个结果最后 N 个词和后一个结果前 N 个词
        let maxCheck = min(prevWords.count, currWords.count, 20)
        var bestMatchLen = 0

        for matchLen in stride(from: maxCheck, through: 1, by: -1) {
            let prevTail = Array(prevWords.suffix(matchLen))
            let currHead = Array(currWords.prefix(matchLen))
            // 比较时不区分大小写
            if prevTail.map({ $0.lowercased() }) == currHead.map({ $0.lowercased() }) {
                bestMatchLen = matchLen
                break
            }
        }

        if bestMatchLen > 0 {
            // 去除后一个结果开头的重复词
            return currWords.dropFirst(bestMatchLen).joined(separator: " ")
        }
        return curr
    }

    // MARK: - Parsing

    private static func parseText(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String, !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some endpoints return a bare JSON string rather than {"text": ...}
        if let s = String(data: data, encoding: .utf8) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 1, !trimmed.hasPrefix("{") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - WAV encoding (16-bit PCM mono)

    /// Build a complete 16-bit PCM mono WAV from Float32 samples in [-1, 1].
    static func buildWav(samples: [Float], sampleRate: Double = 16_000) -> Data {
        let ints = samples.map { s -> Int16 in
            let clamped = max(-1.0, min(1.0, s))
            return Int16(clamped * 32_767)
        }
        let pcm = ints.withUnsafeBytes { Data($0) }
        var header = Self.buildWavHeader(pcmSize: UInt32(pcm.count), sampleRate: sampleRate)
        header.append(pcm)
        return header
    }

    private static func buildWavHeader(pcmSize: UInt32, sampleRate: Double) -> Data {
        var h = Data()
        h.append("RIFF".data(using: .ascii)!)
        h.append(withUnsafeBytes(of: UInt32(pcmSize + 36).littleEndian) { Data($0) })
        h.append("WAVE".data(using: .ascii)!)
        h.append("fmt ".data(using: .ascii)!)
        h.append(withUnsafeBytes(of: UInt32(16)) { Data($0) })
        h.append(withUnsafeBytes(of: UInt16(1)) { Data($0) }) // PCM
        h.append(withUnsafeBytes(of: UInt16(1)) { Data($0) }) // mono
        h.append(withUnsafeBytes(of: UInt32(UInt32(sampleRate))) { Data($0) })
        let byteRate = UInt32(sampleRate) * 2
        h.append(withUnsafeBytes(of: byteRate) { Data($0) })
        h.append(withUnsafeBytes(of: UInt16(2)) { Data($0) })   // block align
        h.append(withUnsafeBytes(of: UInt16(16)) { Data($0) })  // bits per sample
        h.append("data".data(using: .ascii)!)
        h.append(withUnsafeBytes(of: UInt32(pcmSize).littleEndian) { Data($0) })
        return h
    }
}
