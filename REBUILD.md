# NotchOtter — Source Bundle (rebuild from this file)

This single Markdown file contains the full source of **NotchOtter**, a macOS
menu bar / notch pet that shows what every Claude Code session is doing.

## For the assistant reading this

Reconstruct the repository and build it:

1. For every block below, create the file at the exact path shown in its
   `FILE:` marker, writing the content **verbatim** (everything between the
   `⟦⟦⟦ FILE: ... ⟧⟧⟧` line and the matching `⟦⟦⟦ END ⟧⟧⟧` line).
2. Regenerate the otter sprite art from code (needs Python + Pillow):
   `pip3 install pillow` then `python3 spritegen/gen_sprites.py`.
   This writes the PNG sprite sheets under `assets/sprites/`.
3. Make sure the build script's sprite source directory exists. If
   `gen_sprites.py` wrote to a variant folder other than
   `assets/sprites/chatgpt`, either copy it there or edit `SPRITES_SRC`
   near the top of `scripts/build_app.sh` to point at the folder that was
   created.
4. Build and install: `bash scripts/build_app.sh`
   (needs macOS 13+ and Xcode Command Line Tools). It builds a release,
   generates an app icon, ad-hoc codesigns, and installs
   `/Applications/NotchOtter.app`.
5. `open "/Applications/NotchOtter.app"`. First launch may show an
   "unidentified developer" warning — right-click the app → Open → Open.
6. To wire up the Claude Code hooks that feed the otter:
   `bash engine/install.sh` (it backs up the user's settings first).

The parsing format is delimiter-based (not code fences) on purpose, so
triple-backticks inside the sources are preserved exactly. Do not
"reformat" the code — write it byte-for-byte.

---

⟦⟦⟦ FILE: app/Package.swift ⟧⟧⟧
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotchOtter",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "NotchOtter",
            path: "Sources/NotchOtter"
        )
    ]
)

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/main.swift ⟧⟧⟧
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/AppDelegate.swift ⟧⟧⟧
import AppKit

/// Wires together SessionStore, the notch panel, the dropdown, the status
/// bar item, and notifications. LSUIElement (set in Info.plist by
/// scripts/build_app.sh) keeps this out of the Dock; `.accessory` activation
/// policy is set here too as a belt-and-suspenders match.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchPanelController: NotchPanelController!
    private var companionPanelController: CompanionPanelController!
    private var desktopPetController: DesktopPetController!
    private var dropdownController: DropdownPanelController!
    private var statusBarController: StatusBarController?

    private var storeObserver: NSObjectProtocol?
    private var tabsPollObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        notchPanelController = NotchPanelController()
        companionPanelController = CompanionPanelController()
        desktopPetController = DesktopPetController()
        dropdownController = DropdownPanelController()
        // Pass `--no-menubar` to run without a menu bar item — handy if you
        // only want the otter in the notch and desktop pet and prefer to
        // keep the menu bar uncluttered. Default keeps the menu bar item.
        if !CommandLine.arguments.contains("--no-menubar") {
            statusBarController = StatusBarController(
                notchPanelController: notchPanelController,
                companionPanelController: companionPanelController,
                desktopPetController: desktopPetController
            )
        }

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
        desktopPetController.update(store: store)
        statusBarController?.updateSummary(store.summaryText)
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
        TerminalFocusDispatcher.focus(cwd: record.session.cwd)
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/Session.swift ⟧⟧⟧
import Foundation

/// State values as defined in SPEC.md section 1.
/// `stale` is never written by hooks; it is a display-only state computed
/// by the app when a session's process is no longer alive.
enum SessionState: String, Codable, CaseIterable {
    case idle
    case working
    case waitingPermission = "waiting_permission"
    case waitingInput = "waiting_input"
    case done
    case error
    case stale

    /// Priority order for choosing the state shown by the single notch otter
    /// across all live sessions: error > waiting_permission > waiting_input > working > done > idle.
    /// Lower number = higher priority.
    var priority: Int {
        switch self {
        case .error: return 0
        case .waitingPermission: return 1
        case .waitingInput: return 2
        case .working: return 3
        case .done: return 4
        case .idle: return 5
        case .stale: return 6
        }
    }
}

/// Mirrors the session state file schema from SPEC.md section 1.
/// Decoding tolerates unknown/extra fields (JSONDecoder ignores them by default)
/// and missing optional-ish fields via explicit defaults in the custom initializer.
struct Session: Codable {
    let sessionID: String
    let state: SessionState
    let cwd: String
    /// The `cwd` from the FIRST event that created the state file, frozen
    /// forever after (per SPEC.md section 1) -- unlike `cwd`, which keeps
    /// updating as Claude `cd`s around. This is what actually matches a
    /// Ghostty tab's shell launch directory. Optional/tolerant since it's a
    /// newer field: falls back to `cwd` via `groupingCwd` wherever it's used.
    let launchCwd: String?
    let project: String
    let pid: Int32
    /// The claude process's controlling tty (e.g. "ttys014"), optional --
    /// absent on older session files or when the hook couldn't determine it.
    let tty: String?
    let updatedAt: Date
    let lastEvent: String
    let errorCount: Int
    let outputs: [String]
    /// Short excerpt of the most recent assistant reply (or the pending
    /// permission prompt's message), written by the hook for the desktop
    /// pet's hover bubble. Optional -- absent on session files written
    /// before this field existed.
    let lastSummary: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
        case cwd
        case launchCwd = "launch_cwd"
        case project
        case pid
        case tty
        case updatedAt = "updated_at"
        case lastEvent = "last_event"
        case errorCount = "error_count"
        case outputs
        case lastSummary = "last_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        state = try container.decode(SessionState.self, forKey: .state)
        cwd = try container.decode(String.self, forKey: .cwd)
        project = (try? container.decode(String.self, forKey: .project)) ?? (cwd as NSString).lastPathComponent
        pid = try container.decode(Int32.self, forKey: .pid)

        let updatedAtRaw = try container.decode(String.self, forKey: .updatedAt)
        updatedAt = Session.parseISO8601(updatedAtRaw) ?? Date()

        lastEvent = (try? container.decode(String.self, forKey: .lastEvent)) ?? ""
        errorCount = (try? container.decode(Int.self, forKey: .errorCount)) ?? 0
        outputs = (try? container.decode([String].self, forKey: .outputs)) ?? []

        let decodedLaunchCwd = (try? container.decode(String.self, forKey: .launchCwd))
        launchCwd = (decodedLaunchCwd?.isEmpty ?? true) ? nil : decodedLaunchCwd
        let decodedTty = (try? container.decode(String.self, forKey: .tty))
        tty = (decodedTty?.isEmpty ?? true) ? nil : decodedTty
        let decodedSummary = (try? container.decode(String.self, forKey: .lastSummary))
        lastSummary = (decodedSummary?.isEmpty ?? true) ? nil : decodedSummary
    }

    /// The cwd to use for Ghostty tab matching: `launch_cwd` when present,
    /// else `cwd` (per the matching algorithm in CompanionPanel.swift).
    var groupingCwd: String {
        launchCwd ?? cwd
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

/// Runtime wrapper around a decoded `Session`, tracking app-side staleness
/// bookkeeping that is never persisted to disk (per SPEC.md: "stale" is
/// app-computed only).
final class SessionRecord {
    var session: Session
    let fileURL: URL
    var isStale: Bool = false
    var staleSince: Date?

    /// When this record was first discovered in memory (not persisted to
    /// disk). Since `SessionStore` reuses the same `SessionRecord` instance
    /// across reloads as long as the session file keeps existing, this gives
    /// a stable sort key for UI ordering (e.g. the companion otter row) that
    /// never shuffles as session state changes.
    let firstSeenAt = Date()

    init(session: Session, fileURL: URL) {
        self.session = session
        self.fileURL = fileURL
    }

    /// The state used for all display/notification purposes: `stale` overrides
    /// whatever the file says once the app has detected a dead PID.
    var displayState: SessionState {
        isStale ? .stale : session.state
    }

    var ageSeconds: TimeInterval {
        Date().timeIntervalSince(session.updatedAt)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/SessionStore.swift ⟧⟧⟧
import Foundation

extension Notification.Name {
    /// Posted on the main thread whenever the in-memory session set changes
    /// (file added/removed/modified, staleness detected, or a stale entry pruned).
    static let sessionStoreDidUpdate = Notification.Name("NotchOtter.sessionStoreDidUpdate")
}

/// Owns the on-disk session state files described in SPEC.md section 1.
/// Watches the sessions directory for changes and polls PID liveness on a
/// timer, marking dead-but-still-present sessions as `stale` and removing
/// their files after a grace period.
final class SessionStore {
    static let shared = SessionStore()

    /// How long a session must be observed stale (dead PID, file still present)
    /// before its file is deleted. Per SPEC.md section 1.
    private static let staleGracePeriod: TimeInterval = 60

    /// Sessions in `done`/`idle` older than this are hidden from the UI
    /// (but not deleted -- deletion is only for `stale`/`SessionEnd`).
    private static let displayPruneAge: TimeInterval = 30 * 60

    private static let livenessPollInterval: TimeInterval = 5

    /// Debounce window for coalescing bursts of filesystem events before reloading.
    private static let debounceInterval: TimeInterval = 0.2

    let sessionsDirectory: URL

    private(set) var records: [String: SessionRecord] = [:]

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var dirFileDescriptor: CInt = -1
    private var debounceWorkItem: DispatchWorkItem?
    private var livenessTimer: Timer?

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/notch-otter/sessions", isDirectory: true)
        sessionsDirectory = base
        ensureDirectoryExists()
    }

    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Lifecycle

    func start() {
        reloadFromDisk()
        startWatchingDirectory()
        startLivenessTimer()
    }

    func stop() {
        dirWatcher?.cancel()
        dirWatcher = nil
        if dirFileDescriptor >= 0 {
            close(dirFileDescriptor)
            dirFileDescriptor = -1
        }
        livenessTimer?.invalidate()
        livenessTimer = nil
    }

    // MARK: - Directory watching

    private func startWatchingDirectory() {
        ensureDirectoryExists()
        let fd = open(sessionsDirectory.path, O_EVTONLY)
        guard fd >= 0 else {
            return
        }
        dirFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleDebouncedReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.dirFileDescriptor >= 0 {
                close(self.dirFileDescriptor)
                self.dirFileDescriptor = -1
            }
        }
        source.resume()
        dirWatcher = source
    }

    private func scheduleDebouncedReload() {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.reloadFromDisk()
        }
        debounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: workItem)
    }

    // MARK: - Liveness polling

    private func startLivenessTimer() {
        let timer = Timer(timeInterval: Self.livenessPollInterval, repeats: true) { [weak self] _ in
            self?.pollLivenessAndPrune()
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    private func pollLivenessAndPrune() {
        // Re-sync with disk first in case a filesystem event was missed.
        reloadFromDisk(postNotification: false)

        var changed = false
        var toDelete: [String] = []

        for (id, record) in records {
            if record.isStale {
                if let staleSince = record.staleSince,
                   Date().timeIntervalSince(staleSince) >= Self.staleGracePeriod {
                    toDelete.append(id)
                }
                continue
            }

            if !isProcessAlive(pid: record.session.pid) {
                record.isStale = true
                record.staleSince = Date()
                changed = true
            }
        }

        for id in toDelete {
            if let record = records.removeValue(forKey: id) {
                try? FileManager.default.removeItem(at: record.fileURL)
                changed = true
            }
        }

        if changed {
            postUpdate()
        }
    }

    /// Returns true if the process is alive (signal 0 delivery succeeds or fails
    /// only due to permissions, which still implies existence).
    private func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        // EPERM means the process exists but we lack permission to signal it.
        return errno == EPERM
    }

    // MARK: - Disk reload

    private func reloadFromDisk(postNotification: Bool = true) {
        ensureDirectoryExists()

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            files = []
        }

        var seenIDs = Set<String>()
        var changed = false

        for fileURL in files {
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                continue
            }
            guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
                // Malformed file: skip it silently, per SPEC tolerance rule.
                continue
            }
            seenIDs.insert(session.sessionID)

            if let existing = records[session.sessionID] {
                if existing.session.state != session.state || existing.session.updatedAt != session.updatedAt {
                    existing.session = session
                    // A fresh write means the process is definitely alive again.
                    existing.isStale = false
                    existing.staleSince = nil
                    changed = true
                } else {
                    existing.session = session
                }
            } else {
                records[session.sessionID] = SessionRecord(session: session, fileURL: fileURL)
                changed = true
            }
        }

        // Files that disappeared (SessionEnd deleted them, or they were pruned
        // externally) should be dropped from memory immediately.
        let missingIDs = Set(records.keys).subtracting(seenIDs)
        for id in missingIDs {
            records.removeValue(forKey: id)
            changed = true
        }

        if changed && postNotification {
            postUpdate()
        }
    }

    private func postUpdate() {
        NotificationCenter.default.post(name: .sessionStoreDidUpdate, object: self)
    }

    // MARK: - Queries

    /// All records currently tracked, including stale ones, sorted by project name.
    var allRecords: [SessionRecord] {
        records.values.sorted { $0.session.project.localizedCaseInsensitiveCompare($1.session.project) == .orderedAscending }
    }

    /// Records to actually show in the UI: hides `done`/`idle` sessions older
    /// than the display-prune age, per SPEC.md section 4 -- EXCEPT a session
    /// whose `pid` is still alive is NEVER pruned by age, full stop. The
    /// session objectively still exists (its process is running) regardless
    /// of whether Ghostty tab-matching can find/confirm it, so visibility
    /// deliberately does NOT depend on tab-matching at all -- only order and
    /// labels do (in CompanionPanelController). This also means bad/stale
    /// matching data (e.g. a `launch_cwd` backfilled from before that field
    /// existed, or Automation permission not granted) can never cause a
    /// still-alive session to vanish; at worst it's ordered/labeled less
    /// precisely, never hidden. `isProcessAlive` already treats pid <= 0 as
    /// dead/absent, so those sessions remain normally eligible for the
    /// age-based prune below.
    var visibleRecords: [SessionRecord] {
        allRecords.filter { record in
            let state = record.displayState
            if state == .done || state == .idle {
                if isProcessAlive(pid: record.session.pid) {
                    return true
                }
                return record.ageSeconds < Self.displayPruneAge
            }
            return true
        }
    }

    /// The single highest-priority state across all visible sessions, used to
    /// pick which otter animation to show. Nil when there are no sessions.
    var highestPriorityState: SessionState? {
        visibleRecords.map(\.displayState).min { $0.priority < $1.priority }
    }

    /// Count of sessions that are not `done` (used for the summary badge).
    var activeCount: Int {
        visibleRecords.filter { $0.displayState != .done }.count
    }

    var waitingCount: Int {
        visibleRecords.filter { $0.displayState == .waitingPermission || $0.displayState == .waitingInput }.count
    }

    /// Compact badge text like "3 working · 1 waiting", counting only
    /// non-done sessions grouped by state (waiting_permission and
    /// waiting_input are collapsed into a single "waiting" bucket).
    /// Empty string when there is nothing to report.
    var summaryText: String {
        let nonDone = visibleRecords.filter { $0.displayState != .done }
        guard !nonDone.isEmpty else { return "" }

        var counts: [String: Int] = [:]
        for record in nonDone {
            let label: String
            switch record.displayState {
            case .error: label = "error"
            case .waitingPermission, .waitingInput: label = "waiting"
            case .working: label = "working"
            case .idle: label = "idle"
            case .stale: label = "stale"
            case .done: continue
            }
            counts[label, default: 0] += 1
        }

        let priorityOrder = ["error", "waiting", "working", "idle", "stale"]
        return priorityOrder
            .compactMap { label -> String? in
                guard let count = counts[label] else { return nil }
                return "\(count) \(label)"
            }
            .joined(separator: " · ")
    }

    func record(forSessionID id: String) -> SessionRecord? {
        records[id]
    }

    /// Count of visible sessions currently in `state`.
    func count(of state: SessionState) -> Int {
        visibleRecords.filter { $0.displayState == state }.count
    }

    /// Grouped counts for the compact notch badge (waiting_permission and
    /// waiting_input collapsed into one "waiting" bucket, matching
    /// `summaryText`'s grouping).
    var compactCounts: (error: Int, waiting: Int, working: Int) {
        (count(of: .error), count(of: .waitingPermission) + count(of: .waitingInput), count(of: .working))
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/SessionRowView.swift ⟧⟧⟧
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/NotchGeometry.swift ⟧⟧⟧
import AppKit

/// Computes where to place the notch panel so it reads as a true horizontal
/// extension of the physical notch, not a floating overlay: flush against
/// one of the notch's edges (zero gap) and spanning the exact same height as
/// the menu bar / safe-area strip.
enum NotchGeometry {
    /// Real-world measurements of the notch on a given screen, derived from
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` when the
    /// system exposes them (macOS 12+, notched hardware only).
    struct NotchMetrics {
        /// X position (screen coordinates) immediately left of the notch --
        /// a panel to the left of the notch must have its RIGHT edge here.
        let leftEdgeX: CGFloat
        /// X position (screen coordinates) immediately right of the notch --
        /// a panel to the right of the notch must have its LEFT edge here.
        let rightEdgeX: CGFloat
        /// Height of the menu bar / safe-area strip the notch lives in.
        /// This is `safeAreaInsets.top`; never hardcode a menu bar constant.
        let stripHeight: CGFloat
        /// Physical width of the notch itself, for reference/debugging.
        let notchWidth: CGFloat
    }

    /// Returns notch metrics for `screen`, or nil on hardware with no notch
    /// (safeAreaInsets.top == 0).
    static func metrics(for screen: NSScreen) -> NotchMetrics? {
        let stripHeight = screen.safeAreaInsets.top
        guard stripHeight > 0 else { return nil }

        if let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            // The two aux areas are the strip to the left and right of the
            // notch; the gap between them is the notch itself. These are the
            // exact, authoritative edges -- equivalent to the
            // "screenWidth/2 +/- notchWidth/2" formula when the notch is
            // perfectly centered, but reading the aux area rects directly
            // avoids the rounding drift that formula introduces when the two
            // aux areas aren't perfectly symmetric (observed ~0.5pt drift on
            // real hardware).
            let notchWidth = rightArea.minX - leftArea.maxX
            return NotchMetrics(
                leftEdgeX: leftArea.maxX,
                rightEdgeX: rightArea.minX,
                stripHeight: stripHeight,
                notchWidth: notchWidth
            )
        }

        // Aux areas unavailable (shouldn't happen on real notched hardware,
        // but guard for older SDKs / misreporting screens): fall back to the
        // screenWidth/2 +/- notchWidth/2 formula with an estimated notch
        // width scaled from the strip height (current notches run roughly 6x
        // their height in width).
        let estimatedNotchWidth = stripHeight * 6
        let centerX = screen.frame.midX
        return NotchMetrics(
            leftEdgeX: centerX - estimatedNotchWidth / 2,
            rightEdgeX: centerX + estimatedNotchWidth / 2,
            stripHeight: stripHeight,
            notchWidth: estimatedNotchWidth
        )
    }

    /// How far the panel slides UNDER the notch's left edge. The current
    /// sprite sheet bakes transparent margins into each square cell, so a
    /// panel that stops exactly at the notch edge leaves the otter looking
    /// detached from it; overhanging by this much hides the margin beneath
    /// the (black) notch and puts the otter's body visually flush against
    /// the notch. Invisible on the notch itself; applied on notched screens
    /// only.
    private static let notchOverhang: CGFloat = 6

    /// Frame (screen coordinates) for a panel of `width` positioned
    /// immediately LEFT of the notch (panel's right edge tucked slightly
    /// under the notch's left edge so the otter reads as touching it),
    /// spanning the exact strip height. Falls back to a
    /// standard-menu-bar-height placement on screens with no notch.
    static func panelFrameLeftOfNotch(on screen: NSScreen, width: CGFloat) -> NSRect {
        let screenFrame = screen.frame

        if let notch = metrics(for: screen) {
            let y = screenFrame.maxY - notch.stripHeight
            let x = notch.leftEdgeX - width + notchOverhang
            return NSRect(x: x, y: y, width: width, height: notch.stripHeight)
        }

        // No notch: standard 24pt menu bar strip; park near top-center since
        // "left of the notch" is meaningless without one.
        let fallbackHeight: CGFloat = 24
        let y = screenFrame.maxY - fallbackHeight
        let x = screenFrame.midX - width
        return NSRect(x: x, y: y, width: width, height: fallbackHeight)
    }

    /// The screen the notch panel should live on: the notched (built-in)
    /// display when one is active, otherwise the main screen (clamshell mode
    /// falls back to the menu bar strip of the external monitor).
    static var panelScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
    }

    /// True when the main screen reports a physical notch.
    static var hasNotch: Bool {
        guard let screen = NSScreen.main else { return false }
        return screen.safeAreaInsets.top > 0
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/NotchPanel.swift ⟧⟧⟧
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

/// Owns the always-visible notch-adjacent panel: a compact colored-count
/// badge plus an animated otter sprite that hugs the notch. Non-activating,
/// borderless, flush against the notch's LEFT edge and spanning the exact
/// safe-area strip height, so it reads as a true horizontal extension of the
/// notch rather than a floating overlay. Layout is [badge][otter] left to
/// right, so the otter itself is the element touching the notch.
final class NotchPanelController {
    /// Max 2pt padding on either side -- keeps the panel exactly
    /// content-sized with no leftover empty space.
    private static let horizontalPadding: CGFloat = 2
    private static let spriteBadgeGap: CGFloat = 2
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
        // bottom-right corner (touches the notch, since the panel now sits
        // to its LEFT); round only the outer bottom-left corner so the panel
        // reads as a small tab hanging off the notch, not a floating box.
        contentView.layer?.maskedCorners = [.layerMinXMinYCorner]

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

        // Otter only — session counts are visible elsewhere (per-tab pets),
        // so the notch tab stays clean with no text badge.
        badgeLabel.attributedStringValue = NSAttributedString(string: "")
        badgeLabel.isHidden = true

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

    /// Lays out [badge][otter] left-to-right so the otter is the element
    /// touching the notch, and sizes the panel to exactly the content width
    /// -- no fixed minimums, no spare pixels.
    private func layoutContent() {
        let screen = NotchGeometry.panelScreen
        let stripHeight = screen.flatMap { NotchGeometry.metrics(for: $0)?.stripHeight } ?? Self.fallbackStripHeight

        let spriteSize = stripHeight - 4
        let spriteY = (stripHeight - spriteSize) / 2

        var width: CGFloat

        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            let badgeOrigin = CGPoint(
                x: Self.horizontalPadding,
                y: (stripHeight - badgeLabel.frame.height) / 2
            )
            badgeLabel.setFrameOrigin(badgeOrigin)
            let spriteX = badgeOrigin.x + badgeLabel.frame.width + Self.spriteBadgeGap
            spriteView.setFrameOrigin(NSPoint(x: spriteX, y: spriteY))
            width = spriteX + spriteSize + Self.horizontalPadding
        } else {
            let spriteX = Self.horizontalPadding
            spriteView.setFrameOrigin(NSPoint(x: spriteX, y: spriteY))
            width = spriteX + spriteSize + Self.horizontalPadding
        }

        spriteView.setFrameSize(NSSize(width: spriteSize, height: spriteSize))

        let newSize = NSSize(width: width, height: stripHeight)
        panel.setContentSize(newSize)
        contentView.frame = NSRect(origin: .zero, size: newSize)
    }

    /// Re-pins the panel flush against the notch's LEFT edge (panel's right
    /// edge meets the notch's left edge), spanning the full safe-area strip
    /// height. Call after content size changes and on screen configuration
    /// changes.
    func reposition() {
        guard let screen = NotchGeometry.panelScreen else { return }
        let width = panel.frame.width
        let frame = NotchGeometry.panelFrameLeftOfNotch(on: screen, width: width)
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/CompanionPanel.swift ⟧⟧⟧
import AppKit
import CoreGraphics

/// Content view for the companion panel: fully transparent (no background at
/// all -- just sprites floating), hosts the shared right-click context menu.
/// Left-click is handled per-otter (see OtterUnitView), not here -- clicking
/// empty space between otters does nothing.
final class CompanionContentView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true // layer-backed for smooth compositing; no background color set, so it stays transparent.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// One session's otter + its label, laid out vertically: otter on top, a
/// small semi-transparent name chip directly underneath. Left-clicking
/// anywhere on the unit focuses the matched Ghostty tab (or falls back to
/// cwd-matching for unmatched sessions).
final class OtterUnitView: NSView {
    static let otterSize: CGFloat = 96
    static let labelHeight: CGFloat = 14
    static let gap: CGFloat = 2
    static let totalHeight: CGFloat = otterSize + gap + labelHeight

    /// Label chip width for a session matched to a live Ghostty tab (shows
    /// the tab title, which can run longer than a folder name).
    static let matchedLabelWidth: CGFloat = 110
    /// Label chip width for an unmatched session (shows the project name,
    /// same as before this feature).
    static let unmatchedLabelWidth: CGFloat = 80

    /// Where a left-click on this otter should focus.
    enum FocusTarget: Equatable {
        /// Matched to a specific Ghostty tab -- focus by exact identity,
        /// since cwd-matching alone is ambiguous when multiple tabs share a
        /// working directory. `cwd` rides along too: if the user's selected
        /// terminal (see TerminalPreference) isn't Ghostty, exact-tab focus
        /// doesn't apply and TerminalFocusDispatcher falls back to it.
        case tab(windowIndex: Int, tabIndex: Int, cwd: String)
        /// Unmatched (headless run, different terminal, or tab data
        /// unavailable) -- fall back to the existing cwd-based focus.
        case cwd(String)
    }

    let sessionID: String
    private(set) var focusTarget: FocusTarget
    /// This unit's own width (varies: matched otters get a wider label chip
    /// than unmatched ones), used by the row layout to step `cursorX`.
    private(set) var totalWidth: CGFloat

    /// Set by the controller so dragging any otter moves the whole row
    /// (mirrors the desktop pet's drag behavior); a sub-4pt press-and-release
    /// still focuses the session's tab.
    weak var dragTarget: NSPanel?
    var onDragStart: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private static let dragThreshold: CGFloat = 4
    private var pressOrigin: NSPoint?
    private var panelOriginAtPress: NSPoint?
    private var didDrag = false

    private let spriteView: OtterSpriteView
    private let labelBackground: NSView
    private let labelField: NSTextField

    init(sessionID: String, focusTarget: FocusTarget, labelText: String, labelWidth: CGFloat) {
        self.sessionID = sessionID
        self.focusTarget = focusTarget
        let unitWidth = max(Self.otterSize, labelWidth)
        self.totalWidth = unitWidth

        spriteView = OtterSpriteView(frame: NSRect(
            x: (unitWidth - Self.otterSize) / 2,
            y: Self.labelHeight + Self.gap,
            width: Self.otterSize,
            height: Self.otterSize
        ))

        let labelX = (unitWidth - labelWidth) / 2
        labelBackground = NSView(frame: NSRect(x: labelX, y: 0, width: labelWidth, height: Self.labelHeight))

        labelField = NSTextField(labelWithString: labelText)
        labelField.font = .boldSystemFont(ofSize: 9)
        labelField.textColor = .white
        labelField.alignment = .center
        labelField.backgroundColor = .clear
        labelField.isBezeled = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = labelBackground.bounds.insetBy(dx: 2, dy: 0)

        super.init(frame: NSRect(x: 0, y: 0, width: unitWidth, height: Self.totalHeight))
        wantsLayer = true

        labelBackground.wantsLayer = true
        labelBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        labelBackground.layer?.cornerRadius = 4
        labelBackground.layer?.cornerCurve = .continuous

        addSubview(spriteView)
        addSubview(labelBackground)
        labelBackground.addSubview(labelField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setState(_ state: SessionState) {
        spriteView.setState(state)
    }

    func updateFocusTarget(_ target: FocusTarget) {
        focusTarget = target
    }

    /// Updates label text/width in place (tab title changed, or a session
    /// flipped between matched/unmatched), resizing this unit's own frame
    /// and repositioning subviews -- but keeping the SAME OtterSpriteView
    /// instance alive so its walk-cycle animation doesn't reset.
    func updateLabel(text: String, width: CGFloat) {
        let unitWidth = max(Self.otterSize, width)
        guard unitWidth != totalWidth || labelField.stringValue != text else { return }
        totalWidth = unitWidth

        setFrameSize(NSSize(width: unitWidth, height: Self.totalHeight))
        spriteView.setFrameOrigin(NSPoint(x: (unitWidth - Self.otterSize) / 2, y: Self.labelHeight + Self.gap))
        labelBackground.frame = NSRect(x: (unitWidth - width) / 2, y: 0, width: width, height: Self.labelHeight)
        labelField.frame = labelBackground.bounds.insetBy(dx: 2, dy: 0)
        labelField.stringValue = text
    }

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        panelOriginAtPress = dragTarget?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin, let panelOriginAtPress, let panel = dragTarget else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - pressOrigin.x
        let dy = now.y - pressOrigin.y
        if !didDrag {
            guard abs(dx) >= Self.dragThreshold || abs(dy) >= Self.dragThreshold else { return }
            didDrag = true
            onDragStart?()
        }
        panel.setFrameOrigin(NSPoint(x: panelOriginAtPress.x + dx, y: panelOriginAtPress.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressOrigin = nil
            panelOriginAtPress = nil
        }
        if didDrag {
            onDragEnd?()
            return
        }
        switch focusTarget {
        case let .tab(windowIndex, tabIndex, cwd):
            TerminalFocusDispatcher.focusTab(windowIndex: windowIndex, tabIndex: tabIndex, cwd: cwd)
        case let .cwd(cwd):
            TerminalFocusDispatcher.focus(cwd: cwd)
        }
    }

    /// Right-click anywhere on a unit shows the row's shared context menu.
    /// NSView's default `menu(for:)` only returns `self.menu` (nil here), so
    /// without this override a right-click landing directly on an otter
    /// would show nothing even though the container has a menu set.
    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }

    /// Strips leading spinner/glyph characters and whitespace from a live
    /// Ghostty tab title (e.g. "✳ my-project" -> "my-project"), keeping
    /// any real text intact -- including CJK/Hangul, since Swift's
    /// `Character.isLetter` already recognizes Hangul syllables as letters,
    /// so no separate Unicode-range logic is needed.
    static func stripLeadingGlyphs(_ title: String) -> String {
        var chars = Substring(title)
        while let first = chars.first, !(first.isLetter || first.isNumber) {
            chars.removeFirst()
        }
        // Trailing whitespace is invisible in a centered label, but trim it
        // anyway for cleanliness (real Ghostty titles can have a trailing
        // space after the spinner glyph, e.g. "✳ Piauel ").
        return chars.trimmingCharacters(in: .whitespaces)
    }

    /// Char-count truncation for unmatched (project-name) labels -- the
    /// original behavior, kept as-is for that case. Matched tab-title labels
    /// use pixel-accurate `.byTruncatingTail` on a fixed-width field instead,
    /// since mixed English/Korean titles don't truncate predictably by raw
    /// character count (Hangul glyphs are roughly twice as wide as Latin
    /// ones at the same point size).
    static func truncateProjectName(_ name: String) -> String {
        guard name.count > 12 else { return name }
        return String(name.prefix(11)) + "\u{2026}"
    }
}

/// Small "+N" pill shown at the left end of the row when there are more
/// sessions than fit in the 5-otter cap.
final class OverflowChipView: NSView {
    static let width: CGFloat = 28
    static let height: CGFloat = 18

    let count: Int

    init(count: Int) {
        self.count = count
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: "+\(count)")
        label.font = .boldSystemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}

/// A row of "companion" otters -- one per live session, each animating its
/// own session's state -- perched on the frontmost Ghostty window. Visible
/// only while Ghostty is frontmost and at least one session exists. Never
/// steals focus (non-activating panel) and never covers the terminal's own
/// content (perched above the window's top edge, clamped inside it if
/// there's no room above).
///
/// Row order/labels come from `GhosttyTabMatcher`, fed by `GhosttyTabsPoller`
/// (live Ghostty tab list, polled every 2s). When tab data is unavailable
/// (Automation permission not granted, Ghostty not running, etc.) this
/// degrades gracefully to the pre-tab-matching behavior: firstSeenAt order,
/// project-name labels, cwd-based focus.
final class CompanionPanelController {
    private static let rightMargin: CGFloat = 24
    private static let rowSpacing: CGFloat = 8
    private static let maxOtters = 10
    /// How far below the window's top edge the row sits when it has to nest
    /// INSIDE the window (maximized / touching the menu bar): clears
    /// Ghostty's title-bar-plus-tab-strip so the otters never cover the tabs
    /// -- the panel swallows clicks, so covering the tab bar made tabs
    /// unclickable. Tuned by eye: 44 still grazed the strip's hit area on a
    /// maximized window, 76 sat too deep into the terminal content.
    private static let nestedTabBarOffset: CGFloat = 50
    private static let hiddenPrefKey = "NotchOtter.companionHidden"
    private static let ghosttyOwnerName = "Ghostty"
    private static let pollInterval: TimeInterval = 1.0

    let panel: NSPanel
    private let contentView: CompanionContentView

    /// Currently-shown per-session unit views, keyed by session_id, reused
    /// across updates (rather than destroyed/recreated) so an otter whose
    /// state hasn't changed doesn't have its walk-cycle animation reset.
    private var unitViews: [String: OtterUnitView] = [:]
    private var overflowChipView: OverflowChipView?

    /// True when the user hid the companion (status bar menu or its own
    /// right-click "Hide Companion"); persisted so it survives relaunch.
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: CompanionPanelController.hiddenPrefKey)

    private static let offsetXPrefKey = "NotchOtter.companionOffsetX"
    private static let offsetYPrefKey = "NotchOtter.companionOffsetY"

    /// Where the user parked the row, as an offset from the frontmost
    /// Ghostty window's bottom-left origin -- relative, so the row keeps
    /// following the window around. nil = default perch position. Persisted
    /// across relaunches; cleared via the right-click "Reset Position" item.
    private var customOffset: NSPoint? = CompanionPanelController.loadOffset()
    /// Suspends the follow timer's repositioning while the user is
    /// mid-drag, so it doesn't yank the row back every second.
    private var isDraggingRow = false

    private var isGhosttyFrontmost = false
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OtterUnitView.otterSize, height: OtterUnitView.totalHeight),
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

        contentView = CompanionContentView(frame: NSRect(x: 0, y: 0, width: OtterUnitView.otterSize, height: OtterUnitView.totalHeight))
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

        // Tab data itself (GhosttyTabsPoller.shared) is a permanent app-wide
        // singleton started once in AppDelegate, not owned or lifecycle-tied
        // to this controller -- SessionStore.visibleRecords needs fresh-ish
        // tab-match data at all times (even while the companion is hidden)
        // to decide which done/idle sessions are exempt from the age prune.
        // AppDelegate observes `.ghosttyTabsPollerDidUpdate` and calls
        // `update(store:)` again from there, same as `.sessionStoreDidUpdate`.
    }

    deinit {
        pollTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Rebuilds the otter row for the current session set and re-evaluates
    /// visibility. Reuses `SessionStore.visibleRecords` directly -- no
    /// duplicated state computation.
    func update(store: SessionStore) {
        let allVisible = store.visibleRecords
        let fullOrder = GhosttyTabMatcher.buildRowOrder(sessions: allVisible, tabs: GhosttyTabsPoller.shared.tabs)

        // Cap at 5, prioritizing matched (tab-order) rows over unmatched
        // ones when there's overflow, since matched rows correspond to
        // actually-open, user-recognizable Ghostty tabs.
        let overflowCount = max(0, fullOrder.count - Self.maxOtters)
        let displayed = Array(fullOrder.prefix(Self.maxOtters))

        rebuildRow(displayed: displayed, overflowCount: overflowCount)
        refreshVisibility(sessionsPresent: !allVisible.isEmpty)
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

    // MARK: - Row layout

    /// Diffs `displayed` against the currently-shown unit views: removes
    /// views for sessions no longer displayed, creates views for newly
    /// displayed sessions, and updates state/label/focus-target/position for
    /// all of them (in place where possible, to avoid resetting an
    /// unaffected otter's animation). Left-to-right in `displayed`'s given
    /// order (matched rows in Ghostty tab order, then unmatched rows in
    /// firstSeenAt order); the overflow "+N" chip (if any) sits at the row's
    /// left end.
    private func rebuildRow(displayed: [MatchedRow], overflowCount: Int) {
        let displayedIDs = Set(displayed.map { $0.record.session.sessionID })
        for (id, view) in unitViews where !displayedIDs.contains(id) {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }

        let sharedMenu = contentView.menu

        if overflowCount > 0 {
            if overflowChipView?.count != overflowCount {
                overflowChipView?.removeFromSuperview()
                let chip = OverflowChipView(count: overflowCount)
                chip.menu = sharedMenu
                contentView.addSubview(chip)
                overflowChipView = chip
            }
        } else if let existing = overflowChipView {
            existing.removeFromSuperview()
            overflowChipView = nil
        }

        var cursorX: CGFloat = 0
        if overflowCount > 0 {
            overflowChipView?.setFrameOrigin(NSPoint(x: cursorX, y: (OtterUnitView.totalHeight - OverflowChipView.height) / 2))
            cursorX += OverflowChipView.width + Self.rowSpacing
        }

        for row in displayed {
            let record = row.record
            let id = record.session.sessionID

            let focusTarget: OtterUnitView.FocusTarget
            let labelText: String
            let labelWidth: CGFloat
            if let tab = row.matchedTab {
                focusTarget = .tab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, cwd: record.session.cwd)
                labelText = OtterUnitView.stripLeadingGlyphs(tab.title)
                labelWidth = OtterUnitView.matchedLabelWidth
            } else {
                focusTarget = .cwd(record.session.cwd)
                labelText = OtterUnitView.truncateProjectName(record.session.project)
                labelWidth = OtterUnitView.unmatchedLabelWidth
            }

            let unit: OtterUnitView
            if let existing = unitViews[id] {
                unit = existing
                unit.updateFocusTarget(focusTarget)
                unit.updateLabel(text: labelText, width: labelWidth)
            } else {
                unit = OtterUnitView(sessionID: id, focusTarget: focusTarget, labelText: labelText, labelWidth: labelWidth)
                unit.menu = sharedMenu
                unit.dragTarget = panel
                unit.onDragStart = { [weak self] in self?.isDraggingRow = true }
                unit.onDragEnd = { [weak self] in self?.finishRowDrag() }
                contentView.addSubview(unit)
                unitViews[id] = unit
            }
            unit.setState(record.displayState)
            unit.setFrameOrigin(NSPoint(x: cursorX, y: 0))
            cursorX += unit.totalWidth + Self.rowSpacing
        }

        let rowWidth = max(OtterUnitView.otterSize, cursorX - Self.rowSpacing)
        let size = NSSize(width: rowWidth, height: OtterUnitView.totalHeight)
        panel.setContentSize(size)
        contentView.frame = NSRect(origin: .zero, size: size)
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

    /// Starts the reposition-follow timer (window-move/resize tracking
    /// while the companion is visible). `GhosttyTabsPoller.shared` is a
    /// separate, permanently-running app-wide singleton (started once in
    /// AppDelegate) -- not tied to this controller's own visibility, since
    /// SessionStore needs fresh tab-match data even while the companion
    /// itself is hidden.
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

    /// Repositions the row onto the frontmost Ghostty window's top-right
    /// area, or hides the companion if no Ghostty window bounds can be found
    /// (e.g. all windows minimized). The perch anchor is unchanged from the
    /// single-otter version: each otter's own bottom edge sits ON the
    /// window's top edge; the label chips hang below that line (slightly
    /// over the window's own top edge), and the clamp-inside-the-window
    /// fallback now nests the whole otter+label unit rather than just the
    /// otter.
    private func repositionToGhosttyWindow() {
        guard !isDraggingRow else { return }
        guard let windowFrame = Self.frontmostGhosttyWindowFrame() else {
            panel.orderOut(nil)
            return
        }

        // User-parked position: follow the window at the dragged offset,
        // clamped to the screen -- anywhere is allowed, even over the
        // terminal content; that's the user's call.
        if let customOffset {
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main else {
                return
            }
            let size = panel.frame.size
            var origin = NSPoint(x: windowFrame.origin.x + customOffset.x, y: windowFrame.origin.y + customOffset.y)
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
            if !isManuallyHidden {
                panel.orderFrontRegardless()
            }
            return
        }
        // Clamp against whichever screen actually contains the Ghostty
        // window, not just NSScreen.main -- on multi-monitor setups the key
        // application's screen and the screen the terminal window lives on
        // can differ.
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) ?? NSScreen.main else {
            return
        }

        let rowWidth = panel.frame.width
        let unitHeight = OtterUnitView.totalHeight
        let perchLocalY = OtterUnitView.labelHeight + OtterUnitView.gap // local y of the otter's bottom edge

        var x = windowFrame.maxX - rowWidth - Self.rightMargin
        var y = windowFrame.maxY - perchLocalY

        // Clamp: if perching above the window would push the otters' tops
        // above the screen's visible area (window touches the menu bar /
        // near-fullscreen), nest the whole unit INSIDE the window -- but
        // BELOW the title bar + tab strip, so the tabs stay clickable.
        if y + unitHeight > screen.frame.maxY {
            y = windowFrame.maxY - unitHeight - Self.nestedTabBarOffset
        }

        // Keep the row horizontally within the window's own bounds.
        x = min(x, windowFrame.maxX - rowWidth)
        x = max(x, windowFrame.minX)

        panel.setFrame(NSRect(x: x, y: y, width: rowWidth, height: unitHeight), display: true)
        if !isManuallyHidden {
            panel.orderFrontRegardless()
        }
    }

    /// Below this size, a Ghostty window is treated as a quick-terminal-style
    /// overlay/sliver rather than a real terminal window worth perching on.
    private static let minRealWindowWidth: CGFloat = 400
    private static let minRealWindowHeight: CGFloat = 150

    /// Bounds of the frontmost real on-screen Ghostty window, converted from
    /// Quartz global-display coordinates (top-left origin, y-down) to AppKit
    /// screen coordinates (bottom-left origin, y-up). Only reads owner name,
    /// window layer, and bounds -- none of which require Screen Recording /
    /// Accessibility permission (unlike window titles, which are
    /// deliberately never read here).
    private static func frontmostGhosttyWindowFrame() -> NSRect? {
        // Quartz's global display coordinate space is anchored at the
        // top-left of the PRIMARY display (the one with the menu bar), which
        // AppKit always places at frame origin (0, 0) -- not necessarily
        // `NSScreen.screens.first` (that array's ordering isn't documented
        // to put the primary display first, and on multi-monitor setups it
        // sometimes doesn't). Anchoring the Y-flip to the wrong screen would
        // silently misplace the companion on any secondary display.
        guard let anchorScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowListCopyWindowInfo with .optionOnScreenOnly returns windows
        // already ordered front-to-back, so this preserves z-order
        // (candidates[0] is the frontmost Ghostty window, if any).
        var candidates: [NSRect] = []
        for info in infoList {
            guard let ownerName = info[kCGWindowOwnerName as String] as? String,
                  ownerName == ghosttyOwnerName else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let quartzY = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }

            let appKitY = anchorScreen.frame.height - quartzY - height
            candidates.append(NSRect(x: x, y: appKitY, width: width, height: height))
        }

        guard !candidates.isEmpty else { return nil }

        // Skip quick-terminal-style slivers/overlays (too narrow or too
        // short to be a real terminal window) and take the frontmost
        // survivor. If every on-screen Ghostty window is that small, fall
        // back to the largest by area rather than showing nothing.
        if let realWindow = candidates.first(where: { $0.width >= minRealWindowWidth && $0.height >= minRealWindowHeight }) {
            return realWindow
        }
        return candidates.max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    // MARK: - Drag-to-park

    private func finishRowDrag() {
        isDraggingRow = false
        guard let windowFrame = Self.frontmostGhosttyWindowFrame() else { return }
        let offset = NSPoint(
            x: panel.frame.origin.x - windowFrame.origin.x,
            y: panel.frame.origin.y - windowFrame.origin.y
        )
        customOffset = offset
        UserDefaults.standard.set(Double(offset.x), forKey: Self.offsetXPrefKey)
        UserDefaults.standard.set(Double(offset.y), forKey: Self.offsetYPrefKey)
    }

    private static func loadOffset() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: offsetXPrefKey) != nil,
              defaults.object(forKey: offsetYPrefKey) != nil else { return nil }
        return NSPoint(
            x: CGFloat(defaults.double(forKey: offsetXPrefKey)),
            y: CGFloat(defaults.double(forKey: offsetYPrefKey))
        )
    }

    // MARK: - Context menu (right-click kill switch)

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Companion", action: #selector(hideCompanionFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPositionFromContextMenu), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideCompanionFromContextMenu() {
        setManuallyHidden(true)
    }

    @objc private func resetPositionFromContextMenu() {
        customOffset = nil
        UserDefaults.standard.removeObject(forKey: Self.offsetXPrefKey)
        UserDefaults.standard.removeObject(forKey: Self.offsetYPrefKey)
        repositionToGhosttyWindow()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/DesktopPetPanel.swift ⟧⟧⟧
import AppKit

/// Compact relative age for the hover bubble ("now", "3m", "2h") so the
/// summary text reads with the right freshness.
private func ageText(_ seconds: TimeInterval) -> String {
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    return "\(Int(seconds / 3600))h"
}

/// Human-readable status line for the hover bubble, e.g. "working…" or
/// "needs permission!".
private func statusText(for state: SessionState) -> String {
    switch state {
    case .idle: return "idle"
    case .working: return "working\u{2026}"
    case .waitingPermission: return "needs permission!"
    case .waitingInput: return "waiting for input"
    case .done: return "done \u{2713}"
    case .error: return "error!"
    case .stale: return "stale"
    }
}

/// One desktop-pet otter: the sprite (with headroom above it so it can grow
/// on hover) and a name chip underneath. Hovering scales the sprite up and
/// fires `onHoverChange` so the controller can show the shared status
/// bubble; the bubble itself lives in a separate click-through panel (see
/// StatusBubbleController), NOT inside this view, so long summary text is
/// never clipped by the pet panel's own bounds.
///
/// Handles its own drag-vs-click disambiguation: dragging anywhere on the
/// otter moves the WHOLE panel (the pet is "carried around" the desktop),
/// while a sub-4pt press-and-release fires `onClick`.
final class PetOtterView: NSView {
    static let otterSize: CGFloat = 96
    /// Extra space above the resting sprite so the hover-grow never clips
    /// against the panel edge.
    static let growHeadroom: CGFloat = 12
    static let hoverScale: CGFloat = 1.12
    static let labelHeight: CGFloat = 14
    static let labelGap: CGFloat = 2
    static let totalHeight: CGFloat = growHeadroom + otterSize + labelGap + labelHeight
    static let unitWidth: CGFloat = 110

    private static let dragThreshold: CGFloat = 4

    var onClick: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Set by the controller so a drag on any otter moves the shared panel.
    weak var dragTarget: NSPanel?
    var onDragEnd: (() -> Void)?

    private let spriteView: OtterSpriteView
    private let labelBackground: NSView
    private let labelField: NSTextField

    private var pressOrigin: NSPoint?
    private var panelOriginAtPress: NSPoint?
    private var didDrag = false

    private var restingSpriteFrame: NSRect {
        NSRect(
            x: (Self.unitWidth - Self.otterSize) / 2,
            y: Self.labelHeight + Self.labelGap,
            width: Self.otterSize,
            height: Self.otterSize
        )
    }

    private var grownSpriteFrame: NSRect {
        let size = Self.otterSize * Self.hoverScale
        // Anchored at the bottom-center of the resting frame: the otter's
        // feet stay planted, it puffs up and out.
        return NSRect(
            x: (Self.unitWidth - size) / 2,
            y: Self.labelHeight + Self.labelGap,
            width: size,
            height: size
        )
    }

    init(labelText: String) {
        spriteView = OtterSpriteView(frame: .zero)

        labelBackground = NSView(frame: NSRect(x: 0, y: 0, width: Self.unitWidth, height: Self.labelHeight))
        labelField = NSTextField(labelWithString: labelText)
        labelField.font = .boldSystemFont(ofSize: 9)
        labelField.textColor = .white
        labelField.alignment = .center
        labelField.backgroundColor = .clear
        labelField.isBezeled = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.lineBreakMode = .byTruncatingTail
        labelField.frame = labelBackground.bounds.insetBy(dx: 2, dy: 0)

        super.init(frame: NSRect(x: 0, y: 0, width: Self.unitWidth, height: Self.totalHeight))
        wantsLayer = true
        spriteView.frame = restingSpriteFrame

        labelBackground.wantsLayer = true
        labelBackground.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        labelBackground.layer?.cornerRadius = 4
        labelBackground.layer?.cornerCurve = .continuous

        addSubview(spriteView)
        addSubview(labelBackground)
        labelBackground.addSubview(labelField)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setState(_ state: SessionState) {
        spriteView.setState(state)
    }

    func setLabel(_ text: String) {
        guard labelField.stringValue != text else { return }
        labelField.stringValue = text
    }

    // MARK: - Hover: grow + bubble callback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        animateSprite(to: grownSpriteFrame)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        animateSprite(to: restingSpriteFrame)
        onHoverChange?(false)
    }

    private func animateSprite(to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            spriteView.animator().frame = frame
        }
    }

    // MARK: - Drag the whole panel vs. click

    override func mouseDown(with event: NSEvent) {
        pressOrigin = NSEvent.mouseLocation
        panelOriginAtPress = dragTarget?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressOrigin, let panelOriginAtPress, let panel = dragTarget else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - pressOrigin.x
        let dy = now.y - pressOrigin.y
        if !didDrag {
            guard abs(dx) >= Self.dragThreshold || abs(dy) >= Self.dragThreshold else { return }
            didDrag = true
            // The bubble's screen position goes stale the moment the panel
            // starts moving -- hide it for the duration of the drag.
            onHoverChange?(false)
        }
        panel.setFrameOrigin(NSPoint(x: panelOriginAtPress.x + dx, y: panelOriginAtPress.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressOrigin = nil
            panelOriginAtPress = nil
        }
        if didDrag {
            onDragEnd?()
        } else {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}

/// The shared hover bubble: a small click-through panel (ignoresMouseEvents,
/// so it never steals the hover it depends on) showing a bold status line
/// plus the session's last-reply excerpt, auto-sized up to ~260pt wide and
/// positioned above whichever otter is hovered. One instance serves every
/// otter in the pet.
final class StatusBubbleController {
    private static let maxTextWidth: CGFloat = 244
    private static let paddingX: CGFloat = 10
    private static let paddingY: CGFloat = 7
    private static let gapAboveOtter: CGFloat = 6

    private let panel: NSPanel
    private let textField: NSTextField

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One notch above the pet panel so the bubble is never under it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        container.layer?.cornerRadius = 9
        container.layer?.cornerCurve = .continuous

        textField = NSTextField(wrappingLabelWithString: "")
        textField.font = .systemFont(ofSize: 10)
        textField.textColor = .white
        textField.backgroundColor = .clear
        textField.isBezeled = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.maximumNumberOfLines = 4
        textField.cell?.truncatesLastVisibleLine = true

        container.addSubview(textField)
        panel.contentView = container
    }

    /// Shows the bubble centered above `view` (an otter in the pet panel).
    /// `statusLine` renders bold; `detail` (the last-reply excerpt) regular.
    func show(statusLine: String, detail: String?, above view: NSView) {
        guard let window = view.window else { return }

        let text = NSMutableAttributedString(
            string: statusLine,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white]
        )
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(
                string: "\n" + detail,
                attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.85)]
            ))
        }
        textField.attributedStringValue = text
        textField.preferredMaxLayoutWidth = Self.maxTextWidth
        var textSize = textField.fittingSize
        textSize.width = min(textSize.width, Self.maxTextWidth)

        let bubbleSize = NSSize(
            width: textSize.width + Self.paddingX * 2,
            height: textSize.height + Self.paddingY * 2
        )
        textField.frame = NSRect(x: Self.paddingX, y: Self.paddingY, width: textSize.width, height: textSize.height)

        // Otter's frame in screen coordinates.
        let rectInWindow = view.convert(view.bounds, to: nil)
        let rectOnScreen = window.convertToScreen(rectInWindow)

        var origin = NSPoint(
            x: rectOnScreen.midX - bubbleSize.width / 2,
            y: rectOnScreen.maxY + Self.gapAboveOtter
        )
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - bubbleSize.width - 4)
            if origin.y + bubbleSize.height > visible.maxY {
                // No room above (pet parked at the top edge): flip below.
                origin.y = rectOnScreen.minY - bubbleSize.height - Self.gapAboveOtter
            }
        }

        panel.setFrame(NSRect(origin: origin, size: bubbleSize), display: true)
        panel.contentView?.frame = NSRect(origin: .zero, size: bubbleSize)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// A Codex-Pets-style desktop companion: while Ghostty is NOT frontmost (and
/// the notch/companion UIs are therefore out of sight), one otter floats
/// above every app, animating the highest-priority state across all live
/// sessions. It can be dragged anywhere (position persists across launches).
/// Clicking it expands the pet into one otter per live session -- hover any
/// of them to puff it up and read its status bubble (state + last reply
/// excerpt), click one to jump to its Ghostty tab, click the "\u{00AB}" chip
/// to collapse back to the single otter.
///
/// Complements (never overlaps) the existing UI: the notch panel is always
/// notch-anchored, and `CompanionPanelController` only shows while Ghostty IS
/// frontmost -- this controller only shows while it ISN'T.
final class DesktopPetController {
    private static let rowSpacing: CGFloat = 8
    private static let maxOtters = 8
    private static let hiddenPrefKey = "NotchOtter.desktopPetHidden"
    private static let originXPrefKey = "NotchOtter.desktopPetOriginX"
    private static let originYPrefKey = "NotchOtter.desktopPetOriginY"
    private static let ghosttyOwnerName = "Ghostty"

    let panel: NSPanel
    private let contentView: NSView
    private let bubble = StatusBubbleController()

    /// Per-session otters (expanded mode), keyed by session_id and reused
    /// across updates so walk-cycle animations don't reset.
    private var unitViews: [String: PetOtterView] = [:]
    /// The single summary otter (collapsed mode).
    private var summaryView: PetOtterView?
    private var collapseChipView: NSView?
    private var overflowChipView: OverflowChipView?

    private(set) var isExpanded = false
    private(set) var isManuallyHidden: Bool = UserDefaults.standard.bool(forKey: DesktopPetController.hiddenPrefKey)

    private var isGhosttyFrontmost = false
    private var activationObserver: NSObjectProtocol?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PetOtterView.unitWidth, height: PetOtterView.totalHeight),
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

        contentView = NSView(frame: NSRect(x: 0, y: 0, width: PetOtterView.unitWidth, height: PetOtterView.totalHeight))
        contentView.wantsLayer = true
        contentView.menu = buildContextMenu()
        panel.contentView = contentView

        panel.setFrameOrigin(Self.loadOrigin() ?? Self.defaultOrigin())

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
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Rebuilds the pet for the current session set and re-evaluates
    /// visibility. Driven by AppDelegate on every store/tab update, same as
    /// the other panel controllers.
    func update(store: SessionStore) {
        let records = store.visibleRecords
        guard !records.isEmpty else {
            hidePanel()
            return
        }
        if isExpanded {
            layoutExpanded(store: store)
        } else {
            layoutCollapsed(store: store)
        }
        refreshVisibility(sessionsPresent: true)
    }

    func toggleManualVisibility() {
        isManuallyHidden.toggle()
        UserDefaults.standard.set(isManuallyHidden, forKey: Self.hiddenPrefKey)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
    }

    // MARK: - Collapsed layout: one summary otter

    private func layoutCollapsed(store: SessionStore) {
        for (id, view) in unitViews {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }
        collapseChipView?.removeFromSuperview()
        collapseChipView = nil
        overflowChipView?.removeFromSuperview()
        overflowChipView = nil

        let records = store.visibleRecords
        // The lone otter animates the most urgent state across every session
        // (same priority rule the notch otter uses), so "one of my runs needs
        // permission" is visible even from another app.
        let urgent = records.min { $0.displayState.priority < $1.displayState.priority }
        let state = urgent?.displayState ?? .idle

        let view: PetOtterView
        if let existing = summaryView {
            view = existing
        } else {
            view = PetOtterView(labelText: "")
            view.dragTarget = panel
            view.onDragEnd = { [weak self] in self?.saveOrigin() }
            view.onClick = { [weak self] in self?.setExpanded(true) }
            contentView.addSubview(view)
            summaryView = view
        }
        view.setState(state)
        view.setLabel(records.count == 1
            ? OtterUnitView.truncateProjectName(records[0].session.project)
            : "\(records.count) sessions")

        // Bubble: overall summary line, plus the most urgent session's
        // project + last-reply excerpt as the detail.
        let statusLine = store.summaryText.isEmpty ? statusText(for: state) : store.summaryText
        var detail: String?
        if let urgent {
            let excerpt = urgent.session.lastSummary ?? statusText(for: urgent.displayState)
            detail = "\(urgent.session.project) (\(ageText(urgent.ageSeconds))): \(excerpt)"
        }
        view.onHoverChange = { [weak self, weak view] hovering in
            guard let self else { return }
            if hovering, let view {
                self.bubble.show(statusLine: statusLine, detail: detail, above: view)
            } else {
                self.bubble.hide()
            }
        }
        view.setFrameOrigin(.zero)

        resizePanelKeepingAnchor(width: PetOtterView.unitWidth)
    }

    // MARK: - Expanded layout: one otter per session + collapse chip

    private func layoutExpanded(store: SessionStore) {
        summaryView?.removeFromSuperview()
        summaryView = nil

        let fullOrder = GhosttyTabMatcher.buildRowOrder(
            sessions: store.visibleRecords,
            tabs: GhosttyTabsPoller.shared.tabs
        )
        let overflowCount = max(0, fullOrder.count - Self.maxOtters)
        let displayed = Array(fullOrder.prefix(Self.maxOtters))

        let displayedIDs = Set(displayed.map { $0.record.session.sessionID })
        for (id, view) in unitViews where !displayedIDs.contains(id) {
            view.removeFromSuperview()
            unitViews.removeValue(forKey: id)
        }

        let sharedMenu = contentView.menu

        if collapseChipView == nil {
            let chip = CollapseChipView()
            chip.menu = sharedMenu
            chip.onClick = { [weak self] in self?.setExpanded(false) }
            contentView.addSubview(chip)
            collapseChipView = chip
        }

        if overflowCount > 0 {
            if overflowChipView?.count != overflowCount {
                overflowChipView?.removeFromSuperview()
                let chip = OverflowChipView(count: overflowCount)
                chip.menu = sharedMenu
                contentView.addSubview(chip)
                overflowChipView = chip
            }
        } else if let existing = overflowChipView {
            existing.removeFromSuperview()
            overflowChipView = nil
        }

        var cursorX: CGFloat = 0
        let chipY = PetOtterView.labelHeight + PetOtterView.labelGap
            + (PetOtterView.otterSize - CollapseChipView.height) / 2
        collapseChipView?.setFrameOrigin(NSPoint(x: cursorX, y: chipY))
        cursorX += CollapseChipView.width + Self.rowSpacing

        if overflowCount > 0 {
            overflowChipView?.setFrameOrigin(NSPoint(
                x: cursorX,
                y: PetOtterView.labelHeight + PetOtterView.labelGap
                    + (PetOtterView.otterSize - OverflowChipView.height) / 2
            ))
            cursorX += OverflowChipView.width + Self.rowSpacing
        }

        for row in displayed {
            let record = row.record
            let id = record.session.sessionID

            let labelText: String
            if let tab = row.matchedTab {
                labelText = OtterUnitView.stripLeadingGlyphs(tab.title)
            } else {
                labelText = OtterUnitView.truncateProjectName(record.session.project)
            }

            let unit: PetOtterView
            if let existing = unitViews[id] {
                unit = existing
            } else {
                unit = PetOtterView(labelText: labelText)
                unit.menu = sharedMenu
                unit.dragTarget = panel
                unit.onDragEnd = { [weak self] in self?.saveOrigin() }
                contentView.addSubview(unit)
                unitViews[id] = unit
            }
            // Rebind click/hover targets each update -- the matched tab's
            // ordinals and the last-reply excerpt both change over time.
            let matchedTab = row.matchedTab
            let cwd = record.session.cwd
            unit.onClick = {
                if let tab = matchedTab {
                    TerminalFocusDispatcher.focusTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex, cwd: cwd)
                } else {
                    TerminalFocusDispatcher.focus(cwd: cwd)
                }
            }
            let statusLine = "\(statusText(for: record.displayState)) \u{00B7} \(record.session.project) \u{00B7} \(ageText(record.ageSeconds))"
            let detail = record.session.lastSummary
            unit.onHoverChange = { [weak self, weak unit] hovering in
                guard let self else { return }
                if hovering, let unit {
                    self.bubble.show(statusLine: statusLine, detail: detail, above: unit)
                } else {
                    self.bubble.hide()
                }
            }
            unit.setState(record.displayState)
            unit.setLabel(labelText)
            unit.setFrameOrigin(NSPoint(x: cursorX, y: 0))
            cursorX += PetOtterView.unitWidth + Self.rowSpacing
        }

        resizePanelKeepingAnchor(width: max(PetOtterView.unitWidth, cursorX - Self.rowSpacing))
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        bubble.hide()
        update(store: SessionStore.shared)
    }

    /// Resizes the panel so its top-RIGHT corner stays put: the summary otter
    /// keeps its spot and the session otters pop out leftward (and fold back
    /// into the same spot on collapse), then clamps to the screen so a pet
    /// parked near an edge never expands off-screen.
    private func resizePanelKeepingAnchor(width: CGFloat) {
        let size = NSSize(width: width, height: PetOtterView.totalHeight)
        guard panel.frame.size != size else {
            contentView.frame = NSRect(origin: .zero, size: size)
            return
        }
        let anchorMaxX = panel.frame.maxX
        let y = panel.frame.origin.y
        var frame = NSRect(x: anchorMaxX - width, y: y, width: width, height: size.height)

        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - width))
            frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }

        panel.setFrame(frame, display: true)
        contentView.frame = NSRect(origin: .zero, size: size)
    }

    // MARK: - Visibility rule: Ghostty NOT frontmost + sessions exist + not hidden

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        isGhosttyFrontmost = Self.isGhostty(app)
        refreshVisibility(sessionsPresent: !SessionStore.shared.visibleRecords.isEmpty)
    }

    private static func isGhostty(_ app: NSRunningApplication) -> Bool {
        if let bundleID = app.bundleIdentifier, bundleID.localizedCaseInsensitiveContains("ghostty") {
            return true
        }
        return app.localizedName == ghosttyOwnerName
    }

    private func refreshVisibility(sessionsPresent: Bool) {
        let shouldShow = !isGhosttyFrontmost && sessionsPresent && !isManuallyHidden
        guard shouldShow else {
            hidePanel()
            return
        }
        clampOntoScreen()
        panel.orderFrontRegardless()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        bubble.hide()
    }

    /// Pulls the panel fully back into some screen's visible area, e.g. after
    /// a display was unplugged while the pet was parked on it.
    private func clampOntoScreen() {
        var frame = panel.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    // MARK: - Position persistence (anchored to the top-right corner, since
    // that's the point `resizePanelKeepingAnchor` keeps fixed)

    private func saveOrigin() {
        UserDefaults.standard.set(Double(panel.frame.maxX), forKey: Self.originXPrefKey)
        UserDefaults.standard.set(Double(panel.frame.origin.y), forKey: Self.originYPrefKey)
    }

    private static func loadOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXPrefKey) != nil,
              defaults.object(forKey: originYPrefKey) != nil else { return nil }
        let maxX = CGFloat(defaults.double(forKey: originXPrefKey))
        let y = CGFloat(defaults.double(forKey: originYPrefKey))
        return NSPoint(x: maxX - PetOtterView.unitWidth, y: y)
    }

    private static func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return NSPoint(x: 100, y: 100) }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - PetOtterView.unitWidth - 24,
            y: visible.minY + 24
        )
    }

    // MARK: - Context menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let hideItem = NSMenuItem(title: "Hide Desktop Pet", action: #selector(hideFromContextMenu), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit NotchOtter", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    @objc private func hideFromContextMenu() {
        isManuallyHidden = true
        UserDefaults.standard.set(true, forKey: Self.hiddenPrefKey)
        hidePanel()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

/// Small "\u{00AB}" pill at the row's left end (expanded mode) that folds the
/// pet back into the single summary otter.
final class CollapseChipView: NSView {
    static let width: CGFloat = 28
    static let height: CGFloat = 18

    var onClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous

        let label = NSTextField(labelWithString: "\u{00AB}")
        label.font = .boldSystemFont(ofSize: 11)
        label.textColor = .white
        label.alignment = .center
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        superview?.menu
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/DropdownPanel.swift ⟧⟧⟧
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/OtterSpriteView.swift ⟧⟧⟧
import AppKit

/// Displays one frame of a state's sprite sheet at a time, stepping through
/// frames on a timer with nearest-neighbor (pixel-perfect) scaling.
/// Sprite sheets are loaded from `Contents/Resources/sprites/<state>.png`,
/// laid out horizontally in square cells: cell size = sheet height, so
/// frame count = width / height (SPEC.md section 3; a 96x32 sheet is 3
/// frames, a 501x167 sheet is 3 frames).
final class OtterSpriteView: NSView {
    private static let defaultFrameInterval: TimeInterval = 0.4
    /// `working` animates snappier than the rest so it visibly reads as
    /// "busy" at a glance.
    private static let workingFrameInterval: TimeInterval = 0.25

    private static func frameInterval(for state: SessionState) -> TimeInterval {
        state == .working ? workingFrameInterval : defaultFrameInterval
    }

    private let imageLayer = CALayer()
    private var frames: [CGImage] = []
    private var frameIndex = 0
    private var timer: Timer?
    private var loadedState: SessionState?
    private var packObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.actions = ["contents": NSNull()] // disable implicit fade between frames
        layer?.addSublayer(imageLayer)

        // Live character swap: when the user picks a different sprite pack,
        // re-load the currently-shown state from the new pack in place.
        packObserver = NotificationCenter.default.addObserver(
            forName: .spritePackDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let current = self.loadedState else { return }
            self.loadedState = nil
            self.setState(current)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    /// Switches the displayed animation to `state`. No-op if already showing it.
    func setState(_ state: SessionState) {
        guard state != loadedState else { return }
        loadedState = state
        frames = Self.loadFrames(for: state)
        frameIndex = 0
        timer?.invalidate()
        timer = nil

        guard !frames.isEmpty else {
            imageLayer.contents = nil
            return
        }

        imageLayer.contents = frames[0]
        guard frames.count > 1 else { return }

        let newTimer = Timer(timeInterval: Self.frameInterval(for: state), repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        frameIndex = (frameIndex + 1) % frames.count
        imageLayer.contents = frames[frameIndex]
    }

    /// First frame of the currently-selected sprite pack's sheet for
    /// `state`, as a static (non-animated) image -- used for the Preferences
    /// window's character-pack preview, which doesn't need a full animated
    /// OtterSpriteView. Reuses the same slicing logic as the live animation
    /// loader, just without the timer.
    static func previewImage(for state: SessionState) -> NSImage? {
        guard let cgImage = loadFrames(for: state).first else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func loadFrames(for state: SessionState) -> [CGImage] {
        guard let url = SpritePacks.sheetURL(for: state),
              let image = NSImage(contentsOf: url) else {
            return []
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return []
        }

        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let cellPixels = pixelHeight
        guard cellPixels > 0, pixelWidth >= cellPixels else {
            return [cgImage]
        }

        let frameCount = max(1, pixelWidth / cellPixels)
        var slices: [CGImage] = []
        slices.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let rect = CGRect(x: i * cellPixels, y: 0, width: cellPixels, height: pixelHeight)
            if let slice = cgImage.cropping(to: rect) {
                slices.append(slice)
            }
        }
        return slices.isEmpty ? [cgImage] : slices
    }

    deinit {
        timer?.invalidate()
        if let packObserver {
            NotificationCenter.default.removeObserver(packObserver)
        }
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/SpritePacks.swift ⟧⟧⟧
import Foundation

extension Notification.Name {
    /// Posted when the selected sprite pack changes; every live
    /// OtterSpriteView reloads its current animation from the new pack.
    static let spritePackDidChange = Notification.Name("NotchOtter.spritePackDidChange")
}

/// Custom character packs: a pack is a directory under
/// `~/.local/share/notch-otter/sprites/<name>/` holding `<state>.png` sprite
/// sheets in the same format as the bundled otter (horizontal strip of
/// square cells; see SPEC.md section 3). Packs are typically produced by
/// `spritegen/hatch.py` from a user photo. Missing states fall back to the
/// bundled otter's sheet for that state, so a partial pack still works.
enum SpritePacks {
    private static let selectionKey = "NotchOtter.spritePack"

    /// Directory scanned for packs. Created on demand so "Open Sprite Packs
    /// Folder" always has somewhere to land.
    static var packsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/notch-otter/sprites", isDirectory: true)
    }

    /// Currently selected pack name; nil = the bundled otter.
    static var selected: String? {
        let raw = UserDefaults.standard.string(forKey: selectionKey)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static func select(_ name: String?) {
        if let name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
        NotificationCenter.default.post(name: .spritePackDidChange, object: nil)
    }

    /// Pack names available on disk (subdirectories containing at least one
    /// recognizable state sheet), sorted for stable menu ordering.
    static func availablePacks() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: packsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { dir in
                SessionState.allCases.contains { state in
                    fm.fileExists(atPath: dir.appendingPathComponent("\(state.rawValue).png").path)
                }
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Ensures the packs directory exists (for the "open folder" menu item).
    @discardableResult
    static func ensurePacksDirectory() -> URL {
        try? FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        return packsDirectory
    }

    /// Sheet URL for a state: the selected pack's file when present, else
    /// the bundled otter's.
    static func sheetURL(for state: SessionState) -> URL? {
        if let selected {
            let candidate = packsDirectory
                .appendingPathComponent(selected, isDirectory: true)
                .appendingPathComponent("\(state.rawValue).png")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return Bundle.main.url(forResource: state.rawValue, withExtension: "png", subdirectory: "sprites")
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/StatusBarController.swift ⟧⟧⟧
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
    private let preferencesItem = NSMenuItem(title: "Preferences\u{2026}", action: nil, keyEquivalent: ",")

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

    /// The menu bar shows only the otter icon — session counts are visible
    /// in the notch/companion pets, so no text is appended here.
    func updateSummary(_ text: String) {
        guard let button = statusItem.button else { return }
        button.title = "\u{1F9A6}"
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

        preferencesItem.target = self
        preferencesItem.action = #selector(openPreferences)
        menu.addItem(preferencesItem)

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
    /// (e.g. the otter's own right-click "Hide Otter"/"Hide Companion"
    /// items). Character-pack and terminal choices moved into the
    /// Preferences window (see PreferencesWindowController), which rebuilds
    /// its own sections from disk/UserDefaults every time it's opened, so
    /// there's nothing to refresh here anymore.
    func menuWillOpen(_ menu: NSMenu) {
        showHideItem.state = (notchPanelController?.isManuallyHidden ?? false) ? .off : .on
        showHideCompanionItem.state = (companionPanelController?.isManuallyHidden ?? false) ? .off : .on
        showHideDesktopPetItem.state = (desktopPetController?.isManuallyHidden ?? false) ? .off : .on
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.show()
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/PreferencesWindowController.swift ⟧⟧⟧
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

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/TerminalFocuser.swift ⟧⟧⟧
import Foundation

/// A way to bring the terminal window/tab for a given working directory to
/// the front. Implementations must never crash and never surface an
/// uncaught error to the caller -- at most a beep -- mirroring
/// `GhosttyFocus`'s swallow-all-failures behavior (see its doc comment).
protocol TerminalFocuser {
    static func focus(cwd: String)
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/TerminalPreference.swift ⟧⟧⟧
import AppKit

extension Notification.Name {
    /// Posted when the user's selected terminal app changes (Preferences
    /// window's Terminal section), mirroring `.spritePackDidChange` for
    /// consistency even though there's currently only the one UI that reads
    /// `TerminalPreference.selected`.
    static let terminalAppDidChange = Notification.Name("NotchOtter.terminalAppDidChange")
}

/// Which terminal app NotchOtter focuses when a session's otter is clicked.
/// `.ghostty` is the default -- this preserves exactly the pre-Preferences
/// behavior, when GhosttyFocus was the only option and every click site
/// called it directly.
enum TerminalApp: String, CaseIterable {
    case ghostty
    case iterm2
    case terminal

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .terminal: return "Terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        }
    }

    /// Whether this terminal app is installed on this Mac, per LaunchServices
    /// (NSWorkspace bundle-identifier lookup) -- not whether it's currently
    /// running. An app can be selected in Preferences without being open;
    /// focusing it will simply launch/activate it like any AppleScript
    /// `tell application ... activate` does.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

/// Persisted choice of which terminal app to focus, read by
/// `TerminalFocusDispatcher` and written by the Preferences window.
enum TerminalPreference {
    private static let key = "NotchOtter.terminalApp"

    static var selected: TerminalApp {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let app = TerminalApp(rawValue: raw) else {
            return .ghostty
        }
        return app
    }

    static func select(_ app: TerminalApp) {
        UserDefaults.standard.set(app.rawValue, forKey: key)
        NotificationCenter.default.post(name: .terminalAppDidChange, object: nil)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/TerminalFocusDispatcher.swift ⟧⟧⟧
import Foundation

/// Single entry point every click site routes through, replacing direct
/// `GhosttyFocus` calls: reads `TerminalPreference.selected` and dispatches
/// to whichever `TerminalFocuser` matches.
///
/// Exposes the same two method names as `GhosttyFocus` (`focus(cwd:)`,
/// `focusTab(...)`) so call sites only needed a type-name swap, not a
/// rewrite.
enum TerminalFocusDispatcher {
    /// Focuses `cwd` in the user's selected terminal app.
    static func focus(cwd: String) {
        switch TerminalPreference.selected {
        case .ghostty:
            GhosttyFocus.focus(cwd: cwd)
        case .iterm2:
            ITerm2Focus.focus(cwd: cwd)
        case .terminal:
            AppleTerminalFocus.focus(cwd: cwd)
        }
    }

    /// Focuses an exact Ghostty tab (`GhosttyFocus.focusTab`) when the
    /// user's selected terminal IS Ghostty, preserving today's behavior
    /// byte-for-byte. Any other selected terminal has no equivalent notion
    /// of a stable (windowIndex, tabIndex) identity, so this falls back to
    /// `focus(cwd:)` using the matched tab's own cwd instead -- exact-tab
    /// precision is a Ghostty-only feature (see ITerm2Focus/AppleTerminalFocus
    /// doc comments).
    static func focusTab(windowIndex: Int, tabIndex: Int, cwd: String) {
        guard TerminalPreference.selected == .ghostty else {
            focus(cwd: cwd)
            return
        }
        GhosttyFocus.focusTab(windowIndex: windowIndex, tabIndex: tabIndex)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/GhosttyFocus.swift ⟧⟧⟧
import AppKit

/// Focuses the Ghostty terminal window whose working directory matches a
/// session's `cwd`, using Ghostty's own AppleScript dictionary (Ghostty.sdef:
/// `terminal` objects expose a `working directory` property and a `focus`
/// command) rather than System Events UI scripting -- this avoids requiring
/// Accessibility (TCC) permission entirely.
///
/// Match order:
/// 1. Exact `working directory is <cwd>`.
/// 2. `working directory contains <cwd>` (tolerates trailing slash / symlink
///    resolution differences between the hook-recorded cwd and what Ghostty
///    reports).
/// 3. `working directory ends with "/<project>"` (last path component only).
/// 4. Fall back to plain `activate` of Ghostty.
///
/// All failures are swallowed per SPEC: a beep, never a crash.
enum GhosttyFocus: TerminalFocuser {
    static func focus(cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = runFocusScript(cwd: cwd)
            if !success {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    /// Focuses an EXACT tab by its (windowIndex, tabIndex) ordinals, as
    /// established by `GhosttyTabsPoller` -- used when a session has been
    /// matched to a specific tab, since cwd-matching alone is ambiguous when
    /// multiple tabs share the same working directory. Reuses the same
    /// verified `focus (first terminal of ...)` command as `focus(cwd:)`
    /// rather than assuming tabs themselves also support `focus` directly.
    static func focusTab(windowIndex: Int, tabIndex: Int) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = runFocusTabScript(windowIndex: windowIndex, tabIndex: tabIndex)
            if !success {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    private static func runFocusTabScript(windowIndex: Int, tabIndex: Int) -> Bool {
        let script = """
        on run
            try
                tell application "Ghostty"
                    activate
                    set targetWindow to window \(windowIndex)
                    set targetTab to tab \(tabIndex) of targetWindow
                    focus (first terminal of targetTab)
                end tell
                return true
            on error
                return false
            end try
        end run
        """

        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("NotchOtter: Ghostty focusTab AppleScript failed: \(errorDict)")
            return false
        }
        return result.booleanValue
    }

    private static func runFocusScript(cwd: String) -> Bool {
        let projectName = (cwd as NSString).lastPathComponent
        let escapedCwd = appleScriptEscape(cwd)
        let escapedProject = appleScriptEscape(projectName)

        let script = """
        on run
            tell application "Ghostty"
                try
                    activate
                on error
                    return false
                end try
                try
                    set t to first terminal whose working directory is "\(escapedCwd)"
                    focus t
                    return true
                end try
                try
                    set t to first terminal whose working directory contains "\(escapedCwd)"
                    focus t
                    return true
                end try
                try
                    set t to first terminal whose working directory ends with "/\(escapedProject)"
                    focus t
                    return true
                end try
            end tell
            return true
        end run
        """

        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("NotchOtter: Ghostty focus AppleScript failed: \(errorDict)")
            return false
        }
        return result.booleanValue
    }

    private static func appleScriptEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/GhosttyTabMatching.swift ⟧⟧⟧
import Foundation

/// One row-worthy entry: a session, plus the Ghostty tab it was matched to
/// (nil when unmatched -- headless run, different terminal app, or tab data
/// unavailable).
struct MatchedRow {
    let record: SessionRecord
    let matchedTab: GhosttyTabInfo?
}

/// Matches live sessions to Ghostty tabs and produces the companion row's
/// display order. Pure function, no app state -- easy to reason about and
/// test independently of AppleScript/timers.
///
/// Algorithm:
/// 1. If no tab data is available (`tabs == nil`, e.g. Automation permission
///    not yet granted, or Ghostty not running), degrade to the old
///    behavior: every session unmatched, ordered by `firstSeenAt`.
/// 2. Otherwise, group both tabs and sessions by normalized working
///    directory (`tab.cwd` vs `session.groupingCwd`, i.e. `launch_cwd`
///    falling back to `cwd`).
/// 3. Within each cwd group, sort that group's sessions by numeric tty
///    suffix ascending (sessions without a tty sort after those with one,
///    sub-sorted by `firstSeenAt`), then zip 1:1 with that group's tabs in
///    their existing tab order. A group with exactly one tab and one
///    session is just the trivial case of this same zip (no special-casing
///    needed). Leftover tabs (more tabs than sessions in a group) are
///    simply unused; leftover sessions (more sessions than tabs) fall
///    through to "unmatched".
/// 4. Matched rows are sorted by the matched tab's global (windowIndex,
///    tabIndex) position, so the final order reflects Ghostty's actual
///    on-screen tab order regardless of cwd-group iteration order.
/// 5. Unmatched sessions are appended after all matched ones, in
///    `firstSeenAt` order.
enum GhosttyTabMatcher {
    static func buildRowOrder(sessions: [SessionRecord], tabs: [GhosttyTabInfo]?) -> [MatchedRow] {
        guard let tabs, !tabs.isEmpty else {
            return sessions
                .sorted { $0.firstSeenAt < $1.firstSeenAt }
                .map { MatchedRow(record: $0, matchedTab: nil) }
        }

        var tabsByCwd: [String: [GhosttyTabInfo]] = [:]
        for tab in tabs {
            tabsByCwd[normalize(tab.cwd), default: []].append(tab)
        }

        var sessionsByCwd: [String: [SessionRecord]] = [:]
        for session in sessions {
            sessionsByCwd[normalize(session.session.groupingCwd), default: []].append(session)
        }

        var matchedRows: [MatchedRow] = []
        var matchedSessionIDs = Set<String>()

        for (cwdKey, groupTabs) in tabsByCwd {
            guard let groupSessionsRaw = sessionsByCwd[cwdKey], !groupSessionsRaw.isEmpty else { continue }
            let groupSessions = groupSessionsRaw.sorted(by: sessionOrderingForZip)
            let pairCount = min(groupTabs.count, groupSessions.count)
            for i in 0..<pairCount {
                matchedRows.append(MatchedRow(record: groupSessions[i], matchedTab: groupTabs[i]))
                matchedSessionIDs.insert(groupSessions[i].session.sessionID)
            }
        }

        // Re-sort by the matched tab's actual global position so the final
        // order is correct regardless of which order we happened to iterate
        // cwd groups in above (dictionary iteration order is not stable).
        matchedRows.sort { lhs, rhs in
            guard let lt = lhs.matchedTab, let rt = rhs.matchedTab else { return false }
            if lt.windowIndex != rt.windowIndex { return lt.windowIndex < rt.windowIndex }
            return lt.tabIndex < rt.tabIndex
        }

        let unmatchedRows = sessions
            .filter { !matchedSessionIDs.contains($0.session.sessionID) }
            .sorted { $0.firstSeenAt < $1.firstSeenAt }
            .map { MatchedRow(record: $0, matchedTab: nil) }

        return matchedRows + unmatchedRows
    }

    /// Trailing-slash-insensitive comparison key (tabs/sessions may report
    /// the same directory with or without a trailing slash).
    private static func normalize(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// Sessions with a tty sort before sessions without one; among those
    /// with a tty, ascending numeric suffix (ttys003 < ttys014); among those
    /// without, ascending firstSeenAt.
    private static func sessionOrderingForZip(_ a: SessionRecord, _ b: SessionRecord) -> Bool {
        let aTTY = ttyNumericSuffix(a.session.tty)
        let bTTY = ttyNumericSuffix(b.session.tty)
        switch (aTTY, bTTY) {
        case let (a?, b?): return a < b
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.firstSeenAt < b.firstSeenAt
        }
    }

    private static func ttyNumericSuffix(_ tty: String?) -> Int? {
        guard let tty else { return nil }
        let digits = String(tty.reversed().prefix { $0.isNumber }.reversed())
        return digits.isEmpty ? nil : Int(digits)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/GhosttyTabsPoller.swift ⟧⟧⟧
import AppKit

extension Notification.Name {
    /// Posted on the main thread whenever `GhosttyTabsPoller.shared.tabs`
    /// changes (including transitions to/from nil). Separate from
    /// `.sessionStoreDidUpdate` since tab titles can change independently of
    /// any session state change.
    static let ghosttyTabsPollerDidUpdate = Notification.Name("NotchOtter.ghosttyTabsPollerDidUpdate")
}

/// One Ghostty tab's identity and live state, in on-screen tab order.
struct GhosttyTabInfo: Equatable {
    /// 1-based index into Ghostty's `windows` list (AppleScript ordinal).
    let windowIndex: Int
    /// 1-based index into that window's `tabs` list (AppleScript ordinal).
    let tabIndex: Int
    /// Live tab title, unstripped (may have leading spinner/glyph characters
    /// -- stripping happens where it's displayed, not here).
    let title: String
    /// The launching shell's working directory, from the tab's first
    /// terminal. Stays at the shell's launch directory even if a program
    /// running inside `cd`s elsewhere.
    let cwd: String
}

/// App-wide singleton that polls Ghostty's own AppleScript dictionary every
/// 2 seconds for the live list of open tabs (window index, tab index, title,
/// cwd), in on-screen tab order. Runs independently of whether the companion
/// panel is currently visible -- `SessionStore.visibleRecords` also needs
/// fresh-ish tab-match data to decide which done/idle sessions are exempt
/// from the age-based prune (a session matched to a still-open tab is never
/// pruned), and that decision has to be correct even while Ghostty isn't
/// frontmost or the companion is hidden.
///
/// Degrades gracefully to `tabs = nil` on ANY failure (Ghostty not running,
/// Automation permission not yet granted, AppleScript error) -- callers must
/// treat `nil` as "fall back to plain session-only behavior", never crash,
/// and this never retries faster than the fixed 2s cadence.
final class GhosttyTabsPoller {
    static let shared = GhosttyTabsPoller()

    private static let pollInterval: TimeInterval = 2.0

    private(set) var tabs: [GhosttyTabInfo]?

    private var timer: Timer?

    private init() {}

    /// Starts (or no-ops if already running) polling every 2s, with an
    /// immediate first poll so callers don't wait a full interval for data.
    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        // Checked BEFORE touching AppleScript: `tell application "Ghostty"`
        // would otherwise silently LAUNCH Ghostty if it isn't running, which
        // is never something a 2s background poll should do.
        guard Self.isGhosttyRunning() else {
            setTabs(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.runAppleScript()
            DispatchQueue.main.async {
                self?.setTabs(result)
            }
        }
    }

    /// Only updates state (and notifies) when the tab list actually
    /// changed, so a steady-state Ghostty (nothing opened/closed/retitled)
    /// doesn't cause a `refreshUI()` every 2s for nothing.
    private func setTabs(_ newTabs: [GhosttyTabInfo]?) {
        guard newTabs != tabs else { return }
        tabs = newTabs
        NotificationCenter.default.post(name: .ghosttyTabsPollerDidUpdate, object: self)
    }

    private static func isGhosttyRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            if let bundleID = app.bundleIdentifier, bundleID.localizedCaseInsensitiveContains("ghostty") {
                return true
            }
            return app.localizedName == "Ghostty"
        }
    }

    /// Field separator (ASCII Unit Separator) and entry separator (ASCII
    /// Record Separator) used to marshal Ghostty's tab list back through
    /// NSAppleScript as one plain string, instead of trying to parse
    /// NSAppleEventDescriptor records (AppleScript's keyword-code mapping for
    /// ad-hoc record labels is fragile and not worth it here). Real terminal
    /// titles/paths essentially never contain raw ASCII control characters,
    /// so this is a robust delimiter choice even with arbitrary Unicode
    /// (including Korean) title text.
    private static let fieldSeparator = "\u{1F}"
    private static let entrySeparator = "\u{1E}"

    private static func runAppleScript() -> [GhosttyTabInfo]? {
        let fs = fieldSeparator
        let rs = entrySeparator
        let script = """
        on run
            set fs to "\(fs)"
            set rs to "\(rs)"
            set outLines to {}
            try
                tell application "Ghostty"
                    set winList to windows
                    repeat with wIdx from 1 to count of winList
                        set w to item wIdx of winList
                        set tabList to tabs of w
                        repeat with tIdx from 1 to count of tabList
                            set t to item tIdx of tabList
                            set tTitle to ""
                            set tCwd to ""
                            try
                                set tTitle to (name of t as string)
                            end try
                            try
                                set tCwd to (working directory of (first terminal of t)) as string
                            end try
                            set end of outLines to ((wIdx as string) & fs & (tIdx as string) & fs & tTitle & fs & tCwd)
                        end repeat
                    end repeat
                end tell
            on error
                return ""
            end try
            set AppleScript's text item delimiters to rs
            set outString to outLines as string
            set AppleScript's text item delimiters to ""
            return outString
        end run
        """

        guard let appleScript = NSAppleScript(source: script) else { return nil }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("NotchOtter: Ghostty tabs poll failed (Automation permission not granted yet, or AppleScript error): \(errorDict)")
            return nil
        }
        guard let raw = result.stringValue else { return nil }
        guard !raw.isEmpty else { return [] }

        var parsed: [GhosttyTabInfo] = []
        for entry in raw.components(separatedBy: entrySeparator) {
            let fields = entry.components(separatedBy: fieldSeparator)
            guard fields.count == 4,
                  let windowIndex = Int(fields[0]),
                  let tabIndex = Int(fields[1]) else { continue }
            parsed.append(GhosttyTabInfo(windowIndex: windowIndex, tabIndex: tabIndex, title: fields[2], cwd: fields[3]))
        }
        return parsed
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/ITerm2Focus.swift ⟧⟧⟧
import AppKit

/// Focuses the iTerm2 window/tab/session whose current working directory
/// matches a session's `cwd`, using iTerm2's own AppleScript dictionary
/// (each `session` exposes its live cwd via `variable named "session.path"`).
///
/// Unlike Ghostty, iTerm2 sessions have no stable per-launch (windowIndex,
/// tabIndex) identity worth threading through the app -- this is cwd-based
/// window/tab focus only, same as Ghostty's own cwd fallback path. Exact-tab
/// precision (`GhosttyFocus.focusTab`) is Ghostty-only; see
/// `TerminalFocusDispatcher`.
///
/// Match order mirrors GhosttyFocus:
/// 1. Exact `session.path` match.
/// 2. Substring match (tolerates trailing slash / symlink differences).
/// 3. Trailing path component match (last resort).
/// 4. Fall back to plain `activate` of iTerm2.
///
/// All failures are swallowed per SPEC: a beep, never a crash.
enum ITerm2Focus: TerminalFocuser {
    static func focus(cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = runFocusScript(cwd: cwd)
            if !success {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    private static func runFocusScript(cwd: String) -> Bool {
        let projectName = (cwd as NSString).lastPathComponent
        let escapedCwd = appleScriptEscape(cwd)
        let escapedProject = appleScriptEscape(projectName)

        // Three passes (exact, substring, suffix) over every session in
        // every tab in every window, in that priority order -- iTerm2's
        // dictionary has no "session whose variable ..." filter clause, so
        // this walks the tree explicitly instead, same shape as
        // GhosttyTabsPoller's own enumeration script.
        let script = """
        on run
            tell application "iTerm2"
                try
                    activate
                on error
                    return false
                end try
                repeat with matchTier from 1 to 3
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                set sPath to ""
                                try
                                    set sPath to (variable named "session.path" of s) as string
                                end try
                                set isMatch to false
                                if matchTier is 1 and sPath is "\(escapedCwd)" then
                                    set isMatch to true
                                else if matchTier is 2 and sPath contains "\(escapedCwd)" then
                                    set isMatch to true
                                else if matchTier is 3 and sPath ends with "/\(escapedProject)" then
                                    set isMatch to true
                                end if
                                if isMatch then
                                    try
                                        select w
                                    end try
                                    try
                                        select t
                                    end try
                                    try
                                        select s
                                    end try
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                end repeat
            end tell
            return true
        end run
        """

        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("NotchOtter: iTerm2 focus AppleScript failed: \(errorDict)")
            return false
        }
        return result.booleanValue
    }

    private static func appleScriptEscape(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/AppleTerminalFocus.swift ⟧⟧⟧
import AppKit

/// Focuses the Apple Terminal.app window/tab whose foreground process's
/// working directory matches a session's `cwd`.
///
/// Terminal's AppleScript dictionary exposes each tab's `tty name` but --
/// unlike Ghostty/iTerm2 -- no working-directory property at all, so the
/// match is done in two steps: enumerate every (windowIndex, tabIndex,
/// ttyName) via AppleScript, then resolve each tty to its attached
/// processes' cwd with `ps`/`lsof` (reading only the current user's own
/// processes -- no Accessibility/TCC permission needed).
///
/// Match order mirrors GhosttyFocus/ITerm2Focus: exact cwd, then substring,
/// then trailing path component; falls back to plain `activate` if nothing
/// matches (or `ps`/`lsof` are unavailable). Exact-tab precision is
/// Ghostty-only; see `TerminalFocusDispatcher`.
///
/// All failures are swallowed per SPEC: a beep, never a crash.
enum AppleTerminalFocus: TerminalFocuser {
    static func focus(cwd: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let success = runFocus(cwd: cwd)
            if !success {
                DispatchQueue.main.async {
                    NSSound.beep()
                }
            }
        }
    }

    private struct TabEntry {
        let windowIndex: Int
        let tabIndex: Int
        let tty: String
    }

    private static func runFocus(cwd targetCwd: String) -> Bool {
        guard activateTerminal() else { return false }

        let projectName = (targetCwd as NSString).lastPathComponent
        let entries = listTabs()

        // Three passes (exact, substring, suffix), same priority order as
        // the other focusers -- checked across all tabs' resolved cwds
        // before falling through to the next, looser tier.
        for tier in 0..<3 {
            for entry in entries {
                for candidateCwd in candidateCwds(forTTY: entry.tty) {
                    let isMatch: Bool
                    switch tier {
                    case 0: isMatch = candidateCwd == targetCwd
                    case 1: isMatch = candidateCwd.contains(targetCwd)
                    default: isMatch = candidateCwd.hasSuffix("/\(projectName)")
                    }
                    if isMatch {
                        selectTab(windowIndex: entry.windowIndex, tabIndex: entry.tabIndex)
                        return true
                    }
                }
            }
        }
        // No tab's resolved cwd matched, but Terminal is already frontmost
        // from activateTerminal() above -- that alone counts as success (no
        // beep), same as GhosttyFocus's "no matching terminal found" case.
        return true
    }

    private static func activateTerminal() -> Bool {
        let script = """
        on run
            try
                tell application "Terminal" to activate
                return true
            on error
                return false
            end try
        end run
        """
        guard let appleScript = NSAppleScript(source: script) else { return false }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if let errorDict {
            NSLog("NotchOtter: Terminal.app activate AppleScript failed: \(errorDict)")
            return false
        }
        return result.booleanValue
    }

    private static let fieldSeparator = "\u{1F}"
    private static let entrySeparator = "\u{1E}"

    private static func listTabs() -> [TabEntry] {
        let fs = fieldSeparator
        let rs = entrySeparator
        let script = """
        on run
            set fs to "\(fs)"
            set rs to "\(rs)"
            set outLines to {}
            try
                tell application "Terminal"
                    set winList to windows
                    repeat with wIdx from 1 to count of winList
                        set w to item wIdx of winList
                        set tabList to tabs of w
                        repeat with tIdx from 1 to count of tabList
                            set t to item tIdx of tabList
                            set tTTY to ""
                            try
                                set tTTY to (tty of t) as string
                            end try
                            set end of outLines to ((wIdx as string) & fs & (tIdx as string) & fs & tTTY)
                        end repeat
                    end repeat
                end tell
            on error
                return ""
            end try
            set AppleScript's text item delimiters to rs
            set outString to outLines as string
            set AppleScript's text item delimiters to ""
            return outString
        end run
        """

        guard let appleScript = NSAppleScript(source: script) else { return [] }
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)
        if errorDict != nil { return [] }
        guard let raw = result.stringValue, !raw.isEmpty else { return [] }

        var parsed: [TabEntry] = []
        for entry in raw.components(separatedBy: entrySeparator) {
            let fields = entry.components(separatedBy: fieldSeparator)
            guard fields.count == 3,
                  let windowIndex = Int(fields[0]),
                  let tabIndex = Int(fields[1]),
                  !fields[2].isEmpty else { continue }
            parsed.append(TabEntry(windowIndex: windowIndex, tabIndex: tabIndex, tty: fields[2]))
        }
        return parsed
    }

    /// Every process attached to `tty` (e.g. "/dev/ttys003"), via `ps -t`,
    /// resolved to its own current working directory via `lsof`. Returns
    /// every candidate rather than picking just the login shell, since a
    /// program running inside the tab (e.g. `claude`) may be the one whose
    /// cwd actually matches the session -- any match on the tty is good
    /// enough to focus that tab.
    private static func candidateCwds(forTTY tty: String) -> [String] {
        let ttyName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard let output = run("/bin/ps", ["-t", ttyName, "-o", "pid="]) else { return [] }
        let pids = output.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return pids.compactMap(cwd(forPID:))
    }

    private static func cwd(forPID pid: Int) -> String? {
        guard let output = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(pid)", "-Fn"]) else { return nil }
        // lsof's `-Fn` field output: the line right after the "cwd" file
        // descriptor entry starts with "n" and carries the path.
        for line in output.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func run(_ executablePath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    private static func selectTab(windowIndex: Int, tabIndex: Int) {
        let script = """
        on run
            try
                tell application "Terminal"
                    activate
                    set targetWindow to window \(windowIndex)
                    set targetTab to tab \(tabIndex) of targetWindow
                    set selected of targetTab to true
                    set frontmost of targetWindow to true
                end tell
            end try
        end run
        """
        guard let appleScript = NSAppleScript(source: script) else { return }
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/NotificationManager.swift ⟧⟧⟧
import Foundation
import UserNotifications

/// Fires local notifications on transitions INTO `waiting_permission`,
/// `done`, or `error` (never on `working`/`idle`), per SPEC.md section 4.
/// Also triggers Otter Outputs folder creation on the `done` transition,
/// since both need the same "previous state per session_id" bookkeeping.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var previousStates: [String: SessionState] = [:]
    private var storeObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("NotchOtter: notification authorization error: \(error)")
            }
        }

        // Seed with whatever is already on disk so we don't re-fire for
        // sessions that were already in a terminal/waiting state at launch.
        for record in SessionStore.shared.allRecords {
            previousStates[record.session.sessionID] = record.session.state
        }

        storeObserver = NotificationCenter.default.addObserver(
            forName: .sessionStoreDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let store = note.object as? SessionStore else { return }
            self?.processUpdate(store: store)
        }
    }

    private func processUpdate(store: SessionStore) {
        var seenIDs = Set<String>()

        for record in store.allRecords {
            let id = record.session.sessionID
            seenIDs.insert(id)
            let newState = record.session.state
            let oldState = previousStates[id]

            if oldState != newState {
                switch newState {
                case .waitingPermission, .done, .error:
                    fireNotification(for: record)
                default:
                    break
                }
                if newState == .done && oldState != .done {
                    OutputsManager.handleDoneTransition(for: record.session)
                }
            }

            previousStates[id] = newState
        }

        // Sessions that vanished (SessionEnd, or stale cleanup) drop out of
        // transition tracking so a reused session_id starts fresh.
        let goneIDs = Set(previousStates.keys).subtracting(seenIDs)
        for id in goneIDs {
            previousStates.removeValue(forKey: id)
        }
    }

    private func fireNotification(for record: SessionRecord) {
        let content = UNMutableNotificationContent()
        let project = record.session.project

        switch record.session.state {
        case .waitingPermission:
            content.title = "\(project) needs your approval"
            content.body = "Claude Code is waiting on a permission prompt."
        case .done:
            let count = record.session.outputs.count
            content.title = "\(project) finished"
            content.body = count > 0 ? "\(count) file\(count == 1 ? "" : "s") changed." : "Session complete."
        case .error:
            content.title = "\(project) hit repeated errors"
            content.body = "3 or more consecutive tool failures."
        default:
            return
        }

        content.sound = .default
        content.userInfo = ["session_id": record.session.sessionID]

        let request = UNNotificationRequest(
            identifier: "\(record.session.sessionID)-\(record.session.state.rawValue)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NotchOtter: failed to deliver notification: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionID = response.notification.request.content.userInfo["session_id"] as? String,
           let record = SessionStore.shared.record(forSessionID: sessionID) {
            TerminalFocusDispatcher.focus(cwd: record.session.cwd)
        }
        completionHandler()
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: app/Sources/NotchOtter/OutputsManager.swift ⟧⟧⟧
import Foundation

/// Handles the "Otter Outputs" folder created on a session's transition to
/// `done`, per SPEC.md section 5: symlinks to every output path that still
/// exists, collected under `~/Desktop/Otter Outputs/<YYYY-MM-DD>-<project>/`.
enum OutputsManager {
    static func handleDoneTransition(for session: Session) {
        guard !session.outputs.isEmpty else { return }

        let folder = destinationFolder(for: session, on: session.updatedAt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("NotchOtter: failed to create outputs folder \(folder.path): \(error)")
            return
        }

        for outputPath in session.outputs {
            let sourceURL = URL(fileURLWithPath: outputPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                continue // Skip dead paths per SPEC.
            }
            let linkURL = folder.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
            } catch {
                // Symlink already exists (e.g. duplicate basenames, re-run) --
                // ignore per SPEC, don't fail the whole batch.
                continue
            }
        }
    }

    private static func destinationFolder(for session: Session, on date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: date)

        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop
            .appendingPathComponent("Otter Outputs")
            .appendingPathComponent("\(dateString)-\(session.project)")
    }
}

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: scripts/build_app.sh ⟧⟧⟧
#!/usr/bin/env bash
# Builds NotchOtter with SPM, then assembles and ad-hoc codesigns a proper
# .app bundle at dist/NotchOtter.app. Xcode is not required (CommandLineTools
# `swift build` only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/app"
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/NotchOtter.app"
SPRITES_SRC="$REPO_ROOT/assets/sprites/chatgpt"
BUNDLE_ID="com.minje.notchotter"
BUILD_CONFIG="${1:-release}"

echo "==> Building NotchOtter ($BUILD_CONFIG configuration)"
(cd "$APP_DIR" && swift build -c "$BUILD_CONFIG")

BIN_PATH="$(cd "$APP_DIR" && swift build -c "$BUILD_CONFIG" --show-bin-path)/NotchOtter"

if [ ! -x "$BIN_PATH" ]; then
  echo "error: could not locate built NotchOtter binary at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources/sprites"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/NotchOtter"
chmod +x "$APP_BUNDLE/Contents/MacOS/NotchOtter"

if [ -d "$SPRITES_SRC" ]; then
  cp -R "$SPRITES_SRC"/* "$APP_BUNDLE/Contents/Resources/sprites/"
else
  echo "error: sprite source directory not found: $SPRITES_SRC" >&2
  exit 1
fi

echo "==> Building app icon"
ICON_SRC="$REPO_ROOT/assets/icon/AppIcon.png"
if [ ! -f "$ICON_SRC" ]; then
  swift "$REPO_ROOT/scripts/gen-icon.swift" "$SPRITES_SRC/idle.png" "$ICON_SRC"
fi
ICONSET="$DIST_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z "$d" "$d" "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>NotchOtter</string>
    <key>CFBundleDisplayName</key>
    <string>NotchOtter</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>NotchOtter</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSUserNotificationUsageDescription</key>
    <string>NotchOtter shows a notification when a Claude Code session needs your approval, finishes, or hits repeated errors.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>NotchOtter uses AppleScript to focus the matching Ghostty terminal window when you click a session.</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc codesigning"
codesign -s - --force --deep "$APP_BUNDLE"

echo "==> Verifying signature"
codesign -v "$APP_BUNDLE"

echo "==> Installing to /Applications"
osascript -e 'quit app "NotchOtter"' 2>/dev/null || true
sleep 1
rm -rf "/Applications/NotchOtter.app"
cp -R "$APP_BUNDLE" "/Applications/NotchOtter.app"

echo "==> Done: /Applications/NotchOtter.app"

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: scripts/gen-icon.swift ⟧⟧⟧
// Generates AppIcon.png (1024x1024) for NotchOtter: dark navy squircle in
// the shared app family, with the first otter sprite frame centered on it.
// Run: swift scripts/gen-icon.swift <sprite-sheet.png> <out.png>
import AppKit

let args = CommandLine.arguments
let spritePath = args.count > 1 ? args[1] : "assets/sprites/chatgpt/idle.png"
let out = args.count > 2 ? args[2] : "AppIcon.png"

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Background squircle, same family as the other apps (dark navy gradient).
let inset = size * 0.05
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)
NSGradient(colors: [
    NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.10, alpha: 1),
])!.draw(in: path, angle: -90)

// Crop the first frame out of the horizontal sprite sheet.
guard let sheet = NSImage(contentsOfFile: spritePath),
      let tiff = sheet.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    fatalError("Could not load sprite sheet at \(spritePath)")
}
let sheetW = CGFloat(rep.pixelsWide)
let sheetH = CGFloat(rep.pixelsHigh)
let frameW = sheetW / 3.0            // three frames side by side
let frameRect = CGRect(x: 0, y: 0, width: frameW, height: sheetH)
guard let cg = rep.cgImage?.cropping(to: frameRect) else {
    fatalError("Could not crop sprite frame")
}
let frame = NSImage(cgImage: cg, size: NSSize(width: frameW, height: sheetH))

// Draw the otter centered, scaled to ~62% of the icon, nearest-neighbor so
// the pixel art stays crisp.
NSGraphicsContext.current?.imageInterpolation = .none
let target = size * 0.62
let aspect = frameW / sheetH
let drawW = target * aspect
let drawH = target
let drawRect = NSRect(x: (size - drawW) / 2, y: (size - drawH) / 2 - size * 0.02,
                      width: drawW, height: drawH)
frame.draw(in: drawRect)

image.unlockFocus()
guard let outTiff = image.tiffRepresentation,
      let outRep = NSBitmapImageRep(data: outTiff),
      let png = outRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: spritegen/gen_sprites.py ⟧⟧⟧
#!/usr/bin/env python3
"""Procedural pixel-art otter sprite sheet generator for NotchOtter.

Every frame is a hand-authored 32x32 character grid (list-of-strings /
list-of-lists mapped through a palette dict), NOT drawn with vector
ellipse/rect primitives -- those look mushy at this resolution. Ovals used
for the head/body/tail are built by `oval_rows()`, which fills explicit
per-row half-widths (a classic pixel-art circle technique: each row is a
horizontal band with hand-picked width, giving a crisp "staircase" outline
instead of an anti-aliased blob). Small asymmetric features (eyes, nose,
paws, tail, props) are then stamped on top at fixed coordinates.

Usage:
    python3 spritegen/gen_sprites.py

Regenerates every sprite sheet in assets/sprites/<variant>/<state>.png and
the two comparison images in assets/previews/. See spritegen/README.md for
how frame counts are encoded (sheet width / 32 = frame count, per SPEC.md).
"""

import os

from PIL import Image, ImageDraw, ImageFont

CELL = 32
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
SPRITES_DIR = os.path.join(REPO_ROOT, "assets", "sprites")
PREVIEWS_DIR = os.path.join(REPO_ROOT, "assets", "previews")

STATES = [
    "idle",
    "working",
    "waiting_permission",
    "waiting_input",
    "done",
    "error",
    "stale",
]

FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"


def font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default()


# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------

def build_palette(ghost=False):
    """Char -> RGBA. `ghost=True` gives the pale translucent 'stale' look."""
    p = {
        ".": None,                     # transparent
        "O": (55, 34, 20, 255),        # outline - dark brown
        "B": (150, 98, 56, 255),       # body fur - warm brown
        "D": (120, 76, 42, 255),       # shading - darker brown
        "C": (245, 227, 194, 255),     # cream muzzle / belly
        "c": (221, 198, 160, 255),     # cream shading (patch outline)
        "K": (26, 20, 16, 255),        # eye black
        "W": (255, 255, 255, 255),     # eye highlight
        "N": (40, 26, 20, 255),        # nose
        "P": (222, 148, 138, 255),     # inner ear / mouth pink
        "S": (223, 232, 235, 255),     # clam shell (cool gray-blue, pops off fur)
        "T": (163, 180, 186, 255),     # clam shell shadow line
        "R": (214, 58, 58, 255),       # error X
        "!": (247, 197, 55, 255),      # exclaim mark / sparkle gold
        "u": (255, 255, 255, 235),     # bubble fill (white)
        "g": (70, 55, 40, 235),        # bubble outline
        "L": (215, 217, 222, 255),     # laptop chassis (cool light gray)
        "l": (146, 149, 156, 255),     # laptop chassis shadow / underside
        "E": (38, 40, 46, 255),        # laptop screen bezel (near-black)
        "U": (88, 168, 224, 255),      # laptop screen glow (blue)
        "V": (156, 214, 255, 255),     # laptop screen glow, bright flicker frame
        "H": (103, 65, 40, 255),       # sea otter: dark chocolate body/back fur
        "Y": (78, 48, 29, 255),        # sea otter: chocolate shading (tail/ear)
        "q": (140, 202, 232, 190),     # sea otter: water line accent (translucent)
    }
    if not ghost:
        return p
    ghost_map = {}
    for k, v in p.items():
        if v is None:
            ghost_map[k] = None
            continue
        r, g, b, a = v
        r = int(r + (232 - r) * 0.6)
        g = int(g + (238 - g) * 0.6)
        b = int(b + (245 - b) * 0.6)
        ghost_map[k] = (r, g, b, 145)
    return ghost_map


# ---------------------------------------------------------------------------
# Grid helpers
# ---------------------------------------------------------------------------

def new_grid(w=CELL, h=CELL):
    return [["." for _ in range(w)] for _ in range(h)]


def stamp(grid, rows, top, left):
    """Draw `rows` (list[str]) onto `grid` at (top, left). '.' = skip."""
    h, w = len(grid), len(grid[0])
    for r, row in enumerate(rows):
        gr = top + r
        if not (0 <= gr < h):
            continue
        for c, ch in enumerate(row):
            if ch == ".":
                continue
            gc = left + c
            if 0 <= gc < w:
                grid[gr][gc] = ch


def oval_rows(half_widths, fill="B", outline="O"):
    """Hand-authored circle/oval technique: one explicit half-width per row.

    Each row is filled center +/- half_width with `fill`, edges marked
    `outline`. Produces a crisp pixel-art "staircase" silhouette.
    """
    maxw = max(half_widths)
    width = maxw * 2 + 1
    center = maxw
    rows = []
    for hw in half_widths:
        row = ["."] * width
        if hw <= 0:
            row[center] = outline
        else:
            for c in range(center - hw, center + hw + 1):
                row[c] = fill
            row[center - hw] = outline
            row[center + hw] = outline
        rows.append("".join(row))
    return rows


def render(grid, palette):
    img = Image.new("RGBA", (len(grid[0]), len(grid)), (0, 0, 0, 0))
    px = img.load()
    for r, row in enumerate(grid):
        for c, ch in enumerate(row):
            color = palette.get(ch)
            if color:
                px[c, r] = color
    return img


def sheet_from_frames(frames, palette):
    n = len(frames)
    sheet = Image.new("RGBA", (CELL * n, CELL), (0, 0, 0, 0))
    for i, grid in enumerate(frames):
        sheet.paste(render(grid, palette), (i * CELL, 0))
    return sheet


def upscale_nn(img, factor):
    return img.resize((img.width * factor, img.height * factor), Image.NEAREST)


# ---------------------------------------------------------------------------
# Shared building blocks (used across variant A poses)
# ---------------------------------------------------------------------------

CLAM = [
    ".TTT.",
    "TSSST",
    "STTTS",
]

BUBBLE = [
    ".ggg.",
    "gu!ug",
    "gu!ug",
    "guuug",
    "gu!ug",
    "..g..",
]


SPARKLE = [
    ".!.",
    "!!!",
    ".!.",
]

DIZZY = [
    "O.O",
    ".O.",
]

# Small open laptop: upright glowing screen + flat keyboard deck, sat in
# front of the belly. Kept a distinct cool gray/blue palette (L/l/E/U) so
# it never blends into the warm-brown fur silhouette behind it.
LAPTOP = [
    "..EEEEEEE..",
    ".EUUUUUUUE.",
    ".EUUUUUUUE.",
    ".EEEEEEEEE.",
    "LLLLLLLLLLL",
    "LLLLLLLLLLL",
    "lllllllllll",
]

LAPTOP_FLICKER = [
    "..EEEEEEE..",
    ".EVVVVVVVE.",
    ".EVVVVVVVE.",
    ".EEEEEEEEE.",
    "LLLLLLLLLLL",
    "LLLLLLLLLLL",
    "lllllllllll",
]

# These (medium-brown "B"/"O" fill) are used by variants B and C, which
# still use the old single-brown palette -- kept here even though variant
# A's sea-otter redesign below uses its own chocolate "H" shapes instead.
EAR = [
    ".OO.",
    "OPPO",
    "OBBO",
]

TAIL_RIGHT = [
    ".OO....",
    "OBBO...",
    "OBBBO..",
    ".OBBBO.",
    "..OBBBO",
    "..OBBBO",
    "...OBBO",
    "....OBO",
    "....OO.",
]

PAW_DOWN = [
    "OO",
    "BB",
    "OO",
]

PAW_UP = [
    "OO",
    "BB",
]

WAVE_PAW = [
    ".OOO.",
    "OBBBO",
    "OBBBO",
    ".OOO.",
]


# ---------------------------------------------------------------------------
# Variant A: SEA OTTER floating on its back -- all 7 states
# ---------------------------------------------------------------------------
# Sea otters float belly-up and use their chest as a table -- that's the
# whole pose language here, replacing the old sitting-chibi. The identity
# markers that must read at a glance: a pale cream/gray face ("C"/"c")
# against a dark chocolate body ("H"/"O"), tiny low-set ears, and a
# horizontal on-back silhouette using the full 32px width. Head sits at the
# left, body/belly extend right, tail at the far right -- same head-then-
# body overlap technique proven in variant B, just recolored and widened.

# Head made a touch bigger/rounder (10 rows, maxhw 7) -- the face is the
# cuteness anchor and was too small next to the long body. Belly shrunk to
# a small oval (5 rows, maxhw 4) AND, critically, moved clearly clear of
# the head's own right edge (head's widest rows reach col 14) so a solid
# band of dark chocolate separates the pale face from the pale belly --
# without that gap the two pale regions visually fuse into one big pale
# mass and the "dark body" read disappears even though the belly itself
# is small. That's what was wrong the first time: belly left was 13,
# inside the head's own footprint, touching/overlapping it directly.
SEA_HEAD_HALFW = [2, 4, 6, 7, 7, 7, 7, 6, 4, 2]     # 10 rows, maxhw 7 -> width 15
SEA_BODY_HALFW = [5, 9, 11, 12, 12, 12, 11, 9, 5]   # 9 rows, maxhw 12 -> width 25
SEA_BELLY_HALFW = [2, 4, 4, 3, 2]                   # 5 rows, maxhw 4 -> width 9

SEA_HEAD_TOP, SEA_HEAD_LEFT = 8, 0
SEA_BODY_TOP, SEA_BODY_LEFT = 11, 6
SEA_BELLY_TOP, SEA_BELLY_LEFT = 12, 17
SEA_TAIL_TOP, SEA_TAIL_LEFT = 13, 26
SEA_WATERLINE_ROW = 20

SEA_EAR = [
    "HH",
    "OO",
]

SEA_TAIL = [
    "..OOO..",
    ".OHHHO.",
    "OHHHHHO",
    "OHHHHHO",
    ".OHHHO.",
    "..OOO..",
]

# Small folded paw (rests flat on the belly) vs the big rounded paw used
# whenever a limb needs to read clearly away from the body (typing,
# waving, holding, splayed) -- chocolate "H" fill so it always matches the
# body rather than the old medium-brown "B" used by variants B/C.
SEA_PAW_SMALL = [
    "OO",
    "HH",
]

SEA_PAW_BIG = [
    ".OOO.",
    "OHHHO",
    "OHHHO",
    ".OOO.",
]

SEA_EYE_OPEN = ["KW", "KK"]
SEA_EYE_CLOSED = ["OO"]
SEA_EYE_WIDE = [".K.", "KWK", "KKK"]
SEA_EYE_X = ["R.R", ".R.", "R.R"]
# Lowered lids, cast down toward the laptop -- reads as concentration
# rather than the fully-shut "closed" style, which looks like napping.
SEA_EYE_FOCUS = ["OO", "KK"]


def add_sea_body(grid, dy=0):
    rows = oval_rows(SEA_BODY_HALFW, fill="H", outline="O")
    stamp(grid, rows, SEA_BODY_TOP + dy, SEA_BODY_LEFT)


def add_sea_tail(grid, dy=0):
    stamp(grid, SEA_TAIL, SEA_TAIL_TOP + dy, SEA_TAIL_LEFT)


def add_sea_belly(grid, dy=0):
    rows = oval_rows(SEA_BELLY_HALFW, fill="C", outline="c")
    stamp(grid, rows, SEA_BELLY_TOP + dy, SEA_BELLY_LEFT)


def add_sea_head(grid, dy=0, dx=0):
    # Pale face oval stamped AFTER the body so the face silhouette always
    # wins in the head/body overlap -- the pale/dark contrast is the whole
    # point, so the face must never get eaten by the darker torso.
    rows = oval_rows(SEA_HEAD_HALFW, fill="C", outline="c")
    stamp(grid, rows, SEA_HEAD_TOP + dy, SEA_HEAD_LEFT + dx)


def add_sea_ears(grid, dy=0, dx=0):
    # Tiny, low on the head (near the lower edge of the face oval), not
    # tall nubs on top like a land otter -- that low placement is one of
    # the sea-otter identity cues called out in the brief.
    stamp(grid, SEA_EAR, 15 + dy, 1 + dx)
    stamp(grid, SEA_EAR, 15 + dy, 11 + dx)


def add_sea_face(grid, style="open", dy=0, dx=0):
    row = 11 + dy
    lcol, rcol = 3 + dx, 10 + dx
    if style == "open":
        stamp(grid, SEA_EYE_OPEN, row, lcol)
        stamp(grid, SEA_EYE_OPEN, row, rcol)
    elif style == "closed":
        stamp(grid, SEA_EYE_CLOSED, row + 1, lcol)
        stamp(grid, SEA_EYE_CLOSED, row + 1, rcol)
    elif style == "focus":
        stamp(grid, SEA_EYE_FOCUS, row + 1, lcol)
        stamp(grid, SEA_EYE_FOCUS, row + 1, rcol)
    elif style == "wide":
        stamp(grid, SEA_EYE_WIDE, row - 1, lcol - 1)
        stamp(grid, SEA_EYE_WIDE, row - 1, rcol - 1)
    elif style == "x":
        stamp(grid, SEA_EYE_X, row, lcol)
        stamp(grid, SEA_EYE_X, row, rcol)
    nose_row = 14 + dy
    grid[nose_row][7 + dx] = "N"
    # a couple of whisker dashes per cheek, if they still land inside the
    # face oval after a head-turn dx shift
    if 0 <= dx + 1 < 32:
        grid[13 + dy][1 + dx] = "O"
    if 0 <= dx + 13 < 32:
        grid[13 + dy][13 + dx] = "O"


def add_sea_waterline(grid, dy=0):
    # Subtle floating-in-water accent -- translucent so it still reads
    # (rather than vanishing) on a pure black background.
    row = SEA_WATERLINE_ROW + dy
    if not (0 <= row < 32):
        return
    for c in (9, 13, 17, 21, 25):
        grid[row][c] = "q"


def sea_base(dy=0, eye="open", dx=0, waterline=True):
    """The common floating-on-back pose shared by idle/working/waiting."""
    g = new_grid()
    add_sea_body(g, dy=dy)
    add_sea_tail(g, dy=dy)
    add_sea_head(g, dy=dy, dx=dx)
    add_sea_ears(g, dy=dy, dx=dx)
    add_sea_belly(g, dy=dy)
    add_sea_face(g, style=eye, dy=dy, dx=dx)
    if waterline:
        add_sea_waterline(g, dy=dy)
    return g


def add_folded_paws(grid, dy=0):
    stamp(grid, SEA_PAW_SMALL, 14 + dy, 20)
    stamp(grid, SEA_PAW_SMALL, 14 + dy, 25)


def variant_a_idle():
    f1 = sea_base(dy=0, eye="open")
    add_folded_paws(f1, dy=0)

    f2 = sea_base(dy=-1, eye="open")
    add_folded_paws(f2, dy=-1)

    f3 = sea_base(dy=0, eye="closed")
    add_folded_paws(f3, dy=0)
    return [f1, f2, f3]


# Laptop rests on the belly (the pale "table" patch), keyboard deck low
# enough that the typing paws mostly hang in the open canvas below the
# body (nothing else is drawn past row 20) rather than inside the laptop's
# own small detail pixels -- that's what made the paws finally read as
# paws instead of keyboard noise in the previous redesign round.
SEA_LAPTOP_TOP, SEA_LAPTOP_LEFT = 13, 17
SEA_KEY_L_COL, SEA_KEY_R_COL = 17, 24
SEA_PAW_LIFT_ROW = SEA_LAPTOP_TOP + 5
SEA_PAW_CONTACT_ROW = SEA_LAPTOP_TOP + 6
SEA_PAW_LIFT_SHIFT = 3


def add_sea_laptop(grid, flicker=False):
    stamp(grid, LAPTOP_FLICKER if flicker else LAPTOP, SEA_LAPTOP_TOP, SEA_LAPTOP_LEFT)


def add_sea_typing_paws(grid, left_down, spark=None):
    l_row = SEA_PAW_CONTACT_ROW if left_down else SEA_PAW_LIFT_ROW
    r_row = SEA_PAW_LIFT_ROW if left_down else SEA_PAW_CONTACT_ROW
    l_col = SEA_KEY_L_COL if left_down else SEA_KEY_L_COL - SEA_PAW_LIFT_SHIFT
    r_col = SEA_KEY_R_COL if not left_down else SEA_KEY_R_COL + SEA_PAW_LIFT_SHIFT
    stamp(grid, SEA_PAW_BIG, l_row, l_col)
    stamp(grid, SEA_PAW_BIG, r_row, r_col)
    if spark == "left":
        grid[l_row - 1][l_col + 1] = "W"
        grid[l_row - 1][l_col + 2] = "W"
    elif spark == "right":
        grid[r_row - 1][r_col + 1] = "W"
        grid[r_row - 1][r_col + 2] = "W"


def variant_a_working():
    # On its back, laptop propped on the belly, head tipped down toward
    # the screen. Paws alternate contact/lift on the keys, with a "clack"
    # spark and a screen-brightness flicker so the motion is unmistakable.
    frames = []
    steps = [
        dict(left_down=True, spark="left", flicker=False),
        dict(left_down=False, spark=None, flicker=True),
        dict(left_down=True, spark="left", flicker=False),
        dict(left_down=False, spark="right", flicker=False),
    ]
    for step in steps:
        g = sea_base(dy=0, eye="focus", waterline=False)
        add_sea_laptop(g, flicker=step["flicker"])
        add_sea_typing_paws(g, left_down=step["left_down"], spark=step["spark"])
        frames.append(g)
    return frames


def variant_a_waiting_permission():
    frames = []
    for raised in (True, False):
        g = sea_base(dy=0, eye="open")
        stamp(g, SEA_PAW_SMALL, 14, 20)
        if raised:
            stamp(g, SEA_PAW_BIG, 2, 2)
            stamp(g, BUBBLE, 0, 9)
        else:
            stamp(g, SEA_PAW_SMALL, 14, 25)
        frames.append(g)
    return frames


def variant_a_waiting_input():
    f1 = sea_base(dy=0, eye="open", dx=0)
    add_folded_paws(f1, dy=0)

    f2 = sea_base(dy=0, eye="wide", dx=2)
    add_folded_paws(f2, dy=0)

    f3 = sea_base(dy=0, eye="closed", dx=0)
    add_folded_paws(f3, dy=0)
    return [f1, f2, f3]


def variant_a_done():
    frames = []
    for i in range(3):
        g = sea_base(dy=0, eye="wide")
        # Paws flank the clam tightly at the same height, close enough
        # (small gaps, not floating far apart) to read as gripping it, and
        # the whole cluster sits close above the head instead of stranded
        # high up with a big empty gap in between.
        stamp(g, SEA_PAW_BIG, 5, 4)
        stamp(g, SEA_PAW_BIG, 5, 20)
        stamp(g, CLAM, 6, 12)
        if i in (0, 2):
            stamp(g, SPARKLE, 0, 0)
            stamp(g, SPARKLE, 4, 29)
        else:
            stamp(g, SPARKLE, 4, 0)
            stamp(g, SPARKLE, 0, 29)
        frames.append(g)
    return frames


def sea_distressed_pose(dx=0):
    """Still floating on its back, but distressed: X eyes, paws flung out
    away from the belly, small dizzy flicks above the head."""
    g = sea_base(dy=0, eye="x", dx=dx, waterline=False)
    stamp(g, SEA_PAW_BIG, 2, 1 + dx)
    stamp(g, SEA_PAW_BIG, 2, 23 + dx)
    stamp(g, DIZZY, 5, 3 + dx)
    stamp(g, DIZZY, 5, 9 + dx)
    return g


def variant_a_error():
    # small side-to-side shake between the two frames sells "distressed".
    f1 = sea_distressed_pose(dx=0)
    f2 = sea_distressed_pose(dx=1)
    return [f1, f2]


def variant_a_stale():
    f1 = sea_base(dy=0, eye="closed")
    add_folded_paws(f1, dy=0)
    f2 = sea_base(dy=-1, eye="closed")
    add_folded_paws(f2, dy=-1)
    return [f1, f2]


VARIANT_A_BUILDERS = {
    "idle": variant_a_idle,
    "working": variant_a_working,
    "waiting_permission": variant_a_waiting_permission,
    "waiting_input": variant_a_waiting_input,
    "done": variant_a_done,
    "error": variant_a_error,
    "stale": variant_a_stale,
}


# ---------------------------------------------------------------------------
# Variant B: classic long-body otter, lying horizontally (idle + waiting only)
# ---------------------------------------------------------------------------

# Wide, mostly-flat half-widths (only the two end rows taper) so the oval
# reads as a long horizontal capsule instead of a round blob.
B_BODY_HALFW = [6, 10, 12, 12, 12, 12, 10, 6]
B_HEAD_HALFW = [2, 4, 5, 5, 5, 4, 2]

B_TAIL = [
    ".OOO...",
    "OBBBBO.",
    "OBBBBBO",
    "OBBBBBO",
    "OBBBBO.",
    ".OOO...",
]

B_EAR = [".OO.", "OPPO", "OBBO"]


def b_base(dy=0, eye="open"):
    g = new_grid()
    # body: long flat capsule, the spine of the "lying down" pose.
    body_rows = oval_rows(B_BODY_HALFW, fill="B", outline="O")
    stamp(g, body_rows, 13 + dy, 6)
    # tail continues the body's right end, tapering off past the canvas edge.
    stamp(g, B_TAIL, 15 + dy, 25)
    # head overlaps the body's left bulge so neck reads as one silhouette.
    stamp(g, B_EAR, 9 + dy, 2)
    head_rows = oval_rows(B_HEAD_HALFW, fill="B", outline="O")
    stamp(g, head_rows, 11 + dy, 0)
    muzzle = oval_rows([2, 3, 3, 2], fill="C", outline="c")
    stamp(g, muzzle, 14 + dy, 2)
    g[16 + dy][6] = "N"
    if eye == "open":
        stamp(g, ["KW", "KK"], 13 + dy, 4)
    else:
        stamp(g, ["OO"], 14 + dy, 4)
    # belly patch along the body's underside
    belly = oval_rows([2, 4, 5, 5, 4, 2], fill="C", outline="c")
    stamp(g, belly, 17 + dy, 11)
    # little paws tucked underneath
    stamp(g, ["OO", "BB"], 20 + dy, 10)
    stamp(g, ["OO", "BB"], 20 + dy, 20)
    return g


def variant_b_idle():
    f1 = b_base(dy=0, eye="open")
    f2 = b_base(dy=1, eye="open")
    f3 = b_base(dy=0, eye="closed")
    return [f1, f2, f3]


def variant_b_waiting_permission():
    frames = []
    for raised in (True, False):
        g = b_base(dy=0, eye="open")
        if raised:
            stamp(g, WAVE_PAW, 6, 11)
            stamp(g, BUBBLE, 0, 15)
        else:
            stamp(g, ["OO", "BB"], 12, 11)
        frames.append(g)
    return frames


VARIANT_B_BUILDERS = {
    "idle": variant_b_idle,
    "waiting_permission": variant_b_waiting_permission,
}


# ---------------------------------------------------------------------------
# Variant C: tiny minimal style -- same oval-silhouette technique as variant
# A, but with chunky stepped half-widths (fewer, bigger jumps -> a more
# faceted/blocky look) and flat colors (no cream-shading ring, no whiskers),
# evoking a simplified 16x16 sprite blown up to 32x32.
# ---------------------------------------------------------------------------

C_HEAD_HALFW = [5, 5, 9, 9, 9, 9, 9, 5, 5]
C_BODY_HALFW = [7, 7, 10, 10, 10, 7, 7]
C_EYE = ["KK", "KK"]
C_EYE_CLOSED = ["OO"]


def c_base(eye="open", dy=0):
    g = new_grid()
    stamp(g, TAIL_RIGHT, 16 + dy, 23)
    stamp(g, EAR, 4 + dy, 8)
    stamp(g, EAR, 4 + dy, 20)
    head_rows = oval_rows(C_HEAD_HALFW, fill="B", outline="O")
    stamp(g, head_rows, 7 + dy, 7)  # head: rows 7-15
    body_rows = oval_rows(C_BODY_HALFW, fill="B", outline="O")
    stamp(g, body_rows, 15 + dy, 6)  # body: rows 15-21, overlaps head row 15
    # flat cream muzzle + belly blocks (no shading ring -- keeps it "flat").
    stamp(g, ["CCCCC"] * 3, 12 + dy, 14)
    stamp(g, ["CCCCCCC"] * 3, 17 + dy, 13)
    if eye == "open":
        stamp(g, C_EYE, 10 + dy, 11)
        stamp(g, C_EYE, 10 + dy, 19)
    else:
        stamp(g, C_EYE_CLOSED, 11 + dy, 11)
        stamp(g, C_EYE_CLOSED, 11 + dy, 19)
    g[14 + dy][16] = "N"
    g[15 + dy][15] = "P"
    g[15 + dy][17] = "P"
    stamp(g, PAW_DOWN, 20 + dy, 9)
    stamp(g, PAW_DOWN, 20 + dy, 21)
    return g


def variant_c_idle():
    return [c_base(eye="open", dy=0), c_base(eye="open", dy=-1), c_base(eye="closed", dy=0)]


def variant_c_waiting_permission():
    frames = []
    for raised in (True, False):
        g = c_base(eye="open")
        if raised:
            stamp(g, WAVE_PAW, 8, 27)
            stamp(g, BUBBLE, 0, 26)
        else:
            stamp(g, PAW_DOWN, 20, 21)
        frames.append(g)
    return frames


VARIANT_C_BUILDERS = {
    "idle": variant_c_idle,
    "waiting_permission": variant_c_waiting_permission,
}


VARIANTS = {
    "A": VARIANT_A_BUILDERS,
    "B": VARIANT_B_BUILDERS,
    "C": VARIANT_C_BUILDERS,
}


# ---------------------------------------------------------------------------
# Build + save
# ---------------------------------------------------------------------------

def build_all():
    saved = {}
    for variant, builders in VARIANTS.items():
        out_dir = os.path.join(SPRITES_DIR, variant)
        os.makedirs(out_dir, exist_ok=True)
        saved[variant] = {}
        for state, builder in builders.items():
            frames = builder()
            ghost = state == "stale"
            palette = build_palette(ghost=ghost)
            sheet = sheet_from_frames(frames, palette)
            path = os.path.join(out_dir, f"{state}.png")
            sheet.save(path)
            saved[variant][state] = (path, len(frames))
    return saved


# ---------------------------------------------------------------------------
# Previews
# ---------------------------------------------------------------------------

def label(draw, xy, text, size=20, fill=(255, 255, 255, 255)):
    draw.text(xy, text, font=font(size), fill=fill)


def build_variants_preview(saved):
    scale = 8
    cell_px = CELL * scale
    pad = 24
    label_h = 40
    strip_h = cell_px + label_h
    total_w = pad + 3 * (cell_px + pad)
    total_h = pad + strip_h + pad + strip_h + pad

    canvas = Image.new("RGB", (total_w, total_h), (30, 30, 30))
    draw = ImageDraw.Draw(canvas)

    # black strip (notch simulation) on top, light strip below
    black_y = pad
    light_y = pad + strip_h + pad
    draw.rectangle([0, black_y - 4, total_w, black_y + strip_h + 4], fill=(0, 0, 0))
    draw.rectangle([0, light_y - 4, total_w, light_y + strip_h + 4], fill=(232, 232, 228))

    variant_names = {"A": "A - sea otter", "B": "B - long body", "C": "C - tiny 16x16"}
    for i, variant in enumerate(("A", "B", "C")):
        idle_path = saved[variant]["idle"][0]
        sheet = Image.open(idle_path).convert("RGBA")
        first_frame = sheet.crop((0, 0, CELL, CELL))
        big = upscale_nn(first_frame, scale)

        x = pad + i * (cell_px + pad)

        canvas.paste(big, (x, black_y), big)
        label(draw, (x, black_y + cell_px + 4), variant_names[variant],
              size=20, fill=(255, 255, 255))

        canvas.paste(big, (x, light_y), big)
        label(draw, (x, light_y + cell_px + 4), variant_names[variant],
              size=20, fill=(20, 20, 20))

    label(draw, (pad, 2), "notch-otter sprite variants (idle frame 1, 8x nearest-neighbor)",
          size=16, fill=(255, 255, 255))

    out_path = os.path.join(PREVIEWS_DIR, "variants.png")
    canvas.save(out_path)
    return out_path


def build_variant_a_all_states_preview(saved):
    scale = 8
    cell_px = CELL * scale
    pad = 20
    label_h = 28
    cols = 4
    rows = 2
    cell_w = cell_px * 4 + pad  # up to 4 frames wide per state
    cell_h = cell_px + label_h + pad

    total_w = pad + cols * cell_w
    total_h = pad + rows * cell_h + 40

    canvas = Image.new("RGB", (total_w, total_h), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    label(draw, (pad, 6), "notch-otter variant A - all 7 states (8x, on black)",
          size=18, fill=(255, 255, 255))

    for idx, state in enumerate(STATES):
        r, c = divmod(idx, cols)
        x = pad + c * cell_w
        y = 40 + pad + r * cell_h

        path, nframes = saved["A"][state]
        sheet = Image.open(path).convert("RGBA")
        big = upscale_nn(sheet, scale)
        canvas.paste(big, (x, y), big)
        label(draw, (x, y + cell_px + 4), f"{state} ({nframes}f)",
              size=16, fill=(255, 255, 255))

    out_path = os.path.join(PREVIEWS_DIR, "variant_A_all_states.png")
    canvas.save(out_path)
    return out_path


def main():
    os.makedirs(SPRITES_DIR, exist_ok=True)
    os.makedirs(PREVIEWS_DIR, exist_ok=True)
    saved = build_all()

    for variant in sorted(saved):
        for state in sorted(saved[variant]):
            path, n = saved[variant][state]
            print(f"[{variant}] {state}: {n} frames -> {path}")

    vpath = build_variants_preview(saved)
    print(f"preview: {vpath}")
    apath = build_variant_a_all_states_preview(saved)
    print(f"preview: {apath}")


if __name__ == "__main__":
    main()

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: engine/install.sh ⟧⟧⟧
#!/bin/sh
# Installs the NotchOtter hook dispatcher into a Claude Code settings.json
# file, per SPEC.md section 2.
#
# Env overrides (for testing, never touch the real files unless intended):
#   OTTER_SETTINGS_FILE  - settings.json path (default: ~/.claude/settings.json)
#   OTTER_SHARE_DIR      - where otter-hook.sh is copied (default: ~/.local/share/notch-otter)

set -eu

JQ_BIN="/usr/bin/jq"
SETTINGS_FILE="${OTTER_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SHARE_DIR="${OTTER_SHARE_DIR:-$HOME/.local/share/notch-otter}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

EVENTS_JSON='["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PostToolUseFailure","Stop","Notification","SessionEnd"]'

# 1. Stage the dispatcher script.
mkdir -p "$SHARE_DIR"
cp "$SCRIPT_DIR/otter-hook.sh" "$SHARE_DIR/otter-hook.sh"
chmod +x "$SHARE_DIR/otter-hook.sh"
CMD="$SHARE_DIR/otter-hook.sh"

# 2. Load (or initialize) the settings file, validating it first.
mkdir -p "$(dirname "$SETTINGS_FILE")"

if [ -f "$SETTINGS_FILE" ]; then
  current=$(cat "$SETTINGS_FILE")
else
  current='{}'
fi

if ! printf '%s' "$current" | "$JQ_BIN" empty >/dev/null 2>&1; then
  echo "otter-install: $SETTINGS_FILE is not valid JSON, aborting without changes" >&2
  exit 1
fi

# 3. Back up the original settings file exactly once.
BACKUP="$SETTINGS_FILE.pre-otter.bak"
if [ -f "$SETTINGS_FILE" ] && [ ! -f "$BACKUP" ]; then
  cp "$SETTINGS_FILE" "$BACKUP"
fi

# 4. Merge our hooks in. For each of our events, strip any pre-existing
# notch-otter entries (idempotency / upgrade-in-place) then append a fresh
# one. Entries belonging to other tools are left untouched. Events we don't
# own are never read or written.
new=$(printf '%s' "$current" | "$JQ_BIN" \
  --arg cmd "$CMD" \
  --argjson events "$EVENTS_JSON" \
  '
  def strip_notch(arr):
    arr
    | map(.hooks = ((.hooks // []) | map(select((.command // "" | test("notch-otter")) | not))))
    | map(select((.hooks | length) > 0));

  def upsert_event(ev; cmd):
    (.[ev] // []) as $arr
    | (strip_notch($arr)) as $cleaned
    | .[ev] = ($cleaned + [{"hooks": [{"type": "command", "command": cmd, "async": true, "timeout": 10}]}]);

  (if has("hooks") then . else . + {hooks: {}} end)
  | .hooks = (
      .hooks
      | reduce $events[] as $ev (.; upsert_event($ev; $cmd))
    )
  ')

if ! printf '%s' "$new" | "$JQ_BIN" empty >/dev/null 2>&1; then
  echo "otter-install: generated settings JSON failed validation, aborting without changes" >&2
  exit 1
fi

# 5. Atomically replace the settings file.
tmp="$SETTINGS_FILE.tmp.$$"
printf '%s' "$new" | "$JQ_BIN" '.' > "$tmp"
mv "$tmp" "$SETTINGS_FILE"

echo "NotchOtter hooks installed into $SETTINGS_FILE"
echo "Dispatcher: $CMD"

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: engine/uninstall.sh ⟧⟧⟧
#!/bin/sh
# Removes the NotchOtter hook dispatcher from a Claude Code settings.json
# file, per SPEC.md section 2. Only removes entries whose command contains
# "notch-otter"; everything else in the settings file is left intact.
#
# Env overrides (for testing, never touch the real files unless intended):
#   OTTER_SETTINGS_FILE  - settings.json path (default: ~/.claude/settings.json)
#   OTTER_SHARE_DIR      - dispatcher install dir to remove (default: ~/.local/share/notch-otter)

set -eu

JQ_BIN="/usr/bin/jq"
SETTINGS_FILE="${OTTER_SETTINGS_FILE:-$HOME/.claude/settings.json}"
SHARE_DIR="${OTTER_SHARE_DIR:-$HOME/.local/share/notch-otter}"

if [ -f "$SETTINGS_FILE" ]; then
  current=$(cat "$SETTINGS_FILE")

  if ! printf '%s' "$current" | "$JQ_BIN" empty >/dev/null 2>&1; then
    echo "otter-uninstall: $SETTINGS_FILE is not valid JSON, aborting without changes" >&2
    exit 1
  fi

  new=$(printf '%s' "$current" | "$JQ_BIN" '
    if has("hooks") then
      .hooks = (
        .hooks
        | with_entries(
            .value |= (
              map(.hooks = ((.hooks // []) | map(select((.command // "" | test("notch-otter")) | not))))
              | map(select((.hooks | length) > 0))
            )
          )
        | with_entries(select((.value | length) > 0))
      )
    else
      .
    end
  ')

  if ! printf '%s' "$new" | "$JQ_BIN" empty >/dev/null 2>&1; then
    echo "otter-uninstall: generated settings JSON failed validation, aborting without changes" >&2
    exit 1
  fi

  tmp="$SETTINGS_FILE.tmp.$$"
  printf '%s' "$new" | "$JQ_BIN" '.' > "$tmp"
  mv "$tmp" "$SETTINGS_FILE"
  echo "NotchOtter hooks removed from $SETTINGS_FILE"
else
  echo "otter-uninstall: $SETTINGS_FILE not found, nothing to remove there" >&2
fi

rm -rf "$SHARE_DIR"
echo "Removed $SHARE_DIR"

⟦⟦⟦ END ⟧⟧⟧

⟦⟦⟦ FILE: engine/otter-hook.sh ⟧⟧⟧
#!/bin/sh
# NotchOtter hook dispatcher.
#
# Reads a single Claude Code hook JSON payload from stdin and updates the
# per-session state file described in SPEC.md section 1. This script is
# registered for every hook event NotchOtter cares about and branches on
# hook_event_name internally.
#
# Contract: this script must NEVER exit nonzero and must NEVER write to
# stderr during normal operation, even on malformed input. Any failure just
# means the state file is left as-is (or untouched) and we exit 0.

JQ_BIN="/usr/bin/jq"
STATE_DIR="${OTTER_STATE_DIR:-$HOME/.local/state/notch-otter/sessions}"

hook_json=$(cat 2>/dev/null)
if [ -z "$hook_json" ]; then
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null

session_id=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '.session_id // empty' 2>/dev/null)
if [ -z "$session_id" ]; then
  exit 0
fi

state_file="$STATE_DIR/$session_id.json"
tmp_file="$state_file.tmp.$$"

if [ -f "$state_file" ]; then
  existing_json=$(cat "$state_file" 2>/dev/null)
  if [ -z "$existing_json" ]; then
    existing_json='{}'
  fi
else
  existing_json='{}'
fi

# $PPID is the pid of the process that spawned this script, i.e. the claude
# process itself (per SPEC.md: "hook runs as child of claude").
ppid_val="${PPID:-0}"

# last_summary: a short single-line excerpt of the most recent assistant
# reply, shown in the desktop pet's hover bubble. Prefer the Notification
# payload's own message (it names the pending tool for permission prompts);
# otherwise pull the last assistant text block from the transcript tail.
# Truncation happens in jq (codepoint-safe for Korean), NOT via cut -c
# (bytes), which could split a UTF-8 sequence and corrupt the state file.
summary=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '
  if (.hook_event_name // "") == "Notification" and ((.message // "") != "")
  then .message else empty end
  | gsub("\\s+"; " ") | .[0:160]
' 2>/dev/null)
if [ -z "$summary" ]; then
  transcript_path=$(printf '%s' "$hook_json" | "$JQ_BIN" -r '.transcript_path // empty' 2>/dev/null)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Last assistant entry that actually HAS text -- during tool-call bursts
    # the newest assistant entries are often tool_use-only (no text blocks),
    # and those must not blank out the summary. The text is then cleaned
    # (code fences, markdown glyphs, links) and condensed: replies lead with
    # the outcome and end with the next step / question, so when the whole
    # reply doesn't fit, "first sentence … last sentence" beats a mid-word
    # cut at some fixed offset.
    summary=$(tail -n 60 "$transcript_path" 2>/dev/null | "$JQ_BIN" -rRs '
      split("\n")
      | map(fromjson? | select(.type == "assistant"))
      | map([.message.content[]? | select(.type == "text") | .text] | join(" "))
      | map(select(. != ""))
      | last // empty
      | gsub("```[\\s\\S]*?```"; " ")
      | gsub("\\[(?<t>[^\\]]*)\\]\\([^)]*\\)"; "\(.t)")
      | gsub("[*_#`~]"; "")
      | gsub("\\s+"; " ")
      | gsub("^\\s+|\\s+$"; "")
      | . as $t
      | [scan("[^.!?]+[.!?]*")] as $s
      | (if ($t | length) <= 200 then $t
         elif ($s | length) >= 2 then
           (($s[0] | gsub("^\\s+|\\s+$"; "")) + " … " + ($s[-1] | gsub("^\\s+|\\s+$"; "")))
         else $t end)
      | .[0:200]
    ' 2>/dev/null)
  fi
fi

# tty is backfilled once per session, same as pid: only shell out to ps when
# the existing state file doesn't already have a non-empty tty, so the
# (relatively expensive) ps call happens at most once per session lifetime.
existing_tty=$(printf '%s' "$existing_json" | "$JQ_BIN" -r '.tty // empty' 2>/dev/null)
new_tty=""
if [ -z "$existing_tty" ]; then
  new_tty=$(ps -o tty= -p "$ppid_val" 2>/dev/null | tr -d ' ')
  case "$new_tty" in
    '??'|'?') new_tty="" ;;
  esac
fi

merged=$(printf '%s' "$hook_json" | "$JQ_BIN" -c \
  --argjson existing "$existing_json" \
  --arg pid "$ppid_val" \
  --arg new_tty "$new_tty" \
  --arg summary "$summary" \
  '
  . as $in
  | ($in.hook_event_name // "") as $event
  | ($in.cwd // $existing.cwd // "") as $cwd
  | ($cwd | rtrimstr("/")) as $cwd_trimmed
  | (($cwd_trimmed | split("/") | last) // "") as $project0
  | (if ($project0 // "") == "" then "unknown" else $project0 end) as $project
  | ($in.session_id // $existing.session_id // "") as $sid
  | (now | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")) as $ts
  | ($existing.error_count // 0) as $prev_err
  | ($existing.outputs // []) as $prev_outputs
  # launch_cwd is captured once from the first event that creates the state
  # file and never overwritten afterward, even as cwd itself keeps changing.
  | (($existing.launch_cwd // "") ) as $prev_launch_cwd
  | (if $prev_launch_cwd != "" then $prev_launch_cwd else $cwd end) as $launch_cwd
  | (($existing.tty // "")) as $prev_tty
  | (if $prev_tty != "" then $prev_tty else $new_tty end) as $tty_final
  | (
      if $event == "SessionStart" then
        {
          state: "idle",
          pid: (($pid | tonumber?) // ($existing.pid // 0)),
          outputs: [],
          error_count: 0
        }
      elif $event == "UserPromptSubmit" or $event == "PreToolUse" then
        { state: "working" }
      elif $event == "PostToolUse" then
        ((($in.tool_name // "") == "Write") or (($in.tool_name // "") == "Edit")) as $is_output_tool
        | ($in.tool_input.file_path // "") as $fp
        | (
            if $is_output_tool and ($fp != "") then
              (if ($prev_outputs | index($fp)) then $prev_outputs else ($prev_outputs + [$fp]) end)
            else
              $prev_outputs
            end
          ) as $merged_outputs
        | ($merged_outputs | if length > 200 then .[-200:] else . end) as $capped
        | { state: "working", error_count: 0, outputs: $capped }
      elif $event == "PostToolUseFailure" then
        ($prev_err + 1) as $newerr
        | { state: (if $newerr >= 3 then "error" else "working" end), error_count: $newerr }
      elif $event == "Notification" then
        (
          if $in.notification_type == "permission_prompt" then "waiting_permission"
          elif $in.notification_type == "idle_prompt" then "waiting_input"
          else ($existing.state // "working")
          end
        ) as $st
        | { state: $st }
      elif $event == "Stop" then
        { state: "done" }
      elif $event == "SessionEnd" then
        { _delete: true }
      else
        {}
      end
    ) as $delta
  | (
      $existing
      * { session_id: $sid, cwd: $cwd, project: $project, updated_at: $ts, last_event: $event,
          # Sessions started before install never fire SessionStart, so capture
          # the claude pid on whatever event arrives first.
          pid: (if (($existing.pid // 0) | tonumber? // 0) > 0 then $existing.pid else (($pid | tonumber?) // 0) end),
          launch_cwd: $launch_cwd }
      * (if $tty_final != "" then { tty: $tty_final } else {} end)
      * (if $summary != "" then { last_summary: $summary } else {} end)
      * $delta
    )
  ' 2>/dev/null)
status=$?

if [ $status -ne 0 ] || [ -z "$merged" ]; then
  exit 0
fi

case "$merged" in
  *'"_delete":true'*)
    rm -f "$state_file" "$tmp_file" 2>/dev/null
    ;;
  *)
    printf '%s\n' "$merged" > "$tmp_file" 2>/dev/null && mv -f "$tmp_file" "$state_file" 2>/dev/null
    ;;
esac

exit 0

⟦⟦⟦ END ⟧⟧⟧
