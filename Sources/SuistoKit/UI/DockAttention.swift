import AppKit

/// Bounces the Dock icon when a bell arrives while Suisto is in the
/// background — what Terminal.app does, and the only bell signal that reaches
/// you at all when the window is buried behind something else.
@MainActor
final class DockAttention {
    static let shared = DockAttention()

    /// Bells arrive in bursts — a failing build can ring several in a row, and
    /// every request queues another bounce. One bounce is a signal; six in a
    /// row is a tantrum.
    static let coalescingInterval: TimeInterval = 2

    /// Injected so the decision of *when* to bounce can be tested without an
    /// app that is really sitting in the Dock.
    var isApplicationActive: () -> Bool = { NSApp.isActive }
    var beginRequest: () -> Int = { NSApp.requestUserAttention(.informationalRequest) }
    var endRequest: (Int) -> Void = { NSApp.cancelUserAttentionRequest($0) }

    private(set) var pendingRequest: Int?
    private var lastRequest = Date.distantPast

    /// Returns whether it actually asked for attention.
    @discardableResult
    func bell(at now: Date = Date()) -> Bool {
        // An app that jumps up and down while you are looking at it is just
        // noise: the tab's own badge already says which session rang.
        guard !isApplicationActive() else { return false }
        guard now.timeIntervalSince(lastRequest) >= Self.coalescingInterval else { return false }
        lastRequest = now
        pendingRequest = beginRequest()
        return true
    }

    /// Called when the user comes back, so the icon is never still asking
    /// about a bell they have already answered.
    func clear() {
        if let pendingRequest { endRequest(pendingRequest) }
        pendingRequest = nil
    }
}
