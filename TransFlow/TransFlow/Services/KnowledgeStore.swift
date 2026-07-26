import Foundation
import NaturalLanguage
import PDFKit

/// Manages knowledge base documents: import, chunk, and semantic retrieval.
///
/// Documents are stored as JSON in Application Support. Each document is split
/// into chunks (~400 words each, paragraph-aligned). Retrieval uses
/// NLEmbedding.distance(between:and:) for semantic similarity.
@Observable
@MainActor
final class KnowledgeStore {
    static let shared = KnowledgeStore()

    /// All imported documents.
    private(set) var documents: [KnowledgeDocument] = []

    /// All indexed text chunks.
    private(set) var chunks: [KnowledgeChunk] = []

    /// Whether the store has been loaded from disk.
    private(set) var isLoaded = false

    /// Whether NLEmbedding is available on this system.
    private(set) var isEmbeddingAvailable = false

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var documentsURL: URL {
        appSupportDir.appendingPathComponent("knowledge_documents.json")
    }
    private var chunksURL: URL {
        appSupportDir.appendingPathComponent("knowledge_chunks.json")
    }
    private var appSupportDir: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transflow"
        return base.appendingPathComponent(bundleID, isDirectory: true)
    }

    private init() {}

    // MARK: - Lifecycle

    func load() {
        guard !isLoaded else { return }
        isLoaded = true

        isEmbeddingAvailable = NLEmbedding.sentenceEmbedding(for: .english) != nil

        if fileManager.fileExists(atPath: documentsURL.path),
           let data = try? Data(contentsOf: documentsURL),
           let decoded = try? decoder.decode([KnowledgeDocument].self, from: data) {
            documents = decoded
        }

        if fileManager.fileExists(atPath: chunksURL.path),
           let data = try? Data(contentsOf: chunksURL),
           let decoded = try? decoder.decode([KnowledgeChunk].self, from: data) {
            chunks = decoded
        }
    }

    private func saveDocuments() {
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(documents) else { return }
        try? data.write(to: documentsURL)
    }

    private func saveChunks() {
        try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(chunks) else { return }
        try? data.write(to: chunksURL)
    }

    // MARK: - Import

    /// Import a document from a file URL. Returns nil on failure.
    @discardableResult
    func importDocument(from url: URL) -> KnowledgeDocument? {
        guard let text = extractText(from: url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        return importText(text, name: name)
    }

    /// Import raw text as a document.
    @discardableResult
    func importText(_ text: String, name: String) -> KnowledgeDocument {
        let doc = KnowledgeDocument(name: name)
        documents.append(doc)
        saveDocuments()
        indexDocument(doc, text: text)
        return doc
    }

    // MARK: - Indexing

    private func indexDocument(_ doc: KnowledgeDocument, text: String) {
        let textChunks = chunkText(text)
        var newChunks: [KnowledgeChunk] = []

        for textChunk in textChunks {
            newChunks.append(KnowledgeChunk(documentId: doc.id, text: textChunk))
        }

        chunks.append(contentsOf: newChunks)
        saveChunks()

        if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[idx].chunkCount = newChunks.count
            saveDocuments()
        }
    }

    /// Split text into chunks of ~400 words, aligned to paragraph boundaries.
    private func chunkText(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var current = ""
        let maxWords = 400

        for para in paragraphs {
            let wordCount = para.split(separator: " ").count
            if current.isEmpty {
                current = para
            } else if current.split(separator: " ").count + wordCount <= maxWords {
                current += "\n\n" + para
            } else {
                result.append(current)
                current = para
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    // MARK: - Retrieval

    /// Find the top-K most relevant chunks for a query string using NLEmbedding.
    func retrieveTopK(_ query: String, k: Int = 3) -> [KnowledgeChunk] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english), !chunks.isEmpty else {
            return []
        }

        var scored: [(KnowledgeChunk, Double)] = []
        for chunk in chunks {
            let distance = embedding.distance(between: query, and: chunk.text)
            scored.append((chunk, distance))
        }

        scored.sort { $0.1 < $1.1 }
        return Array(scored.prefix(k).map { $0.0 })
    }

    // MARK: - Delete

    func deleteDocument(id: String) {
        documents.removeAll { $0.id == id }
        chunks.removeAll { $0.documentId == id }
        saveDocuments()
        saveChunks()
    }

    func resetAll() {
        documents.removeAll()
        chunks.removeAll()
        saveDocuments()
        saveChunks()
    }

    // MARK: - Text Extraction

    private func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return extractTextFromPDF(url)
        default:
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }

    private func extractTextFromPDF(_ url: URL) -> String? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        var text = ""
        for i in 0..<pdf.pageCount {
            if let pageText = pdf.page(at: i)?.string {
                text += pageText + "\n\n"
            }
        }
        return text.isEmpty ? nil : text
    }
}
