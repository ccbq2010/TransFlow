import Testing
import Foundation
@testable import TransFlow

@MainActor
struct QuestionDetectorTests {

    // MARK: - English Questions

    @Test func questionMarkDetected() {
        #expect(QuestionDetector.containsQuestion("What is the timeline?"))
    }

    @Test func chineseQuestionMarkDetected() {
        #expect(QuestionDetector.containsQuestion("这个方案怎么样？"))
    }

    @Test func whatPrefixDetected() {
        #expect(QuestionDetector.containsQuestion("what time is the meeting"))
    }

    @Test func howPrefixDetected() {
        #expect(QuestionDetector.containsQuestion("how do we proceed"))
    }

    @Test func whyPrefixDetected() {
        #expect(QuestionDetector.containsQuestion("why was this decision made"))
    }

    @Test func couldYouDetected() {
        #expect(QuestionDetector.containsQuestion("could you clarify that"))
    }

    @Test func isQuestionDetected() {
        #expect(QuestionDetector.containsQuestion("is this the right approach"))
    }

    // MARK: - Chinese Questions

    @Test func chineseShenmeDetected() {
        #expect(QuestionDetector.containsQuestion("这个项目的目标是什么"))
    }

    @Test func chineseZenmeDetected() {
        #expect(QuestionDetector.containsQuestion("怎么解决这个问题"))
    }

    @Test func chineseWeishenmeDetected() {
        #expect(QuestionDetector.containsQuestion("为什么选择这个方案"))
    }

    @Test func chineseMaParticleDetected() {
        #expect(QuestionDetector.containsQuestion("这样可以吗"))
    }

    @Test func chineseNeParticleDetected() {
        #expect(QuestionDetector.containsQuestion("那我们怎么办呢"))
    }

    // MARK: - Non-Questions

    @Test func statementNotDetected() {
        #expect(!QuestionDetector.containsQuestion("This is a normal statement."))
    }

    @Test func emptyStringNotDetected() {
        #expect(!QuestionDetector.containsQuestion(""))
    }

    @Test func tooShortNotDetected() {
        #expect(!QuestionDetector.containsQuestion("hi"))
    }

    @Test func commandNotDetected() {
        #expect(!QuestionDetector.containsQuestion("Please send the report."))
    }

    @Test func chineseStatementNotDetected() {
        #expect(!QuestionDetector.containsQuestion("今天的会议很顺利。"))
    }

    // MARK: - Extract Latest Question

    @Test func extractLatestFromMultipleSentences() {
        let text = "We discussed the budget. What is the next step?"
        #expect(QuestionDetector.extractLatestQuestion(from: text) == "What is the next step?")
    }

    @Test func extractLatestReturnsLastQuestion() {
        let text = "How are things? What is the deadline?"
        #expect(QuestionDetector.extractLatestQuestion(from: text) == "What is the deadline?")
    }

    @Test func extractLatestReturnsNilForNoQuestion() {
        let text = "Everything is going well. No issues found."
        #expect(QuestionDetector.extractLatestQuestion(from: text) == nil)
    }

    @Test func extractLatestChinese() {
        let text = "项目进展顺利。下一步怎么做？"
        let result = QuestionDetector.extractLatestQuestion(from: text)
        #expect(result != nil)
        #expect(result?.contains("怎么做") == true)
    }
}
