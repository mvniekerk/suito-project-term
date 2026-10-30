import AppKit
import Foundation
import RioKit
import Testing
@testable import SuistoKit

/// Cmd-K: clear the screen and the scrollback, keeping the prompt.
///
/// These drive a real librio surface, because the whole feature is a sequence
/// handed to librio's parser — a test against anything else would be testing
/// the string, not the clear.
@MainActor
@Suite("Clear scrollback", .serialized)
struct ClearTests {

    private func makeSession(rows: UInt16 = 6) throws -> TerminalSession {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 30, rows: rows, pixelWidth: 300, pixelHeight: 120, scrollback: 200)
        return try #require(RioEngine.shared.makeSession(launch))
    }

    /// Injects and waits for librio's IO thread to parse it onto the grid.
    private func inject(_ session: TerminalSession, _ text: String,
                        until ready: () -> Bool) {
        session.injectOutput(text)
        for _ in 0..<100 {
            rio_render_state_update(session.renderState)
            if ready() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    /// Twelve lines into a six-row grid, so half is scrollback, ending on a
    /// prompt with the cursor parked after it.
    ///
    /// Waits for the prompt text itself rather than for a cursor column:
    /// `L10-text` is also eight columns wide, so a column check lets the test
    /// run on a half-parsed stream and the rest arrives mid-assertion.
    private func fill(_ session: TerminalSession) {
        let body = (1...12).map { "L\($0)-text" }.joined(separator: "\r\n")
        inject(session, body + "\r\nPROMPT$ ") {
            let cursor = rio_render_state_cursor(session.renderState)
            return row(session, 5) == "PROMPT$" && cursor.line == 5 && cursor.column == 8
        }
    }

    private func row(_ session: TerminalSession, _ index: UInt16) -> String {
        let state = session.renderState
        rio_render_state_update(state)
        var line = ""
        for col in 0..<rio_render_state_columns(state) {
            let cp = rio_render_state_cell(state, index, col).codepoint
            line.append(cp == 0 ? " " : Character(UnicodeScalar(cp) ?? " "))
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// Waits for librio's IO thread to parse what was just injected, then
    /// refreshes the snapshot the assertions read from.
    ///
    /// Both halves matter. It sleeps rather than spinning the run loop,
    /// because `RunLoop.run(until:)` returns straight away when the loop has
    /// no input sources and the parsing happens on another thread anyway. And
    /// `rio_render_state_cursor` reads the last snapshot rather than the live
    /// terminal, so without the update an assertion sees the state as it was
    /// before the clear.
    private func settle(_ session: TerminalSession) {
        Thread.sleep(forTimeInterval: 0.2)
        rio_render_state_update(session.renderState)
    }

    // MARK: - Clearing

    @Test func scrollbackIsErased() throws {
        let session = try makeSession()
        fill(session)
        #expect(session.dumpBuffer()?.contains("L1-text") == true)

        session.clearScreenAndScrollback()
        settle(session)

        let dump = try #require(session.dumpBuffer())
        #expect(!dump.contains("L1-text"))
        #expect(!dump.contains("L12-text"))
    }

    /// The point of the feature: everything goes except the line you are
    /// standing on, which ends up at the top.
    @Test func promptSurvivesAndMovesToTheTop() throws {
        let session = try makeSession()
        fill(session)
        #expect(row(session, 0) == "L8-text")

        session.clearScreenAndScrollback()
        settle(session)

        #expect(row(session, 0) == "PROMPT$")
        for index in UInt16(1)..<6 {
            #expect(row(session, index) == "", "row \(index) should be blank")
        }
    }

    /// The cursor has to land back where it was in the prompt, or the next
    /// character typed overwrites it.
    @Test func cursorKeepsItsColumn() throws {
        let session = try makeSession()
        fill(session)
        #expect(rio_render_state_cursor(session.renderState).column == 8)

        session.clearScreenAndScrollback(); settle(session)

        let cursor = rio_render_state_cursor(session.renderState)
        #expect(cursor.line == 0)
        #expect(cursor.column == 8)
    }

    /// A one-row grid is the case where "erase everything below the kept row"
    /// would wrap back onto the kept row itself.
    @Test func oneRowGridKeepsItsOnlyLine() throws {
        let session = try makeSession(rows: 1)
        inject(session, "ONLY$ ") { rio_render_state_cursor(session.renderState).column == 6 }

        session.clearScreenAndScrollback()
        settle(session)

        #expect(row(session, 0) == "ONLY$")
    }

    @Test func clearingDropsTheSelection() throws {
        let session = try makeSession()
        fill(session)
        session.beginSelection(viewportLine: 0, col: 0, kind: .line, sideRight: false)
        #expect(session.selectedText != nil)

        session.clearScreenAndScrollback()
        settle(session)

        #expect(session.selectedText == nil)
    }

    // MARK: - The alternate screen

    /// A full-screen program owns the grid, and there is no scrollback behind
    /// it. Wiping it would leave the display disagreeing with what the program
    /// believes it drew.
    @Test func refusedOnTheAlternateScreen() throws {
        let session = try makeSession()
        fill(session)
        inject(session, "\u{1b}[?1049h\u{1b}[HVIM-IS-DRAWING") { session.isAlternateScreen }
        #expect(session.isAlternateScreen)

        #expect(session.clearScreenAndScrollback() == false)
        settle(session)

        #expect(row(session, 0) == "VIM-IS-DRAWING")
    }

    @Test func menuItemGreysOutOnTheAlternateScreen() throws {
        let view = TerminalView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
        let session = try makeSession()
        view.attach(session)

        let item = NSMenuItem(title: "Clear Scrollback",
                              action: #selector(TerminalView.clearScrollback(_:)),
                              keyEquivalent: "k")
        #expect(view.validateUserInterfaceItem(item))

        inject(session, "\u{1b}[?1049h") { session.isAlternateScreen }
        #expect(view.validateUserInterfaceItem(item) == false)
    }

    // MARK: - Wiring

    @Test func editMenuBindsItToCommandK() {
        let menu = MenuBuilder.editMenu()
        let clear = try? #require(menu.items.first { $0.title == "Clear Scrollback" })

        #expect(clear?.keyEquivalent == "k")
        #expect(clear?.keyEquivalentModifierMask == .command)
        #expect(clear?.action == #selector(TerminalView.clearScrollback(_:)))
    }
}
