import Foundation

/// Handles the "Otter Outputs" folder created on a session's transition to
/// `done`, per SPEC.md section 5: symlinks to every output path that still
/// exists, collected under `~/Desktop/Otter Outputs/<YYYY-MM-DD>-<project>/`.
enum OutputsManager {
    static func handleDoneTransition(for session: Session) {
        guard !session.outputs.isEmpty else { return }

        let folder = destinationFolder(for: session, on: session.updatedAt)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            NSLog("NotchOtter: failed to create outputs folder \(folder.path): \(error)")
            return
        }

        for outputPath in session.outputs {
            let sourceURL = URL(fileURLWithPath: outputPath)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                continue // Skip dead paths per SPEC.
            }
            let linkURL = folder.appendingPathComponent(sourceURL.lastPathComponent)
            do {
                try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
            } catch {
                // Symlink already exists (e.g. duplicate basenames, re-run) --
                // ignore per SPEC, don't fail the whole batch.
                continue
            }
        }
    }

    private static func destinationFolder(for session: Session, on date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let dateString = formatter.string(from: date)

        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        return desktop
            .appendingPathComponent("Otter Outputs")
            .appendingPathComponent("\(dateString)-\(session.project)")
    }
}
