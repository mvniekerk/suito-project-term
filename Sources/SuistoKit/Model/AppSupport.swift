import Foundation

/// Where Suisto keeps its workspace and saved scrollback.
///
/// The app was called ProjectsTerm before it was called Suisto. The first run
/// after the rename carries the old directory across rather than starting with
/// an empty workspace — which would lose not just the projects and their
/// colours, but the tab identifiers that name the `screen` sessions those tabs
/// reattach to. A new identifier means a new session name, and the still-live
/// session on the far side becomes unreachable from the app.
enum AppSupport {
    private static let folder = "Suisto"
    private static let previousFolder = "ProjectsTerm"

    /// Resolved once: the move must not be attempted twice, and nothing about
    /// it changes while the app runs.
    static let directory: URL = {
        let manager = FileManager.default
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = support.appendingPathComponent(folder, isDirectory: true)
        let previous = support.appendingPathComponent(previousFolder, isDirectory: true)

        // Only when there is nothing here yet: if both exist, the current one
        // is authoritative and the old one is left alone rather than merged.
        if !manager.fileExists(atPath: url.path),
           manager.fileExists(atPath: previous.path) {
            do {
                try manager.moveItem(at: previous, to: url)
                NSLog("Suisto: carried \(previous.lastPathComponent) across to \(folder)")
            } catch {
                NSLog("Suisto: could not migrate \(previous.path): \(error)")
            }
        }

        try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Carries a `UserDefaults` value across the rename, used for the saved
    /// window frame so the window does not jump back to its default position.
    static func migrateDefault(from old: String, to new: String,
                               in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: new) == nil,
              let value = defaults.object(forKey: old) else { return }
        defaults.set(value, forKey: new)
    }
}
