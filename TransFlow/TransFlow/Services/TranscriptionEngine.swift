import Foundation

/// Protocol abstracting a transcription engine.
///
/// Both `SpeechEngine` (Apple Speech) and `WhisperKitSpeechEngine` (OpenAI Whisper)
/// conform to this protocol, allowing the ViewModel to switch engines without
/// `AnyObject` casts. Use `isAvailable` at runtime to short-circuit when the
/// engine's dependencies (e.g. WhisperKit model files) are not yet present.
protocol TranscriptionEngineProtocol: Sendable {
    /// Whether the engine's prerequisites are satisfied.
    ///
    /// Must be accessed from the main actor — engine state (model readiness, etc.)
    /// is UI-facing and managed alongside the ViewModel.
    ///
    /// - `true` for `SpeechEngine` (Apple Speech is a system framework, always present on macOS 14+).
    /// - For `WhisperKitSpeechEngine`, returns `true` only when the Core ML model
    ///   files have been downloaded and verified on disk.
    @MainActor static var isAvailable: Bool { get }

    /// Process an audio chunk stream and return a stream of transcription events.
    func processStream(_ audioStream: AsyncStream<AudioChunk>) -> AsyncStream<TranscriptionEvent>
}
