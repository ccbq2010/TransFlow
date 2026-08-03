import SwiftUI

/// History view with a left session list and right content preview.
/// Supports both live transcription and video transcription sessions.
struct HistoryView: View {
    @Binding var initialSessionID: String?

    @State private var liveStore = JSONLStore()
    @State private var videoStore = VideoJSONLStore()
    @State private var allItems: [HistoryItem] = []
    @State private var selectedItemID: String?
    @State private var filter: HistoryFilter = .all

    private var filteredItems: [HistoryItem] {
        switch filter {
        case .all: return allItems
        case .live: return allItems.filter { $0.type == .live }
        case .media: return allItems.filter { $0.type == .audio }
        case .video: return allItems.filter { $0.type == .video }
        }
    }

    var body: some View {
        Group {
            if allItems.isEmpty {
                emptyState
            } else {
                HSplitView {
                    SessionListView(
                        items: filteredItems,
                        selectedItemID: $selectedItemID,
                        filter: $filter,
                        liveStore: liveStore,
                        videoStore: videoStore,
                        onRefresh: refreshSessions
                    )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

                    if let selected = allItems.first(where: { $0.id == selectedItemID }) {
                        switch selected.type {
                        case .live:
                            if let session = selected.liveSession {
                                SessionDetailView(session: session, store: liveStore)
                            }
                        case .video, .audio:
                            if let session = selected.videoSession {
                                VideoSessionDetailView(session: session, store: videoStore)
                            }
                        }
                    } else {
                        noSelectionView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            refreshSessions()
            consumeInitialSessionID()
        }
        .onChange(of: initialSessionID) {
            consumeInitialSessionID()
        }
    }

    private func consumeInitialSessionID() {
        if let id = initialSessionID {
            refreshSessions()
            selectedItemID = id
            initialSessionID = nil
        }
    }

    private func refreshSessions() {
        let liveSessions = liveStore.listSessions().map { HistoryItem(live: $0) }
        let videoSessions = videoStore.listSessions().map { HistoryItem(video: $0) }
        allItems = (liveSessions + videoSessions).sorted { $0.createdAt > $1.createdAt }
        if selectedItemID == nil || !allItems.contains(where: { $0.id == selectedItemID }) {
            selectedItemID = filteredItems.first?.id
        }
    }

    // MARK: - Empty States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.quaternary)

            Text("history.empty_title")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            Text("history.empty_description")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelectionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.quaternary)

            Text("history.select_session")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
