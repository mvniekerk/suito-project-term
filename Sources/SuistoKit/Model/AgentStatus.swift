import Foundation

/// What a coding agent running in a tab is doing, read off the title it sets.
///
/// Claude Code reports its own state through the terminal title (OSC 0/2):
/// a half-filled circle that alternates `◐` / `◑` while it is working, and an
/// eight-spoked asterisk `✳` once it has stopped and is waiting on you. It is
/// the same signal Terminal.app puts in its titlebar, which is where this was
/// taken from.
///
/// This is worth having on top of `TerminalSession.isBusy`, which asks the
/// process table what the foreground program is. An agent tab's foreground
/// program is `claude` — or whatever it has shelled out to — whether it is
/// thinking or sitting at an empty prompt, so the process table reports such a
/// tab busy for its whole life and never says the one thing worth knowing:
/// whether it is your turn.
enum AgentStatus: Equatable {
    /// Thinking, or running a tool. Nothing is wanted from you.
    case working
    /// Stopped — finished, or asking a question. Your turn.
    case waiting

    /// The spinner's phases. Only `◐` and `◑` have been observed, but the
    /// quarter-filled pair belongs to the same spinner and costs nothing to
    /// accept.
    private static let workingGlyphs: Set<Unicode.Scalar> = ["◐", "◑", "◒", "◓"]
    private static let waitingGlyphs: Set<Unicode.Scalar> = ["✳"]

    /// Reads the state out of a terminal title, or nil when the title is not
    /// an agent's.
    ///
    /// Matched on the leading Unicode *scalar* rather than the leading
    /// `Character`: should a variation selector ever follow the glyph, the
    /// grapheme would stop comparing equal to the bare one while the scalar
    /// still does.
    static func parse(title: String?) -> AgentStatus? {
        guard let title else { return nil }
        guard let first = title.drop(while: { $0.isWhitespace }).unicodeScalars.first else {
            return nil
        }
        if workingGlyphs.contains(first) { return .working }
        if waitingGlyphs.contains(first) { return .waiting }
        return nil
    }

    /// One glyph per state for the badges, deliberately *not* the live
    /// character: echoing the spinner's current phase into a badge that
    /// redraws every tick would strobe it at the spinner's rate.
    var glyph: String {
        switch self {
        case .working: "◐"
        case .waiting: "✳"
        }
    }
}
