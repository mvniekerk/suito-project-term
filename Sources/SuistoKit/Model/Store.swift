import Foundation

/// Loads and saves the workspace as JSON under Application Support.
///
/// Writes are debounced and atomic: the app saves on every model change, and a
/// half-written file would lose the user's whole layout.
@MainActor
final class Store {
    private let url: URL
    private var pendingSave: DispatchWorkItem?
    private let debounce: TimeInterval = 0.5

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            self.url = AppSupport.directory.appendingPathComponent("workspace.json")
        }
    }

    var location: URL { url }

    func load() -> Workspace? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(Workspace.self, from: data)
        } catch {
            // Keep the unreadable file rather than silently overwriting a
            // layout the user may want to recover by hand.
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            NSLog("Suisto: could not read workspace (\(error)); moved aside to \(backup.path)")
            return nil
        }
    }

    func save(_ workspace: Workspace) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeNow(workspace) }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    /// Bypasses the debounce, for app termination.
    func flush(_ workspace: Workspace) {
        pendingSave?.cancel()
        pendingSave = nil
        writeNow(workspace)
    }

    private func writeNow(_ workspace: Workspace) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(workspace)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Suisto: could not save workspace: \(error)")
        }
    }
}
