import AppKit

extension Notification.Name {
    /// Posted when the user's selected terminal app changes (Preferences
    /// window's Terminal section), mirroring `.spritePackDidChange` for
    /// consistency even though there's currently only the one UI that reads
    /// `TerminalPreference.selected`.
    static let terminalAppDidChange = Notification.Name("NotchOtter.terminalAppDidChange")
}

/// Which terminal app NotchOtter focuses when a session's otter is clicked.
/// `.ghostty` is the default -- this preserves exactly the pre-Preferences
/// behavior, when GhosttyFocus was the only option and every click site
/// called it directly.
enum TerminalApp: String, CaseIterable {
    case ghostty
    case iterm2
    case terminal

    var displayName: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .terminal: return "Terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        }
    }

    /// Whether this terminal app is installed on this Mac, per LaunchServices
    /// (NSWorkspace bundle-identifier lookup) -- not whether it's currently
    /// running. An app can be selected in Preferences without being open;
    /// focusing it will simply launch/activate it like any AppleScript
    /// `tell application ... activate` does.
    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

/// Persisted choice of which terminal app to focus, read by
/// `TerminalFocusDispatcher` and written by the Preferences window.
enum TerminalPreference {
    private static let key = "NotchOtter.terminalApp"

    static var selected: TerminalApp {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let app = TerminalApp(rawValue: raw) else {
            return .ghostty
        }
        return app
    }

    static func select(_ app: TerminalApp) {
        UserDefaults.standard.set(app.rawValue, forKey: key)
        NotificationCenter.default.post(name: .terminalAppDidChange, object: nil)
    }
}
