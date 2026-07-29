import Foundation
import FluidAudio

/// Captures audio and extracts speaker embeddings for enrollment.
///
/// Uses FluidAudio's `DiarizerManager.extractSpeakerEmbedding` to compute a
/// 256-dimensional voice embedding from ~5-10 seconds of speech. The embedding
/// is then stored in `SpeakerProfilesStore` for future identification.
///
/// Lifecycle:
    /// 1. Call `beginEnrollment()` — loads diarization models if needed.
    /// 2. Feed audio via `feedAudio(_:)` or use the built-in tap.
    /// 3. Call `extractEmbedding()` — returns the averaged embedding from all fed audio.
    /// 4. Call `reset()` to clear the buffer for the next speaker.
final class SpeakerEnrollmentService: @unchecked Sendable {

    private var diarizerManager: DiarizerManager?
    private var audioBuffer: [Float] = []
    private let bufferLock = NSLock()
    private var isPrepared = false

    /// Minimum audio duration (seconds) needed for a reliable embedding.
    nonisolated(unsafe) static let minimumDuration: Double = 3.0
    /// Recommended audio duration (seconds) for best results.
    static let recommendedDuration: Double = 8.0
    private let sampleRate = 16_000

    /// Prepare the diarization models (idempotent).
    func prepare() async throws {
        guard !isPrepared else { return }

        let models = try await DiarizationModelManager.shared.loadModels()
        let manager = DiarizerManager()
        manager.initialize(models: models)
        self.diarizerManager = manager
        self.isPrepared = true
    }

    /// Feed 16kHz mono Float32 audio samples into the enrollment buffer.
    func feedAudio(_ samples: [Float]) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        audioBuffer.append(contentsOf: samples)
    }

    /// Current buffered audio duration in seconds.
    var currentDuration: Double {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return Double(audioBuffer.count) / Double(sampleRate)
    }

    /// Whether enough audio has been collected for enrollment.
    var hasEnoughAudio: Bool {
        currentDuration >= Self.minimumDuration
    }

    /// Extract a 256-dim embedding from the buffered audio.
    /// Requires at least `minimumDuration` seconds of audio.
    func extractEmbedding() throws -> [Float] {
        guard isPrepared, let manager = diarizerManager else {
            throw EnrollmentError.notPrepared
        }

        bufferLock.lock()
        let samples = audioBuffer
        bufferLock.unlock()

        guard Double(samples.count) >= Double(sampleRate) * Self.minimumDuration else {
            throw EnrollmentError.insufficientAudio(duration: Double(samples.count) / Double(sampleRate))
        }

        return try manager.extractSpeakerEmbedding(from: samples)
    }

    /// Clear the audio buffer (e.g. before enrolling the next speaker).
    func reset() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        audioBuffer.removeAll(keepingCapacity: true)
    }

    /// Release model resources when enrollment is complete.
    func cleanup() {
        bufferLock.lock()
        audioBuffer.removeAll()
        bufferLock.unlock()
        diarizerManager?.cleanup()
        diarizerManager = nil
        isPrepared = false
    }
}

enum EnrollmentError: LocalizedError {
    case notPrepared
    case insufficientAudio(duration: Double)

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return String(localized: "enrollment.error.not_prepared")
        case .insufficientAudio(let duration):
            return String(localized: "enrollment.error.insufficient_audio \(SpeakerEnrollmentService.minimumDuration) \(duration)")
        }
    }
}
