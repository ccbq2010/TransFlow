import SwiftUI

/// Preview mode for transcription sessions (rich list vs. markdown).
enum PreviewMode: String, CaseIterable {
    case rich
    case markdown
}

/// Detail pane for a live transcription session: audio playback, sentence
/// editing, rich/markdown preview, and AI summary.
struct SessionDetailView: View {
    let session: SessionFile
    let store: JSONLStore

    @State private var entries: [JSONLContentEntry] = []
    @State private var previewMode: PreviewMode = .rich
    @State private var showTimestamps = true
    @State private var showTranslation = true
    @State private var copyFeedback = false
    @State private var audioPlayer = SessionAudioPlayer()

    /// Index of the entry currently being edited (sentence-level post-editing).
    /// nil = not editing. Reset to nil on session load to avoid cross-session index drift.
    @State private var editingIndex: Int?
    /// Draft text for the entry being edited. Kept separate from `entries` so ESC can revert.
    @State private var editingDraft: String = ""

    /// Summary state for AI-generated meeting summary.
    @State private var showingSummary = false
    @State private var summaryText: String?
    @State private var isGeneratingSummary = false
    @State private var summaryError: String?

    private var hasRecording: Bool { session.hasRecording }

    var body: some View {
        VStack(spacing: 0) {
            detailToolbar

            Divider()

            if hasRecording {
                AudioPlayerBarView(player: audioPlayer)
                Divider()
            }

            if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.page.slash")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundStyle(.quaternary)
                    Text("history.no_entries")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if previewMode == .rich {
                    richPreview
                } else {
                    markdownPreview
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadSession() }
        .onChange(of: session.id) { loadSession() }
        .onDisappear { audioPlayer.unload() }
        .sheet(isPresented: $showingSummary) {
            if let summary = summaryText {
                SummarySheet(summary: summary, sessionName: session.name, onDismiss: {
                    showingSummary = false
                })
            }
        }
    }

    private func loadSession() {
        let allLines = store.readAllLines(from: session.url)
        entries = allLines.compactMap { if case .content(let e) = $0 { return e } else { return nil } }
        audioPlayer.unload()
        if hasRecording {
            audioPlayer.load(allLines: allLines)
        }
        // Cancel any in-progress edit when switching sessions.
        editingIndex = nil
        editingDraft = ""
    }

    // MARK: - Sentence Editing

    /// Start editing an entry by index. Seeds the draft from the current text.
    private func beginEdit(at index: Int) {
        guard entries.indices.contains(index) else { return }
        editingIndex = index
        editingDraft = entries[index].originalText
    }

    /// Commit the edited draft: persist to disk and update the in-memory entry.
    /// Empty (whitespace-only) text is rejected — the edit is cancelled instead.
    private func commitEdit(at index: Int) {
        guard entries.indices.contains(index) else { cancelEdit(); return }
        let trimmed = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { cancelEdit(); return }

        let entry = entries[index]
        let ok = store.updateEntry(
            in: session.url,
            matchingStartTime: entry.startTime,
            matchingEndTime: entry.endTime,
            originalText: trimmed,
            translatedText: entry.translatedText
        )
        if ok {
            entries[index].originalText = trimmed
        } else {
            ErrorLogger.shared.log(
                "Failed to persist entry edit at index \(index)",
                source: "HistoryView"
            )
        }
        editingIndex = nil
        editingDraft = ""
    }

    /// Discard the current edit and revert to the stored text.
    private func cancelEdit() {
        editingIndex = nil
        editingDraft = ""
    }

    // MARK: - Rich Preview

    private var richPreview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        EntryRowView(
                            entry: entry,
                            isActive: audioPlayer.activeEntryIndex == index,
                            hasAudioOffset: audioPlayer.entryOffset(at: index) != nil,
                            onTimestampTap: {
                                if audioPlayer.entryOffset(at: index) != nil {
                                    audioPlayer.seekToEntry(at: index)
                                    if !audioPlayer.isPlaying {
                                        audioPlayer.play()
                                    }
                                }
                            },
                            isEditing: editingIndex == index,
                            editingDraft: editingIndex == index ? editingDraft : nil,
                            onBeginEdit: { beginEdit(at: index) },
                            onDraftChange: { newVal in editingDraft = newVal },
                            onCommitEdit: { commitEdit(at: index) },
                            onCancelEdit: { cancelEdit() }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .onChange(of: audioPlayer.activeEntryIndex) { _, newIndex in
                if let idx = newIndex {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(idx, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Markdown Preview

    private var markdownText: String {
        generateMarkdownPreview(
            entries: entries,
            sessionName: session.name,
            showTimestamps: showTimestamps,
            showTranslation: showTranslation
        )
    }

    private var markdownPreview: some View {
        VStack(spacing: 0) {
            markdownOptionsBar

            Divider()

            ScrollView {
                Text(markdownText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
            }
        }
    }

    private var markdownOptionsBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                markdownToggle(
                    "history.md.show_time",
                    icon: "clock",
                    isOn: $showTimestamps
                )
                markdownToggle(
                    "history.md.show_translation",
                    icon: "bubble.left.and.text.bubble.right",
                    isOn: $showTranslation
                )
            }

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdownText, forType: .string)
                withAnimation(.easeInOut(duration: 0.2)) {
                    copyFeedback = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copyFeedback = false
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copyFeedback ? "history.md.copied" : "history.md.copy_all")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(copyFeedback ? .green : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(copyFeedback ? AnyShapeStyle(Color.green.opacity(0.1)) : AnyShapeStyle(.quaternary.opacity(0.3)))
                )
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.background)
    }

    private func markdownToggle(
        _ titleKey: LocalizedStringKey,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(titleKey)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isOn.wrappedValue ? .primary : .tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isOn.wrappedValue ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.quaternary.opacity(isOn.wrappedValue ? 0 : 0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Toolbar

    private var detailToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    if hasRecording {
                        HStack(spacing: 3) {
                            Image(systemName: "waveform")
                                .font(.system(size: 9, weight: .medium))
                            Text(formatDuration(ms: session.totalRecordingDurationMs))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.1))
                        )
                    }

                    HStack(spacing: 3) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 9, weight: .medium))
                        Text("\(entries.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(.quaternary.opacity(0.4))
                    )
                }
                Text(session.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            previewModeToggle

            Button {
                Task { await generateSummary() }
            } label: {
                if isGeneratingSummary {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("summary.button", systemImage: "text.textformat")
                }
            }
            .disabled(entries.isEmpty || isGeneratingSummary)
            .help(Text("summary.button"))

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        Task {
                            await TranscriptionExporter.exportToFile(
                                entries: entries,
                                format: format,
                                sessionName: session.name
                            )
                        }
                    } label: {
                        Label(
                            "history.export_format \(format.displayName)",
                            systemImage: format == .srt ? "captions.bubble" : "doc.richtext"
                        )
                    }
                }
            } label: {
                Label("history.export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    private var previewModeToggle: some View {
        HStack(spacing: 0) {
            previewModeButton(.rich, icon: "text.alignleft", titleKey: "history.mode.rich")
            previewModeButton(.markdown, icon: "text.page", titleKey: "history.mode.markdown")
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary.opacity(0.2))
        )
        .padding(.trailing, 8)
    }

    private func previewModeButton(_ mode: PreviewMode, icon: String, titleKey: LocalizedStringKey) -> some View {
        let isSelected = previewMode == mode
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                previewMode = mode
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(titleKey)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isSelected ? .primary : .tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.clear))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Markdown Generation

    private func generateMarkdownPreview(
        entries: [JSONLContentEntry],
        sessionName: String,
        showTimestamps: Bool,
        showTranslation: Bool
    ) -> String {
        guard !entries.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("# \(sessionName)")
        lines.append("")

        let formatter = ISO8601DateFormatter()

        for entry in entries {
            var line = ""

            if showTimestamps {
                let timeStr: String
                if let date = formatter.date(from: entry.startTime) {
                    let displayFormatter = DateFormatter()
                    displayFormatter.dateFormat = "HH:mm:ss"
                    timeStr = displayFormatter.string(from: date)
                } else {
                    timeStr = entry.startTime
                }
                line += "**[\(timeStr)]** "
            }

            line += entry.originalText
            lines.append(line)

            if showTranslation, let translation = entry.translatedText, !translation.isEmpty {
                lines.append("")
                lines.append("> \(translation)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - AI Summary

    private func generateSummary() async {
        isGeneratingSummary = true
        summaryError = nil
        do {
            let summarizer = MeetingSummarizer()
            let result = try await summarizer.summarize(entries: entries, sessionName: session.name)
            summaryText = result
            showingSummary = true
        } catch {
            summaryError = error.localizedDescription
        }
        isGeneratingSummary = false
    }
}

private struct SummarySheet: View {
    let summary: String
    let sessionName: String?
    let onDismiss: () -> Void

    var body: some View {
        SummaryPanelView(summary: summary, sessionName: sessionName, onDismiss: onDismiss)
    }
}

/// Single transcription entry row with inline sentence editing.
struct EntryRowView: View {
    let entry: JSONLContentEntry
    var isActive: Bool = false
    var hasAudioOffset: Bool = false
    var onTimestampTap: (() -> Void)? = nil
    /// Whether this row is currently in edit mode (sentence-level post-editing).
    var isEditing: Bool = false
    /// Draft text when editing; nil when not editing.
    var editingDraft: String? = nil
    var onBeginEdit: (() -> Void)? = nil
    var onDraftChange: ((String) -> Void)? = nil
    var onCommitEdit: (() -> Void)? = nil
    var onCancelEdit: (() -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .frame(height: 0.5)
                .padding(.vertical, 10)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTime)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(hasAudioOffset ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(hasAudioOffset ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.quaternary.opacity(0.3)))
                    )
                    .onHover { inside in
                        if hasAudioOffset {
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                    .onTapGesture {
                        onTimestampTap?()
                    }

                if let speakerId = entry.speakerId {
                    entrySpeakerBadge(speakerId)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if isEditing, let draft = editingDraft {
                        TextField("history.edit.placeholder", text: Binding(
                            get: { draft },
                            set: { onDraftChange?($0) }
                        ))
                        .font(.system(size: 14, weight: .regular))
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onSubmit { onCommitEdit?() }
                        .onExitCommand { onCancelEdit?() }
                    } else {
                        Text(entry.originalText)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }

                    if let translation = entry.translatedText, !translation.isEmpty {
                        Text(translation)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineSpacing(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isEditing ? Color.accentColor.opacity(0.5)
                                  : (isActive ? Color.accentColor.opacity(0.3) : Color.clear),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
            // Double-click to start editing (macOS-native convention, like Finder rename).
            .onTapGesture(count: 2) {
                onBeginEdit?()
            }
            .onChange(of: isEditing) { _, nowEditing in
                if nowEditing { isFocused = true }
            }
            .help(Text(isEditing ? "history.edit.save_hint" : "history.edit.double_click_hint"))
        }
    }

    private func entrySpeakerBadge(_ speakerId: String) -> some View {
        let colorHex = SpeakerColor.color(for: speakerId)
        let displayName = SpeakerDisplayName.displayName(for: speakerId)
        return Text(displayName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(hex: colorHex))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(hex: colorHex).opacity(0.12))
            )
    }

    private var displayTime: String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: entry.startTime) {
            let display = DateFormatter()
            display.dateFormat = "HH:mm:ss"
            return display.string(from: date)
        }
        return entry.startTime
    }
}
