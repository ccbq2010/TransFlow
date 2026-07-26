import Testing
import Foundation
@testable import TransFlow

@MainActor
struct JSONLModelsTests {

    @Test func contentEntryWithSpeakerName() throws {
        let entry = JSONLContentEntry(
            startTime: "2026-07-26T10:00:00Z",
            endTime: "2026-07-26T10:00:05Z",
            originalText: "Hello world",
            translatedText: "你好世界",
            speakerId: "speaker_0",
            speakerName: "张三"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["speaker_id"] as? String == "speaker_0")
        #expect(json?["speaker_name"] as? String == "张三")
        #expect(json?["original_text"] as? String == "Hello world")
    }

    @Test func contentEntryWithoutSpeakerName() throws {
        let entry = JSONLContentEntry(
            startTime: "2026-07-26T10:00:00Z",
            endTime: "2026-07-26T10:00:05Z",
            originalText: "Hello",
            translatedText: nil,
            speakerId: nil
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["speaker_name"] == nil)
        #expect(json?["speaker_id"] == nil)
    }

    @Test func contentEntryDecodeWithSpeakerName() throws {
        let json = """
        {
            "type": "content",
            "start_time": "2026-07-26T10:00:00Z",
            "end_time": "2026-07-26T10:00:05Z",
            "original_text": "Test",
            "translated_text": null,
            "speaker_id": "speaker_1",
            "speaker_name": "李四"
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let entry = try decoder.decode(JSONLContentEntry.self, from: data)

        #expect(entry.speakerId == "speaker_1")
        #expect(entry.speakerName == "李四")
        #expect(entry.originalText == "Test")
    }

    @Test func contentEntryDecodeWithoutSpeakerName() throws {
        let json = """
        {
            "type": "content",
            "start_time": "2026-07-26T10:00:00Z",
            "end_time": "2026-07-26T10:00:05Z",
            "original_text": "Test",
            "translated_text": null,
            "speaker_id": null
        }
        """
        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let entry = try decoder.decode(JSONLContentEntry.self, from: data)

        #expect(entry.speakerId == nil)
        #expect(entry.speakerName == nil)
    }

    @Test func jsonlLineEncoding() throws {
        let entry = JSONLContentEntry(
            startTime: "2026-07-26T10:00:00Z",
            endTime: "2026-07-26T10:00:05Z",
            originalText: "Hello",
            translatedText: "Hi",
            speakerId: "speaker_0",
            speakerName: "Test"
        )
        let line = JSONLLine.content(entry)

        let encoder = JSONEncoder()
        let data = try encoder.encode(line)
        let decoded = try JSONDecoder().decode(JSONLLine.self, from: data)

        if case .content(let decodedEntry) = decoded {
            #expect(decodedEntry.speakerName == "Test")
            #expect(decodedEntry.speakerId == "speaker_0")
        } else {
            Issue.record("Expected content line")
        }
    }
}
