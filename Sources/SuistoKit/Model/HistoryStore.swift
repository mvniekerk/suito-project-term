import Foundation

/// Saved scrollback for tabs, so a tab still shows what it said before the app
/// was last quit.
///
/// Kept out of `workspace.json`: history is large and churns constantly, while
/// the workspace is small and must not be risked by a half-written write. Each
/// tab gets its own file, named by tab id.
///
/// librio makes this possible with two calls — `rio_surface_dump` returns the
/// whole buffer as text, and `rio_surface_inject_output` writes bytes to the
/// terminal *display* without sending them to the PTY, which is exactly a
/// replay. The dump is plain UTF-8, so colours and styles do not survive.
@MainActor
final class HistoryStore {
    /// Per tab. Enough for a long build log, bounded so the directory cannot
    /// grow without limit.
    static let byteLimit = 256 * 1024

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = AppSupport.directory
                .appendingPathComponent("history", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
    }

    var location: URL { directory }

    private func url(for tabID: UUID) -> URL {
        directory.appendingPathComponent("\(tabID.uuidString).txt")
    }

    /// Stores the tail of `text`, dropping the blank rows a full-grid dump
    /// leaves at the end.
    func save(_ text: String, for tabID: UUID) {
        var trimmed = String(text.reversed().drop { $0 == "\n" || $0 == " " }.reversed())
        guard !trimmed.isEmpty else {
            remove(tabID)
            return
        }

        // Keep the end, which is the part worth reading.
        var bytes = Array(trimmed.utf8)
        if bytes.count > Self.byteLimit {
            bytes = Array(bytes.suffix(Self.byteLimit))
            // The cut may land inside a multi-byte scalar; drop the partial
            // prefix rather than writing invalid UTF-8.
            while !bytes.isEmpty, bytes[0] & 0xC0 == 0x80 { bytes.removeFirst() }
            trimmed = String(decoding: bytes, as: UTF8.self)
        }

        do {
            try Data(trimmed.utf8).write(to: url(for: tabID), options: .atomic)
        } catch {
            NSLog("Suisto: could not save history for \(tabID): \(error)")
        }
    }

    func load(for tabID: UUID) -> String? {
        guard let data = try? Data(contentsOf: url(for: tabID)),
              !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func remove(_ tabID: UUID) {
        try? FileManager.default.removeItem(at: url(for: tabID))
    }

    /// Drops history for tabs that no longer exist, so deleting a tab or a
    /// project does not leave its output on disk forever.
    func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "txt" {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Turns saved text into bytes a terminal will lay out correctly.
    ///
    /// A dump carries bare `\n`, which moves down a row without returning to
    /// column 0, so a replay would stair-step across the screen. A separator
    /// marks where the restored text ends and the new session begins.
    static func replayBytes(_ history: String, restoredAt date: Date = Date()) -> String {
        let normalised = history
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        // Dim, so the marker reads as chrome rather than as program output.
        let marker = "\u{1b}[2m── restored \(formatter.string(from: date)) ──\u{1b}[0m"
        return normalised + "\r\n" + marker + "\r\n"
    }
}
