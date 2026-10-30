import AppKit
import RioKit

/// One running terminal: a PTY, a VT grid, and the badge state we track for it.
///
/// Owned by `RioEngine`. All render-state access happens here, on the main
/// actor, because librio requires every `rio_render_state_*` call to come from
/// a single thread.
@MainActor
final class TerminalSession {
    let id: SurfaceID
    let surface: OpaquePointer
    let renderState: OpaquePointer
    let launch: SurfaceLaunch
    /// The spawned program's pid. Identity and CPU accounting only — never
    /// signal it: `rio_surface_free` owns the child's lifecycle.
    let childPID: pid_t

    weak var view: TerminalView?

    // MARK: Badge state

    /// Bells rung since the user last looked at this session.
    private(set) var bellCount = 0
    /// Output arrived while this session was not on screen.
    private(set) var hasUnread = false
    /// Title from OSC 0/2, if the program set one.
    private(set) var title: String?
    private(set) var progress: (state: UInt32, value: UInt32)?
    /// Foreground program name, refreshed by `ProcessSampler`.
    var foregroundProcess: String?
    /// Percent of one core, summed over the child process tree.
    var cpuPercent: Double?
    private(set) var isAlive = true

    /// Whether this session is the one currently on screen. Drives unread.
    var isVisible = false {
        didSet {
            guard isVisible, isVisible != oldValue else { return }
            clearAttention()
            view?.markNeedsRender()
        }
    }

    /// Fires whenever badge-visible state changes, so the chrome can refresh.
    var onBadgeChange: (() -> Void)?

    init(surface: OpaquePointer, launch: SurfaceLaunch) {
        self.surface = surface
        self.launch = launch
        self.id = rio_surface_id(surface)
        self.renderState = rio_render_state_new(surface)!
        self.childPID = pid_t(rio_surface_child_pid(surface))
    }

    // MARK: - Lifecycle

    func tearDown() {
        rio_render_state_free(renderState)
        rio_surface_free(surface)
        isAlive = false
    }

    // MARK: - Events

    func apply(_ events: SurfaceEvents) {
        var badgesChanged = false

        if events.bells > 0 {
            if !isVisible {
                bellCount += events.bells
                badgesChanged = true
            }
            if isVisible { NSSound.beep() }
            // Behind another app, neither the beep nor the badge is much use:
            // bounce the Dock icon, the way Terminal.app does.
            DockAttention.shared.bell()
        }

        if events.needsRedraw {
            if isVisible {
                view?.markNeedsRender()
            } else if !hasUnread {
                hasUnread = true
                badgesChanged = true
            }
        }

        if let title = events.title, title != self.title {
            self.title = title
            badgesChanged = true
        }

        if let progress = events.progress {
            // ConEmu state 0 means "remove the indicator".
            self.progress = progress.state == 0 ? nil : progress
            badgesChanged = true
        }

        for write in events.clipboardWrites {
            // kind 0 is the clipboard proper; selection kinds are ignored, as
            // macOS has no primary selection.
            guard write.kind == 0 else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(write.text, forType: .string)
        }

        if events.closed {
            isAlive = false
            badgesChanged = true
        }

        if badgesChanged { onBadgeChange?() }
    }

    /// Called when the user looks at this session.
    func clearAttention() {
        guard bellCount != 0 || hasUnread else { return }
        bellCount = 0
        hasUnread = false
        onBadgeChange?()
    }

    func noteBadgeChange() { onBadgeChange?() }

    // MARK: - Input

    func send(_ text: String) {
        text.withCString { rio_surface_text(surface, $0, strlen($0)) }
    }

    func paste(_ text: String) {
        // librio brackets this itself when the program enabled mode 2004.
        text.withCString { rio_surface_paste(surface, $0, strlen($0)) }
    }

    @discardableResult
    func send(key event: rio_key_event_s) -> Bool {
        var event = event
        return rio_surface_key(surface, &event)
    }

    func resize(cols: UInt16, rows: UInt16, pixelWidth: UInt16, pixelHeight: UInt16) {
        guard cols > 0, rows > 0 else { return }
        rio_surface_resize(surface, cols, rows, pixelWidth, pixelHeight)
    }

    /// True when the program consumed the wheel event, meaning the host should
    /// not also scroll its own view.
    @discardableResult
    func scrollWheel(lines: Int32, col: UInt16, row: UInt16, mods: UInt8) -> Bool {
        rio_surface_scroll_wheel(surface, lines, col, row, mods)
    }

    @discardableResult
    func mouseButton(col: UInt16, row: UInt16, button: UInt8, pressed: Bool, mods: UInt8) -> Bool {
        rio_surface_mouse_button(surface, col, row, button, pressed, mods)
    }

    @discardableResult
    func mouseMotion(col: UInt16, row: UInt16, button: UInt8, mods: UInt8) -> Bool {
        rio_surface_mouse_motion(surface, col, row, button, mods)
    }

    /// Scrolls the scrollback view directly, bypassing librio's wheel
    /// dispatch: an autoscrolling selection drag has to move the viewport even
    /// when the program has asked for mouse reporting. Positive scrolls back
    /// into history.
    func scrollViewport(lines: Int32) {
        rio_surface_scroll(surface, lines)
    }

    func beginSelection(viewportLine: Int32, col: UInt16, kind: SelectionKind, sideRight: Bool) {
        rio_surface_selection_begin(surface, viewportLine, col, kind.rawValue, sideRight)
    }

    func updateSelection(viewportLine: Int32, col: UInt16, sideRight: Bool) {
        rio_surface_selection_update(surface, viewportLine, col, sideRight)
    }

    func clearSelection() { rio_surface_selection_clear(surface) }

    /// Clears the screen and the scrollback, keeping the line the cursor is
    /// on — what Cmd-K does in Terminal.app and iTerm2. The prompt you are
    /// standing on moves to the top and everything above it goes.
    ///
    /// librio has no clear call, so this drives its own parser through
    /// `inject_output`, which writes to the display without reaching the PTY.
    /// The program in the tab never sees it, so nothing is typed on its behalf
    /// and nothing is echoed back.
    ///
    /// Refused on the alternate screen: there is no scrollback to clear there,
    /// and wiping the grid under a full-screen program would leave the display
    /// lying about what the program thinks it drew, until the next redraw.
    @discardableResult
    func clearScreenAndScrollback() -> Bool {
        guard !isAlternateScreen else { return false }

        rio_render_state_update(renderState)
        let cursor = rio_render_state_cursor(renderState)
        let rows = rio_render_state_lines(renderState)

        var sequence = "\u{1b}[H"
        // Delete the rows above the cursor, which pulls its row up to the top.
        if cursor.line > 0 { sequence += "\u{1b}[\(cursor.line)M" }
        // Erase whatever is left below the row that was kept. Guarded, because
        // on a one-row grid row 2 clamps back onto the row being preserved.
        if rows > 1 { sequence += "\u{1b}[2;1H\u{1b}[J" }
        // ED 3 erases the saved lines, then the cursor goes back to its column.
        sequence += "\u{1b}[3J\u{1b}[1;\(cursor.column + 1)H"

        injectOutput(sequence)
        clearSelection()
        return true
    }

    var selectedText: String? {
        guard let ptr = rio_surface_selection_text(surface) else { return nil }
        defer { rio_text_free(ptr) }
        return String(cString: ptr)
    }

    // MARK: - Queries

    /// Mouse reporting is on, so drags belong to the program, not to selection.
    var wantsMouseReporting: Bool { rio_surface_mode_bits(surface) & 0b0001 != 0 }
    var isAlternateScreen: Bool { rio_surface_mode_bits(surface) & 0b0100 != 0 }

    /// OSC 7 working directory, when the shell reports one.
    var workingDirectory: String? {
        guard let ptr = rio_surface_working_dir(surface) else { return nil }
        defer { rio_text_free(ptr) }
        return String(cString: ptr)
    }

    /// The running program's name, straight from librio.
    func readForegroundProcess() -> String? {
        guard let ptr = rio_surface_foreground_process_name(surface) else { return nil }
        defer { rio_text_free(ptr) }
        return String(cString: ptr)
    }

    /// Whole buffer as text, for persisting scrollback across restarts.
    func dumpBuffer() -> String? {
        guard let ptr = rio_surface_dump(surface) else { return nil }
        defer { rio_text_free(ptr) }
        return String(cString: ptr)
    }

    /// Writes bytes to the terminal *display* without sending them to the PTY,
    /// for replaying persisted scrollback on restore.
    func injectOutput(_ text: String) {
        text.withCString { rio_surface_inject_output(surface, $0, strlen($0)) }
    }

    /// Names that mean "sitting at a prompt", not "running something".
    ///
    /// `screen` and `tmux` are listed because they are always the foreground
    /// process of a multiplexed tab, whatever is running inside: counting them
    /// as busy would peg such a tab busy forever, which is less useful than
    /// admitting we cannot tell.
    private static let idleProcessNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "-fish",
        "dash", "tcsh", "csh", "login", "env", "screen", "tmux",
    ]

    /// Whether this session is actually running something.
    ///
    /// Only answerable for local sessions: for an SSH tab the local foreground
    /// process is always `ssh`, whatever the far side is doing, so a remote
    /// session is never reported busy rather than always busy.
    var isBusy: Bool {
        guard !launch.isRemote else { return false }
        guard let name = foregroundProcess?.lowercased(), !name.isEmpty else { return false }
        return !Self.idleProcessNames.contains(name)
    }

    /// What a coding agent in this tab is doing, when one is announcing it.
    ///
    /// Read from the live title, so it dies with the session: a tab whose
    /// program has exited keeps whatever title it last set, and reporting an
    /// agent still waiting there would be a lie that never clears.
    var agentStatus: AgentStatus? {
        guard isAlive else { return nil }
        return AgentStatus.parse(title: title)
    }

    /// A label for the tab: the program's title, else its process name, else
    /// whatever we launched.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let foregroundProcess, !foregroundProcess.isEmpty { return foregroundProcess }
        return launch.executable.map { ($0 as NSString).lastPathComponent } ?? "shell"
    }
}
