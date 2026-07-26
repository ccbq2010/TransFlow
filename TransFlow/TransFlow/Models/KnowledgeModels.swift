import Foundation

/// A knowledge base document imported by the user.
struct KnowledgeDocument: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    let createdAt: Date
    var chunkCount: Int

    init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        chunkCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.chunkCount = chunkCount
    }
}

/// A chunk of text from a knowledge document. Embedding is computed on-the-fly
/// via NLEmbedding.distance(between:and:) since Apple's API doesn't expose raw vectors.
struct KnowledgeChunk: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let documentId: String
    let text: String

    init(id: String = UUID().uuidString, documentId: String, text: String) {
        self.id = id
        self.documentId = documentId
        self.text = text
    }
}

/// A detected question from the live transcription with surrounding context.
struct DetectedQuestion: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
    let context: String
    let detectedAt: Date

    init(
        id: String = UUID().uuidString,
        text: String,
        context: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.context = context
        self.detectedAt = detectedAt
    }
}

/// A suggested answer generated from the knowledge base.
struct SuggestedAnswer: Identifiable, Equatable, Sendable {
    let id: String
    let questionId: String
    var text: String
    let sources: [String]
    var isComplete: Bool

    init(
        id: String = UUID().uuidString,
        questionId: String,
        text: String = "",
        sources: [String] = [],
        isComplete: Bool = false
    ) {
        self.id = id
        self.questionId = questionId
        self.text = text
        self.sources = sources
        self.isComplete = isComplete
    }
}
