import SwiftUI

/// Diarization model status section of the Settings page.
struct DiarizationModelsSettingsSection: View {
    @State private var diarizationModelManager = DiarizationModelManager.shared

    var body: some View {
        diarizationModelContent
            .task {
                diarizationModelManager.checkStatus()
            }
    }

    private var diarizationModelContent: some View {
        VStack(spacing: 0) {
            // Model status row
            HStack(spacing: 8) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.diarization.pyannote_model")
                            .font(.system(size: 13, weight: .regular))
                        Text(diarizationStatusDescription)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(diarizationStatusColor)
                    }
                } icon: {
                    diarizationStatusIcon
                        .frame(width: 24)
                }

                Spacer()

                Text("~100 MB")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                diarizationModelAction
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var diarizationStatusIcon: some View {
        switch diarizationModelManager.modelStatus {
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
        case .checking:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        }
    }

    private var diarizationStatusDescription: LocalizedStringKey {
        switch diarizationModelManager.modelStatus {
        case .installed: "model_status.installed"
        case .notDownloaded: "model_status.not_downloaded"
        case .downloading(let progress): "model_status.downloading_percent \(Int(progress * 100))"
        case .failed(let message): LocalizedStringKey("model_status.failed_detail \(message)")
        case .checking: "model_status.checking"
        }
    }

    private var diarizationStatusColor: Color {
        switch diarizationModelManager.modelStatus {
        case .installed: .green
        case .notDownloaded: .secondary
        case .downloading: .blue
        case .failed: .orange
        case .checking: .secondary
        }
    }

    @ViewBuilder
    private var diarizationModelAction: some View {
        switch diarizationModelManager.modelStatus {
        case .notDownloaded, .failed:
            Button {
                Task {
                    await diarizationModelManager.downloadModels()
                }
            } label: {
                Text("model_action.select")
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

        case .checking:
            EmptyView()
        }
    }
}
