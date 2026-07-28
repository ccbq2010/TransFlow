# TransFlow Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复项目全面 review 中发现的 P0（阻断级）与高优先级低风险问题，提升发布可信度、测试基线、国际化与可访问性。

**Architecture:** 纯文档修正 + 配置修正 + 纯函数单元测试 + 局部 UI 修正。不涉及架构重构（God Method 拆分、Store 合并、数据竞争修复等留作后续 plan）。

**Tech Stack:** Swift 6.0 / SwiftUI / Swift Testing (`@Test` / `#expect`) / Xcode 26 / macOS 26.0 deployment target

---

## 范围说明

本计划仅覆盖**低风险、高收益**的修复项。以下高风险项**不在本计划范围内**，需单独 plan：
- 拆分 `TransFlowViewModel.startListening()` God Method
- 合并 `JSONLStore` / `VideoJSONLStore`
- 修复 `GlobalHotkeyManager.cachedBindings` 数据竞争
- 拆分 `SettingsView.swift` / `HistoryView.swift`
- CI/CD 搭建
- Dynamic Type 支持

---

## File Structure

| 文件 | 操作 | 职责 |
|---|---|---|
| `README.md` | 修改 | 修正部署目标信息 |
| `README_EN.md` | 修改 | 修正部署目标信息 |
| `release-notes/*.md` | 修改 | 修正部署目标信息 |
| `.gitignore` | 修改 | 取消忽略 `Package.resolved` |
| `TransFlow/TransFlowTests/TransFlowTests.swift` | 修改 | 删除空占位测试 |
| `TransFlow/TransFlowTests/HotwordCorrectorTests.swift` | 新建 | HotwordCorrector 单测 |
| `TransFlow/TransFlowTests/VADServiceTests.swift` | 新建 | VADService 单测 |
| `TransFlow/TransFlowTests/SRTExporterTests.swift` | 新建 | SRTExporter 单测 |
| `TransFlow/TransFlow/Services/ErrorLogger.swift` | 修改 | 修正 `log()` 默认级别 |
| `TransFlow/TransFlow/Views/VideoTranscriptionView.swift` | 修改 | 修正硬编码语言名 |
| `TransFlow/TransFlow/Localizable.xcstrings` | 修改 | 新增 i18n key |
| `TransFlow/TransFlow/Views/AudioPlayerBarView.swift` | 修改 | 补 accessibilityLabel |
| `TransFlow/TransFlow/Views/MediaPlayerBarView.swift` | 修改 | 补 accessibilityLabel |
| `TransFlow/TransFlow/Views/TranscriptionView.swift` | 修改 | 补 accessibilityLabel |
| `.cursor/rules/global-rules.mdc` | 修改 | 清理过时 DMG 引用 |
| `.cursor/skills/build-dmg/SKILL.md` | 删除 | 过时 DMG skill |

---

## Task 1: 修正 README 部署目标信息

**Files:**
- Modify: `README.md:8,60`
- Modify: `README_EN.md:8,60`

- [ ] **Step 1: 修正 README.md 平台徽章**

将 `README.md:8` 的平台徽章从 `macOS%2015.0+` 改为 `macOS%2026.0+`：

```
[![Platform](https://img.shields.io/badge/platform-macOS%2026.0+-blue?style=flat-square&logo=apple)](https://github.com/Cyronlee/TransFlow)
```

- [ ] **Step 2: 修正 README.md 系统要求**

将 `README.md:60` 的系统要求从 `macOS 15.0 (Sequoia) 或更高版本` 改为：

```
- macOS 26.0 (Tahoe) 或更高版本
```

- [ ] **Step 3: 修正 README_EN.md 平台徽章与系统要求**

对 `README_EN.md` 做同样修改：平台徽章 `macOS%2015.0+` → `macOS%2026.0+`，系统要求 `macOS 15.0 (Sequoia) or later` → `macOS 26.0 (Tahoe) or later`。

- [ ] **Step 4: Commit**

```bash
git add README.md README_EN.md
git commit -m "docs: fix deployment target from 15.0 to 26.0 in READMEs"
```

---

## Task 2: 修正 release-notes 部署目标信息

**Files:**
- Modify: `release-notes/v1.0.0.md` ~ `release-notes/v1.6.2.md`

- [ ] **Step 1: 批量替换 release-notes 中的系统要求**

所有 `release-notes/*.md` 文件中出现的 `macOS 15.0 or later` / `macOS 15.0 或更高版本` 统一改为 `macOS 26.0 or later`（release-notes 为英文）。

- [ ] **Step 2: 验证替换结果**

Run: `grep -rn "15.0" release-notes/`
Expected: 无输出（无残留 15.0 引用）

- [ ] **Step 3: Commit**

```bash
git add release-notes/
git commit -m "docs: align release-notes system requirement to macOS 26.0"
```

---

## Task 3: 锁定 Package.resolved

**Files:**
- Modify: `.gitignore:25-26`

- [ ] **Step 1: 从 .gitignore 移除 Package.resolved 忽略规则**

删除 `.gitignore` 中的以下两行：
```
Package.resolved
*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
```

注意：保留 `.build/` 和 `Packages/` 忽略。

- [ ] **Step 2: 验证 Package.resolved 不再被忽略**

Run: `git check-ignore TransFlow/TransFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Expected: 无输出（表示未被忽略）

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "build: track Package.resolved for reproducible builds"
```

---

## Task 4: 删除空占位测试

**Files:**
- Modify: `TransFlow/TransFlowTests/TransFlowTests.swift`

- [ ] **Step 1: 删除 example() 占位测试**

将 `TransFlowTests.swift` 内容替换为（保留文件结构与 import，供后续扩展）：

```swift
//
//  TransFlowTests.swift
//  TransFlowTests
//
//  Created by Siyuan Li on 2026/2/6.
//

import Testing
@testable import TransFlow

struct TransFlowTests {
    // 通用测试入口。具体测试按模块拆分到独立的 *Tests.swift 文件。
}
```

- [ ] **Step 2: Commit**

```bash
git add TransFlow/TransFlowTests/TransFlowTests.swift
git commit -m "test: remove empty placeholder test"
```

---

## Task 5: 修正 ErrorLogger 默认级别

**Files:**
- Modify: `TransFlow/TransFlow/Services/ErrorLogger.swift:64-67`

- [ ] **Step 1: 修正 log() 默认级别为 .info**

将 `ErrorLogger.swift:64-67` 的 `log()` 方法从 `.error` 改为 `.info`：

```swift
    /// Generic entry point — logs at info level.
    /// Use `error()` / `warning()` / `info()` for explicit severity.
    func log(_ message: String, source: String, file: String = #fileID, line: Int = #line) {
        write(message, level: .info, source: source, file: file, line: line)
    }
```

理由：`log()` 是通用/遗留入口，调用方多用其记录一般消息；真正错误应使用显式的 `error()`。此修正消除日志级别污染。

- [ ] **Step 2: Commit**

```bash
git add TransFlow/TransFlow/Services/ErrorLogger.swift
git commit -m "fix: ErrorLogger.log() defaults to info instead of error"
```

---

## Task 6: 新增 HotwordCorrector 单元测试

**Files:**
- Create: `TransFlow/TransFlowTests/HotwordCorrectorTests.swift`

- [ ] **Step 1: 编写 HotwordCorrectorTests.swift**

```swift
//
//  HotwordCorrectorTests.swift
//  TransFlowTests
//

import Testing
@testable import TransFlow

struct HotwordCorrectorTests {

    @Test func emptyHotwordsReturnsTextUnchanged() {
        let corrector = HotwordCorrector(hotwords: [])
        #expect(corrector.correct("hello world") == "hello world")
    }

    @Test func chineseSubstringReplacement() {
        // 标准 form "张三"，变体 "章三"
        let corrector = HotwordCorrector(hotwords: ["张三,章三"])
        #expect(corrector.correct("今天章三来开会") == "今天张三来开会")
    }

    @Test func englishWordBoundaryReplacement() {
        // "OpenAI" 标准 form，变体 "openai" / "open ai"
        let corrector = HotwordCorrector(hotwords: ["OpenAI,openai,open ai"])
        #expect(corrector.correct("openai released a model") == "OpenAI released a model")
        #expect(corrector.correct("open ai released a model") == "OpenAI released a model")
    }

    @Test func englishWordBoundaryDoesNotMatchPartial() {
        // "cat" 变体不应匹配 "category" 中的 "cat"
        let corrector = HotwordCorrector(hotwords: ["feline,cat"])
        #expect(corrector.correct("the category is broad") == "the category is broad")
        #expect(corrector.correct("the cat sat") == "the feline sat")
    }

    @Test func caseInsensitiveEnglishMatch() {
        let corrector = HotwordCorrector(hotwords: ["OpenAI,openai"])
        #expect(corrector.correct("OPENAI is great") == "OpenAI is great")
    }

    @Test func multipleHotwordsApplied() {
        let corrector = HotwordCorrector(hotwords: ["张三,章三", "OpenAI,openai"])
        let input = "章三 uses openai"
        let result = corrector.correct(input)
        #expect(result.contains("张三"))
        #expect(result.contains("OpenAI"))
    }

    @Test func emptyVariantSkipped() {
        // 空行或仅逗号应被跳过
        let corrector = HotwordCorrector(hotwords: ["", ",", "有效,有笑"])
        #expect(corrector.correct("有笑") == "有效")
    }
}
```

- [ ] **Step 2: 运行测试验证通过**

Run: `xcodebuild test -scheme TransFlow -destination 'platform=macOS' -only-testing:TransFlowTests/HotwordCorrectorTests`
Expected: 所有 7 个测试通过

- [ ] **Step 3: Commit**

```bash
git add TransFlow/TransFlowTests/HotwordCorrectorTests.swift
git commit -m "test: add HotwordCorrector unit tests"
```

---

## Task 7: 新增 VADService 单元测试

**Files:**
- Create: `TransFlow/TransFlowTests/VADServiceTests.swift`

- [ ] **Step 1: 编写 VADServiceTests.swift**

```swift
//
//  VADServiceTests.swift
//  TransFlowTests
//

import Testing
@testable import TransFlow

struct VADServiceTests {

    @Test func emptySamplesReturnsNoSegments() {
        let vad = VADService()
        #expect(vad.detectSpeechSegments([]).isEmpty)
    }

    @Test func pureSilenceReturnsNoSegments() {
        let vad = VADService(silenceThreshold: 0.01, sampleRate: 16000)
        // 1 秒静音（全零）
        let silence = [Float](repeating: 0.0, count: 16000)
        #expect(vad.detectSpeechSegments(silence).isEmpty)
    }

    @Test func continuousSpeechDetectedAsSingleSegment() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 1 秒持续语音：正弦波幅值 0.1（远超阈值 0.01）
        let speech = (0..<16000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let segments = vad.detectSpeechSegments(speech)
        #expect(segments.count == 1)
        // 段应覆盖大部分样本
        let seg = segments[0]
        #expect(seg.upperBound - seg.lowerBound > 8000)
    }

    @Test func silenceBetweenSpeechProducesTwoSegments() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 0.5s 语音 + 1s 静音 + 0.5s 语音
        let speechPart = (0..<8000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = speechPart + silence + speechPart
        let segments = vad.detectSpeechSegments(samples)
        #expect(segments.count == 2)
    }

    @Test func extractSpeechRemovesSilence() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        let speechPart = (0..<8000).map { i in
            Float(0.1 * sin(2.0 * .pi * 440.0 * Double(i) / 16000.0))
        }
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = speechPart + silence + speechPart
        let extracted = vad.extractSpeech(samples)
        // 提取后应短于原始（静音被移除），且非空
        #expect(!extracted.isEmpty)
        #expect(extracted.count < samples.count)
    }

    @Test func shortNoiseBurstFiltered() {
        let vad = VADService(
            silenceThreshold: 0.01,
            minSpeechDuration: 0.3,  // 要求至少 0.3s
            minSilenceDuration: 0.5,
            sampleRate: 16000
        )
        // 0.1s 短噪声（低于 minSpeechDuration）+ 静音
        let noise = [Float](repeating: 0.5, count: 1600)  // 0.1s
        let silence = [Float](repeating: 0.0, count: 16000)
        let samples = noise + silence
        #expect(vad.detectSpeechSegments(samples).isEmpty)
    }
}
```

- [ ] **Step 2: 运行测试验证通过**

Run: `xcodebuild test -scheme TransFlow -destination 'platform=macOS' -only-testing:TransFlowTests/VADServiceTests`
Expected: 所有 6 个测试通过

- [ ] **Step 3: Commit**

```bash
git add TransFlow/TransFlowTests/VADServiceTests.swift
git commit -m "test: add VADService unit tests"
```

---

## Task 8: 新增 SRTExporter 单元测试

**Files:**
- Create: `TransFlow/TransFlowTests/SRTExporterTests.swift`

- [ ] **Step 1: 编写 SRTExporterTests.swift**

```swift
//
//  SRTExporterTests.swift
//  TransFlowTests
//

import Testing
import Foundation
@testable import TransFlow

struct SRTExporterTests {

    @Test func emptySentencesReturnsEmptyString() {
        #expect(SRTExporter.generateSRT(from: []) == "")
    }

    @Test func singleSentenceHasCorrectSequenceAndTimestamp() {
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

    @Test func multipleSentencesUseRelativeOffsets() {
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

    @Test func translationAppendedWhenPresent() {
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

    @Test func srtTimeFormatCorrect() {
        let base = Date(timeIntervalSince1970: 1000)
        // 1h 2m 3.5s 偏移
        let sentence = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base.addingTimeInterval(3723.5),
            text: "test"
        )
        let srt = SRTExporter.generateSRT(from: [sentence])
        // 3723.5s = 01:02:03,500
        #expect(srt.contains("01:02:03,500"))
    }

    @Test func lastSentenceEndsThreeSecondsAfterStart() {
        let base = Date(timeIntervalSince1970: 1000)
        let sentence = TranscriptionSentence(
            startTimestamp: base,
            timestamp: base.addingTimeInterval(10),
            text: "last"
        )
        let srt = SRTExporter.generateSRT(from: [sentence])
        // 末句 end = start + 3s = 13s
        #expect(srt.contains("00:00:10,000 --> 00:00:13,000"))
    }
}
```

- [ ] **Step 2: 运行测试验证通过**

Run: `xcodebuild test -scheme TransFlow -destination 'platform=macOS' -only-testing:TransFlowTests/SRTExporterTests`
Expected: 所有 6 个测试通过

- [ ] **Step 3: Commit**

```bash
git add TransFlow/TransFlowTests/SRTExporterTests.swift
git commit -m "test: add SRTExporter unit tests"
```

---

## Task 9: 修正 VideoTranscriptionView 硬编码语言名

**Files:**
- Modify: `TransFlow/TransFlow/Views/VideoTranscriptionView.swift:263-268`
- Modify: `TransFlow/TransFlow/Localizable.xcstrings`

- [ ] **Step 1: 用 Locale 动态生成语言名替换硬编码 Text**

将 `VideoTranscriptionView.swift:263-268` 的 Picker 内容替换为使用 `Locale.current.localizedString(forIdentifier:)` 动态生成：

```swift
                        Picker("", selection: $viewModel.targetLanguage) {
                            Text(languageDisplayName("zh-Hans")).tag(Locale.Language(identifier: "zh-Hans"))
                            Text(languageDisplayName("en")).tag(Locale.Language(identifier: "en"))
                            Text(languageDisplayName("ja")).tag(Locale.Language(identifier: "ja"))
                            Text(languageDisplayName("ko")).tag(Locale.Language(identifier: "ko"))
                        }
```

- [ ] **Step 2: 在 VideoTranscriptionView 中添加 languageDisplayName 辅助方法**

在 `VideoTranscriptionView` 结构体内添加私有辅助方法（使用系统本地化，无需 String Catalog key，因为语言名本身由系统提供）：

```swift
    /// 返回语言标识在当前系统语言下的本地化显示名。
    private func languageDisplayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
```

- [ ] **Step 3: 从 Localizable.xcstrings 清理自动提取的空 key**

删除 xcstrings 中以下无翻译的自动提取 key（若存在）：
- `"中文 (简体)"`
- `"English"`
- `"日本語"`
- `"한국어"`

- [ ] **Step 4: Commit**

```bash
git add TransFlow/TransFlow/Views/VideoTranscriptionView.swift TransFlow/TransFlow/Localizable.xcstrings
git commit -m "i18n: use Locale display names for target language picker"
```

---

## Task 10: 补充图标按钮 accessibilityLabel

**Files:**
- Modify: `TransFlow/TransFlow/Views/AudioPlayerBarView.swift`
- Modify: `TransFlow/TransFlow/Views/MediaPlayerBarView.swift`
- Modify: `TransFlow/TransFlow/Views/TranscriptionView.swift`

- [ ] **Step 1: AudioPlayerBarView 补 accessibilityLabel**

在 `AudioPlayerBarView.swift` 的播放/暂停按钮（第 10-21 行）添加 `.accessibilityLabel`，停止按钮（第 24-35 行）添加 `.accessibilityLabel`：

播放/暂停按钮在 `.buttonStyle(.plain)` 后追加：
```swift
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
```

停止按钮在 `.buttonStyle(.plain)` 后追加：
```swift
                .accessibilityLabel("停止")
```

- [ ] **Step 2: MediaPlayerBarView 补 accessibilityLabel**

在 `MediaPlayerBarView.swift` 的播放/暂停按钮（第 16-27 行）`.buttonStyle(.plain)` 后追加：

```swift
            .accessibilityLabel(isPlaying ? "暂停" : "播放")
```

- [ ] **Step 3: TranscriptionView 自动滚动按钮补 accessibilityLabel**

读取 `TranscriptionView.swift:44-57` 的自动滚动切换按钮，在其修饰符链添加 `.accessibilityLabel`：

```swift
                .accessibilityLabel("自动滚动")
```

- [ ] **Step 4: Commit**

```bash
git add TransFlow/TransFlow/Views/AudioPlayerBarView.swift TransFlow/TransFlow/Views/MediaPlayerBarView.swift TransFlow/TransFlow/Views/TranscriptionView.swift
git commit -m "a11y: add accessibilityLabel to icon-only playback buttons"
```

---

## Task 11: 清理过时 DMG 文档

**Files:**
- Modify: `.cursor/rules/global-rules.mdc:12-13`
- Delete: `.cursor/skills/build-dmg/SKILL.md`

- [ ] **Step 1: 修正 global-rules.mdc 的 DMG 引用**

将 `.cursor/rules/global-rules.mdc:12-13` 的 DMG 打包段落：

```
## DMG 打包
- 使用 `build-dmg` skill 打包 DMG（`./scripts/build-dmg.sh`）
```

替换为 PKG 发布段落（与 AGENTS.md 一致）：

```
## PKG 发布
- 仅使用 `./scripts/build-pkg.sh` 生成安装包，发布流程统一为 PKG-only
- 发布 GitHub Release 时只上传经过 Developer ID 签名、notarization 和 stapling 的 PKG
```

- [ ] **Step 2: 删除过时的 build-dmg skill 目录**

删除 `.cursor/skills/build-dmg/SKILL.md` 文件（该 skill 引用的 `./scripts/build-dmg.sh` 已不在仓库中）。

- [ ] **Step 3: Commit**

```bash
git add .cursor/rules/global-rules.mdc
git rm .cursor/skills/build-dmg/SKILL.md
git commit -m "docs: remove obsolete DMG packaging references"
```

---

## Task 12: 构建验证

**Files:** 无（仅验证）

- [ ] **Step 1: 运行 xcodebuild 验证编译**

Run: `xcodebuild build -scheme TransFlow -destination 'platform=macOS' -configuration Debug`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: 运行全部测试**

Run: `xcodebuild test -scheme TransFlow -destination 'platform=macOS'`
Expected: 所有测试通过（含新增的 HotwordCorrector / VADService / SRTExporter 测试）

- [ ] **Step 3: 若构建/测试失败，修复后重新提交**

如遇编译错误或测试失败，定位问题并修复，直至 BUILD SUCCEEDED 且全部测试通过。

---

## Self-Review

**1. Spec coverage:** 本计划覆盖 review 中的 P0 项（部署目标文档、Package.resolved 锁定）与高优先级低风险项（占位测试清理、ErrorLogger 级别、纯函数单测、i18n 硬编码、a11y、过时文档）。未覆盖项已在"范围说明"中明确列出。

**2. Placeholder scan:** 所有步骤均含具体代码或具体命令，无 TBD/TODO。

**3. Type consistency:** `languageDisplayName(_:)` 在 Task 9 Step 1 调用与 Step 2 定义一致；`TranscriptionSentence` 初始化签名与 `TranscriptionModels.swift` 一致；`VADService` 初始化参数与源文件一致。
