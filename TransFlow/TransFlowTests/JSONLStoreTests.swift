import Testing
import Foundation
@testable import TransFlow

/// File-level persistence tests for JSONLStore, isolated in a temporary directory.
/// Covers session lifecycle plus the atomic-rewrite flush/reopen invariants:
/// editing a session must not lose pending appends, and subsequent appends must
/// keep landing in the same file.
@MainActor
struct JSONLStoreTests {

    private func makeStore() -> (store: JSONLStore, baseDirectory: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transflow-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (JSONLStore(baseDirectory: base), base)
    }

    private func makeEntry(
        text: String,
        start: String = "2026-01-01T00:00:00Z",
        end: String = "2026-01-01T00:00:01Z"
    ) -> JSONLContentEntry {
        JSONLContentEntry(
            startTime: start,
            endTime: end,
            originalText: text,
            translatedText: nil
        )
    }

    // MARK: - Session Lifecycle

    @Test func createSessionCreatesFileWithMetadata() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let name = store.createSession(name: "test-session")
        #expect(name == "test-session")
        #expect(store.currentFileURL != nil)

        let lines = store.readAllLines(from: store.currentFileURL!)
        #expect(lines.count == 1)
        guard case .metadata = lines[0] else {
            Issue.record("First line should be metadata")
            return
        }
    }

    @Test func appendEntryPersistsContent() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        store.appendEntry(entry: makeEntry(text: "hello"))

        let entries = store.readEntries(from: store.currentFileURL!)
        #expect(entries.count == 1)
        #expect(entries[0].originalText == "hello")
    }

    @Test func renameSessionMovesFile() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "old-name")
        #expect(store.renameSession(from: "old-name", to: "new-name"))

        let sessions = store.listSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].name == "new-name")
    }

    @Test func deleteSessionRemovesFile() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        #expect(store.deleteSession(name: "test"))
        #expect(store.listSessions().isEmpty)
    }

    // MARK: - Entry Editing (atomic rewrite invariants)

    @Test func updateEntryUpdatesUniqueMatch() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        let entry = makeEntry(text: "original")
        store.appendEntry(entry: entry)

        let ok = store.updateEntry(
            in: store.currentFileURL!,
            matchingStartTime: entry.startTime,
            matchingEndTime: entry.endTime,
            originalText: "edited",
            translatedText: "translated"
        )
        #expect(ok)

        let entries = store.readEntries(from: store.currentFileURL!)
        #expect(entries.count == 1)
        #expect(entries[0].originalText == "edited")
        #expect(entries[0].translatedText == "translated")
    }

    @Test func updateEntryFailsOnNoMatch() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        store.appendEntry(entry: makeEntry(text: "hello"))

        let ok = store.updateEntry(
            in: store.currentFileURL!,
            matchingStartTime: "1999-01-01T00:00:00Z",
            matchingEndTime: "1999-01-01T00:00:01Z",
            originalText: "nope",
            translatedText: nil
        )
        #expect(!ok)

        let entries = store.readEntries(from: store.currentFileURL!)
        #expect(entries.count == 1)
        #expect(entries[0].originalText == "hello")
    }

    @Test func updateEntryFailsOnMultipleMatches() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        // Duplicate (startTime, endTime) key — the de-facto primary key must be unique.
        let a = makeEntry(text: "first", start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:01Z")
        let b = makeEntry(text: "second", start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:01Z")
        store.appendEntry(entry: a)
        store.appendEntry(entry: b)

        let ok = store.updateEntry(
            in: store.currentFileURL!,
            matchingStartTime: a.startTime,
            matchingEndTime: a.endTime,
            originalText: "edited",
            translatedText: nil
        )
        #expect(!ok)
    }

    /// Regression test for the flush-before-atomic-rewrite fix: editing the first
    /// entry while a second append is still pending must not drop the second entry.
    @Test func updateEntryDoesNotLosePendingAppends() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        let a = makeEntry(text: "first", start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:01Z")
        let b = makeEntry(text: "second", start: "2026-01-01T00:00:02Z", end: "2026-01-01T00:00:03Z")
        store.appendEntry(entry: a)
        store.appendEntry(entry: b)

        let ok = store.updateEntry(
            in: store.currentFileURL!,
            matchingStartTime: a.startTime,
            matchingEndTime: a.endTime,
            originalText: "edited",
            translatedText: nil
        )
        #expect(ok)

        let entries = store.readEntries(from: store.currentFileURL!)
        #expect(entries.count == 2)
        #expect(entries[0].originalText == "edited")
        #expect(entries[1].originalText == "second")
    }

    /// Regression test for the reopen-handle fix: after an atomic rewrite, appends
    /// must land in the new inode instead of silently writing to the replaced file.
    @Test func appendAfterUpdateEntryStillPersists() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        store.createSession(name: "test")
        let a = makeEntry(text: "first", start: "2026-01-01T00:00:00Z", end: "2026-01-01T00:00:01Z")
        store.appendEntry(entry: a)

        let ok = store.updateEntry(
            in: store.currentFileURL!,
            matchingStartTime: a.startTime,
            matchingEndTime: a.endTime,
            originalText: "edited",
            translatedText: nil
        )
        #expect(ok)

        // Append after the rewrite — must be visible on re-read.
        let c = makeEntry(text: "third", start: "2026-01-01T00:00:04Z", end: "2026-01-01T00:00:05Z")
        store.appendEntry(entry: c)

        let entries = store.readEntries(from: store.currentFileURL!)
        #expect(entries.count == 2)
        #expect(entries[0].originalText == "edited")
        #expect(entries[1].originalText == "third")
    }
}
