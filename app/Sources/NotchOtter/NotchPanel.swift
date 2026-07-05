import AppKit

/// Content view for the notch panel: pure black, rounded on the bottom
/// corners only (so it reads as an extension hanging down from the notch),
/// and forwards clicks to `onClick`.
final class NotchContentView: NSView {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        // In Core Animation layer coordinates the origin is bottom-left, so
        // the "bottom" corners of the panel (as seen on screen, hanging below
        // the notch) are the MinY corners.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Owns the always-visible notch-adjacent panel: an animated otter sprite
/// plus a compact text badge summarizing session counts. Non-activating,
/// borderless, pinned to the top of the screen immediately right of the
/// physical notch (or top-center as a fallback).
final class NotchPanelController {
    private static let height: CGFloat = 28
    private static let spriteSize: CGFloat = 24
    private static let minWidth: CGFloat = 40
    private static let horizontalPadding: CGFloat = 8
    private static let spriteBadgeGap: CGFloat = 6

    let panel: NSPanel
    private let contentView: NotchContentView
    private let spriteView: OtterSpriteView
    private let badgeLabel: NSTextField

    var onToggleDropdown: (() -> Void)?

    /// True when the user explicitly hid the panel from the status bar menu;
    /// suppresses auto-show on session updates until toggled back on.
    private(set) var isManuallyHidden = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height),
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

        contentView = NotchContentView(frame: NSRect(x: 0, y: 0, width: Self.minWidth, height: Self.height))
        spriteView = OtterSpriteView(frame: NSRect(
            x: Self.horizontalPadding,
            y: (Self.height - Self.spriteSize) / 2,
            width: Self.spriteSize,
            height: Self.spriteSize
        ))

        badgeLabel = NSTextField(labelWithString: "")
        badgeLabel.textColor = .white
        badgeLabel.font = .systemFont(ofSize: 11, weight: .medium)
        badgeLabel.backgroundColor = .clear
        badgeLabel.isBezeled = false
        badgeLabel.isEditable = false
        badgeLabel.isSelectable = false
        badgeLabel.lineBreakMode = .byClipping

        contentView.addSubview(spriteView)
        contentView.addSubview(badgeLabel)
        contentView.onClick = { [weak self] in self?.onToggleDropdown?() }
        panel.contentView = contentView
    }

    /// Refreshes the otter animation and badge for the current store state.
    /// Hides the entire panel when there are no sessions to show at all, or
    /// when the user manually hid it via the status bar menu.
    func update(store: SessionStore) {
        guard let state = store.highestPriorityState else {
            panel.orderOut(nil)
            return
        }

        spriteView.setState(state)

        let summary = store.summaryText
        badgeLabel.stringValue = summary
        badgeLabel.isHidden = summary.isEmpty

        layoutContent(hasBadge: !summary.isEmpty)
        reposition()

        if !isManuallyHidden {
            panel.orderFrontRegardless()
        }
    }

    /// Toggled by the "Show/Hide Panel" status bar menu item.
    func toggleManualVisibility() {
        isManuallyHidden.toggle()
        if isManuallyHidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func layoutContent(hasBadge: Bool) {
        var width = Self.horizontalPadding + Self.spriteSize + Self.horizontalPadding

        if hasBadge {
            badgeLabel.sizeToFit()
            let badgeOrigin = CGPoint(
                x: Self.horizontalPadding + Self.spriteSize + Self.spriteBadgeGap,
                y: (Self.height - badgeLabel.frame.height) / 2
            )
            badgeLabel.setFrameOrigin(badgeOrigin)
            width = badgeOrigin.x + badgeLabel.frame.width + Self.horizontalPadding
        }

        width = max(width, Self.minWidth)
        let newFrame = NSRect(origin: panel.frame.origin, size: NSSize(width: width, height: Self.height))
        panel.setFrame(newFrame, display: true)
        contentView.frame = NSRect(origin: .zero, size: newFrame.size)
        spriteView.setFrameOrigin(NSPoint(x: Self.horizontalPadding, y: (Self.height - Self.spriteSize) / 2))
    }

    /// Re-pins the panel to the notch-adjacent position on the main screen.
    /// Call after content size changes and on screen configuration changes.
    func reposition() {
        guard let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let frame = NotchGeometry.panelFrame(on: screen, size: size)
        panel.setFrame(frame, display: true)
    }

    /// Screen point (in screen coordinates) directly below the panel, used to
    /// anchor the dropdown.
    var bottomAnchorPoint: NSPoint {
        NSPoint(x: panel.frame.minX, y: panel.frame.minY)
    }
}
