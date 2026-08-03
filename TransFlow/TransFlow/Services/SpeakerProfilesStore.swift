import Foundation
import Accelerate
import FluidAudio

/// Manages persistent speaker profiles for voice identification.
///
/// Profiles are stored as JSON in Application Support. Each profile contains
/// a 256-dimensional voice embedding that can be matched against live diarization
/// output using cosine similarity.
@Observable
@MainActor
final class SpeakerProfilesStore {
    static let shared = SpeakerProfilesStore()

    /// All known speaker profiles, keyed by profile ID.
    private(set) var profiles: [SpeakerProfile] = []

    /// Whether profiles have been loaded from disk.
    private(set) var isLoaded = false

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transflow"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("speaker_profiles.json")
    }

    private init() {}

    // MARK: - Lifecycle

    func load() {
        guard !isLoaded else { return }
        defer { isLoaded = true }

        guard fileManager.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let decoded = try? decoder.decode([SpeakerProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func save() {
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: storageURL)
        } catch {
            ErrorLogger.shared.error(
                "Failed to save speaker profiles: \(error.localizedDescription)",
                source: "SpeakerProfilesStore"
            )
        }
    }

    // MARK: - CRUD

    @discardableResult
    func addProfile(name: String, embedding: [Float]) -> SpeakerProfile {
        let profile = SpeakerProfile(name: name, embedding: embedding)
        profiles.append(profile)
        save()
        return profile
    }

    func updateProfile(id: String, name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        save()
    }

    func deleteProfile(id: String) {
        profiles.removeAll { $0.id == id }
        save()
    }

    func resetAllProfiles() {
        profiles.removeAll()
        save()
    }

    // MARK: - FluidAudio Integration

    /// Convert all profiles to FluidAudio `Speaker` objects for diarization initialization.
    func toFluidAudioSpeakers() -> [Speaker] {
        profiles.map { profile in
            Speaker(
                id: profile.id,
                name: profile.name,
                currentEmbedding: profile.embedding,
                isPermanent: true
            )
        }
    }

    /// Find the best-matching profile for a given embedding using cosine similarity.
    /// Returns nil if no profile is within the threshold.
    func findBestMatch(for embedding: [Float], threshold: Float = 0.65) -> SpeakerProfile? {
        guard !profiles.isEmpty else { return nil }

        let normalized = l2Normalize(embedding)
        var bestProfile: SpeakerProfile?
        var bestDistance: Float = Float.infinity

        for profile in profiles {
            let distance = cosineDistance(normalized, l2Normalize(profile.embedding))
            if distance < bestDistance {
                bestDistance = distance
                bestProfile = profile
            }
        }

        if bestDistance <= threshold, let match = bestProfile {
            return match
        }
        return nil
    }

    // MARK: - Vector Math

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 0 else { return vector }

        var normalized = [Float](repeating: 0, count: vector.count)
        var invNorm = 1.0 / norm
        vDSP_vsmul(vector, 1, &invNorm, &normalized, 1, vDSP_Length(vector.count))
        return normalized
    }

    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return Float.infinity }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        return 1.0 - dot
    }
}
