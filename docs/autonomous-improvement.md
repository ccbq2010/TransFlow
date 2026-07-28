# TransFlow 自主迭代 Agent 提示词包（Autonomous Improvement Prompts）

> 用途：把下面任意一段提示词粘贴给编程 Agent（WorkBuddy / Claude Code / Codex / Cursor 等），
> 让它**自主**地改进 TransFlow，尤其是**提高语音识别率（WER/CER）**，并实现
> **自动测试 → 自动迭代 → 自动记录 → 自动修复** 的闭环。
>
> 所有提示词都基于本仓库真实代码，可直接用，不需要你改任何东西。
> 命令示例基于本机 macOS + Xcode（`scripts/verify-build.sh` 已存在）。

---

## 0. 先用一句话理解现状（给 Agent 的上下文）

TransFlow 是一个 macOS 实时字幕/转写 App，识别走两条引擎：

- **WhisperKit**（本地大模型，主路径）：`TransFlow/TransFlow/Services/WhisperKitSpeechEngine.swift`
- **Apple Speech**（系统引擎）：`TransFlow/TransFlow/Services/SpeechEngine.swift`

影响**识别率**的真实旋钮（已在代码里，Agent 应优先动这些）：

| 旋钮 | 位置 | 现状 | 改进方向 |
|---|---|---|---|
| 解码质量门禁 | `WhisperKitSpeechEngine.swift:207-219` `DecodingOptions` | `compressionRatioThreshold=2.4`, `logProbThreshold=-1.0`, `noSpeechThreshold=0.6`, `temperatureFallbackCount=5` | 调阈值降低幻觉/漏识 |
| VAD（静音过滤） | `VADService.swift` | **能量/RMS 阈值 0.01，很粗糙**；注释明说"可升级 Silero VAD" | 换成 Silero VAD（Core ML）→ 最大杠杆 |
| 上下文偏置 | 未使用 | 引擎从没传 `prompt`/`initial_prompt` | 加领域词表 `prompt` 做 context biasing |
| 滑窗 | `AppSettings.whisperWindowSeconds`=30 / `whisperSlideSeconds`=5 | 偏保守 | 实验更优窗口/步长 |
| 模型 | `WhisperKitModelManager.defaultModelName` | `large-v3_turbo` 量化版 | 试更大模型 / 不同量化（Q8 vs Q4） |
| 后处理纠错 | `HotwordCorrector.swift` | 朴素子串替换 | 升级为上下文感知纠错 / 自定义词表 |
| 音频预处理 | `AudioCaptureService`/`AudioRecordingService` | 直接喂 16k | 加增益归一化/降噪 |
| 说话人分离 | `diarizationSensitivity` + FluidAudio | 0.8 | 调聚类阈值降 DER |

**最大缺口**：仓库**没有 WER/CER 评测基准**（accuracy benchmark harness），
所以"自动测试识别率"目前做不到。第一个提示词会先让 Agent 把这个基准搭起来。

---

## 1. 总控提示词（Master Prompt）—— 一次性粘贴即可跑闭环

> 复制下面整段给 Agent。它会自己建基准、跑循环、记录、修复。

```
你是 TransFlow（macOS 实时转写 App）的自主改进 Agent。目标：持续提高语音识别率（WER/CER），
并做到自动测试、自动迭代、自动记录、自动修复。遵守以下规则：

## 项目约束（来自 AGENTS.md，违反即失败）
- 只改 TransFlow 源码；发布一律走 ./scripts/build-pkg.sh（PKG-only），不要动签名/entitlements。
- 所有用户可见字符串必须进 Localizable.xcstrings（key 形如 模块.描述），且同时提供 en 与 zh-Hans。
- 任何改动后必须保证 `bash scripts/verify-build.sh` 通过（clean build + xcodebuild test）。
- 不要删、不要改 .workbuddy 目录；不要做不可逆的破坏性操作。

## 你的闭环（每轮都严格按这个顺序）
1. 观测（Observe）：读 metrics/wer-results.jsonl（若不存在则先建，见第 2 条）。读 ErrorLogger 日志与最近测试失败。
2. 假设（Hypothesize）：针对识别率，提出 1 个具体、可量化、可回退的改动（例如"把 VADService 换成 Silero VAD Core ML"）。
   写清：预期降低 WER 的机理、改动文件、回退方式。
3. 实现（Implement）：小步提交（每实验一个 git 分支/commit）。
4. 测试（Test）：先 `bash scripts/verify-build.sh`；再跑识别率基准
   `xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
     -only-testing:TransFlowTests/AccuracyBenchmarks`（或你新建的基准目标）。
5. 记录（Record）：把本轮结果 append 到 metrics/wer-results.jsonl，字段见第 3 条；并 append 一段人类可读摘要到 metrics/accuracy-ledger.md。
6. 决策（Decide）：
   - WER 下降且 build 通过 → 保留，继续下一假设；
   - WER 上升或 build 失败 → 自动回退（git revert / checkout），在 ledger 标记 FAILED 与原因；
   - 连续 3 轮无改进（ΔWER<0.1%）→ 换方向，不要死磕同一旋钮。
7. 回到 1。

## 停止条件
- 达到目标 WER（例如中文 CER<8%、英文 WER<10%）即收手汇报；
- 或已跑满 N=20 轮实验；
- 或所有高价值旋钮都试过。

## 汇报
结束时用中文给一段总结：做了哪些实验、每轮 WER 变化曲线、最终最佳配置（含被证明无效的尝试）、下一步建议。
不要改动业务逻辑之外的东西，保持每次改动小而可逆。
```

---

## 2. 提示词 A —— 先搭"识别率自动测试"基准（WER/CER harness）

> 没有这个，后面所有"自动测试/自动迭代"都是空话。先让 Agent 建它。

```
在 TransFlow 里新建一个可重复运行的识别率评测基准（WER for 英文 / CER for 中文），
用于自动衡量 WhisperKitSpeechEngine 的输出质量。要求：

## 输入
- 评测集目录 Tests/Resources/eval/，内含若干 <id>.wav（16k mono）和对应的 <id>.ref.txt（标准转录，UTF-8）。
- 你可以用 `AudioExtractorService` 从仓库已有的示例（如 panel-discussion-example.wav）切出几条，
  并**人工校对**出 .ref.txt 作为黄金标准（至少 5 条，覆盖安静/噪声/多人场景）。
- 若没有现成音频，生成一个简单合成集（用系统 say 命令 TTS 生成 wav + 已知文本）做冒烟测试。

## 实现
- 新增 Swift 测试目标或可执行 target `TransFlowBenchmark`，复用 `WhisperKitSpeechEngine` 的转写逻辑
  （建议把 processStream 核心抽成一个纯函数 `transcribe(audio: [Float], locale:) -> String`，便于离线批量跑）。
- 计算 WER/CER：对英文按词做 Levenshtein（编辑距离 / 参考词数）；对中文按字做 CER。
  归一化：小写、去首尾空格、英文去标点；中文保留字。
- 输出 JSON 到 metrics/wer-results.jsonl，每行一条：
  {"run_id","timestamp","git_sha","model","engine","dataset","wer","cer","avg_latency_ms","hyp_sample","ref_sample"}

## 验证
- `xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
   -only-testing:TransFlowTests/AccuracyBenchmarks` 能通过并产出 jsonl。
- 在 metrics/accuracy-ledger.md 写"基准 v0 建立：基线 WER=xx%"。
- 不要为了跑通而降低质量要求；模型加载失败要明确报错而不是静默跳过。
```

---

## 3. 提示词 B —— 识别率冲刺（核心：降低 WER）

> 这是你最想要的。它让 Agent 专门冲识别率，且每次改动都被基准量化。

```
针对 TransFlow 的 WhisperKit 识别率做一次冲刺，目标是降低 WER/CER。
按"总控提示词"的闭环执行，但本轮只聚焦识别质量。优先按以下顺序实验（每个单独成轮，量化对比）：

1. VAD 升级：把 VADService.swift 的能量阈值法换成 Silero VAD（Core ML，可在 .local-packages 或
   社区 Core ML 模型里找；若找不到现成 Swift 包，先用 WhisperKit 自带的 VAD/或 onnx 推理封装）。
   预期：长静音段幻觉显著下降，WER 下降。
2. 上下文偏置：在 WhisperKitSpeechEngine 的 DecodingOptions 里加入 `prompt`
   （initial prompt），内容来自 AppSettings.hotwords 与视频场景词表
   （videoSourceLanguage / videoTargetLanguage 相关领域词）。预期：专有名词误识下降。
3. 解码门禁调参：系统网格搜索 compressionRatioThreshold∈{1.8,2.0,2.4,2.8}、
   logProbThreshold∈{-0.8,-1.0,-1.2}、noSpeechThreshold∈{0.5,0.6,0.7}、
   temperatureFallbackCount∈{3,5}。保留使 WER 最低且延迟可接受的组合。
4. 滑窗实验：whisperWindowSeconds∈{20,30,40}、whisperSlideSeconds∈{3,5,10}，测对 WER 与重复/漏句的影响。
5. 模型/量化：试 large-v3_turbo 的 Q8 vs Q4，以及是否上更大模型（受内存/延迟约束）。
6. 音频预处理：在喂给 WhisperKit 前做增益归一化与简单降噪（AudioCaptureService 出口处），测 WER。
7. 后处理升级：把 HotwordCorrector 从朴素替换升级为基于词表+上下文的纠错（可结合 prompt）。

每轮：实现 → `bash scripts/verify-build.sh` → 跑基准（提示词 A 的产物）→ 记录到 metrics/wer-results.jsonl。
无效改动立即回退。汇报时给出"旋钮 → WER 变化"对照表，并指出哪几个组合叠加后最优。
```

---

## 4. 提示词 C —— 自动记录测试结果（结果台账）

> 让 Agent 把"自动记录"标准化，方便你以后回溯和做图表。

```
为 TransFlow 建立并维护一个自动测试结果台账，规则如下：

## 机器可读
- 文件：metrics/wer-results.jsonl（每行一条 JSON，schema 见提示词 A）。
- 每次实验（无论成功失败）都必须 append 一行，包含 run_id / timestamp / git_sha /
  model / engine / dataset / wer / cer / avg_latency_ms / status(success|failed|reverted) / hypothesis / notes。
- 如果 build 失败，也记一行 status=failed，notes 写失败原因（来自 scripts/verify-build.sh 的日志 /tmp/transflow-build.log）。

## 人类可读
- 文件：metrics/accuracy-ledger.md，按时间倒序 append 小节，例如：
  ### 2026-07-28 Sprint#3 — Silero VAD
  - 假设：换 VAD 降低静音段幻觉
  - 改动：VADService.swift（PR #xx）
  - 结果：WER 12.4% → 9.1%（-3.3pt），延迟 +8ms
  - 结论：保留
- 顶部维护一张汇总表：实验 | WER before | WER after | Δ | 状态。

## 约束
- jsonl 与 md 都只追加，不覆盖历史。
- 用 git 跟踪这两个文件，每次 sprint 结束 commit 一次。
- 若 metrics/ 不存在则创建。
```

---

## 5. 提示词 D —— 自动修复（从失败/日志反推）

> 让 Agent 在测试失败或运行报错时自己定位并修，而不是卡住等你。

```
当 TransFlow 的构建或测试失败，或运行期 ErrorLogger 抓到错误时，自动诊断并修复。规则：

## 触发
- `bash scripts/verify-build.sh` 退出非 0；或
- `xcodebuild test` 有 failed 用例；或
- ErrorLogger 日志（运行时）出现未处理异常/转写中断。

## 流程
1. 读日志：构建看 /tmp/transflow-build.log，测试看 /tmp/transflow-test.log，运行期读 ErrorLogger 落盘。
2. 定位：用报错符号/文件:行号 grep 源码，确认根因（编译错误 / 测试断言 / 运行时崩溃）。
3. 修复：最小改动解决根因；不要顺手重构无关代码；不要改 signing/entitlements/PKG 流程。
4. 验证：重跑 `bash scripts/verify-build.sh` 直到通过；若修复引入新失败，回到 2（最多 3 次，仍不行就 revert 并报告）。
5. 记录：把"故障现象 → 根因 → 修复 → 验证结果"append 到 metrics/accuracy-ledger.md 的 [AUTO-FIX] 小节，
   并视情况补一条单元测试防止回归。

## 红线
- 不跳过测试、不注释掉断言来"让绿"；
- 不因为修复而降低识别质量（若改动影响 WER，按提示词 B 的流程回归评测）；
- 改不动就明确报告，不要假装修好。
```

---

## 6. 把闭环变成"定时自动跑"（可选）

如果你想让 Agent **每天/每周**自动跑一轮改进（而不是每次手动粘贴），可以把它做成定时任务：
用自动化（Automation）工具，把"总控提示词（第 1 条）"设为定时触发的 prompt，
调度到本工作区 `TransFlow`，频率如 `FREQ=WEEKLY;BYDAY=MO` 或每天凌晨。
这样它会自己建基准、跑实验、写台账、修复，你只需看 metrics/accuracy-ledger.md 的周报。

---

## 7. 关键命令速查（给 Agent 用）

```bash
# 构建 + 全量测试（质量门禁）
bash scripts/verify-build.sh

# 只跑识别率基准（建好提示词 A 之后）
xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
  -only-testing:TransFlowTests/AccuracyBenchmarks

# Debug 配置更快，适合开发期冒烟
xcodebuild build -scheme TransFlow -destination 'platform=macOS' -configuration Debug

# 发布（PKG-only，按 AGENTS.md）
./scripts/build-pkg.sh
```

---

## 8. 注意事项 / 反模式

- ❌ 不要在没有 WER 基准的情况下声称"识别率提高了"——一切以 metrics/wer-results.jsonl 数字为准。
- ❌ 不要为了跑通基准而用极短/极干净的合成音频刷分；评测集必须包含真实噪声与多人场景。
- ❌ 不要一次改多个旋钮然后归因——单变量实验才能知道哪个旋钮有用。
- ✅ 每轮小步、可回退、有数字、有记录。
- ✅ 无效尝试也是成果，记进 ledger 避免重复踩坑。
```
