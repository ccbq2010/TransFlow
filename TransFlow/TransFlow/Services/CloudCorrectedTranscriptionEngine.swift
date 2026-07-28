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
        while let first = entries.first, last.timeIntervalSince(first.0) > maxDuration {
            entries.removeFirst()
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

        Task {
            // Fork the incoming audio so both the inner engine and our tap see every chunk.
            let (innerStream, innerCont) = AsyncStream<AudioChunk>.makeStream(
                bufferingPolicy: .bufferingOldest(256)
            )
            let (tapStream, tapCont) = AsyncStream<AudioChunk>.makeStream(
                bufferingPolicy: .bufferingOldest(256)
            )

            let forkTask = Task.detached {
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
