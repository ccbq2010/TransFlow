# 多人会议说话人识别 & 知识库答题 — 总体进度

> 创建：2026-07-26 | 最后更新：2026-07-26 (Phase 3)

## 背景

TransFlow 已有 FluidAudio 实时聚类能力，输出匿名 speaker_0/1/2。本项目增强为：
1. 会前注册参会人（声纹录入）→ 实时匹配到具体人名
2. 未匹配声纹可手动命名，命名后自动学习加入 profile
3. 基于知识库的答题建议（Phase 2）

---

## Phase 1：Speaker Profiles 注册与匹配 ✅ 已完成

| 状态 | 任务 | 文件 |
|------|------|------|
| ✅ | SpeakerProfile 模型（embedding + 元数据） | `Models/SpeakerProfile.swift` |
| ✅ | SpeakerProfilesStore 持久化（JSON + Accelerate 向量匹配） | `Services/SpeakerProfilesStore.swift` |
| ✅ | SpeakerEnrollmentService（录音 + FluidAudio embedding 提取） | `Services/SpeakerEnrollmentService.swift` |
| ✅ | SpeakerEnrollmentView 注册引导 UI | `Views/SpeakerEnrollmentView.swift` |
| ✅ | SpeakerProfilesView 参会人管理页面（增/删/改名） | `Views/SpeakerProfilesView.swift` |
| ✅ | RealtimeDiarizationService 增加 setKnownSpeakers | `Services/RealtimeDiarizationService.swift` |
| ✅ | TransFlowViewModel 集成（加载 profiles、改名、display name 解析） | `ViewModels/TransFlowViewModel.swift` |
| ✅ | TranscriptionView speaker badge 可点击改名 | `Views/TranscriptionView.swift` |
| ✅ | SidebarView + MainView 新增"参会人"入口 | `Views/SidebarView.swift` `Views/MainView.swift` |
| ✅ | TranscriptionSentence 新增 confidence 字段 | `Models/TranscriptionModels.swift` |
| ✅ | i18n 新增 22 个 key（中英双语） | `Localizable.xcstrings` |
| ✅ | xcode build 编译通过 | 2026-07-26 |

---

## Phase 2：知识库 + 答题建议 ✅ 已完成

| 状态 | 任务 | 文件 |
|------|------|------|
| ✅ | KnowledgeModels（Document/Chunk/Question/Answer 模型） | `Models/KnowledgeModels.swift` |
| ✅ | KnowledgeStore（Markdown/PDF 导入、分块、NLEmbedding 检索） | `Services/KnowledgeStore.swift` |
| ✅ | QuestionDetector（启发式问题检测：问号/疑问词/语气词） | `Services/QuestionDetector.swift` |
| ✅ | AnswerSuggester（检索 + FoundationModels 流式生成） | `Services/AnswerSuggester.swift` |
| ✅ | AnswerSuggestionViewModel（状态管理 + 防抖 + 错误处理） | `ViewModels/AnswerSuggestionViewModel.swift` |
| ✅ | SuggestionPanelView（建议答案面板 UI） | `Views/SuggestionPanelView.swift` |
| ✅ | KnowledgeManagementView（知识库管理 UI：导入/删除/粘贴） | `Views/KnowledgeManagementView.swift` |
| ✅ | TransFlowViewModel 集成 AnswerSuggester | `ViewModels/TransFlowViewModel.swift` |
| ✅ | SidebarView + MainView 新增"知识库"入口 | `Views/SidebarView.swift` `Views/MainView.swift` |
| ✅ | ContentView 集成 SuggestionPanelView | `Views/ContentView.swift` |
| ✅ | i18n 新增 16 个 key | `Localizable.xcstrings` |
| ✅ | xcode build 编译通过 | 2026-07-26 |

---

## Phase 3：打磨 ✅ 已完成

| 状态 | 任务 |
|------|------|
| ✅ | JSONL 持久化 speakerName 字段 |
| ✅ | 建议面板动画（slide + corner radius + shadow） |
| ✅ | 空知识库检测（跳过生成） |
| ✅ | FoundationModels 不可用 fallback UI |
| ✅ | 修复 SpeakerProfilesView 重复行 |
| ✅ | ContentView HStack 格式修正 |
| ⬜ | 端到端测试（需实际设备） |
| ⬜ | 未匹配声纹"自动学习"加入 profile（Layer 3） |

### Phase 3 变更文件
- Models/JSONLModels.swift — 新增 speakerName 字段
- Services/JSONLStore.swift — 新增 appendEntry(entry:) 重载
- ViewModels/TransFlowViewModel.swift — speakerName 持久化 + 空知识库检测
- ViewModels/AnswerSuggestionViewModel.swift — 空知识库守卫
- Views/SuggestionPanelView.swift — 动画 + unavailable 状态
- Views/SpeakerProfilesView.swift — 修复重复行
- Views/ContentView.swift — 格式修正 + 面板过渡动画
- Localizable.xcstrings — 新增 suggestion.unavailable

---

## 关键设计决策

| 决策点 | 选择 | 理由 |
|--------|------|------|
| 声纹模型 | FluidAudio 内置 wespeaker_v2 | 不引入新依赖 |
| 匹配阈值 | 0.65 | 与 diarization 内部 embeddingThreshold 对齐 |
| profiles 存储 | JSON 文件 (Application Support) | 数据量小，无需数据库 |
| LLM | Apple FoundationModels | 设备端、离线、隐私优先 |
| Embedding | NLEmbedding.sentenceEmbedding | 系统内置、英文支持 |
| 知识库模式 | 导入 → 建索引 → 开会用 | 用户明确要求 |
| FoundationModels API | streamResponse(to:) 流式输出 | 2026 SDK 标准 API |
| NLEmbedding 检索 | distance(between:and:) 实时计算 | API 不暴露原始向量 |
| speakerName 持久化 | JSONLContentEntry 新增字段 | 简单可靠、与现有格式兼容 |

---

## 文件变更汇总

### Phase 1 新增（5 个文件，~470 行）
- Models/SpeakerProfile.swift
- Services/SpeakerProfilesStore.swift
- Services/SpeakerEnrollmentService.swift
- Views/SpeakerEnrollmentView.swift
- Views/SpeakerProfilesView.swift

### Phase 2 新增（7 个文件，~530 行）
- Models/KnowledgeModels.swift
- Services/KnowledgeStore.swift
- Services/QuestionDetector.swift
- Services/AnswerSuggester.swift
- ViewModels/AnswerSuggestionViewModel.swift
- Views/SuggestionPanelView.swift
- Views/KnowledgeManagementView.swift

### 当前分支
- `feature/sentence-editing`
- Phase 1 & 2 已 commit (`8f061f3`)
- Phase 3 打磨已 commit (`cb08446`)
- 单元测试已 commit (`007b336`) — 72 tests 全部通过
