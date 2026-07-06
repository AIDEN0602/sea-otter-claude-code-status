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
