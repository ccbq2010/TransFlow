//
//  HotwordCorrectorTests.swift
//  TransFlowTests
//

import Testing
@testable import TransFlow

struct HotwordCorrectorTests {

    @Test @MainActor func emptyHotwordsReturnsTextUnchanged() {
        let corrector = HotwordCorrector(hotwords: [])
        #expect(corrector.correct("hello world") == "hello world")
    }

    @Test @MainActor func chineseSubstringReplacement() {
        // 标准 form "张三"，变体 "章三"
        let corrector = HotwordCorrector(hotwords: ["张三,章三"])
        #expect(corrector.correct("今天章三来开会") == "今天张三来开会")
    }

    @Test @MainActor func englishWordBoundaryReplacement() {
        // "OpenAI" 标准 form，变体 "openai" / "open ai"
        let corrector = HotwordCorrector(hotwords: ["OpenAI,openai,open ai"])
        #expect(corrector.correct("openai released a model") == "OpenAI released a model")
        #expect(corrector.correct("open ai released a model") == "OpenAI released a model")
    }

    @Test @MainActor func englishWordBoundaryDoesNotMatchPartial() {
        // "cat" 变体不应匹配 "category" 中的 "cat"
        let corrector = HotwordCorrector(hotwords: ["feline,cat"])
        #expect(corrector.correct("the category is broad") == "the category is broad")
        #expect(corrector.correct("the cat sat") == "the feline sat")
    }

    @Test @MainActor func caseInsensitiveEnglishMatch() {
        let corrector = HotwordCorrector(hotwords: ["OpenAI,openai"])
        #expect(corrector.correct("OPENAI is great") == "OpenAI is great")
    }

    @Test @MainActor func multipleHotwordsApplied() {
        let corrector = HotwordCorrector(hotwords: ["张三,章三", "OpenAI,openai"])
        let input = "章三 uses openai"
        let result = corrector.correct(input)
        #expect(result.contains("张三"))
        #expect(result.contains("OpenAI"))
    }

    @Test @MainActor func emptyVariantSkipped() {
        // 空行或仅逗号应被跳过
        let corrector = HotwordCorrector(hotwords: ["", ",", "有效,有笑"])
        #expect(corrector.correct("有笑") == "有效")
    }
}
