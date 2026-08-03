import Foundation
@preconcurrency import WhisperKit
import CoreMedia

/// WhisperKit 版本的语音引擎
/// 使用 OpenAI Whisper 模型进行本地实时转写
/// 接受 AudioChunk 流（16kHz mono Float32），输出 TranscriptionEvent 流
///
/// 采用 VAD 门控的整句解码方案（替代滑动窗口）：
/// - 逐帧 VAD 检测语音/静音边界
/// - 当检测到静音 ≥ minSilenceDuration 时，把累积的整句一次性交给 WhisperKit
/// - 每句只解码一次，根治滑动窗口的重复输出问题
/// - Whisper 拿到完整句子上下文，准确率显著提升
/// - 句子超长（30s）时强制截断，防止 OOM
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
    @MainActor static var isAvailable: Bool {
        WhisperKitModelManager.shared.isReady
    }

    private static let sampleRate = 16000

    /// P1-1 修复：存储 processStream 内部的 Task，使 stop() 能够取消它，
    /// 防止快速重启时旧引擎的 Task 泄漏运行。
    /// 用锁保护：processStream 的后台 Task 写入，stop()（MainActor）读取/清空，两者并发。
    private let processingTaskLock = NSLock()
    nonisolated(unsafe) private var _processingTask: Task<Void, Never>?

    private var processingTask: Task<Void, Never>? {
        get {
            processingTaskLock.lock()
            defer { processingTaskLock.unlock() }
            return _processingTask
        }
        set {
            processingTaskLock.lock()
            _processingTask = newValue
            processingTaskLock.unlock()
        }
    }

    /// 初始化
    init(
        locale: Locale,
        modelName: String = WhisperKitModelManager.defaultModelName,
        onDownloadProgress: (@Sendable (Double) -> Void)? = nil,
        useVAD: Bool = true
    ) {
        self.locale = locale
        self.modelName = modelName
        self.onDownloadProgress = onDownloadProgress
        // VAD 在新架构（VAD 门控整句解码）中是核心机制，不可禁用。
        // useVAD 参数保留以兼容 API 但不再创建 threshold=0 的实例。
        self.vadService = VADService()
    }

    /// 处理音频流并返回转写事件流
    ///
    /// VAD 门控的整句解码：逐帧 VAD 检测语音/静音边界，
    /// 当检测到静音 ≥ 0.8s 时，把累积的整句一次性交给 WhisperKit。
    ///
    /// 语言策略：使用 `locale` 提取的语言代码（如 "en"/"zh"），
    /// 让 WhisperKit 用正确语言的解码器。当用户选 "Auto" 时传 nil 让 WhisperKit 自动检测。
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )

        processingTask = Task {
            do {
                let whisperKit = try await loadWhisperKit()
                let promptText = await Self.contextPromptText()

                // 语言：从 locale 提取语言代码。
                // 传具体语言（如 "zh"）让 WhisperKit 用正确语言的解码器，
                // 避免 language: nil 时 WhisperKit 对较长的非英文音频做翻译而非转写。
                // 当用户选 "Auto" 时 locale 为 system，此处返回 "en" 作为 fallback。
                // 未来可加一个 "Auto" 选项，传 nil 让 WhisperKit 自动检测。
                let languageCode = Self.convertLocaleToWhisperLanguage(locale)

                var transcribeChain: Task<Void, Never>?
                nonisolated(unsafe) let capturedWhisperKit = whisperKit

                ErrorLogger.shared.log(
                    "Starting VAD-gated utterance processing (promptTokens=\(promptText.isEmpty ? "none" : "set"))",
                    source: "WhisperKitSpeechEngine"
                )

                // ── 在线 VAD 状态机 ──
                var utteranceBuffer: [Float] = []
                var utteranceStartTime: Date?
                var silenceFrameCount = 0
                let frameSize = Self.sampleRate / 50     // 20ms frames = 320 samples
                let minSilenceFrames = 40                // 0.8s = 40 frames × 20ms
                let maxUtteranceSamples = Self.sampleRate * 30  // 30s 上限
                let silenceThreshold = vadService.silenceThreshold

                for await chunk in audioStream {
                    // 把 chunk 按 20ms 帧切分，逐帧 VAD
                    var offset = 0
                    while offset < chunk.samples.count {
                        let frameEnd = min(offset + frameSize, chunk.samples.count)
                        let frame = Array(chunk.samples[offset..<frameEnd])

                        let paddedFrame: [Float]
                        if frame.count == frameSize {
                            paddedFrame = frame
                        } else {
                            paddedFrame = frame + [Float](repeating: 0, count: frameSize - frame.count)
                        }
                        let rms = sqrt(paddedFrame.reduce(Float(0)) { $0 + $1 * $1 } / Float(paddedFrame.count))

                        // 语音开始检测
                        if utteranceStartTime == nil && rms >= silenceThreshold {
                            // Bug 3 修复：用帧级偏移修正起始时间，而非整个 chunk 的时间戳。
                            // chunk.timestamp 是 chunk 开始采集的时间；语音可能在 chunk 中间某帧才开始。
                            // offset 是当前帧在 chunk 中的字节偏移；每帧 frameSize 样本 = frameSize/sampleRate 秒。
                            let frameOffsetSec = Double(offset) / Double(Self.sampleRate)
                            utteranceStartTime = chunk.timestamp.addingTimeInterval(frameOffsetSec)
                            utteranceBuffer.removeAll(keepingCapacity: true)
                            silenceFrameCount = 0
                        }

                        if utteranceStartTime != nil {
                            utteranceBuffer.append(contentsOf: frame)

                            if rms >= silenceThreshold {
                                silenceFrameCount = 0
                            } else {
                                silenceFrameCount += 1

                                // 说话结束：静音 ≥ minSilenceFrames 或句子超长
                                if silenceFrameCount >= minSilenceFrames
                                   || utteranceBuffer.count >= maxUtteranceSamples {
                                    let audioToTranscribe = utteranceBuffer
                                    let startTime = utteranceStartTime ?? Date()

                                    let prev = transcribeChain
                                    transcribeChain = Task {
                                        await prev?.value
                                        await Self.transcribeAndYield(
                                            audio: audioToTranscribe,
                                            startTime: startTime,
                                            whisperKit: capturedWhisperKit,
                                            languageCode: languageCode,
                                            promptText: promptText,
                                            continuation: continuation
                                        )
                                    }

                                    utteranceBuffer.removeAll(keepingCapacity: true)
                                    utteranceStartTime = nil
                                    silenceFrameCount = 0
                                }
                            }
                        }

                        offset += frameSize
                    }
                }

                // flush 尾部未结束的句子
                if !utteranceBuffer.isEmpty {
                    let prev = transcribeChain
                    let audioToTranscribe = utteranceBuffer
                    let startTime = utteranceStartTime ?? Date()
                    transcribeChain = Task {
                        await prev?.value
                        await Self.transcribeAndYield(
                            audio: audioToTranscribe,
                            startTime: startTime,
                            whisperKit: capturedWhisperKit,
                            languageCode: languageCode,
                            promptText: promptText,
                            continuation: continuation
                        )
                    }
                }

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

    /// P1-1 修复：取消 processStream 内部的处理 Task。
    func stop() {
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - Transcription helper (shared by streaming + flush)

    /// 转写一段完整音频并 yield 结果到 continuation。
    /// 串行转写链中每个 Task 调用此方法。
    ///
    /// 注意：promptText 在此方法内进行 tokenization，生成 promptTokens
    /// 用于上下文偏置。如果 promptText 为空则不偏置（promptTokens=nil）。
    private static func transcribeAndYield(
        audio: [Float],
        startTime: Date,
        whisperKit: WhisperKit,
        languageCode: String?,
        promptText: String,
        continuation: AsyncStream<TranscriptionEvent>.Continuation
    ) async {
        // 上下文偏置：把热词 prompt 文本 tokenize 为 promptTokens
        var promptTokens: [Int]? = nil
        if !promptText.isEmpty, let tokenizer = whisperKit.tokenizer {
            let tokens = tokenizer.encode(text: promptText)
            if !tokens.isEmpty {
                promptTokens = tokens
            }
        }

        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: languageCode,      // nil = 自动检测；具体 code 锁定语言
            temperature: 0.0,
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            promptTokens: promptTokens,   // 热词上下文偏置
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        do {
            let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decodeOptions)
            for segment in results.first?.segments ?? [] {
                var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 剥离控制 token
                text = text.replacingOccurrences(
                    of: #"<\|[^|]*\|>"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let segStart = startTime.addingTimeInterval(Double(segment.start))
                let segEnd = startTime.addingTimeInterval(Double(segment.end))
                continuation.yield(.sentenceComplete(
                    TranscriptionSentence(
                        id: UUID(),
                        startTimestamp: segStart,
                        timestamp: segEnd,
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

    // MARK: - Model Loading

    /// 加载 WhisperKit（含 90s Core ML ANE 编译硬超时）。
    private func loadWhisperKit() async throws -> WhisperKit {
        ErrorLogger.shared.log(
            "WhisperKitSpeechEngine: [1/5] init start, model=\(modelName), locale=\(locale.identifier)",
            source: "WhisperKitSpeechEngine"
        )

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
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

        onDownloadProgress?(1.0)
        ErrorLogger.shared.log("WhisperKit initialized successfully", source: "WhisperKitSpeechEngine")
        return whisperKit
    }

    // MARK: - Decoding Options

    /// 从 `AppSettings.hotwords` 构建上下文偏置 prompt 文本。
    @MainActor
    private static func contextPromptText() -> String {
        let standards = AppSettings.shared.hotwords.compactMap { entry -> String? in
            guard let first = entry.split(separator: ",").first else { return nil }
            let standard = first.trimmingCharacters(in: .whitespaces)
            return standard.isEmpty ? nil : standard
        }
        return standards.joined(separator: ", ")
    }

    /// 构建解码选项。
    ///
    /// 语言自动检测：`languageCode` 传 nil 时，WhisperKit 在每段音频开头自动检测语言。
    /// 这比锁死单一语言更鲁棒——尤其在中英混合场景下，锁 en 会导致中文被映射为英文 token 乱码。
    private func buildDecodeOptions(
        languageCode: String?,
        whisperKit: WhisperKit,
        promptText: String
    ) -> DecodingOptions {
        var promptTokens: [Int]? = nil
        if !promptText.isEmpty, let tokenizer = whisperKit.tokenizer {
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
            temperatureIncrementOnFallback: 0.2,
            temperatureFallbackCount: 5,
            promptTokens: promptTokens,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )
    }

    /// 离线整段转写（供 AccuracyBenchmarks 评测使用）。
    ///
    /// `language` 参数：传具体语言代码（如 "zh"）锁定解码器语言，
    /// 传 nil 让 WhisperKit 自动检测（对较长的非英文音频可能误做翻译）。
    func transcribeWholeFile(_ audio: [Float], language: String? = nil) async throws -> String {
        let whisperKit = try await loadWhisperKit()
        let promptText = await Self.contextPromptText()
        let decodeOptions = buildDecodeOptions(
            languageCode: language,
            whisperKit: whisperKit,
            promptText: promptText
        )

        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: decodeOptions)
        return results.first?.segments
            .compactMap { segment -> String? in
                var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 剥离控制 token（与 processStream 保持一致）
                text = text.replacingOccurrences(
                    of: #"<\|[^|]*\|>"#,
                    with: "",
                    options: .regularExpression
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
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
