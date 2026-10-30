import AppKit

/// Liquid Glass building blocks.
///
/// `NSGlassEffectView` arrived in macOS 26 and Suisto already requires 26.5,
/// so it needs no availability check; only `effectIsInteractive` is newer and
/// has to be asked for.
///
/// Glass is used for the things that move and get picked — the selected
/// project, the tab pills — and never behind the terminal grid, where a
/// shifting translucent backdrop would fight the text for contrast.
@MainActor
enum Glass {
    /// A glass pill, used as a selection background.
    ///
    /// It carries no `contentView`. The API only promises z-order for the
    /// content view, and these rows draw their own label, so the label sits in
    /// a sibling above the glass instead of inside it.
    static func pill(cornerRadius: CGFloat) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 27.0, *) { view.effectIsInteractive = true }
        return view
    }

    /// Merges nearby glass pills into one shape instead of rendering each
    /// separately — the behaviour that makes a row of tabs read as a single
    /// piece of glass, and one render pass rather than one per pill.
    static func container(spacing: CGFloat) -> NSGlassEffectContainerView {
        let view = NSGlassEffectContainerView()
        view.spacing = spacing
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    /// The frosted panel behind a sidebar or a bar of controls.
    ///
    /// `.behindWindow` samples what is *behind the window*, so it only frosts
    /// if the window is non-opaque with a clear background — otherwise the
    /// material has nothing to sample and falls back to a flat fill.
    ///
    /// The state is `.active` rather than `.followsWindowActiveState`: a
    /// terminal is usually the window you are not looking at while something
    /// runs, and chrome that flattens to grey the moment it loses focus stops
    /// looking like glass exactly when it is most on screen.
    static func backdrop(_ material: NSVisualEffectView.Material,
                         blending: NSVisualEffectView.BlendingMode) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    static func pin(_ view: NSView, to parent: NSView,
                    insets: NSEdgeInsets = NSEdgeInsets()) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
