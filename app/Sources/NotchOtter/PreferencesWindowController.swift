import AppKit

/// The "Preferences…" window: lets the user pick the sprite pack
/// (character/icon) and which terminal app NotchOtter focuses when a
/// session's otter is clicked. Pure AppKit with manual (frame-based) layout,
/// matching the rest of the app -- no SwiftUI, no Auto Layout constraints.
///
/// A singleton (like SpritePacks/TerminalPreference): `show()` brings the
/// same window to front rather than creating a new one, and rebuilds both
/// sections from current disk/UserDefaults state every time it's shown, so
/// packs dropped into the sprites folder while the window was closed still
/// show up (same reasoning as StatusBarController's old Character submenu).
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private static let contentWidth: CGFloat = 440
    private static let margin: CGFloat = 20
    private static let rowHeight: CGFloat = 20
    private static let previewSize: CGFloat = 64

    private let scrollableContentView = NSView()
    private let previewImageView = NSImageView()
    private let previewLabel = NSTextField(labelWithString: "")

    /// Index-aligned with the dynamically-built character radio buttons
    /// (index 0 = "Otter (built-in)", nil packName); read back in
    /// `characterRadioClicked(_:)` via the button's `tag`.
    private var characterRadios: [(button: NSButton, packName: String?)] = []
    /// Index-aligned with the terminal radio buttons, same pattern.
    private var terminalRadios: [(button: NSButton, app: TerminalApp)] = []

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PreferencesWindowController.contentWidth, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchOtter Preferences"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.contentView = scrollableContentView
    }

    /// Brings the (one) Preferences window to front, rebuilding both
    /// sections first. The app runs with activation policy `.accessory`
    /// (no Dock icon), so without an explicit `activate` this window can
    /// open behind whatever app is currently frontmost.
    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    /// Tears down and rebuilds every subview, top-to-bottom, computing each
    /// block's height (measuring wrapped hint labels via `fittingSize`
    /// rather than guessing) before placing anything -- so the window
    /// always sizes exactly to its content, however many packs exist.
    private func refresh() {
        scrollableContentView.subviews.forEach { $0.removeFromSuperview() }

        let innerWidth = Self.contentWidth - Self.margin * 2
        var items: [(view: NSView, height: CGFloat, spacingAfter: CGFloat)] = []

        items.append((sectionHeader("Character"), 18, 8))
        let (characterBlock, characterHeight) = buildCharacterBlock(width: innerWidth)
        items.append((characterBlock, characterHeight, 10))
        let (packHint, packHintHeight) = hintLabel(
            "Packs are folders of <state>.png sprite sheets (see SPEC.md section 3). Missing states fall back to the built-in otter.",
            width: innerWidth
        )
        items.append((packHint, packHintHeight, 10))
        items.append((openFolderButton(), 24, 18))
        items.append((separatorView(width: innerWidth), 1, 18))

        items.append((sectionHeader("Terminal"), 18, 8))
        let (terminalBlock, terminalHeight) = buildTerminalBlock(width: innerWidth)
        items.append((terminalBlock, terminalHeight, 10))
        let (terminalHint, terminalHintHeight) = hintLabel(
            "NotchOtter focuses this terminal when you click a session's otter. Exact-tab focus is only "
                + "available for Ghostty; iTerm2 and Terminal use best-effort window focus by working directory.",
            width: innerWidth
        )
        items.append((terminalHint, terminalHintHeight, 0))

        let totalHeight = items.reduce(CGFloat(0)) { $0 + $1.height + $1.spacingAfter } + Self.margin * 2

        var cursorY = totalHeight - Self.margin
        for item in items {
            cursorY -= item.height
            item.view.frame = NSRect(x: Self.margin, y: cursorY, width: innerWidth, height: item.height)
            scrollableContentView.addSubview(item.view)
            cursorY -= item.spacingAfter
        }

        let size = NSSize(width: Self.contentWidth, height: totalHeight)
        scrollableContentView.setFrameSize(size)
        window?.setContentSize(size)
    }

    // MARK: - Character section

    /// Radio list on the left ("Otter (built-in)" + every
    /// `SpritePacks.availablePacks()` entry), a small idle-frame preview on
    /// the right. The preview reflects the current SELECTION (updates the
    /// instant a radio is clicked) rather than mouse-hover, which would need
    /// per-row tracking areas for little practical benefit here.
    private func buildCharacterBlock(width: CGFloat) -> (NSView, CGFloat) {
        let packs = SpritePacks.availablePacks()
        let selected = SpritePacks.selected
        let rightColumnWidth: CGFloat = Self.previewSize
        let columnGap: CGFloat = 16
        let leftColumnWidth = width - rightColumnWidth - columnGap

        let rowCount = 1 + packs.count
        let listHeight = CGFloat(rowCount) * Self.rowHeight
        let previewBlockHeight = Self.previewSize + 16
        let blockHeight = max(listHeight, previewBlockHeight)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: blockHeight))

        characterRadios.removeAll()
        let options: [String?] = [nil] + packs.map { Optional($0) }
        for (index, packName) in options.enumerated() {
            let title = packName ?? "Otter (built-in)"
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(characterRadioClicked(_:)))
            button.tag = index
            button.state = (packName == selected) ? .on : .off
            button.frame = NSRect(
                x: 0,
                y: blockHeight - CGFloat(index + 1) * Self.rowHeight,
                width: leftColumnWidth,
                height: Self.rowHeight
            )
            container.addSubview(button)
            characterRadios.append((button: button, packName: packName))
        }

        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.frame = NSRect(
            x: leftColumnWidth + columnGap,
            y: blockHeight - Self.previewSize,
            width: Self.previewSize,
            height: Self.previewSize
        )
        previewImageView.image = OtterSpriteView.previewImage(for: .idle)
        container.addSubview(previewImageView)

        previewLabel.stringValue = selected ?? "Otter (built-in)"
        previewLabel.font = .systemFont(ofSize: 10)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.alignment = .center
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.frame = NSRect(
            x: leftColumnWidth + columnGap,
            y: blockHeight - Self.previewSize - 15,
            width: Self.previewSize,
            height: 14
        )
        container.addSubview(previewLabel)

        return (container, blockHeight)
    }

    /// AppKit radio-button exclusivity is per immediate superview, so all of
    /// these being siblings under the same `container` (built above) is
    /// what makes clicking one automatically un-check the others -- no
    /// manual bookkeeping needed here beyond applying the selection and
    /// refreshing the preview.
    @objc private func characterRadioClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < characterRadios.count else { return }
        let packName = characterRadios[sender.tag].packName
        SpritePacks.select(packName)
        previewImageView.image = OtterSpriteView.previewImage(for: .idle)
        previewLabel.stringValue = packName ?? "Otter (built-in)"
    }

    @objc private func openPacksFolder() {
        NSWorkspace.shared.open(SpritePacks.ensurePacksDirectory())
    }

    // MARK: - Terminal section

    /// One radio row per `TerminalApp`, auto-detected via
    /// `TerminalApp.isInstalled` (LaunchServices bundle-id lookup): rows for
    /// terminals that aren't installed are disabled and labeled as such,
    /// rather than hidden, so the option is still visible/explainable.
    private func buildTerminalBlock(width: CGFloat) -> (NSView, CGFloat) {
        let selected = TerminalPreference.selected
        let apps = TerminalApp.allCases
        let blockHeight = CGFloat(apps.count) * Self.rowHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: blockHeight))

        terminalRadios.removeAll()
        for (index, app) in apps.enumerated() {
            let installed = app.isInstalled
            let title = installed ? app.displayName : "\(app.displayName) (not installed)"
            let button = NSButton(radioButtonWithTitle: title, target: self, action: #selector(terminalRadioClicked(_:)))
            button.tag = index
            button.isEnabled = installed
            button.state = (app == selected) ? .on : .off
            button.frame = NSRect(
                x: 0,
                y: blockHeight - CGFloat(index + 1) * Self.rowHeight,
                width: width,
                height: Self.rowHeight
            )
            container.addSubview(button)
            terminalRadios.append((button: button, app: app))
        }

        return (container, blockHeight)
    }

    @objc private func terminalRadioClicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < terminalRadios.count else { return }
        TerminalPreference.select(terminalRadios[sender.tag].app)
    }

    // MARK: - Small view builders

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .boldSystemFont(ofSize: 13)
        return label
    }

    /// A wrapping label sized to `width`, with its actual (measured, not
    /// guessed) height -- `preferredMaxLayoutWidth` makes `fittingSize`
    /// return a correct wrapped height even in this frame-based (non-Auto
    /// Layout) window.
    private func hintLabel(_ text: String, width: CGFloat) -> (view: NSTextField, height: CGFloat) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        let height = max(14, ceil(label.fittingSize.height))
        return (label, height)
    }

    private func separatorView(width: CGFloat) -> NSView {
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        box.boxType = .separator
        return box
    }

    private func openFolderButton() -> NSButton {
        let button = NSButton(title: "Open Sprite Packs Folder\u{2026}", target: self, action: #selector(openPacksFolder))
        button.bezelStyle = .rounded
        return button
    }
}
