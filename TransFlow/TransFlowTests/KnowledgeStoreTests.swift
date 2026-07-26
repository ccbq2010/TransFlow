import Testing
import Foundation
@testable import TransFlow

@MainActor
struct KnowledgeStoreTests {

    // MARK: - KnowledgeDocument

    @Test func documentCreation() {
        let doc = KnowledgeDocument(name: "Test Doc")
        #expect(doc.name == "Test Doc")
        #expect(doc.chunkCount == 0)
        #expect(doc.id.isEmpty == false)
    }

    @Test func documentEquality() {
        let d1 = KnowledgeDocument(name: "A")
        let d2 = KnowledgeDocument(name: "A")
        // Different IDs
        #expect(d1 != d2)
    }

    // MARK: - KnowledgeChunk

    @Test func chunkCreation() {
        let chunk = KnowledgeChunk(documentId: "doc1", text: "Hello world")
        #expect(chunk.documentId == "doc1")
        #expect(chunk.text == "Hello world")
        #expect(chunk.id.isEmpty == false)
    }

    @Test func chunkEquality() {
        let c1 = KnowledgeChunk(documentId: "doc1", text: "Hello")
        let c2 = KnowledgeChunk(documentId: "doc1", text: "Hello")
        // Different IDs
        #expect(c1 != c2)
    }

    // MARK: - DetectedQuestion

    @Test func questionCreation() {
        let q = DetectedQuestion(text: "What is this?", context: "Some context")
        #expect(q.text == "What is this?")
        #expect(q.context == "Some context")
        #expect(q.id.isEmpty == false)
    }

    // MARK: - SuggestedAnswer

    @Test func answerCreation() {
        let answer = SuggestedAnswer(questionId: "q1", text: "The answer", sources: ["src1"])
        #expect(answer.questionId == "q1")
        #expect(answer.text == "The answer")
        #expect(answer.sources.count == 1)
        #expect(answer.isComplete == false)
    }

    @Test func answerMutability() {
        var answer = SuggestedAnswer(questionId: "q1")
        answer.text = "Updated"
        answer.isComplete = true
        #expect(answer.text == "Updated")
        #expect(answer.isComplete == true)
    }
}
