import Foundation

/// A completed transcription sentence with timestamp and optional translation.
struct TranscriptionSentence: Identifiable, Sendable {
    let id: UUID
    /// When the utterance started (first partial text appeared)
    let startTimestamp: Date
    /// When the sentence was finalized
    let timestamp: Date
    var text: String
    var translation: String?
    /// Assigned speaker (e.g. "speaker_0"), nil if diarization disabled or pending
    var speakerId: String?
    /// Engine confidence score (0.0–1.0). nil if the engine does not provide it.
    var confidence: Double?

    init(
        id: UUID = UUID(),
        startTimestamp: Date,
        timestamp: Date,
        text: String,
        translation: String? = nil,
        speakerId: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.startTimestamp = startTimestamp
        self.timestamp = timestamp
        self.text = text
        self.translation = translation
        self.speakerId = speakerId
        self.confidence = confidence
    }
}

/// Events emitted by the SpeechEngine during transcription.
enum TranscriptionEvent: Sendable {
    /// A volatile (in-progress) partial transcription
    case partial(String)
    /// A finalized complete sentence
    case sentenceComplete(TranscriptionSentence)
    /// An error occurred
    case error(String)
}

/// The current state of the listening session.
enum ListeningState: Sendable, Equatable {
    case idle
    case starting
    case active
    case stopping
}

/// Audio source type selection.
enum AudioSourceType: Sendable, Equatable, Hashable {
    case microphone
    case systemAudio
    case appAudio(AppAudioTarget?)
}

/// Represents a running application that can be captured for audio.
struct AppAudioTarget: Identifiable, Sendable, Equatable, Hashable {
    let id: Int32 // process ID
    let name: String
    let bundleIdentifier: String?
    /// PNG icon data for the app (Sendable-safe representation of NSImage)
    let iconData: Data?

    static func == (lhs: AppAudioTarget, rhs: AppAudioTarget) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
