import Foundation
import os
import FluidAudio

/// Wraps FluidAudio's `DiarizerManager` + `AudioStream` for real-time streaming speaker diarization.
///
/// Key parameters:
/// - `clusteringThreshold: 0.5` — 较低的阈值让不同说话人（含同性）更容易被区分。
///   DiarizerManager 内部计算 `speakerThreshold = threshold * 1.2 = 0.6`，
///   `embeddingThreshold = threshold * 0.8 = 0.4`。
///   男女声余弦距离通常 0.5-0.7，0.6 的阈值能有效区分。
///   之前用 0.7（speakerThreshold=0.84）导致男女声都被合并。
/// - `minSpeechDuration: 1.5` — 提高到 1.5 秒，确保嵌入向量基于足够长的语音，
///   避免短片段（0.5s）产生不可靠嵌入导致过度分割。
/// - `chunkDuration: 10.0` — 10s chunks balance latency and accuracy.
/// - `chunkSkip: 3.0` — Overlap between chunks helps capture speaker transitions.
///
/// Must be used on `@MainActor` (FluidAudio types require it).
@MainActor
final class RealtimeDiarizationService {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.transflow",
        category: "RealtimeDiarization"
    )

    struct SpeakerSegment: Sendable {
        let speakerId: String
        let startTime: Float
        let endTime: Float
    }

    typealias DiarizationCallback = @Sendable ([SpeakerSegment]) -> Void

    private let diarizer: DiarizerManager
    private var audioStream: AudioStream?
    private var callback: DiarizationCallback?
    private var isActive = false
    private var chunkCount = 0

    init() throws {
        let config = DiarizerConfig(
            clusteringThreshold: 0.5,
            minSpeechDuration: 1.5,
            minSilenceGap: 0.3
        )
        diarizer = DiarizerManager(config: config)
    }

    deinit {
        // 兜底清理：RealtimeDiarizationService 是 @MainActor 类，
        // deinit 是非隔离的，不能安全访问 @MainActor 隔离的属性。
        // 正常路径下 stop() 会被调用并清理资源。
        // 这里仅记录日志，不访问隔离状态。
        // 注意：如果 stop() 未被调用，diarizer 会随 self 一起被 ARC 释放，
        // SpeakerManager 是 struct，其资源会自动释放。
    }

    /// Initialize the diarizer with pre-loaded models. Must be called before `start()`.
    func initialize(models: DiarizerModels) {
        diarizer.initialize(models: models)
        Self.logger.info("RealtimeDiarizationService initialized with models")
    }

    /// Start the diarization pipeline. The callback is invoked on each processed chunk.
    func start(onSegments: @escaping DiarizationCallback) throws {
        guard !isActive else { return }
        isActive = true
        chunkCount = 0
        callback = onSegments

        let stream = try AudioStream(
            chunkDuration: 10.0,
            chunkSkip: 3.0,
            streamStartTime: 0.0,
            chunkingStrategy: .useFixedSkip
        )
        audioStream = stream

        stream.bind { [weak self] chunk, time in
            guard let self else { return }
            self.chunkCount += 1
            do {
                let result = try self.diarizer.performCompleteDiarization(chunk, atTime: time)
                let segments = result.segments.map { seg in
                    SpeakerSegment(
                        speakerId: seg.speakerId,
                        startTime: seg.startTimeSeconds,
                        endTime: seg.endTimeSeconds
                    )
                }

                let uniqueSpeakers = Set(segments.map(\.speakerId))
                let totalTracked = self.diarizer.speakerManager.speakerCount
                Self.logger.info("Chunk #\(self.chunkCount) at \(time, format: .fixed(precision: 1))s: \(segments.count) segments, \(uniqueSpeakers.count) speakers in chunk [\(uniqueSpeakers.sorted().joined(separator: ", "))], \(totalTracked) total tracked")

                if let timings = result.timings {
                    Self.logger.debug("  Timings — seg: \(timings.segmentationSeconds, format: .fixed(precision: 3))s, emb: \(timings.embeddingExtractionSeconds, format: .fixed(precision: 3))s, cluster: \(timings.speakerClusteringSeconds, format: .fixed(precision: 3))s")
                }

                self.callback?(segments)
            } catch {
                Self.logger.error("Diarization chunk #\(self.chunkCount) failed: \(error.localizedDescription)")
            }
        }

        Self.logger.info("RealtimeDiarizationService started (threshold=0.5, chunk=10s, skip=3s)")
    }

    /// Feed audio samples to the diarization pipeline.
    func feedAudio(_ samples: [Float]) {
        guard isActive, let audioStream else { return }
        do {
            try audioStream.write(from: samples)
        } catch {
            Self.logger.error("AudioStream write failed: \(error.localizedDescription)")
        }
    }

    /// Stop diarization and reset state.
    func stop() {
        let finalCount = diarizer.speakerManager.speakerCount
        let chunks = self.chunkCount
        Self.logger.info("RealtimeDiarizationService stopping — \(chunks) chunks processed, \(finalCount) speakers identified")
        isActive = false
        callback = nil
        audioStream = nil
        diarizer.speakerManager.reset()
    }

    /// Current speaker count being tracked.
    var speakerCount: Int {
        diarizer.speakerManager.speakerCount
    }
}
