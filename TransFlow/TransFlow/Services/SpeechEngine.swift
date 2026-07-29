import Speech
import CoreMedia
@preconcurrency import AVFoundation

/// Uses macOS 26.0 SpeechAnalyzer + SpeechTranscriber for real-time transcription.
/// Accepts an AudioChunk stream (16kHz mono Float32), outputs TranscriptionEvent stream.
final class SpeechEngine: TranscriptionEngineProtocol {
    private let locale: Locale

    /// Apple Speech is a built-in framework — available on every supported macOS.
    @MainActor static var isAvailable: Bool { true }

    init(locale: Locale) {
        self.locale = locale
    }

    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let locale = self.locale

        Task {
            do {
                ErrorLogger.shared.log(
                    "processStream: initializing for locale \(locale.identifier)",
                    source: "SpeechEngine"
                )

                guard let supportedLocale = await SpeechTranscriber.supportedLocale(
                    equivalentTo: locale
                ) else {
                    ErrorLogger.shared.log("Language \(locale.identifier) not supported", source: "SpeechEngine")
                    continuation.yield(.error(String(localized: "speech.error.language_not_supported \(locale.identifier)")))
                    continuation.finish()
                    return
                }

                let transcriber = SpeechTranscriber(
                    locale: supportedLocale,
                    transcriptionOptions: [],
                    // NOTE: intentionally NOT using `.fastResults` here.
                    // `.fastResults` trades recognition accuracy for latency — it emits
                    // results as early as possible, which is exactly what hurts
                    // recognition quality for a transcription app. Keeping only
                    // `.volatileResults` lets the analyzer use fuller context for
                    // more accurate (if slightly later) final results, while still
                    // giving live partial captions.
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )

                let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber]
                )
                // Fall back to an explicit 16kHz mono format when the system returns nil,
                // so prepareToAnalyze and the buffers we feed are guaranteed to match.
                let effectiveFormat = analyzerFormat
                    ?? AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.prepareToAnalyze(in: effectiveFormat)
                ErrorLogger.shared.log(
                    "processStream: analyzer prepared (format: \(effectiveFormat.description))",
                    source: "SpeechEngine"
                )

                // 5. Create input stream
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()

                // 6. Audio format converter (16kHz → analyzer format)
                let sourceFormat = AVAudioFormat(
                    standardFormatWithSampleRate: 16_000, channels: 1
                )!
                let converter: AVAudioConverter?
                let outputSampleRate: Double
                if let analyzerFormat {
                    converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
                    outputSampleRate = analyzerFormat.sampleRate
                } else {
                    converter = nil
                    outputSampleRate = 16_000
                }

                // Pre-allocate reusable output buffer
                let reusableBuffer: AVAudioPCMBuffer?
                if converter != nil, let analyzerFormat {
                    let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
                    let capacity = AVAudioFrameCount(16_000 * 0.25 * ratio) + 64
                    reusableBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity)
                } else { reusableBuffer = nil }

                // Wall-clock anchor: maps CMTime(0) in the analyzer timeline to a real Date.
                let sessionStartDate = Date()

                // 7. Start result consumption first (avoid losing early results)
                let capturedStartDate = sessionStartDate
                let resultTask = Task(priority: .userInitiated) {
                    do {
                        for try await result in transcriber.results {
                            let text = String(result.text.characters)
                            if result.isFinal {
                                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    let range = result.range
                                    let startSec = CMTimeGetSeconds(range.start)
                                    let endSec = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
                                    let startDate = startSec.isFinite
                                        ? capturedStartDate.addingTimeInterval(startSec)
                                        : Date()
                                    let endDate = endSec.isFinite
                                        ? capturedStartDate.addingTimeInterval(endSec)
                                        : Date()
                                    continuation.yield(.sentenceComplete(
                                        TranscriptionSentence(startTimestamp: startDate, timestamp: endDate, text: trimmed)
                                    ))
                                    continuation.yield(.partial(""))
                                }
                            } else {
                                continuation.yield(.partial(text))
                            }
                        }
                    } catch {
                        ErrorLogger.shared.log("Speech error: \(error.localizedDescription)", source: "SpeechEngine")
                        continuation.yield(.error(String(localized: "speech.error.speech_error \(error.localizedDescription)")))
                    }
                }

                // 8. Start autonomous analysis
                try await analyzer.start(inputSequence: inputSequence)

                // 9. Feed audio: accumulate ~200ms before batch sending.
                //    Track cumulative sample count to provide accurate bufferStartTime.
                var accumulator: [Float] = []
                let batchThreshold = Int(16_000 * 0.2)
                var cumulativeOutputFrames: Int64 = 0

                for await chunk in audioStream {
                    accumulator.append(contentsOf: chunk.samples)
                    guard accumulator.count >= batchThreshold else { continue }

                    let startTime = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
                    if let (input, frameCount) = Self.convertToAnalyzerInput(
                        samples: accumulator, converter: converter,
                        reusableBuffer: reusableBuffer, bufferStartTime: startTime
                    ) {
                        inputBuilder.yield(input)
                        cumulativeOutputFrames += Int64(frameCount)
                    }
                    accumulator.removeAll(keepingCapacity: true)
                }

                // Flush remaining
                if !accumulator.isEmpty {
                    let startTime = CMTime(value: cumulativeOutputFrames, timescale: CMTimeScale(outputSampleRate))
                    if let (input, _) = Self.convertToAnalyzerInput(
                        samples: accumulator, converter: converter,
                        reusableBuffer: reusableBuffer, bufferStartTime: startTime
                    ) {
                        inputBuilder.yield(input)
                    }
                }

                inputBuilder.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // 排空结果流而不是立刻 cancel：finalize 之后仍可能有最终句在
                // results 流中未被消费，立刻 cancel 会把说话的结尾丢掉。
                // finalizeAndFinishThroughEndOfInput 保证 results 流会终止，
                // 这里加一个 5 秒兜底避免极端情况下挂起。
                let drainDeadline = Task {
                    try? await Task.sleep(for: .seconds(5))
                    resultTask.cancel()
                }
                _ = await resultTask.value
                drainDeadline.cancel()
                ErrorLogger.shared.log(
                    "processStream: finalized for locale \(locale.identifier)",
                    source: "SpeechEngine"
                )

            } catch {
                ErrorLogger.shared.log("Engine error: \(error.localizedDescription)", source: "SpeechEngine")
                continuation.yield(.error(String(localized: "speech.error.engine_error \(error.localizedDescription)")))
            }
            continuation.finish()
        }

        return events
    }

    // MARK: - Helpers

    /// Convert Float32 samples to AnalyzerInput (with format conversion).
    /// Returns the input and the number of output frames written.
    /// Allocates a fresh output buffer each call so the AnalyzerInput's backing data
    /// is never overwritten before the analyzer consumes it (critical for faster-than-real-time input).
    private static func convertToAnalyzerInput(
        samples: [Float],
        converter: AVAudioConverter?,
        reusableBuffer: AVAudioPCMBuffer?,
        bufferStartTime: CMTime
    ) -> (AnalyzerInput, AVAudioFrameCount)? {
        guard let pcmBuffer = createPCMBuffer(from: samples) else { return nil }

        if let converter, let reusableBuffer {
            // Capacity must cover THIS batch's actual sample count, not a fixed
            // 250ms estimate — chunk sizes from the capture tap vary with the
            // input device (e.g. AirPods @24kHz produce ~2731-sample chunks, so
            // an accumulated batch can far exceed 0.25s worth of samples).
            // Truncating here silently drops audio and destroys accuracy.
            let ratio = reusableBuffer.format.sampleRate / 16_000
            let requiredCapacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: reusableBuffer.format,
                frameCapacity: max(requiredCapacity, reusableBuffer.frameCapacity)
            )!
            outputBuffer.frameLength = 0
            var error: NSError?
            nonisolated(unsafe) var consumed = false
            nonisolated(unsafe) let capturedBuffer = pcmBuffer
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed { outStatus.pointee = .noDataNow; return nil }
                consumed = true; outStatus.pointee = .haveData; return capturedBuffer
            }
            guard error == nil, outputBuffer.frameLength > 0 else { return nil }
            return (AnalyzerInput(buffer: outputBuffer, bufferStartTime: bufferStartTime), outputBuffer.frameLength)
        } else {
            return (AnalyzerInput(buffer: pcmBuffer, bufferStartTime: bufferStartTime), pcmBuffer.frameLength)
        }
    }

    /// Create 16kHz mono PCM buffer from Float32 samples.
    private static func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { ptr in
            channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
