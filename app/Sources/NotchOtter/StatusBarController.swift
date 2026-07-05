import AppKit
import ServiceManagement

/// Menu bar item: shows the same compact summary as the notch badge, plus a
/// menu for showing/hiding the notch panel, toggling launch-at-login, and
/// quitting the app.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var notchPanelController: NotchPanelController?
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")
    private let showHideItem = NSMenuItem(title: "Show/Hide Panel", action: nil, keyEquivalent: "")

    init(notchPanelController: NotchPanelController) {
        self.notchPanelController = notchPanelController
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

    /// Keeps the checkmark in sync even when visibility changed elsewhere
    /// (e.g. the otter's own right-click "Hide Otter" item).
    func menuWillOpen(_ menu: NSMenu) {
        showHideItem.state = (notchPanelController?.isManuallyHidden ?? false) ? .off : .on
    }

    @objc private func toggleShowHidePanel() {
        notchPanelController?.toggleManualVisibility()
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
