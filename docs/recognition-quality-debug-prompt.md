# TransFlow 实时转写识别率过低 — 根因诊断提示词

> 用途：把这份材料整体交给另一个 AI（或贴进一个代码分析会话），请它定位"为什么识别率这么低"。下面已包含可复现的现象描述、关键代码、设置值与排序后的假设。对方无需 clone 仓库即可基于内联代码推理；涉及的文件路径也已给出，便于进一步跳转阅读。

---

## 0. 一句话问题

macOS 实时转写 App（TransFlow，WhisperKit 本地模型）"能出字但识别率极低"：英文偶对、中文严重乱码、同一句话被反复输出。需要判断根因是 **音频输入源错误 / 语言锁定错误 / 流式解码架构缺陷 / VAD 阈值不当** 中的哪一个或哪几个。

---

## 1. 环境

- 平台：macOS（Apple Silicon）
- 引擎：WhisperKit（本地 Core ML，模型 `openai_whisper-large-v3_turbo_954MB`）
- 语言：Swift 6，严格并发（`SWIFT_STRICT_CONCURRENCY=complete`）
- 本地包：`WhisperKit`、`FluidAudio`（SPM 本地包）
- 音频链路：`AVAudioEngine` 采集 → 转 16kHz mono Float32 `AudioChunk` 流 → `WhisperKitSpeechEngine` 流式解码 → `TranscriptionSentence` 事件

---

## 2. 观察到的现象（来自用户截图 + 控制台日志）

### 2.1 转写面板输出（节选自用户录屏，时间戳为本地时间）

```
8:50:46  and            ← 原句应为 "and you can"
8:50:48  and            ← 重复
8:50:48  and            ← 重复
8:51:23  把你当天带说话   ← 中文，明显乱码
8:51:27  妈妈
8:51:28  把你当天带说话   ← 与上一条几乎相同，重复
8:51:32  妈妈            ← 重复
8:51:35  Can you hear me? ← 英文，识别正确
```

特征：
- **重复输出**：同一片段出现 2–3 次（"and"×3；中文两句成对出现）。
- **中文乱码**：`把你当天带说话` 这类无意义的字符序列，应是某句中文被严重误识。
- **英文部分正确**：`Can you hear me?` 准确，说明模型本身能工作、音频并非完全无声。

### 2.2 控制台日志（WhisperKit 解码）

```
Decoding 0.00s - 1.74s
Decoding 0.00s - 3.87s
Decoding 0.00s - 4.04s
...（每秒都有类似短解码）
```

特征：**解码非常频繁，且每段时长极短（1.7–4s）**。说明每次喂给 WhisperKit 的语音段都很短，缺乏上下文。

### 2.3 设置页（截图）

| 项 | 值 |
|---|---|
| Language | **English** |
| Engine | WhisperKit |
| WhisperKit Model | Ready |
| Input Device | **System Default**（未选真实麦克风）|
| Hotwords | 空 |

---

## 3. 关键代码（内联，可推理）

### 3.1 流式解码主循环 —— `WhisperKitSpeechEngine.swift`

滑动窗口：窗口 `windowSeconds = 30`，步长 `slideSeconds = 5`（来自 `AppSettings`）。

```swift
// 音频流处理
for await chunk in audioStream {
    audioBuffer.append(contentsOf: chunk.samples)

    // 每累积到 slideSize(=5s) 样本就触发一次转写
    guard audioBuffer.count >= slideSize else { continue }

    // 裁剪：只保留最近 windowSeconds(=30s) 的样本
    if audioBuffer.count > chunkSize {
        audioBuffer = Array(audioBuffer.suffix(chunkSize))
    }
    let window = Array(audioBuffer.suffix(chunkSize))

    // 串行转写链，保证顺序
    transcribeChain = Task {
        await prev?.value
        do {
            // VAD 过滤静音，提取语音段并拼接
            let (speechSamples, originalOffsets, concatDurations) =
                vadService.extractSpeechWithOffsets(window)
            let audioToTranscribe: [Float]
            let useVAD: Bool
            if speechSamples.isEmpty {
                audioToTranscribe = window      // VAD 无结果则退回整窗
                useVAD = false
            } else {
                audioToTranscribe = speechSamples
                useVAD = true
            }

            let decodeOptions = buildDecodeOptions(
                languageCode: languageCode,      // = "en"（见 3.3）
                whisperKit: capturedWhisperKit,
                promptText: promptText          // 空（hotwords 为空）
            )

            let results = try await capturedWhisperKit.transcribe(
                audioArray: audioToTranscribe,
                decodeOptions: decodeOptions
            )
            guard let result = results.first else { return }
            let segments = result.segments
            // ... 逐 segment 剥离控制 token、用绝对时间戳去重、yield ...
        }
    }
}
```

### 3.2 VAD —— `VADService.swift`（能量法）

```swift
init(
    silenceThreshold: Float = 0.01,   // RMS 阈值，低于即静音
    minSpeechDuration: Double = 0.3,  // 最短语音段
    minSilenceDuration: Double = 0.5, // 多长静音算断句
    sampleRate: Int = 16000
) { ... }

// 20ms 帧，逐帧算 RMS，>= silenceThreshold 判为语音；
// 连续静音 >= minSilenceDuration 切分语音段；
// 返回各语音段的 [startSample...endSample]。
func detectSpeechSegments(_ samples: [Float]) -> [ClosedRange<Int>]
```

注意 `silenceThreshold = 0.01` 是针对 16kHz mono Float32 调的。若输入音频能量整体偏低（真麦距离远 / 虚拟设备近零），VAD 会丢弃大量音频。

### 3.3 解码选项 + 语言锁定 —— `WhisperKitSpeechEngine.swift`

```swift
private func buildDecodeOptions(
    languageCode: String, whisperKit: WhisperKit, promptText: String
) -> DecodingOptions {
    var promptTokens: [Int]? = nil
    if !promptText.isEmpty, let tokenizer = whisperKit.tokenizer {
        promptTokens = tokenizer.encode(text: promptText)   // hotwords 为空 → nil
    }
    return DecodingOptions(
        verbose: false,
        task: .transcribe,
        language: languageCode,          // ★ 用户设 English → "en"
        temperature: 0.0,
        temperatureIncrementOnFallback: 0.2,
        temperatureFallbackCount: 5,
        promptTokens: promptTokens,      // nil
        compressionRatioThreshold: 2.4,
        logProbThreshold: -1.0,
        noSpeechThreshold: 0.6
    )
}

// languageCode 来源：
private static func convertLocaleToWhisperLanguage(_ locale: Locale) -> String {
    let languageCode = locale.language.languageCode?.identifier(.alpha2) ?? "en"
    // ... 若不在支持列表则回退 "en"
    return languageCode
}
```

→ 当用户在设置里选了 "English"，`language` 被**硬编码为 "en"**，强制 WhisperKit 用英语解码器。中文内容因此被映射到最近的英文 token → 乱码。

### 3.4 去重状态机 —— `WhisperKitSpeechEngine.swift`

```swift
private actor TranscriptionState {
    var lastCommittedEndSec: Double = 0
    var lastCommittedText: String = ""

    func shouldCommit(text: String, endingAt end: Double) -> Bool {
        guard end > lastCommittedEndSec else { return false }          // 时间戳去重
        if text == lastCommittedText,
           end - lastCommittedEndSec < 1.5 {
            return false                                               // 1.5s 内同文本去重
        }
        lastCommittedEndSec = end
        lastCommittedText = text
        return true
    }
}
```

→ 去重只挡 **完全相同文本且 1.5s 内** 的重复。滑动窗口每 5s 重解码同一段音频，文本因 VAD 边界微差而略有不同、且 end 时间戳超过 1.5s → **漏过去重** → 用户看到重复。

### 3.5 音频采集 + 设备绑定 —— `AudioCaptureService.swift`

```swift
func startCapture(deviceUID: String? = nil)
    -> (stream: AsyncStream<AudioChunk>, stop: @Sendable () -> Void) {
    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    engine.prepare()   // ★ 最近修复：确保 audioUnit 就绪，否则设备绑定静默失败
    var inputFormat = inputNode.outputFormat(forBus: 0)

    if let deviceUID, !deviceUID.isEmpty,
       let deviceID = Self.resolveDeviceID(uid: deviceUID) {
        let bound = Self.bindInputDevice(deviceID: deviceID, on: engine)
        inputFormat = inputNode.outputFormat(forBus: 0)  // 绑定后重读格式
        // bound=false 会打 ErrorLogger 告警
    }
    // ... installTap(format: inputFormat) → 转 16kHz mono → yield AudioChunk
}
```

→ 用户当前 `deviceUID = nil`（System Default），走引擎默认输入。该机器系统默认输入解析为虚拟聚合设备 `CADefaultDeviceAggregate`（含 BlackHole 2ch 这类静音虚拟源）。**真实麦克风未被选中**。

---

## 4. 排序后的根因假设

### 假设 A（最可能：音频源是虚拟/静音设备）— 导致"整体质量低"
- 用户选 System Default → 引擎默认输入 = `CADefaultDeviceAggregate`，内含 BlackHole 2ch（虚拟 sink，无人往里灌音频时近乎零信号）。
- 采集到的音频大部分静音 → VAD `silenceThreshold=0.01` 滤掉绝大多数帧 → `extractSpeechWithOffsets` 只返回零星短语音 → WhisperKit 在近乎静音的音频上**幻觉**出 "and" 等填充词、中文乱码。
- 间接证据：控制台全是 1.7–4s 的短解码，符合"只抽到零星语音"。
- 验证：让用户去 Settings → 输入设备 选**真实麦克风**（非 System Default / 非带"·虚拟"标记项），再看日志是否出现 `input device (after bind): ... bound=true` 且有真实语音。也可在 `AudioCaptureService` 的 tap 里打印每 chunk 的 RMS（`calculateNormalizedLevel` 已有），确认真实能量。

### 假设 B（确定 bug：语言被锁 English，但用户在说中文）— 导致"中文乱码"
- `buildDecodeOptions(language: "en")` 强制英语解码器。中文音素被映射到最近英文 token → `把你当天带说话` 这类乱码。
- 这是**确定的代码问题**，与音频源无关：即使音频完美，锁 en 也会毁掉中文。
- 修复方向：当用户未显式钉死语言 / 内容是中英混合时，传 `language: nil` 让 WhisperKit 每段自动检测；或在设置里加 "Auto / 自动检测" 选项。

### 假设 C（架构缺陷：滑动窗口 + 每步 VAD → 过短且重叠的解码）— 导致"重复 + 低上下文"
- 30s 窗 / 5s 步长 → 同一句被重叠窗口反复解码约 6 次，每次只喂 VAD 抽出的短语音（~1.7s），缺乏上下文 → 准确率低。
- 去重状态机只挡 1.5s 内**完全相同**文本，跨 5s 的近似重复漏过 → 用户看到重复。
- 修复方向（推荐）：改为 **VAD 门控的整句解码**——累积音频，仅在 VAD 检测到"说话结束（静音 ≥ minSilenceDuration）"时，把整句（约 2–10s）一次性交给 WhisperKit。这样：① 每句只解码一次，根治重复；② Whisper 拿到整句上下文，准确率显著提升；③ 解码频率从"每秒"降到"每句"，省算力。

### 假设 D（次要：VAD 阈值 / 电平校准）
- `silenceThreshold=0.01` 是固定值。真麦在安静环境 RMS 可能低于此值而丢真语音；虚拟设备则整体近零。
- 修复方向：阈值改为自适应（如基于近期 RMS 分位数），或在 tap 处加前置增益；并打日志让用户可以肉眼看到音频电平是否到达模型。

### 假设 E（次要：空热词 / 无上下文偏置）
- `promptTokens = nil`（hotwords 空）。对专有名词/人名帮助有限，但属次要因素。

---

## 5. 请另一个 AI 回答的问题

1. **主因排序**：基于以上代码与现象，A/B/C 三个假设中，哪一个（或组合）最可能导致"识别率极低 + 中文乱码 + 重复输出"？请用代码依据说明。
2. **假设 B 修复安全性**：把 `language: languageCode` 改成"用户选 Auto 时传 `nil`"是否会让 WhisperKit 每段自动检测语言？对纯英文场景是否有退化风险？请给出最小改动方案。
3. **假设 C 改造方案**：把"滑动窗口每步解码"重构为"VAD 门控的整句解码"，请给出具体的 Swift 6 并发安全实现草图（如何在不阻塞 `audioStream` 循环的前提下，监听 VAD 静音边界并触发一次性 `transcribe`），并评估对现有 `TranscriptionState` 去重逻辑的影响（是否可简化/移除）。
4. **假设 A 验证**：如何在不依赖用户手动改设置的前提下，在代码里检测"当前输入设备是虚拟/静音源"并给出告警或自动回退到第一个非虚拟设备？`InputDeviceManager.isVirtual` 的判定逻辑是否足够（见下）？
5. **阈值调优**：`silenceThreshold=0.01` / `minSilenceDuration=0.5` 对真麦 vs 虚拟设备是否都需要调整？有无更稳的 VAD（如 Silero）接入成本评估。
6. **快速验证清单**：给出一个最小复现 + 验证步骤（含应在控制台观察的关键日志行），让用户在本地 5 分钟内确认根因。

---

## 6. 附带：`InputDeviceManager.isVirtual` 判定（假设 A 相关）

```swift
let isVirtual = ["virtual", "aggregate", "airplay"]
    .contains { transport.localizedCaseInsensitiveContains($0) }
    || mfg.localizedCaseInsensitiveContains("existential")      // BlackHole 厂商
    || mfg.localizedCaseInsensitiveContains("rogue amoeba")     // Loopback 厂商
    || name.localizedCaseInsensitiveContains("blackhole")
    || name.localizedCaseInsensitiveContains("loopback")
    || name.localizedCaseInsensitiveContains("multi-output")
    || name.localizedCaseInsensitiveContains("aggregate")
```

问题：`CADefaultDeviceAggregate`（系统自动聚合设备）按 name 含 "aggregate" 会被判为虚拟。但**该聚合设备可能同时含真实麦克风**，判虚拟并不等于"无输入"。这正是假设 A 的微妙之处——System Default 解析到的聚合设备既可能含真麦、也可能只含虚拟源，需实测确认。

---

## 7. 已做的无关修复（避免另一个 AI 误判）

- 已移除会"整挂识别"的 `skipSpecialTokens: true`（改回正则剥离控制 token）。
- 已加 `engine.prepare()` 让设备绑定生效；但用户仍选 System Default，故真实麦克风尚未接入。
- 已加文本去重，但只挡 1.5s 内完全相同文本（见 3.4），对跨窗口近似重复无效。

以上修复均已通过 `swiftc -typecheck`（Swift 6）。本问题（识别率低）应在这些修复**之上**继续排查。
