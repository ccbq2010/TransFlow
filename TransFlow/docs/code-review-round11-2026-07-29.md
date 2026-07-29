# TransFlow 代码审查 — 第十一轮（深入审查）

> 日期：2026-07-29 | 基于前十轮修复后的代码状态

---

## 本轮关注点

前十轮已修复 21 项问题。本轮深入审查以下领域：
1. 音频捕获管道的线程安全边界
2. 翻译服务的 session 生命周期
3. 新拆分的 DiarizationCoordinator 与 ViewModel 交互
4. CloudCorrectedTranscriptionEngine 的取消语义
5. 强制解包和 unsafe 使用的剩余风险

---

## 发现的问题

### P1: AVAudioFormat 强制解包在特定硬件上可能崩溃

**文件**: AudioCaptureService.swift:63

虽然 `AVAudioFormat(standardFormatWithSampleRate:channels:)` 理论上不会返回 nil，但在某些蓝牙设备报告异常格式时，`AVAudioConverter(from:to:)` 可能构造失败。当前代码静默返回空 stream，用户只会看到"无法录音"但无任何错误提示。

**建议**: 增加错误回调或日志记录。

### P2: TranslationService session 的线程安全问题

**文件**: TranslationService.swift:186-210

`activeTranslationTasks` 字典在多个 Task 中被并发读写。虽然 `TranslationService` 是 `@MainActor`，Swift 编译器会保证串行访问，但如果未来有人将方法改为 `nonisolated`，将立即产生数据竞争。

**建议**: 添加 `precondition(IsOnMainActor())` 注释或文档说明。

### P3: DiarizationCoordinator 的 segments 与 ViewModel 状态同步

**文件**: DiarizationCoordinator.swift:43-48

`appendSegments` 方法没有触发 UI 更新。当新 diarization 段到达时，`segments` 数组更新但 SwiftUI 不会自动刷新依赖 `activeSpeakerCount` 的视图。

**建议**: 在 `appendSegments` 中手动触发 objectWillChange。

### P4: CloudCorrectedTranscriptionEngine 的 buffer 访问时序

**文件**: CloudCorrectedTranscriptionEngine.swift:120-135

`correctedSentence` 中 `let samples = await buffer.samples(in: range)` 的 range 计算依赖于 on-device 引擎报告的 timestamp。如果 on-device 引擎和 cloud 引擎的墙钟不同步，窗口可能不匹配。

**建议**: 增加窗口匹配失败的日志。

### P5: AudioRecordingService 的 stopRecording 非线程安全

**文件**: AudioRecordingService.swift:97-115

`stopRecording()` 虽然加了锁，但 `RecordingInfo` 返回后，调用方可能访问 `fileURL`，而 `stopRecording` 后文件已经 finalize。如果另一个线程（如 `writeChunk`）在 `stopRecording` 返回后尝试写入，会写入已关闭的文件。

**建议**: 当前实现中 `writeChunk` 在锁内检查 `_audioFile` 是否为 nil，所以是安全的。但建议添加注释说明这一不变量。

### P6: VAD 服务的能量阈值固定

**文件**: VADService.swift:26-28

`silenceThreshold = 0.01` 是硬编码的。不同麦克风（内置 vs 蓝牙 vs USB）的本底噪声差异很大。固定阈值可能导致：
- 低噪声麦克风：语音被误判为静音
- 高噪声麦克风：噪音被误判为语音

**建议**: 增加自适应阈值或用户可调参数。

### P7: WhisperKit 模型的 ANE 编译超时

**文件**: WhisperKitSpeechEngine.swift

90 秒硬超时对 ANE 编译是合理的，但如果用户使用的是旧款 M1 Mac 或模拟器，编译可能超过 90 秒。当前实现会静默失败。

**建议**: 增加超时后的 fallback 到 CPU 编译。

### P8: CloudASR 的 API Key 在内存中的生命周期

**文件**: CloudASRService.swift:56

`request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")` — `config.apiKey` 是 `String`，在内存中可被调试器读取。虽然 Keychain 存储解决了持久化安全，但内存中的明文 API Key 仍有风险。

**建议**: 当前可接受，但考虑使用 `SecKey` 或加密内存。

---

## 总结

| 级别 | 数量 | 关键问题 |
|------|------|---------|
| P1 | 1 | AVAudioFormat 强制解包 |
| P2 | 3 | 翻译线程安全、Diarization 同步、CloudCorrected 时序 |
| P3 | 4 | 录音 stop 注释、VAD 阈值、ANE 超时、API Key 内存 |

**建议优先修复**: P1（AVAudioFormat 错误处理）和 P3（VAD 自适应阈值）。

---

_审查完成于 2026-07-29_
