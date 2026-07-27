import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Displays the AI-generated meeting summary with copy/export actions.
struct SummaryPanelView: View {
    let summary: String
    let sessionName: String?
    let onDismiss: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
            Text("summary.title")
                .font(.system(size: 15, weight: .semibold))
            if let name = sessionName {
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var content: some View {
        ScrollView {
            Text(summary)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                copyToClipboard()
            } label: {
                Label(copied ? "summary.copied" : "summary.copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                exportSummary()
            } label: {
                Label("summary.export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    private func exportSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(sessionName ?? "Meeting")_Summary.md"
        panel.canCreateDirectories = true

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            var content = ""
            if let name = sessionName {
                content = "# \(name) — Summary\n\n"
            }
            content += summary
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
