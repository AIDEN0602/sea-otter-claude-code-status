import Foundation
import UserNotifications

/// Fires local notifications on transitions INTO `waiting_permission`,
/// `done`, or `error` (never on `working`/`idle`), per SPEC.md section 4.
/// Also triggers Otter Outputs folder creation on the `done` transition,
/// since both need the same "previous state per session_id" bookkeeping.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private var previousStates: [String: SessionState] = [:]
    private var storeObserver: NSObjectProtocol?

    private override init() {
        super.init()
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("NotchOtter: notification authorization error: \(error)")
            }
        }

        // Seed with whatever is already on disk so we don't re-fire for
        // sessions that were already in a terminal/waiting state at launch.
        for record in SessionStore.shared.allRecords {
            previousStates[record.session.sessionID] = record.session.state
        }

        storeObserver = NotificationCenter.default.addObserver(
            forName: .sessionStoreDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let store = note.object as? SessionStore else { return }
            self?.processUpdate(store: store)
        }
    }

    private func processUpdate(store: SessionStore) {
        var seenIDs = Set<String>()

        for record in store.allRecords {
            let id = record.session.sessionID
            seenIDs.insert(id)
            let newState = record.session.state
            let oldState = previousStates[id]

            if oldState != newState {
                switch newState {
                case .waitingPermission, .done, .error:
                    fireNotification(for: record)
                default:
                    break
                }
                if newState == .done && oldState != .done {
                    OutputsManager.handleDoneTransition(for: record.session)
                }
            }

            previousStates[id] = newState
        }

        // Sessions that vanished (SessionEnd, or stale cleanup) drop out of
        // transition tracking so a reused session_id starts fresh.
        let goneIDs = Set(previousStates.keys).subtracting(seenIDs)
        for id in goneIDs {
            previousStates.removeValue(forKey: id)
        }
    }

    private func fireNotification(for record: SessionRecord) {
        let content = UNMutableNotificationContent()
        let project = record.session.project

        switch record.session.state {
        case .waitingPermission:
            content.title = "\(project) needs your approval"
            content.body = "Claude Code is waiting on a permission prompt."
        case .done:
            let count = record.session.outputs.count
            content.title = "\(project) finished"
            content.body = count > 0 ? "\(count) file\(count == 1 ? "" : "s") changed." : "Session complete."
        case .error:
            content.title = "\(project) hit repeated errors"
            content.body = "3 or more consecutive tool failures."
        default:
            return
        }

        content.sound = .default
        content.userInfo = ["session_id": record.session.sessionID]

        let request = UNNotificationRequest(
            identifier: "\(record.session.sessionID)-\(record.session.state.rawValue)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("NotchOtter: failed to deliver notification: \(error)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionID = response.notification.request.content.userInfo["session_id"] as? String,
           let record = SessionStore.shared.record(forSessionID: sessionID) {
            TerminalFocusDispatcher.focus(cwd: record.session.cwd)
        }
        completionHandler()
    }
}
