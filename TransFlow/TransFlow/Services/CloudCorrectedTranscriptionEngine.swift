import Foundation

/// Actor-backed rolling buffer of recent audio, keyed by capture timestamp.
///
/// Used to recover the audio window for a finalized sentence so it can be
/// re-sent to the cloud ASR for correction without an extra capture pipeline.
actor AudioWindowBuffer {
    private var entries: [(Date, [Float])] = []
    private let maxDuration: TimeInterval

    init(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
    }

    func append(_ chunk: AudioChunk) {
        entries.append((chunk.timestamp, chunk.samples))
        trim()
    }

    private func trim() {
        guard let last = entries.last?.0 else { return }
        // P2-2 修复：批量移除过期条目，避免逐个 removeFirst 的 O(n²) 复杂度
        var cutIndex = 0
        for (i, entry) in entries.enumerated() {
            if last.timeIntervalSince(entry.0) > maxDuration {
                cutIndex = i + 1
            } else {
                break
            }
        }
        if cutIndex > 0 {
            entries.removeFirst(cutIndex)
        }
    }

    /// Return concatenated samples whose chunk timestamp falls within `range`.
    func samples(in range: ClosedRange<Date>) -> [Float] {
        var result: [Float] = []
        for (ts, samples) in entries where range.contains(ts) {
            result.append(contentsOf: samples)
        }
        return result
    }
}

/// Scheme A: hybrid transcription engine.
///
/// Wraps any on-device `TranscriptionEngineProtocol` (Apple Speech or WhisperKit).
/// Live partial captions stream through unchanged for low latency. When a sentence
/// finalizes, the audio for that window is sent to the cloud ASR and the (higher
/// accuracy) cloud result replaces the on-device text *before* it reaches the UI.
///
/// If the cloud call times out or fails, the original on-device text is used, so
/// the feature degrades gracefully and never blocks the transcript.
final class CloudCorrectedTranscriptionEngine: TranscriptionEngineProtocol {
    private let inner: any TranscriptionEngineProtocol
    private let config: CloudASRConfig
    private let service: any CloudASRServiceProtocol

    /// P1-5 修复：存储 processStream 内部的 Task，使 stop() 能够取消它
    nonisolated(unsafe) private var processingTask: Task<Void, Never>?
    /// P1-1 修复：存储 forkTask 引用，使 stop() 能直接取消它（detached Task 不随父 Task 取消）
    nonisolated(unsafe) private var forkTask: Task<Void, Never>?

    @MainActor static var isAvailable: Bool { true }

    init(
        inner: any TranscriptionEngineProtocol,
        config: CloudASRConfig,
        service: (any CloudASRServiceProtocol)? = nil
    ) {
        self.inner = inner
        self.config = config
        self.service = service ?? CloudASRService(config: config)
    }

    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent> {
        let (outEvents, outContinuation) = AsyncStream<TranscriptionEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        let config = self.config

        // P1-5 修复：存储 Task 引用以支持取消
        processingTask = Task {
            // Fork the incoming audio so both the inner engine and our tap see every chunk.
            let (innerStream, innerCont) = AsyncStream<AudioChunk>.makeStream(
                bufferingPolicy: .bufferingOldest(256)
            )
            let (tapStream, tapCont) = AsyncStream<AudioChunk>.makeStream(
                bufferingPolicy: .bufferingOldest(256)
            )

            // P1-1 修复：存储 forkTask 引用以支持外部取消
            // 保持 detached 以避免 actor 隔离阻塞，但 stop() 会显式取消
            forkTask = Task.detached {
                for await chunk in audioStream {
                    innerCont.yield(chunk)
                    tapCont.yield(chunk)
                }
                innerCont.finish()
                tapCont.finish()
            }

            let buffer = AudioWindowBuffer(maxDuration: 60)
            let tapTask = Task {
                for await chunk in tapStream {
                    await buffer.append(chunk)
                }
            }

            let events = inner.processStream(innerStream)

            for await event in events {
                switch event {
                case .partial(let text):
                    // Live captions stay on-device and immediate.
                    outContinuation.yield(.partial(text))

                case .sentenceComplete(let sentence):
                    let corrected = await correctedSentence(sentence, buffer: buffer)
                    outContinuation.yield(.sentenceComplete(corrected))

                case .error(let message):
                    outContinuation.yield(.error(message))
                }
            }

            tapTask.cancel()
            forkTask.cancel()
            outContinuation.finish()
        }

        return outEvents
    }

    /// P1-1 / P1-5 修复：取消 processStream 内部的处理 Task 和 forkTask，防止快速重启时旧引擎泄漏。
    func stop() {
        forkTask?.cancel()
        forkTask = nil
        processingTask?.cancel()
        processingTask = nil
    }

    // MARK: - Correction

    private func correctedSentence(
        _ sentence: TranscriptionSentence,
        buffer: AudioWindowBuffer
    ) async -> TranscriptionSentence {
        // Deadline keeps a slow/paused cloud from stalling the transcript.
        let deadlineSeconds = max(2.0, min(config.timeout, 8.0))
        let deadline = UInt64(deadlineSeconds * 1_000_000_000)

        let result = await withTaskGroup(of: TranscriptionSentence?.self) { group in
            group.addTask {
                // Pad the window slightly to absorb pipeline latency between capture
                // and the on-device engine's reported timestamps.
                let pad: TimeInterval = 0.5
                let range = (sentence.startTimestamp - pad)...(sentence.timestamp + pad)
                let samples = await buffer.samples(in: range)
                guard !samples.isEmpty else { return nil }
                guard let text = await self.service.transcribe(samples: samples, sampleRate: 16_000),
                      !text.isEmpty else { return nil }
                var corrected = sentence
                corrected.text = text
                return corrected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: deadline)
                return nil
            }
            for await value in group {
                return value
            }
            return nil
        }

        return result ?? sentence
    }
}
