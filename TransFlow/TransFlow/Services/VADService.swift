import Foundation

/// Voice Activity Detection service for WhisperKit path.
///
/// Filters out silent segments from audio before feeding to WhisperKit,
/// preventing the model from hallucinating text during long silence periods.
///
/// Uses a simple energy-based VAD as a lightweight first-pass filter.
/// Can be upgraded to Silero VAD (Core ML) when a suitable Swift package
/// or converted model becomes available.
final class VADService: Sendable {
    /// RMS energy threshold below which audio is considered silence.
    /// Tuned for 16kHz mono Float32 audio.
    private let silenceThreshold: Float

    /// Minimum duration (seconds) of continuous speech to keep a segment.
    /// Filters out short noise bursts.
    private let minSpeechDuration: Double

    /// Minimum duration (seconds) of continuous silence to split segments.
    private let minSilenceDuration: Double

    /// Sample rate of the input audio.
    private let sampleRate: Int

    init(
        silenceThreshold: Float = 0.01,
        minSpeechDuration: Double = 0.3,
        minSilenceDuration: Double = 0.5,
        sampleRate: Int = 16000
    ) {
        self.silenceThreshold = silenceThreshold
        self.minSpeechDuration = minSpeechDuration
        self.minSilenceDuration = minSilenceDuration
        self.sampleRate = sampleRate
    }

    /// Detect speech segments in the given audio samples.
    /// Returns an array of (startSample, endSample) ranges for speech regions.
    func detectSpeechSegments(_ samples: [Float]) -> [ClosedRange<Int>] {
        guard !samples.isEmpty else { return [] }

        let frameSize = sampleRate / 50 // 20ms frames
        let frameCount = samples.count / frameSize
        guard frameCount > 0 else { return [] }

        // Compute RMS energy per frame
        var frameEnergies: [Float] = []
        for i in 0..<frameCount {
            let start = i * frameSize
            let end = min(start + frameSize, samples.count)
            let frame = samples[start..<end]
            let rms = sqrt(frame.reduce(0.0) { $0 + $1 * $1 } / Float(frame.count))
            frameEnergies.append(rms)
        }

        // Classify frames as speech or silence
        let isSpeech: [Bool] = frameEnergies.map { $0 >= silenceThreshold }

        // Smooth: require min consecutive silence frames to end a segment
        let minSilenceFrames = Int(minSilenceDuration * 50) // 50 fps

        // Find speech segments
        var segments: [ClosedRange<Int>] = []
        var inSpeech = false
        var speechStart = 0
        var silenceCount = 0

        for (i, speech) in isSpeech.enumerated() {
            if speech {
                if !inSpeech {
                    speechStart = i
                    inSpeech = true
                }
                silenceCount = 0
            } else {
                if inSpeech {
                    silenceCount += 1
                    if silenceCount >= minSilenceFrames {
                        // End of speech segment
                        let endFrame = i - silenceCount
                        let startSample = speechStart * frameSize
                        let endSample = endFrame * frameSize
                        if endSample - startSample >= Int(minSpeechDuration * Double(sampleRate)) {
                            segments.append(startSample...endSample)
                        }
                        inSpeech = false
                        silenceCount = 0
                    }
                }
            }
        }

        // Handle trailing speech
        if inSpeech {
            let startSample = speechStart * frameSize
            let endSample = samples.count
            if endSample - startSample >= Int(minSpeechDuration * Double(sampleRate)) {
                segments.append(startSample...endSample)
            }
        }

        return segments
    }

    /// Extract only speech portions from the audio samples.
    /// Returns concatenated speech segments (silence removed).
    func extractSpeech(_ samples: [Float]) -> [Float] {
        let segments = detectSpeechSegments(samples)
        guard !segments.isEmpty else { return [] }
        return segments.flatMap { range in
            // ClosedRange 上界可能等于 samples.count（trailing speech），
            // 用 Range 切片避免越界
            let upper = min(range.upperBound, samples.count - 1)
            guard range.lowerBound <= upper else { return [Float]() }
            return Array(samples[range.lowerBound...upper])
        }
    }

    /// P0-4 修复：提取语音段并返回拼接后的音频 + 偏移映射。
    ///
    /// WhisperKit 对拼接后的音频做转写时，segment.start/end 是相对于拼接后音频的时间戳。
    /// 调用方需要用 originalOffsets + concatenatedDurations 构建查找表，
    /// 将相对时间戳映射回原始音频的绝对偏移，避免时间戳漂移。
    ///
    /// - Parameter samples: 原始 16kHz mono Float32 音频
    /// - Returns: (拼接后的语音样本, 每段在原始音频中的起始偏移秒数, 每段在拼接后音频中的时长秒数)
    func extractSpeechWithOffsets(_ samples: [Float]) -> (audio: [Float], originalOffsets: [Double], concatenatedDurations: [Double]) {
        let segments = detectSpeechSegments(samples)
        guard !segments.isEmpty else { return ([], [], []) }

        var audio: [Float] = []
        var offsets: [Double] = []
        var durations: [Double] = []

        for range in segments {
            let upper = min(range.upperBound, samples.count - 1)
            guard range.lowerBound <= upper else { continue }
            let sampleCount = upper - range.lowerBound + 1
            // 记录该段在原始音频中的起始偏移（秒）
            offsets.append(Double(range.lowerBound) / Double(sampleRate))
            // 记录该段在拼接后音频中的时长（秒）
            durations.append(Double(sampleCount) / Double(sampleRate))
            audio.append(contentsOf: samples[range.lowerBound...upper])
        }

        return (audio, offsets, durations)
    }
}
