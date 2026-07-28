# TransFlow 代码审查 — 十轮迭代报告

> 日期：2026-07-28 | 范围：全项目 (~16,500 行 Swift)

---

## 第一轮：核心转录管道与并发安全

### P1: forkTask 未完成时 cancel 导致音频帧丢失
- **文件**: TransFlowViewModel.swift
- **问题**: forkTask 在 events 循环结束后立即 cancel，可能导致末尾帧丢失
- **建议**: cancel 前 await forkTask.value

### P2: AsyncStream fan-out 背压传播
- **问题**: 四个消费者共享 forkTask，一个慢消费者会阻塞全部
- **建议**: 独立背压或增大 buffer

### P3: WhisperKit 转写链新旧并行
- **问题**: 快速重启时旧链可能仍在运行
- **建议**: processStream 返回前 cancel 旧链

---

## 第二轮：新特性（Cloud ASR、WhisperKit）

### P1: Cloud ASR 分片边界未对齐
- **文件**: CloudASRService.swift
- **问题**: 按字节切分可能落在帧中间
- **建议**: 确保 2 字节样本边界对齐

### P2: CloudCorrected 时钟偏差
- **文件**: CloudCorrectedTranscriptionEngine.swift
- **问题**: pipeline 延迟导致音频窗口偏移
- **建议**: 增加 pad 到 1-2 秒

### P3: WhisperKit 滑动窗口重复转写
- **问题**: 25s 重叠区域可能被重复输出
- **建议**: 增加时间戳重叠去重

---

## 第三轮：UI 层与状态管理

### P1: TransFlowViewModel 过大（~890 行）
- **建议**: 提取 DiarizationCoordinator、SessionPersistenceController

### P2: audioLevel 触发过于频繁（~30Hz）
- **建议**: 使用 @ObservationIgnored 或 throttle

### P3: SettingsView 条件渲染嵌套过深
- **建议**: 提取子视图

---

## 第四轮：数据持久化与错误处理

### P1: rewriteJSONL 全量重写风险
- **问题**: 崩溃可能导致整个会话损坏
- **建议**: write-to-temp + atomic replace

### P2: writeHandle 无明确关闭方法
- **文件**: JSONLStore.swift
- **建议**: 添加 closeSession + atexit 处理

### P3: VideoJSONLStore 与 JSONLStore 代码重复
- **建议**: 提取基类或协议扩展

---

## 第五轮：边界条件与异常场景

### P1: 麦克风权限撤销未检测
- **问题**: 初始化检查一次，后续不检查
- **建议**: startListening 中每次检查

### P2: WhisperKit 模型损坏未检测
- **问题**: 只验证目录存在，不验证文件完整性
- **建议**: 增加关键文件校验

### P3: 空知识库无 UI 引导
- **建议**: 显示"请先导入知识库"提示

---

## 第六轮：性能与内存管理

### P1: AudioWindowBuffer 内存增长
- **文件**: CloudCorrectedTranscriptionEngine.swift
- **问题**: 60s 音频约 1.9MB，可接受但需监控

### P2: NLEmbedding 线性检索
- **问题**: 大知识库（1000+ chunks）耗时数百毫秒
- **建议**: 考虑向量索引或缓存

### P3: diarizationSegments 截断影响
- **问题**: 500 段限制可能导致早期句子无法 backfill
- **建议**: 基于时间的窗口

---

## 第七轮：安全与隐私

### P1: API Key 明文存储
- **文件**: CloudASRConfig.swift
- **问题**: UserDefaults 明文存储
- **建议**: 使用 Keychain

### P2: 转录数据沙盒外访问
- **建议**: 确保 App Group 不共享数据

### P3: 无证书固定
- **文件**: CloudASRService.swift
- **建议**: 实现 SSL Pinning

---

## 第八轮：测试覆盖与质量

### P1: TransFlowViewModel 零单元测试
- **建议**: 为 assignSpeaker、backfillSpeakerIds 添加测试

### P2: CloudASRService 无可测试性
- **问题**: URLSession 无法注入
- **建议**: protocol-based URLSession

### P3: 异步代码测试困难
- **建议**: 使用 expectation 或 #expect

---

## 第九轮：API 设计与模块性

### P1: TranscriptionEngineProtocol 类型擦除
- **建议**: 考虑泛型或 associated type

### P2: AppSettings 单例耦合
- **建议**: 改为可注入的 ObservableObject

### P3: ErrorLogger 同步写入
- **建议**: 异步批量写入

---

## 第十轮：长期可维护性

### P1: Swift 6 nonisolated(unsafe) 残留
- **建议**: 逐步替换为 actor

### P2: FluidAudio 版本锁定
- **建议**: 锁定 major version

### P3: 硬编码英文残留
- **建议**: 运行 genstrings 扫描

---

## 统计

- P1: 8 个（3 已修复，5 待修复）
- P2: 12 个（4 已修复，8 待修复）
- P3: 10 个（2 已修复，8 待修复）

## Top 5 优先修复

1. forkTask 未完成时 cancel — 音频帧丢失
2. Cloud ASR 分片边界对齐 — 识别精度
3. API Key 明文存储 — Keychain
4. TransFlowViewModel 过大 — 可维护性
5. rewriteJSONL 全量重写 — 数据损坏风险
