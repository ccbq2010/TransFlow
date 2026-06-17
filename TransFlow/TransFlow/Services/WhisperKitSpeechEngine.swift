import Foundation
import WhisperKit
import CoreMedia

/// WhisperKit 版本的语音引擎
/// 使用 OpenAI Whisper 模型进行本地实时转写
/// 接受 AudioChunk 流（16kHz mono Float32），输出 TranscriptionEvent 流
///
/// 采用滑动窗口 + 串行转写链 + 墙钟锚点时间戳方案：
/// - 8s 窗口，每 3s 滑动一次
/// - 转写任务串行执行，保证 segment 顺序
/// - 时间戳锚点使用 AudioChunk.timestamp 追踪窗口内最早样本的真实采集时间
final class WhisperKitSpeechEngine: TranscriptionEngineProtocol {
    private let locale: Locale
    private let modelName: String
    private let onDownloadProgress: (@Sendable (Double) -> Void)?
    private let vadService: VADService

    /// 滑动窗口参数
    private static let windowSeconds = 8.0
    private static let slideSeconds = 3.0
    private static let sampleRate = 16000

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
    }

    /// 处理音频流并返回转写事件流
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )

        Task {
            do {
                ErrorLogger.shared.log(
                    "WhisperKitSpeechEngine: initializing with model \(modelName) for locale \(locale.identifier)",
                    source: "WhisperKitSpeechEngine"
                )

                // 1. 初始化 WhisperKit（使用镜像站端点，防止模型未缓存时从 huggingface.co 下载失败）
                let config = WhisperKitConfig(
                    model: modelName,
                    modelEndpoint: WhisperKitModelManager.mirrorEndpoint
                )
                let whisperKit = try await WhisperKit(config)

                // 通知模型已就绪
                onDownloadProgress?(1.0)

                ErrorLogger.shared.log("WhisperKit initialized successfully", source: "WhisperKitSpeechEngine")

                // 2. 设置语言
                let languageCode = Self.convertLocaleToWhisperLanguage(locale)

                // 3. 滑动窗口参数
                let chunkSize = Int(Double(Self.sampleRate) * Self.windowSeconds)
                let slideSize = Int(Double(Self.sampleRate) * Self.slideSeconds)

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
                    "Starting audio processing loop (window=\(Self.windowSeconds)s, slide=\(Self.slideSeconds)s)",
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
                            // VAD 过滤：提取语音段，去除静音
                            let speechSamples = vadService.extractSpeech(window)
                            let audioToTranscribe = speechSamples.isEmpty ? window : speechSamples

                            let decodeOptions = DecodingOptions(
                                verbose: false,
                                task: .transcribe,
                                language: languageCode,
                                temperature: 0.0
                            )

                            let results = try await capturedWhisperKit.transcribe(
                                audioArray: audioToTranscribe,
                                decodeOptions: decodeOptions
                            )

                            guard let result = results.first else { return }
                            let segments = result.segments

                            for segment in segments {
                                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { continue }

                                // S1 修复：通过 actor 安全地检查和更新 lastCommittedEndSec
                                let shouldCommit = await state.shouldCommit(endingAt: Double(segment.end))
                                guard shouldCommit else { continue }

                                // Bug 1.1 修复：时间戳 = 墙钟锚点 + segment 相对时间
                                let startDate = windowStartWallTime.addingTimeInterval(Double(segment.start))
                                let endDate = windowStartWallTime.addingTimeInterval(Double(segment.end))

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
                        // VAD 过滤尾部音频
                        let speechSamples = vadService.extractSpeech(remainingWindow)
                        let audioToTranscribe = speechSamples.isEmpty ? remainingWindow : speechSamples

                        let decodeOptions = DecodingOptions(
                            verbose: false,
                            task: .transcribe,
                            language: languageCode,
                            temperature: 0.0
                        )

                        let results = try await whisperKit.transcribe(
                            audioArray: audioToTranscribe,
                            decodeOptions: decodeOptions
                        )

                        if let result = results.first {
                            let segments = result.segments
                            for segment in segments {
                                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { continue }

                                let shouldCommit = await state.shouldCommit(endingAt: Double(segment.end))
                                guard shouldCommit else { continue }

                                let startDate = windowStartWallTime.addingTimeInterval(Double(segment.start))
                                let endDate = windowStartWallTime.addingTimeInterval(Double(segment.end))

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
                ErrorLogger.shared.log("WhisperKit error: \(error.localizedDescription)", source: "WhisperKitSpeechEngine")
                continuation.yield(.error("WhisperKit error: \(error.localizedDescription)"))
            }
            continuation.finish()
        }

        return events
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
    var lastCommittedEndSec: Double = 0

    /// 检查 segment 是否应该被提交（去重）。
    /// 返回 true 表示该 segment 未被提交过，已更新 lastCommittedEndSec。
    func shouldCommit(endingAt end: Double) -> Bool {
        guard end > lastCommittedEndSec else { return false }
        lastCommittedEndSec = end
        return true
    }

    func reset() { lastCommittedEndSec = 0 }
}
