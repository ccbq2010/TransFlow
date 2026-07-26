import Testing
import Foundation
@testable import TransFlow

struct AnswerSuggesterTests {

    @Test @MainActor func isAvailableReturnsBool() {
        // Just verify it doesn't crash; value depends on device
        let _ = AnswerSuggester.isAvailable
    }

    @Test @MainActor func suggesterCanBeCreated() {
        let suggester = AnswerSuggester()
        #expect(suggester != nil)
    }
}
