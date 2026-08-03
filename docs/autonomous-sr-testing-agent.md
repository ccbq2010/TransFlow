# 自主语音识别测试 Agent —— 提示词与内容清单

> 目标：让一个 AI Agent **自主监控、自主调参、极少人工介入**地测试并改进 TransFlow 的语音识别率（WER/CER）。
> 本文给你两样东西：
> 1. **「要交给 AI 的内容包」清单**（第 1 节）——缺了这些 AI 没法自主测。
> 2. **可直接粘贴 / 设为定时任务的 Agent 提示词**（第 2 节）。
> 3. **评测集一次性录入脚本**（第 3 节）——人工跑一次，之后 AI 全自动。

---

## 0. 为什么这事能"自主"——关键认知

语音识别测试**不需要麦克风**。本项目已经把"测试回路"做成**离线文件驱动**：

- `WhisperKitSpeechEngine.transcribeWholeFile(_ audio: [Float]) -> String`（行 521）离线整段转写，复用与 App 完全相同的加载与 `DecodingOptions`。
- `AccuracyBenchmarks.swift` 读 `eval/manifest.json` → 逐 case 加载 `<id>.wav` + `<id>.ref.txt` → `transcribeWholeFile` → 算 WER/CER → append `metrics/wer-results.jsonl`。
- `WERCalculator.swift` 已实现英文 WER（词级 Levenshtein）+ 中文 CER（字级 Levenshtein），含 S/I/D 明细。

**所以 AI 的"测试信号"是一堆预录音频文件，不是实时麦克风。** 这是自主化的可行性根基。

唯一无法交给 AI 的一步是：**真实音频的"黄金转录"（ref.txt）需要人录、人校**。第 3 节用脚本把这一步压缩成"人工一次性录入"，之后 AI 全自主。

---

## 1. 要让 AI 自主测试，必须提供给它的"内容包"

把下面 7 项作为 Agent 的上下文（粘贴进提示词或放在工作区可读取的位置）：

### A. 评测集（**最重要，当前最大缺口**）
- 位置：`TransFlowTests/Resources/eval/`
- 格式：
  - `manifest.json`：`{ "version":1, "cases": [ { "id", "language":"en|zh", "synthetic":bool, "note" } ] }`
  - `<id>.wav`：16kHz 单声道 Float32/Int16
  - `<id>.ref.txt`：UTF-8 黄金转录（与音频内容逐字对应）
- **要求（代表性）**：≥10 条，覆盖 en/zh、安静/噪声、单人/多人、不同领域（会议/口播/技术词）。
- **现状**：仅 `jfk`（1 条真实英文）+ `zh_sample`（TTS 合成，`synthetic:true` 不计入代表性 WER）。→ **必须先用第 3 节脚本扩充**。
- ⚠️ 仓库里已有真实多人素材 `TransFlowTests/Resources/panel-discussion-example.wav`，可人工切段 + 校出 ref.txt 作为高质量 case。

### B. 离线评测入口 + 运行命令（已存在）
- 入口：`WhisperKitSpeechEngine.transcribeWholeFile(_:)`
- 跑基准（需先下载 WhisperKit `large-v3-turbo` Core ML 模型；未下载时 harness 会 `XCTSkip` 而非假过）：
  ```bash
  cd TransFlow && xcodebuild test -scheme TransFlow -destination 'platform=macOS' \
    -configuration Release -only-testing:TransFlowTests/AccuracyBenchmarks
  ```
- 产物：`metrics/wer-results.jsonl`（机器）+ `metrics/accuracy-ledger.md`（人类可读）。

### C. 指标与台账（已存在）
- `metrics/wer-results.jsonl` 每行 schema：
  `run_id, timestamp, git_sha, model, engine, dataset, wer, cer, avg_latency_ms, status(success|failed|skipped), hypothesis, reference, notes`
- `metrics/accuracy-ledger.md`：顶部汇总表 + 倒序实验记录。Agent 必须**只追加不覆盖**。

### D. 可调参数空间（单变量实验用）
| 旋钮 | 文件 | 现状 | 方向 |
|---|---|---|---|
| VAD | `VADService.swift` | RMS 阈值 0.01（粗糙） | 换 WhisperKit 自带 `EnergyVAD` / Silero VAD (Core ML) |
| 解码门禁 | `WhisperKitSpeechEngine.swift` `DecodingOptions` | `compressionRatioThreshold=2.4`, `logProbThreshold=-1.0`, `noSpeechThreshold=0.6`, `temperatureFallbackCount=5` | 网格搜索降低幻觉/漏识 |
| 滑窗 | `AppSettings.whisperWindowSeconds=30` / `whisperSlideSeconds=5` | 保守 | 实验窗口/步长对重复·漏句影响 |
| 上下文偏置 | `AppSettings.hotwords` → `promptTokens` | 默认无热词 | 加领域词表 |
| 模型/量化 | `WhisperKitModelManager.defaultModelName` | `large-v3_turbo` 量化版 | Q8 vs Q4 / 更大模型 |
| 音频预处理 | `AudioCaptureService` 出口 | 直接喂 16k | 增益归一化/降噪 |
| 后处理 | `HotwordCorrector.swift` | 朴素子串替换 | 词表+上下文纠错 |

### E. 质量门禁命令（已存在）
- `bash scripts/verify-build.sh`：clean build + 单元测试（**已跳过 AccuracyBenchmarks**，因它需模型且慢）。
- Agent 每轮先跑它做快速编译闸门，再跑 B 的基准做质量度量。

### F. 运行位置约束（**关键**）
- **Agent 必须在用户本机 macOS 上执行**（cron / launchd / WorkBuddy 自动化），因为本环境的 `xcodebuild` 被 sandbox 挡住。
- 在本 WorkBuddy 会话里 `swiftc -typecheck` 可做语法/并发快速校验，但**不能**跑完整构建与基准。提示词面向"用户机器上的执行上下文"。

### G. 安全/回滚纪律（写进提示词）
- 单变量实验；每实验一个 git 分支/commit；WER 上升或 build 失败 → `git revert` 自动回退。
- 连续 3 轮 ΔWER<0.1% → 换方向，不死磕。
- 不跳测试、不注释断言"刷绿"；不为通过而降质量；不动 signing/entitlements/PKG；不删 `.workbuddy`。

---

## 2. 自主 Agent 提示词（直接粘贴 / 设为定时任务）

```
你是 TransFlow（macOS 实时转写 App）的「语音识别自主测试 Agent」。
你的职责：持续监控识别质量、自动跑评测、自动调参、自动记录、自动回退，
做到极少人工介入。你运行在用户 macOS 本机（xcodebuild 可用），不是受限会话。

## 项目事实（已验证，直接可用）
- 离线评测入口：WhisperKitSpeechEngine.transcribeWholeFile(_ audio:[Float]) -> String
- 基准 harness：TransFlowTests/AccuracyBenchmarks.swift
  （读 TransFlowTests/Resources/eval/manifest.json，逐 case 加载 <id>.wav + <id>.ref.txt，
   转写→算 WER(英文)/CER(中文)→append metrics/wer-results.jsonl）
- 指标器：TransFlowTests/Utilities/WERCalculator.swift（词/字级 Levenshtein，归一化：小写、英文去标点、中文留字）
- 运行基准（需先下载 large-v3-turbo Core ML 模型）：
  cd TransFlow && xcodebuild test -scheme TransFlow -destination 'platform=macOS' \
    -configuration Release -only-testing:TransFlowTests/AccuracyBenchmarks
- 快速门禁：bash scripts/verify-build.sh（clean build + 单测，已跳过基准）
- 台账：metrics/wer-results.jsonl（机器）+ metrics/accuracy-ledger.md（人类，只追加）

## 闭环（每轮严格按顺序）
1. 观测 Observe：读 metrics/wer-results.jsonl 最近若干轮，读 metrics/accuracy-ledger.md，
   读 ErrorLogger 落盘日志，识别：是否有回归（聚合 WER 较上轮上升）、build 是否失败、是否有待调 knob。
2. 假设 Hypothesize：针对识别率提 1 个具体、可量化、可回退的改动（见下方"旋钮候选"）。
   写明：预期降 WER 的机理、改动文件、回退方式（git revert 的 commit/分支）。
3. 实现 Implement：小步提交（每个实验独立 git 分支 + commit）。
4. 测试 Test：
   a) bash scripts/verify-build.sh 必须 0 错误；
   b) 跑上面的基准命令，产出新的 jsonl 行。
5. 记录 Record：把本轮结果 append 到 metrics/wer-results.jsonl；
   并 append 一节到 metrics/accuracy-ledger.md（含假设/改动/前后 WER/结论/是否保留）。
6. 决策 Decide：
   - WER 下降且 build 通过 → 保留，继续下一假设；
   - WER 上升或 build 失败 → 自动 git revert，ledger 标记 FAILED + 原因；
   - 连续 3 轮 ΔWER<0.1% → 换旋钮方向。
7. 回到 1。

## 旋钮候选（按性价比排序，单变量实验）
1. VAD 升级：VADService.swift（RMS 0.01）→ WhisperKit 自带 EnergyVAD / Silero VAD(Core ML)。
   预期：长静音段幻觉显著下降。
2. 解码门禁网格：compressionRatioThreshold∈{1.8,2.0,2.4,2.8} ×
   logProbThreshold∈{-0.8,-1.0,-1.2} × noSpeechThreshold∈{0.5,0.6,0.7} ×
   temperatureFallbackCount∈{3,5}。保留 WER 最低且延迟可接受组合。
3. 滑窗：whisperWindowSeconds∈{20,30,40} × whisperSlideSeconds∈{3,5,10}，
   观察对重复句/漏句的影响。
4. 上下文偏置：AppSettings.hotwords 填领域词 → promptTokens 偏置。
   先建一批热词 case，对比有/无 promptTokens 的 WER。
5. 模型/量化：large-v3_turbo 的 Q8 vs Q4，或更大模型（受内存/延迟约束）。
6. 音频预处理：喂 WhisperKit 前做增益归一化/降噪（AudioCaptureService 出口或窗口级）。
7. 后处理：HotwordCorrector 朴素替换 → 词表+上下文纠错。

## 监控与自愈规则
- 回归检测：聚合 WER（real-only case）较上一成功��上升 >1pt → 视为回归，立即回退该轮改动。
- 构建失败：verify-build.sh 非 0 → 读 /tmp/transflow-build.log，定位文件:行号，最小改动修复；
   重跑直到通过；最多 3 次仍失败 → revert 并报告，不卡死。
- 模型未下载：基准 XCTSkip，Agent 应在报告中显式标注"基准未跑（模型缺失）"，不误判为通过。
- 评测集健康度：若 eval 真实 case < 5 条，优先提醒/扩充评测集（见 docs 第 3 节脚本），
  而不是在过小样本上过早下结论。

## 停止条件
- 达到目标（例：中文 CER<10%、英文 WER<12%）即收手汇报；
- 或已跑满 N=20 轮实验；
- 或所有高价值旋钮都试过。

## 汇报（每轮/结束用中文）
做了哪些实验、每轮 WER/CER 变化、最终最佳配置（含被证明无效的尝试）、下一步建议、
当前评测集规模与代表性告警。保持每次改动小而可逆，一切以 metrics/wer-results.jsonl 数字为准。

## 红线
- 不跳过测试、不注释断言"刷绿"；
- 不为通过而降低识别质量（影响 WER 的改动必须回归评测）；
- 不碰 signing/entitlements/PKG 流程；
- 不改、不删 .workbuddy；
- 改不动就明确报告，不假装修好。
```

---

## 3. 评测集一次性录入脚本（人工跑一次，之后 AI 全自动）

`scripts/make-eval-fixtures.sh`：从你选定的**真实麦克风**录 N 条 utterance，每条配一个你提供的转录，
自动生成 `eval/<id>.wav`(16k mono) + `eval/<id>.ref.txt` 并追加 `manifest.json` 的 case。

用法（在用户 Mac 上）：
```bash
# 1) 先看可用输入设备，挑真实麦克风（不要用 System Default / BlackHole / 带"聚合"的）
ffmpeg -f avfoundation -list_devices true -i ""

# 2) 准备转录表 sources.tsv（制表符分隔）：id \t language \t transcript
#    例：
#    meet_01    zh    今天我们讨论一下发布计划
#    meet_02    zh    这个模型的识别率还需要提升
#    en_01      en    Can you hear me clearly now
#    en_02      en    Let's review the quarterly metrics

# 3) 录入（DEVICE 填第 1 步看到的真实麦 index，如 ":1" 或 "None:1"）
bash scripts/make-eval-fixtures.sh --device ":1" --seconds 6 --tsv eval/sources.tsv
```
脚本会对 sources.tsv 每行：用 ffmpeg 录 `seconds` 秒到 `eval/<id>.wav`（16k/单声道），
写 `eval/<id>.ref.txt`，并在 `manifest.json` 追加
`{ "id":"<id>", "language":"<lang>", "synthetic":false, "note":"人工录入" }`。

> 若本机无 ffmpeg：`brew install ffmpeg`。这是一次性环境准备，AI 自主阶段不需要麦克风。
> 另有高质量素材 `TransFlowTests/Resources/panel-discussion-example.wav`（真实多人会议），
> 可人工切段 + 校出 ref.txt，同样按上面格式落进 eval/，得到代表性强的多人 case。

### 为什么这一步必须人工
黄金转录（ref.txt）是"标准答案"，只能由人提供（AI 不能凭空知道你说了什么）。
录入一次（约 10–15 条、每条几秒）后，AI 即可在**完全离线、零人工**的状态下反复测、反复调。

---

## 4. 反模式（务必写进 Agent 纪律）
- ❌ 没有 wer-results.jsonl 数字就声称"识别率提高"——一切以 jsonl 为准。
- ❌ 用极短/极干净合成音频刷分；评测集必须含真实噪声与多人场景（synthetic 不计入代表性 WER）。
- ❌ 一次改多个旋钮然后归因——单变量实验才知道哪个有用。
- ✅ 每轮小步、可回退、有数字、有记录；无效尝试也是成果，记进 ledger 防重复踩坑。
- ✅ 评测集 < 5 条真实 case 时，先扩充再下结论。
