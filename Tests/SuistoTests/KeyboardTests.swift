import AppKit
import Foundation
import RioKit
import Testing
@testable import SuistoKit

/// What the program on the other end of the PTY actually receives.
///
/// These drive a real librio surface and read the tty's own echo, because the
/// bytes are librio's decision, not ours — the host only says which key was
/// pressed. Asserting against our own translation would prove nothing about
/// what reaches `claude`.
@MainActor
@Suite("Keyboard encoding", .serialized)
struct KeyboardTests {

    private func makeSession() throws -> TerminalSession {
        // `cat` so there is no shell line editor in the way; it never gets a
        // newline, so everything on screen is the tty driver's echo, which
        // renders control bytes as ^X.
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 40, rows: 4, pixelWidth: 400, pixelHeight: 80, scrollback: 100)
        let session = try #require(RioEngine.shared.makeSession(launch))
        // Let the child open the tty before anything is typed at it.
        Thread.sleep(forTimeInterval: 0.3)
        return session
    }

    private func key(_ characters: String, keyCode: UInt16,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    /// The first row of the grid, with control pictures left intact.
    private func firstRow(_ session: TerminalSession) -> String {
        let state = session.renderState
        rio_render_state_update(state)
        var line = ""
        for col in 0..<rio_render_state_columns(state) {
            let cp = rio_render_state_cell(state, 0, col).codepoint
            line.append(cp == 0 ? " " : Character(UnicodeScalar(cp) ?? " "))
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private func echo(of event: NSEvent, text: String?, in session: TerminalSession) -> String {
        KeyTranslator.withKeyEvent(for: event, text: text) { session.send(key: $0) }
        Thread.sleep(forTimeInterval: 0.25)
        return firstRow(session)
    }

    /// Claude Code cycles its permission modes on Shift-Tab, which is CSI Z.
    ///
    /// The bug this pins down: AppKit does not report Shift-Tab as Tab with a
    /// shift flag. It delivers `NSBackTabCharacter`, U+0019, and a translator
    /// that only recognises U+0009 falls through to the generic character
    /// path and sends the raw 0x19 byte. Readline-style editors read 0x19 as
    /// Ctrl-Y, which is yank — so the symptom was Shift-Tab pasting text.
    @Test("Shift-Tab sends CSI Z, not a raw 0x19")
    func shiftTabIsBacktab() throws {
        let session = try makeSession()
        defer { RioEngine.shared.closeSession(session.id) }

        let line = echo(of: try key("\u{19}", keyCode: 48, flags: .shift),
                        text: nil, in: session)
        #expect(line == "^[[Z", "Shift-Tab echoed as \(line)")
        #expect(!line.contains("^Y"), "Shift-Tab still reaching the program as Ctrl-Y")
    }

    /// The input context usually swallows Shift-Tab and hands back no text,
    /// but it is not required to: if the 0x19 arrives as the event's own
    /// characters it must still not be sent as text.
    @Test("Shift-Tab is backtab even when AppKit hands back its text")
    func shiftTabIgnoresBackTabText() throws {
        let session = try makeSession()
        defer { RioEngine.shared.closeSession(session.id) }

        let line = echo(of: try key("\u{19}", keyCode: 48, flags: .shift),
                        text: "\u{19}", in: session)
        #expect(line == "^[[Z", "Shift-Tab echoed as \(line)")
    }

    @Test("Plain Tab still sends a tab, not an escape sequence")
    func plainTabIsUnchanged() throws {
        let session = try makeSession()
        defer { RioEngine.shared.closeSession(session.id) }

        let line = echo(of: try key("\t", keyCode: 48), text: "\t", in: session)
        #expect(!line.contains("^["), "plain Tab turned into an escape sequence: \(line)")
        #expect(!line.contains("^I"), "plain Tab was echoed as a control picture: \(line)")
    }
}
