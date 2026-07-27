import Foundation
import Observation

/// Manages the state of answer suggestions during a live session.
@Observable
@MainActor
final class AnswerSuggestionViewModel {
    /// The currently displayed suggestion, if any.
    var currentSuggestion: SuggestedAnswer?

    /// Whether a suggestion is being generated.
    var isGenerating = false

    /// The most recent detected question.
    var lastDetectedQuestion: DetectedQuestion?

    /// Error message if generation failed.
    var errorMessage: String?

    /// Whether the suggestion panel is visible.
    var isPanelVisible = false

    /// Whether suggestions are enabled by the user.
    var isEnabled = false

    private let suggester = AnswerSuggester()
    private let knowledgeStore = KnowledgeStore.shared
    private var lastQuestionText: String?

    /// Process a new transcription sentence for question detection.
    /// If a question is found and suggestions are enabled, generate an answer.
    func processTranscription(_ text: String, fullContext: String) {
        guard isEnabled, AnswerSuggester.isAvailable else { return }
        guard let question = QuestionDetector.extractLatestQuestion(from: text) else { return }

        // Debounce: avoid re-triggering on the same question
        guard question != lastQuestionText else { return }
        lastQuestionText = question

        // Don't generate if knowledge base is empty
        guard !knowledgeStore.chunks.isEmpty else { return }

        let contextWindow = String(fullContext.suffix(2000))
        let detected = DetectedQuestion(text: question, context: contextWindow)
        lastDetectedQuestion = detected

        generateSuggestion(for: detected)
    }

    private func generateSuggestion(for question: DetectedQuestion) {
        isGenerating = true
        errorMessage = nil

        Task {
            do {
                // Offload CPU-intensive embedding search to background
                let chunks = knowledgeStore.chunks  // already on @MainActor
                let relevantChunks = await Task.detached {
                    self.knowledgeStore.retrieveTopK(for: question.text, chunks: chunks, k: 3)
                }.value
                let suggestion = try await suggester.suggestAnswer(
                    for: question.text,
                    context: question.context,
                    knowledgeChunks: relevantChunks
                )
                await MainActor.run {
                    currentSuggestion = suggestion
                    isPanelVisible = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
            await MainActor.run {
                isGenerating = false
            }
        }
    }

    /// Dismiss the current suggestion.
    func dismiss() {
        currentSuggestion = nil
        isPanelVisible = false
    }

    /// Clear state when starting a new session.
    func reset() {
        currentSuggestion = nil
        lastDetectedQuestion = nil
        errorMessage = nil
        isGenerating = false
        lastQuestionText = nil
    }
}
