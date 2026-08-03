import Foundation
import FluidAudio

/// P2-2 修复：从 TransFlowViewModel 拆分的 Diarization 协调器。
///
/// 负责：
/// - 管理 RealtimeDiarizationService 完整生命周期（创建、初始化、启动、停止）
/// - 维护 diarization segments 缓存
/// - 根据 segment 时间范围匹配 speaker ID
/// - Backfill 历史句子的 speaker ID
/// - Speaker 显示名解析与重命名
///
/// ViewModel 通过 startSession / feedAudio / stopSession 委托调用，
/// 不再直接访问 service 属性。
@Observable
@MainActor
final class DiarizationCoordinator {

    /// Diarization segments received so far, used for backfilling sentences.
    private(set) var segments: [RealtimeDiarizationService.SpeakerSegment] = []

    /// Realtime diarization service instance.
    private(set) var service: RealtimeDiarizationService?

    /// Active speaker count from the current diarization session.
    var activeSpeakerCount: Int = 0

    /// Speaker name overrides set by the user during/after a session (anonymousId → name).
    var speakerNameOverrides: [String: String] = [:]

    /// Bumped whenever speakerNameOverrides changes to force SwiftUI re-render.
    var speakerRefreshID: UUID = UUID()

    // MARK: - Lifecycle

    /// Start a new diarization session.
    ///
    /// Creates and initializes the `RealtimeDiarizationService` with the given models
    /// and known speakers, then starts the diarization pipeline. The `onSegments`
    /// callback is invoked on the MainActor whenever new segments are produced.
    ///
    /// - Parameters:
    ///   - models: Pre-loaded diarization models (from `DiarizationModelManager`).
    ///   - knownSpeakers: Pre-enrolled known speakers (empty = no enrollment).
    ///   - onSegments: Callback invoked with new speaker segments.
    /// - Throws: If `RealtimeDiarizationService` creation or `start()` fails.
    func startSession(
        models: DiarizerModels,
        knownSpeakers: [Speaker],
        onSegments: @escaping @Sendable ([RealtimeDiarizationService.SpeakerSegment]) -> Void
    ) throws {
        let svc = try RealtimeDiarizationService()
        svc.initialize(models: models)
        if !knownSpeakers.isEmpty {
            svc.setKnownSpeakers(knownSpeakers)
        }
        try svc.start { segments in
            Task { @MainActor in onSegments(segments) }
        }
        service = svc
        activeSpeakerCount = 0
    }

    /// Feed audio samples to the active diarization service.
    /// No-op if no session is active.
    func feedAudio(_ samples: [Float]) {
        service?.feedAudio(samples)
    }

    /// Stop the current diarization session.
    func stopSession() {
        service?.stop()
        service = nil
        activeSpeakerCount = 0
    }

    /// Reset all diarization state for a new session.
    func reset() {
        stopSession()
        segments.removeAll()
        speakerNameOverrides.removeAll()
        speakerRefreshID = UUID()
    }

    // MARK: - Segment Handling

    /// Append new diarization segments and limit cache size.
    func appendSegments(_ newSegments: [RealtimeDiarizationService.SpeakerSegment]) {
        segments.append(contentsOf: newSegments)
        // 限制 segments 大小，保留最近 500 段（约 ~15 分钟音频）
        if segments.count > 500 {
            segments.removeFirst(segments.count - 500)
        }
    }

    // MARK: - Speaker Matching

    /// Assign a speaker to a sentence by matching its time range against diarization segments.
    func assignSpeaker(for sentence: TranscriptionSentence, sessionStart: Date) -> String? {
        let sentStart = sentence.startTimestamp.timeIntervalSince(sessionStart)
        let sentEnd = sentence.timestamp.timeIntervalSince(sessionStart)

        var bestSpeaker: String?
        var bestOverlap: Double = 0

        for seg in segments {
            let overlapStart = max(sentStart, Double(seg.startTime))
            let overlapEnd = min(sentEnd, Double(seg.endTime))
            let overlap = max(0, overlapEnd - overlapStart)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = seg.speakerId
            }
        }

        return bestSpeaker
    }

    /// Find sentences that need speaker ID backfill.
    /// Returns indices and their assigned speaker IDs, or nil if no changes needed.
    func computeBackfill(for sentences: [TranscriptionSentence], sessionStart: Date) -> [(index: Int, speakerId: String)]? {
        let maxBackfill = 50
        let startIndex = max(0, sentences.count - maxBackfill)

        var updates: [(Int, String)] = []

        for i in startIndex..<sentences.count where sentences[i].speakerId == nil {
            let sentStart = sentences[i].startTimestamp.timeIntervalSince(sessionStart)
            let sentEnd = sentences[i].timestamp.timeIntervalSince(sessionStart)

            var bestSpeaker: String?
            var bestOverlap: Double = 0

            for seg in segments {
                let overlapStart = max(sentStart, Double(seg.startTime))
                let overlapEnd = min(sentEnd, Double(seg.endTime))
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = seg.speakerId
                }
            }

            if let speaker = bestSpeaker {
                updates.append((i, speaker))
            }
        }

        return updates.isEmpty ? nil : updates
    }

    // MARK: - Speaker Naming

    /// Resolve the display name for a speaker ID, applying user overrides first.
    func displayName(for speakerId: String) -> String {
        if let override = speakerNameOverrides[speakerId] {
            return override
        }
        return SpeakerDisplayName.displayName(for: speakerId)
    }

    /// Rename a speaker (anonymous or known) for the current session.
    func renameSpeaker(anonymousId: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        speakerNameOverrides[anonymousId] = trimmed
        speakerRefreshID = UUID()
    }

    /// Get the speaker name override for a speaker ID (for JSONL persistence).
    func speakerName(for speakerId: String?) -> String? {
        guard let speakerId else { return nil }
        return speakerNameOverrides[speakerId]
    }
}
