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
