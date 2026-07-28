import Foundation
@preconcurrency import WhisperKit
import CoreMedia

/// WhisperKit 版本的语音引擎
/// 使用 OpenAI Whisper 模型进行本地实时转写
/// 接受 AudioChunk 流（16kHz mono Float32），输出 TranscriptionEvent 流
///
/// 采用滑动窗口 + 串行转写链 + 墙钟锚点时间戳方案：
/// - 默认 30s 窗口，每 5s 滑动一次（WhisperStreaming 原版推荐；可由 AppSettings 调整）
/// - 转写任务串行执行，保证 segment 顺序
/// - 时间戳锚点使用 AudioChunk.timestamp 追踪窗口内最早样本的真实采集时间
///
/// 上下文偏置（context biasing）：把 `AppSettings.hotwords` 的标准词 tokenize 为
/// `DecodingOptions.promptTokens`，引导解码器偏向领域词，降低专有名词误识。
/// 离线整段转写入口 `transcribeWholeFile(_:)` 供 AccuracyBenchmarks 评测使用。
final class WhisperKitSpeechEngine: TranscriptionEngineProtocol {
    private let locale: Locale
    private let modelName: String
    private let onDownloadProgress: (@Sendable (Double) -> Void)?
    private let vadService: VADService

    /// WhisperKit 引擎依赖已下载的 Core ML 模型文件。
    ///
    /// 调用 `WhisperKitModelManager.shared.downloadModel()` 进行下载；
    /// 下载完成后此属性变为 `true`。
    @MainActor static var isAvailable: Bool {
        WhisperKitModelManager.shared.isReady
    }

    /// 滑动窗口参数（原版 WhisperStreaming 推荐 30s / 5s；由 AppSettings 注入，可热调整）
    private let windowSeconds: Double
    private let slideSeconds: Double
    private static let sampleRate = 16000

    /// P1-1 修复：存储 processStream 内部的 Task，使 stop() 能够取消它，
    /// 防止快速重启时旧引擎的 Task 泄漏运行。
    nonisolated(unsafe) private var processingTask: Task<Void, Never>?

    /// 初始化
    /// - Parameters:
    ///   - locale: 语言区域（用于选择 Whisper 模型的语言参数）
    ///   - modelName: WhisperKit 模型目录名（默认 large-v3_turbo 量化版，可选 "openai_whisper-small" 等）
    ///   - onDownloadProgress: 模型下载进度回调（0.0 ~ 1.0）
    ///   - useVAD: 是否启用 VAD 过滤静音段（默认启用，仅 WhisperKit 路径生效）
    init(
        locale: Locale,
        modelName: String = WhisperKitModelManager.defaultModelName,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil,
        useVAD: Bool = true
    ) {
        self.locale = locale
        self.modelName = modelName
        self.onDownloadProgress = onDownloadProgress
        self.vadService = useVAD ? VADService() : VADService(silenceThreshold: 0) // disabled

        // 窗口参数从 AppSettings 读取（默认 30s / 5s，贴近 WhisperStreaming 原版推荐值）
        self.windowSeconds = AppSettings.shared.whisperWindowSeconds
        self.slideSeconds = AppSettings.shared.whisperSlideSeconds
    }

    /// 处理音频流并返回转写事件流
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )

        // P1-1 修复：存储 Task 引用，使 stop() 能取消内部处理
        processingTask = Task {
            do {
                // 1. 初始化 WhisperKit（加载逻辑见 loadWhisperKit，含 90s ANE 编译硬超时）
                let whisperKit = try await loadWhisperKit()

                // 2. 设置语言
                let languageCode = Self.convertLocaleToWhisperLanguage(locale)

                // 上下文偏置 prompt：从 AppSettings.hotwords 构建，整条流复用一份
                let promptText = await Self.contextPromptText()

                // 3. 滑动窗口参数
                let chunkSize = Int(Double(Self.sampleRate) * self.windowSeconds)
                let slideSize = Int(Double(Self.sampleRate) * self.slideSeconds)

                // 4. 状态
                var audioBuffer: [Float] = []
                var windowFirstChunkTime: Date?

                // S1 修复：用 actor 保护跨 Task 共享的可变状态
                let state = TranscriptionState()

                // Bug 1.3 修复：串行转写链，保证 segment 按时间顺序 yield
                var transcribeChain: Task<Void, Never>?

                // WhisperKit 非 Sendable，串行转写链保证同一时刻只有一个 Task 访问
                nonisolated(unsafe) let capturedWhisperKit = whisperKit

                ErrorLogger.shared.log(
                    "Starting audio processing loop (window=\(self.windowSeconds)s, slide=\(self.slideSeconds)s, promptTokens=\(promptText.isEmpty ? "none" : "set"))",
                    source: "WhisperKitSpeechEngine"
                )

                // 5. 处理音频流
                for await chunk in audioStream {
                    audioBuffer.append(contentsOf: chunk.samples)

                    // 记录窗口内最早样本的采集时间（M2 修复）
                    if windowFirstChunkTime == nil {
                        windowFirstChunkTime = chunk.timestamp
                    }

                    // Bug 1.2 修复：滑动窗口，每 slideSize 样本触发一次转写
                    guard audioBuffer.count >= slideSize else { continue }

                    // S2 修复：裁剪 audioBuffer，防止无限增长
                    if audioBuffer.count > chunkSize {
                        audioBuffer = Array(audioBuffer.suffix(chunkSize))
                    }

                    // 取最近 windowSeconds 的样本
                    let window = Array(audioBuffer.suffix(chunkSize))

                    // M2 修复：锚点 = 窗口第一个样本的采集时间（比 Date().addingTimeInterval 更准）
                    let windowStartWallTime = windowFirstChunkTime ?? Date()
                    windowFirstChunkTime = nil  // 下一窗重置

                    // Bug 1.3：串行化转写，等上一个完成再执行下一个
                    let prev = transcribeChain
                    transcribeChain = Task {
                        await prev?.value  // 等前一个转写完成

                        do {
                            // P0-4 修复：VAD 过滤并提取偏移映射，
                            // 避免 VAD 拼接后 segment 时间戳相对于拼接音频而非原始窗口导致漂移
                            let (speechSamples, originalOffsets, concatDurations) = vadService.extractSpeechWithOffsets(window)
                            let audioToTranscribe: [Float]
                            let useVAD: Bool
                            if speechSamples.isEmpty {
                                audioToTranscribe = window
                                useVAD = false
                            } else {
                                audioToTranscribe = speechSamples
                                useVAD = true
                            }

                            let decodeOptions = buildDecodeOptions(
                                languageCode: languageCode,
                                whisperKit: capturedWhisperKit,
                                promptText: promptText
                            )

                            let results = try await capturedWhisperKit.transcribe(
                                audioArray: audioToTranscribe,
                                decodeOptions: decodeOptions
                            )

                            guard let result = results.first else { return }
                            let segments = result.segments

                            // P0-4：当 VAD 启用时，构建查找表将拼接后音频中的时间
                            // 映射回原始窗口中的时间
                            let vadOffsetLookup = useVAD ? Self.buildVADOffsetLookup(
                                originalOffsets: originalOffsets,
                                concatenatedDurations: concatDurations
                            ) : nil

                            for (segIdx, segment) in segments.enumerated() {
                                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { continue }

                                // P0-1 + P0-4：用绝对时间做去重，
                                // VAD 启用时加上该段在原始窗口中的偏移补偿
                                let vadOffsetSec = vadOffsetLookup?(Double(segment.start)) ?? 0
                                let startDate = windowStartWallTime.addingTimeInterval(
                                    Double(segment.start) + vadOffsetSec
                                )
                                let endDate = windowStartWallTime.addingTimeInterval(
                                    Double(segment.end) + vadOffsetSec
                                )
                                let absEnd = endDate.timeIntervalSince1970

                                let shouldCommit = await state.shouldCommit(endingAt: absEnd)
                                guard shouldCommit else { continue }

                                continuation.yield(.sentenceComplete(
                                    TranscriptionSentence(
                                        id: UUID(),
                                        startTimestamp: startDate,
                                        timestamp: endDate,
                                        text: text,
                                        translation: nil,
                                        speakerId: nil
                                    )
                                ))
                            }
                        } catch {
                            ErrorLogger.shared.log(
                                "Transcription error: \(error.localizedDescription)",
                                source: "WhisperKitSpeechEngine"
                            )
                        }
                    }
                }

                // 6. 处理剩余的音频（不足一个 slide 的尾部）
                if !audioBuffer.isEmpty && audioBuffer.count > Self.sampleRate {
                    let remainingWindow = Array(audioBuffer.suffix(chunkSize))
                    let windowStartWallTime = windowFirstChunkTime ?? Date()

                    // 等前面的转写链完成
                    await transcribeChain?.value

                    do {
                        // P0-4 修复：VAD 过滤并提取偏移映射
                        let (speechSamples, originalOffsets, concatDurations) = vadService.extractSpeechWithOffsets(remainingWindow)
                        let audioToTranscribe: [Float]
                        let useVAD: Bool
                        if speechSamples.isEmpty {
                            audioToTranscribe = remainingWindow
                            useVAD = false
                        } else {
                            audioToTranscribe = speechSamples
                            useVAD = true
                        }

                        let decodeOptions = buildDecodeOptions(
                            languageCode: languageCode,
                            whisperKit: capturedWhisperKit,
                            promptText: promptText
                        )

                        let results = try await capturedWhisperKit.transcribe(
                            audioArray: audioToTranscribe,
                            decodeOptions: decodeOptions
                        )

                        if let result = results.first {
                            let segments = result.segments
                            let vadOffsetLookup = useVAD ? Self.buildVADOffsetLookup(
                                originalOffsets: originalOffsets,
                                concatenatedDurations: concatDurations
                            ) : nil

                            for (segIdx, segment) in segments.enumerated() {
                                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { continue }

                                let vadOffsetSec = vadOffsetLookup?(Double(segment.start)) ?? 0
                                let startDate = windowStartWallTime.addingTimeInterval(
                                    Double(segment.start) + vadOffsetSec
                                )
                                let endDate = windowStartWallTime.addingTimeInterval(
                                    Double(segment.end) + vadOffsetSec
                                )
                                let absEnd = endDate.timeIntervalSince1970

                                let shouldCommit = await state.shouldCommit(endingAt: absEnd)
                                guard shouldCommit else { continue }

                                continuation.yield(.sentenceComplete(
                                    TranscriptionSentence(
                                        id: UUID(),
                                        startTimestamp: startDate,
                                        timestamp: endDate,
                                        text: text,
                                        translation: nil,
                                        speakerId: nil
                                    )
                                ))
                            }
                        }
                    } catch {
                        ErrorLogger.shared.log(
                            "Final transcription error: \(error.localizedDescription)",
                            source: "WhisperKitSpeechEngine"
                        )
                    }
                }

                // 等最后一个转写任务完成
                await transcribeChain?.value

                ErrorLogger.shared.log("Audio stream processing completed", source: "WhisperKitSpeechEngine")

            } catch {
                ErrorLogger.shared.log(String(localized: "whisperkit.error.generic") + " \(error.localizedDescription)", source: "WhisperKitSpeechEngine")
                continuation.yield(.error(String(localized: "whisperkit.error.generic") + " \(error.localizedDescription)"))
            }
            continuation.finish()
        }

        return events
    }

    /// P1-1 修复：取消 processStream 内部的处理 Task，防止快速重启时旧引擎泄漏。
    /// 调用方（TransFlowViewModel）在 stopListening 时调用。
    func stop() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - VAD Time Offset Compensation (P0-4)

    /// P0-4 修复：构建 VAD 偏移查找函数。
    ///
    /// VAD 将多个语音段拼接为连续数组。WhisperKit 对拼接后音频返回的 segment.start/end
    /// 是相对于拼接后音频的时间戳。本方法构建一个查找函数，将拼接后音频中的时间戳
    /// 映射为该时间点在原始窗口中的偏移量（秒）。
    ///
    /// 映射逻辑：
    /// - 拼接后音频 = [vad0 | vad1 | vad2 | ...]
    /// - vad_i 在拼接后音频中从 concatStart[i] 开始，持续 concatDurations[i] 秒
    /// - 对于拼接后时间 t，找到所属的 vad 段 i
    /// - 原始偏移 = originalOffsets[i] + (t - concatStart[i])
    ///
    /// - Parameters:
    ///   - originalOffsets: 每段在原始音频中的起始偏移（秒）
    ///   - concatenatedDurations: 每段在拼接后音频中的时长（秒）
    /// - Returns: 闭包，输入拼接后音频中的时间戳（秒），返回在原始窗口中的偏移（秒）
    private static func buildVADOffsetLookup(
        originalOffsets: [Double],
        concatenatedDurations: [Double]
    ) -> (Double) -> Double {
        // 构建每段在拼接后音频中的起始时间
        var concatStarts: [Double] = []
        var cumulative: Double = 0
        for duration in concatenatedDurations {
            concatStarts.append(cumulative)
            cumulative += duration
        }

        return { concatenatedTime in
            guard !concatStarts.isEmpty else { return 0 }

            // 找到 concatenatedTime 属于哪个 VAD 段
            var vadIdx = 0
            for i in 0..<concatStarts.count {
                if concatenatedTime >= concatStarts[i] {
                    vadIdx = i
                } else {
                    break
                }
            }

            // 原始偏移 = 该段在原始音频中的起始 + 在该段内的偏移
            let offsetInSegment = concatenatedTime - concatStarts[vadIdx]
            return originalOffsets[vadIdx] + offsetInSegment
        }
    }

    // MARK: - Model Loading

    /// 加载 WhisperKit（含 90s Core ML ANE 编译硬超时）。
    /// 本地有模型则离线加载（绕过 hf-mirror 元数据兼容 bug），否则走镜像站下载。
    private func loadWhisperKit() async throws -> WhisperKit {
        ErrorLogger.shared.log(
            "WhisperKitSpeechEngine: [1/5] init start, model=\(modelName), locale=\(locale.identifier)",
            source: "WhisperKitSpeechEngine"
        )

        // 模型已在本地时直接用 modelFolder 离线加载（download: false），
        // 绕过 hub 元数据检查——该检查对 hf-mirror 有兼容 bug（"Invalid metadata"），
        // 即使文件齐全也可能失败。仅当本地无模型时才走镜像站下载路径。
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localModelFolder = documents
            .appending(component: "huggingface")
            .appending(component: "models")
            .appending(component: "argmaxinc")
            .appending(component: "whisperkit-coreml")
            .appending(component: modelName)
        let hasLocalModel = FileManager.default.fileExists(
            atPath: localModelFolder.appending(path: "TextDecoder.mlmodelc/weights/weight.bin").path
        )

        ErrorLogger.shared.log(
            "WhisperKitSpeechEngine: [2/5] hasLocalModel=\(hasLocalModel), path=\(localModelFolder.path)",
            source: "WhisperKitSpeechEngine"
        )

        let config: WhisperKitConfig
        if hasLocalModel {
            ErrorLogger.shared.log(
                "WhisperKitSpeechEngine: [3/5] building config (offline mode)",
                source: "WhisperKitSpeechEngine"
            )
            config = WhisperKitConfig(
                modelFolder: localModelFolder.path,
                download: false
            )
        } else {
            ErrorLogger.shared.log(
                "WhisperKitSpeechEngine: [3/5] building config (download mode, this may hit network)",
                source: "WhisperKitSpeechEngine"
            )
            config = WhisperKitConfig(
                model: modelName,
                modelEndpoint: WhisperKitModelManager.mirrorEndpoint
            )
        }
        ErrorLogger.shared.log(
            "WhisperKitSpeechEngine: [4/5] calling WhisperKit(config) — first run may take 10-60s for Core ML ANE compile",
            source: "WhisperKitSpeechEngine"
        )

        // 90s hard cap: Core ML 首次 ANE 编译上限；超时则明确报错而不是无限等待
        let whisperKit: WhisperKit
        do {
            whisperKit = try await withThrowingTaskGroup(of: WhisperKit.self) { group in
                group.addTask { try await WhisperKit(config) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 90_000_000_000)
                    throw NSError(
                        domain: "WhisperKitSpeechEngine",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "WhisperKit load timed out after 90s (Core ML ANE compile stalled?)"]
                    )
                }
                // First task to finish wins; cancel the other.
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            ErrorLogger.shared.log(
                "WhisperKitSpeechEngine: [4/5/FAIL] \(error.localizedDescription)",
                source: "WhisperKitSpeechEngine"
            )
            throw error
        }

        ErrorLogger.shared.log(
            "WhisperKitSpeechEngine: [5/5] WhisperKit loaded, tokenizer=\(whisperKit.tokenizer != nil ? "ready" : "missing"), starting audio loop",
            source: "WhisperKitSpeechEngine"
        )

        // 通知模型已就绪
        onDownloadProgress?(1.0)

        ErrorLogger.shared.log("WhisperKit initialized successfully", source: "WhisperKitSpeechEngine")
        return whisperKit
    }

    // MARK: - Decoding Options (shared: streaming + offline benchmark)

    /// 从 `AppSettings.hotwords` 构建上下文偏置 prompt 文本（取每个热词的标准形式）。
    /// 热词条目格式为 "standard" 或 "standard,variant1,variant2"，这里只取标准词。
    @MainActor
    private static func contextPromptText() -> String {
        let standards = AppSettings.shared.hotwords.compactMap { entry -> String? in
            guard let first = entry.split(separator: ",").first else { return nil }
            let standard = first.trimmingCharacters(in: .whitespaces)
            return standard.isEmpty ? nil : standard
        }
        return standards.joined(separator: ", ")
    }

    /// 构建解码选项（流式窗口路径与离线整段转写共用）。
    /// 含上下文偏置：把热词 prompt 文本 tokenize 为 `promptTokens`，引导解码器偏向领域词，
    /// 降低专有名词误识。无热词时不传 prompt（nil = 不偏置），保持原行为。
    private func buildDecodeOptions(
        languageCode: String,
        whisperKit: WhisperKit,
        promptText: String
    ) -> DecodingOptions {
        var promptTokens: [Int]? = nil
        if !promptText.isEmpty, let tokenizer = whisperKit.tokenizer {
            // WhisperTokenizer 协议只暴露 encode(text:)（默认含 special tokens）。
            // WhisperKit 解码时会自动过滤 special token 并截断到上下文一半
            // （见 TextDecoder: filter { $0 < specialTokenBegin } + suffix(maxPromptLen)），
            // 因此这里直接 encode 即可，无需手动去 special token。
            let tokens = tokenizer.encode(text: promptText)
            if !tokens.isEmpty {
                promptTokens = tokens
            }
        }

        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,
            temperature: 0.0,
            // 原版 Whisper 质量门禁：温度回退 + 对数概率/压缩比/无语音阈值，
            // 过滤静音、噪声与低置信幻觉，显著降低 WER。
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    /// 离线整段转写（供 AccuracyBenchmarks 评测使用，见 docs/autonomous-improvement.md 提示词 A）。
    ///
    /// 复用与流式路径相同的模型加载与 `DecodingOptions`（含上下文偏置），
    /// 一次性转写整段 16kHz mono Float32 音频并返回拼接文本，便于离线批量计算 WER/CER。
    /// - Parameter audio: 16kHz mono Float32 采样数组
    /// - Returns: 所有 segment 文本用单空格拼接的结果
    func transcribeWholeFile(_ audio: [Float]) async throws -> String {
        let whisperKit = try await loadWhisperKit()
        let languageCode = Self.convertLocaleToWhisperLanguage(locale)
        let promptText = await Self.contextPromptText()
        let decodeOptions = buildDecodeOptions(
            languageCode: languageCode,
            whisperKit: whisperKit,
            promptText: promptText
        )

        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decodeOptions)
        return results.first?.segments
            .compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ") ?? ""
    }

    // MARK: - Language Conversion

    /// 将 Locale 转换为 Whisper 支持的语言代码
    private static func convertLocaleToWhisperLanguage(_ locale: Locale) -> String {
        let languageCode = locale.language.languageCode?.identifier(.alpha2) ?? "en"

        let supportedLanguages: Set<String> = [
            "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl",
            "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi", "he", "uk",
            "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr",
            "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn",
            "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne",
            "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si", "km", "sn",
            "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi",
            "lo", "uz", "fo", "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my",
            "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jw", "su"
        ]

        if supportedLanguages.contains(languageCode) {
            return languageCode
        }

        ErrorLogger.shared.log(
            "Language \(languageCode) not supported by Whisper, falling back to English",
            source: "WhisperKitSpeechEngine"
        )
        return "en"
    }
}

// MARK: - TranscriptionState (S1: actor 保护跨 Task 共享状态)

private actor TranscriptionState {
    /// P0-1 修复：存储绝对时间戳（Date.timeIntervalSince1970），
    /// 而非窗口内相对时间，确保滑动窗口间去重正确。
    var lastCommittedEndSec: Double = 0

    /// 检查 segment 是否应该被提交（去重）。
    /// - Parameter end: segment 结束的绝对时间戳（秒，自 1970 起）
    /// - Returns: true 表示该 segment 未被提交过，已更新 lastCommittedEndSec。
    func shouldCommit(endingAt end: Double) -> Bool {
        guard end > lastCommittedEndSec else { return false }
        lastCommittedEndSec = end
        return true
    }

    func reset() { lastCommittedEndSec = 0 }
}
