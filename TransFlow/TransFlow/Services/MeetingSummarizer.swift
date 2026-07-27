import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Generates AI-powered meeting summaries from transcription entries.
///
/// Uses Apple FoundationModels (LanguageModelSession) when available
/// (macOS 15+, Apple Silicon, Apple Intelligence enabled).
@MainActor
final class MeetingSummarizer {

    enum SummaryError: LocalizedError {
        case modelUnavailable
        case generationFailed(String)
        case emptyTranscription

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return String(localized: "summary.error.unavailable")
            case .generationFailed(let message):
                return message
            case .emptyTranscription:
                return String(localized: "summary.error.empty")
            }
        }
    }

    /// Whether FoundationModels is available on this device.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 15.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Generate a meeting summary from transcription entries.
    @available(macOS 15.0, *)
    func summarize(
        entries: [JSONLContentEntry],
        sessionName: String? = nil
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard !entries.isEmpty else {
            throw SummaryError.emptyTranscription
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw SummaryError.modelUnavailable
        }

        let transcriptText = formatTranscript(entries: entries)
        let prompt = buildPrompt(transcript: transcriptText, sessionName: sessionName)
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: prompt)

        var fullText = ""
        for try await snapshot in stream {
            fullText += snapshot.content
        }

        return fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw SummaryError.modelUnavailable
        #endif
    }

    // MARK: - Formatting

    /// Format transcript entries into a readable text for the LLM.
    private func formatTranscript(entries: [JSONLContentEntry]) -> String {
        var lines: [String] = []
        for entry in entries {
            let timeStr = formatTime(entry.startTime)
            if let speaker = entry.speakerId, !speaker.isEmpty {
                let speakerName = SpeakerDisplayName.displayName(for: speaker)
                lines.append("[\(timeStr)] \(speakerName): \(entry.originalText)")
            } else {
                lines.append("[\(timeStr)] \(entry.originalText)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func formatTime(_ iso8601: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso8601) else { return iso8601 }
        let display = DateFormatter()
        display.dateFormat = "HH:mm:ss"
        return display.string(from: date)
    }

    // MARK: - Prompt Building

    #if canImport(FoundationModels)
    @available(macOS 15.0, *)
    private var instructions: String {
        """
        You are a professional meeting assistant. Given a meeting transcript, \
        produce a well-structured summary in Markdown format. The summary should \
        include:

        1. **Overview** — 2-3 sentences describing the meeting purpose and outcome
        2. **Key Discussion Points** — bullet points of main topics discussed
        3. **Decisions Made** — any decisions reached (if applicable)
        4. **Action Items** — tasks assigned with responsible person (if applicable)
        5. **Open Questions** — unresolved items or follow-ups (if applicable)

        Write in the same language as the transcript. Be concise and factual.
        """
    }

    @available(macOS 15.0, *)
    private func buildPrompt(transcript: String, sessionName: String?) -> String {
        var parts: [String] = []
        if let name = sessionName {
            parts.append("Meeting: \(name)")
        }
        parts.append("\nTranscript:")
        parts.append(transcript)
        parts.append("\nPlease provide a structured summary of this meeting.")
        return parts.joined(separator: "\n")
    }
    #endif
}
