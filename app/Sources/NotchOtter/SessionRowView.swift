import AppKit

/// One row in the dropdown session list: state dot, project name, age,
/// outputs count, and an optional "Outputs" button. Clicking anywhere on the
/// row (other than the button) focuses the matching Ghostty window.
final class SessionRowView: NSView {
    static let rowHeight: CGFloat = 30
    static let rowWidth: CGFloat = 280

    let record: SessionRecord
    var onRowClick: ((SessionRecord) -> Void)?
    var onOutputsClick: ((SessionRecord) -> Void)?

    private let dotView = NSView(frame: NSRect(x: 12, y: 0, width: 8, height: 8))
    private let projectLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let ageLabel = NSTextField(labelWithString: "")
    private var outputsButton: NSButton?
    private let hoverLayer = CALayer()
    private var trackingArea: NSTrackingArea?

    init(record: SessionRecord) {
        self.record = record
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        wantsLayer = true

        hoverLayer.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        hoverLayer.isHidden = true
        layer?.addSublayer(hoverLayer)

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = Self.color(for: record.displayState).cgColor
        dotView.frame = NSRect(x: 12, y: (Self.rowHeight - 8) / 2, width: 8, height: 8)

        projectLabel.stringValue = record.session.project
        projectLabel.textColor = .white
        projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        configureLabelStyle(projectLabel)

        stateLabel.stringValue = record.displayState.rawValue.replacingOccurrences(of: "_", with: " ")
        stateLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        stateLabel.font = .systemFont(ofSize: 10, weight: .regular)
        configureLabelStyle(stateLabel)

        ageLabel.stringValue = Self.relativeAge(record.ageSeconds)
        ageLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        ageLabel.font = .systemFont(ofSize: 10, weight: .regular)
        ageLabel.alignment = .right
        configureLabelStyle(ageLabel)

        addSubview(dotView)
        addSubview(projectLabel)
        addSubview(stateLabel)
        addSubview(ageLabel)

        let outputCount = record.session.outputs.count
        if outputCount > 0 {
            let button = NSButton(title: "Outputs (\(outputCount))", target: self, action: #selector(outputsTapped))
            button.bezelStyle = .inline
            button.isBordered = true
            button.controlSize = .mini
            button.font = .systemFont(ofSize: 9)
            addSubview(button)
            outputsButton = button
        }

        layoutSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureLabelStyle(_ field: NSTextField) {
        field.isBezeled = false
        field.isEditable = false
        field.isSelectable = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
    }

    private func layoutSubviews() {
        let dotX: CGFloat = 12
        let textX = dotX + dotView.frame.width + 8
        var rightEdge = Self.rowWidth - 10

        if let button = outputsButton {
            button.sizeToFit()
            let buttonHeight = button.frame.height
            button.setFrameOrigin(NSPoint(x: rightEdge - button.frame.width, y: (Self.rowHeight - buttonHeight) / 2))
            rightEdge -= button.frame.width + 8
        }

        ageLabel.sizeToFit()
        ageLabel.setFrameOrigin(NSPoint(x: rightEdge - ageLabel.frame.width, y: (Self.rowHeight - ageLabel.frame.height) / 2))
        rightEdge -= ageLabel.frame.width + 8

        let textWidth = max(40, rightEdge - textX)
        projectLabel.frame = NSRect(x: textX, y: Self.rowHeight / 2, width: textWidth, height: Self.rowHeight / 2 - 1)
        stateLabel.frame = NSRect(x: textX, y: 2, width: textWidth, height: Self.rowHeight / 2 - 3)
    }

    override func layout() {
        super.layout()
        hoverLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverLayer.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hoverLayer.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onRowClick?(record)
    }

    @objc private func outputsTapped() {
        onOutputsClick?(record)
    }

    private static func color(for state: SessionState) -> NSColor {
        switch state {
        case .error: return .systemRed
        case .waitingPermission: return .systemOrange
        case .waitingInput: return .systemYellow
        case .working: return .systemBlue
        case .done: return .systemGreen
        case .idle: return .systemGray
        case .stale: return NSColor(white: 0.35, alpha: 1)
        }
    }

    private static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let remM = m % 60
        return remM > 0 ? "\(h)h\(remM)m" : "\(h)h"
    }
}
