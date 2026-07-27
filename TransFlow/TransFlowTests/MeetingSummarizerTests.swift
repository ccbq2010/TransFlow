import Testing
import Foundation
@testable import TransFlow

@MainActor
struct MeetingSummarizerTests {

    @Test func isAvailableReturnsBool() {
        let _ = MeetingSummarizer.isAvailable
    }

    @Test func summarizerCanBeCreated() {
        let summarizer = MeetingSummarizer()
        #expect(summarizer != nil)
    }

    @Test func emptyEntriesThrowsError() async {
        let summarizer = MeetingSummarizer()
        do {
            _ = try await summarizer.summarize(entries: [], sessionName: nil)
            Issue.record("Expected emptyTranscription error")
        } catch MeetingSummarizer.SummaryError.emptyTranscription {
            // Expected
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
