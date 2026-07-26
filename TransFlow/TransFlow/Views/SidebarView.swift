import SwiftUI

/// Navigation destinations for the sidebar.
enum SidebarDestination: String, CaseIterable, Identifiable {
    case transcription
    case videoTranscription
    case history
    case participants
    case knowledge
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .transcription: "sidebar.transcription"
        case .videoTranscription: "sidebar.video_transcription"
        case .history: "sidebar.history"
        case .participants: "sidebar.participants"
        case .knowledge: "sidebar.knowledge"
        case .settings: "sidebar.settings"
        }
    }

    var icon: String {
        switch self {
        case .transcription: "waveform"
        case .videoTranscription: "video"
        case .history: "clock.arrow.circlepath"
        case .participants: "person.2"
        case .knowledge: "books.vertical"
        case .settings: "gearshape"
        }
    }
}

/// Apple-style sidebar with navigation destinations.
struct SidebarView: View {
    @Binding var selection: SidebarDestination

    var body: some View {
        List(SidebarDestination.allCases, selection: $selection) { destination in
            Label(destination.title, systemImage: destination.icon)
                .tag(destination)
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 240)
    }
}
