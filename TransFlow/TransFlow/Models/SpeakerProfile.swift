import Foundation

/// A known speaker profile with a voice embedding for identification.
///
/// This is the app-level domain model, independent of FluidAudio's internal `Speaker` type.
/// Persisted as JSON in Application Support. Converted to FluidAudio `Speaker` when
/// initializing the diarization pipeline.
struct SpeakerProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var name: String
    let embedding: [Float]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        embedding: [Float],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A mapping from an anonymous diarization speaker ID (e.g. "speaker_0") to a
/// human-readable name. Created when the user renames an anonymous speaker during
/// or after a session. Persisted alongside the session JSONL.
struct SpeakerNameMapping: Codable, Equatable, Sendable {
    let anonymousId: String
    var name: String
    let createdAt: Date

    init(anonymousId: String, name: String, createdAt: Date = Date()) {
        self.anonymousId = anonymousId
        self.name = name
        self.createdAt = createdAt
    }
}
