import Foundation
import Testing
@testable import SuistoKit

/// How a tab turns into an argv.
///
/// This is the part most worth pinning down: it decides what process actually
/// runs, it is the only place TERM can be set (librio's surface config has no
/// environment field), and the remote path builds a shell command string by
/// hand, which is where quoting bugs live.
@Suite("Tab launch construction")
struct LaunchTests {

    @Test("A local shell tab runs the login shell in the project directory")
    func localShell() {
        let tab = TabSpec(name: "shell", target: .local)
        let launch = tab.launch(projectDirectory: "/tmp/work", loginShell: "/bin/zsh")

        #expect(launch.executable == "/usr/bin/env")
        #expect(launch.arguments == ["TERM=xterm-256color", "/bin/zsh", "-l"])
        #expect(launch.workingDirectory == "/tmp/work")
        #expect(launch.isRemote == false)
    }

    @Test("TERM is always set, because librio would otherwise export TERM=rio")
    func termIsAlwaysSet() {
        let tab = TabSpec(name: "shell")
        let launch = tab.launch(projectDirectory: "/tmp")
        #expect(launch.arguments.first == "TERM=xterm-256color")

        var custom = tab
        custom.term = "xterm-ghostty"
        #expect(custom.launch(projectDirectory: "/tmp").arguments.first == "TERM=xterm-ghostty")
    }

    @Test("A local command runs through the login shell so PATH and aliases work")
    func localCommand() {
        var tab = TabSpec(name: "build", target: .local)
        tab.command = "npm run dev"
        let launch = tab.launch(projectDirectory: "/tmp/work", loginShell: "/bin/zsh")

        #expect(launch.arguments == [
            "TERM=xterm-256color", "/bin/zsh", "-l", "-c", "npm run dev",
        ])
    }

    @Test("Keeping a tab open re-execs a shell after the command, even on failure")
    func localCommandHoldsOpen() {
        var tab = TabSpec(name: "build", target: .local)
        tab.command = "false"
        tab.keepOpenAfterExit = true
        let launch = tab.launch(projectDirectory: "/tmp", loginShell: "/bin/zsh")

        let script = launch.arguments.last ?? ""
        // `;` not `&&`: a failed command is exactly when you want the shell.
        #expect(script.hasPrefix("false; exec "))
        #expect(!script.contains("&&"))
    }

    @Test("An SSH tab runs ssh locally and a login shell remotely")
    func sshShell() {
        let tab = TabSpec(name: "remote",
                          target: .ssh(host: "mike@example.test", directory: nil))
        let launch = tab.launch(projectDirectory: "/tmp/work")

        #expect(launch.arguments == [
            "TERM=xterm-256color", "/usr/bin/ssh", "-t", "mike@example.test",
            "exec \"$SHELL\" -l",
        ])
        #expect(launch.isRemote)
        // A local working directory is meaningless for a remote session.
        #expect(launch.workingDirectory == nil)
    }

    @Test("An SSH tab cds to the remote directory before running the command")
    func sshCommandInDirectory() {
        var tab = TabSpec(name: "deploy",
                          target: .ssh(host: "mike@example.test", directory: "/srv/app"))
        tab.command = "make deploy"
        let launch = tab.launch(projectDirectory: "/tmp")

        // Through the login shell, like a local tab, so PATH and aliases apply.
        #expect(launch.arguments.last == #"cd '/srv/app' && exec "$SHELL" -lc 'make deploy'"#)
    }

    @Test("A remote directory with quotes and separators cannot escape quoting")
    func sshQuotingIsSafe() {
        // A canary payload: if the quoting leaked, `;` would start a new
        // command on the remote host instead of staying part of the path.
        let nasty = "/srv/it's here; touch /tmp/pt-canary"
        let tab = TabSpec(name: "x", target: .ssh(host: "h", directory: nasty))
        let script = tab.launch(projectDirectory: "/tmp").arguments.last ?? ""

        // The only way out of single quotes is the '\'' dance; the separator
        // must stay inside the quoted run.
        #expect(script.hasPrefix("cd '/srv/it'\\''s here; touch /tmp/pt-canary' && "))
        #expect(TabSpec.shellQuoted("plain") == "'plain'")
    }

    @Test("Local arguments are passed as argv, so no shell can re-split them")
    func localArgumentsAreNotReparsed() {
        var tab = TabSpec(name: "odd", target: .local)
        tab.command = "echo 'a b'  &&  echo c"
        let launch = tab.launch(projectDirectory: "/tmp", loginShell: "/bin/zsh")

        // The whole command is one argv entry handed to `zsh -c`; librio execs
        // these directly, so nothing re-splits them on the way.
        #expect(launch.arguments.count == 5)
        #expect(launch.arguments[4] == "echo 'a b'  &&  echo c")
    }

    // MARK: - Multiplexer-backed persistence

    @Test("A tab's screen session name is stable and socket-safe")
    func sessionNameIsStable() {
        let tab = TabSpec(name: "agent")
        #expect(tab.sessionName == tab.sessionName, "must not change between reads")
        #expect(tab.sessionName.hasPrefix("pt-"))
        // screen turns the name into a filename, so keep it boring.
        #expect(tab.sessionName.dropFirst(3).allSatisfy { $0.isHexDigit })

        var renamed = tab
        renamed.name = "something else"
        #expect(renamed.sessionName == tab.sessionName,
                "renaming a tab must not orphan its running session")
        #expect(TabSpec(name: "agent").sessionName != tab.sessionName,
                "different tabs must not share a session")
    }

    @Test("A local screen tab reattaches instead of starting a fresh shell")
    func localScreenReattaches() {
        var tab = TabSpec(name: "agent", target: .local)
        tab.persistence = .screen
        let launch = tab.launch(projectDirectory: "/tmp/work", loginShell: "/bin/zsh")

        #expect(launch.arguments == [
            "TERM=xterm-256color",
            "screen", "-T", "screen-256color", "-D", "-RR", tab.sessionName,
            "/bin/zsh", "-l",
        ])
    }

    @Test("An SSH screen tab reattaches on the far side")
    func remoteScreenReattaches() {
        var tab = TabSpec(name: "agent",
                          target: .ssh(host: "mike@example.test", directory: "/srv/app"))
        tab.persistence = .screen
        let launch = tab.launch(projectDirectory: "/tmp")

        let script = launch.arguments.last ?? ""
        #expect(script.hasPrefix("cd '/srv/app' && exec screen -T screen-256color -D -RR pt-"))
        #expect(script.hasSuffix("\"$SHELL\" -l"))
        // ssh still runs locally; the multiplexer belongs on the remote host.
        #expect(launch.arguments[1] == "/usr/bin/ssh")
    }

    @Test("A command runs inside the persistent session, not beside it")
    func commandRunsInsideSession() {
        var tab = TabSpec(name: "build", target: .local)
        tab.persistence = .screen
        tab.command = "npm run dev"
        let launch = tab.launch(projectDirectory: "/tmp", loginShell: "/bin/zsh")

        let screenIndex = try? #require(launch.arguments.firstIndex(of: "screen"))
        let shellIndex = try? #require(launch.arguments.firstIndex(of: "/bin/zsh"))
        if let screenIndex, let shellIndex {
            #expect(screenIndex < shellIndex,
                    "screen must wrap the shell, otherwise the command outlives nothing")
        }
        #expect(launch.arguments.last == "npm run dev")
    }

    @Test("tmux attaches to an existing session rather than stacking new ones")
    func tmuxAttaches() {
        var tab = TabSpec(name: "agent", target: .local)
        tab.persistence = .tmux
        let launch = tab.launch(projectDirectory: "/tmp", loginShell: "/bin/zsh")

        #expect(launch.arguments.contains("new-session"))
        #expect(launch.arguments.contains("-A"), "-A attaches instead of failing or duplicating")
        #expect(launch.arguments.contains(tab.sessionName))
    }

    @Test("Persistence off leaves the command line exactly as it was")
    func noPersistenceIsUnchanged() {
        let tab = TabSpec(name: "shell", target: .local)
        #expect(tab.multiplexerArguments().isEmpty)
        #expect(tab.launch(projectDirectory: "/tmp", loginShell: "/bin/zsh").arguments
                == ["TERM=xterm-256color", "/bin/zsh", "-l"])
    }
}
