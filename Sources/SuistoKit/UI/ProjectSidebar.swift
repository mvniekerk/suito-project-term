import AppKit

extension NSPasteboard.PasteboardType {
    /// Drag payload for reordering: the row's identifier, as a UUID string.
    /// Private to this app, so a drag cannot escape into another application.
    static let projectRow = NSPasteboard.PasteboardType("za.co.agri-io.suisto.project")
    static let tabItem = NSPasteboard.PasteboardType("za.co.agri-io.suisto.tab")
}

/// Works out where a drag should insert, given the midpoints of the existing
/// items along the drag axis.
///
/// Shared by the sidebar (vertical) and the tab bar (horizontal): the only
/// difference between them is which coordinate is read.
enum DropIndex {
    static func insertion(at position: CGFloat, midpoints: [CGFloat]) -> Int {
        midpoints.filter { position > $0 }.count
    }

    /// Where an item actually lands once it is pulled out of the list.
    ///
    /// Removing the dragged item first shifts everything after it down by one,
    /// so an insertion index past the original position has to be adjusted or
    /// the item lands one slot too far.
    static func destination(movingFrom source: Int, toInsertionIndex target: Int) -> Int {
        target > source ? target - 1 : target
    }
}

/// How far the pointer must travel before a press becomes a reorder drag.
///
/// Without a threshold every click is a one-pixel drag: the press selects, the
/// faintest tremor starts a dragging session, and letting go straight away
/// drops the item then and there. Reordering should cost a deliberate
/// movement, not a twitch.
enum DragThreshold {
    static let distance: CGFloat = 4

    static func exceeded(from origin: NSPoint, to point: NSPoint) -> Bool {
        abs(point.x - origin.x) >= distance || abs(point.y - origin.y) >= distance
    }
}

/// One project row: a glass selection pill with the colour chip, name and
/// live badges drawn above it.
///
/// Split in two because `NSGlassEffectView` is a view, not a fill: subviews
/// always composite above their parent's `draw(_:)`, so the label has to be a
/// sibling layered on top of the glass rather than drawn by the row itself.
@MainActor
final class ProjectRowView: NSView {
    var project: Project { didSet { apply() } }
    var badges: WorkspaceController.ProjectBadges { didSet { apply() } }
    var isSelected = false { didSet { apply() } }
    var onSelect: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?

    private let rowHeight: CGFloat = 46
    /// Glass rather than a flat wash, so the row picks up what is behind the
    /// sidebar and the project colour reads as a tint through it.
    private let glass = Glass.pill(cornerRadius: 10)
    private let content = RowContent()

    init(project: Project, badges: WorkspaceController.ProjectBadges) {
        self.project = project
        self.badges = badges
        super.init(frame: .zero)
        wantsLayer = true

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        // Inside the glass, not layered on top of it. NSGlassEffectView only
        // guarantees z-order for its own content view; a sibling above it gets
        // re-elevated by the container and ends up blurred underneath.
        glass.contentView = content
        Glass.pin(glass, to: self,
                  insets: NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6))
        Glass.pin(content, to: glass)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rowHeight)
    }

    func update(project: Project, badges: WorkspaceController.ProjectBadges) {
        self.project = project
        self.badges = badges
    }

    private func apply() {
        content.project = project
        content.badges = badges
        content.isSelected = isSelected
        // The pill is always there so the label always has its glass host;
        // only a selected row is tinted and solid enough to stand forward.
        glass.style = isSelected ? .regular : .clear
        // Tinting the glass, not covering it: the colour has to survive being
        // seen through, so it goes on at part strength.
        glass.tintColor = isSelected ? project.color.withAlphaComponent(0.55) : nil
    }
    // MARK: - Interaction

    /// Where the press started, in window coordinates. Cleared once a drag has
    /// begun so one press cannot open a second session.
    private var pressOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) {
        pressOrigin = event.locationInWindow
        onSelect?(project.id)
    }

    override func mouseUp(with event: NSEvent) {
        pressOrigin = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin,
              DragThreshold.exceeded(from: origin, to: event.locationInWindow) else { return }
        pressOrigin = nil

        let item = NSPasteboardItem()
        item.setString(project.id.uuidString, forType: .projectRow)

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    /// A picture of the row, so the drag carries the row itself rather than a
    /// generic badge.
    private func snapshot() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let edit = menu.addItem(withTitle: "Edit Project…",
                                action: #selector(editProject), keyEquivalent: "")
        edit.target = self
        let remove = menu.addItem(withTitle: "Remove Project",
                                  action: #selector(removeProject), keyEquivalent: "")
        remove.target = self
        return menu
    }

    @objc private func editProject() { onEdit?(project.id) }
    @objc private func removeProject() { onRemove?(project.id) }
}

/// Draws a project row. Transparent to the mouse, so the row above it keeps
/// handling clicks, drags and the context menu.
@MainActor
private final class RowContent: NSView {
    var project: Project? { didSet { needsDisplay = true } }
    var badges = WorkspaceController.ProjectBadges() { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let project else { return }
        let accent = project.color

        // The colour chip is the project's identity: full strength when
        // selected, dimmed otherwise, so the active project reads instantly.
        (isSelected ? accent : accent.withAlphaComponent(0.65)).setFill()
        NSRect(x: 8, y: 6, width: 3, height: bounds.height - 12).fill()

        let name = NSAttributedString(string: project.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
        name.draw(at: NSPoint(x: 18, y: bounds.height - 19))

        drawBadges(accent: accent)
    }

    private func drawBadges(accent: NSColor) {
        var pieces: [NSAttributedString] = []

        let mono = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        func chip(_ text: String, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: mono, .foregroundColor: color,
            ])
        }

        if badges.total > 0 {
            // busy / total sessions
            let busyColor: NSColor = badges.busy > 0 ? accent : .tertiaryLabelColor
            pieces.append(chip("\(badges.busy)/\(badges.total)", busyColor))
        }

        // Agents, when any tab here is running one. Working is the project's
        // own colour — it is getting on with it — and waiting is green,
        // because a stopped agent is the one thing on this row that is
        // actually asking for you.
        if badges.agentsWorking > 0 {
            pieces.append(chip("\(AgentStatus.working.glyph)\(badges.agentsWorking)", accent))
        }

        if badges.agentsWaiting > 0 {
            pieces.append(chip("\(AgentStatus.waiting.glyph)\(badges.agentsWaiting)", .systemGreen))
        }

        if let cpu = badges.cpuPercent, cpu >= 1 {
            // Warm the colour as it climbs, so a runaway job stands out.
            let color: NSColor = cpu >= 80 ? .systemOrange : .tertiaryLabelColor
            pieces.append(chip("\(Int(cpu.rounded()))%", color))
        } else if badges.total > 0 && badges.cpuPercent == nil {
            // Every session here is remote: local CPU would measure the ssh
            // client, not the work, so say nothing rather than show 0%.
            pieces.append(chip("—", .quaternaryLabelColor))
        }

        if badges.unread > 0 {
            pieces.append(chip("◆\(badges.unread)", accent))
        }

        if badges.bells > 0 {
            pieces.append(chip("🔔\(badges.bells)", .systemYellow))
        }

        var x: CGFloat = 18
        for piece in pieces {
            piece.draw(at: NSPoint(x: x, y: 5))
            x += piece.size().width + 8
        }
    }
}


extension ProjectRowView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation {
        // Reordering only: dragging a project out of the window means nothing.
        context == .withinApplication ? .move : []
    }
}

/// The left column: the major grouping.
@MainActor
final class ProjectSidebarView: NSView {
    private let stack = NSStackView()
    private let addButton = NSButton()
    private var rows: [UUID: ProjectRowView] = [:]
    private let backdrop = Glass.backdrop(.sidebar, blending: .behindWindow)

    var onSelect: ((UUID) -> Void)?
    var onEdit: ((UUID) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onAdd: (() -> Void)?
    /// Reordering, as (from, to) indices into the project list.
    var onReorder: ((Int, Int) -> Void)?

    /// Where a drop would land, drawn as an insertion line.
    private var dropIndicator: Int?
    /// Kept in the order they are shown, so a drop position maps to an index.
    private var orderedIDs: [UUID] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // A translucent sidebar rather than a flat slab, so the glass pills
        // on top of it have something with depth to sit against.
        addSubview(backdrop)
        Glass.pin(backdrop, to: self)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        // The titlebar is transparent and content runs under it, so the first
        // row has to clear the traffic lights.
        stack.edgeInsets = NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.title = "+ Project"
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.contentTintColor = .secondaryLabelColor
        addButton.font = .systemFont(ofSize: 11)
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        registerForDraggedTypes([.projectRow])

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    @objc private func addTapped() { onAdd?() }

    /// Rebuilds only what changed: rows are reused so a badge refresh every
    /// second does not churn the view tree.
    func update(projects: [Project], selected: UUID?,
                badges: (Project) -> WorkspaceController.ProjectBadges) {
        orderedIDs = projects.map { $0.id }
        let wanted = Set(projects.map { $0.id })
        for (id, row) in rows where !wanted.contains(id) {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
            rows[id] = nil
        }

        for (index, project) in projects.enumerated() {
            let row: ProjectRowView
            if let existing = rows[project.id] {
                existing.update(project: project, badges: badges(project))
                row = existing
            } else {
                let created = ProjectRowView(project: project, badges: badges(project))
                created.onSelect = { [weak self] in self?.onSelect?($0) }
                created.onEdit = { [weak self] in self?.onEdit?($0) }
                created.onRemove = { [weak self] in self?.onRemove?($0) }
                created.translatesAutoresizingMaskIntoConstraints = false
                rows[project.id] = created
                row = created
            }

            if stack.arrangedSubviews.indices.contains(index) {
                if stack.arrangedSubviews[index] !== row {
                    stack.insertArrangedSubview(row, at: index)
                }
            } else {
                stack.addArrangedSubview(row)
            }
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.isSelected = project.id == selected
        }
    }

    // MARK: - Reordering

    /// Row midpoints in this view's coordinates, top to bottom. Rows are laid
    /// out by the stack view, so their frames are the source of truth.
    func rowMidpointsTopDown() -> [CGFloat] {
        orderedIDs.compactMap { rows[$0] }.map { row in
            // A row is an arranged subview of the stack, so `row.frame` is in
            // the stack's space, while a drag location arrives in ours. The
            // stack is only as tall as its rows and sits at the top of a
            // full-height sidebar, so mixing the two put every drop above
            // every row — index 0 — and a click became "move to the top".
            let midY = convert(row.bounds, from: row).midY
            // Flip to a top-down axis so index 0 is the first row on screen.
            return bounds.height - midY
        }
    }

    /// The slot a drop at `point` — in this view's own coordinates — lands in.
    func insertionIndex(at point: NSPoint) -> Int {
        DropIndex.insertion(at: bounds.height - point.y,
                            midpoints: rowMidpointsTopDown())
    }

    private func insertionIndex(for sender: any NSDraggingInfo) -> Int {
        insertionIndex(at: convert(sender.draggingLocation, from: nil))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadItem(withDataConformingToTypes:
                [NSPasteboard.PasteboardType.projectRow.rawValue]) else { return [] }
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
        guard let raw = sender.draggingPasteboard.string(forType: .projectRow),
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

        let midpoints = rowMidpointsTopDown()
        let heights = orderedIDs.compactMap { rows[$0] }.map { $0.bounds.height }
        let half = (heights.first ?? 46) / 2
        let topDownY: CGFloat
        if index < midpoints.count {
            topDownY = midpoints[index] - half
        } else {
            topDownY = (midpoints.last ?? half) + half
        }

        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: bounds.height - topDownY - 1, width: bounds.width, height: 2).fill()
    }
}
