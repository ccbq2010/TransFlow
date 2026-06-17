//
//  SRTExporterTests.swift
//  TransFlowTests
//

import Testing
import Foundation
@testable import TransFlow

struct SRTExporterTests {

    @Test @MainActor func emptySentencesReturnsEmptyString() {
        #expect(SRTExporter.generateSRT(from: []) == "")
    }

    @Test @MainActor func singleSentenceHasCorrectSequenceAndTimestamp() {
        let base = Date(timeIntervalSince1970: 1000)
        let sentence = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base,
            text: "Hello world"
        )
        let srt = SRTExporter.generateSRT(from: [sentence])
        // 第一行序号
        #expect(srt.hasPrefix("1\n"))
        // 起始时间戳从 0 开始（相对 baseTime）
        #expect(srt.contains("00:00:00,000 --> 00:00:03,000"))
        // 文本存在
        #expect(srt.contains("Hello world"))
    }

    @Test @MainActor func multipleSentencesUseRelativeOffsets() {
        let base = Date(timeIntervalSince1970: 1000)
        let s1 = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base,
            text: "First"
        )
        let s2 = TranscriptionSentence(
            startTimestamp: base.addingTimeInterval(2),
            timestamp: base.addingTimeInterval(2),
            text: "Second"
        )
        let s3 = TranscriptionSentence(
            startTimestamp: base.addingTimeInterval(5),
            timestamp: base.addingTimeInterval(5),
            text: "Third"
        )
        let srt = SRTExporter.generateSRT(from: [s1, s2, s3])
        // 三个序号
        #expect(srt.components(separatedBy: "\n1\n").count >= 1)
        #expect(srt.contains("\n2\n"))
        #expect(srt.contains("\n3\n"))
        // 第二句起始 = 2s
        #expect(srt.contains("00:00:02,000"))
        // 第三句起始 = 5s
        #expect(srt.contains("00:00:05,000"))
    }

    @Test @MainActor func translationAppendedWhenPresent() {
        let base = Date(timeIntervalSince1970: 1000)
        let sentence = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base,
            text: "Hello",
            translation: "你好"
        )
        let srt = SRTExporter.generateSRT(from: [sentence])
        #expect(srt.contains("Hello"))
        #expect(srt.contains("你好"))
    }

    @Test @MainActor func srtTimeFormatCorrect() {
        let base = Date(timeIntervalSince1970: 1000)
        // 需要两句：第一句建立 baseTime=0，第二句偏移 3723.5s
        let s1 = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base,
            text: "first"
        )
        let s2 = TranscriptionSentence(
            startTimestamp: base.addingTimeInterval(3723.5),
            timestamp: base.addingTimeInterval(3723.5),
            text: "test"
        )
        let srt = SRTExporter.generateSRT(from: [s1, s2])
        // 3723.5s = 01:02:03,500
        #expect(srt.contains("01:02:03,500"))
    }

    @Test @MainActor func lastSentenceEndsThreeSecondsAfterStart() {
        let base = Date(timeIntervalSince1970: 1000)
        // 需要两句：第一句 baseTime=0，第二句 start=10s
        let s1 = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base,
            text: "first"
        )
        let s2 = TranscriptionSentence(
            startTimestamp: base.addingTimeInterval(10),
            timestamp: base.addingTimeInterval(10),
            text: "last"
        )
        let srt = SRTExporter.generateSRT(from: [s1, s2])
        // 末句 end = start + 3s = 13s
        #expect(srt.contains("00:00:10,000 --> 00:00:13,000"))
    }
}
