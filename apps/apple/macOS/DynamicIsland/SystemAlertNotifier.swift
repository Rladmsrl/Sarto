import AppKit
import UserNotifications

/// macOS notifications for what the Dynamic Island would have shown, while the island is off:
/// approvals, turns that ended, failures and plan limits. Clicking one opens its session.
@MainActor
final class SystemAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    struct Alert {
        /// Replaces an earlier notification with the same id, as a newer pop replaces an older one.
        let id: String
        let title: String
        let body: String
        let sessionId: String?
        let sound: Bool
    }

    private nonisolated static let sessionKey = "sessionId"
    private static let requestPrefix = "request:"

    var onOpenSession: ((String?) -> Void)?
    private var shownRequestIDs: Set<String> = []

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    static func requestID(_ key: String) -> String {
        requestPrefix + key
    }

    func post(_ alerts: [Alert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts where alert.id.hasPrefix(Self.requestPrefix) {
            shownRequestIDs.insert(alert.id)
        }
        Task { @MainActor in
            guard await Self.mayNotify() else { return }
            let center = UNUserNotificationCenter.current()
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                if alert.sound { content.sound = .default }
                if let sessionId = alert.sessionId {
                    content.userInfo = [Self.sessionKey: sessionId]
                    content.threadIdentifier = sessionId
                }
                try? await center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
            }
        }
    }

    /// Takes back the approval notifications whose requests were answered or withdrawn.
    func withdrawRequests(except liveKeys: Set<String>) {
        guard !shownRequestIDs.isEmpty else { return }
        let live = Set(liveKeys.map(Self.requestID))
        let gone = shownRequestIDs.subtracting(live)
        guard !gone.isEmpty else { return }
        shownRequestIDs.subtract(gone)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(gone))
    }

    /// Reads only the `Sendable` status inside the callback so `UNNotificationSettings` never
    /// crosses an isolation boundary on SDKs where it is not `Sendable` (Xcode 16.4 / macOS 15).
    private nonisolated static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Asks for permission the first time there is something to say, and never again once the
    /// user has answered; the answer is read each time, as it may change in System Settings.
    private static func mayNotify() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let sessionId = response.notification.request.content.userInfo[Self.sessionKey] as? String
        await MainActor.run {
            self.onOpenSession?(sessionId)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
