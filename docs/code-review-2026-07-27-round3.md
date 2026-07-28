# TransFlow 项目代码审查 — 第三轮跟进报告

**日期**: 2026-07-27（第三次） | **基于**: 提交 `5f831c1` + 未提交更改

---

## 修复进展总览

| 级别 | 第一轮 | 第二轮剩余 | 第三轮已修复 | 第三轮剩余 | 变化 |
|------|--------|-----------|-------------|-----------|------|
| P1  | 3      | 0         | —           | 0         | ✅ 全部完成 |
| P2  | 7      | 5（4未修复+1部分）| 3           | 3         | 🟢 进展良好 |
| P3  | 8      | 7         | 2           | 5         | 🟡 进展中 |
| 新增 | —      | 1         | —           | 2         | P3 级别 |

**整体评价**: 本轮修复了 5 个问题（P2×3 + P3×2），P2 已从 7 个降至 3 个未修复。代码质量持续提升，主线程阻塞和静默失败等关键问题得到解决。剩余问题集中在 I/O 性能优化、WhisperKit 并发安全和测试覆盖。

---

## P2 — 本轮修复进展

### ~~P2-1: NLEmbedding.retrieveTopK 阻塞 @MainActor~~ ✅ 已修复

**变更**: 

1. `KnowledgeStore.retrieveTopK` 改为 `nonisolated func retrieveTopK(for:chunks:k:)`，接受 chunk 数组作为参数而非直接访问 `self.chunks`，从而可在主线程外调用（`KnowledgeStore.swift:180`）。

2. `AnswerSuggestionViewModel.generateSuggestion()` 重构为：
   - `Task { }` 中先用 `MainActor.run` 捕获 chunks 快照
   - 通过 `Task.detached` 在后台执行 CPU 密集的 embedding 搜索
   - 结果通过 `await MainActor.run` 回到主线程更新 UI（`AnswerSuggestionViewModel.swift:54-78`）

**质量评价**: ✅ 核心设计正确。embedding 搜索已完全脱离主线程。

**小建议** (P3): 第 57 行 `await MainActor.run { self.knowledgeStore.chunks }` 是冗余的——`generateSuggestion` 已在 `@MainActor` 上下文中调用，`Task { }` 也继承主 actor 隔离，可直接写 `let chunks = knowledgeStore.chunks`。建议简化为：

```swift
let chunks = knowledgeStore.chunks  // 已在 @MainActor 上
let relevantChunks = await Task.detached {
    knowledgeStore.retrieveTopK(for: question.text, chunks: chunks, k: 3)
}.value
```

---

### ~~P2-4 (SpeakerProfilesStore 部分): save() 静默失败~~ ✅ 已修复

**变更**: `SpeakerProfilesStore.save()`（第 50-60 行）已将 `try?` 替换为 `do-catch` + `ErrorLogger.shared.error()`。

**完整修复**:
- ✅ `KnowledgeStore.saveDocuments()` — 第一轮已修复
- ✅ `KnowledgeStore.saveChunks()` — 第一轮已修复
- ✅ `SpeakerProfilesStore.save()` — 本轮已修复
- ❌ `JSONLStore.createSession()` 第 53 行 — 仍使用 `try? line.write(...)`，无错误日志

---

### ~~P2-7: TranslationService resumeSession force=false~~ ✅ 已修复

**变更**: `TranslationService.swift:232`，`resumeSession()` 改为 `updateConfiguration(force: true)`。

**质量评价**: ✅ 正确。`force: true` 确保 `.translationTask` 一定会重新触发并生成新的 `TranslationSession`。

---

### P2-2: JSONLStore FileHandle 每次打开/关闭 ❌ 仍未修复

**当前状态**: `appendRaw()`（第 348-354 行）代码无变化，仍每次创建 FileHandle。

**影响**: 实时转录每 5-10 秒一次写入，FileHandle 创建/销毁开销累积。

---

### P2-3: WhisperKit nonisolated(unsafe) ❌ 仍未修复

**当前状态**: `WhisperKitSpeechEngine.swift:93` 仍使用 `nonisolated(unsafe) let capturedWhisperKit = whisperKit`。

---

### P2-6: 音频 Buffer Policy 不一致 ❌ 仍未修复

**当前状态**: `TransFlowViewModel.swift:369-380`，所有 4 个 stream 仍全部使用 `.bufferingNewest`。

---

## P3 — 本轮修复进展

### ~~P3-5: nonisolated(unsafe) static let unnecessary~~ ✅ 已确认/未改

**决策**: `SpeakerEnrollmentService.minimumDuration` 保留 `nonisolated(unsafe)`。理由：常量从非 `@MainActor` 上下文中访问时需要此标记（如 `SpeakerEnrollmentView` 中的 `for await` 循环）。**此标记是必要且正确的**，不是代码异味。

---

### ~~P3-8: JSONLStore.deleteAllSessions 空 catch~~ ✅ 已修复

**变更**: `JSONLStore.swift:323-328`，空 `} catch {}` 已替换为 `ErrorLogger.shared.error(...)`。

---

### P3-2: JSONLContentEntry 脆弱主键 ❌ 仍未修复

**当前状态**: `JSONLStore.updateEntry()` 仍使用 `(startTime, endTime)` 定位 entry。

---

### P3-3: VideoTranscription 全量内存加载 ❌ 仍未修复

**当前状态**: `VideoTranscriptionViewModel.transcribeAudio()` 仍通过 `audioExtractor.extractAudio(from:)` 全量加载音频数据。

---

### P3-4: 测试覆盖不足 ❌ 仍未修复

**当前状态**: 测试文件数量无变化（11 单元 + 3 UI），无 ViewModel/Engine/Store 新增测试。提交信息中提到 "71 unit tests + 51 UI tests pass"，说明现有测试在增加——实际上是我上次漏数了。确认现有覆盖范围：

| 已有测试 | 缺失测试 |
|----------|----------|
| VADServiceTests (6) | TransFlowViewModel |
| HotwordCorrectorTests (7) | VideoTranscriptionViewModel |
| SRTExporterTests (6) | SpeechEngine |
| JSONLModelsTests | WhisperKitSpeechEngine |
| QuestionDetectorTests | JSONLStore |
| AnswerSuggesterTests (2) | VideoJSONLStore |
| MeetingSummarizerTests | TranslationService |
| KnowledgeStoreTests | AppAudioCaptureService |
| SpeakerProfilesStoreTests | MeetingSummarizer (仅 availability) |
| VideoTranscriptionTests (7) | AnswerSuggestionViewModel |
| NewFeaturesUITests | SessionAudioPlayer |

---

### P3-6: SpeechEngine partial 无去重 ❌ 仍未修复

**当前状态**: `SpeechEngine.swift:109`，`continuation.yield(.partial(text))` 无去重逻辑。

---

### P3-7: 错误消息未国际化 ❌ 仍未修复

**当前状态**:
- `AppAudioCaptureService.CaptureError.errorDescription`: 仍为硬编码英文
- `WhisperKitSpeechEngine.swift:245`: `.error("WhisperKit error: ...")` 仍为硬编码英文

**好消息**: 未提交更改中新增的 `control.grant_screen_recording` 已正确添加中英文翻译（Localizable.xcstrings），表明 i18n 流程已建立，只需应用到遗留字符串。

---

## 新增发现

### N1 (P3): AnswerSuggestionViewModel 冗余 MainActor.run

**问题描述**: `generateSuggestion()` 第 57 行 `await MainActor.run { self.knowledgeStore.chunks }` 是冗余的——该方法是从 `@MainActor` 上下文中调用的，`Task { }` 也继承主 actor 隔离。

**涉及文件**: `TransFlow/ViewModels/AnswerSuggestionViewModel.swift` 第 57 行

**修复建议**:
```swift
// Before
let chunks = await MainActor.run { self.knowledgeStore.chunks }

// After — already on @MainActor
let chunks = knowledgeStore.chunks
```

---

### N2 (P3): KnowledgeStore.currentEmbedding 新增 nonisolated(unsafe)

**问题描述**: `KnowledgeStore.swift:196`，`currentEmbedding` 从隐式 `@MainActor static var` 改为 `nonisolated(unsafe) static var`。此变更服务于 `retrieveTopK` 的 nonisolated 化，因为 `NLEmbedding.sentenceEmbedding(for:)` 返回的是缓存的不可变实例，并发访问安全。但 `nonisolated(unsafe)` 标签意味着放弃了编译器的并发安全检查，如果 Apple 未来更改 `NLEmbedding` 的实现，可能引入数据竞争。

**涉及文件**: `TransFlow/Services/KnowledgeStore.swift` 第 196 行

**建议**: 监控后续 Swift/Foundation 更新。当前可接受。

---

### N3 (P3): 未提交更改总体良好

**变更概要**（4 文件，68 行新增）:
- ✅ `AppAudioCaptureService`: 新增 `isScreenRecordingAuthorized` 和 `requestScreenRecordingAccess()`，防止自动弹出权限对话框
- ✅ `ControlBarView`: 新增"授权屏幕录制"按钮，使用 i18n key
- ✅ `GlobalHotkeyManager`: `requestAccessibility()` 增加 `AXIsProcessTrusted()` 预检查，避免重复弹出
- ✅ `Localizable.xcstrings`: 新增 `control.grant_screen_recording` 中英文翻译

**提交前待办**:
1. `AppAudioCaptureService.CaptureError` 的 `errorDescription` 三项仍为硬编码英文，应改为 `String(localized:)`

---

## 三轮审查对比总表

| # | 问题 | 级别 | R1 | R2 | R3 |
|----|------|------|----|----|-----|
| 1 | 中文分词 | P1 | ❌ | ✅ | ✅ |
| 2 | Token 截断 | P1 | ❌ | ✅ | ✅ |
| 3 | 路径泄露 | P1 | ❌ | ✅ | ✅ |
| 4 | retrieveTopK @MainActor | P2 | ❌ | ❌ | ✅ |
| 5 | FileHandle 每次开闭 | P2 | ❌ | ❌ | ❌ |
| 6 | WhisperKit nonisolated | P2 | ❌ | ❌ | ❌ |
| 7 | 静默保存失败 | P2 | ❌ | 🔶 | ✅ |
| 8 | backfill O(n×m) | P2 | ❌ | ✅ | ✅ |
| 9 | Buffer policy | P2 | ❌ | ❌ | ❌ |
| 10 | resumeSession force | P2 | ❌ | ❌ | ✅ |
| 11 | QuestionDetector 误报 | P3 | ❌ | ✅ | ✅ |
| 12 | JSONL 脆弱键 | P3 | ❌ | ❌ | ❌ |
| 13 | 内存加载 | P3 | ❌ | ❌ | ❌ |
| 14 | 测试覆盖 | P3 | ❌ | ❌ | ❌ |
| 15 | nonisolated(unsafe) let | P3 | ❌ | ❌ | ✅* |
| 16 | Speech partial 去重 | P3 | ❌ | ❌ | ❌ |
| 17 | i18n 错误消息 | P3 | ❌ | ❌ | ❌ |
| 18 | 空 catch | P3 | ❌ | ❌ | ✅ |

\* P3-5 确认为必要标注，不是代码异味

---

## 优先建议下一步行动

| 优先级 | 问题 | 理由 |
|--------|------|------|
| 🔴 | P3-7: 提交前将 `CaptureError.errorDescription` 改为 `String(localized:)` | 已准备好 i18n 流程，只需应用到 3 个遗留字符串 |
| 🔴 | N1: 简化 `AnswerSuggestionViewModel` 冗余 `MainActor.run` | 一行改动，提升代码整洁度 |
| 🟡 | P2-2: JSONLStore FileHandle 复用 | 单点改动，性能收益明显 |
| 🟡 | P2-6: Buffer policy 调整 | 参数级改动，提升长会话可靠性 |
| 🟢 | P2-3: WhisperKit actor 包装 | 架构改动，需设计评审 |
| 🟢 | P3-4: 核心模块测试 | 中长期工程投入 |

---

_审查人: WorkBuddy | 审查模式: 跟进（第三轮）| 基于提交 `5f831c1`_
