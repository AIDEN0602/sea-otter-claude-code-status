import AppKit

/// Compact relative age for the hover bubble ("now", "3m", "2h") so the
/// summary text reads with the right freshness.
private func ageText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return "\(Int(seconds / 3600))h"
}

/// Human-readable status line for the hover bubble, e.g. "working…" or
/// "needs permission!".
private func statusText(for state: SessionState) -> String {
    switch state {
    case .idle: return "idle"
    case .working: return "working\u{2026}"
    case .waitingPermission: return "needs permission!"
    case .waitingInput: return "waiting for input"
    case .done: return "done \u{2713}"
    case .error: return "error!"
    case .stale: return "stale"
    }
}

/// One desktop-pet otter: the sprite (with headroom above it so it can grow
/// on hover) and a name chip underneath. Hovering scales the sprite up and
/// fires `onHoverChange` so the controller can show the shared status
/// bubble; the bubble itself lives in a separate click-through panel (see
/// StatusBubbleController), NOT inside this view, so long summary text is
/// never clipped by the pet panel's own bounds.
///
/// Handles its own drag-vs-click disambiguation: dragging anywhere on the
/// otter moves the WHOLE panel (the pet is "carried around" the desktop),
/// while a sub-4pt press-and-release fires `onClick`.
final class PetOtterView: NSView {
    static let otterSize: CGFloat = 96
    /// Extra space above the resting sprite so the hover-grow never clips
    /// against the panel edge.
    static let growHeadroom: CGFloat = 12
    static let hoverScale: CGFloat = 1.12
    static let labelHeight: CGFloat = 14
    static let labelGap: CGFloat = 2
    static let totalHeight: CGFloat = growHeadroom + otterSize + labelGap + labelHeight
    static let unitWidth: CGFloat = 110

    private static let dragThreshold: CGFloat = 4

    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Set by the controller so a drag on any otter moves the shared panel.
    weak var dragTarget: NSPanel?
    var onDragEnd: (() -> Void)?

    private let spriteView: OtterSpriteView
    private let labelBackground: NSView
    private let labelField: NSTextField

    private var pressOrigin: NSPoint?
    private var panelOriginAtPress: NSPoint?
    private var didDrag = false

    private var restingSpriteFrame: NSRect {
        NSRect(
            x: (Self.unitWidth - Self.otterSize) / 2,
            y: Self.labelHeight + Self.labelGap,
            width: Self.otterSize,
            height: Self.otterSize
        )
    }

    private var grownSpriteFrame: NSRect {
        let size = Self.otterSize * Self.hoverScale
        // Anchored at the bottom-center of the resting frame: the otter's
        // feet stay planted, it puffs up and out.
        return NSRect(
            x: (Self.unitWidth - size) / 2,
            y: Self.labelHeight + Self.labelGap,
            width: size,
            height: size
        )
    }

    init(labelText: String) {
        spriteView = OtterSpriteView(frame: .zero)

        labelBackground = NSView(frame: NSRect(x: 0, y: 0, width: Self.unitWidth, height: Self.labelHeight))
        labelField = NSTextField(labelWithString: labelText)
        labelField.font = .boldSystemFont(ofSize: 9)
        labelField.textColor = .white
        labelField.alignment = .center
        labelField.backgroundColor = .clear
        labelField.isBezeled = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = labelBackground.bounds.insetBy(dx: 2, dy: 0)

        super.init(frame: NSRect(x: 0, y: 0, width: Self.unitWidth, height: Self.totalHeight))
        wantsLayer = true
        spriteView.frame = restingSpriteFrame

        labelBackground.wantsLayer = true
        labelBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        labelBackground.layer?.cornerRadius = 4
        labelBackground.layer?.cornerCurve = .continuous

        addSubview(spriteView)
        addSubview(labelBackground)
        labelBackground.addSubview(labelField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setState(_ state: SessionState) {
        spriteView.setState(state)
    }

    func setLabel(_ text: String) {
        guard labelField.stringValue != text else { return }
        labelField.stringValue = text
    }

    // MARK: - Hover: grow + bubble callback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        animateSprite(to: grownSpriteFrame)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        animateSprite(to: restingSpriteFrame)
        onHoverChange?(false)
    }

    private func animateSprite(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spriteView.animator().frame = frame
        }
    }

    // MARK: - Drag the whole panel vs. click

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        panelOriginAtPress = dragTarget?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin, let panelOriginAtPress, let panel = dragTarget else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - pressOrigin.x
        let dy = now.y - pressOrigin.y
        if !didDrag {
            guard abs(dx) >= Self.dragThreshold || abs(dy) >= Self.dragThreshold else { return }
            didDrag = true
            // The bubble's screen position goes stale the moment the panel
            // starts moving -- hide it for the duration of the drag.
            onHoverChange?(false)
        }
        panel.setFrameOrigin(NSPoint(x: panelOriginAtPress.x + dx, y: panelOriginAtPress.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressOrigin = nil
            panelOriginAtPress = nil
        }
        if didDrag {
            onDragEnd?()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}

/// The shared hover bubble: a small click-through panel (ignoresMouseEvents,
/// so it never steals the hover it depends on) showing a bold status line
/// plus the session's last-reply excerpt, auto-sized up to ~260pt wide and
/// positioned above whichever otter is hovered. One instance serves every
/// otter in the pet.
final class StatusBubbleController {
    private static let maxTextWidth: CGFloat = 244
    private static let paddingX: CGFloat = 10
    private static let paddingY: CGFloat = 7
    private static let gapAboveOtter: CGFloat = 6

    private let panel: NSPanel
    private let textField: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch above the pet panel so the bubble is never under it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 9
        container.layer?.cornerCurve = .continuous

        textField = NSTextField(wrappingLabelWithString: "")
        textField.font = .systemFont(ofSize: 10)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.maximumNumberOfLines = 4
        textField.cell?.truncatesLastVisibleLine = true

        container.addSubview(textField)
        panel.contentView = container
    }

    /// Shows the bubble centered above `view` (an otter in the pet panel).
    /// `statusLine` renders bold; `detail` (the last-reply excerpt) regular.
    func show(statusLine: String, detail: String?, above view: NSView) {
        guard let window = view.window else { return }

        let text = NSMutableAttributedString(
            string: statusLine,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        )
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            ))
        }
        textField.attributedStringValue = text
        textField.preferredMaxLayoutWidth = Self.maxTextWidth
        var textSize = textField.fittingSize
        textSize.width = min(textSize.width, Self.maxTextWidth)

        let bubbleSize = NSSize(
            width: textSize.width + Self.paddingX * 2,
            height: textSize.height + Self.paddingY * 2
        )
        textField.frame = NSRect(x: Self.paddingX, y: Self.paddingY, width: textSize.width, height: textSize.height)

        // Otter's frame in screen coordinates.
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        var origin = NSPoint(
            x: rectOnScreen.midX - bubbleSize.width / 2,
            y: rectOnScreen.maxY + Self.gapAboveOtter
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - bubbleSize.width - 4)
            if origin.y + bubbleSize.height > visible.maxY {
                // No room above (pet parked at the top edge): flip below.
                origin.y = rectOnScreen.minY - bubbleSize.height - Self.gapAboveOtter
            }
        }

        panel.setFrame(NSRect(origin: origin, size: bubbleSize), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: bubbleSize)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// A Codex-Pets-style desktop companion: while Ghostty is NOT frontmost (and
/// the notch/companion UIs are therefore out of sight), one otter floats
/// above every app, animating the highest-priority state across all live
/// sessions. It can be dragged anywhere (position persists across launches).
/// Clicking it expands the pet into one otter per live session -- hover any
/// of them to puff it up and read its status bubble (state + last reply
/// excerpt), click one to jump to its Ghostty tab, click the "\u{00AB}" chip
/// to collapse back to the single otter.
///
/// Complements (never overlaps) the existing UI: the notch panel is always
/// notch-anchored, and `CompanionPanelController` only shows while Ghostty IS
/// frontmost -- this controller only shows while it ISN'T.
final class DesktopPetController {
    private static let rowSpacing: CGFloat = 8
    private static let maxOtters = 8
    private static let hiddenPrefKey = "NotchOtter.desktopPetHidden"
    private static let originXPrefKey = "NotchOtter.desktopPetOriginX"
    private static let originYPrefKey = "NotchOtter.desktopPetOriginY"
    private static let ghosttyOwnerName = "Ghostty"

    let panel: NSPanel
    private let contentView: NSView
    private let bubble = StatusBubbleController()

    /// Per-session otters (expanded mode), keyed by session_id and reused
    /// across updates so walk-cycle animations don't reset.
    private var unitViews: [String: PetOtterView] = [:]
    /// The single summary otter (collapsed mode).
    private var summaryView: PetOtterView?
    private var collapseChipView: NSView?
    private var overflowChipView: OverflowChipView?

    private(set) var isExpanded = false
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: DesktopPetController.hiddenPrefKey)

    private var isGhosttyFrontmost = false
    private var activationObserver: NSObjectProtocol?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PetOtterView.unitWidth, height: PetOtterView.totalHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        contentView = NSView(frame: NSRect(x: 0, y: 0, width: PetOtterView.unitWidth, height: PetOtterView.totalHeight))
        contentView.wantsLayer = true
        contentView.menu = buildContextMenu()
        panel.contentView = contentView

        panel.setFrameOrigin(Self.loadOrigin() ?? Self.defaultOrigin())

        isGhosttyFrontmost = NSWorkspace.shared.frontmostApplication.map(Self.isGhostty) ?? false

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Rebuilds the pet for the current session set and re-evaluates
    /// visibility. Driven by AppDelegate on every store/tab update, same as
    /// the other panel controllers.
    func update(store: SessionStore) {
        let records = store.visibleRecords
        guard !records.isEmpty else {
            hidePanel()
            return
        }
        if isExpanded {
            layoutExpanded(store: store)
        } else {
            layoutCollapsed(store: store)
        }
        refreshVisibility(sessionsPresent: true)
    }

    func toggleManualVisibility() {
        isManuallyHidden.toggle()
        UserDefaults.standard.set(isManuallyHidden, forKey: Self.hiddenPrefKey)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
    }

    // MARK: - Collapsed layout: one summary otter

    private func layoutCollapsed(store: SessionStore) {
        for (id, view) in unitViews {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }
        collapseChipView?.removeFromSuperview()
        collapseChipView = nil
        overflowChipView?.removeFromSuperview()
        overflowChipView = nil

        let records = store.visibleRecords
        // The lone otter animates the most urgent state across every session
        // (same priority rule the notch otter uses), so "one of my runs needs
        // permission" is visible even from another app.
        let urgent = records.min { $0.displayState.priority < $1.displayState.priority }
        let state = urgent?.displayState ?? .idle

        let view: PetOtterView
        if let existing = summaryView {
            view = existing
        } else {
            view = PetOtterView(labelText: "")
            view.dragTarget = panel
            view.onDragEnd = { [weak self] in self?.saveOrigin() }
            view.onClick = { [weak self] in self?.setExpanded(true) }
            contentView.addSubview(view)
            summaryView = view
        }
        view.setState(state)
        view.setLabel(records.count == 1
            ? OtterUnitView.truncateProjectName(records[0].session.project)
            : "\(records.count) sessions")

        // Bubble: overall summary line, plus the most urgent session's
        // project + last-reply excerpt as the detail.
        let statusLine = store.summaryText.isEmpty ? statusText(for: state) : store.summaryText
        var detail: String?
        if let urgent {
            let excerpt = urgent.session.lastSummary ?? statusText(for: urgent.displayState)
            detail = "\(urgent.session.project) (\(ageText(urgent.ageSeconds))): \(excerpt)"
        }
        view.onHoverChange = { [weak self, weak view] hovering in
            guard let self else { return }
            if hovering, let view {
                self.bubble.show(statusLine: statusLine, detail: detail, above: view)
            } else {
                self.bubble.hide()
            }
        }
        view.setFrameOrigin(.zero)

        resizePanelKeepingAnchor(width: PetOtterView.unitWidth)
    }

    // MARK: - Expanded layout: one otter per session + collapse chip

    private func layoutExpanded(store: SessionStore) {
        summaryView?.removeFromSuperview()
        summaryView = nil

        let fullOrder = GhosttyTabMatcher.buildRowOrder(
            sessions: store.visibleRecords,
            tabs: GhosttyTabsPoller.shared.tabs
        )
        let overflowCount = max(0, fullOrder.count - Self.maxOtters)
        let displayed = Array(fullOrder.prefix(Self.maxOtters))

        let displayedIDs = Set(displayed.map { $0.record.session.sessionID })
        for (id, view) in unitViews where !displayedIDs.contains(id) {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }

        let sharedMenu = contentView.menu

        if collapseChipView == nil {
            let chip = CollapseChipView()
            chip.menu = sharedMenu
            chip.onClick = { [weak self] in self?.setExpanded(false) }
            contentView.addSubview(chip)
            collapseChipView = chip
        }

        if overflowCount > 0 {
            if overflowChipView?.count != overflowCount {
                overflowChipView?.removeFromSuperview()
                let chip = OverflowChipView(count: overflowCount)
                chip.menu = sharedMenu
                contentView.addSubview(chip)
                overflowChipView = chip
            }
        } else if let existing = overflowChipView {
            existing.removeFromSuperview()
            overflowChipView = nil
        }

        var cursorX: CGFloat = 0
        let chipY = PetOtterView.labelHeight + PetOtterView.labelGap
            + (PetOtterView.otterSize - CollapseChipView.height) / 2
        collapseChipView?.setFrameOrigin(NSPoint(x: cursorX, y: chipY))
        cursorX += CollapseChipView.width + Self.rowSpacing

        if overflowCount > 0 {
            overflowChipView?.setFrameOrigin(NSPoint(
                x: cursorX,
                y: PetOtterView.labelHeight + PetOtterView.labelGap
                    + (PetOtterView.otterSize - OverflowChipView.height) / 2
            ))
            cursorX += OverflowChipView.width + Self.rowSpacing
        }

        for row in displayed {
            let record = row.record
            let id = record.session.sessionID

            let labelText: String
            if let tab = row.matchedTab {
                labelText = OtterUnitView.stripLeadingGlyphs(tab.title)
            } else {
                labelText = OtterUnitView.truncateProjectName(record.session.project)
            }

            let unit: PetOtterView
            if let existing = unitViews[id] {
                unit = existing
            } else {
                unit = PetOtterView(labelText: labelText)
                unit.menu = sharedMenu
                unit.dragTarget = panel
                unit.onDragEnd = { [weak self] in self?.saveOrigin() }
                contentView.addSubview(unit)
                unitViews[id] = unit
            }
            // Rebind click/hover targets each update -- the matched tab's
            // ordinals and the last-reply excerpt both change over time.
            let matchedTab = row.matchedTab
            let cwd = record.session.cwd
            unit.onClick = {
                if let tab = matchedTab {
                    TerminalFocusDispatcher.focusTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, cwd: cwd)
                } else {
                    TerminalFocusDispatcher.focus(cwd: cwd)
                }
            }
            let statusLine = "\(statusText(for: record.displayState)) \u{00B7} \(record.session.project) \u{00B7} \(ageText(record.ageSeconds))"
            let detail = record.session.lastSummary
            unit.onHoverChange = { [weak self, weak unit] hovering in
                guard let self else { return }
                if hovering, let unit {
                    self.bubble.show(statusLine: statusLine, detail: detail, above: unit)
                } else {
                    self.bubble.hide()
                }
            }
            unit.setState(record.displayState)
            unit.setLabel(labelText)
            unit.setFrameOrigin(NSPoint(x: cursorX, y: 0))
            cursorX += PetOtterView.unitWidth + Self.rowSpacing
        }

        resizePanelKeepingAnchor(width: max(PetOtterView.unitWidth, cursorX - Self.rowSpacing))
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        bubble.hide()
        update(store: SessionStore.shared)
    }

    /// Resizes the panel so its top-RIGHT corner stays put: the summary otter
    /// keeps its spot and the session otters pop out leftward (and fold back
    /// into the same spot on collapse), then clamps to the screen so a pet
    /// parked near an edge never expands off-screen.
    private func resizePanelKeepingAnchor(width: CGFloat) {
        let size = NSSize(width: width, height: PetOtterView.totalHeight)
        guard panel.frame.size != size else {
            contentView.frame = NSRect(origin: .zero, size: size)
            return
        }
        let anchorMaxX = panel.frame.maxX
        let y = panel.frame.origin.y
        var frame = NSRect(x: anchorMaxX - width, y: y, width: width, height: size.height)

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - width))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }

        panel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - Visibility rule: Ghostty NOT frontmost + sessions exist + not hidden

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        isGhosttyFrontmost = Self.isGhostty(app)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
    }

    private static func isGhostty(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, bundleID.localizedCaseInsensitiveContains("ghostty") {
            return true
        }
        return app.localizedName == ghosttyOwnerName
    }

    private func refreshVisibility(sessionsPresent: Bool) {
        let shouldShow = !isGhosttyFrontmost && sessionsPresent && !isManuallyHidden
        guard shouldShow else {
            hidePanel()
            return
        }
        clampOntoScreen()
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        bubble.hide()
    }

    /// Pulls the panel fully back into some screen's visible area, e.g. after
    /// a display was unplugged while the pet was parked on it.
    private func clampOntoScreen() {
        var frame = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    // MARK: - Position persistence (anchored to the top-right corner, since
    // that's the point `resizePanelKeepingAnchor` keeps fixed)

    private func saveOrigin() {
        UserDefaults.standard.set(Double(panel.frame.maxX), forKey: Self.originXPrefKey)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYPrefKey)
    }

    private static func loadOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXPrefKey) != nil,
              defaults.object(forKey: originYPrefKey) != nil else { return nil }
        let maxX = CGFloat(defaults.double(forKey: originXPrefKey))
        let y = CGFloat(defaults.double(forKey: originYPrefKey))
        return NSPoint(x: maxX - PetOtterView.unitWidth, y: y)
    }

    private static func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - PetOtterView.unitWidth - 24,
            y: visible.minY + 24
        )
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Desktop Pet", action: #selector(hideFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideFromContextMenu() {
        isManuallyHidden = true
        UserDefaults.standard.set(true, forKey: Self.hiddenPrefKey)
        hidePanel()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

/// Small "\u{00AB}" pill at the row's left end (expanded mode) that folds the
/// pet back into the single summary otter.
final class CollapseChipView: NSView {
    static let width: CGFloat = 28
    static let height: CGFloat = 18

    var onClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: "\u{00AB}")
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}
