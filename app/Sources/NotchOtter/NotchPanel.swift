import AppKit

/// Content view for the notch panel: pure black, no border/shadow (shadow is
/// disabled on the owning NSPanel), and forwards left-clicks to `onClick`.
/// Corner rounding is configured by the owner directly on `layer` after
/// construction (see NotchPanelController and DropdownPanelController for
/// their different masks).
final class NotchContentView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Owns the always-visible Dynamic-Island-style panel: a black pill hanging
/// directly BELOW the notch (top corners square so it visually merges with
/// the notch into one shape, bottom corners rounded), containing an animated
/// otter sprite plus a compact colored-count badge, centered. Non-activating
/// and borderless; the panel is at least as wide as the notch itself so its
/// sides always line up with the notch's edges.
final class NotchPanelController {
    private static let horizontalPadding: CGFloat = 10
    private static let spriteBadgeGap: CGFloat = 4
    /// Height of the black extension hanging below the notch.
    private static let panelHeight: CGFloat = 40
    private static let cornerRadius: CGFloat = 14
    private static let hiddenPrefKey = "NotchOtter.manuallyHidden"

    let panel: NSPanel
    private let contentView: NotchContentView
    private let spriteView: OtterSpriteView
    private let badgeLabel: NSTextField

    var onToggleDropdown: (() -> Void)?

    /// True when the user hid the panel (status bar menu or the otter's own
    /// right-click "Hide Otter"); persisted so it survives relaunch.
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: NotchPanelController.hiddenPrefKey)

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        contentView = NotchContentView(frame: NSRect(x: 0, y: 0, width: 120, height: Self.panelHeight))
        contentView.layer?.cornerRadius = Self.cornerRadius
        // Square TOP corners (they meet the notch's bottom edge, merging the
        // panel and the notch into one continuous black shape) and rounded
        // BOTTOM corners, exactly like the notch's own silhouette / iPhone's
        // Dynamic Island.
        contentView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        spriteView = OtterSpriteView(frame: .zero)

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.backgroundColor = .clear
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.lineBreakMode = .byClipping
        badgeLabel.isHidden = true

        contentView.addSubview(spriteView)
        contentView.addSubview(badgeLabel)
        contentView.onClick = { [weak self] in self?.onToggleDropdown?() }
        contentView.menu = buildContextMenu()
        panel.contentView = contentView
    }

    /// Refreshes the otter animation and badge for the current store state.
    /// Hides the entire panel when there are no sessions to show at all, or
    /// when the user manually hid it.
    func update(store: SessionStore) {
        guard let state = store.highestPriorityState else {
            panel.orderOut(nil)
            return
        }

        spriteView.setState(state)

        let badge = Self.compactBadge(for: store)
        badgeLabel.attributedStringValue = badge ?? NSAttributedString(string: "")
        badgeLabel.isHidden = badge == nil

        layoutContent()
        reposition()

        if !isManuallyHidden {
            panel.orderFrontRegardless()
        }
    }

    /// Toggled by the status bar menu's "Show/Hide Panel" item.
    func toggleManualVisibility() {
        setManuallyHidden(!isManuallyHidden)
    }

    private func setManuallyHidden(_ hidden: Bool) {
        isManuallyHidden = hidden
        UserDefaults.standard.set(hidden, forKey: Self.hiddenPrefKey)
        if hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    /// Lays out [otter][badge] centered inside the pill. The panel is at
    /// least as wide as the notch itself so its sides always line up with
    /// the notch's edges; it only grows wider when the content needs it.
    private func layoutContent() {
        let spriteSize = Self.panelHeight - 6
        let spriteY = (Self.panelHeight - spriteSize) / 2

        var contentWidth = spriteSize
        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            contentWidth += Self.spriteBadgeGap + badgeLabel.frame.width
        }

        let notchWidth = NotchGeometry.islandScreen.flatMap { NotchGeometry.metrics(for: $0)?.notchWidth } ?? 0
        let width = max(notchWidth, contentWidth + Self.horizontalPadding * 2)

        let spriteX = (width - contentWidth) / 2
        spriteView.frame = NSRect(x: spriteX, y: spriteY, width: spriteSize, height: spriteSize)
        if !badgeLabel.isHidden {
            badgeLabel.setFrameOrigin(NSPoint(
                x: spriteX + spriteSize + Self.spriteBadgeGap,
                y: (Self.panelHeight - badgeLabel.frame.height) / 2
            ))
        }

        let newSize = NSSize(width: width, height: Self.panelHeight)
        panel.setContentSize(newSize)
        contentView.frame = NSRect(origin: .zero, size: newSize)
    }

    /// Re-pins the panel directly below the notch (top edge flush with the
    /// bottom of the menu bar strip, horizontally centered on the notch).
    /// Call after content size changes and on screen configuration changes.
    func reposition() {
        guard let screen = NotchGeometry.islandScreen else { return }
        let frame = NotchGeometry.panelFrameBelowNotch(on: screen, size: panel.frame.size)
        panel.setFrame(frame, display: true)
    }

    /// Screen point (in screen coordinates) directly below the panel, used to
    /// anchor the dropdown.
    var bottomAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.minY)
    }

    // MARK: - Compact badge

    /// Colored digit-group badge like "3\u{00B7}1" (red error count, dim dot
    /// separator, orange waiting count, green working count) -- replaces the
    /// old full-text summary to keep the panel's total width minimal. The
    /// full "N working · M waiting" text remains available via
    /// `SessionStore.summaryText` in the dropdown and menu bar item.
    private static func compactBadge(for store: SessionStore) -> NSAttributedString? {
        let counts = store.compactCounts
        var groups: [(count: Int, color: NSColor)] = []
        if counts.error > 0 { groups.append((counts.error, .systemRed)) }
        if counts.waiting > 0 { groups.append((counts.waiting, .systemOrange)) }
        if counts.working > 0 { groups.append((counts.working, .systemGreen)) }
        guard !groups.isEmpty else { return nil }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let separatorAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.35)
        ]

        let result = NSMutableAttributedString()
        for (index, group) in groups.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\u{00B7}", attributes: separatorAttrs))
            }
            result.append(NSAttributedString(
                string: "\(group.count)",
                attributes: [.font: font, .foregroundColor: group.color]
            ))
        }
        return result
    }

    // MARK: - Context menu (right-click kill switch)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Otter", action: #selector(hideOtterFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideOtterFromContextMenu() {
        setManuallyHidden(true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
