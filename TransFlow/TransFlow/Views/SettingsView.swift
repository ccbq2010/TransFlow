import SwiftUI
import Speech
import Carbon.HIToolbox
@preconcurrency import Translation

/// Settings page with Apple-grade design.
/// Sections: General (Language), Speech Models, Translation Models, Diarization Models, Feedback, About (Version).
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var updateChecker = UpdateChecker.shared
    @State private var hotkeyManager = GlobalHotkeyManager.shared
    @State private var whisperKitModelManager = WhisperKitModelManager.shared
    @State private var hasLoadedModels = false
    @StateObject private var inputDeviceManager = InputDeviceManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // ── General Section ──
                settingsSection(
                    header: "settings.general",
                    icon: "gearshape.fill",
                    iconColor: .gray
                ) {
                    languageRow
                    Divider().padding(.leading, 46)
                    appearanceRow
                    Divider().padding(.leading, 46)
                    engineRow
                    Divider().padding(.leading, 46)
                    hotwordsRow
                    Divider().padding(.leading, 46)
                    whisperKitModelRow
                    Divider().padding(.leading, 46)
                    inputDeviceRow
                }

                // ── Cloud ASR Section (Scheme A) ──
                settingsSection(
                    header: "cloud_asr.title",
                    icon: "cloud.fill",
                    iconColor: .blue
                ) {
                    cloudASREnableRow
                    if settings.cloudASR.enabled {
                        Divider().padding(.leading, 46)
                        cloudASRProviderRow
                        Divider().padding(.leading, 46)
                        cloudASRApiKeyRow
                        Divider().padding(.leading, 46)
                        cloudASRModelRow
                        Divider().padding(.leading, 46)
                        cloudASRBaseURLRow
                        Divider().padding(.leading, 46)
                        cloudASRNoteRow
                    }
                }

                // ── Hotkeys Section ──
                settingsSection(
                    header: "settings.hotkeys",
                    icon: "keyboard.fill",
                    iconColor: .orange
                ) {
                    hotkeyAccessibilityHintRow

                    hotkeyRow(
                        label: "settings.hotkey.toggle_transcription",
                        icon: "waveform",
                        iconColor: .red,
                        binding: $settings.hotkeyToggleTranscription
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_translation",
                        icon: "translate",
                        iconColor: .blue,
                        binding: $settings.hotkeyToggleTranslation
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_floating_preview",
                        icon: "rectangle.dock",
                        iconColor: .purple,
                        binding: $settings.hotkeyToggleFloatingPreview
                    )
                    Divider().padding(.leading, 46)
                    hotkeyRow(
                        label: "settings.hotkey.toggle_main_window",
                        icon: "macwindow",
                        iconColor: .green,
                        binding: $settings.hotkeyToggleMainWindow
                    )
                }

                // ── Speech Models Section ──
                settingsSection(
                    header: "settings.speech_models",
                    icon: "waveform.badge.mic",
                    iconColor: .indigo
                ) {
                    SpeechModelsSettingsSection()
                }

                // ── Translation Models Section ──
                settingsSection(
                    header: "settings.translation_models",
                    icon: "translate",
                    iconColor: .blue
                ) {
                    TranslationModelsSettingsSection()
                }

                // ── Diarization Models Section ──
                settingsSection(
                    header: "settings.diarization_models",
                    icon: "person.2.fill",
                    iconColor: .orange
                ) {
                    DiarizationModelsSettingsSection()
                }

                // ── Feedback Section ──
                settingsSection(
                    header: "settings.feedback",
                    icon: "bubble.left.fill",
                    iconColor: .blue
                ) {
                    feedbackRow
                    Divider().padding(.leading, 46)
                    openLogsRow
                }

                // ── About Section ──
                settingsSection(
                    header: "settings.about",
                    icon: "info.circle.fill",
                    iconColor: .secondary
                ) {
                    versionRow
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task(id: "initial-load") {
            guard !hasLoadedModels else { return }
            hasLoadedModels = true
            await whisperKitModelManager.checkStatus()
        }
        .onAppear {
            if hasLoadedModels {
                Task {
                    await whisperKitModelManager.checkStatus()
                }
            }
        }
        .onAppear {
            updateChecker.checkOnceOnLaunch()
        }
    }

    // MARK: - Section Builder

    private func settingsSection<Content: View>(
        header: LocalizedStringKey,
        icon: String,
        iconColor: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                Text(header)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .padding(.bottom, 8)
            .padding(.top, 20)

            // Section content card
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary.opacity(0.3))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Language Row

    private var languageRow: some View {
        HStack {
            Label {
                Text("settings.language")
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: "globe")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
            }

            Spacer()

            Picker("", selection: $settings.appLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName)
                        .tag(language)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .tint(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Appearance Row

    private var appearanceRow: some View {
        HStack {
            Label {
                Text("settings.appearance")
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.purple)
                    .frame(width: 24)
            }

            Spacer()

            Picker("", selection: $settings.appAppearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.displayName)
                        .tag(appearance)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .tint(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Engine Row

    private var engineRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.engine")
                        .font(.system(size: 13, weight: .regular))
                    Text(engineDescription)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.indigo)
                    .frame(width: 24)
            }

            Spacer()

            Picker("", selection: $settings.transcriptionEngine) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    Text(engine.displayName)
                        .tag(engine)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .tint(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var engineDescription: LocalizedStringKey {
        switch settings.transcriptionEngine {
        case .appleSpeech: "engine.apple_speech.description"
        case .whisperKit: "engine.whisper_kit.description"
        }
    }

    // MARK: - Input Device Row

    /// Picker for which CoreAudio input device to record from. "System Default" follows
    /// whatever the user picked in System Settings; selecting a specific device here
    /// overrides that and rebinds the engine's input node on the next capture start.
    private var inputDeviceRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("audio.input.title")
                        .font(.system(size: 13, weight: .regular))
                    Text(inputDeviceSubtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.pink)
                    .frame(width: 24)
            }

            Spacer()

            Menu {
                Button {
                    settings.selectedInputDeviceUID = nil
                } label: {
                    Label {
                        Text("audio.input.system_default")
                    } icon: {
                        if settings.selectedInputDeviceUID == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                if !inputDeviceManager.devices.isEmpty {
                    Divider()
                }
                ForEach(inputDeviceManager.devices) { dev in
                    Button {
                        settings.selectedInputDeviceUID = dev.uid
                    } label: {
                        Label {
                            HStack {
                                Text(dev.name)
                                if dev.isVirtual {
                                    Text("·").foregroundStyle(.tertiary)
                                    Text("audio.input.virtual").foregroundStyle(.tertiary)
                                }
                            }
                        } icon: {
                            if dev.uid == settings.selectedInputDeviceUID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(inputDeviceSelectedLabel)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                inputDeviceManager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(Text("audio.input.refresh"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onAppear { inputDeviceManager.refresh() }
    }

    private var inputDeviceSelectedLabel: String {
        let selected = settings.selectedInputDeviceUID
        if let selected, let dev = inputDeviceManager.devices.first(where: { $0.uid == selected }) {
            return dev.name
        }
        // Either "System Default" or the previously-picked device is gone — show default's name.
        if let defUID = inputDeviceManager.systemDefaultUID,
           let def = inputDeviceManager.devices.first(where: { $0.uid == defUID }) {
            return def.name
        }
        return String(localized: "audio.input.system_default")
    }

    private var inputDeviceSubtitle: LocalizedStringKey {
        let selected = settings.selectedInputDeviceUID
        if let selected, !selected.isEmpty,
           let dev = inputDeviceManager.devices.first(where: { $0.uid == selected }) {
            if dev.isVirtual {
                return "audio.input.subtitle.virtual"
            } else {
                return "audio.input.subtitle.specific"
            }
        }
        return "audio.input.subtitle.system_default"
    }

    // MARK: - Cloud ASR Rows (Scheme A)

    private var cloudASREnableRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("cloud_asr.enable")
                        .font(.system(size: 13, weight: .regular))
                    Text("cloud_asr.enable.description")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
            }
            Spacer()
            Toggle("", isOn: $settings.cloudASR.enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cloudASRProviderRow: some View {
        HStack {
            Label {
                Text("cloud_asr.provider")
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: "server.rack")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 24)
            }
            Spacer()
            Picker("", selection: $settings.cloudASR.provider) {
                ForEach(CloudASRProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .tint(.secondary)
            .onChange(of: settings.cloudASR.provider) { newProvider in
                // Adopt the preset's defaults when switching away from a custom endpoint.
                if newProvider != .custom {
                    settings.cloudASR.baseURL = newProvider.defaultBaseURL
                    settings.cloudASR.model = newProvider.defaultModel
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cloudASRApiKeyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text("cloud_asr.api_key")
                        .font(.system(size: 13, weight: .regular))
                } icon: {
                    Image(systemName: "key.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }
                Spacer()
            }
            SecureField("cloud_asr.api_key.placeholder", text: $settings.cloudASR.apiKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cloudASRModelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text("cloud_asr.model")
                        .font(.system(size: 13, weight: .regular))
                } icon: {
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }
                Spacer()
            }
            TextField("cloud_asr.model.placeholder", text: $settings.cloudASR.model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cloudASRBaseURLRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label {
                    Text("cloud_asr.base_url")
                        .font(.system(size: 13, weight: .regular))
                } icon: {
                    Image(systemName: "link")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }
                Spacer()
            }
            TextField("cloud_asr.base_url.placeholder", text: $settings.cloudASR.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var cloudASRNoteRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text("cloud_asr.note")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Hotwords Row

    private var hotwordsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    Text("settings.hotwords")
                        .font(.system(size: 13, weight: .regular))
                } icon: {
                    Image(systemName: "textformat.abc")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.teal)
                        .frame(width: 24)
                }
                Spacer()
            }

            Text("settings.hotwords.hint")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.tertiary)

            TextField(
                "settings.hotwords.placeholder",
                text: Binding(
                    get: { settings.hotwords.joined(separator: "\n") },
                    set: { newValue in
                        settings.hotwords = newValue
                            .split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                    }
                ),
                axis: .vertical
            )
            .lineLimit(3...6)
            .font(.system(size: 12, design: .monospaced))
            .textFieldStyle(.roundedBorder)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - WhisperKit Model Row

    private var whisperKitModelRow: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.whisperkit_model.title")
                        .font(.system(size: 13, weight: .regular))
                    Text(whisperKitModelStatusText)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(whisperKitModelStatusColor)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            } icon: {
                whisperKitModelStatusIcon
                    .frame(width: 24)
            }

            Spacer()

            whisperKitModelAction
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var whisperKitModelStatusText: String {
        switch whisperKitModelManager.downloadState {
        case .notDownloaded:
            return String(localized: "settings.whisperkit_model.download")
        case .downloading(let progress):
            return "\(String(localized: "settings.whisperkit_model.downloading")) \(Int(progress * 100))%"
        case .ready:
            return String(localized: "settings.whisperkit_model.ready")
        case .failed(let message):
            return message
        }
    }

    private var whisperKitModelStatusColor: Color {
        switch whisperKitModelManager.downloadState {
        case .notDownloaded: .secondary
        case .downloading: .blue
        case .ready: .green
        case .failed: .orange
        }
    }

    @ViewBuilder
    private var whisperKitModelStatusIcon: some View {
        switch whisperKitModelManager.downloadState {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var whisperKitModelAction: some View {
        switch whisperKitModelManager.downloadState {
        case .notDownloaded, .failed:
            Button {
                Task {
                    await whisperKitModelManager.downloadModel()
                }
            } label: {
                Text("model_action.download")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.accentColor)
                    )
            }
            .buttonStyle(.plain)

        case .downloading(let progress):
            HStack(spacing: 4) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 50)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            }

        case .ready:
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                Text("model_status.ready")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            )
        }
    }

    // MARK: - Feedback Row

    private var feedbackRow: some View {
        Button {
            openFeedback()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.send_feedback")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                        Text("settings.feedback_description")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "envelope.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 24)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Version Row

    private var versionRow: some View {
        VStack(spacing: 0) {
            switch updateChecker.status {
            case .updateAvailable(let version, _):
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.version")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                            Text("settings.update_available \(version)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.orange)
                        }
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Text(appVersionString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)

                        Button {
                            updateChecker.downloadUpdate()
                        } label: {
                            Text("settings.update_download")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.accentColor)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .downloading(let progress):
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.version")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                            Text("settings.update_downloading \(Int(progress * 100))")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.blue)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                            .tint(.blue)

                        Button {
                            updateChecker.cancelDownload()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .readyToInstall(let version, _):
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.version")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                            Text("settings.update_ready \(version)")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.green)
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.green)
                            .frame(width: 24)
                    }

                    Spacer()

                    Button {
                        updateChecker.installUpdate()
                    } label: {
                        Text("settings.update_install")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.green)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .installing:
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.version")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                            Text("settings.update_installing")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.blue)
                        }
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24)
                    }

                    Spacer()

                    Text(appVersionString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .upToDate:
                HStack {
                    Label {
                        Text("settings.version")
                            .font(.system(size: 13, weight: .regular))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.green)
                            .frame(width: 24)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text("settings.up_to_date")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.green)
                        Text(appVersionString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .checking:
                HStack {
                    Label {
                        Text("settings.version")
                            .font(.system(size: 13, weight: .regular))
                    } icon: {
                        Image(systemName: "number")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(appVersionString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .failed(let message):
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.version")
                                .font(.system(size: 13, weight: .regular))
                            Text(message)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.yellow)
                            .frame(width: 24)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Text("settings.check_failed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(appVersionString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            case .idle:
                HStack {
                    Label {
                        Text("settings.version")
                            .font(.system(size: 13, weight: .regular))
                    } icon: {
                        Image(systemName: "number")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }

                    Spacer()

                    Text(appVersionString)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider().padding(.leading, 46)

            checkForUpdatesRow
        }
    }

    private var checkForUpdatesRow: some View {
        Button {
            updateChecker.checkForUpdates()
        } label: {
            HStack {
                Label {
                    Text("settings.check_for_updates")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(updateChecker.status == .checking)
    }

    // MARK: - Helpers

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.6.2"
    }

    // MARK: - Open Logs Row

    private var openLogsRow: some View {
        Button {
            ErrorLogger.shared.openLogsFolder()
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.open_logs")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                        Text("settings.open_logs_description")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                } icon: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                }

                Spacer()

                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hotkey Accessibility Hint

    @ViewBuilder
    private var hotkeyAccessibilityHintRow: some View {
        if hotkeyManager.isAccessibilityGranted {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                Text("settings.hotkey.accessibility_granted")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.leading, 46)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.shield")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                Text("settings.hotkey.accessibility_hint")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                Button {
                    hotkeyManager.requestAccessibility()
                } label: {
                    Text("settings.hotkey.grant_access")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("settings.hotkey.open_accessibility")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().padding(.leading, 46)
        }
    }

    // MARK: - Hotkey Row

    private func hotkeyRow(
        label: LocalizedStringKey,
        icon: String,
        iconColor: Color,
        binding: Binding<HotkeyBinding>
    ) -> some View {
        HStack {
            Label {
                Text(label)
                    .font(.system(size: 13, weight: .regular))
            } icon: {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
            }

            Spacer()

            HotkeyRecorderView(binding: binding)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func openFeedback() {
        if let url = URL(string: "https://github.com/Cyronlee/TransFlow/issues") {
            NSWorkspace.shared.open(url)
        }
    }
}
