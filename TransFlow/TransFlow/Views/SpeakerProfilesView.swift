import SwiftUI

/// Manage known speaker profiles: view, add, rename, and delete.
struct SpeakerProfilesView: View {
    @State private var store = SpeakerProfilesStore.shared
    @State private var showingEnrollment = false
    @State private var newSpeakerName = ""
    @State private var renamingProfile: SpeakerProfile?
    @State private var renameText = ""
    @State private var showingNameAlert = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            profileList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.load() }
        .sheet(isPresented: $showingEnrollment) {
            enrollmentView(name: newSpeakerName)
        }
        .alert("participants.name_alert.title", isPresented: $showingNameAlert) {
            TextField("participants.name_alert.placeholder", text: $newSpeakerName)
            Button("participants.name_alert.confirm") {
                let trimmed = newSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    showingEnrollment = true
                }
            }
            Button("session.cancel", role: .cancel) {}
        }
        .alert("participants.rename_alert.title", isPresented: Binding(
            get: { renamingProfile != nil },
            set: { if !$0 { renamingProfile = nil } }
        )) {
            TextField("participants.rename_alert.placeholder", text: $renameText)
            Button("participants.rename_alert.confirm") {
                if let profile = renamingProfile {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        store.updateProfile(id: profile.id, name: trimmed)
                    }
                }
                renamingProfile = nil
            }
            Button("session.cancel", role: .cancel) {
                renamingProfile = nil
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("participants.title")
                    .font(.system(size: 16, weight: .semibold))
                Text("participants.subtitle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                newSpeakerName = ""
                showingNameAlert = true
            } label: {
                Label("participants.add", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var profileList: some View {
        if store.profiles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(.quaternary)
                Text("participants.empty")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.profiles) { profile in
                        profileRow(profile)
                        Divider()
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func profileRow(_ profile: SpeakerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 24))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 14, weight: .medium))
                Text("participants.enrolled_date \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                Text("\(Text("participants.enrolled_date")): \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                renamingProfile = profile
                renameText = profile.name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)

            Button {
                store.deleteProfile(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 10)
    }

    private func enrollmentView(name: String) -> some View {
        SpeakerEnrollmentView(
            participantName: name,
            onComplete: { embedding in
                store.addProfile(name: name, embedding: embedding)
                showingEnrollment = false
            },
            onCancel: {
                showingEnrollment = false
            }
        )
    }
}
