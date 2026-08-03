import SwiftUI
@preconcurrency import Translation

/// Translation model download/manage section of the Settings page.
struct TranslationModelsSettingsSection: View {
    @State private var translationService: TranslationService = {
        let svc = TranslationService()
        svc.sourceLanguage = Locale.Language(identifier: "en")
        return svc
    }()
    @State private var isManagingTranslationLanguages = false
    @State private var translationDownloadConfig: TranslationSession.Configuration?

    var body: some View {
        VStack(spacing: 0) {
            translationModelsContent
        }
        .task {
            await translationService.refreshLanguageStatuses()
        }
        .sheet(isPresented: $isManagingTranslationLanguages) {
            manageTranslationLanguagesSheet
        }
        .onChange(of: isManagingTranslationLanguages) {
            if !isManagingTranslationLanguages {
                Task {
                    await translationService.refreshLanguageStatuses()
                }
            }
        }
    }

    private var installedTranslationLanguages: [Locale.Language] {
        TranslationService.supportedTargetLanguages.filter { lang in
            translationService.languageStatuses[lang.minimalIdentifier] == .installed
        }
    }

    private var translationModelsContent: some View {
        VStack(spacing: 0) {
            if translationService.languageStatuses.isEmpty {
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
            } else if installedTranslationLanguages.isEmpty {
                HStack {
                    Label {
                        Text("settings.translation_models_no_installed")
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
                ForEach(Array(installedTranslationLanguages.enumerated()), id: \.element.minimalIdentifier) { index, lang in
                    if index > 0 {
                        Divider().padding(.leading, 46)
                    }
                    translationModelRow(for: lang, showAction: false)
                }
            }

            Divider().padding(.leading, 46)

            Button {
                Task {
                    await translationService.refreshLanguageStatuses()
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
                isManagingTranslationLanguages = true
            } label: {
                HStack {
                    Label {
                        Text("settings.translation_models_manage")
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

    private func translationModelRow(for lang: Locale.Language, showAction: Bool = true) -> some View {
        let status = translationService.languageStatuses[lang.minimalIdentifier]
        let displayName = Locale.current.localizedString(forIdentifier: lang.minimalIdentifier) ?? lang.minimalIdentifier

        return HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 13, weight: .regular))
                    Text(translationStatusDescription(for: status))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(translationStatusColor(for: status))
                }
            } icon: {
                translationStatusIcon(for: status)
                    .frame(width: 24)
            }

            Spacer()

            if showAction {
                translationModelAction(for: lang, status: status)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func translationStatusIcon(for status: LanguageAvailability.Status?) -> some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.green)
        case .supported:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case .unsupported:
            Image(systemName: "xmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
        case nil:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        @unknown default:
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func translationStatusDescription(for status: LanguageAvailability.Status?) -> LocalizedStringKey {
        switch status {
        case .installed: "model_status.installed"
        case .supported: "model_status.not_downloaded"
        case .unsupported: "model_status.unsupported"
        case nil: "model_status.checking"
        @unknown default: "model_status.checking"
        }
    }

    private func translationStatusColor(for status: LanguageAvailability.Status?) -> Color {
        switch status {
        case .installed: .green
        case .supported: .secondary
        case .unsupported: .secondary.opacity(0.5)
        case nil: .secondary
        @unknown default: .secondary
        }
    }

    @ViewBuilder
    private func translationModelAction(for lang: Locale.Language, status: LanguageAvailability.Status?) -> some View {
        switch status {
        case .supported:
            Button {
                let source = Locale.Language(identifier: "en")
                translationDownloadConfig?.invalidate()
                translationDownloadConfig = nil
                translationDownloadConfig = TranslationSession.Configuration(
                    source: source,
                    target: lang
                )
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

        case .installed:
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

        case .unsupported, nil:
            EmptyView()
        @unknown default:
            EmptyView()
        }
    }

    private var manageTranslationLanguagesSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("settings.translation_models_manage_title")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(TranslationService.supportedTargetLanguages.enumerated()), id: \.element.minimalIdentifier) { index, lang in
                        if index > 0 {
                            Divider().padding(.leading, 46)
                        }
                        translationModelRow(for: lang, showAction: true)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("settings.done") {
                    isManagingTranslationLanguages = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 520, height: 420)
        .translationTask(translationDownloadConfig) { session in
            try? await session.prepareTranslation()
            await translationService.refreshLanguageStatuses()
        }
        .task {
            await translationService.refreshLanguageStatuses()
        }
    }
}
