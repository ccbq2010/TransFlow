import Testing
import Foundation
@testable import TransFlow

@MainActor
struct SpeakerProfilesStoreTests {

    // MARK: - SpeakerDisplayName

    @Test func displayNameForAnonymousSpeaker0() {
        let name = SpeakerDisplayName.displayName(for: "speaker_0")
        #expect(name.contains("1"))
    }

    @Test func displayNameForAnonymousSpeaker1() {
        let name = SpeakerDisplayName.displayName(for: "speaker_1")
        #expect(name.contains("2"))
    }

    @Test func displayNameForCustomName() {
        let name = SpeakerDisplayName.displayName(for: "张三")
        #expect(name == "张三")
    }

    @Test func displayNameForSpeakerWithSpace() {
        let name = SpeakerDisplayName.displayName(for: "speaker 0")
        #expect(name.contains("1"))
    }

    @Test func displayNameCaseInsensitive() {
        let name = SpeakerDisplayName.displayName(for: "SPEAKER_2")
        #expect(name.contains("3"))
    }

    // MARK: - SpeakerColor

    @Test func colorForSpeakerIsValidHex() {
        let color = SpeakerColor.color(for: "speaker_0")
        #expect(color.hasPrefix("#"))
        #expect(color.count == 7)
    }

    @Test func colorConsistentForSameSpeaker() {
        let color1 = SpeakerColor.color(for: "speaker_0")
        let color2 = SpeakerColor.color(for: "speaker_0")
        #expect(color1 == color2)
    }

    @Test func colorPaletteNotEmpty() {
        #expect(!SpeakerColor.palette.isEmpty)
    }

    // MARK: - SpeakerProfile

    @Test func profileCreation() {
        let profile = SpeakerProfile(name: "Test", embedding: [Float](repeating: 0.5, count: 256))
        #expect(profile.name == "Test")
        #expect(profile.embedding.count == 256)
        #expect(profile.id.isEmpty == false)
    }

    @Test func profileEquality() {
        let p1 = SpeakerProfile(name: "A", embedding: [1.0])
        let p2 = SpeakerProfile(name: "A", embedding: [1.0])
        // Different IDs, so not equal
        #expect(p1 != p2)
    }

    // MARK: - SpeakerNameMapping

    @Test func nameMappingCreation() {
        let mapping = SpeakerNameMapping(anonymousId: "speaker_0", name: "张三")
        #expect(mapping.anonymousId == "speaker_0")
        #expect(mapping.name == "张三")
    }
}
