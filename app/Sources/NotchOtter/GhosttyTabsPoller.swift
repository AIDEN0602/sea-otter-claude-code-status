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
