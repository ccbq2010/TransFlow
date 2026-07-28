# TransFlow 项目代码审查 — 跟进报告（第二轮）

**日期**: 2026-07-27（第二次） | **基于**: [第一轮审查](./code-review-2026-07-27.md) | **提交**: `7c729ff` + 未提交更改

---

## 修复进展总览

| 级别 | 第一轮 | 已修复 | 部分修复 | 未修复 | 新增 |
|------|--------|--------|----------|--------|------|
| P1  | 3      | 3 ✅   | 0        | 0      | 0    |
| P2  | 7      | 2      | 1        | 4      | 0    |
| P3  | 8      | 1      | 0        | 7      | 1    |

**整体评价**: 所有 P1 严重问题已修复 ✅。P2/P3 只修复了几个关键项，大部分 P2 和 P3 问题仍需继续处理。

---

## P1 — 已全部修复 ✅

### P1-1: KnowledgeBase 中文分词 ✅ 已修复

**变更**: 新增 `countUnits()` 方法（KnowledgeStore.swift:163-175），通过 Unicode 范围检测 CJK 字符，将 `split(separator: " ")` 替换为基于字符数的计数。`maxWords` 重命名为 `maxUnits`。

```swift
// 修复后
private func countUnits(_ text: String) -> Int {
    let cjkChars = text.unicodeScalars.filter {
        (0x4E00...0x9FFF).contains($0.value) ||  // CJK Unified
        (0x3400...0x4DBF).contains($0.value) ||  // CJK Extension A
        (0x3040...0x309F).contains($0.value) ||  // Hiragana
        (0x30A0...0x30FF).contains($0.value)     // Katakana
    }.count
    if cjkChars > text.count / 2 {
        return text.count  // CJK: ~1 char ≈ 1 token
    }
    return text.split(separator: " ").count
}
```

**质量评价**: ✅ 良好。正确覆盖了日文假名（Hiragana/Katakana）场景。CJK 判定阈值 `> 50%` 合理。建议后续考虑添加韩文（Hangul）范围 `0xAC00-0xD7AF`。

---

### P1-2: MeetingSummarizer Token 截断 ✅ 已修复

**变更**: 新增 `estimateTokens()`（MeetingSummarizer.swift:131-136）和 `truncateTranscript()`（第 139-160 行），使用 4000 token 预算，保留头部 30% 和尾部 70% 的行。

```swift
// 修复后
private func truncateTranscript(_ transcript: String) -> String {
    let budget = 4000
    if estimateTokens(transcript) <= budget { return transcript }
    // 保留 head (30%) + tail (70%), 省略中间
    let headCount = max(keepCount * 3 / 10, 10)
    let tailCount = max(keepCount - headCount, 10)
    // ...
}
```

**质量评价**: ✅ 良好。截断算法合理保留了 context（头部会议开始）和重要内容（尾部会议结论）。建议在 summary 输出末尾添加提示如 `*(Note: very long transcript was truncated)*`。

---

### P1-3: VideoTranscription 路径泄露 ✅ 已修复

**变更**: `VideoTranscriptionViewModel.swift:226` 移除了 `originalFilePath` 参数传递，现在只传 `videoFile: fileURL.lastPathComponent`。`VideoJSONLMetadata` 模型保留 `originalFilePath` 字段但标记为 `String?`（可选），默认 `nil`，保证旧 JSONL 文件向后兼容。

**质量评价**: ✅ 良好。向后兼容策略正确。旧数据中的路径不会被清除，但新数据不再写入。

---

## P2 — 仍需修复（4 项未修复 + 1 项部分修复）

### ~~P2-5: backfillSpeakerIds O(n×m)~~ ✅ 已修复

**变更**: `TransFlowViewModel.swift:713-714`，新增 `maxBackfill = 50`，只回溯最近 50 句未分配的句子。

**代码**:
```swift
// 修复后
let maxBackfill = 50
let startIndex = max(0, sentences.count - maxBackfill)
for i in startIndex..<sentences.count where sentences[i].speakerId == nil {
```

**质量评价**: ✅ 修复有效。但 `rewriteJSONLWithCurrentSentences()` 仍每次全量重写，建议后续添加 debounce。

---

### ~~P2-4 (部分): KnowledgeStore 保存错误日志~~ 🔶 部分修复

**变更**: `KnowledgeStore.saveDocuments()`（第 66-77 行）和 `saveChunks()`（第 79-90 行）已将 `try?` 替换为 `do-catch` + `ErrorLogger.shared.error()`。

**未修复**: `SpeakerProfilesStore.save()`（第 50-53 行）仍使用静默 `try?`，无错误日志。`JSONLStore.createSession()`（第 53 行）也有同样问题。

**建议**: 继续以同样模式修复剩余位置。

---

### P2-1: NLEmbedding.retrieveTopK 阻塞 @MainActor ❌ 未修复

**当前状态**: `AnswerSuggestionViewModel.generateSuggestion()`（第 54-68 行）仍在 `Task { @MainActor in ... }` 中调用 `knowledgeStore.retrieveTopK()`，该方法标记为 `@MainActor` 且在 `retrieveTopK()` 中遍历所有 chunks 执行 `NLEmbedding.distance()`。

**建议**: 将 `retrieveTopK` 改为 `nonisolated` 方法，或在 `generateSuggestion` 中使用 `Task.detached`。

---

### P2-2: JSONLStore FileHandle 每次打开/关闭 ❌ 未修复

**当前状态**: `appendRaw()`（第 343-350 行）仍每次创建 FileHandle。

**建议**: 在 `createSession` 时打开 FileHandle 并保持引用，`closeSession` 时关闭。

---

### P2-3: WhisperKit nonisolated(unsafe) ❌ 未修复

**当前状态**: `WhisperKitSpeechEngine.swift:93` 仍使用 `nonisolated(unsafe) let capturedWhisperKit = whisperKit`。

**建议**: 如第一轮建议，使用 actor 包装 WhisperKit 访问。

---

### P2-6: 音频 Buffer Policy 不一致 ❌ 未修复

**当前状态**: `TransFlowViewModel.swift:369-380` 仍全部使用 `.bufferingNewest`。

**建议**: engine/diarization 改用 `.bufferingOldest` 避免丢帧。

---

### P2-7: TranslationService resumeSession force=false ❌ 未修复

**当前状态**: `TranslationService.swift:232`，`resumeSession()` 仍调用 `updateConfiguration()` 不带 `force: true`。

**建议**: 改为 `updateConfiguration(force: true)`。

---

## P3 — 仍需修复（7 项未修复）

### ~~P3-1: QuestionDetector 中文误报~~ ✅ 已修复

**变更**: `QuestionDetector.swift:62-74`，不再全文匹配 `chineseKeywords`，改为仅检查前 10 个字符（`String(text.prefix(10))`）。句末语气词（`吗`、`呢`、`吧`）保持原有逻辑不变。

```swift
// 修复后
private static func hasChineseQuestion(_ text: String) -> Bool {
    let prefix = String(text.prefix(10))
    if chineseKeywords.contains(where: { prefix.contains($0) }) {
        return true
    }
    if let last = text.last {
        return chineseParticles.contains(String(last))
    }
    return false
}
```

**质量评价**: ✅ 有效减少了误报。`prefix(10)` 对短句（如"为什么?"）仍能匹配，对长陈述句（如"我不知道为什么他会来"）正确排除。

---

### P3-2: JSONLContentEntry 脆弱主键 ❌ 未修复

**当前状态**: 无变化。

---

### P3-3: VideoTranscription 全量内存加载 ❌ 未修复

**当前状态**: 无变化。

---

### P3-4: 测试覆盖不足 ❌ 未修复

**当前状态**: 测试文件数量无变化（仍 11 个单元测试文件）。无 ViewModel、SpeechEngine、JSONLStore 测试。

---

### P3-5: 不必要的 nonisolated(unsafe) ❌ 未修复

**当前状态**: `SpeakerEnrollmentService.swift:23` 的 `nonisolated(unsafe) static let minimumDuration` 仍未改动。

---

### P3-6: SpeechEngine partial 无去重 ❌ 未修复

**当前状态**: 无变化。

---

### P3-7: 错误消息未国际化 ❌ 未修复（但进度中）

**当前状态**: 
- `AppAudioCaptureService.CaptureError` 的 `errorDescription` 仍使用硬编码英文字符串（`"Target application not found"`、`"No display available for capture"`）
- `WhisperKitSpeechEngine.swift:245` 仍 yield 硬编码 `"WhisperKit error: ..."`
- **未提交更改**新增了 `control.grant_screen_recording` 的 i18n 字符串（✅），以及 `CaptureError.notAuthorized` 的错误消息（❌ 仍硬编码英文）

**建议**: 提交时将 `CaptureError` 的 `errorDescription` 全部改为 `String(localized:)`。

---

### P3-8: JSONLStore.deleteAllSessions 空 catch ❌ 未修复

**当前状态**: 第 323 行仍为 `} catch {}`。

---

## 新增发现

### N1 (P3): AppAudioCaptureService Screen Recording 权限处理（未提交更改）

**问题描述**:
未提交的更改（`AppAudioCaptureService.swift` + `ControlBarView.swift` + `GlobalHotkeyManager.swift`）添加了 Screen Recording 权限的预处理检查，但存在以下小问题：

1. `AppAudioCaptureService.CaptureError.notAuthorized` 的 `errorDescription` 使用了硬编码英文字符串 `"Screen Recording permission is required to capture app audio"`，未使用 `String(localized:)`。

2. `availableApps()` 中 `guard CGPreflightScreenCaptureAccess() else { return [] }` 后静默返回空数组，UI 层通过 `isScreenRecordingAuthorized` 检测并显示授权按钮，这是正确的。但如果用户已授权后 `SCShareableContent` 抛错（如无显示可用），错误日志会被吞掉（`} catch { ErrorLogger...; return [] }` 虽然已有日志）。

**涉及文件**: `TransFlow/Services/AppAudioCaptureService.swift` 第 16-35、113-117、189-191、255-263 行（未提交更改）

**修复建议**: 
```swift
case .notAuthorized:
    return String(localized: "capture.error.screen_recording_required")
```

**整体评价**: ✅ 这个更改的方向是正确的，避免自动弹出系统权限对话框。提交前仅需补上 i18n。

---

## 第二轮审查总结

| 类别 | 第一轮 | 第二轮 | 变化 |
|------|--------|--------|------|
| P1 问题 | 3 | 0 | **全部修复** ✅ |
| P2 问题 | 7 | 4 未修复 + 1 部分 | 修复 2 项 |
| P3 问题 | 8 | 7 未修复 | 修复 1 项 |
| 新增问题 | - | 1 (P3) | 权限处理增强中 |

**优先建议下一步行动**:
1. 🔴 **P2-1**: `retrieveTopK` @MainActor 阻塞 — 影响实时转写体验
2. 🔴 **P2-4**: `SpeakerProfilesStore.save()` 静默失败 — 数据丢失风险
3. 🟡 **P2-2**: FileHandle 频繁操作 — 性能累积开销
4. 🟡 **P2-3/P2-6**: WhisperKit 安全性和 buffer 策略 — 长期稳定性
5. 🟢 **P3-4**: 测试覆盖 — ViewModel/Engine 测试

---

_审查人: WorkBuddy | 审查模式: 跟进（第二轮）| 基于提交 `7c729ff`_
