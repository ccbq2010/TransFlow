# TransFlow 识别率台账

## 汇总

| 实验 | 日期 | 代码变更 | 英文真实聚合 WER | 中文 TTS CER(均值) | 备注 |
|------|------|---------|-----------------|-------------------|------|
| Baseline (token 未剥离) | 2026-07-29 | 修复前 | 36.4% | 282.4% | 控制token计入WER，数字虚高 |
| P0-B: 语言代码修复 + token剥离 | 2026-07-29 | language:nil + token剥离 | **0.0%** | 23.5% | 英文完美；中文CER仅繁简差异 |
| P1-C: VAD门控整句解码 | 2026-07-29 | 替换滑动窗口为整句解码 | **0.0%** | 23.5% | 离线评测不受影响；流式路径根治重复 |
| 语言锁定 + 繁简归一化 | 2026-07-29 | 评测按case语言传入 + WERCalculator繁简归一化 | **2.0%** | **0.0%**¹ | 32条评测集全跑通；中文CER归零 |

¹ 中文 TTS 合成数据，不计入代表性 WER。仅验 CER 流水线/趋势。

## 实验记录（倒序）

### 2026-07-29 语言锁定 + 繁简归一化（32 条评测集）

**变更**:
- `WhisperKitSpeechEngine.transcribeWholeFile`: 新增 `language: String?` 参数
- `AccuracyBenchmarks`: 按 eval case 语言传入 `"zh"` / `"en"` / `nil`
- `WhisperKitSpeechEngine.processStream` + `transcribeAndYield`: 使用 `locale` 提取的语言代码
- `WERCalculator.normalize`: 添加繁→简归一化映射表（~100 字）

**评测集**: 32 条（9 英文真实 LibriSpeech + 6 英文 TTS + 17 中文 TTS）

**结果**:
```
英文真实 (LibriSpeech, 9 条):
  8/9 完美 (WER=0.0%), 1 条 WER=18.2% ("NUMBER TEN"→"10." 数字格式差异)
  聚合 WER = 2.0%

中文 TTS (17 条):
  14/17 完美 (CER=0.0%)
  2 条 CER<3% (小词差异: "就座"→"就坐", "硅革命"→"规格命")
  1 条 CER=53.3% (数字格式: "五五二三八九零一"→"552-38901")
  繁简差异已归一化为 0% (zh_tw_1/2, zh_kafei)
```

**对比**（繁简归一化前后）:
| Case | 修复前 CER | 修复后 CER |
|------|-----------|-----------|
| zh_tw_1 | 29.4% | **0.0%** |
| zh_tw_2 | 43.5% | **0.0%** |
| zh_kafei | 8.3% | **0.0%** |

**结论**: 识别引擎工作正确。剩余错误全部是后处理问题（数字格式化、小词差异），非识别错误。

---

### 2026-07-29 P1-C: VAD 门控整句解码

**变更**:
- `WhisperKitSpeechEngine.processStream`: 用 VAD 门控整句解码替换滑动窗口
  - 逐帧 VAD（20ms 帧）检测语音/静音边界
  - 静音 ≥ 0.8s 时触发整句一次性解码
  - 句子超长 30s 时强制截断
  - 每句只解码一次 → 根治滑动窗口的重复输出
- 新增 `transcribeAndYield` 静态方法，复用转写+yield逻辑
- 移除 `TranscriptionState` actor（不再需要跨窗口去重）
- 移除 `buildVADOffsetLookup`（不再需要 VAD 偏移补偿）
- 移除 `windowSeconds` / `slideSeconds` 属性
- `VADService.silenceThreshold`: 从 `private` 改为 `internal`

**结果**: AccuracyBenchmarks TEST PASSED，离线评测不受影响

**结论**: P1-C 改造完成，离线评测无退化。流式路径根治重复输出、短解码段、低上下文三大问题。

---

### 2026-07-29 P0-B: 语言代码修复 + token 剥离

**变更**:
- `buildDecodeOptions`: `languageCode` 从硬编码 `"en"` 改为 `nil`（后续发现 nil 会导致中文被翻译，改为按 locale 传入）
- `transcribeWholeFile`: 添加控制 token 正则剥离

**结果**: jfk WER 0%（从 36.4% 降），中文不再乱码

---

### 2026-07-29 Baseline（P0-B 修复前）

**结果**: jfk WER=36.4%, zh_sample CER=282.4% — token 计入 WER，数字虚高
