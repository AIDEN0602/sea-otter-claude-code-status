import Foundation

/// A way to bring the terminal window/tab for a given working directory to
/// the front. Implementations must never crash and never surface an
/// uncaught error to the caller -- at most a beep -- mirroring
/// `GhosttyFocus`'s swallow-all-failures behavior (see its doc comment).
protocol TerminalFocuser {
    static func focus(cwd: String)
}
