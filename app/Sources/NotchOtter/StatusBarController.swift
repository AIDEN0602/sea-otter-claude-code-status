import AppKit
import ServiceManagement

/// Menu bar item: shows the same compact summary as the notch badge, plus a
/// menu for showing/hiding the notch panel and the companion, toggling
/// launch-at-login, and quitting the app.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var notchPanelController: NotchPanelController?
    private weak var companionPanelController: CompanionPanelController?
    private weak var desktopPetController: DesktopPetController?
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let showHideItem = NSMenuItem(title: "Show/Hide Panel", action: nil, keyEquivalent: "")
    private let showHideCompanionItem = NSMenuItem(title: "Show/Hide Companion", action: nil, keyEquivalent: "")
    private let showHideDesktopPetItem = NSMenuItem(title: "Show/Hide Desktop Pet", action: nil, keyEquivalent: "")

    init(
        notchPanelController: NotchPanelController,
        companionPanelController: CompanionPanelController,
        desktopPetController: DesktopPetController
    ) {
        self.notchPanelController = notchPanelController
        self.companionPanelController = companionPanelController
        self.desktopPetController = desktopPetController
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "\u{1F9A6}" // otter emoji as a stable fallback icon
        statusItem.menu = buildMenu()
    }

    /// Mirrors `SessionStore.summaryText` onto the menu bar button.
    func updateSummary(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = text.isEmpty ? "\u{1F9A6}" : "\u{1F9A6} \(text)"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        showHideItem.target = self
        showHideItem.action = #selector(toggleShowHidePanel)
        menu.addItem(showHideItem)

        showHideCompanionItem.target = self
        showHideCompanionItem.action = #selector(toggleShowHideCompanion)
        menu.addItem(showHideCompanionItem)

        showHideDesktopPetItem.target = self
        showHideDesktopPetItem.action = #selector(toggleShowHideDesktopPet)
        menu.addItem(showHideDesktopPetItem)

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin(_:))
        launchAtLoginItem.state = currentLaunchAtLoginState
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    /// Keeps both checkmarks in sync even when visibility changed elsewhere
    /// (e.g. the otter's own right-click "Hide Otter"/"Hide Companion" items).
    func menuWillOpen(_ menu: NSMenu) {
        showHideItem.state = (notchPanelController?.isManuallyHidden ?? false) ? .off : .on
        showHideCompanionItem.state = (companionPanelController?.isManuallyHidden ?? false) ? .off : .on
        showHideDesktopPetItem.state = (desktopPetController?.isManuallyHidden ?? false) ? .off : .on
    }

    @objc private func toggleShowHidePanel() {
        notchPanelController?.toggleManualVisibility()
    }

    @objc private func toggleShowHideCompanion() {
        companionPanelController?.toggleManualVisibility()
    }

    @objc private func toggleShowHideDesktopPet() {
        desktopPetController?.toggleManualVisibility()
    }

    private var currentLaunchAtLoginState: NSControl.StateValue {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled ? .on : .off
        }
        return .off
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else {
            NSLog("NotchOtter: Launch at Login requires macOS 13 or later.")
            return
        }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("NotchOtter: Launch at Login toggle failed: \(error)")
        }
        sender.state = currentLaunchAtLoginState
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
