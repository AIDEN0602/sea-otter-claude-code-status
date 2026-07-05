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

/// Owns the always-visible notch-adjacent panel: an animated otter sprite
/// plus a compact colored-count badge. Non-activating, borderless, flush
/// against the notch's right edge and spanning the exact safe-area strip
/// height, so it reads as a true horizontal extension of the notch rather
/// than a floating overlay.
final class NotchPanelController {
    private static let horizontalPadding: CGFloat = 3
    private static let spriteBadgeGap: CGFloat = 3
    /// Matches NotchGeometry's no-notch fallback strip height.
    private static let fallbackStripHeight: CGFloat = 24
    private static let cornerRadius: CGFloat = 6
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
            contentRect: NSRect(x: 0, y: 0, width: 40, height: Self.fallbackStripHeight),
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

        contentView = NotchContentView(frame: NSRect(x: 0, y: 0, width: 40, height: Self.fallbackStripHeight))
        contentView.layer?.cornerRadius = Self.cornerRadius
        // Square top corners (flush with the menu bar strip) and square
        // bottom-left corner (touches the notch); round only the outer
        // bottom-right corner so the panel reads as a small tab hanging off
        // the notch, not a floating box.
        contentView.layer?.maskedCorners = [.layerMaxXMinYCorner]

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

    private func layoutContent() {
        let screen = NSScreen.main
        let stripHeight = screen.flatMap { NotchGeometry.metrics(for: $0)?.stripHeight } ?? Self.fallbackStripHeight
        let scale = screen?.backingScaleFactor ?? 2

        let spriteSize = Self.spriteDisplaySize(stripHeight: stripHeight, scale: scale)
        spriteView.setFrameOrigin(NSPoint(x: Self.horizontalPadding, y: (stripHeight - spriteSize) / 2))
        spriteView.setFrameSize(NSSize(width: spriteSize, height: spriteSize))

        var width = Self.horizontalPadding + spriteSize + Self.horizontalPadding

        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            let badgeOrigin = CGPoint(
                x: Self.horizontalPadding + spriteSize + Self.spriteBadgeGap,
                y: (stripHeight - badgeLabel.frame.height) / 2
            )
            badgeLabel.setFrameOrigin(badgeOrigin)
            width = badgeOrigin.x + badgeLabel.frame.width + Self.horizontalPadding
        }

        let newSize = NSSize(width: width, height: stripHeight)
        panel.setContentSize(newSize)
        contentView.frame = NSRect(origin: .zero, size: newSize)
    }

    /// Re-pins the panel flush against the notch's right edge, spanning the
    /// full safe-area strip height. Call after content size changes and on
    /// screen configuration changes.
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let width = panel.frame.width
        let frame = NotchGeometry.panelFrame(on: screen, width: width)
        panel.setFrame(frame, display: true)
    }

    /// Screen point (in screen coordinates) directly below the panel, used to
    /// anchor the dropdown.
    var bottomAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.minY)
    }

    // MARK: - Sprite sizing

    /// The otter should fill the strip height (minus 2-3pt of padding), and
    /// prefers a height whose physical-pixel size lands on a whole multiple
    /// of the sprite's native 32px cell for crisp nearest-neighbor scaling.
    /// Falls back to the plain padded height when no such multiple fits
    /// inside the 2-3pt padding budget (common on typical current notch
    /// strip heights, e.g. 32pt).
    private static func spriteDisplaySize(stripHeight: CGFloat, scale: CGFloat) -> CGFloat {
        let minPadding: CGFloat = 2
        let maxPadding: CGFloat = 3
        let paddedHeight = stripHeight - (minPadding + maxPadding) / 2

        let nativeCell: CGFloat = 32
        let physicalPadded = paddedHeight * scale
        let nearestMultiple = (physicalPadded / nativeCell).rounded() * nativeCell
        let candidate = nearestMultiple / scale

        let minHeight = stripHeight - maxPadding
        let maxHeight = stripHeight - minPadding
        if candidate >= minHeight && candidate <= maxHeight {
            return candidate
        }
        return paddedHeight
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
