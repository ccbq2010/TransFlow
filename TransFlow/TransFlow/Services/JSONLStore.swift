import Foundation
import AppKit

/// Manages JSONL file persistence in the app's internal `transcriptions` directory.
@MainActor
@Observable
final class JSONLStore {

    // MARK: - State

    /// The filename (without extension) of the current active session.
    private(set) var currentSessionName: String = ""

    /// Full URL of the current session file.
    private(set) var currentFileURL: URL?

    /// Reusable FileHandle for the current session (avoids repeated open/close).
    nonisolated(unsafe) private var writeHandle: FileHandle?

    // MARK: - Private

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let transcriptionsDirectory: URL
    private let recordingsDirectory: URL

    // MARK: - Initialization

    /// - Parameter baseDirectory: Optional override for tests. When nil, files live
    ///   under Application Support/`bundleID`. When set, `transcriptions/` and
    ///   `recordings/` are created inside the given directory.
    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.transcriptionsDirectory = baseDirectory
                .appendingPathComponent("transcriptions", isDirectory: true)
            self.recordingsDirectory = baseDirectory
                .appendingPathComponent("recordings", isDirectory: true)
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let bundleID = Bundle.main.bundleIdentifier ?? "com.transflow"
            self.transcriptionsDirectory = appSupport
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("transcriptions", isDirectory: true)
            self.recordingsDirectory = appSupport
                .appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("recordings", isDirectory: true)
        }
        ensureDirectoryExists()
        // P1-3 修复：监听应用终止通知，确保 writeHandle 被正确关闭
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        // P1-3 修复：deinit 时关闭 writeHandle，防止文件描述符泄漏
        writeHandle?.closeFile()
        writeHandle = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleWillTerminate() {
        // P1-3 修复：应用退出时刷新并关闭 writeHandle
        writeHandle?.synchronizeFile()
        writeHandle?.closeFile()
        writeHandle = nil
    }

    // MARK: - Write Handle Management (P1-2)

    /// P1-2 修复：flush writeHandle 缓冲数据到磁盘，确保后续原子写入不会丢失数据。
    func flushWriteHandle() {
        writeHandle?.synchronizeFile()
    }

    /// P1-2 修复：原子写入后重新打开 writeHandle 并 seek 到末尾。
    /// 因为 `write(to:atomically:)` 会替换底层文件，旧的 FileHandle fd 仍指向旧 inode。
    func reopenWriteHandle() {
        guard let fileURL = currentFileURL else { return }
        writeHandle?.closeFile()
        writeHandle = try? FileHandle(forWritingTo: fileURL)
        writeHandle?.seekToEndOfFile()
    }

    // MARK: - Session Management

    @discardableResult
    func createSession(name: String? = nil) -> String {
        // Close any previously open handle
        writeHandle?.closeFile()
        writeHandle = nil

        let sessionName = name ?? Self.generateDefaultName()
        let fileURL = transcriptionsDirectory.appendingPathComponent("\(sessionName).jsonl")

        let metadata = JSONLMetadata()
        if let line = encodeLine(.metadata(metadata)) {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        currentSessionName = sessionName
        currentFileURL = fileURL

        // Open a reusable handle for subsequent appends
        writeHandle = try? FileHandle(forWritingTo: fileURL)
        writeHandle?.seekToEndOfFile()

        return sessionName
    }

    // MARK: - Appending

    func appendEntry(sentence: TranscriptionSentence) {
        guard let fileURL = currentFileURL else { return }
        let entry = JSONLContentEntry(sentence: sentence)
        guard let line = encodeLine(.content(entry)) else { return }
        appendRaw(line, to: fileURL)
    }

    /// Append a pre-built content entry (with speaker name).
    func appendEntry(entry: JSONLContentEntry) {
        guard let fileURL = currentFileURL else { return }
        guard let line = encodeLine(.content(entry)) else { return }
        appendRaw(line, to: fileURL)
    }

    func appendRecordingStart(fileName: String, timestamp: Date = Date()) {
        guard let fileURL = currentFileURL else { return }
        let marker = JSONLRecordingStart(recordingFile: fileName, timestamp: timestamp)
        guard let line = encodeLine(.recordingStart(marker)) else { return }
        appendRaw(line, to: fileURL)
    }

    func appendRecordingStop(fileName: String, timestamp: Date = Date(), durationMs: Int) {
        guard let fileURL = currentFileURL else { return }
        let marker = JSONLRecordingStop(recordingFile: fileName, timestamp: timestamp, durationMs: durationMs)
        guard let line = encodeLine(.recordingStop(marker)) else { return }
        appendRaw(line, to: fileURL)
    }

    // MARK: - History / Reading

    func listSessions() -> [SessionFile] {
        ensureDirectoryExists()
        do {
            let files = try fileManager.contentsOfDirectory(
                at: transcriptionsDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            return files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> SessionFile? in
                    let name = url.deletingPathExtension().lastPathComponent
                    let allLines = readAllLines(from: url)
                    let metadata = allLines.compactMap { if case .metadata(let m) = $0 { return m } else { return nil } }.first
                    let entryCount = allLines.filter { if case .content = $0 { return true } else { return false } }.count

                    var recordings: [SessionFile.RecordingSegment] = []
                    for line in allLines {
                        if case .recordingStart(let r) = line {
                            recordings.append(.init(fileName: r.recordingFile, timestamp: r.timestamp, durationMs: 0))
                        } else if case .recordingStop(let r) = line {
                            if let idx = recordings.lastIndex(where: { $0.fileName == r.recordingFile }) {
                                recordings[idx] = .init(fileName: r.recordingFile, timestamp: recordings[idx].timestamp, durationMs: r.durationMs)
                            }
                        }
                    }

                    let createdAt: Date
                    if let timeStr = metadata?.createTime,
                       let date = ISO8601DateFormatter().date(from: timeStr) {
                        createdAt = date
                    } else {
                        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                        createdAt = attrs?[.creationDate] as? Date ?? Date.distantPast
                    }
                    return SessionFile(
                        name: name,
                        url: url,
                        createdAt: createdAt,
                        entryCount: entryCount,
                        appVersion: metadata?.appVersion,
                        recordings: recordings
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            return []
        }
    }

    func readEntries(from url: URL) -> [JSONLContentEntry] {
        readAllLines(from: url).compactMap {
            if case .content(let entry) = $0 { return entry } else { return nil }
        }
    }

    func readAllLines(from url: URL) -> [JSONLLine] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = data.components(separatedBy: .newlines)
        var result: [JSONLLine] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(JSONLLine.self, from: lineData) {
                result.append(decoded)
            }
        }
        return result
    }

    func readRecordingFiles(from url: URL) -> [String] {
        readAllLines(from: url).compactMap {
            if case .recordingStart(let r) = $0 { return r.recordingFile } else { return nil }
        }
    }

    func readMetadata(from url: URL) -> JSONLMetadata? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = data.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lineData = firstLine.data(using: .utf8),
              let decoded = try? decoder.decode(JSONLLine.self, from: lineData),
              case .metadata(let meta) = decoded else {
            return nil
        }
        return meta
    }

    // MARK: - Editing

    /// Update an existing content entry's text fields in place.
    ///
    /// The entry is located by its `(startTime, endTime)` pair (the de-facto primary key
    /// since `JSONLContentEntry` has no id field). The whole file is read, the matching
    /// line is rewritten, and the file is written back atomically. Non-content lines
    /// (metadata, recording markers) are preserved verbatim.
    ///
    /// - Returns: `true` if exactly one entry was updated. `false` (with an error log)
    ///   if zero or multiple entries matched the key.
    @discardableResult
    func updateEntry(
        in url: URL,
        matchingStartTime: String,
        matchingEndTime: String,
        originalText: String,
        translatedText: String?
    ) -> Bool {
        let allLines = readAllLines(from: url)
        var newLines: [String] = []
        var matchCount = 0

        for line in allLines {
            switch line {
            case .metadata(let meta):
                if let encoded = encodeLine(.metadata(meta)) {
                    newLines.append(encoded)
                }
            case .content(let entry):
                let updated: JSONLContentEntry
                if entry.startTime == matchingStartTime && entry.endTime == matchingEndTime {
                    matchCount += 1
                    // Only the first match is updated; subsequent matches are logged.
                    if matchCount == 1 {
                        updated = JSONLContentEntry(
                            startTime: entry.startTime,
                            endTime: entry.endTime,
                            originalText: originalText,
                            translatedText: translatedText,
                            speakerId: entry.speakerId
                        )
                    } else {
                        updated = entry
                    }
                } else {
                    updated = entry
                }
                if let encoded = encodeLine(.content(updated)) {
                    newLines.append(encoded)
                }
            case .recordingStart(let r):
                if let encoded = encodeLine(.recordingStart(r)) {
                    newLines.append(encoded)
                }
            case .recordingStop(let r):
                if let encoded = encodeLine(.recordingStop(r)) {
                    newLines.append(encoded)
                }
            }
        }

        guard matchCount == 1 else {
            ErrorLogger.shared.log(
                "updateEntry failed: matched \(matchCount) entries for startTime=\(matchingStartTime) endTime=\(matchingEndTime) (expected exactly 1)",
                source: "JSONLStore"
            )
            return false
        }

        let content = newLines.joined(separator: "\n")
        do {
            // P1-2 与 performRewriteJSONL 一致：原子替换前 flush writeHandle，
            // 避免 writeHandle 中未落盘的数据在文件被替换后丢失。
            flushWriteHandle()
            try content.write(to: url, atomically: true, encoding: .utf8)
            // 原子写入替换了底层文件，旧 writeHandle 的 fd 仍指向旧 inode。
            // 若更新的是当前会话文件，必须重开 handle，否则后续 appendRaw 会写入
            // 已被删除的旧文件，静默丢失数据。
            if url == currentFileURL {
                reopenWriteHandle()
            }
            return true
        } catch {
            ErrorLogger.shared.log(
                "updateEntry write failed: \(error.localizedDescription)",
                source: "JSONLStore"
            )
            return false
        }
    }

    // MARK: - File Management

    @discardableResult
    func renameSession(from oldName: String, to newName: String) -> Bool {
        let oldURL = transcriptionsDirectory.appendingPathComponent("\(oldName).jsonl")
        let newURL = transcriptionsDirectory.appendingPathComponent("\(newName).jsonl")
        guard fileManager.fileExists(atPath: oldURL.path),
              !fileManager.fileExists(atPath: newURL.path) else { return false }
        do {
            try fileManager.moveItem(at: oldURL, to: newURL)
            if currentSessionName == oldName {
                currentSessionName = newName
                currentFileURL = newURL
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteSession(name: String) -> Bool {
        let url = transcriptionsDirectory.appendingPathComponent("\(name).jsonl")
        let recordingFiles = readRecordingFiles(from: url)
        for recFile in recordingFiles {
            let recURL = recordingsDirectory.appendingPathComponent(recFile)
            try? fileManager.removeItem(at: recURL)
        }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func deleteAllSessions() -> Int {
        ensureDirectoryExists()
        var deleted = 0
        do {
            let files = try fileManager.contentsOfDirectory(
                at: transcriptionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for file in files where file.pathExtension == "jsonl" {
                if file == currentFileURL { continue }
                let recordingFiles = readRecordingFiles(from: file)
                for recFile in recordingFiles {
                    let recURL = recordingsDirectory.appendingPathComponent(recFile)
                    try? fileManager.removeItem(at: recURL)
                }
                if (try? fileManager.removeItem(at: file)) != nil {
                    deleted += 1
                }
            }
        } catch {
            ErrorLogger.shared.error(
                "Failed to delete all sessions: \(error.localizedDescription)",
                source: "JSONLStore"
            )
        }
        return deleted
    }

    // MARK: - Helpers

    static func generateDefaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let prefix = String(localized: "session.default_name_prefix")
        return "\(prefix) \(timestamp)"
    }

    private func encodeLine(_ line: JSONLLine) -> String? {
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(line) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func appendRaw(_ line: String, to fileURL: URL) {
        let data = Data(("\n" + line).utf8)
        if writeHandle == nil {
            // Handle may have been closed (e.g. after atomic rewrite) or never opened.
            // Attempt to reopen before writing so data is not silently lost.
            writeHandle = try? FileHandle(forWritingTo: fileURL)
            writeHandle?.seekToEndOfFile()
            if writeHandle == nil {
                ErrorLogger.shared.log(
                    "appendRaw: writeHandle is nil and file cannot be opened: \(fileURL.lastPathComponent)",
                    source: "JSONLStore"
                )
                return
            }
        }
        writeHandle?.write(data)
    }

    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: transcriptionsDirectory.path) {
            try? fileManager.createDirectory(at: transcriptionsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Supporting Types

struct SessionFile: Identifiable {
    struct RecordingSegment {
        let fileName: String
        let timestamp: String
        let durationMs: Int
    }

    let name: String
    let url: URL
    let createdAt: Date
    let entryCount: Int
    let appVersion: String?
    let recordings: [RecordingSegment]

    var hasRecording: Bool { !recordings.isEmpty }
    var totalRecordingDurationMs: Int { recordings.reduce(0) { $0 + $1.durationMs } }

    var recordingFiles: [String] { recordings.map(\.fileName) }

    var id: String { name }
}
