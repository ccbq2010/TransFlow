# 开发会话记录 — 2026-07-26

> 会话时长：约 3 小时 | 分支：`feature/sentence-editing`

## 需求讨论

用户提出两个功能增强方向：
1. **更好的多人会议说话人识别** — 识别每个人是谁，而非匿名 speaker_0/1/2
2. **基于知识库的答题建议** — 根据本地知识库，针对参会人问题生成建议回答

## 设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 声纹模型 | FluidAudio 内置 wespeaker_v2 | 不引入新依赖 |
| 匹配阈值 | 0.65 | 与 diarization 内部 embeddingThreshold 对齐 |
| profiles 存储 | JSON 文件 (Application Support) | 数据量小，无需数据库 |
| LLM | Apple FoundationModels | 设备端、离线、隐私优先 |
| Embedding | NLEmbedding.sentenceEmbedding | 系统内置、支持多语言 |
| 知识库模式 | 导入 → 建索引 → 开会用 | 用户明确要求非实时导入 |
| 目标系统 | macOS 26.0, Apple Silicon | FoundationModels 需要 |

## 实现计划

### Phase 1: Speaker Profiles 注册与匹配
- 会前注册参会人（录几秒语音提取声纹 embedding）
- 实时转写时自动匹配已注册说话人
- 转写中/后可点击 speaker badge 改名

### Phase 2: 知识库 + 答题建议
- 导入 PDF/Markdown/粘贴文本 → 分块 → NLEmbedding 索引
- 实时检测问题（启发式：问号/疑问词/语气词）
- FoundationModels 流式生成建议答案
- 右侧面板显示答案 + 来源引用

### Phase 3: 打磨
- JSONL 持久化 speakerName
- 建议面板动画
- 边界情况处理

## 实现过程

### 第一轮：功能实现

创建 12 个新文件，修改 13 个已有文件：

**新增文件：**
- `Models/SpeakerProfile.swift` — SpeakerProfile + SpeakerNameMapping
- `Models/KnowledgeModels.swift` — KnowledgeDocument/Chunk/DetectedQuestion/SuggestedAnswer
- `Services/SpeakerProfilesStore.swift` — profiles 持久化 + 余弦相似度匹配
- `Services/SpeakerEnrollmentService.swift` — 录音 + embedding 提取
- `Services/KnowledgeStore.swift` — 文档导入/分块/检索
- `Services/QuestionDetector.swift` — 启发式问题检测
- `Services/AnswerSuggester.swift` — FoundationModels 流式生成
- `ViewModels/AnswerSuggestionViewModel.swift` — 状态管理
- `Views/SpeakerEnrollmentView.swift` — 注册引导 UI
- `Views/SpeakerProfilesView.swift` — 参会人管理
- `Views/SuggestionPanelView.swift` — 建议面板
- `Views/KnowledgeManagementView.swift` — 知识库管理

**修改文件：**
- `Models/TranscriptionModels.swift` — 新增 confidence 字段
- `Models/JSONLModels.swift` — 新增 speakerName 字段
- `Services/RealtimeDiarizationService.swift` — 新增 setKnownSpeakers
- `Services/JSONLStore.swift` — 新增 appendEntry(entry:)
- `ViewModels/TransFlowViewModel.swift` — 集成 speaker matching + answer suggester
- `Views/TranscriptionView.swift` — speaker badge 可点击改名
- `Views/SidebarView.swift` — 新增"参会人"和"知识库"入口
- `Views/MainView.swift` — 处理新增导航目标
- `Views/ContentView.swift` — 集成 SuggestionPanelView
- `Localizable.xcstrings` — 新增 38 个 key

### 第二轮：代码审查

对全部新增代码进行了审查，发现 14 个问题：

| # | 严重度 | 问题 |
|---|--------|------|
| 1 | P1 | KnowledgeManagementView 重复 Text（旧行未删） |
| 2 | P1 | SpeakerEnrollmentView 音频电平表不工作（audioLevel 未连接） |
| 3 | P1 | TranscriptionView.speakerBadge 死代码 |
| 4 | P2 | AnswerSuggester/QuestionDetector 不必要 @MainActor |
| 5 | P2 | retrieveTopK 在主线程同步计算 |
| 6 | P2 | save() 频繁写磁盘 |
| 7 | P2 | embedding 硬编码 .english |
| 8 | P2 | fileImporter 未开始安全域访问 |
| 9 | P3 | renameSpeaker 中 self-assignment |
| 10 | P3 | SpeakerNameMapping 从未使用 |
| 11 | P3 | enrollment 后未调用 cleanup |
| 12 | P3 | rewriteJSONLWithCurrentSentences 用 deprecated atomically |
| 13 | P3 | SpeakerEnrollmentView 未检查麦克风权限 |
| 14 | P3 | 知识库重复导入无检测 |

### 第三轮：修复审查问题

按 P1-P3 优先级分批修复，全部完成（#12 因 API 限制保留原样）。

### 第四轮：单元测试

创建 5 个测试文件，共 47 个新测试（总计 71 个测试全部通过）：
- `QuestionDetectorTests` — 21 tests
- `SpeakerProfilesStoreTests` — 11 tests
- `KnowledgeStoreTests` — 9 tests
- `JSONLModelsTests` — 5 tests
- `AnswerSuggesterTests` — 2 tests

## Commit 记录

| Commit | 说明 |
|--------|------|
| `8f061f3` | feat: speaker profiles, knowledge base, and AI answer suggestions |
| `cb08446` | feat: polish phase 3 — persistence, animations, edge cases |
| `007b336` | test: unit tests for new speaker and knowledge base features |
| `235a03b` | fix: address code review findings (P1-P3) |

## 功能全流程

### 参会人注册
1. 侧边栏点击"参会人" → 进入管理页面
2. 点击"添加参会人" → 输入姓名 → 录制几秒语音
3. FluidAudio 提取 256 维声纹 embedding → 保存到 JSON

### 会议中的说话人识别
1. 开始转写时，SpeakerProfilesStore 加载所有 profiles
2. RealtimeDiarizationService 初始化时传入已知说话人
3. FluidAudio 实时聚类时自动匹配到具体人名
4. 转写中/后点击 speaker badge 可随时重命名

### 知识库答题
1. 侧边栏点击"知识库" → 导入 PDF/Markdown/粘贴文本
2. 文档自动分块（~400 词/块）并持久化
3. 开会时实时转写，检测到问题自动检索相关知识
4. FoundationModels 生成建议答案，右侧面板显示

## 已知限制

- FoundationModels 需要 macOS 15+、Apple Silicon、Apple Intelligence 开启
- NLEmbedding 对中文的语义检索精度不如专用模型
- 未匹配声纹不会自动加入 profile（Layer 3 暂不实现）
- 知识库大文件在主线程分块可能卡顿

## 后续可选工作

- Push 到远程 + 创建 PR
- 运行 UI Tests
- Layer 3: 未匹配声纹自动学习
- 性能优化（知识库后台分块）
- 端到端真机测试
