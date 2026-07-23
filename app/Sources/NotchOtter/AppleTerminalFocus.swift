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
