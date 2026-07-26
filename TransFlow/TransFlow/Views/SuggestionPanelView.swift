import SwiftUI

/// Displays a suggested answer in a floating panel beside the transcription area.
struct SuggestionPanelView: View {
    @Bindable var viewModel: AnswerSuggestionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 320)
        .background(.background)
        .overlay(alignment: .topTrailing) {
            closeButton
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            Text("suggestion.title")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var closeButton: some View {
        Button {
            viewModel.dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isGenerating {
            generatingView
        } else if let suggestion = viewModel.currentSuggestion {
            suggestionContent(suggestion)
        } else if let error = viewModel.errorMessage {
            errorView(error)
        } else if let question = viewModel.lastDetectedQuestion {
            waitingView(question)
        }
    }

    private var generatingView: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("suggestion.generating")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private func suggestionContent(_ suggestion: SuggestedAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let question = viewModel.lastDetectedQuestion {
                    Text(question.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }

                Text(suggestion.text)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)

                if !suggestion.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("suggestion.sources")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(suggestion.sources, id: \.self) { source in
                            Text("• \(source)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private func waitingView(_ question: DetectedQuestion) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
            Text(question.text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Text("suggestion.processing")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
