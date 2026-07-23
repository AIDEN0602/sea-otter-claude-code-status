import AppKit
import CoreGraphics

/// Content view for the companion panel: fully transparent (no background at
/// all -- just sprites floating), hosts the shared right-click context menu.
/// Left-click is handled per-otter (see OtterUnitView), not here -- clicking
/// empty space between otters does nothing.
final class CompanionContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true // layer-backed for smooth compositing; no background color set, so it stays transparent.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// One session's otter + its label, laid out vertically: otter on top, a
/// small semi-transparent name chip directly underneath. Left-clicking
/// anywhere on the unit focuses the matched Ghostty tab (or falls back to
/// cwd-matching for unmatched sessions).
final class OtterUnitView: NSView {
    static let otterSize: CGFloat = 96
    static let labelHeight: CGFloat = 14
    static let gap: CGFloat = 2
    static let totalHeight: CGFloat = otterSize + gap + labelHeight

    /// Label chip width for a session matched to a live Ghostty tab (shows
    /// the tab title, which can run longer than a folder name).
    static let matchedLabelWidth: CGFloat = 110
    /// Label chip width for an unmatched session (shows the project name,
    /// same as before this feature).
    static let unmatchedLabelWidth: CGFloat = 80

    /// Where a left-click on this otter should focus.
    enum FocusTarget: Equatable {
        /// Matched to a specific Ghostty tab -- focus by exact identity,
        /// since cwd-matching alone is ambiguous when multiple tabs share a
        /// working directory. `cwd` rides along too: if the user's selected
        /// terminal (see TerminalPreference) isn't Ghostty, exact-tab focus
        /// doesn't apply and TerminalFocusDispatcher falls back to it.
        case tab(windowIndex: Int, tabIndex: Int, cwd: String)
        /// Unmatched (headless run, different terminal, or tab data
        /// unavailable) -- fall back to the existing cwd-based focus.
        case cwd(String)
    }

    let sessionID: String
    private(set) var focusTarget: FocusTarget
    /// This unit's own width (varies: matched otters get a wider label chip
    /// than unmatched ones), used by the row layout to step `cursorX`.
    private(set) var totalWidth: CGFloat

    /// Set by the controller so dragging any otter moves the whole row
    /// (mirrors the desktop pet's drag behavior); a sub-4pt press-and-release
    /// still focuses the session's tab.
    weak var dragTarget: NSPanel?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private static let dragThreshold: CGFloat = 4
    private var pressOrigin: NSPoint?
    private var panelOriginAtPress: NSPoint?
    private var didDrag = false

    private let spriteView: OtterSpriteView
    private let labelBackground: NSView
    private let labelField: NSTextField

    init(sessionID: String, focusTarget: FocusTarget, labelText: String, labelWidth: CGFloat) {
        self.sessionID = sessionID
        self.focusTarget = focusTarget
        let unitWidth = max(Self.otterSize, labelWidth)
        self.totalWidth = unitWidth

        spriteView = OtterSpriteView(frame: NSRect(
            x: (unitWidth - Self.otterSize) / 2,
            y: Self.labelHeight + Self.gap,
            width: Self.otterSize,
            height: Self.otterSize
        ))

        let labelX = (unitWidth - labelWidth) / 2
        labelBackground = NSView(frame: NSRect(x: labelX, y: 0, width: labelWidth, height: Self.labelHeight))

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

        super.init(frame: NSRect(x: 0, y: 0, width: unitWidth, height: Self.totalHeight))
        wantsLayer = true

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

    func updateFocusTarget(_ target: FocusTarget) {
        focusTarget = target
    }

    /// Updates label text/width in place (tab title changed, or a session
    /// flipped between matched/unmatched), resizing this unit's own frame
    /// and repositioning subviews -- but keeping the SAME OtterSpriteView
    /// instance alive so its walk-cycle animation doesn't reset.
    func updateLabel(text: String, width: CGFloat) {
        let unitWidth = max(Self.otterSize, width)
        guard unitWidth != totalWidth || labelField.stringValue != text else { return }
        totalWidth = unitWidth

        setFrameSize(NSSize(width: unitWidth, height: Self.totalHeight))
        spriteView.setFrameOrigin(NSPoint(x: (unitWidth - Self.otterSize) / 2, y: Self.labelHeight + Self.gap))
        labelBackground.frame = NSRect(x: (unitWidth - width) / 2, y: 0, width: width, height: Self.labelHeight)
        labelField.frame = labelBackground.bounds.insetBy(dx: 2, dy: 0)
        labelField.stringValue = text
    }

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
            onDragStart?()
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
            return
        }
        switch focusTarget {
        case let .tab(windowIndex, tabIndex, cwd):
            TerminalFocusDispatcher.focusTab(windowIndex: windowIndex, tabIndex: tabIndex, cwd: cwd)
        case let .cwd(cwd):
            TerminalFocusDispatcher.focus(cwd: cwd)
        }
    }

    /// Right-click anywhere on a unit shows the row's shared context menu.
    /// NSView's default `menu(for:)` only returns `self.menu` (nil here), so
    /// without this override a right-click landing directly on an otter
    /// would show nothing even though the container has a menu set.
    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }

    /// Strips leading spinner/glyph characters and whitespace from a live
    /// Ghostty tab title (e.g. "✳ my-project" -> "my-project"), keeping
    /// any real text intact -- including CJK/Hangul, since Swift's
    /// `Character.isLetter` already recognizes Hangul syllables as letters,
    /// so no separate Unicode-range logic is needed.
    static func stripLeadingGlyphs(_ title: String) -> String {
        var chars = Substring(title)
        while let first = chars.first, !(first.isLetter || first.isNumber) {
            chars.removeFirst()
        }
        // Trailing whitespace is invisible in a centered label, but trim it
        // anyway for cleanliness (real Ghostty titles can have a trailing
        // space after the spinner glyph, e.g. "✳ Piauel ").
        return chars.trimmingCharacters(in: .whitespaces)
    }

    /// Char-count truncation for unmatched (project-name) labels -- the
    /// original behavior, kept as-is for that case. Matched tab-title labels
    /// use pixel-accurate `.byTruncatingTail` on a fixed-width field instead,
    /// since mixed English/Korean titles don't truncate predictably by raw
    /// character count (Hangul glyphs are roughly twice as wide as Latin
    /// ones at the same point size).
    static func truncateProjectName(_ name: String) -> String {
        guard name.count > 12 else { return name }
        return String(name.prefix(11)) + "\u{2026}"
    }
}

/// Small "+N" pill shown at the left end of the row when there are more
/// sessions than fit in the 5-otter cap.
final class OverflowChipView: NSView {
    static let width: CGFloat = 28
    static let height: CGFloat = 18

    let count: Int

    init(count: Int) {
        self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: "+\(count)")
        label.font = .boldSystemFont(ofSize: 10)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}

/// A row of "companion" otters -- one per live session, each animating its
/// own session's state -- perched on the frontmost Ghostty window. Visible
/// only while Ghostty is frontmost and at least one session exists. Never
/// steals focus (non-activating panel) and never covers the terminal's own
/// content (perched above the window's top edge, clamped inside it if
/// there's no room above).
///
/// Row order/labels come from `GhosttyTabMatcher`, fed by `GhosttyTabsPoller`
/// (live Ghostty tab list, polled every 2s). When tab data is unavailable
/// (Automation permission not granted, Ghostty not running, etc.) this
/// degrades gracefully to the pre-tab-matching behavior: firstSeenAt order,
/// project-name labels, cwd-based focus.
final class CompanionPanelController {
    private static let rightMargin: CGFloat = 24
    private static let rowSpacing: CGFloat = 8
    private static let maxOtters = 10
    /// How far below the window's top edge the row sits when it has to nest
    /// INSIDE the window (maximized / touching the menu bar): clears
    /// Ghostty's title-bar-plus-tab-strip so the otters never cover the tabs
    /// -- the panel swallows clicks, so covering the tab bar made tabs
    /// unclickable. Tuned by eye: 44 still grazed the strip's hit area on a
    /// maximized window, 76 sat too deep into the terminal content.
    private static let nestedTabBarOffset: CGFloat = 50
    private static let hiddenPrefKey = "NotchOtter.companionHidden"
    private static let ghosttyOwnerName = "Ghostty"
    private static let pollInterval: TimeInterval = 1.0

    let panel: NSPanel
    private let contentView: CompanionContentView

    /// Currently-shown per-session unit views, keyed by session_id, reused
    /// across updates (rather than destroyed/recreated) so an otter whose
    /// state hasn't changed doesn't have its walk-cycle animation reset.
    private var unitViews: [String: OtterUnitView] = [:]
    private var overflowChipView: OverflowChipView?

    /// True when the user hid the companion (status bar menu or its own
    /// right-click "Hide Companion"); persisted so it survives relaunch.
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: CompanionPanelController.hiddenPrefKey)

    private static let offsetXPrefKey = "NotchOtter.companionOffsetX"
    private static let offsetYPrefKey = "NotchOtter.companionOffsetY"

    /// Where the user parked the row, as an offset from the frontmost
    /// Ghostty window's bottom-left origin -- relative, so the row keeps
    /// following the window around. nil = default perch position. Persisted
    /// across relaunches; cleared via the right-click "Reset Position" item.
    private var customOffset: NSPoint? = CompanionPanelController.loadOffset()
    /// Suspends the follow timer's repositioning while the user is
    /// mid-drag, so it doesn't yank the row back every second.
    private var isDraggingRow = false

    private var isGhosttyFrontmost = false
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OtterUnitView.otterSize, height: OtterUnitView.totalHeight),
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

        contentView = CompanionContentView(frame: NSRect(x: 0, y: 0, width: OtterUnitView.otterSize, height: OtterUnitView.totalHeight))
        contentView.menu = buildContextMenu()
        panel.contentView = contentView

        isGhosttyFrontmost = NSWorkspace.shared.frontmostApplication.map(Self.isGhostty) ?? false

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.handleActivation(note)
        }

        // Tab data itself (GhosttyTabsPoller.shared) is a permanent app-wide
        // singleton started once in AppDelegate, not owned or lifecycle-tied
        // to this controller -- SessionStore.visibleRecords needs fresh-ish
        // tab-match data at all times (even while the companion is hidden)
        // to decide which done/idle sessions are exempt from the age prune.
        // AppDelegate observes `.ghosttyTabsPollerDidUpdate` and calls
        // `update(store:)` again from there, same as `.sessionStoreDidUpdate`.
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Rebuilds the otter row for the current session set and re-evaluates
    /// visibility. Reuses `SessionStore.visibleRecords` directly -- no
    /// duplicated state computation.
    func update(store: SessionStore) {
        let allVisible = store.visibleRecords
        let fullOrder = GhosttyTabMatcher.buildRowOrder(sessions: allVisible, tabs: GhosttyTabsPoller.shared.tabs)

        // Cap at 5, prioritizing matched (tab-order) rows over unmatched
        // ones when there's overflow, since matched rows correspond to
        // actually-open, user-recognizable Ghostty tabs.
        let overflowCount = max(0, fullOrder.count - Self.maxOtters)
        let displayed = Array(fullOrder.prefix(Self.maxOtters))

        rebuildRow(displayed: displayed, overflowCount: overflowCount)
        refreshVisibility(sessionsPresent: !allVisible.isEmpty)
    }

    /// Toggled by the status bar menu's "Show/Hide Companion" item.
    func toggleManualVisibility() {
        setManuallyHidden(!isManuallyHidden)
    }

    private func setManuallyHidden(_ hidden: Bool) {
        isManuallyHidden = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hiddenPrefKey)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
    }

    // MARK: - Row layout

    /// Diffs `displayed` against the currently-shown unit views: removes
    /// views for sessions no longer displayed, creates views for newly
    /// displayed sessions, and updates state/label/focus-target/position for
    /// all of them (in place where possible, to avoid resetting an
    /// unaffected otter's animation). Left-to-right in `displayed`'s given
    /// order (matched rows in Ghostty tab order, then unmatched rows in
    /// firstSeenAt order); the overflow "+N" chip (if any) sits at the row's
    /// left end.
    private func rebuildRow(displayed: [MatchedRow], overflowCount: Int) {
        let displayedIDs = Set(displayed.map { $0.record.session.sessionID })
        for (id, view) in unitViews where !displayedIDs.contains(id) {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }

        let sharedMenu = contentView.menu

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
        if overflowCount > 0 {
            overflowChipView?.setFrameOrigin(NSPoint(x: cursorX, y: (OtterUnitView.totalHeight - OverflowChipView.height) / 2))
            cursorX += OverflowChipView.width + Self.rowSpacing
        }

        for row in displayed {
            let record = row.record
            let id = record.session.sessionID

            let focusTarget: OtterUnitView.FocusTarget
            let labelText: String
            let labelWidth: CGFloat
            if let tab = row.matchedTab {
                focusTarget = .tab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, cwd: record.session.cwd)
                labelText = OtterUnitView.stripLeadingGlyphs(tab.title)
                labelWidth = OtterUnitView.matchedLabelWidth
            } else {
                focusTarget = .cwd(record.session.cwd)
                labelText = OtterUnitView.truncateProjectName(record.session.project)
                labelWidth = OtterUnitView.unmatchedLabelWidth
            }

            let unit: OtterUnitView
            if let existing = unitViews[id] {
                unit = existing
                unit.updateFocusTarget(focusTarget)
                unit.updateLabel(text: labelText, width: labelWidth)
            } else {
                unit = OtterUnitView(sessionID: id, focusTarget: focusTarget, labelText: labelText, labelWidth: labelWidth)
                unit.menu = sharedMenu
                unit.dragTarget = panel
                unit.onDragStart = { [weak self] in self?.isDraggingRow = true }
                unit.onDragEnd = { [weak self] in self?.finishRowDrag() }
                contentView.addSubview(unit)
                unitViews[id] = unit
            }
            unit.setState(record.displayState)
            unit.setFrameOrigin(NSPoint(x: cursorX, y: 0))
            cursorX += unit.totalWidth + Self.rowSpacing
        }

        let rowWidth = max(OtterUnitView.otterSize, cursorX - Self.rowSpacing)
        let size = NSSize(width: rowWidth, height: OtterUnitView.totalHeight)
        panel.setContentSize(size)
        contentView.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - Visibility rule: Ghostty frontmost + sessions exist + not hidden

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        isGhosttyFrontmost = Self.isGhostty(app)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
        if isGhosttyFrontmost {
            repositionToGhosttyWindow()
        }
    }

    private static func isGhostty(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, bundleID.localizedCaseInsensitiveContains("ghostty") {
            return true
        }
        return app.localizedName == ghosttyOwnerName
    }

    private func refreshVisibility(sessionsPresent: Bool) {
        let shouldShow = isGhosttyFrontmost && sessionsPresent && !isManuallyHidden
        guard shouldShow else {
            hidePanel()
            return
        }
        repositionToGhosttyWindow()
        startPolling()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopPolling()
    }

    /// Starts the reposition-follow timer (window-move/resize tracking
    /// while the companion is visible). `GhosttyTabsPoller.shared` is a
    /// separate, permanently-running app-wide singleton (started once in
    /// AppDelegate) -- not tied to this controller's own visibility, since
    /// SessionStore needs fresh tab-match data even while the companion
    /// itself is hidden.
    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.repositionToGhosttyWindow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Perch positioning

    /// Repositions the row onto the frontmost Ghostty window's top-right
    /// area, or hides the companion if no Ghostty window bounds can be found
    /// (e.g. all windows minimized). The perch anchor is unchanged from the
    /// single-otter version: each otter's own bottom edge sits ON the
    /// window's top edge; the label chips hang below that line (slightly
    /// over the window's own top edge), and the clamp-inside-the-window
    /// fallback now nests the whole otter+label unit rather than just the
    /// otter.
    private func repositionToGhosttyWindow() {
        guard !isDraggingRow else { return }
        guard let windowFrame = Self.frontmostGhosttyWindowFrame() else {
            panel.orderOut(nil)
            return
        }

        // User-parked position: follow the window at the dragged offset,
        // clamped to the screen -- anywhere is allowed, even over the
        // terminal content; that's the user's call.
        if let customOffset {
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main else {
                return
            }
            let size = panel.frame.size
            var origin = NSPoint(x: windowFrame.origin.x + customOffset.x, y: windowFrame.origin.y + customOffset.y)
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if !isManuallyHidden {
                panel.orderFrontRegardless()
            }
            return
        }
        // Clamp against whichever screen actually contains the Ghostty
        // window, not just NSScreen.main -- on multi-monitor setups the key
        // application's screen and the screen the terminal window lives on
        // can differ.
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main else {
            return
        }

        let rowWidth = panel.frame.width
        let unitHeight = OtterUnitView.totalHeight
        let perchLocalY = OtterUnitView.labelHeight + OtterUnitView.gap // local y of the otter's bottom edge

        var x = windowFrame.maxX - rowWidth - Self.rightMargin
        var y = windowFrame.maxY - perchLocalY

        // Clamp: if perching above the window would push the otters' tops
        // above the screen's visible area (window touches the menu bar /
        // near-fullscreen), nest the whole unit INSIDE the window -- but
        // BELOW the title bar + tab strip, so the tabs stay clickable.
        if y + unitHeight > screen.frame.maxY {
            y = windowFrame.maxY - unitHeight - Self.nestedTabBarOffset
        }

        // Keep the row horizontally within the window's own bounds.
        x = min(x, windowFrame.maxX - rowWidth)
        x = max(x, windowFrame.minX)

        panel.setFrame(NSRect(x: x, y: y, width: rowWidth, height: unitHeight), display: true)
        if !isManuallyHidden {
            panel.orderFrontRegardless()
        }
    }

    /// Below this size, a Ghostty window is treated as a quick-terminal-style
    /// overlay/sliver rather than a real terminal window worth perching on.
    private static let minRealWindowWidth: CGFloat = 400
    private static let minRealWindowHeight: CGFloat = 150

    /// Bounds of the frontmost real on-screen Ghostty window, converted from
    /// Quartz global-display coordinates (top-left origin, y-down) to AppKit
    /// screen coordinates (bottom-left origin, y-up). Only reads owner name,
    /// window layer, and bounds -- none of which require Screen Recording /
    /// Accessibility permission (unlike window titles, which are
    /// deliberately never read here).
    private static func frontmostGhosttyWindowFrame() -> NSRect? {
        // Quartz's global display coordinate space is anchored at the
        // top-left of the PRIMARY display (the one with the menu bar), which
        // AppKit always places at frame origin (0, 0) -- not necessarily
        // `NSScreen.screens.first` (that array's ordering isn't documented
        // to put the primary display first, and on multi-monitor setups it
        // sometimes doesn't). Anchoring the Y-flip to the wrong screen would
        // silently misplace the companion on any secondary display.
        guard let anchorScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo with .optionOnScreenOnly returns windows
        // already ordered front-to-back, so this preserves z-order
        // (candidates[0] is the frontmost Ghostty window, if any).
        var candidates: [NSRect] = []
        for info in infoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == ghosttyOwnerName else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let quartzY = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }

            let appKitY = anchorScreen.frame.height - quartzY - height
            candidates.append(NSRect(x: x, y: appKitY, width: width, height: height))
        }

        guard !candidates.isEmpty else { return nil }

        // Skip quick-terminal-style slivers/overlays (too narrow or too
        // short to be a real terminal window) and take the frontmost
        // survivor. If every on-screen Ghostty window is that small, fall
        // back to the largest by area rather than showing nothing.
        if let realWindow = candidates.first(where: { $0.width >= minRealWindowWidth && $0.height >= minRealWindowHeight }) {
            return realWindow
        }
        return candidates.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    // MARK: - Drag-to-park

    private func finishRowDrag() {
        isDraggingRow = false
        guard let windowFrame = Self.frontmostGhosttyWindowFrame() else { return }
        let offset = NSPoint(
            x: panel.frame.origin.x - windowFrame.origin.x,
            y: panel.frame.origin.y - windowFrame.origin.y
        )
        customOffset = offset
        UserDefaults.standard.set(Double(offset.x), forKey: Self.offsetXPrefKey)
        UserDefaults.standard.set(Double(offset.y), forKey: Self.offsetYPrefKey)
    }

    private static func loadOffset() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: offsetXPrefKey) != nil,
              defaults.object(forKey: offsetYPrefKey) != nil else { return nil }
        return NSPoint(
            x: CGFloat(defaults.double(forKey: offsetXPrefKey)),
            y: CGFloat(defaults.double(forKey: offsetYPrefKey))
        )
    }

    // MARK: - Context menu (right-click kill switch)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Companion", action: #selector(hideCompanionFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPositionFromContextMenu), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideCompanionFromContextMenu() {
        setManuallyHidden(true)
    }

    @objc private func resetPositionFromContextMenu() {
        customOffset = nil
        UserDefaults.standard.removeObject(forKey: Self.offsetXPrefKey)
        UserDefaults.standard.removeObject(forKey: Self.offsetYPrefKey)
        repositionToGhosttyWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
