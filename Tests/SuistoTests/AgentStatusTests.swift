import AppKit
import CoreText
import Foundation
import Testing
@testable import SuistoKit

/// Reading an agent's state out of the title it sets.
///
/// The glyphs here were taken from live `claude` sessions, read back out of
/// Terminal.app's own tab titles while they ran.
@MainActor
@Suite("Agent status from the terminal title")
struct AgentStatusTests {

    @Test("The spinner means working, in either phase")
    func spinnerIsWorking() {
        #expect(AgentStatus.parse(title: "◐ diagnose-zig-statement-balance-mismatch") == .working)
        #expect(AgentStatus.parse(title: "◑ diagnose-zig-statement-balance-mismatch") == .working)
    }

    @Test("The asterisk means it has stopped and is waiting")
    func asteriskIsWaiting() {
        #expect(AgentStatus.parse(title: "✳ clear-conversation") == .waiting)
        #expect(AgentStatus.parse(title: "✳ Claude Code") == .waiting)
    }

    /// Both phases have to collapse to one badge. Echoing the live character
    /// would flicker the sidebar between two shapes a few times a second,
    /// which reads as a glitch rather than as progress.
    @Test("Both spinner phases show as the same glyph")
    func spinnerDoesNotStrobe() {
        let phases = ["◐ x", "◑ x", "◒ x", "◓ x"].compactMap { AgentStatus.parse(title: $0) }
        #expect(phases.count == 4)
        #expect(Set(phases.map(\.glyph)).count == 1)
    }

    @Test("A title nobody set, or one without a status glyph, is not an agent")
    func ordinaryTitlesAreNotAgents() {
        #expect(AgentStatus.parse(title: nil) == nil)
        #expect(AgentStatus.parse(title: "") == nil)
        #expect(AgentStatus.parse(title: "   ") == nil)
        #expect(AgentStatus.parse(title: "mike@host:~/src") == nil)
        #expect(AgentStatus.parse(title: "vim README.md") == nil)
    }

    /// The glyph leads the title; one buried in a filename the shell happens
    /// to be showing is not a status report.
    @Test("The glyph only counts at the front")
    func glyphMustLead() {
        #expect(AgentStatus.parse(title: "editing ✳ notes.txt") == nil)
        #expect(AgentStatus.parse(title: "build ◐ step") == nil)
    }

    @Test("Leading whitespace does not hide the glyph")
    func toleratesLeadingSpace() {
        #expect(AgentStatus.parse(title: "  ✳ waiting") == .waiting)
    }

    /// A bare glyph with nothing after it is still a status report — the summary
    /// is optional, and the badge counts tabs, not words.
    @Test("A glyph on its own is enough")
    func glyphAloneCounts() {
        #expect(AgentStatus.parse(title: "✳") == .waiting)
        #expect(AgentStatus.parse(title: "◐") == .working)
    }

    /// Matching is on the leading scalar, so a glyph dressed up with a
    /// variation selector still reads as the same state.
    @Test("A variation selector after the glyph does not break the match")
    func toleratesVariationSelector() {
        #expect(AgentStatus.parse(title: "✳\u{FE0F} clear-conversation") == .waiting)
    }

    /// The badges draw these two characters in the *system* font, not in the
    /// terminal's, so neither librio's embedded symbols font nor the user's
    /// chosen monospace face is there to fall back on. A glyph the system
    /// cannot resolve would show up as a tofu box in every project row.
    @Test("Both badge glyphs resolve to a real glyph in the badge font")
    func glyphsHaveCoverage() throws {
        for status in [AgentStatus.working, .waiting] {
            let attributed = NSAttributedString(string: status.glyph, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            let run = try #require(runs.first)

            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: glyphs.count), &glyphs)

            let attributes = CTRunGetAttributes(run) as NSDictionary
            let resolved = attributes[kCTFontAttributeName] as! CTFont
            let name = CTFontCopyFullName(resolved) as String
            print("AGENT glyph=\(status.glyph) font=\(name) glyphs=\(glyphs)")

            #expect(glyphs.first != 0, "no glyph for \(status.glyph)")
            #expect(!name.contains("LastResort"), "\(status.glyph) fell through to LastResort")
        }
    }
}
