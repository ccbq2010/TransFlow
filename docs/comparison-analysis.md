# 语音识别方案对比分析：whisper-input-next-mac-kit vs TransFlow

## 结论先行（TL;DR）

**不建议替换。** whisper-input-next-mac-kit 的 `whisper.cpp` 方案对 TransFlow 来说是一种架构退化，无论从性能、集成度还是功能完整性看都是降级。但可以借鉴其辅助功能（本地 LLM 润色、冻结监控、录音指示器）。

---

## 1. 两个项目的基本定位

| 维度 | whisper-input-next-mac-kit | TransFlow |
|------|---------------------------|-----------|
| **本质** | 安装/补丁工具包（对上游 Python 项目打补丁） | 原生 macOS Swift 实时转写 App |
| **运行方式** | Python + `whisper-cli` 子进程，launchd 服务 | Swift 原生进程，GUI App |
| **交互方式** | 按键说话（push-to-talk），无 VAD | 持续流式 + 能量 VAD 自动切句 |
| **模型引擎** | `whisper.cpp`（C++，ggml 格式） | WhisperKit（Core ML，modelc 格式） |
| **模型格式** | `ggml-large-v3-turbo.bin`（~2GB） | `openai_whisper-large-v3_turbo_954MB`（Core ML 量化） |

---

## 2. 核心差异：whisper.cpp vs WhisperKit

### 2.1 技术栈完全不兼容

```
whisper-input-next-mac-kit:
   Python  →  subprocess.Popen("whisper-cli --model ggml-xxx.bin ...")
                                         ↑
                                  brew install whisper-cpp 安装的二进制

TransFlow:
   Swift   →  WhisperKit.transcribe(audioArray:) 
                                         ↑
                         Core ML .mlmodelc 文件（ANE 加速）
```

**要从 TransFlow 调用 whisper.cpp，必须：**
- 用 `Process`（`NSTask`）启动 `whisper-cli` 子进程
- 临时写 WAV 文件或通过 stdin 管道传输音频
- 解析 stdout 文本输出
- 管理子进程生命周期（启动开销、超时、崩溃恢复）

这种方案在 Swift App 中非常不优雅，且会引入大量额外复杂度。

### 2.2 性能对比

| 维度 | whisper.cpp | WhisperKit (Core ML) |
|------|------------|---------------------|
| **Apple Silicon 硬件加速** | 仅利用 CPU（可选 Metal 后端但不如 ANE） | 自动利用 ANE（Apple Neural Engine）+ GPU + CPU |
| **电量效率** | 较差的 CPU 密集型 | ANE 专为神经推理设计，功耗极低 |
| **模型体积** | ggml-large-v3-turbo ~2GB | openai_whisper-large-v3_turbo ~954MB（量化后） |
| **加载时间** | 二进制模型直接 mmap，较快 | Core ML 需首次编译 ANE 模型（约 90s 超时），但后续即时 |
| **推理速度** | 取决于 CPU 核心数 | ANE 推理，对于大模型通常更快 |

### 2.3 集成代价

**如果真的要替换，需要重写的部分：**

1. **`WhisperKitSpeechEngine.swift`** — 整个引擎（440 行）全部重写，改为调用 `whisper-cli` 子进程
2. **`WhisperKitModelManager.swift`** — 改为下载 ggml 模型而不是 Core ML 模型
3. **依赖注入** — 去掉 WhisperKit SPM 包以及 FluidAudio（如果不再用 VAD）
4. **VAD 管线** — 当前的能量 VAD + 20ms 帧 + 0.8s 静音边界，需要适配子进程调用
5. **Context Biasing** — 当前通过 `DecodingOptions.promptTokens` 做 prompt biasing，whisper.cpp 也有 `--prompt` 参数但行为可能不同
6. **错误处理和恢复** — 子进程崩溃/超时 vs in-process crash，完全不同
7. **测试** — 当前测试依赖于 Swift 类型系统，全部需要重写

**估计工作量：至少 3-5 个完整工作日，且引入大量回归风险。**

---

## 3. TransFlow 的 WhisperKit 方案已是优秀选择

### 3.1 TransFlow 已有的优势

| 能力 | 状态 |
|------|------|
| **VAD 自动切句** | ✅ 能量阈值 VAD + 20ms 帧 + 0.8s 静音边界 |
| **Context Biasing**（解码前） | ✅ `DecodingOptions.promptTokens` 直接偏置解码器 |
| **Hotword Correction**（解码后） | ✅ 正则/子串替换，中英文分别处理 |
| **Cloud Correction**（可选） | ✅ 本地引擎 + 云端纠错装饰器模式 |
| **说话人分离**（FluidAudio） | ✅ 完整集成 |
| **多引擎回退**（Apple Speech） | ✅ 协议化架构，可随时切换 |
| **App/系统音频采集** | ✅ ScreenCaptureKit |
| **离线文件处理** | ✅ AVAssetReader 提取音频 |
| **术语表评测闭环** | ✅ WER 评测 + metrics 台账 |

### 3.2 whisper-input-next-mac-kit 没有但 TransFlow 有的

- 流式 VAD（whisper-input 是按键手动切句）
- Context Biasing
- Hotword 后处理纠错
- 云纠错层
- 说话人分离
- App 音频采集
- 视频文件转录

---

## 4. 可以借鉴的部分

虽然核心引擎不应替换，但 whisper-input-next-mac-kit 有以下**辅助功能**值得考虑接入：

### 4.1 本地 LLM 润色（`ollama_polish.py`）

**是什么：** 转录完成后用本地 Ollama 模型（如 glm4、qwen2.5:3b）做二次润色。
- `light` 模式：修复标点和错别字
- `concise` 模式：去除填充词

**对 TransFlow 的价值：** 高。可以作为 `HotwordCorrector` 之后的一个可选后处理步骤，提升输出可读性。

**实现难度：** 低。Ollama 是本地 HTTP API（`localhost:11434/api/chat`），Swift 中只需调用 URLSession。

### 4.2 冻结监控（`freeze_watchdog.py`）

**是什么：** 后台线程监控状态机。如果卡在 processing >45s 或 recording >180s，dump 所有线程堆栈。

**对 TransFlow 的价值：** 中。WhisperKit ANE 编译偶尔会超时，有个 watchdog 帮助排查。

**实现难度：** 中。需要在 Swift 中创建后台 Timer 和 `Thread.callStackSymbols` 收集。

### 4.3 屏幕录音指示器（`listening_indicator.py` / `capsule_indicator.py`）

**是什么：** 使用 PyObjC + Core Animation 的悬浮窗：
- 录音中：呼吸环/脉冲点动画
- 转写中：旋转弧/圆圈 spinner
- 完成：绿色对勾

**对 TransFlow 的价值：** 低-中。TransFlow 已有状态栏指示器，但更丰富的 overlay 可以改善 UX。

**实现难度：** 低。纯 SwiftUI 即可实现类似效果。

### 4.4 录音存档自动清理（`archive.py` 补丁）

**是什么：** 定期清理旧录音文件。

**对 TransFlow 的价值：** 低。TransFlow 的 `AudioRecordingService` 已产生录音文件，可加一个简单的 N 天清理策略。

---

## 5. 架构对比图

```
┌─────────────────────────────────────────────────────────────────────┐
│               whisper-input-next-mac-kit (参考项目)                   │
│                                                                     │
│  键盘监听 → 状态机 → 手动开始/停止                                     │
│                      │                                              │
│              ┌───────▼────────┐                                      │
│              │ 麦克风录音(WAV) │  (Python audio 模块)                  │
│              └───────┬────────┘                                      │
│                      │ 完整音频文件                                    │
│              ┌───────▼────────┐                                      │
│              │ whisper-cli    │  (whisper.cpp 子进程)                  │
│              │ subprocess     │  模型: ggml-large-v3-turbo.bin       │
│              └───────┬────────┘                                      │
│                      │ 文本                                         │
│         ┌────────────┼────────────┐                                  │
│         ▼            ▼            ▼                                  │
│   全角标点归一化   Ollama润色    粘贴到光标                             │
│                                        (Accessibility API)           │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                       TransFlow (当前项目)                           │
│                                                                     │
│  AudioCaptureService → AsyncStream<AudioChunk>                      │
│         │                                                           │
│         ├─→ Level (UI 音量指示)                                       │
│         ├─→ RecordingService (M4A 存档)                               │
│         ├─→ DiarizationService (说话人分离)                           │
│         │                                                           │
│         └─→ TranscriptionEngine (协议化，三选一)                       │
│              │                                                      │
│              ├─ SpeechEngine          (Apple Speech 框架)            │
│              ├─ WhisperKitSpeechEngine                               │
│              │   ├─ VAD 20ms帧 能量切句                               │
│              │   ├─ Context Biasing  (DecodingOptions.promptTokens)  │
│              │   └─ WhisperKit CoreML (modelc, ANE 加速)             │
│              └─ CloudCorrectedTranscriptionEngine (装饰器层)          │
│                      │                                              │
│              ┌───────▼────────┐                                      │
│              │ TranscriptionEvent                                      │
│              │ .partial(text)                                       │
│              │ .sentenceComplete(sentence)                           │
│              └───────┬────────┘                                      │
│                      │                                              │
│         ┌────────────┼────────────┬────────────┐                     │
│         ▼            ▼            ▼            ▼                     │
│  HotwordCorrector  翻译     说话人标注     JSONL 持久化               │
│  (后处理纠错)       (LLM)    (FluidAudio)                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 6. 最终建议

| 项目 | 行动 | 理由 |
|------|------|------|
| **核心引擎：whisper.cpp → 替换 WhisperKit** | ❌ 不要做 | 架构退化，技术栈不兼容，丢失 ANE 加速和 context biasing |
| **WhisperKit 引擎** | ✅ 保持现状 | 对 macOS 原生 App 是最佳选择 |
| **Ollama 本地 LLM 润色** | ✅ 值得借鉴 | 增强输出质量，实现简单（HTTP API） |
| **冻结监控 watchdog** | ✅ 值得借鉴 | 帮助排查 ANE 编译超时等问题 |
| **屏幕录音指示器** | 🤔 可选 | 可改善 UX，但非刚需 |
| **录音清理策略** | 🤔 可选 | 架构小事，有需要再加 |

**优先推荐行动：**

1. **不要替换引擎。** TransFlow 的 WhisperKit + VAD + Context Biasing + Cloud Fix 管线已经比 whisper.cpp 方案更完善。

2. **参考实现本地 LLM 润色层。** 在 `HotwordCorrector` 之后加一个可选的 Ollama 润色步骤，用于修复标点/错别字。纯 HTTP 调用，实现成本极低。

3. **添加冻结检测。** 在 `TransFlowViewModel` 的 event loop 中加一个后台 timer，如果引擎长时间无输出则记录诊断信息。
