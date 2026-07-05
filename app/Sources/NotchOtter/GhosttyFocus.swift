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
enum GhosttyFocus {
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
