import Foundation
import RioKit

typealias SurfaceID = rio_surface_id_t

/// What a terminal told us about itself since the last drain, coalesced.
struct SurfaceEvents {
    var needsRedraw = false
    var bells = 0
    var title: String?
    var subtitle: String?
    /// OSC 9;4 — (ConEmu state, 0-100 value).
    var progress: (state: UInt32, value: UInt32)?
    var cursorBlinking: Bool?
    /// The program asked the surface to close, or its child went away.
    var closed = false
    var clipboardWrites: [(kind: UInt8, text: String)] = []
}

/// Where librio's PTY IO threads deposit events for the main actor to collect.
///
/// librio's contract is strict: `wakeup_cb` and `action_cb` may fire on the IO
/// thread and must *only* flag or schedule work — calling back into any `rio_*`
/// function from inside a callback is undefined behaviour. So the callbacks do
/// nothing but append here, and a single coalesced main-queue hop drains it.
final class EventMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SurfaceID: SurfaceEvents] = [:]
    private var drainScheduled = false

    /// Records an event. Returns true when the caller should schedule a drain,
    /// which is only the case for the first event after each drain — that is
    /// what keeps a firehose of output from flooding the main queue.
    func post(_ id: SurfaceID, _ mutate: (inout SurfaceEvents) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        mutate(&pending[id, default: SurfaceEvents()])
        if drainScheduled { return false }
        drainScheduled = true
        return true
    }

    func take() -> [SurfaceID: SurfaceEvents] {
        lock.lock()
        defer { lock.unlock() }
        drainScheduled = false
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        return batch
    }
}

private let mailbox = EventMailbox()

private func scheduleDrain() {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            RioEngine.shared.drain(mailbox.take())
        }
    }
}

// MARK: - C callbacks
//
// These run on librio's PTY IO thread. They may only touch the mailbox.

private let wakeupCallback: @convention(c) (UnsafeMutableRawPointer?, SurfaceID) -> Void = { _, id in
    if mailbox.post(id, { $0.needsRedraw = true }) { scheduleDrain() }
}

private let actionCallback: @convention(c) (UnsafeMutableRawPointer?, SurfaceID, rio_action_s) -> Void = { _, id, action in
    // `title`/`subtitle` are valid only for this call, so copy before returning.
    let title = action.title.map { String(cString: $0) }
    let subtitle = action.subtitle.map { String(cString: $0) }

    let shouldSchedule = mailbox.post(id) { events in
        switch action.tag {
        case RIO_ACTION_SET_TITLE:
            events.title = title
            events.subtitle = subtitle
        case RIO_ACTION_RING_BELL:
            events.bells += 1
        case RIO_ACTION_CURSOR_BLINKING_CHANGE:
            events.cursorBlinking = action.data_a != 0
            events.needsRedraw = true
        case RIO_ACTION_PROGRESS:
            events.progress = (state: action.data_a, value: action.data_b)
        default:
            break
        }
    }
    if shouldSchedule { scheduleDrain() }
}

private let clipboardCallback: @convention(c) (UnsafeMutableRawPointer?, SurfaceID, UInt8, UnsafePointer<CChar>?) -> Void = { _, id, kind, utf8 in
    guard let utf8 else { return }
    let text = String(cString: utf8)
    if mailbox.post(id, { $0.clipboardWrites.append((kind: kind, text: text)) }) {
        scheduleDrain()
    }
}

private let closeCallback: @convention(c) (UnsafeMutableRawPointer?, SurfaceID) -> Void = { _, id in
    if mailbox.post(id, { $0.closed = true }) { scheduleDrain() }
}

// MARK: - Engine

/// How to start the program behind a terminal.
struct SurfaceLaunch {
    /// nil means $SHELL, falling back to /bin/sh.
    var executable: String?
    var arguments: [String] = []
    var workingDirectory: String?
    var cols: UInt16 = 80
    var rows: UInt16 = 24
    var pixelWidth: UInt16 = 720
    var pixelHeight: UInt16 = 432
    var scrollback: Int = 10_000
    /// True when the local child is only an ssh client. Local process metrics
    /// then describe the tunnel, not the work, so they are not reported.
    var isRemote = false
}

/// Owns the process-wide `rio_engine_t` and every live surface.
///
/// One engine per process: it holds shared config and fans actions out to the
/// host. Sessions are owned here and referred to elsewhere by `SurfaceID`.
@MainActor
final class RioEngine {
    static let shared = RioEngine()

    private let handle: OpaquePointer
    private var sessions: [SurfaceID: TerminalSession] = [:]

    /// Called when a surface's child exits or the program asks it to close.
    var onSessionClosed: ((TerminalSession) -> Void)?

    private init() {
        var config = rio_runtime_config_s()
        config.wakeup_cb = wakeupCallback
        config.action_cb = actionCallback
        config.clipboard_write_cb = clipboardCallback
        config.close_surface_cb = closeCallback

        guard let handle = rio_engine_new(&config) else {
            fatalError("rio_engine_new returned NULL — librio failed to start")
        }
        self.handle = handle
        TerminalTheme.dark.apply()
    }

    func session(for id: SurfaceID) -> TerminalSession? { sessions[id] }

    var liveSessions: [TerminalSession] { Array(sessions.values) }

    /// Spawns a terminal. Returns nil when librio could not start the program.
    func makeSession(_ launch: SurfaceLaunch) -> TerminalSession? {
        var config = rio_surface_config_s()
        config.cols = launch.cols
        config.rows = launch.rows
        config.pixel_width = launch.pixelWidth
        config.pixel_height = launch.pixelHeight
        config.scrollback = launch.scrollback

        // Every C string must outlive the rio_surface_new call, so they are
        // duplicated and freed once the surface exists.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }

        func dup(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }

        if let executable = launch.executable { config.shell = dup(executable) }
        if let cwd = launch.workingDirectory { config.working_dir = dup(cwd) }

        var argv: [UnsafePointer<CChar>?] = launch.arguments.map { dup($0) }
        let surface: OpaquePointer? = argv.withUnsafeMutableBufferPointer { buffer in
            if !launch.arguments.isEmpty {
                config.args = UnsafePointer(buffer.baseAddress)
                config.args_len = buffer.count
            }
            return rio_surface_new(handle, &config)
        }

        guard let surface else { return nil }
        let session = TerminalSession(surface: surface, launch: launch)
        sessions[session.id] = session
        return session
    }

    /// Tears a session down. `rio_surface_free` already hangs up the child's
    /// process group and reaps it, so the pid is never signalled from here.
    func closeSession(_ id: SurfaceID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.tearDown()
    }

    /// Applies one batch of coalesced events from the IO threads.
    func drain(_ batch: [SurfaceID: SurfaceEvents]) {
        for (id, events) in batch {
            guard let session = sessions[id] else { continue }
            session.apply(events)
            if events.closed { onSessionClosed?(session) }
        }
    }
}
