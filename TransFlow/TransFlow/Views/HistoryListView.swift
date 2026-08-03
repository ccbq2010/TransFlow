import SwiftUI

/// Session list sidebar for the History page: filter, rename, and delete sessions.
struct SessionListView: View {
    let items: [HistoryItem]
    @Binding var selectedItemID: String?
    @Binding var filter: HistoryFilter
    let liveStore: JSONLStore
    let videoStore: VideoJSONLStore
    let onRefresh: () -> Void

    @State private var isEditMode = false
    @State private var selectedForDeletion: Set<String> = []
    @State private var renamingItemID: String?
    @State private var renameText: String = ""
    @State private var itemToDelete: HistoryItem?
    @State private var showDeleteConfirmation = false
    @State private var showBatchDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            listHeader

            Divider()

            if isEditMode {
                editableList
            } else {
                selectableList
            }

            if isEditMode {
                editModeFooter
            }
        }
        .alert("history.delete_confirm_title", isPresented: $showDeleteConfirmation) {
            Button("history.delete", role: .destructive) {
                if let item = itemToDelete {
                    deleteItem(item)
                }
            }
            Button("session.cancel", role: .cancel) {}
        } message: {
            if let item = itemToDelete {
                Text("history.delete_confirm_message \(item.name)")
            }
        }
        .alert("history.delete_selected_confirm_title", isPresented: $showBatchDeleteConfirmation) {
            Button("history.delete", role: .destructive) {
                deleteSelectedItems()
            }
            Button("session.cancel", role: .cancel) {}
        } message: {
            Text("history.delete_selected_confirm_message \(selectedForDeletion.count)")
        }
    }

    // MARK: - List Header

    private var listHeader: some View {
        HStack(spacing: 8) {
            Picker(selection: $filter) {
                ForEach(HistoryFilter.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.menu)
            .fixedSize()

            Text("\(items.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(.quaternary.opacity(0.4))
                )

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditMode.toggle()
                    if !isEditMode {
                        selectedForDeletion.removeAll()
                    }
                }
            } label: {
                Text(isEditMode ? "history.done" : "history.edit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isEditMode ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Lists

    private var selectableList: some View {
        List(selection: $selectedItemID) {
            ForEach(items) { item in
                sessionRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button {
                            renamingItemID = item.id
                            renameText = item.name
                        } label: {
                            Label("history.rename", systemImage: "pencil")
                        }

                        Divider()

                        Button(role: .destructive) {
                            itemToDelete = item
                            showDeleteConfirmation = true
                        } label: {
                            Label("history.delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.inset)
    }

    private var editableList: some View {
        List {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    let isSelected = selectedForDeletion.contains(item.id)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

                    sessionRow(item: item)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleSelection(item.id)
                }
            }
        }
        .listStyle(.inset)
    }

    private func sessionRow(item: HistoryItem) -> some View {
        HistoryRowView(
            item: item,
            isRenaming: renamingItemID == item.id,
            renameText: $renameText,
            onCommitRename: { commitRename(item: item) },
            onCancelRename: { renamingItemID = nil }
        )
    }

    // MARK: - Edit Mode Footer

    private var editModeFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    if selectedForDeletion.count == items.count {
                        selectedForDeletion.removeAll()
                    } else {
                        selectedForDeletion = Set(items.map(\.id))
                    }
                } label: {
                    Text(selectedForDeletion.count == items.count
                         ? "history.deselect_all" : "history.select_all")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(role: .destructive) {
                    showBatchDeleteConfirmation = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                        Text("history.delete_count \(selectedForDeletion.count)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(selectedForDeletion.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.red))
                }
                .buttonStyle(.plain)
                .disabled(selectedForDeletion.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.background)
    }

    // MARK: - Actions

    private func toggleSelection(_ id: String) {
        if selectedForDeletion.contains(id) {
            selectedForDeletion.remove(id)
        } else {
            selectedForDeletion.insert(id)
        }
    }

    private func commitRename(item: HistoryItem) {
        let newName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else {
            renamingItemID = nil
            return
        }
        switch item.type {
        case .live:
            if liveStore.renameSession(from: item.name, to: newName) {
                renamingItemID = nil
                onRefresh()
                selectedItemID = "live_\(newName)"
            }
        case .video, .audio:
            if videoStore.renameSession(from: item.name, to: newName) {
                renamingItemID = nil
                onRefresh()
                selectedItemID = "video_\(newName)"
            }
        }
    }

    private func deleteItem(_ item: HistoryItem) {
        let wasSelected = selectedItemID == item.id
        switch item.type {
        case .live:
            liveStore.deleteSession(name: item.name)
        case .video, .audio:
            videoStore.deleteSession(name: item.name)
        }
        itemToDelete = nil
        onRefresh()
        if wasSelected {
            selectedItemID = items.first?.id
        }
    }

    private func deleteSelectedItems() {
        for id in selectedForDeletion {
            if let item = items.first(where: { $0.id == id }) {
                switch item.type {
                case .live:
                    liveStore.deleteSession(name: item.name)
                case .video, .audio:
                    videoStore.deleteSession(name: item.name)
                }
            }
        }
        selectedForDeletion.removeAll()
        isEditMode = false
        onRefresh()
    }
}

/// Single row in the history session list (badge, name, recording/entry metadata).
struct HistoryRowView: View {
    let item: HistoryItem
    let isRenaming: Bool
    @Binding var renameText: String
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { onCommitRename() }
                    .onExitCommand { onCancelRename() }
            } else {
                HStack(spacing: 6) {
                    typeBadge

                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 8) {
                Text(item.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                if item.type == .live, let session = item.liveSession, session.hasRecording {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .medium))
                        Text(formatDuration(ms: session.totalRecordingDurationMs))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(.orange)
                }

                if (item.type == .video || item.type == .audio), let session = item.videoSession,
                   let duration = session.durationSeconds {
                    HStack(spacing: 3) {
                        Image(systemName: item.type == .video ? "video" : "music.note")
                            .font(.system(size: 9, weight: .medium))
                        Text(formatDurationSeconds(duration))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                    }
                    .foregroundStyle(item.type == .video ? .blue : .green)
                }

                HStack(spacing: 3) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 9, weight: .medium))
                    Text("\(item.entryCount)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var typeBadge: some View {
        let color: Color
        let labelKey: LocalizedStringKey
        switch item.type {
        case .live:
            color = .orange
            labelKey = "history.badge.live"
        case .audio:
            color = .green
            labelKey = "history.badge.audio"
        case .video:
            color = .blue
            labelKey = "history.badge.video"
        }
        return Text(labelKey)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private func formatDuration(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatDurationSeconds(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
