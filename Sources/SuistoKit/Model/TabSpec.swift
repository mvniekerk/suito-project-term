import Foundation

/// One minor tab: a named terminal that runs either locally or over SSH.
///
/// Tabs are owned by a single project and are not shared between projects.
struct TabSpec: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var target: Target = .local
    /// Command line to run instead of a login shell. Run through the shell, so
    /// aliases, functions and a profile-built PATH all work.
    var command: String?
    /// Keep a shell after `command` exits, instead of letting the tab die.
    var keepOpenAfterExit = false
    /// TERM for the child. librio's own default is `rio`, whose terminfo a
    /// remote host will not have, and which advertises capabilities this
    /// renderer does not implement.
    var term: String = "xterm-256color"
    /// Run the session inside a terminal multiplexer so the *processes*
    /// survive this app quitting, not just their output.
    var persistence: SessionPersistence = .none

    /// How a tab's work outlives the app.
    ///
    /// Replaying saved scrollback brings the text back but not the processes —
    /// they died with the PTY. A multiplexer running on the far side keeps the
    /// real session alive between connections, so reattaching restores the
    /// running programs, not a transcript of them. This is the difference
    /// between seeing what a build said and finding it still running.
    enum SessionPersistence: String, Codable, Hashable, CaseIterable, Sendable {
        /// A fresh shell each time; saved scrollback is replayed into it.
        case none
        /// `screen -D -RR`: detach the session from wherever else it is
        /// attached, reattach here, and create it if it does not exist.
        case screen
        /// `tmux new-session -A`: attach if it exists, otherwise create.
        case tmux

        var label: String {
            switch self {
            case .none: return "None (replay scrollback)"
            case .screen: return "screen (reattach session)"
            case .tmux: return "tmux (reattach session)"
            }
        }

        var executable: String? {
            switch self {
            case .none: return nil
            case .screen: return "screen"
            case .tmux: return "tmux"
            }
        }
    }

    enum Target: Codable, Hashable {
        case local
        case ssh(host: String, directory: String?)

        var isRemote: Bool {
            if case .ssh = self { return true }
            return false
        }

        var label: String {
            switch self {
            case .local: return "local"
            case .ssh(let host, _): return host
            }
        }
    }
}

extension TabSpec {
    /// Tolerant decoding, so a workspace written by an older build still loads.
    ///
    /// Swift's synthesised `Decodable` ignores property default values: a key
    /// that is simply absent is a hard error, not a fallback. Every field
    /// added after v1 therefore has to be decoded with `decodeIfPresent`, or
    /// upgrading the app would fail to read the user's layout and silently
    /// start them over.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "tab"
        target = try container.decodeIfPresent(Target.self, forKey: .target) ?? .local
        command = try container.decodeIfPresent(String.self, forKey: .command)
        keepOpenAfterExit = try container.decodeIfPresent(
            Bool.self, forKey: .keepOpenAfterExit) ?? false
        term = try container.decodeIfPresent(String.self, forKey: .term) ?? "xterm-256color"
        persistence = try container.decodeIfPresent(
            SessionPersistence.self, forKey: .persistence) ?? .none
    }

    /// Stable multiplexer session name for this tab.
    ///
    /// Derived from the tab id so it survives renames and cannot collide with
    /// a session the user started by hand. Kept short and hex-only because
    /// screen turns the name into a socket filename.
    var sessionName: String {
        "pt-" + id.uuidString.replacingOccurrences(of: "-", with: "")
            .prefix(8).lowercased()
    }

    /// argv that reattaches (or creates) this tab's long-lived session, and
    /// runs the rest of the command line inside it. Empty when persistence is
    /// off.
    func multiplexerArguments() -> [String] {
        switch persistence {
        case .none:
            return []
        case .screen:
            // -D detaches it from anywhere else it is attached, -RR reattaches
            // or creates: the "just give me that session" idiom. -T sets $TERM
            // for programs inside, which otherwise defaults to 8-colour
            // "screen".
            return ["screen", "-T", "screen-256color", "-D", "-RR", sessionName]
        case .tmux:
            return ["tmux", "new-session", "-A", "-s", sessionName]
        }
    }

    /// Builds the spawn description for this tab.
    ///
    /// Everything launches through `/usr/bin/env` because
    /// `rio_surface_config_s` has no environment field: that is the only place
    /// to set TERM. Arguments reach the child through `execvp` as separate
    /// argv entries, so nothing here is re-parsed by a shell's line editor and
    /// no quoting hazard exists on the local side.
    func launch(
        projectDirectory: String,
        loginShell: String = TabSpec.defaultShell,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        pixelWidth: UInt16 = 720,
        pixelHeight: UInt16 = 432
    ) -> SurfaceLaunch {
        var arguments = ["TERM=\(term)"]
        var workingDirectory: String? = projectDirectory

        switch target {
        case .local:
            // A multiplexer works locally too: the session outlives the app.
            arguments += multiplexerArguments()
            arguments += [loginShell, "-l"]
            if let script = localScript() {
                arguments += ["-c", script]
            }

        case .ssh(let host, let directory):
            // The local side only needs to run ssh; the far side gets one
            // shell command string, which must be quoted by us.
            arguments += ["/usr/bin/ssh", "-t", host, remoteScript(directory: directory)]
            // A local cwd is meaningless for a remote session.
            workingDirectory = nil
        }

        return SurfaceLaunch(
            executable: "/usr/bin/env",
            arguments: arguments,
            workingDirectory: workingDirectory,
            cols: cols,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            isRemote: target.isRemote
        )
    }

    /// What the local login shell should run, or nil for an interactive shell.
    private func localScript() -> String? {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        guard keepOpenAfterExit else { return command }
        // `exec` replaces the shell so there is no stray parent process left.
        return "\(command); exec \(TabSpec.defaultShell) -l"
    }

    private func remoteScript(directory: String?) -> String {
        let prefix = (directory?.isEmpty == false)
            ? "cd \(TabSpec.shellQuoted(directory!)) && "
            : ""
        // Already safe to interpolate: the only variable part is `sessionName`,
        // which is `pt-` plus hex.
        let mux = multiplexerArguments()
        let muxPrefix = mux.isEmpty ? "" : mux.joined(separator: " ") + " "

        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            return prefix + "exec " + muxPrefix + "\"$SHELL\" -l"
        }
        // `;` not `&&`: the hold-open shell must appear even when the command
        // fails, which is exactly when the output is worth reading.
        let inner = keepOpenAfterExit ? "\(command); exec \"$SHELL\" -l" : command
        // Through the login shell, so PATH and aliases work the same way they
        // do for a local tab.
        return prefix + "exec " + muxPrefix + "\"$SHELL\" -lc " + TabSpec.shellQuoted(inner)
    }

    /// Wraps a string in single quotes for POSIX shells, escaping any it holds.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
