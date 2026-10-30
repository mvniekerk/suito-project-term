import AppKit

/// How far the viewport moves when a selection drag leaves the view.
///
/// Dragging past an edge has to keep extending the selection into text that
/// is not on screen, so the overshoot is converted into a scroll. The sign
/// follows librio's: positive scrolls back into history.
///
/// A single event never moves more than one screen, so flinging the pointer
/// far outside the window pans steadily instead of jumping to an end.
enum SelectionAutoscroll {
    /// `row` is the fractional row from the top of the view, unclamped:
    /// negative above it, greater than `rows - 1` below it.
    static func lines(forRow row: CGFloat, rows: Int) -> Int32 {
        let rows = max(1, rows)
        guard row.isFinite else { return 0 }

        if row < 0 {
            return Int32(min(CGFloat(rows), (-row).rounded(.up)))
        }
        let last = CGFloat(rows - 1)
        if row > last {
            return -Int32(min(CGFloat(rows), (row - last).rounded(.up)))
        }
        return 0
    }
}

/// The terminal's right-click menu.
///
/// Built here rather than inline so its shape can be tested, and built fresh
/// on every click so Copy and Paste validate against the selection and the
/// clipboard as they stand at that moment.
@MainActor
enum TerminalContextMenu {
    static func make(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, _ key: String) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            // Explicit, for the same reason the View menu is: an item whose
            // action no responder claims is silently disabled.
            item.target = target
        }

        add("Copy", #selector(NSText.copy(_:)), "c")
        add("Paste", #selector(NSText.paste(_:)), "v")
        menu.addItem(.separator())
        add("Select All", #selector(NSResponder.selectAll(_:)), "a")
        add("Clear Selection", #selector(TerminalView.clearSelection(_:)), "")
        return menu
    }
}
