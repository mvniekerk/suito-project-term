import Foundation

/// The persisted shape of the whole app: projects and their tabs.
///
/// Running sessions are deliberately absent. Processes die with the app, so
/// tabs respawn lazily the first time they are viewed after a relaunch.
struct Workspace: Codable {
    var projects: [Project] = []
    /// Font and colours for every terminal.
    var appearance = Appearance()
    /// Remembered so a relaunch lands where the user left off.
    var selectedProjectID: UUID?

    static let defaultSSHHost = "mike@mb1-ssh.bushtelegram.com"

    /// How terminals are drawn. Applies to every session at once; a per-tab
    /// font would make the shared grid size meaningless.
    struct Appearance: Codable, Hashable, Sendable {
        /// nil means the system monospace font, which is the sane default and
        /// always present.
        var fontName: String?
        var fontSize: Double = 13
        var themeName: String = "Dark"
        /// How solid the terminal's default background is over the frosted
        /// panel behind it. Persisted, so the look survives a restart.
        var terminalOpacity: Double = Appearance.defaultOpacity

        /// Floored well above zero: the slider must not be able to make the
        /// terminal unreadable, which is a state you cannot then see well
        /// enough to undo.
        static let opacityRange: ClosedRange<Double> = 0.3...1.0
        static let defaultOpacity: Double = 0.82

        static func clampOpacity(_ value: Double) -> Double {
            guard value.isFinite else { return defaultOpacity }
            return min(max(value, opacityRange.lowerBound), opacityRange.upperBound)
        }

        var theme: TerminalTheme { .named(themeName) }
    }


    /// What a first run looks like: the directory the app was launched from,
    /// with a shell and a remote tab, so both paths are visible immediately.
    static func bootstrap(directory: String) -> Workspace {
        let name = (directory as NSString).lastPathComponent
        let project = Project(
            name: name.isEmpty ? "project" : name,
            directory: directory,
            colorIndex: 0,
            tabs: [
                TabSpec(name: "shell", target: .local),
                TabSpec(name: "remote", target: .ssh(host: defaultSSHHost, directory: nil)),
            ]
        )
        return Workspace(projects: [project], selectedProjectID: project.id)
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    /// The next palette slot not already in use, so new projects look distinct.
    var nextColorIndex: Int {
        let used = Set(projects.map { $0.colorIndex % ProjectPalette.colors.count })
        for candidate in 0..<ProjectPalette.colors.count where !used.contains(candidate) {
            return candidate
        }
        return projects.count % ProjectPalette.colors.count
    }
}

extension Workspace.Appearance {
    /// Tolerant decoding, for the same reason as `TabSpec` and `Project`: a
    /// key added in a later build is simply absent from an older workspace
    /// file, and Swift's synthesised decoder treats that as an error rather
    /// than falling back to the property's default. Without this, adding the
    /// opacity field would have thrown away every existing appearance.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName) ?? "Dark"
        terminalOpacity = Self.clampOpacity(
            try container.decodeIfPresent(Double.self, forKey: .terminalOpacity)
                ?? Self.defaultOpacity)
    }
}

extension Workspace {
    /// Tolerant decoding; see `TabSpec.init(from:)`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        selectedProjectID = try container.decodeIfPresent(
            UUID.self, forKey: .selectedProjectID)
        appearance = try container.decodeIfPresent(
            Appearance.self, forKey: .appearance) ?? Appearance()
    }
}
