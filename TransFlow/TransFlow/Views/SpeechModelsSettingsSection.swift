import SwiftUI
import Speech

/// Speech model download/manage section of the Settings page.
struct SpeechModelsSettingsSection: View {
    @State private var modelManager = SpeechModelManager.shared
    @State private var isManagingSpeechLanguages = false

    var body: some View {
        VStack(spacing: 0) {
            speechModelsContent
        }
        .task {
            await modelManager.refreshAllStatuses()
        }
        .sheet(isPresented: $isManagingSpeechLanguages) {
            manageSpeechLanguagesSheet
        }
        .onChange(of: isManagingSpeechLanguages) {
            if !isManagingSpeechLanguages {
                Task {
                    await modelManager.refreshAllStatuses()
                }
            }
        }
    }

    private var speechModelsContent: some View {
        VStack(spacing: 0) {
            if modelManager.supportedLocales.isEmpty {
                HStack {
                    Label {
                        Text("settings.models_loading")
                            .font(.system(size: 13, weight: .regular))
                    } icon: {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 14)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else if installedSpeechLocales.isEmpty {
                HStack {
                    Label {
                        Text("settings.speech_models_no_installed")
                            .font(.system(size: 13, weight: .regular))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                ForEach(Array(installedSpeechLocales.enumerated()), id: \.element.identifier) { index, locale in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    speechModelRow(for: locale)
                }
            }

            Divider().padding(.leading, 46)

            Button {
                Task {
                    await modelManager.refreshAllStatuses()
                }
            } label: {
                HStack {
                    Label {
                        Text("settings.speech_models_refresh")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "arrow.clockwise")
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

            Divider().padding(.leading, 46)

            Button {
                isManagingSpeechLanguages = true
            } label: {
                HStack {
                    Label {
                        Text("settings.speech_models_manage")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var installedSpeechLocales: [Locale] {
        modelManager.supportedLocales
            .filter { (modelManager.localeStatuses[$0.identifier] ?? .checking).isReady }
            .sorted { $0.identifier < $1.identifier }
    }

    private var manageSpeechLanguagesSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("settings.speech_models_manage_title")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    if modelManager.supportedLocales.isEmpty {
                        HStack {
                            Label {
                                Text("settings.models_loading")
                                    .font(.system(size: 13, weight: .regular))
                            } icon: {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 24, height: 14)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    } else {
                        ForEach(Array(modelManager.supportedLocales.sorted { $0.identifier < $1.identifier }.enumerated()), id: \.element.identifier) { index, locale in
                            if index > 0 {
                                Divider().padding(.leading, 46)
                            }
                            speechModelRow(for: locale)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("settings.done") {
                    isManagingSpeechLanguages = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 420)
        .task {
            await modelManager.refreshAllStatuses()
        }
    }

    private func speechModelRow(for locale: Locale) -> some View {
        let status = modelManager.localeStatuses[locale.identifier] ?? .checking
        let displayName = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier

        return HStack(spacing: 8) {
            // Locale icon and name
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .regular))
                    Text(statusDescription(for: status))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(statusColor(for: status))
                }
            } icon: {
                statusIcon(for: status)
                    .frame(width: 24)
            }

            Spacer()

            // Action button or progress
            speechModelAction(for: locale, status: status)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusIcon(for status: SpeechModelStatus) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .downloading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
        case .unsupported:
            Image(systemName: "xmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        }
    }

    private func statusDescription(for status: SpeechModelStatus) -> LocalizedStringKey {
        switch status {
        case .installed:
            "model_status.installed"
        case .notDownloaded:
            "model_status.not_downloaded"
        case .downloading(let progress):
            "model_status.downloading_percent \(Int(progress * 100))"
        case .failed(let message):
            LocalizedStringKey("model_status.failed_detail \(message)")
        case .unsupported:
            "model_status.unsupported"
        case .checking:
            "model_status.checking"
        }
    }

    private func statusColor(for status: SpeechModelStatus) -> Color {
        switch status {
        case .installed: .green
        case .notDownloaded: .secondary
        case .downloading: .blue
        case .failed: .orange
        case .unsupported: .secondary.opacity(0.5)
        case .checking: .secondary
        }
    }

    @ViewBuilder
    private func speechModelAction(for locale: Locale, status: SpeechModelStatus) -> some View {
        switch status {
        case .notDownloaded, .failed:
            Button {
                Task {
                    _ = await modelManager.downloadModel(for: locale)
                    await modelManager.refreshAllStatuses()
                }
            } label: {
                Text("model_action.add")
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
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 60)
                .tint(.blue)

        case .installed:
            Button {
                Task {
                    await modelManager.releaseLocale(locale)
                    await modelManager.refreshAllStatuses()
                }
            } label: {
                Text("model_action.remove")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.quaternary.opacity(0.7))
                    )
            }
            .buttonStyle(.plain)

        case .unsupported, .checking:
            EmptyView()
        }
    }
}
