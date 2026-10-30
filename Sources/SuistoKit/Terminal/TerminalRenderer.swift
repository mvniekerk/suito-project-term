import CoreGraphics

/// Draws a terminal grid into a bitmap the view can present.
///
/// Deliberately narrow so the CoreText implementation can be swapped for a
/// Metal one without touching the view or the session.
@MainActor
protocol TerminalRenderer: AnyObject {
    var metrics: GlyphCache.Metrics { get }

    /// Resizes the backing store. `size` is in points; `scale` is the backing
    /// scale factor.
    func resize(to size: CGSize, scale: CGFloat)

    /// Pulls the session's render state and repaints whatever changed.
    /// Returns the image to present, or nil when there is nothing to show.
    func render(_ session: TerminalSession, focused: Bool) -> CGImage?

    /// Forces the next render to repaint every row.
    func invalidateAll()
}
