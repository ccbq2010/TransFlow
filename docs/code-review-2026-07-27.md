# TransFlow 项目代码审查报告

**日期**: 2026-07-27 | **范围**: 全项目 | **Swift 版本**: 6 | **平台**: macOS 15.0+

---

## 审查概览

| 级别 | 数量 | 说明 |
|------|------|------|
| P1 — 必须修复 | 3 | 功能 Bug / 数据丢失 / 隐私泄露 |
| P2 — 建议修复 | 7 | 性能 / 架构 / 安全隐患 |
| P3 — 改进建议 | 8 | 代码质量 / 可维护性 / 测试 |

**总体评价**: 项目整体架构清晰，MVVM 分层合理，Swift 6 并发模型使用较为规范。AsyncStream fan-out 模式设计精巧，@unchecked Sendable 使用点均有注释说明安全性。主要问题集中在知识库中文处理、长文本边界、和静默失败处理上。

---

## P1 — 必须修复（Bug / 崩溃 / 数据泄露）

### P1-1: KnowledgeBase 中文分词完全失效

**问题描述**:
`KnowledgeStore.chunkText()` 使用 `para.split(separator: " ")` 计算词数（第 133 行）。中文文本无空格分隔，整个段落被计为 1 个"词"。这导致：
- 中文文档的 chunk 永远不会达到 `maxWords = 400` 的阈值
- 多个段落被拼接成一个巨大的 chunk，可能包含整篇文档的全部内容
- `NLEmbedding` 的语义检索对大段文本效果极差
- `AnswerSuggester` 传入的 knowledge context 可能远超 FoundationModels 的上下文窗口

**涉及文件**: `TransFlow/Services/KnowledgeStore.swift` 第 123-147 行

**修复建议**:
```swift
// 针对 CJK 文本使用字符数而非空格分词数
private func wordCount(_ text: String) -> Int {
    // 检测是否主要为 CJK 文本
    let cjkChars = text.unicodeScalars.filter {
        (0x4E00...0x9FFF).contains($0.value) ||  // CJK Unified
        (0x3400...0x4DBF).contains($0.value) ||  // CJK Extension A
        (0x3040...0x309F).contains($0.value) ||  // Hiragana
        (0x30A0...0x30FF).contains($0.value)     // Katakana
    }.count
    if cjkChars > text.count / 2 {
        // CJK: ~400 字符 = ~400 tokens
        return text.count
    }
    return text.split(separator: " ").count
}

private func chunkText(_ text: String) -> [String] {
    // 对中文也按句子边界分割
    let paragraphs = text.components(separatedBy: "\n\n")
        .flatMap { splitIntoCJKSentences($0) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    // ...
}
```

---

### P1-2: MeetingSummarizer 无 Transcript 长度限制

**问题描述**:
`MeetingSummarizer.buildPrompt()` 将全部转录条目拼接到一个 prompt 中，无截断逻辑。FoundationModels (`SystemLanguageModel`) 有明确的上下文窗口限制：
- 1 小时会议 ≈ 800-1000 条句子 ≈ 5000-8000 tokens（仅原文）
- 加上 speaker 标注和 markdown 指令，极易超过 Apple 本地模型的上下文限制
- 超限时 FoundationModels 可能出现：静默截断输出、生成乱码、或抛异常但不提供有意义的错误信息

目前唯一的保护是 `SummaryError.emptyTranscription`，但缺少 token 计数和截断机制。

**涉及文件**: `TransFlow/Services/MeetingSummarizer.swift` 第 76-87 行、第 120-128 行

**修复建议**:
```swift
/// 估算 token 数量（粗略：英文 1 token ≈ 4 字符，中文 1 token ≈ 1.5 字符）
private func estimateTokens(_ text: String) -> Int {
    let cjkCount = text.unicodeScalars.filter {
        (0x4E00...0x9FFF).contains($0.value)
    }.count
    let otherCount = text.count - cjkCount
    return cjkCount + otherCount / 4
}

/// FoundationModels 保守的上下文上限
private static let maxInputTokens = 4000

private func buildPrompt(transcript: String, sessionName: String?) -> String {
    var truncated = transcript
    if estimateTokens(transcript) > Self.maxInputTokens {
        // 保留前 30% 和后 70% 的转录内容
        let sentences = transcript.components(separatedBy: "\n")
        let keepCount = sentences.count
        let headCount = Int(Double(keepCount) * 0.3)
        let tailCount = keepCount - headCount
        let head = sentences.prefix(headCount).joined(separator: "\n")
        let tail = sentences.suffix(tailCount).joined(separator: "\n")
        truncated = """
        [Beginning of transcript]
        \(head)
        ...
        [\(keepCount - headCount - tailCount) lines omitted]
        ...
        \(tail)
        [End of transcript]
        """
    }
    // ...
}
```

---

### P1-3: VideoTranscription 存储原始文件完整路径（隐私泄露）

**问题描述**:
`VideoTranscriptionViewModel.swift` 第 228 行将 `originalFilePath: fileURL.path` 直接写入 JSONL 元数据。文件路径包含用户名：
```
/Users/zhangsan/Downloads/机密会议录屏.mp4
/Users/johnsmith/Desktop/company-strategy.mp4
```
此路径被持久化到 `~/Library/Application Support/com.transflow/video_transcriptions/*.jsonl`，且可能在导出 SRT/Markdown 时泄露，或在 HistoryView 中展示。

**涉及文件**: `TransFlow/ViewModels/VideoTranscriptionViewModel.swift` 第 226-228 行

**修复建议**:
```swift
// 只存文件名，不存完整路径；如需恢复路径，存 security-scoped bookmark
let metadata = VideoJSONLMetadata(
    videoFile: fileURL.lastPathComponent,     // ✅ 已有，仅文件名
    // originalFilePath: fileURL.path,        // ❌ 删除此行
    bookmarkData: try? fileURL.bookmarkData(  // ✅ 替换为 security-scoped bookmark
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    ),
    // ...
)
```

---

## P2 — 建议修复（性能 / 架构 / 安全隐患）

### P2-1: NLEmbedding.retrieveTopK 阻塞主线程

**问题描述**:
`KnowledgeStore.retrieveTopK()` 在第 152-165 行遍历所有 chunks 并调用 `NLEmbedding.distance(between:and:)`。此方法从 `AnswerSuggestionViewModel.generateSuggestion()`（第 56 行）调用，后者是 `@MainActor` 上下文。对大知识库（100+ chunks），NLEmbedding 距离计算是 CPU 密集型操作，会直接卡住 UI。

**涉及文件**: 
- `TransFlow/Services/KnowledgeStore.swift` 第 152-165 行
- `TransFlow/ViewModels/AnswerSuggestionViewModel.swift` 第 54-68 行

**修复建议**:
```swift
// AnswerSuggestionViewModel.generateSuggestion 中：
Task.detached { [question, knowledgeStore] in
    let relevantChunks = knowledgeStore.retrieveTopK(question.text, k: 3)
    await MainActor.run {
        // 继续在主线程上调用 suggester
    }
}
// 或将 KnowledgeStore.retrieveTopK 改为 nonisolated：
nonisolated func retrieveTopK(_ query: String, k: Int = 3) -> [KnowledgeChunk] {
    // ...CPU 密集计算在主线程外执行
}
```

---

### P2-2: JSONLStore.appendRaw 每次写入都打开/关闭 FileHandle

**问题描述**:
`JSONLStore.appendRaw()` 第 343-350 行每次调用都执行 `FileHandle(forWritingTo:)` → `seekToEndOfFile()` → `write()` → `closeFile()`。实时转录时，每句完整话（约每 5-10 秒）触发一次写入。`rewriteJSONLWithCurrentSentences()` 也更频繁地全量重写文件。虽然 JSONL 单行写入量小，但 FileHandle 的创建/销毁开销累积可观。

**涉及文件**: `TransFlow/Services/JSONLStore.swift` 第 343-350 行

**修复建议**:
```swift
// 在 createSession 时保持一个 FileHandle，session 结束时关闭
private var writeHandle: FileHandle?

func createSession(name: String? = nil) -> String {
    // ...existing code...
    if let fileURL = self.currentFileURL {
        writeHandle = try? FileHandle(forWritingTo: fileURL)
        writeHandle?.seekToEndOfFile()
    }
    return sessionName
}

private func appendRaw(_ line: String, to fileURL: URL) {
    let data = Data(("\n" + line).utf8)
    writeHandle?.write(data)
}

// 在 TransFlowViewModel.stopListening() 或 createNewSession() 时关闭
func closeSession() {
    writeHandle?.closeFile()
    writeHandle = nil
}
```
相同问题也存在于 `VideoJSONLStore`。

---

### P2-3: WhisperKitSpeechEngine 中 `nonisolated(unsafe)` 存在潜在悬垂引用

**问题描述**:
`WhisperKitSpeechEngine.swift` 第 93 行用 `nonisolated(unsafe) let capturedWhisperKit = whisperKit` 将非 Sendable 的 WhisperKit 实例传入串行转写链。虽然 `transcribeChain` 机制保证了同时只有一个 Task 访问，但如果 `WhisperKitSpeechEngine` 实例在转写进行中被释放（例如用户快速切换引擎），串行链中 pending 的 Task 仍持有 `capturedWhisperKit` 的引用，而 `nonisolated(unsafe)` 绕过了编译器的生命周期检查。

**涉及文件**: `TransFlow/Services/WhisperKitSpeechEngine.swift` 第 93 行

**修复建议**:
```swift
// 方案 1: 使用 actor 包装 WhisperKit 访问
private actor WhisperKitActor {
    let whisperKit: WhisperKit
    init(_ wk: WhisperKit) { self.whisperKit = wk }
    
    func transcribe(audio: [Float], options: DecodingOptions) async throws -> [TranscriptionResult] {
        try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
    }
}

// 方案 2: 在 processStream 返回时取消所有 pending 的 transcribeChain
// 在流结束后 await transcribeChain?.cancel()
```

---

### P2-4: 写盘静默失败（多处）

**问题描述**:
以下位置的 `try?` 在磁盘空间不足、权限变更等场景下会静默丢弃数据：
- `KnowledgeStore.saveDocuments()` 第 69 行 — 丢失知识库文档
- `KnowledgeStore.saveChunks()` 第 75 行 — 丢失知识库索引
- `SpeakerProfilesStore.save()` 第 52 行 — 丢失声纹数据
- `JSONLStore.createSession()` 第 53 行 — 丢失元数据行
- `VideoJSONLStore.rewriteAllEntries` 类似模式

**涉及文件**:
- `TransFlow/Services/KnowledgeStore.swift` 第 67-70, 73-76 行
- `TransFlow/Services/SpeakerProfilesStore.swift` 第 50-53 行
- `TransFlow/Services/JSONLStore.swift` 第 51-53 行

**修复建议**:
```swift
private func saveDocuments() {
    let dir = appSupportDir
    do {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(documents)
        try data.write(to: documentsURL, options: .atomic)
    } catch {
        ErrorLogger.shared.error(
            "Failed to save knowledge documents: \(error.localizedDescription)",
            source: "KnowledgeStore"
        )
        // 可选：标记需要重试、通知 UI
    }
}
```

---

### P2-5: 实时说话人回溯 O(n×m) 性能问题

**问题描述**:
`TransFlowViewModel.backfillSpeakerIds()` 第 703-733 行在每次新的 diarization 段到达时，遍历所有 sentences × 所有 diarizationSegments。对于 1 小时会议（~600 句 × ~200 段），这是 120,000 次循环。且每次 backfill 后调用 `rewriteJSONLWithCurrentSentences()`（第 731 行），触发全量 JSONL 重写。

**涉及文件**:
- `TransFlow/ViewModels/TransFlowViewModel.swift` 第 703-733 行
- `TransFlow/ViewModels/TransFlowViewModel.swift` 第 736-777 行

**修复建议**:
```swift
// 只回溯最近 N 句未分配说话人的句子（而非全部）
private func backfillSpeakerIds() {
    guard let sessionStart = sessionStartTime else { return }
    // 从后向前扫描，只处理新增的尚未分配 speaker 的句子
    let maxBackfill = 50  // 只回溯最近 50 句
    var changed = false
    let startIndex = max(0, sentences.count - maxBackfill)
    
    for i in startIndex..<sentences.count where sentences[i].speakerId == nil {
        // ...existing overlap logic...
    }
    if changed && shouldRewriteOnDisk {
        rewriteJSONLWithCurrentSentences()
    }
}

// 同时加 debounce: 500ms 内只重写一次
private var backfillDebounceTask: Task<Void, Never>?
```

---

### P2-6: 音频录制 buffer 策略不一致

**问题描述**:
`TransFlowViewModel.startListening()` 第 369-403 行为 4 个消费者创建了不同的 `bufferingPolicy`：
- engine: `.bufferingNewest(256)` — 最大 256 个 AudioChunk（约 25 秒 @100ms/chunk）
- level: `.bufferingNewest(64)` — 最大 64 个 AudioChunk
- recording: `.bufferingNewest(256)` — 与 engine 相同
- diarization: `.bufferingNewest(256)` — 与 engine 相同

当引擎处理慢于音频采集（WhisperKit 转写可能数秒延迟），engine stream 积压 256 个 chunk → 25 秒延迟。这会导致说话人分配的时间戳偏移越来越大。`bufferingNewest` 会丢弃旧数据，但对 engine 路径来说丢失的是中间的音频，可能导致转写不完整。

**涉及文件**: `TransFlow/ViewModels/TransFlowViewModel.swift` 第 369-380 行

**修复建议**:
```swift
// engine 和 diarization 使用 .bufferingOldest(128) 以避免丢帧
// recording 和 level 使用较小的 .bufferingNewest(32)
// 同时添加背压机制：如果 engine stream buffer 接近满，skip yield
let (engineStream, engineContinuation) = AsyncStream<AudioChunk>.makeStream(
    bufferingPolicy: .bufferingOldest(128)  // 不丢数据，但限制最大积压
)
```

---

### P2-7: TranslationService.updateConfiguration — force=false 时的静默跳过

**问题描述**:
`TranslationService.updateConfiguration(force:)` 第 152-195 行中，当 `pairUnchanged == true` 且 `force == false` 时，函数在已 `cancelAllTranslations()` 并设置 `session = nil` 后直接返回（第 176-184 行）。此时 `session` 为 nil，后续翻译请求将静默失败直到 `.translationTask` 重新触发。调用方（`disableTranslation()` → `updateConfiguration()`）在 `isEnabled = false` 后不调用 `updateConfiguration(force: true)`——实际上 `disableTranslation()` 调用的是无参 `updateConfiguration()`，该路径第 153-158 行会正确清除 session。

但是 `disableTranslation()` 第 261 行调用的是 `updateConfiguration()`（无 force 参数）。检查 `updateConfiguration` 第 153-158 行的 guard 逻辑：`guard isEnabled else { cancelAllTranslations(); session = nil; return }` — 当 `isEnabled = false` 时会正确清理。所以这个问题在 disable 路径上是正确的。

但当此方法被多次调用（同一语言对）且 `force=false` 时，会没有 agent 重新创建配置。如果 session 因某种原因变为 nil 后但配置未 refresh 时。调用 `resumeSession()`（第 229-233 行）使用无参 `updateConfiguration()`，如果 pair unchanged 且 force=false，不会 invalidate。但 `resumeSession` 调用时 `isEnabled=true`，而且之前 `suspendSession` 只是清了 session 没有改配置。由于 pair unchanged，`updateConfiguration()` 直接 return 了（第 184 行 after `session=nil` on line 169）。这导致 session 保持为 nil 但配置正确——需要 `.translationTask` 重新触发才能获得新 session。这可能是一个隐含的 bug。

**涉及文件**: `TransFlow/Services/TranslationService.swift` 第 152-195 行

**修复建议**:
```swift
// resumeSession 应该始终 force invalidate
func resumeSession() {
    guard isEnabled, sourceLanguage != nil else { return }
    updateConfiguration(force: true)  // 改为 force: true
}
```

---

## P3 — 改进建议（代码质量 / 可维护性 / 测试）

### P3-1: QuestionDetector 中文问句检测误报

**问题描述**:
`QuestionDetector.hasChineseQuestion()` 第 62-69 行只要文本包含"为什么"/"什么"/"怎么"等关键词就判定为问句。这会产生大量误报，例如：
- "我不知道为什么他会来" → 误判为问句
- "这不重要，重要的是什么结果" → 误判为问句
- "你告诉我怎么走" → 误判为问句

**涉及文件**: `TransFlow/Services/QuestionDetector.swift` 第 62-69 行

**修复建议**:
```swift
private static func hasChineseQuestion(_ text: String) -> Bool {
    // 增强规则：关键词必须在句首或近句首 + 无否定前缀
    if chineseKeywords.contains(where: { text.hasPrefix($0) }) {
        return true
    }
    // 句末语气词必须在句尾
    if let last = text.last, chineseParticles.contains(String(last)) {
        return true
    }
    // 疑问词 + 句末问号（如"可以...吗"）
    return false  // 移除通用 contains 匹配
}
```

---

### P3-2: JSONLStore.updateEntry 使用脆弱的主键

**问题描述**:
`JSONLStore.updateEntry()` 第 195-264 行使用 `(startTime, endTime)` 作为定位 entry 的唯一键。ISO8601 时间戳精度为毫秒级，理论上两个句子的时间戳可能相同（特别是快速说话或同一段音频）。当匹配到 0 或 >1 条记录时仅 log 错误并返回 false，调用方无法区分"找不到"和"重复"。

**涉及文件**: `TransFlow/Services/JSONLStore.swift` 第 195-264 行

**修复建议**:
```swift
// 为 JSONLContentEntry 添加唯一 id
struct JSONLContentEntry: Codable {
    let id: String  // UUID
    let startTime: String
    // ...
}

func updateEntry(in url: URL, entryId: String, ...) -> Bool {
    // 使用 id 而非 (startTime, endTime) 元组定位
}
```

---

### P3-3: VideoTranscription audioExtractor 全量加载到内存

**问题描述**:
`VideoTranscriptionViewModel.transcribeAudio()` 第 277-343 行将整个视频的音频提取为 `[Float]` 数组并一次性加载到内存。对于大视频文件：
- 1 小时 16kHz mono Float32 = 57.6M 采样 × 4 字节 = **230 MB**
- 2 小时电影 = **460 MB**
- 这在 Swift 内存中是单个连续数组，分配可能失败（OOM）

虽然 `AudioExtractorService` 有 streaming 变体（`extractAudioStreaming`），但视频转录路径使用的是 `extractAudio(from:)` 返回全量数组。

**涉及文件**:
- `TransFlow/ViewModels/VideoTranscriptionViewModel.swift` 第 168 行
- `TransFlow/Services/AudioExtractorService.swift`

**修复建议**:
```swift
// 使用 streaming 版本 + chunked transcription
let audioStream = try audioExtractor.extractAudioStreaming(from: fileURL)
var allSamples: [Float] = []
for await chunk in audioStream {
    allSamples.append(contentsOf: chunk.samples)
    // 每 30 秒 flush 到磁盘以防 OOM
}
// 或改为 pipeline 模式：边提取边转写
```

---

### P3-4: 测试覆盖不足

**问题描述**:
现有测试覆盖：
- ✅ VADService、HotwordCorrector、SRTExporter、QuestionDetector（逻辑测试充分）
- ✅ JSONLModels、KnowledgeStore、SpeakerProfilesStore（基本 CRUD 测试）
- ✅ VideoTranscriptionTests（集成测试较好）
- ❌ TransFlowViewModel（0 测试）— 核心协调器
- ❌ VideoTranscriptionViewModel（0 测试）— 视频转录管道
- ❌ SpeechEngine / WhisperKitSpeechEngine（0 测试）— 核心引擎
- ❌ TranslationService（0 测试）— 翻译协调
- ❌ JSONLStore / VideoJSONLStore（0 单元测试）— 持久化
- ❌ AppAudioCaptureService（0 测试）
- ❌ MeetingSummarizer（仅有 availability 检查）

**涉及文件**: `TransFlow/TransFlowTests/`

**建议**:
至少为以下模块添加单元测试：
1. `JSONLStore` — append/read/update/delete roundtrip
2. `TranslationService` — 语言对配置、session 生命周期
3. `TransFlowViewModel` — `renameSpeaker`、`assignSpeaker`、`backfillSpeakerIds`
4. `MeetingSummarizer` — token 截断逻辑（新增后）

---

### P3-5: `nonisolated(unsafe)` 用于静态常量

**问题描述**:
以下静态常量被标记为 `nonisolated(unsafe)`，但它们实际上是不可变的常量：
- `AudioCaptureService` 中的 `nonisolated(unsafe) var consumed = false`（局部变量，tap 回调内）
- `SpeakerEnrollmentService` 中的 `nonisolated(unsafe) static let minimumDuration: Double = 3.0` — 这是 let 常量为什么需要 `nonisolated(unsafe)`？
- `GlobalHotkeyManager` 中的 `nonisolated(unsafe) static var cachedBindings` — 可变的全局状态，确实是 unsafe

**涉及文件**: 多处（见搜索结果中的 `nonisolated(unsafe)` 使用）

**修复建议**:
```swift
// SpeakerEnrollmentService.swift:23 — 移除 unnecessary nonisolated(unsafe)
static let minimumDuration: Double = 3.0  // let 常量不需要 nonisolated(unsafe)

// GlobalHotkeyManager.swift:23 — 使用 actor 或 @MainActor 替代全局可变状态
@MainActor static var cachedBindings: [CachedBinding] = []
```

---

### P3-6: SpeechEngine 错误处理不完整

**问题描述**:
`SpeechEngine.processStream()` 第 87-116 行的 resultTask 中，`for try await result in transcriber.results` 可能抛出多种错误（SpeechAnalyzer 运行时错误、格式不匹配等），当前只在最外层 catch 捕获为通用错误消息。对 `result.isFinal == false` 的 partial 结果没有去重逻辑，SwiftUI Text 更新可能过于频繁。

**涉及文件**: `TransFlow/Services/SpeechEngine.swift` 第 87-116 行

**修复建议**:
```swift
for try await result in transcriber.results {
    let text = String(result.text.characters)
    if result.isFinal {
        // ...existing logic...
    } else {
        // 添加去重：仅在文本变更时发送
        if text != lastPartialText {
            continuation.yield(.partial(text))
            lastPartialText = text
        }
    }
}
```

---

### P3-7: 错误消息未国际化

**问题描述**:
以下硬编码的英文字符串未使用 String Catalog：
- `AudioCaptureService` 错误消息 `"Microphone permission not granted"`
- `AppAudioCaptureService.CaptureError` 错误描述 `"Target application not found"`、`"No display available for capture"`
- `WhisperKitSpeechEngine` 错误 yield 的字符串 `"WhisperKit error: ..."`（直接拼接 error.localizedDescription）

`AppAudioCaptureService.CaptureError` 的 `errorDescription` 使用普通字符串而非 `String(localized:)`，与项目国际化规范（AGENTS.md）不一致。

**涉及文件**:
- `TransFlow/Services/AppAudioCaptureService.swift` 第 222-234 行
- `TransFlow/Services/WhisperKitSpeechEngine.swift` 第 245 行

---

### P3-8: JSONLStore.deleteAllSessions 第 323 行空 catch

**问题描述**:
`JSONLStore.deleteAllSessions()` 第 306-324 行的 `do-catch` 块使用空 `catch {}`，静默吞下所有目录遍历错误。如果 `Application Support` 权限变更或目录损坏，用户无法感知删除失败。

**涉及文件**: `TransFlow/Services/JSONLStore.swift` 第 323 行

**修复建议**:
```swift
} catch {
    ErrorLogger.shared.error(
        "Failed to delete all sessions: \(error.localizedDescription)",
        source: "JSONLStore"
    )
}
```

---

## 架构亮点

以下是审查中发现的值得肯定的设计决策：

1. **AsyncStream fan-out 模式**（TransFlowViewModel:369-403）：一个音频源 fork 到 4 个独立的消费者流，每个有独立的 `bufferingPolicy`，设计优雅且可扩展。

2. **说话人命名管线**：`speakerNameOverrides` → `backfillSpeakerIds` → `rewriteJSONL` 的链路清晰，支持实时回溯和历史持久化。

3. **TranslationService Configuration 生命周期**：经过多次迭代修复的 `invalidate()` / `force` 机制正确解决了 SwiftUI `.translationTask` 的 re-fire 问题，注释详尽。

4. **双引擎架构**：`TranscriptionEngineProtocol` 抽象层使得 Apple Speech 和 WhisperKit 可以互换，视频和实时场景共用相同接口。

5. **HuggingFace 镜像自动检测**：`DiarizationModelManager` 和 `WhisperKitModelManager` 对中国地区的自动镜像切换。

6. **ErrorLogger 设计**：`Sendable` + 内部串行队列 + ring buffer + 自动清理，是线程安全日志的良好实践。

7. **@unchecked Sendable 文档化**：每个 `@unchecked Sendable` 类都附有注释说明为什么安全（NSLock、serial queue 等）。

---

## 总结

TransFlow 是一个架构合理、并发使用规范的 macOS 应用。P1 问题（中文分词、transcript 截断、路径泄露）应优先修复，它们直接影响中文用户的使用体验和隐私安全。P2 问题主要是性能优化和健壮性改进，可在后续迭代中逐步解决。测试覆盖方面，核心 ViewModel 和服务层缺乏单元测试，建议在新增功能前先补齐关键路径的测试。
