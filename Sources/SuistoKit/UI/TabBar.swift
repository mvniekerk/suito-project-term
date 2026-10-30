import AppKit

/// One minor tab button: a glass pill with its label drawn above it.
///
/// Split in two like the project row, and for the same reason — glass is a
/// view, not a fill, so the label cannot be drawn by the view that hosts it.
@MainActor
final class TabButtonView: NSView {
    var tab: TabSpec { didSet { apply() } }
    var isSelected = false { didSet { apply() } }
    var accent: NSColor { didSet { apply() } }
    /// Set when the program behind this tab has exited.
    var hasExited = false { didSet { apply() } }
    var bells = 0 { didSet { apply() } }
    var hasUnread = false { didSet { apply() } }
    var isBusy = false { didSet { apply() } }
    /// What an agent in this tab is doing, when one is announcing it.
    var agent: AgentStatus? { didSet { apply() } }
    /// Live title from the program, when it set one.
    var liveTitle: String? { didSet { apply() } }

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRestart: ((UUID) -> Void)?

    private let glass = Glass.pill(cornerRadius: 9)
    private let content = TabContent()

    init(tab: TabSpec, accent: NSColor) {
        self.tab = tab
        self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        // Inside the glass: see the note on ProjectRowView.
        glass.contentView = content
        Glass.pin(glass, to: self,
                  insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        Glass.pin(content, to: glass)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    private var label: String {
        var text = tab.name
        if tab.target.isRemote { text = "⇡ " + text }
        return text
    }

    override var intrinsicContentSize: NSSize {
        let width = (label as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12),
        ]).width
        return NSSize(width: ceil(width) + 46, height: 30)
    }

    private func apply() {
        content.label = label
        content.isSelected = isSelected
        content.accent = accent
        content.hasExited = hasExited
        content.bells = bells
        content.hasUnread = hasUnread
        content.isBusy = isBusy
        content.agent = agent

        // Every tab gets a pill so the bar reads as one run of glass; only the
        // selected one is tinted and solid enough to stand forward.
        glass.style = isSelected ? .regular : .clear
        glass.tintColor = isSelected ? accent.withAlphaComponent(0.5) : nil
    }

    /// See `ProjectRowView.pressOrigin`: a tab must be dragged, not nudged.
    private var pressOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        onSelect?(tab.id)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin,
              DragThreshold.exceeded(from: origin, to: event.locationInWindow) else { return }
        pressOrigin = nil

        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: .tabItem)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, selector) in [
            ("Edit Tab…", #selector(editTab)),
            ("Restart", #selector(restartTab)),
            ("Close Tab", #selector(closeTab)),
        ] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    @objc private func editTab() { onEdit?(tab.id) }
    @objc private func restartTab() { onRestart?(tab.id) }
    @objc private func closeTab() { onClose?(tab.id) }
}

/// Draws a tab's label and status dot. Transparent to the mouse, so the
/// button above it keeps handling clicks, drags and the context menu.
@MainActor
private final class TabContent: NSView {
    var label = "" { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var hasExited = false { didSet { needsDisplay = true } }
    var bells = 0 { didSet { needsDisplay = true } }
    var hasUnread = false { didSet { needsDisplay = true } }
    var isBusy = false { didSet { needsDisplay = true } }
    var agent: AgentStatus? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        var color: NSColor = isSelected ? .labelColor : .secondaryLabelColor
        if hasExited { color = .tertiaryLabelColor }

        let title = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: isSelected ? .medium : .regular),
            .foregroundColor: color,
            .strikethroughStyle: hasExited ? NSUnderlineStyle.single.rawValue : 0,
        ])
        title.draw(at: NSPoint(x: 12, y: (bounds.height - title.size().height) / 2))

        // A single status mark at the trailing edge, in priority order: a
        // bell outranks an agent, which outranks unread output, which
        // outranks merely being busy.
        //
        // The agent sits above unread deliberately. An agent writes
        // constantly, so one left running in a background tab is always
        // unread, and a dot that is always lit says nothing; its own state
        // says whether it is still going or waiting on an answer.
        if bells == 0, let agent {
            let mark = NSAttributedString(string: agent.glyph, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: agent == .working ? accent : NSColor.systemGreen,
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: bounds.width - size.width - 8,
                                  y: (bounds.height - size.height) / 2))
            return
        }

        let dotColor: NSColor?
        if bells > 0 {
            dotColor = .systemYellow
        } else if hasUnread {
            dotColor = accent
        } else if isBusy {
            dotColor = accent.withAlphaComponent(0.45)
        } else {
            dotColor = nil
        }
        if let dotColor {
            dotColor.setFill()
            let size: CGFloat = 6
            NSBezierPath(ovalIn: NSRect(
                x: bounds.width - size - 10,
                y: (bounds.height - size) / 2,
                width: size, height: size)).fill()
        }
    }
}

extension TabButtonView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

/// The top row: the minor grouping, scoped to the selected project.
@MainActor
final class TabBarView: NSView {
    private let stack = NSStackView()
    private let addButton = NSButton()
    private var buttons: [UUID: TabButtonView] = [:]
    private let backdrop = Glass.backdrop(.headerView, blending: .behindWindow)
    /// Merges the tab pills into one shape when they sit close together.
    private let glassContainer = Glass.container(spacing: 10)

    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRestart: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    /// Reordering, as (from, to) indices into the project's tab list.
    var onReorder: ((Int, Int) -> Void)?

    private var dropIndicator: Int?
    private var orderedIDs: [UUID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(backdrop)
        Glass.pin(backdrop, to: self)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassContainer)
        glassContainer.contentView = stack
        Glass.pin(stack, to: glassContainer)

        addButton.title = "+"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 14)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        registerForDraggedTypes([.tabItem])

        NSLayoutConstraint.activate([
            glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            // The top 28pt belong to the titlebar and its traffic lights.
            glassContainer.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            addButton.leadingAnchor.constraint(
                equalTo: glassContainer.trailingAnchor, constant: 6),
            addButton.centerYAnchor.constraint(equalTo: glassContainer.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    @objc private func addTapped() { onAdd?() }

    struct TabStatus {
        var bells = 0
        var hasUnread = false
        var isBusy = false
        var hasExited = false
        var agent: AgentStatus?
        var liveTitle: String?
    }

    func update(tabs: [TabSpec], selected: UUID?, accent: NSColor,
                status: (TabSpec) -> TabStatus) {
        orderedIDs = tabs.map { $0.id }
        let wanted = Set(tabs.map { $0.id })
        for (id, button) in buttons where !wanted.contains(id) {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
            buttons[id] = nil
        }

        for (index, tab) in tabs.enumerated() {
            let button: TabButtonView
            if let existing = buttons[tab.id] {
                existing.tab = tab
                existing.accent = accent
                button = existing
            } else {
                let created = TabButtonView(tab: tab, accent: accent)
                created.onSelect = { [weak self] in self?.onSelect?($0) }
                created.onClose = { [weak self] in self?.onClose?($0) }
                created.onEdit = { [weak self] in self?.onEdit?($0) }
                created.onRestart = { [weak self] in self?.onRestart?($0) }
                buttons[tab.id] = created
                button = created
            }

            let state = status(tab)
            button.bells = state.bells
            button.hasUnread = state.hasUnread
            button.isBusy = state.isBusy
            button.hasExited = state.hasExited
            button.agent = state.agent
            button.liveTitle = state.liveTitle
            button.isSelected = tab.id == selected
            button.invalidateIntrinsicContentSize()

            if stack.arrangedSubviews.indices.contains(index) {
                if stack.arrangedSubviews[index] !== button {
                    stack.insertArrangedSubview(button, at: index)
                }
            } else {
                stack.addArrangedSubview(button)
            }
            button.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
        }
    }

    // MARK: - Reordering

    /// Tab midpoints along the horizontal axis, in display order.
    func buttonMidpoints() -> [CGFloat] {
        // Buttons are arranged inside the glass container's stack, which is
        // inset from this view's leading edge; a drag location arrives in this
        // view's space. Convert, or every drop is skewed by the inset.
        orderedIDs.compactMap { buttons[$0] }.map { convert($0.bounds, from: $0).midX }
    }

    private func insertionIndex(for sender: any NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        return DropIndex.insertion(at: point.x, midpoints: buttonMidpoints())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(withDataConformingToTypes:
                [NSPasteboard.PasteboardType.tabItem.rawValue]) else { return [] }
        dropIndicator = insertionIndex(for: sender)
        needsDisplay = true
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropIndicator = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dropIndicator = nil
            needsDisplay = true
        }
        guard let raw = sender.draggingPasteboard.string(forType: .tabItem),
              let id = UUID(uuidString: raw),
              let from = orderedIDs.firstIndex(of: id) else { return false }

        let to = DropIndex.destination(movingFrom: from,
                                       toInsertionIndex: insertionIndex(for: sender))
        guard to != from else { return false }
        onReorder?(from, to)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let index = dropIndicator else { return }

        let frames = orderedIDs.compactMap { buttons[$0] }.map { convert($0.bounds, from: $0) }
        let x: CGFloat
        if index < frames.count {
            x = frames[index].minX
        } else {
            x = frames.last.map { $0.maxX } ?? 0
        }
        NSColor.controlAccentColor.setFill()
        NSRect(x: max(0, x - 1), y: 0, width: 2, height: bounds.height).fill()
    }
}
