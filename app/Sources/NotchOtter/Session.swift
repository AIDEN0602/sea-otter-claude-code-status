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
