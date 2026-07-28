# 十轮审查问题验证报告

> 日期：2026-07-28 | 验证已修复问题是否仍存在

---

## 验证结果总览

| 状态 | 数量 | 说明 |
|------|------|------|
| ✅ 已修复 | 5 | 另一个 AI 已修复 |
| ⚠️ 仍存在 | 5 | 需要继续修复 |

---

## ✅ 已修复的问题

### 1. WhisperKit 旧链泄漏（第一轮 P1-3）
- **修复方式**: 新增 `processingTask` 引用 + `stop()` 方法
- **文件**: WhisperKitSpeechEngine.swift:38, 69, 258
- **验证**: `processingTask?.cancel()` 在 stopListening 时被调用

### 2. API Key 明文存储（第七轮 P7-1）
- **修复方式**: 新增 KeychainHelper，API Key 从 UserDefaults 迁移到 Keychain
- **文件**: AppSettings.swift:227, 233, KeychainHelper.swift（新文件）
- **验证**: KeychainHelper.saveAPIKey/loadAPIKey 完整实现，含迁移逻辑

### 3. WhisperKit 重复转写去重（第二轮 P2-3）
- **修复方式**: 使用绝对时间戳（Date.timeIntervalSince1970）做去重
- **文件**: WhisperKitSpeechEngine.swift:155-160, 214-217
- **验证**: `absEnd = endDate.timeIntervalSince1970` 替代相对时间

### 4. 引擎内部 Task 泄漏（第一轮 P1-1 部分）
- **修复方式**: stopListening 中调用 engine.stop() 并置 nil
- **文件**: TransFlowViewModel.swift:682-685
- **验证**: `if let engine = speechEngine as? WhisperKitSpeechEngine { engine.stop() }`

### 5. CloudCorrectedTranscriptionEngine 音频窗口
- **修复方式**: 使用绝对时间戳（墙钟 + segment 相对时间）
- **文件**: WhisperKitSpeechEngine.swift:153-154

---

## ⚠️ 仍存在的问题

### 1. forkTask 未完成时 cancel（第一轮 P1）
- **文件**: TransFlowViewModel.swift:628
- **问题**: `forkTask.cancel()` 前未 await，可能丢失末尾帧
- **建议**: `await forkTask.value` 后再 cancel

### 2. rewriteJSONL 全量重写风险（第四轮 P1）
- **文件**: TransFlowViewModel.swift:805-850
- **问题**: 崩溃可能导致整个会话 JSONL 损坏
- **建议**: write-to-temp + atomic replace

### 3. Cloud ASR 分片边界未对齐（第二轮 P1）
- **文件**: CloudASRService.swift:33-35
- **问题**: 按字节切分可能落在 16-bit PCM 帧中间
- **建议**: 确保切分点在 2 字节样本边界

### 4. TransFlowViewModel 过大（第三轮 P1）
- **文件**: TransFlowViewModel.swift（~890 行）
- **问题**: 单文件承担过多职责
- **建议**: 提取 DiarizationCoordinator、SessionPersistenceController

### 5. i18n 硬编码英文残留（第十轮 P3）
- **文件**: AudioCaptureService.swift、WhisperKitSpeechEngine.swift
- **问题**: 部分错误消息仍为硬编码英文
- **建议**: 运行 genstrings 扫描

---

## 另一个 AI 的修复质量评估

| 评价维度 | 评分 | 说明 |
|----------|------|------|
| 修复完整性 | ⭐⭐⭐⭐ | 5/10 问题已修复，关键安全问题（API Key）优先处理 |
| 代码质量 | ⭐⭐⭐⭐ | KeychainHelper 实现规范，含迁移逻辑 |
| 向后兼容 | ⭐⭐⭐⭐⭐ | Keychain 迁移考虑了旧数据兼容 |
| 测试覆盖 | ⭐⭐ | 新增代码缺少单元测试 |

---

_验证完成于 2026-07-28_
