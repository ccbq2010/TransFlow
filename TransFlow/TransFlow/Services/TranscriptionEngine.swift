import Foundation

/// Protocol abstracting a transcription engine.
/// Both `SpeechEngine` (Apple Speech) and `WhisperKitSpeechEngine` (OpenAI Whisper)
/// conform to this protocol, allowing the ViewModel to switch engines without
/// `AnyObject` casts.
protocol TranscriptionEngineProtocol: Sendable {
    /// Process an audio chunk stream and return a stream of transcription events.
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent>
}
