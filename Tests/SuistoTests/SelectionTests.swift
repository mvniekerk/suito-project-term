import AppKit
import Foundation
import RioKit
import Testing
@testable import SuistoKit

/// Selection, the right-click menu, and the autoscroll that lets a drag reach
/// past the edge of the view.
///
/// The selection tests drive a real librio surface: `rio_surface_inject_output`
/// puts exact content on the grid without going through the PTY, so the text a
/// drag produces can be asserted character for character.
@MainActor
@Suite("Selection", .serialized)
struct SelectionTests {

    private func makeSession() throws -> TerminalSession {
        let launch = SurfaceLaunch(
            executable: "/bin/cat", arguments: [], workingDirectory: nil,
            cols: 40, rows: 6, pixelWidth: 400, pixelHeight: 120, scrollback: 100)
        return try #require(RioEngine.shared.makeSession(launch))
    }

    /// Injects text and waits for the IO thread to parse it onto the grid.
    private func fill(_ session: TerminalSession) {
        session.injectOutput("hello world alpha\r\nsecond line here\r\n")
        for _ in 0..<80 {
            rio_render_state_update(session.renderState)
            if rio_render_state_cell(session.renderState, 1, 0).codepoint > 32 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - Dragging

    @Test func dragSelectsTheSpanItCovers() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 3, kind: .simple, sideRight: false)
        session.updateSelection(viewportLine: 0, col: 10, sideRight: true)

        #expect(session.selectedText == "lo world")
    }

    /// A click with no drag must leave nothing selected, or every click would
    /// strand a highlighted cell behind it.
    @Test func bareClickSelectsNothing() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 3, kind: .simple, sideRight: false)
        rio_render_state_update(session.renderState)

        #expect(session.selectedText == nil)
        #expect(rio_render_state_selection(session.renderState).active == false)
    }

    @Test func doubleClickSelectsAWord() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 7, kind: .word, sideRight: false)

        #expect(session.selectedText == "world")
    }

    @Test func tripleClickSelectsALine() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 7, kind: .line, sideRight: false)

        #expect(session.selectedText == "hello world alpha\n")
    }

    @Test func multiLineDragJoinsTheRows() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 12, kind: .simple, sideRight: false)
        session.updateSelection(viewportLine: 1, col: 5, sideRight: true)

        #expect(session.selectedText == "alpha\nsecond")
    }

    /// Dragging upwards must select the same text as dragging downwards, and
    /// the render state must come back with start before end — the renderer's
    /// hit test assumes that ordering when it decides which cells to tint.
    @Test func backwardsDragIsNormalised() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 1, col: 5, kind: .simple, sideRight: true)
        session.updateSelection(viewportLine: 0, col: 12, sideRight: false)
        rio_render_state_update(session.renderState)

        let selection = rio_render_state_selection(session.renderState)
        #expect(selection.active)
        #expect(selection.start_line <= selection.end_line)
        #expect(session.selectedText == "alpha\nsecond")
    }

    @Test func clearingEmptiesTheSelection() throws {
        let session = try makeSession()
        fill(session)

        session.beginSelection(viewportLine: 0, col: 0, kind: .line, sideRight: false)
        #expect(session.selectedText != nil)

        session.clearSelection()
        rio_render_state_update(session.renderState)

        #expect(session.selectedText == nil)
        #expect(rio_render_state_selection(session.renderState).active == false)
    }

    // MARK: - Autoscroll

    @Test func pointerInsideTheViewDoesNotScroll() {
        #expect(SelectionAutoscroll.lines(forRow: 0, rows: 24) == 0)
        #expect(SelectionAutoscroll.lines(forRow: 12.5, rows: 24) == 0)
        #expect(SelectionAutoscroll.lines(forRow: 23, rows: 24) == 0)
    }

    /// Positive is librio's direction for scrolling back into history.
    @Test func draggingAboveTheViewScrollsIntoHistory() {
        #expect(SelectionAutoscroll.lines(forRow: -0.2, rows: 24) == 1)
        #expect(SelectionAutoscroll.lines(forRow: -3.4, rows: 24) == 4)
    }

    @Test func draggingBelowTheViewScrollsTowardsTheLiveEdge() {
        #expect(SelectionAutoscroll.lines(forRow: 23.4, rows: 24) == -1)
        #expect(SelectionAutoscroll.lines(forRow: 27.0, rows: 24) == -4)
    }

    /// Flinging the pointer far outside the window should pan steadily rather
    /// than jump to an end — and must not overflow on the way.
    @Test func overshootIsCappedAtOneScreen() {
        #expect(SelectionAutoscroll.lines(forRow: -5000, rows: 24) == 24)
        #expect(SelectionAutoscroll.lines(forRow: 5000, rows: 24) == -24)
        #expect(SelectionAutoscroll.lines(forRow: -1e30, rows: 24) == 24)
        #expect(SelectionAutoscroll.lines(forRow: .infinity, rows: 24) == 0)
        #expect(SelectionAutoscroll.lines(forRow: .nan, rows: 24) == 0)
    }

    // MARK: - Context menu

    @Test func contextMenuOffersCopyPasteAndSelection() {
        let view = TerminalView()
        let menu = TerminalContextMenu.make(target: view)

        #expect(menu.items.map(\.title) == ["Copy", "Paste", "", "Select All", "Clear Selection"])
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items[0].action == #selector(NSText.copy(_:)))
        #expect(menu.items[1].action == #selector(NSText.paste(_:)))
        #expect(menu.items[3].action == #selector(NSResponder.selectAll(_:)))
        #expect(menu.items[4].action == #selector(TerminalView.clearSelection(_:)))
    }

    /// Every item carries an explicit target: an item whose action no responder
    /// claims is silently disabled, which is how the View menu once broke.
    @Test func contextMenuItemsAreTargeted() {
        let view = TerminalView()
        let menu = TerminalContextMenu.make(target: view)

        for item in menu.items where !item.isSeparatorItem {
            #expect(item.target === view, "\(item.title) has no target")
        }
    }

    /// Copy and Clear Selection must grey out with nothing selected, and both
    /// must light up once there is.
    @Test func validationFollowsTheSelection() throws {
        let session = try makeSession()
        let view = TerminalView()
        // A real frame before attaching, so the view hands the surface a grid
        // with room for the injected text rather than a single cell.
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        view.attach(session)
        fill(session)

        let menu = TerminalContextMenu.make(target: view)
        let copy = menu.items[0]
        let clear = menu.items[4]

        #expect(view.validateUserInterfaceItem(copy) == false)
        #expect(view.validateUserInterfaceItem(clear) == false)

        session.beginSelection(viewportLine: 0, col: 0, kind: .line, sideRight: false)

        #expect(view.validateUserInterfaceItem(copy))
        #expect(view.validateUserInterfaceItem(clear))
    }
}
