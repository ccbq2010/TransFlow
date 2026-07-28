import XCTest
@testable import TransFlow

/// WERCalculator 单元测试（快速、无模型依赖，随 verify-build.sh 一起跑）。
final class WERCalculatorTests: XCTestCase {

    // MARK: - Normalize

    func testNormalizeLowercasesAndStripsPunctuation() {
        let n = WERCalculator.normalize("Hello, World! It's 100% — done.")
        XCTAssertEqual(n, "hello world it s 100 done")
    }

    func testNormalizeKeepsChineseCharacters() {
        let n = WERCalculator.normalize("今天，天气真不错！对吧？")
        XCTAssertEqual(n, "今天 天气真不错 对吧")
    }

    func testNormalizeCollapsesWhitespace() {
        XCTAssertEqual(WERCalculator.normalize("  a   b  "), "a b")
    }

    // MARK: - Edit distance breakdown

    func testEditBreakdownPerfectMatch() {
        let b = WERCalculator.editBreakdown(reference: ["a", "b", "c"], hypothesis: ["a", "b", "c"])
        XCTAssertEqual(b, .init(substitutions: 0, insertions: 0, deletions: 0))
        XCTAssertEqual(b.total, 0)
    }

    func testEditBreakdownSubstitution() {
        let b = WERCalculator.editBreakdown(reference: ["a", "b", "c"], hypothesis: ["a", "x", "c"])
        XCTAssertEqual(b.substitutions, 1)
        XCTAssertEqual(b.insertions, 0)
        XCTAssertEqual(b.deletions, 0)
    }

    func testEditBreakdownInsertion() {
        // hyp 多了一个词 → insertion
        let b = WERCalculator.editBreakdown(reference: ["a", "c"], hypothesis: ["a", "b", "c"])
        XCTAssertEqual(b.insertions, 1)
        XCTAssertEqual(b.substitutions, 0)
        XCTAssertEqual(b.deletions, 0)
    }

    func testEditBreakdownDeletion() {
        // hyp 少了一个词 → deletion
        let b = WERCalculator.editBreakdown(reference: ["a", "b", "c"], hypothesis: ["a", "c"])
        XCTAssertEqual(b.deletions, 1)
        XCTAssertEqual(b.substitutions, 0)
        XCTAssertEqual(b.insertions, 0)
    }

    func testEditBreakdownEmptyReference() {
        let b = WERCalculator.editBreakdown(reference: [], hypothesis: ["a", "b"])
        XCTAssertEqual(b.insertions, 2)
        XCTAssertEqual(b.total, 2)
    }

    // MARK: - WER

    func testWERPerfectMatchIsZero() {
        let ref = "the quick brown fox"
        XCTAssertEqual(WERCalculator.wer(hypothesis: ref, reference: ref), 0.0)
    }

    func testWERSingleSubstitution() {
        // 4 词, 1 替换 → 0.25
        let wer = WERCalculator.wer(hypothesis: "the quick red fox", reference: "the quick brown fox")
        XCTAssertEqual(wer, 0.25, accuracy: 1e-9)
    }

    func testWERCaseInsensitive() {
        let wer = WERCalculator.wer(hypothesis: "THE QUICK BROWN FOX", reference: "the quick brown fox")
        XCTAssertEqual(wer, 0.0)
    }

    func testWERIgnoresPunctuation() {
        let wer = WERCalculator.wer(hypothesis: "the quick, brown fox!", reference: "the quick brown fox")
        XCTAssertEqual(wer, 0.0)
    }

    func testWEREmptyReferenceNonEmptyHypothesisIsOne() {
        XCTAssertEqual(WERCalculator.wer(hypothesis: "something", reference: ""), 1.0)
    }

    func testWERBothEmptyIsZero() {
        XCTAssertEqual(WERCalculator.wer(hypothesis: "", reference: ""), 0.0)
    }

    func testWERBreakdownCounts() {
        // ref: a b c d (4) ; hyp: a x c → b 替换, d 删除
        let (wer, breakdown, refCount) = WERCalculator.werBreakdown(hypothesis: "a x c", reference: "a b c d")
        XCTAssertEqual(refCount, 4)
        XCTAssertEqual(breakdown.substitutions, 1)
        XCTAssertEqual(breakdown.deletions, 1)
        XCTAssertEqual(wer, 0.5, accuracy: 1e-9) // 2 / 4
    }

    // MARK: - CER (Chinese)

    func testCERPerfectChineseMatch() {
        let ref = "今天天气真不错"
        XCTAssertEqual(WERCalculator.cer(hypothesis: ref, reference: ref), 0.0)
    }

    func testCERSingleCharSubstitution() {
        // 7 字, 1 替换 → 1/7
        let cer = WERCalculator.cer(hypothesis: "今天天气真不差", reference: "今天天气真不错")
        XCTAssertEqual(cer, 1.0 / 7.0, accuracy: 1e-9)
    }

    func testCERIgnoresChinesePunctuation() {
        let cer = WERCalculator.cer(hypothesis: "今天，天气真不错！", reference: "今天天气真不错")
        XCTAssertEqual(cer, 0.0)
    }

    func testCERDeletion() {
        // ref 7 字, hyp 少 1 字 → 1/7
        let cer = WERCalculator.cer(hypothesis: "今天天气不错", reference: "今天天气真不错")
        XCTAssertEqual(cer, 1.0 / 7.0, accuracy: 1e-9)
    }

    // MARK: - Format helper

    func testFormatPercent() {
        XCTAssertEqual(WERCalculator.format(percent: 0.1234), "12.3%")
        XCTAssertEqual(WERCalculator.format(percent: 0.0), "0.0%")
        XCTAssertEqual(WERCalculator.format(percent: 1.0), "100.0%")
    }
}
