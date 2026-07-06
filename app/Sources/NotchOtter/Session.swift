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
    let project: String
    let pid: Int32
    let updatedAt: Date
    let lastEvent: String
    let errorCount: Int
    let outputs: [String]

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state
        case cwd
        case project
        case pid
        case updatedAt = "updated_at"
        case lastEvent = "last_event"
        case errorCount = "error_count"
        case outputs
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
