import Foundation

/// P2-2 修复：从 TransFlowViewModel 拆分的 Diarization 协调器。
///
/// 负责：
/// - 管理 RealtimeDiarizationService 生命周期
/// - 维护 diarization segments 缓存
/// - 根据 segment 时间范围匹配 speaker ID
/// - Backfill 历史句子的 speaker ID
/// - Speaker 显示名解析与重命名
///
/// ViewModel 通过委托方式调用，状态属性（sentences、speakerNameOverrides 等）
/// 仍保留在 ViewModel 中以维持 SwiftUI 观察链。
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
    func startSession(speakerCount: Int, onSegments: @escaping ([RealtimeDiarizationService.SpeakerSegment]) -> Void) {
        let svc = RealtimeDiarizationService(targetSpeakerCount: speakerCount)
        svc.onSegmentsUpdated = { segments in
            Task { @MainActor in onSegments(segments) }
        }
        svc.start()
        service = svc
        activeSpeakerCount = speakerCount
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
