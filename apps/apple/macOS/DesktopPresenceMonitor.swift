import AppKit
import CoreGraphics
import Foundation
import Observation
import UserNotifications

/// Tracks whether the user is actively at this Mac (unlocked, awake, active console session, and
/// recent keyboard or pointer input) and whether this Mac can show them what waits, so the daemon
/// holds `onlyAway` mobile APNs pushes only while the desktop already tells them.
@MainActor
final class DesktopPresenceMonitor {
    /// Seconds without keyboard or mouse input after which the user counts as away.
    static let awayAfterSeconds: TimeInterval = 120
    /// How often input is read while the user is away: coming back raises no event to wait for.
    private static let awayPollSeconds: TimeInterval = 10

    var onPresenceChanged: ((Bool) -> Void)?

    private var isEnabled = true
    private var started = false
    private var screenLocked = false
    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    /// Whether the island or a macOS notification shows the user what waits. Unknown counts as
    /// unreachable, so pushes keep going until the desktop is known to tell them.
    private var alertsReachable = false
    private var islandEnabled: (@MainActor () -> Bool)?
    private var alertsWanted: (@MainActor () -> Bool)?
    /// Drops permission reads that a newer refresh overtook.
    private var reachGeneration: UInt64 = 0
    /// Ends the observation chain of an earlier start once the monitor stops.
    private var observationGeneration: UInt64 = 0
    private var lastReported: Bool?
    private var checkTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Starts tracking. `islandEnabled` and `alertsWanted` read `@Observable` state, which the
    /// monitor follows: with the island off, only macOS notifications the user allows reach them.
    func start(
        enabled: Bool,
        islandEnabled: @escaping @MainActor () -> Bool,
        alertsWanted: @escaping @MainActor () -> Bool
    ) {
        isEnabled = enabled
        self.islandEnabled = islandEnabled
        self.alertsWanted = alertsWanted
        if !started {
            started = true
            let session = Self.readSessionState()
            screenLocked = session.locked
            sessionInactive = !session.onConsole
            screensAsleep = false
            systemAsleep = false
            installObservers()
            observationGeneration &+= 1
            observeReachSettings(generation: observationGeneration)
        }
        refreshAlertsReachable()
        evaluate()
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if started {
            evaluate()
        }
    }

    func stop() {
        checkTimer?.invalidate()
        checkTimer = nil
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        observationGeneration &+= 1
        reachGeneration &+= 1
        started = false
        lastReported = nil
        screenLocked = false
        screensAsleep = false
        systemAsleep = false
        sessionInactive = false
        alertsReachable = false
    }

    private enum PowerChange: Sendable {
        case screensSlept
        case screensWoke
        case systemSlept
        case systemWoke
        case sessionResigned
        case sessionActivated
        case locked
        case unlocked
        case appActivated
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let dnc = DistributedNotificationCenter.default()
        let appCenter = NotificationCenter.default

        let entries: [(NotificationCenter, Notification.Name, PowerChange)] = [
            (workspace, NSWorkspace.screensDidSleepNotification, .screensSlept),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensWoke),
            (workspace, NSWorkspace.willSleepNotification, .systemSlept),
            (workspace, NSWorkspace.didWakeNotification, .systemWoke),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated),
            (dnc, Notification.Name("com.apple.screenIsLocked"), .locked),
            (dnc, Notification.Name("com.apple.screenIsUnlocked"), .unlocked),
            (appCenter, NSApplication.didBecomeActiveNotification, .appActivated),
        ]

        for (center, name, change) in entries {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePowerChange(change)
                }
            }
            observers.append((center, token))
        }
    }

    private func handlePowerChange(_ change: PowerChange) {
        switch change {
        case .screensSlept:
            screensAsleep = true
        case .screensWoke:
            screensAsleep = false
            let session = Self.readSessionState()
            screenLocked = session.locked
            sessionInactive = !session.onConsole
        case .systemSlept:
            systemAsleep = true
        case .systemWoke:
            // Do not clear `screensAsleep` here: macOS Dark Wake / Power Nap fires `didWake`
            // while displays stay asleep, and real wakes emit `screensDidWake` or `screenIsUnlocked`.
            systemAsleep = false
            let session = Self.readSessionState()
            screenLocked = session.locked
            sessionInactive = !session.onConsole
        case .sessionResigned:
            sessionInactive = true
        case .sessionActivated:
            let session = Self.readSessionState()
            screenLocked = session.locked
            sessionInactive = !session.onConsole
            refreshAlertsReachable()
        case .locked:
            screenLocked = true
        case .unlocked:
            screenLocked = false
            screensAsleep = false
            systemAsleep = false
            sessionInactive = !Self.readSessionState().onConsole
            refreshAlertsReachable()
        case .appActivated:
            let session = Self.readSessionState()
            screenLocked = session.locked
            sessionInactive = !session.onConsole
            // Recover if macOS dropped a `screensDidWake` notification across display hotplug.
            if !screenLocked && !sessionInactive {
                screensAsleep = false
                systemAsleep = false
            }
            // The user may have changed Sarto's notification permission in System Settings.
            refreshAlertsReachable()
        }
        evaluate()
    }

    /// Follows the island and notification settings, as one `withObservationTracking` per change.
    private func observeReachSettings(generation: UInt64) {
        guard let islandEnabled, let alertsWanted else { return }
        withObservationTracking {
            _ = islandEnabled()
            _ = alertsWanted()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.started, self.observationGeneration == generation else { return }
                self.refreshAlertsReachable()
                self.observeReachSettings(generation: generation)
            }
        }
    }

    private func refreshAlertsReachable() {
        guard let islandEnabled, let alertsWanted else { return }
        reachGeneration &+= 1
        let generation = reachGeneration
        // The island shows what waits whatever macOS allows Sarto to post.
        if islandEnabled() {
            setAlertsReachable(true)
            return
        }
        guard alertsWanted() else {
            setAlertsReachable(false)
            return
        }
        Task { @MainActor [weak self] in
            let allowed = await Self.notificationsAllowed()
            guard let self, self.started, self.reachGeneration == generation else { return }
            self.setAlertsReachable(allowed)
        }
    }

    private func setAlertsReachable(_ reachable: Bool) {
        guard alertsReachable != reachable else { return }
        alertsReachable = reachable
        if started {
            evaluate()
        }
    }

    private func evaluate() {
        let unavailable = screenLocked || screensAsleep || systemAsleep || sessionInactive
        guard isEnabled, !unavailable, alertsReachable else {
            scheduleCheck(after: nil)
            report(false)
            return
        }
        let idle = Self.secondsSinceLastUserInput()
        let active = idle.isFinite && idle >= 0 && idle < Self.awayAfterSeconds
        // While active nothing changes before the idle time reaches the limit, so one check then
        // is enough; while away, input that brings the user back raises no event, so it is polled.
        scheduleCheck(after: active ? Self.awayAfterSeconds - idle + 1 : Self.awayPollSeconds)
        report(active)
    }

    private func report(_ present: Bool) {
        guard present != lastReported else { return }
        lastReported = present
        onPresenceChanged?(present)
    }

    private func scheduleCheck(after seconds: TimeInterval?) {
        checkTimer?.invalidate()
        checkTimer = nil
        guard let seconds else { return }
        let timer = Timer(timeInterval: max(seconds, 1), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        timer.tolerance = 2
        // Common modes, so the check still fires while a menu or a window resize tracks events.
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    /// Reads only the `Sendable` status inside the callback, as `SystemAlertNotifier` does.
    private nonisolated static func notificationsAllowed() async -> Bool {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func readSessionState() -> (locked: Bool, onConsole: Bool) {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else {
            return (locked: false, onConsole: true)
        }
        let locked = (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        let onConsole = (session[kCGSessionOnConsoleKey] as? NSNumber)?.boolValue ?? true
        return (locked: locked, onConsole: onConsole)
    }

    // The HID system's state, not the session's: events apps post into the session, as automation
    // and agents driving the computer do, do not hold pushes while the user is gone. Input through
    // Screen Sharing counts as away too, which errs toward sending them.
    private static func secondsSinceLastUserInput() -> TimeInterval {
        if let any = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: any)
        }
        let kinds: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
        ]
        return kinds.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? 0
    }
}
