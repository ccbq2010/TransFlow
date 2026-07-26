import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Orchestrates question detection, knowledge retrieval, and LLM-based answer generation.
///
/// Uses Apple FoundationModels (LanguageModelSession) when available
/// (macOS 15+, Apple Silicon, Apple Intelligence enabled). Otherwise returns
/// a fallback response suggesting the user enable the feature.
struct AnswerSuggester {

    /// Error types for answer suggestions.
    enum SuggestionError: LocalizedError {
        case modelUnavailable
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return String(localized: "suggestion.error.unavailable")
            case .generationFailed(let message):
                return message
            }
        }
    }

    /// Whether FoundationModels is available and usable on this device.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 15.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Generate a suggested answer for a question using knowledge base context.
    @available(macOS 15.0, *)
    func suggestAnswer(
        for question: String,
        context: String,
        knowledgeChunks: [KnowledgeChunk]
    ) async throws -> SuggestedAnswer {
        #if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw SuggestionError.modelUnavailable
        }

        let prompt = buildPrompt(question: question, context: context, chunks: knowledgeChunks)
        let session = LanguageModelSession(instructions: instructions)
        let stream = session.streamResponse(to: prompt)

        var fullText = ""
        for try await snapshot in stream {
            fullText += snapshot.content
        }

        let sources = knowledgeChunks.prefix(3).map { chunk in
            String(chunk.text.prefix(100))
        }

        return SuggestedAnswer(
            questionId: UUID().uuidString,
            text: fullText,
            sources: sources,
            isComplete: true
        )
        #else
        throw SuggestionError.modelUnavailable
        #endif
    }

    // MARK: - Prompt Building

    #if canImport(FoundationModels)
    @available(macOS 15.0, *)
    private var instructions: String {
        """
        You are a meeting assistant helping a participant answer questions in real time.
        Based on the provided knowledge base excerpts and recent conversation context,
        give a concise, actionable answer (2-3 sentences). If the knowledge base does
        not contain relevant information, say so briefly.
        """
    }

    @available(macOS 15.0, *)
    private func buildPrompt(question: String, context: String, chunks: [KnowledgeChunk]) -> String {
        var parts: [String] = []

        parts.append("## Recent conversation context")
        parts.append(context.isEmpty ? "(none)" : context)

        if !chunks.isEmpty {
            parts.append("\n## Relevant knowledge base excerpts")
            for (i, chunk) in chunks.enumerated() {
                parts.append("[\(i + 1)] \(chunk.text)")
            }
        }

        parts.append("\n## Question")
        parts.append(question)

        parts.append("\nProvide a concise answer:")

        return parts.joined(separator: "\n")
    }
    #endif
}
