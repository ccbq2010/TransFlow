import SwiftUI
import Speech

/// Main ViewModel coordinating all services: audio capture, speech engine, translation, and recording.
@Observable
@MainActor
final class TransFlowViewModel {
    // MARK: - Published State

    /// Completed transcription sentences history
    var sentences: [TranscriptionSentence] = []
    /// Current volatile partial text
    var currentPartialText: String = ""
    /// Current listening state
    var listeningState: ListeningState = .idle
    /// Current audio level (0-1)
    var audioLevel: Float = 0
    /// Audio level waveform history
    var audioLevelHistory: [Float] = Array(repeating: 0, count: 30)
    /// Selected audio source
    var audioSource: AudioSourceType = .microphone
    /// Selected transcription language.
    /// Defaults to the system's primary language so a non-English user isn't silently
    /// forced into an `en-US` transcriber (which would produce garbage for their speech).
    var selectedLanguage: Locale = Locale.current
    /// Available transcription languages (installed/ready only)
    var availableLanguages: [Locale] = []
    /// Available apps for audio capture
    var availableApps: [AppAudioTarget] = []
    /// Error message
    var errorMessage: String?
    /// Non-fatal warning about the active input device (e.g. virtual default device).
    var inputDeviceWarning: String?
    /// Whether to show the "model not ready" alert prompting user to go to Settings.
    var showModelNotReadyAlert: Bool = false
    /// Whether to show the WhisperKit model not ready alert.
    var showWhisperKitModelNotReadyAlert: Bool = false
    /// Microphone permission granted
    var micPermissionGranted: Bool = false

    /// Translation service (observed separately for SwiftUI binding)
    let translationService = TranslationService()

    /// Speech model manager for asset checking and downloading.
    let modelManager = SpeechModelManager.shared

    /// JSONL persistence store for the current session.
    let jsonlStore = JSONLStore()

    /// Whether real-time speaker diarization is active this session.
    var isDiarizationEnabled: Bool = false

    /// P2-2 修复：Diarization 协调器，从 ViewModel 拆分出的 diarization 逻辑
    let diarizationCoordinator = DiarizationCoordinator()

    /// Active speaker count from the current diarization session.
    var activeSpeakerCount: Int { diarizationCoordinator.activeSpeakerCount }

    /// Speaker name overrides set by the user during/after a session (anonymousId → name).
    var speakerNameOverrides: [String: String] { diarizationCoordinator.speakerNameOverrides }

    /// Bumped whenever speakerNameOverrides changes to force SwiftUI re-render.
    var speakerRefreshID: UUID { diarizationCoordinator.speakerRefreshID }

    /// Answer suggestion coordinator for the knowledge base feature.
    let answerSuggestion = AnswerSuggestionViewModel()

    // MARK: - Private

    private let audioCaptureService = AudioCaptureService()
    private let audioRecordingService = AudioRecordingService()
    private var speechEngine: TranscriptionEngineProtocol?  // Protocol-based, no AnyObject cast needed
    private var stopAudioCapture: (@Sendable () -> Void)?
    private var listeningTask: Task<Void, Never>?
    private var audioLevelTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var diarizationTask: Task<Void, Never>?
    private var lifecycleObserver: (any NSObjectProtocol)?

    /// Current recording file name (set while recording is active).
    private var currentRecordingFileName: String?

    /// When the current partial utterance started (for flushing on stop).
    private var partialStartTimestamp: Date?

    /// Cached hotword corrector — rebuilt when hotwords change.
    /// 通过比较 hotwords 哈希检测变化，避免每次转写都重建。
    private var _hotwordCorrector: HotwordCorrector = HotwordCorrector(hotwords: AppSettings.shared.hotwords)
    private var _cachedHotwordsHash: Int = AppSettings.shared.hotwords.hashValue

    private var hotwordCorrector: HotwordCorrector {
        let currentHotwords = AppSettings.shared.hotwords
        let currentHash = currentHotwords.hashValue
        if currentHash != _cachedHotwordsHash {
            _hotwordCorrector = HotwordCorrector(hotwords: currentHotwords)
            _cachedHotwordsHash = currentHash
        }
        return _hotwordCorrector
    }

    /// Session start time for converting absolute timestamps to relative offsets.
    private var sessionStartTime: Date?

    /// P1-4 修复：throttle rewriteJSONLWithCurrentSentences 的延迟 Task
    private var rewriteThrottleTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        Task {
            await initialize()
        }
        setupLifecycleObserver()
    }

    deinit {
        // P3-1 修复：兜底清理。deinit 是非隔离的，不能直接访问 @MainActor 隔离属性。
        // 用 Task 兜底在 MainActor 上清理，若 VM 已释放则 weak self 为 nil 跳过。
        // 正常路径下 stopListening() 会被调用并清理所有资源。
        Task { @MainActor [weak self] in
            self?.listeningTask?.cancel()
            self?.audioLevelTask?.cancel()
            self?.recordingTask?.cancel()
            self?.diarizationTask?.cancel()
            self?.rewriteThrottleTask?.cancel()
            // P3-1：也取消引擎内部 Task
            if let engine = self?.speechEngine as? WhisperKitSpeechEngine {
                engine.stop()
            }
            if let engine = self?.speechEngine as? CloudCorrectedTranscriptionEngine {
                engine.stop()
            }
            // P2-2：清理 diarization
            self?.diarizationCoordinator.reset()
            self?.stopAudioCapture?()
            if let observer = self?.lifecycleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func initialize() async {
        jsonlStore.createSession()
        micPermissionGranted = await AudioCaptureService.requestPermission()
        translationService.updateSourceLanguage(from: selectedLanguage)
        DiarizationModelManager.shared.checkStatus()
        SpeakerProfilesStore.shared.load()
        KnowledgeStore.shared.load()
        await refreshInstalledLanguages()
        await refreshAvailableApps()
        await modelManager.checkCurrentStatus(for: selectedLanguage)
    }

    private func setupLifecycleObserver() {
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                ErrorLogger.shared.log(
                    "App became active — listeningState=\(self.listeningState), selectedLanguage=\(self.selectedLanguage.identifier)",
                    source: "Transcription"
                )
                guard self.listeningState == .idle else { return }
                DiarizationModelManager.shared.checkStatus()
                await self.refreshInstalledLanguages()
                await self.modelManager.checkCurrentStatus(for: self.selectedLanguage)
            }
        }
    }

    // MARK: - Language

    func loadSupportedLanguages() async {
        await refreshInstalledLanguages()
    }

    func refreshInstalledLanguages() async {
        await modelManager.refreshAllStatuses()
        let supportedLanguages = modelManager.supportedLocales.sorted { $0.identifier < $1.identifier }
        let readyLanguages = supportedLanguages.filter { locale in
            (modelManager.localeStatuses[locale.identifier] ?? .checking).isReady
        }

        // 同语言代码（如 zh-CN、zh-TW）只保留一个变体。
        // 注意：不能按字母序取第一个 —— 英语会选中 en_AU（澳洲）而不是 en_US，
        // 用错地区模型会显著拉低识别率。优先级：系统偏好语言 > 常用地区变体 > 字母序。
        func variantPriority(_ locale: Locale) -> Int {
            let id = locale.identifier
                .replacingOccurrences(of: "_", with: "-")
                .lowercased()
            // 1. 与系统偏好语言完全匹配（如系统为 en-US 时优先 en_US）
            for (index, preferred) in Locale.preferredLanguages.enumerated()
            where preferred.lowercased() == id {
                return index
            }
            // 2. 各语言的常用地区变体
            let canonical: [String: String] = [
                "en": "en-us", "zh": "zh-cn", "es": "es-es", "fr": "fr-fr",
                "de": "de-de", "pt": "pt-br", "ja": "ja-jp", "ko": "ko-kr",
            ]
            if let code = locale.language.languageCode?.identifier.lowercased(),
               canonical[code] == id {
                return 100
            }
            // 3. 其余按字母序兜底
            return 1000
        }
        var bestVariant: [String: Locale] = [:]
        for locale in readyLanguages {
            let code = locale.language.languageCode?.identifier ?? locale.identifier
            if let existing = bestVariant[code] {
                if variantPriority(locale) < variantPriority(existing) {
                    bestVariant[code] = locale
                }
            } else {
                bestVariant[code] = locale
            }
        }
        availableLanguages = readyLanguages.filter { locale in
            let code = locale.language.languageCode?.identifier ?? locale.identifier
            return bestVariant[code]?.identifier == locale.identifier
        }

        guard !availableLanguages.isEmpty else { return }

        let selectedIdentifier = selectedLanguage.identifier
        if !availableLanguages.contains(where: { $0.identifier == selectedIdentifier }) {
            // Prefer the system's primary language if it's ready, instead of blindly
            // picking the alphabetically-first locale (which could be an unrelated language).
            let systemCode = Locale.current.language.languageCode?.identifier
            if let preferred = availableLanguages.first(where: {
                $0.language.languageCode?.identifier == systemCode
            }) {
                selectedLanguage = preferred
            } else {
                selectedLanguage = availableLanguages[0]
            }
            translationService.updateSourceLanguage(from: selectedLanguage)
        }
    }

    func switchLanguage(to locale: Locale) {
        let wasListening = listeningState == .active
        if wasListening {
            stopListening()
        }
        selectedLanguage = locale
        // 注意：不在这里创建 speechEngine，startListening() 内部会根据当前语言创建。
        // 之前在这里创建的引擎会立即被 startListening() 覆盖，造成浪费。
        translationService.updateSourceLanguage(from: locale)

        Task {
            await modelManager.checkCurrentStatus(for: locale)
            if !modelManager.currentModelStatus.isReady {
                await modelManager.ensureModelReady(for: locale)
            }
            if translationService.isEnabled {
                await translationService.refreshAndAutoSelect()
            }
            if wasListening {
                startListening()
            }
        }
    }

    /// Enable translation and, if currently listening, restart the transcription
    /// pipeline so a fresh `TranslationSession` is picked up before the engine
    /// resumes emitting events.
    ///
    /// This is the single entry point for turning translation ON. It exists to
    /// avoid two races we had before:
    ///   1. `translateSentence` / `translatePartial` guard on `session != nil`,
    ///      but the session only becomes available after `.translationTask`
    ///      finishes preparing — which races with incoming engine events.
    ///   2. Callers that fired multiple concurrent Tasks each calling
    ///      `refreshAndAutoSelect` could interleave and leave the config in a
    ///      state where `.translationTask` never re-fires.
    func enableTranslation() {
        guard !translationService.isEnabled else { return }
        translationService.isEnabled = true
        translationService.updateSourceLanguage(from: selectedLanguage)

        let wasListening = listeningState == .active
        if wasListening {
            ErrorLogger.shared.log(
                "Enabling translation while listening — restarting pipeline",
                source: "Translation"
            )
            stopListening()
        } else {
            ErrorLogger.shared.log(
                "Enabling translation while idle — preparing config only",
                source: "Translation"
            )
        }

        Task {
            await translationService.refreshAndAutoSelect(force: true)
            if wasListening {
                startListening()
            }
        }
    }

    /// Disable translation. Keeps the transcription pipeline running — only tears
    /// down the translation session so future sentences won't request translation.
    func disableTranslation() {
        guard translationService.isEnabled else { return }
        ErrorLogger.shared.log("Disabling translation", source: "Translation")
        translationService.isEnabled = false
        translationService.updateConfiguration()
    }

    /// Convenience for UI toggles and global hotkeys.
    func toggleTranslation() {
        if translationService.isEnabled {
            disableTranslation()
        } else {
            enableTranslation()
        }
    }

    /// Enable or disable live speaker diarization.
    ///
    /// Diarization is instantiated inside `startListening()` based on
    /// `AppSettings.liveEnableDiarization`, so toggling the setting mid-session
    /// alone does nothing — the UI flips but the pipeline keeps its old state
    /// (same class of bug as translation toggle). This method restarts the
    /// transcription pipeline when listening so the new setting takes effect
    /// immediately.
    func setDiarizationEnabled(_ enabled: Bool) {
        guard AppSettings.shared.liveEnableDiarization != enabled else { return }
        AppSettings.shared.liveEnableDiarization = enabled

        let wasListening = listeningState == .active
        if wasListening {
            ErrorLogger.shared.log(
                "Changing diarization to \(enabled) while listening — restarting pipeline",
                source: "RealtimeDiarization"
            )
            stopListening()
            Task {
                startListening()
            }
        } else {
            ErrorLogger.shared.log(
                "Changing diarization to \(enabled) while idle — setting only",
                source: "RealtimeDiarization"
            )
        }
    }

    /// Convenience for UI toggle.
    func toggleDiarization() {
        setDiarizationEnabled(!AppSettings.shared.liveEnableDiarization)
    }

    /// Change the translation target language. When listening, restart the
    /// pipeline so the new session is fully ready before the next utterance —
    /// mirroring the behavior of `switchLanguage(to:)` for source language.
    func setTranslationTargetLanguage(_ lang: Locale.Language) {
        guard translationService.isEnabled else {
            translationService.targetLanguage = lang
            return
        }
        translationService.targetLanguage = lang

        let wasListening = listeningState == .active
        if wasListening {
            ErrorLogger.shared.log(
                "Changing translation target to \(lang.minimalIdentifier) while listening — restarting pipeline",
                source: "Translation"
            )
            stopListening()
        }

        Task {
            translationService.updateConfiguration(force: true)
            if wasListening {
                startListening()
            }
        }
    }

    // MARK: - App Audio

    func refreshAvailableApps() async {
        availableApps = await AppAudioCaptureService.availableApps()
    }

    // MARK: - Listening

    func startListening() {
        guard listeningState == .idle else { return }
        guard !availableLanguages.isEmpty else {
            showModelNotReadyAlert = true
            return
        }
        listeningState = .starting
        ErrorLogger.shared.log(
            "startListening: language=\(selectedLanguage.identifier), source=\(audioSource)",
            source: "Transcription"
        )

        listeningTask = Task {
            do {
                let modelReady = await modelManager.ensureModelReady(for: selectedLanguage)
                guard modelReady else {
                    ErrorLogger.shared.log(
                        "startListening: model not ready for \(selectedLanguage.identifier) — showing alert",
                        source: "Transcription"
                    )
                    showModelNotReadyAlert = true
                    listeningState = .idle
                    return
                }

                // Fork audio stream: engine, UI level, recording, and diarization
                let (engineStream, engineContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingOldest(128)  // avoid dropping audio frames
                )
                let (levelStream, levelContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                let (recordingStream, recordingContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(256)
                )
                let (diarizationStream, diarizationContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingOldest(128)  // avoid dropping audio frames
                )

                let baseEngine: any TranscriptionEngineProtocol
                switch AppSettings.shared.transcriptionEngine {
                case .appleSpeech:
                    baseEngine = SpeechEngine(locale: selectedLanguage)

                case .whisperKit:
                    // S3 修复：WhisperKit 路径也检查模型是否就绪
                    await WhisperKitModelManager.shared.checkStatus()
                    guard WhisperKitModelManager.shared.isReady else {
                        showWhisperKitModelNotReadyAlert = true
                        listeningState = .idle
                        return
                    }
                    baseEngine = WhisperKitSpeechEngine(locale: selectedLanguage)
                }

                // Scheme A: when cloud ASR correction is enabled and configured, wrap the
                // on-device engine so each finalized sentence is re-sent to the cloud for
                // higher accuracy while live partial captions remain on-device.
                let cloudConfig = AppSettings.shared.cloudASR
                let finalEngine: any TranscriptionEngineProtocol
                if cloudConfig.isConfigured {
                    finalEngine = CloudCorrectedTranscriptionEngine(inner: baseEngine, config: cloudConfig)
                    ErrorLogger.shared.log(
                        "startListening: cloud ASR correction enabled (provider=\(cloudConfig.provider.rawValue), model=\(cloudConfig.model))",
                        source: "Transcription"
                    )
                } else {
                    finalEngine = baseEngine
                    if cloudConfig.enabled, cloudConfig.apiKey.isEmpty {
                        ErrorLogger.shared.log(
                            "startListening: cloud ASR enabled but API key missing — using on-device only",
                            source: "Transcription"
                        )
                    }
                }
                self.speechEngine = finalEngine
                let events = finalEngine.processStream(engineStream)

                let audioStream: AsyncStream<AudioChunk>
                let stop: @Sendable () -> Void

                switch audioSource {
                case .microphone:
                    guard micPermissionGranted else {
                        errorMessage = String(localized: "error.mic_permission_denied")
                        ErrorLogger.shared.log("Microphone permission not granted", source: "AudioCapture")
                        listeningState = .idle
                        return
                    }
                    // 用户未显式选择设备、且系统默认输入是虚拟/聚合设备时，
                    // 提示可能录不到声音（不再自动切换设备，尊重用户对系统默认的选择）。
                    if AppSettings.shared.selectedInputDeviceUID == nil,
                       let defaultUID = InputDeviceManager.shared.systemDefaultUID,
                       let defaultDevice = InputDeviceManager.shared.devices.first(where: { $0.uid == defaultUID }),
                       defaultDevice.isVirtual {
                        inputDeviceWarning = String(localized: "warning.virtual_input_device")
                    } else {
                        inputDeviceWarning = nil
                    }
                    let capture = audioCaptureService.startCapture(deviceUID: AppSettings.shared.selectedInputDeviceUID)
                    audioStream = capture.stream
                    stop = capture.stop

                case .systemAudio:
                    if !AppAudioCaptureService.isScreenRecordingAuthorized {
                        _ = AppAudioCaptureService.requestScreenRecordingAccess()
                    }
                    let capture = try await AppAudioCaptureService.startSystemCapture()
                    audioStream = capture.stream
                    stop = capture.stop

                case .appAudio(let target):
                    guard let target else {
                        errorMessage = String(localized: "error.no_app_selected")
                        ErrorLogger.shared.log("No app selected for audio capture", source: "AudioCapture")
                        listeningState = .idle
                        return
                    }
                    if !AppAudioCaptureService.isScreenRecordingAuthorized {
                        _ = AppAudioCaptureService.requestScreenRecordingAccess()
                    }
                    let capture = try await AppAudioCaptureService.startCapture(for: target)
                    audioStream = capture.stream
                    stop = capture.stop
                }

                self.stopAudioCapture = stop
                self.sessionStartTime = Date()

                // Audio level update task
                audioLevelTask = Task {
                    for await chunk in levelStream {
                        self.audioLevel = chunk.level
                        self.audioLevelHistory.append(chunk.level)
                        if self.audioLevelHistory.count > 30 {
                            self.audioLevelHistory.removeFirst()
                        }
                    }
                }

                // Start recording — each start creates a new uniquely-named file
                let (recFileName, recStartTime) = audioRecordingService.startRecording()
                self.currentRecordingFileName = recFileName
                jsonlStore.appendRecordingStart(fileName: recFileName, timestamp: recStartTime)

                let recorder = audioRecordingService
                recordingTask = Task.detached {
                    for await chunk in recordingStream {
                        recorder.writeChunk(chunk)
                    }
                }

                // Diarization — start if enabled and models ready
                DiarizationModelManager.shared.checkStatus()
                let enableDiarization = AppSettings.shared.liveEnableDiarization
                    && DiarizationModelManager.shared.modelStatus.isReady
                self.isDiarizationEnabled = enableDiarization

                if enableDiarization {
                    do {
                        let diarizationModels = try await DiarizationModelManager.shared.loadModels()
                        let knownSpeakers = SpeakerProfilesStore.shared.toFluidAudioSpeakers()
                        // 通过 coordinator 管理 diarization 完整生命周期
                        try self.diarizationCoordinator.startSession(
                            models: diarizationModels,
                            knownSpeakers: knownSpeakers
                        ) { [weak self] segments in
                            Task { @MainActor in
                                self?.handleDiarizationSegments(segments)
                            }
                        }

                        diarizationTask = Task {
                            for await chunk in diarizationStream {
                                self.diarizationCoordinator.feedAudio(chunk.samples)
                            }
                        }
                    } catch {
                        ErrorLogger.shared.log(
                            "RealtimeDiarizationService failed: \(error.localizedDescription)",
                            source: "RealtimeDiarization"
                        )
                        self.isDiarizationEnabled = false
                    }
                }

                if !isDiarizationEnabled {
                    diarizationTask = Task.detached {
                        for await _ in diarizationStream {}
                    }
                }

                // Fork task — fan out audio to all four consumers
                let forkTask = Task.detached {
                    for await chunk in audioStream {
                        engineContinuation.yield(chunk)
                        levelContinuation.yield(chunk)
                        recordingContinuation.yield(chunk)
                        diarizationContinuation.yield(chunk)
                    }
                    engineContinuation.finish()
                    levelContinuation.finish()
                    recordingContinuation.finish()
                    diarizationContinuation.finish()
                }

                listeningState = .active
                errorMessage = nil
                ErrorLogger.shared.log(
                    "startListening: engine started, diarization=\(enableDiarization), now active",
                    source: "Transcription"
                )

                for await event in events {
                    switch event {
                    case .partial(let text):
                        if partialStartTimestamp == nil && !text.isEmpty {
                            partialStartTimestamp = Date()
                        }
                        currentPartialText = text
                        translationService.translatePartial(text)

                    case .sentenceComplete(var sentence):
                        // Apply hotword correction (L1: use cached corrector)
                        sentence.text = hotwordCorrector.correct(sentence.text)

                        if let translation = await translationService.translateSentence(sentence.text) {
                            sentence.translation = translation
                        }
                        if isDiarizationEnabled {
                            sentence.speakerId = assignSpeaker(for: sentence)
                        }
                        sentences.append(sentence)
                        appendSentenceWithSpeakerName(sentence)
                        answerSuggestion.processTranscription(
                            sentence.text,
                            fullContext: currentTranscriptionContext()
                        )
                        currentPartialText = ""
                        partialStartTimestamp = nil
                        translationService.currentPartialTranslation = ""

                    case .error(let message):
                        errorMessage = message
                        ErrorLogger.shared.log(message, source: "Transcription")
                        await SpeechRuntimeRecovery.refreshSpeechModelState(for: self.selectedLanguage)
                    }
                }

                forkTask.cancel()

            } catch {
                errorMessage = error.localizedDescription
                ErrorLogger.shared.log("Listening failed: \(error.localizedDescription)", source: "AudioCapture")
            }

            listeningState = .idle
            audioLevel = 0
        }
    }

    func stopListening() {
        guard listeningState == .active || listeningState == .starting else { return }
        ErrorLogger.shared.log(
            "stopListening: sentences=\(sentences.count), partialText=\(currentPartialText.isEmpty ? "(empty)" : "present")",
            source: "Transcription"
        )
        listeningState = .stopping

        // Flush remaining partial text as a final sentence
        if !currentPartialText.isEmpty {
            let trimmed = currentPartialText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sentence = TranscriptionSentence(
                    startTimestamp: partialStartTimestamp ?? Date(),
                    timestamp: Date(),
                    text: trimmed
                )
                sentences.append(sentence)
                jsonlStore.appendEntry(sentence: sentence)
            }
            currentPartialText = ""
            partialStartTimestamp = nil
        }

        // Stop recording and write marker
        if let info = audioRecordingService.stopRecording(), let recFileName = currentRecordingFileName {
            jsonlStore.appendRecordingStop(fileName: recFileName, durationMs: info.durationMs)
        }
        recordingTask?.cancel()
        recordingTask = nil
        currentRecordingFileName = nil

        // P2-2 修复：通过 coordinator 清理 diarization 状态
        diarizationCoordinator.stopSession()
        diarizationTask?.cancel()
        diarizationTask = nil
        isDiarizationEnabled = false
        sessionStartTime = nil

        // P1-1 / P1-5 修复：取消引擎内部处理 Task，防止资源泄漏
        if let engine = speechEngine as? WhisperKitSpeechEngine {
            engine.stop()
        }
        if let engine = speechEngine as? CloudCorrectedTranscriptionEngine {
            engine.stop()
        }
        stopAudioCapture?()
        stopAudioCapture = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        listeningTask?.cancel()
        listeningTask = nil
        speechEngine = nil

        listeningState = .idle
        audioLevel = 0
        translationService.currentPartialTranslation = ""
    }

    func toggleListening() {
        if listeningState == .idle {
            startListening()
        } else {
            stopListening()
        }
    }

    // MARK: - Session

    func createNewSession(name: String? = nil) {
        if listeningState != .idle {
            stopListening()
        }
        sentences.removeAll()
        currentPartialText = ""
        translationService.currentPartialTranslation = ""
        answerSuggestion.reset()
        jsonlStore.createSession(name: name)
    }

    // MARK: - History

    func clearHistory() {
        sentences.removeAll()
        currentPartialText = ""
        translationService.currentPartialTranslation = ""
    }

    // MARK: - Export

    func exportSRT() async {
        await SRTExporter.exportToFile(sentences: sentences)
    }

    // MARK: - Diarization

    /// Handle incoming diarization segments from the streaming pipeline.
    // P2-2 修复：Diarization 逻辑委托给 DiarizationCoordinator，ViewModel 只做状态协调

    private func handleDiarizationSegments(_ segments: [RealtimeDiarizationService.SpeakerSegment]) {
        diarizationCoordinator.appendSegments(segments)
        diarizationCoordinator.activeSpeakerCount = diarizationCoordinator.service?.speakerCount ?? 0
        backfillSpeakerIds()
    }

    /// Assign a speaker to a sentence by matching its time range against diarization segments.
    private func assignSpeaker(for sentence: TranscriptionSentence) -> String? {
        guard let sessionStart = sessionStartTime else { return nil }
        return diarizationCoordinator.assignSpeaker(for: sentence, sessionStart: sessionStart)
    }

    /// Backfill speakerId for sentences that were emitted before diarization results arrived.
    private func backfillSpeakerIds() {
        guard let sessionStart = sessionStartTime else { return }
        guard let updates = diarizationCoordinator.computeBackfill(for: sentences, sessionStart: sessionStart) else { return }
        for (index, speakerId) in updates {
            sentences[index].speakerId = speakerId
        }
        rewriteJSONLWithCurrentSentences()
    }

    /// P1-4 修复：debounce 版 rewriteJSONLWithCurrentSentences。
    /// 短时间内多次调用（如 diarization backfill 密集更新）只执行最后一次，避免高频全文件重写。
    private func scheduleRewriteJSONL() {
        rewriteThrottleTask?.cancel()
        rewriteThrottleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s debounce
            guard !Task.isCancelled else { return }
            self?.performRewriteJSONL()
        }
    }

    /// Rewrite the JSONL file with updated speaker IDs after backfill.
    private func rewriteJSONLWithCurrentSentences() {
        scheduleRewriteJSONL()
    }

    private func performRewriteJSONL() {
        guard let fileURL = jsonlStore.currentFileURL else { return }

        // P1-2 修复：写入前先 flush writeHandle，确保缓冲数据已落盘
        jsonlStore.flushWriteHandle()

        let allLines = jsonlStore.readAllLines(from: fileURL)

        var contentIndex = 0
        var updatedLines: [JSONLLine] = []
        var hasChanges = false

        for line in allLines {
            switch line {
            case .content(let entry):
                if contentIndex < sentences.count {
                    let sentence = sentences[contentIndex]
                    let newSpeakerId = sentence.speakerId
                    let newSpeakerName = diarizationCoordinator.speakerName(for: sentence.speakerId)
                    // P1-2 修复：dirty checking，仅当 speakerId 或 speakerName 变化时才标记
                    if entry.speakerId != newSpeakerId || entry.speakerName != newSpeakerName {
                        hasChanges = true
                        let updated = JSONLContentEntry(
                            startTime: entry.startTime,
                            endTime: entry.endTime,
                            originalText: entry.originalText,
                            translatedText: entry.translatedText,
                            speakerId: newSpeakerId,
                            speakerName: newSpeakerName
                        )
                        updatedLines.append(.content(updated))
                    } else {
                        updatedLines.append(line)
                    }
                } else {
                    updatedLines.append(line)
                }
                contentIndex += 1
            default:
                updatedLines.append(line)
            }
        }

        // P1-2 修复：无变化时跳过写入
        guard hasChanges else { return }

        // P1-2 修复：逐行写入临时文件，避免在内存中拼接整个文件内容
        let tempURL = fileURL.appendingPathExtension("tmp")
        let encoder = JSONEncoder()
        encoder.outputFormatting = []

        do {
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let tempHandle = try FileHandle(forWritingTo: tempURL)
            for (i, line) in updatedLines.enumerated() {
                if let data = try? encoder.encode(line),
                   let str = String(data: data, encoding: .utf8) {
                    if i > 0 { tempHandle.write(Data("\n".utf8)) }
                    tempHandle.write(Data(str.utf8))
                }
            }
            tempHandle.closeFile()

            try FileManager.default.replaceItem(at: fileURL, withItemAt: tempURL, backupItemName: nil, resultingItemURL: nil)

            // P1-2 修复：原子替换后重新打开 writeHandle（旧 fd 指向旧 inode）
            jsonlStore.reopenWriteHandle()
        } catch {
            ErrorLogger.shared.log(
                "performRewriteJSONL failed: \(error.localizedDescription)",
                source: "TransFlowViewModel"
            )
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    // MARK: - Speaker Naming (P2-2: 委托给 DiarizationCoordinator)

    /// Resolve the display name for a speaker ID, applying user overrides first.
    func displayName(for speakerId: String) -> String {
        diarizationCoordinator.displayName(for: speakerId)
    }

    /// Build a context string from recent sentences for question answering.
    private func currentTranscriptionContext() -> String {
         let recent = sentences.suffix(20)
         return recent.map { $0.text }.joined(separator: " ")
     }

    /// Rename a speaker (anonymous or known) for the current session.
    /// Updates all matching sentences and persists the override.
    func renameSpeaker(anonymousId: String, to name: String) {
        diarizationCoordinator.renameSpeaker(anonymousId: anonymousId, to: name)
        rewriteJSONLWithCurrentSentences()
    }

    /// Append a sentence to JSONL, including any user-assigned speaker name.
    private func appendSentenceWithSpeakerName(_ sentence: TranscriptionSentence) {
        let formatter = ISO8601DateFormatter()
        let entry = JSONLContentEntry(
            startTime: formatter.string(from: sentence.startTimestamp),
            endTime: formatter.string(from: sentence.timestamp),
            originalText: sentence.text,
            translatedText: sentence.translation,
            speakerId: sentence.speakerId,
            speakerName: diarizationCoordinator.speakerName(for: sentence.speakerId)
        )
        jsonlStore.appendEntry(entry: entry)
    }
}
