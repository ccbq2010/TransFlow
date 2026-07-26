import SwiftUI
import UniformTypeIdentifiers

/// Manage knowledge base documents: import, view, and delete.
struct KnowledgeManagementView: View {
    @State private var store = KnowledgeStore.shared
    @State private var showingFilePicker = false
    @State private var showingTextInput = false
    @State private var inputText = ""
    @State private var inputName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            documentList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { store.load() }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showingTextInput) {
            textInputSheet
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("knowledge.title")
                    .font(.system(size: 16, weight: .semibold))
                Text("knowledge.subtitle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    showingFilePicker = true
                } label: {
                    Label("knowledge.import_file", systemImage: "doc.badge.plus")
                }
                Button {
                    inputName = ""
                    inputText = ""
                    showingTextInput = true
                } label: {
                    Label("knowledge.import_text", systemImage: "text.cursor")
                }
            } label: {
                Label("knowledge.add", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var documentList: some View {
        if store.documents.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 36, weight: .thin))
                    .foregroundStyle(.quaternary)
                Text("knowledge.empty")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.documents) { doc in
                        documentRow(doc)
                        Divider()
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func documentRow(_ doc: KnowledgeDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 20))
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.name)
                    .font(.system(size: 14, weight: .medium))
                Text("knowledge.chunk_count \(doc.chunkCount)")
                Text("\(doc.chunkCount) \(Text("knowledge.chunk_count"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.deleteDocument(id: doc.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
        .padding(.vertical, 10)
    }

    private var textInputSheet: some View {
        VStack(spacing: 16) {
            Text("knowledge.import_text_title")
                .font(.system(size: 16, weight: .semibold))
                .padding(.top, 20)

            TextField("knowledge.name_placeholder", text: $inputName)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $inputText)
                .font(.system(size: 13))
                .border(.quaternary, width: 0.5)
                .frame(minHeight: 200)

            HStack {
                Button("session.cancel", role: .cancel) {
                    showingTextInput = false
                }
                Spacer()
                Button("knowledge.import_confirm") {
                    let name = inputName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty && !inputText.isEmpty {
                        store.importText(inputText, name: name)
                        showingTextInput = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inputText.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 400)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                _ = store.importDocument(from: url)
            }
        case .failure:
            break
        }
    }
}
