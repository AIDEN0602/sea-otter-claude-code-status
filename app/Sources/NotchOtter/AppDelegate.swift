import AppKit

/// Wires together SessionStore, the notch panel, the dropdown, the status
/// bar item, and notifications. LSUIElement (set in Info.plist by
/// scripts/build_app.sh) keeps this out of the Dock; `.accessory` activation
/// policy is set here too as a belt-and-suspenders match.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanelController: NotchPanelController!
    private var companionPanelController: CompanionPanelController!
    private var dropdownController: DropdownPanelController!
    private var statusBarController: StatusBarController!

    private var storeObserver: NSObjectProtocol?
    private var tabsPollObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        notchPanelController = NotchPanelController()
        companionPanelController = CompanionPanelController()
        dropdownController = DropdownPanelController()
        statusBarController = StatusBarController(
            notchPanelController: notchPanelController,
            companionPanelController: companionPanelController
        )

        // Only the notch otter toggles the shared dropdown; companion otters
        // left-click straight to focusing their own session's Ghostty tab
        // (each OtterUnitView handles that itself), so there's no dropdown
        // wiring for the companion anymore.
        notchPanelController.onToggleDropdown = { [weak self] in
            guard let self else { return }
            self.toggleDropdown(anchor: self.notchPanelController.bottomAnchorPoint)
        }

        SessionStore.shared.start()
        NotificationManager.shared.start()
        // App-wide, always-on (not tied to companion visibility): SessionStore
        // needs fresh-ish Ghostty tab data at all times to decide which
        // done/idle sessions are exempt from the age-based prune (a session
        // matched to a still-open tab is never pruned by age).
        GhosttyTabsPoller.shared.start()

        storeObserver = NotificationCenter.default.addObserver(
            forName: .sessionStoreDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshUI()
        }

        tabsPollObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyTabsPollerDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshUI()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notchPanelController.reposition()
        }

        refreshUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionStore.shared.stop()
        GhosttyTabsPoller.shared.stop()
    }

    private func refreshUI() {
        let store = SessionStore.shared
        notchPanelController.update(store: store)
        companionPanelController.update(store: store)
        statusBarController.updateSummary(store.summaryText)
        dropdownController.refreshIfVisible(
            store: store,
            onRowClick: { [weak self] record in self?.focusSession(record) },
            onOutputsClick: { [weak self] record in self?.openOutputs(for: record) }
        )
    }

    /// Shared by both the notch otter and the companion otter -- each passes
    /// its own anchor point, but they toggle the same underlying dropdown.
    private func toggleDropdown(anchor: NSPoint) {
        let store = SessionStore.shared
        dropdownController.toggle(
            store: store,
            below: anchor,
            onRowClick: { [weak self] record in self?.focusSession(record) },
            onOutputsClick: { [weak self] record in self?.openOutputs(for: record) }
        )
    }

    private func focusSession(_ record: SessionRecord) {
        GhosttyFocus.focus(cwd: record.session.cwd)
    }

    /// Reveals a session's output files in Finder. Prefers revealing the
    /// actual files at their real locations (multiple directories are fine --
    /// Finder opens one window per unique parent) since `outputs` may still
    /// point at scattered paths mid-session, before the dedicated Otter
    /// Outputs staging folder exists (that folder is only created on the
    /// `done` transition, per SPEC.md section 5).
    private func openOutputs(for record: SessionRecord) {
        let outputs = record.session.outputs
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !outputs.isEmpty else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
}
