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
    /// currently matched to a still-open Ghostty tab is never pruned by age;
    /// it stays visible until its tab closes (SessionEnd deletes the file)
    /// or the session goes stale via dead PID. When tab data is unavailable
    /// (Automation permission missing, Ghostty not running, etc.),
    /// `GhosttyTabMatcher` itself degrades to "everyone unmatched", so this
    /// naturally falls back to the plain age-based prune for every session,
    /// unchanged from before this exemption existed.
    var visibleRecords: [SessionRecord] {
        let matchedIDs = matchedToOpenTabSessionIDs
        return allRecords.filter { record in
            let state = record.displayState
            if state == .done || state == .idle {
                if matchedIDs.contains(record.session.sessionID) {
                    return true
                }
                return record.ageSeconds < Self.displayPruneAge
            }
            return true
        }
    }

    /// Session IDs currently matched to an open Ghostty tab, per the same
    /// matching algorithm the companion row uses (computed independently
    /// here since SessionStore doesn't otherwise depend on the companion UI
    /// layer) -- derived fresh from `GhosttyTabsPoller.shared.tabs` on each
    /// access, so there's no separately-mutable cache to fall out of sync
    /// with either the 2s tab poll or filesystem-driven session updates.
    private var matchedToOpenTabSessionIDs: Set<String> {
        let rows = GhosttyTabMatcher.buildRowOrder(sessions: allRecords, tabs: GhosttyTabsPoller.shared.tabs)
        return Set(rows.compactMap { $0.matchedTab != nil ? $0.record.session.sessionID : nil })
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
