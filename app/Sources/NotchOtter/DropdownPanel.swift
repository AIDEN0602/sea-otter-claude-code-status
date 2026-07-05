import AppKit

/// The dropdown session list panel that appears below the notch otter when
/// clicked. Lists every visible session with its state, age, and outputs
/// count; clicking a row focuses the matching Ghostty window.
final class DropdownPanelController {
    private static let width: CGFloat = SessionRowView.rowWidth
    private static let maxVisibleRows: CGFloat = 8
    private static let emptyHeight: CGFloat = 40

    let panel: NSPanel
    private let scrollView: NSScrollView
    private let documentView: FlippedView
    private let emptyLabel: NSTextField

    private(set) var isVisible = false

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.emptyHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let container = NotchContentView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.emptyHeight))
        container.layer?.cornerRadius = 12
        container.layer?.maskedCorners = [
            .layerMinXMinYCorner, .layerMaxXMinYCorner,
            .layerMinXMaxYCorner, .layerMaxXMaxYCorner
        ]

        // Top-left-origin (flipped) plain view so rows can be laid out with
        // simple, deterministic frames instead of Auto Layout constraints.
        documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.emptyHeight))

        emptyLabel = NSTextField(labelWithString: "No active sessions")
        emptyLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.alignment = .center
        emptyLabel.isBezeled = false
        emptyLabel.isEditable = false
        emptyLabel.isSelectable = false
        emptyLabel.backgroundColor = .clear

        scrollView = NSScrollView(frame: container.bounds)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView

        container.addSubview(scrollView)
        panel.contentView = container
    }

    /// Rebuilds the row list from the store's currently visible sessions and
    /// shows the panel anchored below `anchor` (top-left origin, screen coords).
    func show(store: SessionStore, below anchor: NSPoint, onRowClick: @escaping (SessionRecord) -> Void, onOutputsClick: @escaping (SessionRecord) -> Void) {
        rebuild(store: store, onRowClick: onRowClick, onOutputsClick: onOutputsClick)
        reposition(below: anchor)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
    }

    func toggle(store: SessionStore, below anchor: NSPoint, onRowClick: @escaping (SessionRecord) -> Void, onOutputsClick: @escaping (SessionRecord) -> Void) {
        if isVisible {
            hide()
        } else {
            show(store: store, below: anchor, onRowClick: onRowClick, onOutputsClick: onOutputsClick)
        }
    }

    /// Refreshes row contents in place without changing visibility, so an
    /// open dropdown stays live as sessions change.
    func refreshIfVisible(store: SessionStore, onRowClick: @escaping (SessionRecord) -> Void, onOutputsClick: @escaping (SessionRecord) -> Void) {
        guard isVisible else { return }
        let anchorOrigin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        rebuild(store: store, onRowClick: onRowClick, onOutputsClick: onOutputsClick)
        reposition(below: anchorOrigin)
    }

    private func rebuild(store: SessionStore, onRowClick: @escaping (SessionRecord) -> Void, onOutputsClick: @escaping (SessionRecord) -> Void) {
        documentView.subviews.forEach { $0.removeFromSuperview() }

        let records = store.visibleRecords
        let visiblePanelHeight: CGFloat

        if records.isEmpty {
            emptyLabel.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.emptyHeight)
            documentView.addSubview(emptyLabel)
            documentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.emptyHeight)
            visiblePanelHeight = Self.emptyHeight
        } else {
            var y: CGFloat = 4
            for record in records {
                let row = SessionRowView(record: record)
                row.onRowClick = onRowClick
                row.onOutputsClick = onOutputsClick
                row.frame = NSRect(x: 0, y: y, width: Self.width, height: SessionRowView.rowHeight)
                documentView.addSubview(row)
                y += SessionRowView.rowHeight
            }
            let totalContentHeight = y + 4
            documentView.frame = NSRect(x: 0, y: 0, width: Self.width, height: totalContentHeight)
            visiblePanelHeight = min(totalContentHeight, Self.maxVisibleRows * SessionRowView.rowHeight + 8)
        }

        panel.setContentSize(NSSize(width: Self.width, height: visiblePanelHeight))
        scrollView.frame = NSRect(x: 0, y: 0, width: Self.width, height: visiblePanelHeight)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: Self.width, height: visiblePanelHeight)
    }

    private func reposition(below anchor: NSPoint) {
        let size = panel.frame.size
        let frame = NSRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}

/// Plain NSView with a top-left origin, so row frames can be laid out
/// top-down with simple increasing y offsets.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
