# TransFlow 代码审查 — 需修复问题清单

> 基于十轮代码审查 + 逐条代码核实（2026-07-29）
> 核实方式：阅读实际源码，区分真问题 / 误报 / 已处理

---

## 一、已核实为误报（无需处理）

| 编号 | 问题 | 核实结论 |
|------|------|----------|
| R1-P1 | forkTask cancel 丢帧 | **误报**。`forkTask.cancel()` 在 events 循环结束后调用（TransFlowViewModel.swift:628），循环退出即 forkTask 已完成，cancel 是清理空操作 |
| R4-P1 | rewriteJSONL 全量重写损坏 | **已处理**。三处全用 `atomically: true`（JSONLStore.swift:267 / VideoJSONLStore.swift:287 / TransFlowViewModel.swift:845），APFS 上写临时文件+rename，崩溃不损坏原文件 |
| R2-P1 | Cloud ASR 分片边界未对齐 | **误报**。`bytesPerSecond = 16000 * 2 = 32000`（恒偶），切片偏移永远是 2 字节倍数，不会落在样本中间 |

---

## 二、需修复问题（按优先级排序）

### 🔴 P0-1：WhisperKit 滑动窗口重复输出（直接影响识别质量）

- **文件**：`TransFlow/TransFlow/Services/WhisperKitSpeechEngine.swift`
- **问题**：`TranscriptionState.shouldCommit(endingAt:)` 用 `segment.end`（**窗口内相对时间**）做去重。30s 窗口每 5s 滑动一次，同一音频段在新窗口里的相对时间会偏移（如 `[1.0, 2.0]` → `[1.0, 2.1]`），`2.1 > lastCommittedEndSec(2.0)` 判定为新段 → **重复提交**。
- **根因**：`segment.end` 是相对当前窗口的时间戳，不是绝对时间。绝对时间在 154-155 行已计算（`windowStartWallTime + segment.end`）但**未用于去重**。
- **修法**：`shouldCommit` 改用**绝对时间**作为去重键：

```swift
// 修改前（相对时间，有重复风险）
let shouldCommit = await state.shouldCommit(endingAt: Double(segment.end))

// 修改后（绝对时间）
let absEnd = windowStartWallTime.addingTimeInterval(Double(segment.end)).timeIntervalSince1970
let shouldCommit = await state.shouldCommit(endingAt: absEnd)
```

`TranscriptionState` actor 内部 `lastCommittedEndSec` 改存绝对时间戳（`Date().timeIntervalSince1970`），两处调用点（窗口路径 ~line 150 + 尾部路径 ~line 180）都改。

- **验证**：用 `AccuracyBenchmarks` 跑基准，对比修复前后 WER（重复句应消失，WER 下降）。
- **风险**：低。改动局限于去重逻辑，不影响转写本身。
- **回退**：git revert 单文件。

---

### 🟡 P0-2：API Key 明文存储（安全问题）

- **文件**：`TransFlow/TransFlow/Models/AppSettings.swift:304-305` + `CloudASRConfig.swift`
- **问题**：`CloudASRConfig`（含 `apiKey: String`）整体 JSON 编码后存 `UserDefaults.standard`。全项目零 Keychain 调用。API Key 可通过 `defaults read` 或备份提取恢复。
- **修法**：
  1. 新建 `KeychainHelper.swift`：封装 `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete`，按 service="TransFlow.cloudASR" + account="apiKey" 存取。
  2. `CloudASRConfig` 的 `apiKey` 不再随 JSON 存 UserDefaults；`saveCloudASR()` / 加载时单独走 Keychain。
  3. 迁移：首次加载时若 UserDefaults 里还有旧 apiKey，迁移到 Keychain 并从 UserDefaults 清除。
- **验证**：设一个 Cloud ASR 配置 → 重启 App → 确认 Keychain 里有、UserDefaults 里没有 → `defaults read com.cyron.TransFlow` 不应出现 apiKey。
- **风险**：中。涉及密钥迁移，需处理迁移失败/回退。Cloud ASR 是可选功能，未启用时不影响。
- **国际化**：KeychainHelper 的用户可见错误信息走 `Localizable.xcstrings`。

---

### 🟢 P1-1：WhisperKit 重启竞态（资源泄漏）

- **文件**：`TransFlow/TransFlow/Services/WhisperKitSpeechEngine.swift`
- **问题**：`processStream` 内的 `Task { ... }`（line 64）未存储为实例属性，不可取消。`stopListening()` → `listeningTask?.cancel()` 传不到引擎内部 Task。快速重启时旧引擎的 Task 会泄漏运行（直到音频流排空），浪费 CPU/内存。
- **影响**：资源泄漏，非数据损坏（各引擎实例有独立 WhisperKit）。
- **修法**：
  1. 引擎新增 `private var processingTask: Task<Void, Never>?` 实例属性。
  2. `processStream` 开头 `processingTask = Task { ... }`。
  3. 新增 `func stop() { processingTask?.cancel() }`。
  4. 调用方（TransFlowViewModel）在 `stopListening` 时调 `engine.stop()`（若有引擎引用）。
- **风险**：低-中。需确认调用方持有引擎引用。Swift 6 下 `var` 属性存 non-Sendable Task 需注意隔离（可能需 `nonisolated(unsafe)` 或 actor 化）。
- **验证**：快速 start→stop→start 三次，用 Activity Monitor 观察 CPU 是否回落。

---

## 三、可排期改进（P2/P3，非紧急）

以下有价值但不阻塞，建议按需排期：

| 编号 | 问题 | 建议 | 难度 |
|------|------|------|------|
| R1-P2 | AsyncStream fan-out 背压 | 慢消费者阻塞全部；增大 buffer 或独立背压 | 中 |
| R3-P1 | TransFlowViewModel 过大(~890行) | 提取 DiarizationCoordinator / SessionPersistenceController | 中 |
| R3-P2 | audioLevel 触发~30Hz | `@ObservationIgnored` 或 throttle 到 10Hz | 低 |
| R3-P3 | SettingsView 嵌套过深 | 提取子视图 | 低 |
| R4-P2 | JSONLStore writeHandle 无 close | 加 `closeSession()` + atexit | 低 |
| R4-P3 | VideoJSONLStore 与 JSONLStore 重复 | 提取基类/协议扩展 | 中 |
| R5-P1 | 麦克风权限撤销未检测 | `startListening` 每次检查 | 低 |
| R5-P2 | WhisperKit 模型损坏未检测 | 校验关键文件完整性（hash/size） | 低 |
| R6-P2 | NLEmbedding 线性检索 | 大知识库考虑向量索引/缓存 | 中 |
| R8-P1 | TransFlowViewModel 零单测 | 为 assignSpeaker / backfillSpeakerIds 加测试 | 中 |
| R8-P2 | CloudASRService 不可测试 | protocol-based URLSession 注入 | 中 |
| R9-P2 | AppSettings 单例耦合 | 改为可注入 ObservableObject | 高 |
| R10-P1 | nonisolated(unsafe) 残留 | WhisperKit 非 Sendable 的客观约束，短期难消 | 高 |
| R10-P3 | 硬编码英文残留 | `genstrings` 扫描 + 补 `Localizable.xcstrings` | 低 |

---

## 四、建议执行顺序

1. **P0-1 滑窗去重** ← 现在修，改动小、直接降 WER、可用基准量化
2. **P0-2 API Key Keychain** ← 尽快修，安全问题
3. **P1-1 重启竞态** ← 排期修，资源泄漏
4. P2/P3 按需排期

> 每项修复后跑 `bash scripts/verify-build.sh` 确认通过；P0-1 额外跑 AccuracyBenchmarks 量化 WER 变化，记入 `metrics/accuracy-ledger.md`。
