import Foundation
import AppKit

/// Manages JSONL persistence for video transcription sessions.
/// Stores files in `video_transcriptions/` under the app's Application Support directory.
@MainActor
@Observable
final class VideoJSONLStore {

    // MARK: - State

    private(set) var currentSessionName: String = ""
    private(set) var currentFileURL: URL?

    /// P2-1 修复：持久 writeHandle，避免每次 append 都 open/close
    nonisolated(unsafe) private var writeHandle: FileHandle?

    // MARK: - Private

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var videoTranscriptionsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.transflow"
        return appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("video_transcriptions", isDirectory: true)
    }

    // MARK: - Initialization

    init() {
        ensureDirectoryExists()
        // 监听应用终止通知，确保 writeHandle 被正确关闭
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        writeHandle?.closeFile()
        writeHandle = nil
        NotificationCenter.default.removeObserver(self)
    }

    @MainActor
    @objc private func handleWillTerminate() {
        writeHandle?.synchronizeFile()
        writeHandle?.closeFile()
        writeHandle = nil
    }

    // MARK: - Session Management

    @discardableResult
    func createSession(name: String? = nil, metadata: VideoJSONLMetadata) -> String {
        // P2-1 修复：关闭之前的 writeHandle
        writeHandle?.closeFile()
        writeHandle = nil

        let sessionName = name ?? Self.generateDefaultName()
        let fileURL = videoTranscriptionsDirectory.appendingPathComponent("\(sessionName).jsonl")

        if let line = encodeLine(.videoMetadata(metadata)) {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        currentSessionName = sessionName
        currentFileURL = fileURL

        // P2-1 修复：打开持久 writeHandle
        writeHandle = try? FileHandle(forWritingTo: fileURL)
        writeHandle?.seekToEndOfFile()

        return sessionName
    }

    // MARK: - Appending

    func appendEntry(_ entry: VideoJSONLContentEntry) {
        guard let fileURL = currentFileURL else { return }
        guard let line = encodeLine(.content(entry)) else { return }
        appendRaw(line, to: fileURL)
    }

    func appendSegment(_ segment: VideoTranscriptionSegment) {
        appendEntry(VideoJSONLContentEntry(segment: segment))
    }

    func appendSegments(_ segments: [VideoTranscriptionSegment]) {
        for segment in segments {
            appendSegment(segment)
        }
    }

    // MARK: - Reading

    func listSessions() -> [VideoSessionFile] {
        ensureDirectoryExists()
        do {
            let files = try fileManager.contentsOfDirectory(
                at: videoTranscriptionsDirectory,
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
            return files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> VideoSessionFile? in
                    let name = url.deletingPathExtension().lastPathComponent
                    let allLines = readAllLines(from: url)
                    let metadata = allLines.compactMap {
                        if case .videoMetadata(let m) = $0 { return m } else { return nil }
                    }.first
                    let entries = allLines.compactMap {
                        if case .content(let e) = $0 { return e } else { return nil }
                    }

                    let createdAt: Date
                    if let timeStr = metadata?.createTime,
                       let date = ISO8601DateFormatter().date(from: timeStr) {
                        createdAt = date
                    } else {
                        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
                        createdAt = attrs?[.creationDate] as? Date ?? Date.distantPast
                    }

                    return VideoSessionFile(
                        name: name,
                        url: url,
                        createdAt: createdAt,
                        entryCount: entries.count,
                        videoFile: metadata?.videoFile,
                        originalFilePath: metadata?.originalFilePath,
                        durationSeconds: metadata?.durationSeconds,
                        sourceLanguage: metadata?.sourceLanguage,
                        targetLanguage: metadata?.targetLanguage,
                        diarizationEnabled: metadata?.diarizationEnabled ?? false,
                        speakerCount: Set(entries.compactMap(\.speakerId)).count
                    )
                }
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            return []
        }
    }

    func readAllLines(from url: URL) -> [VideoJSONLLine] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = data.components(separatedBy: .newlines)
        var result: [VideoJSONLLine] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(VideoJSONLLine.self, from: lineData) {
                result.append(decoded)
            }
        }
        return result
    }

    func readEntries(from url: URL) -> [VideoJSONLContentEntry] {
        readAllLines(from: url).compactMap {
            if case .content(let entry) = $0 { return entry } else { return nil }
        }
    }

    func readMetadata(from url: URL) -> VideoJSONLMetadata? {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = data.components(separatedBy: .newlines)
        guard let firstLine = lines.first,
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let lineData = firstLine.data(using: .utf8),
              let decoded = try? decoder.decode(VideoJSONLLine.self, from: lineData),
              case .videoMetadata(let meta) = decoded else {
            return nil
        }
        return meta
    }

    // MARK: - File Management

    @discardableResult
    func renameSession(from oldName: String, to newName: String) -> Bool {
        let oldURL = videoTranscriptionsDirectory.appendingPathComponent("\(oldName).jsonl")
        let newURL = videoTranscriptionsDirectory.appendingPathComponent("\(newName).jsonl")
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
        let url = videoTranscriptionsDirectory.appendingPathComponent("\(name).jsonl")
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Rename all occurrences of a speaker ID in a session file.
    @discardableResult
    func renameSpeaker(in url: URL, from oldId: String, to newId: String) -> Bool {
        let allLines = readAllLines(from: url)
        var newLines: [String] = []
        for line in allLines {
            switch line {
            case .videoMetadata(let meta):
                if let encoded = encodeLine(.videoMetadata(meta)) {
                    newLines.append(encoded)
                }
            case .content(let entry):
                let updatedEntry: VideoJSONLContentEntry
                if entry.speakerId == oldId {
                    updatedEntry = VideoJSONLContentEntry(
                        startTime: entry.startTime,
                        endTime: entry.endTime,
                        originalText: entry.originalText,
                        translatedText: entry.translatedText,
                        speakerId: newId
                    )
                } else {
                    updatedEntry = entry
                }
                if let encoded = encodeLine(.content(updatedEntry)) {
                    newLines.append(encoded)
                }
            }
        }

        let content = newLines.joined(separator: "\n")
        do {
            // 原子替换前 flush writeHandle（与 JSONLStore 保持一致），
            // 避免未落盘数据在文件替换后丢失。
            writeHandle?.synchronizeFile()
            try content.write(to: url, atomically: true, encoding: .utf8)
            // 原子写入替换了底层文件，若更新的是当前会话文件，
            // 必须重开 handle，否则后续 appendRaw 会写入已被替换的旧 inode。
            if url == currentFileURL {
                writeHandle?.closeFile()
                writeHandle = try? FileHandle(forWritingTo: url)
                writeHandle?.seekToEndOfFile()
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - Editing

    /// Update an existing content entry's text fields in place.
    ///
    /// The entry is located by its `(startTime, endTime)` pair (the de-facto primary key
    /// since `VideoJSONLContentEntry` has no id field). The whole file is read, the matching
    /// line is rewritten, and the file is written back atomically. Non-content lines
    /// (metadata) are preserved verbatim.
    ///
    /// - Returns: `true` if exactly one entry was updated. `false` (with an error log)
    ///   if zero or multiple entries matched the key.
    @discardableResult
    func updateEntry(
        in url: URL,
        matchingStartTime: Double,
        matchingEndTime: Double,
        originalText: String,
        translatedText: String?
    ) -> Bool {
        let allLines = readAllLines(from: url)
        var newLines: [String] = []
        var matchCount = 0

        for line in allLines {
            switch line {
            case .videoMetadata(let meta):
                if let encoded = encodeLine(.videoMetadata(meta)) {
                    newLines.append(encoded)
                }
            case .content(let entry):
                let updated: VideoJSONLContentEntry
                if entry.startTime == matchingStartTime && entry.endTime == matchingEndTime {
                    matchCount += 1
                    // Only the first match is updated; subsequent matches are logged.
                    if matchCount == 1 {
                        updated = VideoJSONLContentEntry(
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
            }
        }

        guard matchCount == 1 else {
            ErrorLogger.shared.log(
                "updateEntry failed: matched \(matchCount) entries for startTime=\(matchingStartTime) endTime=\(matchingEndTime) (expected exactly 1)",
                source: "VideoJSONLStore"
            )
            return false
        }

        let content = newLines.joined(separator: "\n")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            ErrorLogger.shared.log(
                "updateEntry write failed: \(error.localizedDescription)",
                source: "VideoJSONLStore"
            )
            return false
        }
    }

    // MARK: - Helpers

    static func generateDefaultName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "video_\(formatter.string(from: Date()))"
    }

    private func encodeLine(_ line: VideoJSONLLine) -> String? {
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(line) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func appendRaw(_ line: String, to fileURL: URL) {
        let data = Data(("\n" + line).utf8)
        // P2-1 修复：使用持久 writeHandle
        if let handle = writeHandle {
            handle.write(data)
        } else {
            // Fallback: 若 writeHandle 不可用则临时打开
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }

    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: videoTranscriptionsDirectory.path) {
            try? fileManager.createDirectory(at: videoTranscriptionsDirectory, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Supporting Types

struct VideoSessionFile: Identifiable {
    let name: String
    let url: URL
    let createdAt: Date
    let entryCount: Int
    let videoFile: String?
    let originalFilePath: String?
    let durationSeconds: Double?
    let sourceLanguage: String?
    let targetLanguage: String?
    let diarizationEnabled: Bool
    let speakerCount: Int

    var id: String { name }
}
