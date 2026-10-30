import AppKit
import RioKit

/// The terminal surface on screen: presents the renderer's bitmap and forwards
/// input to the session.
///
/// Rendering is pulled, not pushed. A wakeup only marks the view dirty; the
/// actual `rio_render_state_update` happens in `updateLayer`, which AppKit
/// calls at most once per display refresh. That is what keeps a firehose of
/// output from costing more than one repaint per frame.
@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient,
                          NSUserInterfaceValidations {
    private let renderer: CoreTextRenderer
    private(set) var session: TerminalSession?

    /// Input-method composition in progress, drawn as a preedit overlay.
    private var markedText: NSAttributedString?
    private var markedTextRange = NSRange(location: NSNotFound, length: 0)
    /// Text AppKit produced while we were inside `keyDown`.
    private var textFromCurrentKeyDown: String?
    private var isInsideKeyDown = false

    /// Set while the user drags out a selection, so motion updates it.
    private var isDraggingSelection = false
    /// The last drag position, in window space. The autoscroll timer needs it:
    /// it has no event of its own to read.
    private var lastDragLocation = NSPoint.zero
    /// Runs while a selection drag sits outside the view. AppKit only delivers
    /// `mouseDragged` when the pointer actually moves, so holding still past
    /// an edge would otherwise stall the drag halfway through a long block.
    private var autoscroll: Timer?
    /// True when the program took the right-button press, so its release is
    /// owed to the program rather than swallowed by a context menu.
    private var rightButtonWentToProgram = false
    /// Accumulates trackpad momentum until it is worth a whole line.
    private var scrollAccumulator: CGFloat = 0

    var onTitleChange: (() -> Void)?

    init(renderer: CoreTextRenderer = CoreTextRenderer()) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // No backing colour of its own: the frosted panel behind the terminal
        // shows through wherever the rendered bitmap is translucent.
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Session

    func attach(_ session: TerminalSession) {
        self.session?.view = nil
        self.session = session
        session.view = self
        renderer.invalidateAll()
        syncGeometry()
        markNeedsRender()
    }

    func detach() {
        setAutoscroll(running: false)
        isDraggingSelection = false
        session?.view = nil
        session = nil
    }

    /// Applies new font and colours. The cell size usually changes with the
    /// font, so the PTY has to be told the new grid as well.
    func apply(_ appearance: Workspace.Appearance) {
        renderer.apply(appearance)
        syncGeometry()
        markNeedsRender()
    }

    /// Live translucency, without the grid re-measure `apply(_:)` does: a
    /// font change resizes every PTY, which means a SIGWINCH to every running
    /// program, and that is not something to send on each frame of a drag.
    func applyTranslucency(_ opacity: Double) {
        renderer.setBackgroundOpacity(opacity)
        markNeedsRender()
    }

    /// Schedules a repaint. Cheap and idempotent: safe to call per wakeup.
    func markNeedsRender() {
        needsDisplay = true
    }

    // MARK: - Presentation

    override var wantsUpdateLayer: Bool { true }
    /// Translucent now, so AppKit has to composite what is behind it.
    override var isOpaque: Bool { false }

    override func updateLayer() {
        guard let session else { return }
        let focused = isFocused
        if let image = renderer.render(session, focused: focused) {
            layer?.contents = image
            layer?.contentsScale = window?.backingScaleFactor ?? 2
        }
    }

    private var isFocused: Bool {
        window?.isKeyWindow == true && window?.firstResponder === self
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        syncGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncGeometry()
        renderer.invalidateAll()
        markNeedsRender()
    }

    /// Matches the renderer's bitmap and the PTY's window size to the view.
    private func syncGeometry() {
        let scale = window?.backingScaleFactor ?? 2
        renderer.resize(to: bounds.size, scale: scale)

        guard let session else { return }
        let m = renderer.metrics
        let cols = max(1, Int(bounds.width / m.cellWidth))
        let rows = max(1, Int(bounds.height / m.cellHeight))
        session.resize(
            cols: UInt16(min(cols, Int(UInt16.max))),
            rows: UInt16(min(rows, Int(UInt16.max))),
            pixelWidth: UInt16(min(Int(bounds.width * scale), Int(UInt16.max))),
            pixelHeight: UInt16(min(Int(bounds.height * scale), Int(UInt16.max)))
        )
    }

    /// Columns and rows that fit in an arbitrary size, at the current font.
    /// Exposed so the window controller can size every session, not only the
    /// one attached here.
    func gridFitting(size: CGSize) -> (cols: UInt16, rows: UInt16) {
        let m = renderer.metrics
        let cols = max(1, min(Int(size.width / m.cellWidth), Int(UInt16.max)))
        let rows = max(1, min(Int(size.height / m.cellHeight), Int(UInt16.max)))
        return (UInt16(cols), UInt16(rows))
    }

    /// Columns and rows that currently fit, for hit-testing.
    private var gridSize: (cols: UInt16, rows: UInt16) {
        let m = renderer.metrics
        return (
            UInt16(max(1, Int(bounds.width / m.cellWidth))),
            UInt16(max(1, Int(bounds.height / m.cellHeight)))
        )
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        defer { markNeedsRender() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { markNeedsRender() }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let centre = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            centre.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.markNeedsRender() }
            }
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }

        textFromCurrentKeyDown = nil
        isInsideKeyDown = true
        // Route through the input context first so dead keys and input methods
        // get their chance; it calls back into insertText/setMarkedText.
        let consumedByIME = inputContext?.handleEvent(event) ?? false
        isInsideKeyDown = false

        if hasMarkedText() {
            // An input method owns the key. Tell librio so it encodes nothing
            // and waits for the commit.
            KeyTranslator.withKeyEvent(for: event, text: nil, composing: true) {
                session.send(key: $0)
            }
            markNeedsRender()
            return
        }

        // Prefer what the input context produced; fall back to the event's own
        // characters when it did not consume the key at all.
        let text = textFromCurrentKeyDown ?? (consumedByIME ? nil : event.characters)
        KeyTranslator.withKeyEvent(for: event, text: text) { session.send(key: $0) }
        markNeedsRender()
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier-only changes matter solely in kitty report-all mode, which
        // librio decides; forwarding bare modifier presses is not needed for
        // normal encoding, so this only keeps AppKit from beeping.
        super.flagsChanged(with: event)
    }

    override func doCommand(by selector: Selector) {
        // Swallow editing commands: the terminal program owns these keys, and
        // the default implementation would beep.
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let value as String: text = value
        case let value as NSAttributedString: text = value.string
        default: return
        }
        unmarkText()

        if isInsideKeyDown {
            // keyDown will fold this into the key report, so librio can apply
            // modifiers and mode state to it.
            textFromCurrentKeyDown = text
        } else {
            // A bare input-method commit, with no key press to attach it to.
            guard let session else { return }
            KeyTranslator.withTextEvent(text) { session.send(key: $0) }
            markNeedsRender()
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as String:
            markedText = NSAttributedString(string: value)
        case let value as NSAttributedString:
            markedText = value
        default:
            markedText = nil
        }
        markedTextRange = markedText.map { NSRange(location: 0, length: $0.length) }
            ?? NSRange(location: NSNotFound, length: 0)
        markNeedsRender()
    }

    func unmarkText() {
        markedText = nil
        markedTextRange = NSRange(location: NSNotFound, length: 0)
        markNeedsRender()
    }

    func hasMarkedText() -> Bool { markedText != nil }
    func markedRange() -> NSRange { markedTextRange }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input-method candidate window should appear: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let session, let window else { return .zero }
        let cursor = rio_render_state_cursor(session.renderState)
        let m = renderer.metrics
        let local = NSRect(
            x: CGFloat(cursor.column) * m.cellWidth,
            y: bounds.height - CGFloat(cursor.line + 1) * m.cellHeight,
            width: m.cellWidth,
            height: m.cellHeight
        )
        return window.convertToScreen(convert(local, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    // MARK: - Mouse

    /// A point in the view resolved to a cell.
    private struct Hit {
        var col: UInt16
        var row: UInt16
        /// True when the pointer sits in the right half of the cell. librio
        /// needs the half to decide whether the cell at a drag's edge falls
        /// inside the selection, so a drag can reach the cells at both ends.
        var sideRight: Bool
        /// The row before clamping, as a fraction: negative above the view,
        /// past `rows - 1` below it. That overshoot is what drives autoscroll.
        var rawRow: CGFloat
    }

    private func cell(at locationInWindow: NSPoint) -> Hit {
        let point = convert(locationInWindow, from: nil)
        let m = renderer.metrics
        let (cols, rows) = gridSize

        let rawCol = point.x / m.cellWidth
        let col = UInt16(min(max(0, Int(rawCol)), Int(cols) - 1))
        // View coordinates have their origin bottom-left; rows count from top.
        let rawRow = (bounds.height - point.y) / m.cellHeight
        let row = UInt16(min(max(0, Int(rawRow)), Int(rows) - 1))
        return Hit(col: col, row: row,
                   sideRight: rawCol - rawCol.rounded(.down) > 0.5, rawRow: rawRow)
    }

    override func mouseDown(with event: NSEvent) {
        guard let session else { return }
        let hit = cell(at: event.locationInWindow)
        let mods = KeyTranslator.mods(from: event.modifierFlags)

        // Shift bypasses mouse reporting to give a local selection, which is
        // the convention; librio reports whether the program took the event.
        let reported = !event.modifierFlags.contains(.shift)
            && session.mouseButton(col: hit.col, row: hit.row, button: 0, pressed: true, mods: mods)
        if reported { return }

        // Control-click is the system's other way to ask for a context menu,
        // and a one-button mouse has no other way at all.
        if event.modifierFlags.contains(.control) {
            showContextMenu(for: event)
            return
        }

        let kind: SelectionKind
        switch event.clickCount {
        case 2: kind = .word
        case 3: kind = .line
        default: kind = event.modifierFlags.contains(.option) ? .block : .simple
        }
        session.beginSelection(viewportLine: Int32(hit.row), col: hit.col,
                               kind: kind, sideRight: hit.sideRight)
        isDraggingSelection = true
        markNeedsRender()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let session else { return }

        if isDraggingSelection {
            lastDragLocation = event.locationInWindow
            setAutoscroll(running: extendSelection())
            return
        }
        let hit = cell(at: event.locationInWindow)
        session.mouseMotion(col: hit.col, row: hit.row, button: 0,
                            mods: KeyTranslator.mods(from: event.modifierFlags))
    }

    /// Extends the drag to `lastDragLocation`, panning the viewport first when
    /// that point is outside the view. Returns whether it had to pan, which is
    /// also the answer to "should autoscroll keep running".
    @discardableResult
    private func extendSelection() -> Bool {
        guard let session, isDraggingSelection else { return false }
        let hit = cell(at: lastDragLocation)
        let lines = SelectionAutoscroll.lines(forRow: hit.rawRow, rows: Int(gridSize.rows))
        if lines != 0 { session.scrollViewport(lines: lines) }
        // The clamped edge row is the right place to extend to: the content has
        // just moved underneath it.
        session.updateSelection(viewportLine: Int32(hit.row), col: hit.col,
                                sideRight: hit.sideRight)
        markNeedsRender()
        return lines != 0
    }

    private func setAutoscroll(running: Bool) {
        guard running else {
            autoscroll?.invalidate()
            autoscroll = nil
            return
        }
        guard autoscroll == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setAutoscroll(running: self.extendSelection())
            }
        }
        // `.common` so it also fires inside AppKit's event-tracking mode,
        // which is where a mouse drag spends its time.
        RunLoop.main.add(timer, forMode: .common)
        autoscroll = timer
    }

    override func mouseUp(with event: NSEvent) {
        guard let session else { return }
        let hit = cell(at: event.locationInWindow)
        let mods = KeyTranslator.mods(from: event.modifierFlags)

        if isDraggingSelection {
            isDraggingSelection = false
            setAutoscroll(running: false)
        } else {
            session.mouseButton(col: hit.col, row: hit.row, button: 0, pressed: false, mods: mods)
        }
    }

    /// The program gets first refusal, so a full-screen app that asked for
    /// mouse reporting still sees the button; Shift forces the local menu, the
    /// same bypass the left button uses for selection.
    override func rightMouseDown(with event: NSEvent) {
        guard let session else { return }
        let hit = cell(at: event.locationInWindow)
        let mods = KeyTranslator.mods(from: event.modifierFlags)

        rightButtonWentToProgram = !event.modifierFlags.contains(.shift)
            && session.mouseButton(col: hit.col, row: hit.row, button: 2, pressed: true, mods: mods)
        if rightButtonWentToProgram { return }

        showContextMenu(for: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let session, rightButtonWentToProgram else { return }
        rightButtonWentToProgram = false
        let hit = cell(at: event.locationInWindow)
        session.mouseButton(col: hit.col, row: hit.row, button: 2, pressed: false,
                            mods: KeyTranslator.mods(from: event.modifierFlags))
    }

    /// Pops the menu explicitly instead of assigning `menu`, so right-click
    /// reaches the program first. A right-click leaves any existing selection
    /// alone — otherwise the click would destroy the very thing Copy is for.
    private func showContextMenu(for event: NSEvent) {
        NSMenu.popUpContextMenu(TerminalContextMenu.make(target: self), with: event, for: self)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let session, session.wantsMouseReporting else { return }
        let hit = cell(at: event.locationInWindow)
        // Button 3 means "no button held", for bare-motion reporting.
        session.mouseMotion(col: hit.col, row: hit.row, button: 3,
                            mods: KeyTranslator.mods(from: event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let session else { return }
        let m = renderer.metrics

        // Precise deltas are pixels, so bank them until they add up to a row.
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
        } else {
            scrollAccumulator += event.scrollingDeltaY * m.cellHeight
        }
        let lines = Int32((scrollAccumulator / m.cellHeight).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines) * m.cellHeight

        let hit = cell(at: event.locationInWindow)
        // librio dispatches this itself: a mouse report, alternate-scroll
        // cursor keys, or the scrollback view, whichever applies.
        session.scrollWheel(lines: lines, col: hit.col, row: hit.row,
                            mods: KeyTranslator.mods(from: event.modifierFlags))
        markNeedsRender()
    }

    // MARK: - Clipboard

    @objc func copy(_ sender: Any?) {
        guard let text = session?.selectedText, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        session?.paste(text)
        markNeedsRender()
    }

    /// Cmd-K. Named for Terminal.app's Edit item, which behaves the same way.
    @objc func clearScrollback(_ sender: Any?) {
        session?.clearScreenAndScrollback()
        markNeedsRender()
    }

    @objc func clearSelection(_ sender: Any?) {
        session?.clearSelection()
        markNeedsRender()
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let session else { return }
        let (cols, rows) = gridSize
        session.beginSelection(viewportLine: 0, col: 0,
                               kind: .simple, sideRight: false)
        session.updateSelection(viewportLine: Int32(rows - 1), col: cols - 1, sideRight: true)
        markNeedsRender()
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return session?.selectedText?.isEmpty == false
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(clearSelection(_:)):
            return session?.selectedText?.isEmpty == false
        case #selector(clearScrollback(_:)):
            // Nothing to clear under a full-screen program: it owns the grid
            // and there is no scrollback behind the alternate screen.
            guard let session else { return false }
            return !session.isAlternateScreen
        case #selector(selectAll(_:)):
            return session != nil
        default:
            return true
        }
    }
}
