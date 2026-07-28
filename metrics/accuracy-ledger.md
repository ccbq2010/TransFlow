# TransFlow 识别率迭代台账（Accuracy Ledger）

> 由自主迭代 Agent 自动追加。人类可读摘要；机器可读明细见同目录 `wer-results.jsonl`。
> 每条实验一行 JSON，schema：
> `{"run_id","timestamp","git_sha","model","engine","dataset","wer","cer","avg_latency_ms","status","hypothesis","reference","notes"}`

## 汇总表

| 实验 | WER before | WER after | Δ | 状态 | 备注 |
|---|---|---|---|---|---|
| Sprint#1 建立 WER/CER 基准 harness | - | 待测 | - | pending | 基准 v0 待在用户终端运行 AccuracyBenchmarks 取数（见下） |
| Sprint#1 上下文偏置（context biasing） | 待测 | 待测 | - | pending | 代码已落地；默认无热词时行为不变，需配合热词 + 基准评测量化 |

---

## 实验记录（倒序）

### 2026-07-28 Sprint#1 — 建立 WER/CER 评测基准 + 上下文偏置

**目标**：落地 `docs/autonomous-improvement.md` 提示词 A（基准）与提示词 B 第 2 步（上下文偏置），为后续"自动测试→迭代→记录→修复"闭环打地基。

**改动（均已写入仓库，待用户终端构建验证）**：

1. **WER/CER 计算器（纯 Swift，无依赖）** — `TransFlowTests/Utilities/WERCalculator.swift`
   - 词级 Levenshtein（WER，英文）+ 字级 Levenshtein（CER，中文），含 S/I/D 明细与回溯统计。
   - 归一化：小写、英文去标点、中文保留字、折叠空白（符合提示词 A 规则）。
   - 单测 `TransFlowTests/WERCalculatorTests.swift`（20 例：完美/替换/插入/删除/中文 CER/大小写/标点/空串/格式化），随 `verify-build.sh` 跑。

2. **上下文偏置（docs 旋钮 #3，原"从未传 prompt"缺口）** — `TransFlow/Services/WhisperKitSpeechEngine.swift`
   - 新增 `contextPromptText()`（@MainActor）：从 `AppSettings.hotwords` 取标准词拼接。
   - 新增 `buildDecodeOptions(languageCode:whisperKit:promptText:)`：用 `whisperKit.tokenizer.encode(text:)` tokenize 为 `DecodingOptions.promptTokens`，引导解码器偏向领域词、降低专有名词误识。
     - 关键点：`WhisperTokenizer` 协议仅暴露 `encode(text:)`（含 special tokens）；`TextDecoder` 解码时会自动 `filter { $0 < specialTokenBegin }` 去掉 special token 并 `suffix(maxPromptLen)` 截断，故无需手动处理。
   - 重构：抽出 `loadWhisperKit()`（含 90s ANE 编译硬超时，原内联逻辑原样搬迁）与 `buildDecodeOptions`，消除流式窗口/尾部两处 `DecodingOptions` 重复构造。流式路径行为不变（默认无热词 → promptTokens=nil）。
   - 新增 `transcribeWholeFile(_ audio: [Float]) async throws -> String`：离线整段转写，复用同一加载与 DecodingOptions，供 AccuracyBenchmarks 批量评测。

3. **评测集** — `TransFlowTests/Resources/eval/`
   - `manifest.json` + `jfk.wav`（真实英文人声，公有领域）+ `jfk.ref.txt`（已知黄金转录）→ 英文 WER 基线 case。
   - `zh_sample.wav`（macOS TTS Tingting 合成，标注 `synthetic:true`）+ `zh_sample.ref.txt` → 中文 CER 冒烟（不计入代表性 WER）。
   - ⚠️ 当前仅冒烟级；需补充真实噪声/多人场景参考转录才能得到代表性 WER。

4. **AccuracyBenchmarks 评测 harness** — `TransFlowTests/AccuracyBenchmarks.swift`
   - 读 manifest → 逐 case 加载音频（任意格式→16kHz mono Float32）→ `transcribeWholeFile` → 算 WER/CER → append `metrics/wer-results.jsonl`。
   - 模型未下载时 **明确 XCTSkip**（非静默通过）；转写失败记 `status=failed`；宽松 sanity 断言（真实 case 聚合 WER<60%，仅捕获"模型彻底失效"，非质量门禁）。

5. **质量门禁** — `scripts/verify-build.sh`
   - 测试步加 `-skip-testing:TransFlowTests/AccuracyBenchmarks`：基准需模型且较慢，单独用 `-only-testing` 跑；WERCalculator 单测仍随门禁跑。

**结论 / 状态**：代码已落地并经人工审查（含 WhisperKit API 核对：`promptTokens` 协议方法、`TextDecoder` 自动去 special token）。

**✅ 编译验证（本环境用 `swiftc -typecheck` 绕过 sandbox-exec 完成）**：
本环境 `sandbox-exec` 被禁，`xcodebuild`/`swift build` 都跑不了；但 `swiftc`（裸编译器）不依赖 sandbox-exec。用预构建的 `build/Debug/.../WhisperKit.swiftmodule`/`FluidAudio.swiftmodule` + Clang modulemap + `libObservationMacros.dylib` 作依赖，对**整个 app target（68 个源文件，含改动后的 `WhisperKitSpeechEngine.swift`）做 `swiftc -typecheck`**：
- `WERCalculator.swift`：独立 typecheck **0 error**，确认编译通过。
- `WhisperKitSpeechEngine.swift`（新增 `loadWhisperKit`/`buildDecodeOptions`/`contextPromptText`/`transcribeWholeFile`）：整模块 typecheck **这些新方法 0 error**。唯一报错在**未改动的 `init` 第 44 行**（`modelName: String = WhisperKitModelManager.defaultModelName` 的 default value，"main actor-isolated default value in a nonisolated context"）——这是 swiftc 与 xcodebuild 在「`@MainActor` 类型上 `static let` 字面量是否算 non-isolated 全局常量」上的判定差异；**该 init 在用户 xcodebuild 下今日 20:14 已成功编译出 `.o`**（`build/Debug/.../WhisperKitSpeechEngine.o`），证明 xcodebuild 下能过，属本环境 swiftc 的误报，非本次改动引入。
- `WERCalculatorTests.swift`：WERCalculator API 用法正确；手搓 swiftc 下 XCTest 符号无法解析（tooling 限制，非代码问题）。
- `AccuracyBenchmarks.swift`：依赖新增的 `transcribeWholeFile`，无法对旧 TransFlow 模块 typecheck；已人工审查（AVFoundation/JSONEncoder/XCTest 标准用法）。

**⚠️ 仍需用户终端完成：完整 xcodebuild + 基线 WER 测量**（`xcodebuild`/`swift build` 本环境被 sandbox-exec 挡住，无法跑测试/出 jsonl）。请在终端执行：

```bash
# 1) 质量门禁（build + 单测，跳过基准）
bash scripts/verify-build.sh

# 2) 跑识别率基准（产出 metrics/wer-results.jsonl + 基线 WER/CER）
cd TransFlow && xcodebuild test -scheme TransFlow -destination 'platform=macOS' -configuration Release \
  -only-testing:TransFlowTests/AccuracyBenchmarks
```

跑完后把 `metrics/wer-results.jsonl` 末行的聚合 WER 回填到本表"基准 v0"行，作为后续实验对照。

**下一步（提示词 B 剩余旋钮，每项单变量实验 + 基准量化后再决策保留/回退）**：
1. VAD 升级：`VADService`（RMS 阈值 0.01，粗糙）→ Silero VAD (Core ML)；或先接入 WhisperKit 自带 `EnergyVAD`/`VoiceActivityDetector`（已在 `.local-packages/WhisperKit`，未启用）。预期：长静音段幻觉下降。
2. 解码门禁网格搜索：`compressionRatioThreshold∈{1.8,2.0,2.4,2.8}` × `logProbThreshold∈{-0.8,-1.0,-1.2}` × `noSpeechThreshold∈{0.5,0.6,0.7}` × `temperatureFallbackCount∈{3,5}`。
3. 滑窗实验：`whisperWindowSeconds∈{20,30,40}` × `whisperSlideSeconds∈{3,5,10}`。
4. 模型/量化：`large-v3_turbo` Q8 vs Q4 / 更大模型（受内存/延迟约束）。
5. 音频预处理：喂 WhisperKit 前做增益归一化/降噪（`AudioCaptureService` 出口或窗口级）。
6. 后处理升级：`HotwordCorrector` 朴素子串替换 → 词表+上下文感知纠错（可结合 prompt）。
7. 上下文偏置效果量化：设定一批领域热词后，对比有/无 `promptTokens` 的 WER（本轮代码已支持，缺数据）。

**反模式提醒（来自提示词 8）**：不要在没有 `wer-results.jsonl` 数字的情况下声称"识别率提高"；不要用极短/极干净合成音频刷分；一次只改一个旋钮。
