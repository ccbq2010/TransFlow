import SwiftUI
import AVKit

/// NSViewRepresentable wrapper around AVPlayerView.
/// Replaces SwiftUI `VideoPlayer` which crashes in release builds due to
/// _AVKit_SwiftUI metadata resolution failure (getSuperclassMetadata).
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsSharingServiceButton = false
        view.showsFullScreenToggleButton = false
        view.player = player
        ErrorLogger.shared.log(
            "AVPlayerViewRepresentable created, player=\(player != nil)",
            source: "VideoHistory"
        )
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
            ErrorLogger.shared.log(
                "AVPlayerViewRepresentable updated player, player=\(player != nil)",
                source: "VideoHistory"
            )
        }
    }
}

/// Observable model for video playback state in history preview.
@Observable
@MainActor
final class VideoHistoryPlayerModel {
    var player: AVPlayer?
    var activeSegmentIndex: Int?
    var segments: [VideoTranscriptionSegment] = []
    private var timeObserverToken: Any?

    private var currentURL: URL?

    func setup(url: URL, segments: [VideoTranscriptionSegment]) {
        self.segments = segments
        guard url != currentURL else { return }
        cleanup()
        currentURL = url
        ErrorLogger.shared.log(
            "Setting up video player for: \(url.lastPathComponent)",
            source: "VideoHistory"
        )
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        startObservation()
    }

    func seekToSegment(at index: Int) {
        guard index >= 0, index < segments.count else { return }
        let segment = segments[index]
        let time = CMTime(seconds: segment.startTime, preferredTimescale: 600)
        player?.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        activeSegmentIndex = index
    }

    func cleanup() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
        player?.pause()
        player = nil
        activeSegmentIndex = nil
        ErrorLogger.shared.log(
            "Video player cleaned up (was: \(currentURL?.lastPathComponent ?? "nil"))",
            source: "VideoHistory"
        )
        currentURL = nil
    }

    private func startObservation() {
        guard let player, timeObserverToken == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cmTime in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let time = CMTimeGetSeconds(cmTime)
                var best: Int?
                for (i, seg) in self.segments.enumerated() {
                    if time >= seg.startTime && time < seg.endTime {
                        best = i
                        break
                    }
                }
                if self.activeSegmentIndex != best {
                    self.activeSegmentIndex = best
                }
            }
        }
    }
}

/// Detail pane for a video/audio transcription session: player, segment
/// editing, speaker rename, and rich/markdown preview.
struct VideoSessionDetailView: View {
    let session: VideoSessionFile
    let store: VideoJSONLStore

    @State private var entries: [VideoJSONLContentEntry] = []
    @State private var playerModel = VideoHistoryPlayerModel()
    @State private var previewMode: PreviewMode = .rich
    @State private var showTimestamps = true
    @State private var showTranslation = true
    @State private var copyFeedback = false
    @State private var renamingSpeakerId: String?
    @State private var speakerRenameText: String = ""
    @State private var showSpeakerRenameAlert = false
    @State private var videoPlayerHeight: CGFloat = 280
    @GestureState private var dragOffset: CGFloat = 0

    /// Index of the segment currently being edited (sentence-level post-editing).
    /// nil = not editing. Reset to nil on session load to avoid cross-session index drift.
    @State private var editingIndex: Int?
    /// Draft text for the segment being edited. Kept separate so ESC can revert.
    @State private var editingDraft: String = ""

    private var sourceFileURL: URL? {
        if let path = session.originalFilePath {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private var isVideo: Bool {
        guard let url = sourceFileURL else { return false }
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }

    var body: some View {
        VStack(spacing: 0) {
            detailToolbar

            Divider()

            if let url = sourceFileURL {
                if isVideo {
                    AVPlayerViewRepresentable(player: playerModel.player)
                        .frame(minWidth: 300, maxWidth: .infinity)
                        .frame(height: max(150, min(videoPlayerHeight + dragOffset, 600)))
                        .clipped()

                    videoResizeHandle
                } else {
                    audioPlayerHeader(url: url)
                    Divider()
                }
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
        .onDisappear { playerModel.cleanup() }
        .alert("speaker.rename_title", isPresented: $showSpeakerRenameAlert) {
            TextField("", text: $speakerRenameText)
            Button("session.cancel", role: .cancel) {
                renamingSpeakerId = nil
            }
            Button("history.done") {
                commitSpeakerRename()
            }
        } message: {
            Text("speaker.rename_prompt")
        }
    }

    private var videoResizeHandle: some View {
        Divider()
            .overlay(
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
            )
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        let final = videoPlayerHeight + value.translation.height
                        videoPlayerHeight = min(max(final, 150), 600)
                    }
            )
    }

    private func beginSpeakerRename(_ speakerId: String) {
        renamingSpeakerId = speakerId
        speakerRenameText = SpeakerDisplayName.displayName(for: speakerId)
        showSpeakerRenameAlert = true
    }

    private func commitSpeakerRename() {
        guard let oldId = renamingSpeakerId else { return }
        let newName = speakerRenameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != SpeakerDisplayName.displayName(for: oldId) else {
            renamingSpeakerId = nil
            return
        }

        store.renameSpeaker(in: session.url, from: oldId, to: newName)
        renamingSpeakerId = nil
        loadSession()
    }

    private func loadSession() {
        ErrorLogger.shared.log(
            "Loading video session: \(session.name), id=\(session.id)",
            source: "VideoHistory"
        )
        entries = store.readEntries(from: session.url)
        ErrorLogger.shared.log(
            "Loaded \(entries.count) entries, sourceFile=\(sourceFileURL?.path ?? "nil"), isVideo=\(isVideo)",
            source: "VideoHistory"
        )
        let segments = entries.map { entry in
            VideoTranscriptionSegment(
                startTime: entry.startTime,
                endTime: entry.endTime,
                text: entry.originalText,
                translation: entry.translatedText,
                speakerId: entry.speakerId
            )
        }
        if let url = sourceFileURL {
            DispatchQueue.main.async {
                playerModel.setup(url: url, segments: segments)
            }
        } else {
            ErrorLogger.shared.log(
                "No source file URL, skipping player setup",
                source: "VideoHistory"
            )
            playerModel.segments = segments
        }
        // Cancel any in-progress edit when switching sessions.
        editingIndex = nil
        editingDraft = ""
    }

    // MARK: - Audio Player Header

    private func audioPlayerHeader(url: URL) -> some View {
        MediaPlayerBarView(playerModel: playerModel, title: session.videoFile ?? session.name)
    }

    // MARK: - Sentence Editing

    /// Start editing a segment by index. Seeds the draft from the current text.
    private func beginEdit(at index: Int) {
        guard playerModel.segments.indices.contains(index) else { return }
        editingIndex = index
        editingDraft = playerModel.segments[index].text
    }

    /// Commit the edited draft: persist to disk and update both in-memory copies
    /// (`playerModel.segments` for display, `entries` for export source-of-truth).
    /// Empty (whitespace-only) text is rejected — the edit is cancelled instead.
    private func commitEdit(at index: Int) {
        guard playerModel.segments.indices.contains(index),
              entries.indices.contains(index) else { cancelEdit(); return }
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
            playerModel.segments[index].text = trimmed
            entries[index].originalText = trimmed
        } else {
            ErrorLogger.shared.log(
                "Failed to persist video entry edit at index \(index)",
                source: "VideoHistory"
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
                    ForEach(Array(playerModel.segments.enumerated()), id: \.element.id) { index, segment in
                        VideoSegmentRow(
                            segment: segment,
                            isActive: playerModel.activeSegmentIndex == index,
                            onTap: {
                                playerModel.seekToSegment(at: index)
                            },
                            onSpeakerTap: { speakerId in
                                beginSpeakerRename(speakerId)
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
            .onChange(of: playerModel.activeSegmentIndex) { _, newIndex in
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
        generateVideoMarkdownPreview(
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

                    if let duration = session.durationSeconds {
                        HStack(spacing: 3) {
                            Image(systemName: "video")
                                .font(.system(size: 9, weight: .medium))
                            Text(TranscriptionExporter.formatTimestamp(duration))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.blue.opacity(0.1))
                        )
                    }

                    if session.speakerCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2")
                                .font(.system(size: 9, weight: .medium))
                            Text("\(session.speakerCount)")
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

            Menu {
                ForEach(ExportFormat.allCases) { format in
                    Button {
                        Task {
                            await TranscriptionExporter.exportVideoToFile(
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

    // MARK: - Video Markdown

    private func generateVideoMarkdownPreview(
        entries: [VideoJSONLContentEntry],
        sessionName: String,
        showTimestamps: Bool,
        showTranslation: Bool
    ) -> String {
        guard !entries.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("# \(sessionName)")
        lines.append("")

        for entry in entries {
            var line = ""
            if showTimestamps {
                line += "**[\(TranscriptionExporter.formatTimestamp(entry.startTime))]** "
            }
            if let speaker = entry.speakerId {
                line += "_\(SpeakerDisplayName.displayName(for: speaker))_: "
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
}
