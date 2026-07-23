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
