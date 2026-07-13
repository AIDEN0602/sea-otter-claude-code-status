import Foundation

extension Notification.Name {
    /// Posted when the selected sprite pack changes; every live
    /// OtterSpriteView reloads its current animation from the new pack.
    static let spritePackDidChange = Notification.Name("NotchOtter.spritePackDidChange")
}

/// Custom character packs: a pack is a directory under
/// `~/.local/share/notch-otter/sprites/<name>/` holding `<state>.png` sprite
/// sheets in the same format as the bundled otter (horizontal strip of
/// square cells; see SPEC.md section 3). Packs are typically produced by
/// `spritegen/hatch.py` from a user photo. Missing states fall back to the
/// bundled otter's sheet for that state, so a partial pack still works.
enum SpritePacks {
    private static let selectionKey = "NotchOtter.spritePack"

    /// Directory scanned for packs. Created on demand so "Open Sprite Packs
    /// Folder" always has somewhere to land.
    static var packsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/notch-otter/sprites", isDirectory: true)
    }

    /// Currently selected pack name; nil = the bundled otter.
    static var selected: String? {
        let raw = UserDefaults.standard.string(forKey: selectionKey)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static func select(_ name: String?) {
        if let name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectionKey)
        }
        NotificationCenter.default.post(name: .spritePackDidChange, object: nil)
    }

    /// Pack names available on disk (subdirectories containing at least one
    /// recognizable state sheet), sorted for stable menu ordering.
    static func availablePacks() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: packsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { dir in
                SessionState.allCases.contains { state in
                    fm.fileExists(atPath: dir.appendingPathComponent("\(state.rawValue).png").path)
                }
            }
            .map(\.lastPathComponent)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Ensures the packs directory exists (for the "open folder" menu item).
    @discardableResult
    static func ensurePacksDirectory() -> URL {
        try? FileManager.default.createDirectory(at: packsDirectory, withIntermediateDirectories: true)
        return packsDirectory
    }

    /// Sheet URL for a state: the selected pack's file when present, else
    /// the bundled otter's.
    static func sheetURL(for state: SessionState) -> URL? {
        if let selected {
            let candidate = packsDirectory
                .appendingPathComponent(selected, isDirectory: true)
                .appendingPathComponent("\(state.rawValue).png")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return Bundle.main.url(forResource: state.rawValue, withExtension: "png", subdirectory: "sprites")
    }
}
