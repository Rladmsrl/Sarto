import AppKit
import CoreGraphics
import Foundation

/// Tracks whether the user is actively at this Mac (unlocked, awake, active console session, and
/// recent keyboard or pointer input) so the daemon can hold `onlyAway` mobile APNs pushes while
/// desktop notifications already reach them.
@MainActor
final class DesktopPresenceMonitor {
    /// Seconds without keyboard or mouse input after which the user counts as away.
    static let awayAfterSeconds: TimeInterval = 120
    /// Polling cadence while unlocked and enabled; paused completely while locked, asleep or off.
    private static let pollIntervalSeconds: TimeInterval = 10

    var onPresenceChanged: ((Bool) -> Void)?

    private var isEnabled = true
    private var started = false
    private var screenLocked = false
    private var screensAsleep = false
    private var systemAsleep = false
    private var sessionInactive = false
    private var lastReported: Bool?
    private var pollTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    func start(enabled: Bool) {
        isEnabled = enabled
        if !started {
            started = true
            screenLocked = Self.isScreenLocked()
            installObservers()
        }
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
        pollTimer?.invalidate()
        pollTimer = nil
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        started = false
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
            screenLocked = Self.isScreenLocked()
        case .systemSlept:
            systemAsleep = true
        case .systemWoke:
            systemAsleep = false
            screensAsleep = false
            screenLocked = Self.isScreenLocked()
        case .sessionResigned:
            sessionInactive = true
        case .sessionActivated:
            sessionInactive = false
            screenLocked = Self.isScreenLocked()
        case .locked:
            screenLocked = true
        case .unlocked:
            screenLocked = false
            screensAsleep = false
        case .appActivated:
            if screenLocked {
                screenLocked = Self.isScreenLocked()
            }
        }
        evaluate()
    }

    private func evaluate() {
        let unavailable = screenLocked || screensAsleep || systemAsleep || sessionInactive
        let shouldPoll = isEnabled && !unavailable
        syncPollTimer(running: shouldPoll)

        let present: Bool
        if !isEnabled || unavailable {
            present = false
        } else {
            let idle = Self.secondsSinceLastUserInput()
            present = idle.isFinite && idle >= 0 && idle < Self.awayAfterSeconds
        }

        if present != lastReported {
            lastReported = present
            onPresenceChanged?(present)
        }
    }

    private func syncPollTimer(running: Bool) {
        if running {
            guard pollTimer == nil else { return }
            let timer = Timer.scheduledTimer(
                withTimeInterval: Self.pollIntervalSeconds,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.evaluate()
                }
            }
            timer.tolerance = 2
            pollTimer = timer
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private static func isScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as NSDictionary? else { return false }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    private static func secondsSinceLastUserInput() -> TimeInterval {
        if let any = CGEventType(rawValue: ~0) {
            return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        }
        let kinds: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel,
        ]
        return kinds.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }.min() ?? 0
    }
}
