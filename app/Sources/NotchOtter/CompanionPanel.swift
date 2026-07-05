import AppKit
import CoreGraphics

/// Content view for the companion panel: fully transparent (no background at
/// all -- just the sprite floating), forwards left-clicks to `onClick`, and
/// hosts a right-click context menu.
final class CompanionContentView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true // layer-backed for smooth compositing; no background color set, so it stays transparent.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// A large, transparent "companion" otter that perches on the frontmost
/// Ghostty window -- the clawd-on-desk feel, visible only while Ghostty is
/// frontmost and at least one session exists. Never steals focus
/// (non-activating panel) and never covers the terminal's own content
/// (perched above the window's top edge, clamped inside it if there's no
/// room above).
final class CompanionPanelController {
    /// 32px native sprite cell x3 = 96pt, per spec.
    private static let displaySize: CGFloat = 96
    private static let rightMargin: CGFloat = 24
    private static let hiddenPrefKey = "NotchOtter.companionHidden"
    private static let ghosttyOwnerName = "Ghostty"
    private static let pollInterval: TimeInterval = 1.0

    let panel: NSPanel
    private let contentView: CompanionContentView
    private let spriteView: OtterSpriteView

    var onToggleDropdown: (() -> Void)?

    /// True when the user hid the companion (status bar menu or its own
    /// right-click "Hide Companion"); persisted so it survives relaunch.
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: CompanionPanelController.hiddenPrefKey)

    private var isGhosttyFrontmost = false
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        let size = Self.displaySize
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
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

        contentView = CompanionContentView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        spriteView = OtterSpriteView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        contentView.addSubview(spriteView)
        contentView.onClick = { [weak self] in self?.onToggleDropdown?() }
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
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Refreshes the otter animation and re-evaluates visibility for the
    /// current store state. Reuses `SessionStore.highestPriorityState` --
    /// the same source of truth as the notch panel -- rather than
    /// duplicating any state computation.
    func update(store: SessionStore) {
        guard let state = store.highestPriorityState else {
            hidePanel()
            return
        }
        spriteView.setState(state)
        refreshVisibility(sessionsPresent: true)
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

    /// Repositions onto the frontmost Ghostty window's top-right area, or
    /// hides the companion if no Ghostty window bounds can be found (e.g.
    /// all windows minimized).
    private func repositionToGhosttyWindow() {
        guard let windowFrame = Self.frontmostGhosttyWindowFrame() else {
            panel.orderOut(nil)
            return
        }
        guard let screen = NSScreen.main else { return }

        let size = Self.displaySize
        var x = windowFrame.maxX - size - Self.rightMargin
        // Bottom edge of the otter sits ON the window's top edge (AppKit
        // coordinates are bottom-left origin, so the panel's own origin.y is
        // the window's top edge y-value).
        var y = windowFrame.maxY

        // Clamp: if perching above the window would go above the screen's
        // visible area (window touches the menu bar / near-fullscreen),
        // nest the otter INSIDE the window's top-right corner instead.
        if y + size > screen.frame.maxY {
            y = windowFrame.maxY - size
        }

        // Keep the otter horizontally within the window's own bounds.
        x = min(x, windowFrame.maxX - size)
        x = max(x, windowFrame.minX)

        panel.setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
        if !isManuallyHidden {
            panel.orderFrontRegardless()
        }
    }

    /// Bounds of the frontmost on-screen Ghostty window, converted from
    /// Quartz global-display coordinates (top-left origin, y-down) to AppKit
    /// screen coordinates (bottom-left origin, y-up). Only reads owner name,
    /// window layer, and bounds -- none of which require Screen Recording /
    /// Accessibility permission (unlike window titles, which are
    /// deliberately never read here).
    private static func frontmostGhosttyWindowFrame() -> NSRect? {
        guard let mainScreen = NSScreen.screens.first else { return nil }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo with .optionOnScreenOnly returns windows
        // already ordered front-to-back, so the first Ghostty match is the
        // frontmost one.
        for info in infoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == ghosttyOwnerName else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let quartzY = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }

            let appKitY = mainScreen.frame.height - quartzY - height
            return NSRect(x: x, y: appKitY, width: width, height: height)
        }
        return nil
    }

    /// Screen point (in screen coordinates) directly below the companion,
    /// used to anchor the shared dropdown when toggled from here.
    var bottomAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.minY)
    }

    // MARK: - Context menu (right-click kill switch)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Companion", action: #selector(hideCompanionFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideCompanionFromContextMenu() {
        setManuallyHidden(true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
