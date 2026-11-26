import AppKit
import Combine
import Foundation
import SartoProtocol
import MenuBarKit
import Observation
import PrismDesign
import UsageCore

/// Unified coordinator for Sarto's macOS Dynamic Island (multi-monitor `PrismIslandHub`)
/// and frosted Menu Bar Usage Panel (`StatusPanelController`, with the usage the Sarto daemon computes).
///
/// - Zero-polling observation of `SartoState` via `withObservationTracking` with an 80ms
///   leading + trailing throttle so 60Hz token streaming stays smooth without freezing updates.
/// - Bidirectional live synchronization with Sarto's 4 optical palettes & accent tones.
/// - Cleanly keeps background daemons untouched while letting users close the main window and
///   continue monitoring both agent sessions and token/quota usage from the menu bar & island.
@MainActor
@Observable
final class PrismDynamicIslandCoordinator: IslandActionSink {
    private static let syncThrottleInterval: TimeInterval = 0.08

    let model = PrismIslandModel()
    let usageStore = PrismUsageStore()
    let settingsStore = UsageSettingsStore()
    /// The idle game the game service runs, as the daemon relays it.
    let gameStore = GameStore()
    let launchAtLogin = PrismLaunchAtLogin()
    /// What the island would show, as macOS notifications while the island is off.
    let systemAlerts = SystemAlertNotifier()
    let panelRouter = MenuBarPanelRouter()
    let panelState = MenuBarPanelState()

    /// Triggers opening the New Session sheet inside `MacWorkbenchView` when requested from the island footer.
    var newSessionRequestToken: Int = 0
    /// Callback wired by `SartoMacApp` to reopen the main window if it was previously closed.
    var onRequestOpenMainWindow: (() -> Void)?
    /// Callback wired by `SartoMacApp` to open the native independent macOS Settings window.
    var onRequestOpenSettings: ((PrismSettingsSection?) -> Void)?
    /// Callback wired by `SartoMacApp` to confirm & execute a full quit (stopping Menu Bar + bound Daemon).
    var onRequestQuitFromMenuBar: (() -> Void)?
    /// The version of an update waiting for a restart, for the menu bar panel to offer.
    var updateReadyVersion: () -> String? = { nil }
    var onRequestOpenUpdates: (() -> Void)?

    /// Mirror of `settingsStore.settings.islandEnabled` exposed to SwiftUI `@Observable` views.
    var isEnabled: Bool {
        get { _islandEnabledMirror }
        set {
            _islandEnabledMirror = newValue
            if settingsStore.settings.islandEnabled != newValue {
                settingsStore.setIslandEnabled(newValue)
            }
        }
    }

    var isOpen: Bool {
        isEnabled && model.mode == .open
    }

    var isMenuBarEnabled: Bool {
        get { _menubarEnabledMirror }
        set {
            _menubarEnabledMirror = newValue
            if settingsStore.settings.menubarEnabled != newValue {
                settingsStore.setMenubarEnabled(newValue)
            }
        }
    }

    private var _islandEnabledMirror: Bool
    private var _menubarEnabledMirror: Bool
    private(set) var islandDisplays: [DisplayChoice]

    private var islandHub: PrismIslandHub?
    private var statusPanel: StatusPanelController?
    private weak var appState: SartoState?

    private static let requestForgetAfter: TimeInterval = 15 * 60
    private static let endedUnreadWindow: TimeInterval = 15

    private var previousStatuses: [String: SessionStatus] = [:]
    /// Each session's last turn ending as last seen, so an ending that arrives after its status
    /// change, or a failure a later limit notice turns into a limit, still pops.
    private var previousEndings: [String: LastTurn] = [:]
    /// Each request's first sighting (epoch ms, which orders the cards) and its last (uptime). A
    /// request that drops out with its host's link and comes back is not announced again.
    private var requestSightings: [String: (firstSeenMs: Double, lastSeen: TimeInterval)] = [:]
    /// Sessions waiting on the user whose replica was asked for, `hostId::sessionId`, with when
    /// to ask again: a failed fetch or an evicted replica must never leave an approval without
    /// its card. The wait doubles each time, so the replica caches cannot thrash.
    private var snapshotRetry: [String: (due: TimeInterval, wait: TimeInterval)] = [:]
    /// Running sessions with an active plan whose full step list was asked for once.
    private var planSnapshotRequestedSessionIDs: Set<String> = []
    /// Turns that ended before their host marked them unread, by when; they pop once it does.
    private var endedAwaitingUnread: [String: TimeInterval] = [:]
    private var lastDockBadge: String?
    /// The menu bar item shows while no window is open even when the user hid it, without
    /// changing the setting.
    private var menuBarResidentOverride = false
    private var railShowing = true
    private var previousConnectionMode: ConnectionMode = .disconnected
    private var hasInitializedWorkbenchFocus = false
    private var lastWorkbenchFocusKey: WorkbenchFocusKey?
    private var workbenchSelectedAt: Date?

    private var coalesceWorkItem: DispatchWorkItem?
    private var trailingSyncScheduled = false
    private var lastSyncUptime: TimeInterval = 0
    private var telemetryTrailingScheduled = false
    private var lastTelemetryUptime: TimeInterval = 0

    private var lastLimitsRefresh: Date = .distantPast
    private var isObserving = false
    private var themeKey: IslandThemeKey?
    private var statusPanelOpen = false
    private var usageViewerCount = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        self._islandEnabledMirror = settingsStore.settings.islandEnabled
        self._menubarEnabledMirror = settingsStore.settings.menubarEnabled
        self.islandDisplays = settingsStore.settings.islandDisplays
        self.model.actionSink = self
    }

    func attach(to state: SartoState) {
        guard appState !== state else { return }
        self.appState = state
        self.previousConnectionMode = state.connectionMode
        self.railShowing = Self.readRunningRailShowing()

        NumFont.register()
        Fmt.symbol = "$"
        IslandMarkImageCache.warmUp()
        systemAlerts.install()
        systemAlerts.onOpenSession = { [weak self] sessionId in
            self?.islandOpenApp(sessionId: sessionId)
        }

        syncTheme(from: state)

        if islandHub == nil {
            islandHub = PrismIslandHub(
                model: model,
                usageStore: usageStore,
                settingsStore: settingsStore,
                gameStore: gameStore
            )
        }

        if statusPanel == nil {
            setupStatusPanel(state: state)
        }

        applySettings(settingsStore.settings)
        installUsageSubscriptions()
        usageStore.start()
        startObserving(state)
        syncNow()
    }

    func openMenuBarPanel(page: MenuBarPage = .main) {
        model.collapse()
        panelRouter.go(page)
        // Reading resumes before the panel shows, whatever opened it.
        statusPanelOpen = true
        updateUsageActivity()
        statusPanel?.open()
    }

    /// For any other view that shows usage (such as a Settings page): keeps the usage store
    /// reading, and more often, while at least one is on screen, even with the island and menu bar
    /// item off.
    func setUsageViewerVisible(_ visible: Bool) {
        usageViewerCount = max(0, usageViewerCount + (visible ? 1 : -1))
        updateUsageActivity()
    }

    /// Usage is read only while something can show it: the island, the menu bar item, the open
    /// panel or another usage view; more often while the panel or another usage view is open.
    private func updateUsageActivity(_ settings: UsageIslandSettings? = nil) {
        let s = settings ?? settingsStore.settings
        usageStore.setActive(s.islandEnabled || s.menubarEnabled || statusPanelOpen || usageViewerCount > 0)
        usageStore.setVisible(statusPanelOpen || usageViewerCount > 0)
    }

    func toggleIslandExpansion() {
        if !isEnabled {
            isEnabled = true
            statusPanel?.close()
            model.expand(by: .click, onScreen: Displays.preferredScreen().map(Displays.id(of:)))
        } else if isOpen {
            model.collapse()
        } else {
            statusPanel?.close()
            model.expand(by: .click, onScreen: Displays.preferredScreen().map(Displays.id(of:)))
        }
    }

    // MARK: - Status Panel Setup (MenuBarKit)

    private func setupStatusPanel(state: SartoState) {
        let actions = MenuBarPanelActions(
            openMainWindow: { [weak self] sessionId in
                self?.statusPanel?.close()
                self?.islandOpenApp(sessionId: sessionId)
            },
            openSettings: { [weak self] section in
                self?.statusPanel?.close()
                self?.onRequestOpenSettings?(section)
            },
            toggleIsland: { [weak self] in
                self?.toggleIslandExpansion()
            },
            refresh: { [weak self] in
                guard let self else { return }
                self.snapshotRetry.removeAll()
                self.usageStore.refresh()
                Task { [weak self] in
                    await self?.appState?.refreshAgentLimits()
                }
            },
            close: { [weak self] in
                self?.statusPanel?.close()
            },
            quit: { [weak self] in
                self?.statusPanel?.close()
                if let customQuit = self?.onRequestQuitFromMenuBar {
                    customQuit()
                } else {
                    NSApp.terminate(nil)
                }
            },
            updateReadyVersion: { [weak self] in
                self?.updateReadyVersion()
            },
            openUpdates: { [weak self] in
                self?.statusPanel?.close()
                self?.onRequestOpenUpdates?()
            }
        )

        let controller = StatusPanelController(state: panelState) { [weak self, weak state] in
            if let self, let state {
                MenuBarPanelRootView(
                    appState: state,
                    islandModel: self.model,
                    usageStore: self.usageStore,
                    settingsStore: self.settingsStore,
                    router: self.panelRouter,
                    panel: self.panelState,
                    actions: actions
                )
            }
        }

        controller.escapeHandler = { [weak self] in
            guard let self, self.panelRouter.page != .main else { return false }
            self.panelRouter.go(.main)
            return true
        }

        controller.keyHandler = { [weak self] event in
            guard let self, event.modifierFlags.contains(.command) else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r":
                self.snapshotRetry.removeAll()
                self.usageStore.refresh()
                return true
            case "i":
                self.toggleIslandExpansion()
                return true
            case ",":
                self.statusPanel?.close()
                self.onRequestOpenSettings?(.islandAndMenuBar)
                return true
            case "q":
                self.statusPanel?.close()
                if let customQuit = self.onRequestQuitFromMenuBar {
                    customQuit()
                } else {
                    NSApp.terminate(nil)
                }
                return true
            default:
                return false
            }
        }

        controller.onOpenChange = { [weak self] open in
            guard let self else { return }
            self.statusPanelOpen = open
            self.updateUsageActivity()
            if open {
                self.launchAtLogin.refresh()
                if self.model.mode == .open && self.model.opener == .hover {
                    self.model.collapse()
                }
            } else if self.panelRouter.page != .main {
                self.panelRouter.page = .main
            }
        }

        self.statusPanel = controller
        updateStatusBarItem()
    }

    // MARK: - Combine Subscriptions (UsageStore + SettingsStore + App/Screen Lifecycle)

    private func installUsageSubscriptions() {
        cancellables.removeAll()

        usageStore.$providers
            .receive(on: RunLoop.main)
            .sink { [weak self] providers in
                guard let self else { return }
                self.model.hasLowUsageAlert = self.settingsStore.settings.lowAlert && self.usageStore.lowestWindow != nil
                let now = Date()
                var quotas: [String: [IslandQuotaWindow]] = [:]
                var names: [String: String] = [:]
                for provider in providers where provider.eligible && !provider.allWindows.isEmpty {
                    names[provider.id] = provider.name
                    quotas[provider.id] = provider.allWindows.map { window in
                        let current = window.current(at: now)
                        return IslandQuotaWindow(
                            label: current.label,
                            remaining: current.remaining,
                            resetsAt: current.resetsAt.map { $0.timeIntervalSince1970 * 1000 }
                        )
                    }
                }
                if self.model.usageQuotas != quotas { self.model.usageQuotas = quotas }
                if self.model.usageQuotaNames != names { self.model.usageQuotaNames = names }
                self.updateStatusBarItem()
            }
            .store(in: &cancellables)

        usageStore.$ready
            .receive(on: RunLoop.main)
            .sink { [weak self] ready in
                if ready, self?.model.usageReady == false { self?.model.usageReady = true }
                self?.updateStatusBarItem()
            }
            .store(in: &cancellables)

        usageStore.events
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard let self else { return }
                guard self.settingsStore.settings.lowAlert,
                      !self.settingsStore.settings.subtleReminders
                else { return }
                switch event {
                case .runningLow(let provider, let label, let remaining, _):
                    let remPct = Int((remaining * 100).rounded())
                    let usedPct = max(0, min(100, (1 - remaining) * 100))
                    let body = self.currentStrings.text(
                        "pop.lowUsageBody",
                        ["window": label, "percent": "\(remPct)"]
                    )
                    guard self.isEnabled else {
                        self.systemAlerts.post([SystemAlertNotifier.Alert(
                            id: "low:\(provider.id):\(label)",
                            title: provider.name,
                            body: body,
                            sessionId: nil,
                            sound: self.appState?.notificationPrefs.soundEnabled ?? true
                        )])
                        return
                    }
                    self.model.pushPop(
                        rowKey: nil,
                        kind: "limit-near",
                        title: provider.name,
                        body: body,
                        agent: IslandAgentIdentity(
                            id: provider.id,
                            name: provider.name,
                            harness: provider.id == "claude" ? "claude-code" : provider.id,
                            color: nil
                        ),
                        percent: usedPct
                    )
                }
            }
            .store(in: &cancellables)

        settingsStore.$settings
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] next in
                self?.applySettings(next)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let s = self.settingsStore.settings
                self.islandHub?.apply(
                    enabled: s.islandEnabled,
                    screens: Displays.screens(for: s.islandDisplays)
                )
                self.refreshDisplayMenu()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.hasInitializedWorkbenchFocus && self.hasVisibleMainWindow {
                    self.workbenchSelectedAt = Date()
                }
                self.syncNow()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncNow()
            }
            .store(in: &cancellables)

        for name in [
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] note in
                    guard let self, let win = note.object as? NSWindow, !(win is NSPanel) else { return }
                    self.scheduleCoalescedSync()
                }
                .store(in: &cancellables)
        }

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                guard let self, let win = note.object as? NSWindow, !(win is NSPanel) else { return }
                // Defer one runloop turn so `win.isVisible` reflects the closed state.
                DispatchQueue.main.async { [weak self] in
                    self?.scheduleCoalescedSync()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let showing = Self.readRunningRailShowing()
                guard showing != self.railShowing else { return }
                self.railShowing = showing
                self.scheduleCoalescedSync()
            }
            .store(in: &cancellables)
    }

    private func applySettings(_ settings: UsageIslandSettings) {
        if model.motionStyle != settings.islandMotion { model.motionStyle = settings.islandMotion }
        if _islandEnabledMirror != settings.islandEnabled {
            _islandEnabledMirror = settings.islandEnabled
        }
        if _menubarEnabledMirror != settings.menubarEnabled {
            _menubarEnabledMirror = settings.menubarEnabled
        }
        if islandDisplays != settings.islandDisplays {
            islandDisplays = settings.islandDisplays
        }

        statusPanel?.statusItemVisible = settings.menubarEnabled || menuBarResidentOverride
        let lowMark = settings.lowAlert && usageStore.lowestWindow != nil
        if model.hasLowUsageAlert != lowMark { model.hasLowUsageAlert = lowMark }
        updateUsageActivity(settings)
        usageStore.excluded = Set(settings.hidden)
        usageStore.lowThreshold = Double(settings.lowThreshold) / 100
        usageStore.scope = settings.usageScope == .allMacs ? .all : .computer

        islandHub?.apply(
            enabled: settings.islandEnabled,
            screens: Displays.screens(for: settings.islandDisplays)
        )
        refreshDisplayMenu()
        updateStatusBarItem()
        syncNow()
    }

    /// While no window is open, the menu bar item is the only way back to Sarto, so it shows
    /// even if the user hid it; the setting itself stays as the user left it.
    func setMenuBarResident(_ resident: Bool) {
        guard menuBarResidentOverride != resident else { return }
        menuBarResidentOverride = resident
        statusPanel?.statusItemVisible = settingsStore.settings.menubarEnabled || resident
    }

    private static func readRunningRailShowing() -> Bool {
        let railOn = UserDefaults.standard.object(forKey: "sarto.runningRail.enabled") as? Bool ?? true
        return railOn && !UserDefaults.standard.bool(forKey: "sarto.runningRail.collapsed")
    }

    private func refreshDisplayMenu() {
        let activeIDs = Set(Displays.screens(for: settingsStore.settings.islandDisplays).map(Displays.id(of:)))
        let items = Displays.all().map { IslandDisplayMenuItem(display: $0, isActive: activeIDs.contains($0.id)) }
        if model.displayMenuItems != items {
            model.displayMenuItems = items
        }
        let automatic = settingsStore.settings.islandDisplays.isEmpty
        if model.displaysAutomatic != automatic {
            model.displaysAutomatic = automatic
        }
    }

    private var currentStrings: IslandStrings {
        IslandStrings(language: appState?.language ?? .system)
    }

    /// Shows or clears the menu bar icon's update dot, as an update becomes ready or installs.
    func refreshUpdateBadge() {
        updateStatusBarItem()
    }

    private func updateStatusBarItem() {
        guard let statusPanel else { return }
        let s = settingsStore.settings
        let updateReady = updateReadyVersion() != nil
        let image = prismStatusMarkImage(badged: updateReady)
        let title = prismStatusTitle(store: usageStore, settings: s)
        let hasLow = s.lowAlert && usageStore.lowestWindow != nil
        let tint: NSColor? = hasLow ? .systemOrange : nil
        var label = title.isEmpty
            ? currentStrings.text("a11y.statusItem")
            : currentStrings.text("a11y.statusItemTitle", ["title": title])
        if updateReady, let l10n = appState?.l10n {
            label += ", " + l10n.tr("menuBar.update.a11y")
        }
        statusPanel.setStatus(image: image, title: title, tint: tint, accessibilityLabel: label)
    }

    // MARK: - Bidirectional Theme Sync (4 Palettes + Accent Mode)

    private func syncTheme(from state: SartoState) {
        let key = IslandThemeKey(palette: state.palette, accent: state.accentMode, language: state.language)
        guard key != themeKey else { return }
        let languageChanged = key.language != themeKey?.language
        themeKey = key
        if languageChanged {
            updateStatusBarItem()
        }
        let style = state.palette.menuBarStyle
        let accentHex = state.palette.resolvedAccentHex(accent: state.accentMode)
        if panelState.themeStyle != style {
            panelState.themeStyle = style
        }
        if panelState.accentHex != accentHex {
            panelState.accentHex = accentHex
        }
        // `PrismTokens` is not Equatable, so it is rebuilt and assigned only when its inputs change.
        model.prismTokens = state.tokens
    }

    // MARK: - Reactive Observation of SartoState (Leading + Trailing 80ms Throttle)

    private func startObserving(_ state: SartoState) {
        guard !isObserving else { return }
        isObserving = true
        observeNextChange(state)
        observeTelemetry(state)
    }

    /// Everything the rows, requests and pops are built from. `replicas` is followed through
    /// `islandReplicaRevision` and the live metrics through `observeTelemetry`, so a streamed token
    /// never rebuilds every host's rows.
    private func observeNextChange(_ state: SartoState) {
        withObservationTracking {
            _ = state.sessions
            _ = state.islandReplicaRevision
            _ = state.agents
            _ = state.agentOptionsById
            _ = state.activeHostID
            _ = state.backgroundHostSnapshots
            _ = state.backgroundReplicaRevision
            _ = state.selectedSessionID
            _ = state.showStudioHome
            _ = state.selectedAgentID
            _ = state.newSessionOptionPicks
            _ = state.preparedSession
            _ = state.pendingSwitchBySession
            _ = state.language
            _ = state.palette
            _ = state.accentMode
            _ = state.connectionMode
            _ = state.motionTier
        } onChange: { [weak self, weak state] in
            Task { @MainActor [weak self, weak state] in
                guard let self, let state else { return }
                self.syncTheme(from: state)
                self.scheduleCoalescedSync()
                self.observeNextChange(state)
            }
        }
    }

    /// The selected session's live metrics change with each streamed batch; they update only
    /// `model.telemetry`, which the views that show them read, with the same throttle as a sync.
    private func observeTelemetry(_ state: SartoState) {
        withObservationTracking {
            _ = IslandProjector.buildTelemetry(state: state)
        } onChange: { [weak self, weak state] in
            Task { @MainActor [weak self, weak state] in
                guard let self, let state else { return }
                self.scheduleTelemetrySync()
                self.observeTelemetry(state)
            }
        }
    }

    private func scheduleTelemetrySync() {
        let elapsed = ProcessInfo.processInfo.systemUptime - lastTelemetryUptime
        if elapsed >= Self.syncThrottleInterval {
            syncTelemetry()
            return
        }
        guard !telemetryTrailingScheduled else { return }
        telemetryTrailingScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.005, Self.syncThrottleInterval - elapsed)) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.telemetryTrailingScheduled = false
                self.syncTelemetry()
            }
        }
    }

    private func syncTelemetry() {
        lastTelemetryUptime = ProcessInfo.processInfo.systemUptime
        guard let state = appState else { return }
        let telemetry = IslandProjector.buildTelemetry(state: state)
        model.applyTelemetry(telemetry)
    }

    private func scheduleCoalescedSync() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastSyncUptime
        if elapsed >= Self.syncThrottleInterval {
            coalesceWorkItem?.cancel()
            coalesceWorkItem = nil
            trailingSyncScheduled = false
            syncNow()
            return
        }
        guard !trailingSyncScheduled else { return }
        trailingSyncScheduled = true
        let remaining = max(0.005, Self.syncThrottleInterval - elapsed)
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trailingSyncScheduled = false
                self.coalesceWorkItem = nil
                self.syncNow()
            }
        }
        coalesceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    func syncNow() {
        lastSyncUptime = ProcessInfo.processInfo.systemUptime
        guard let state = appState else { return }
        let uptime = lastSyncUptime
        let strings = IslandStrings(language: state.language)
        let nowMs = Date().timeIntervalSince1970 * 1000

        if state.connectionMode != previousConnectionMode {
            previousConnectionMode = state.connectionMode
            snapshotRetry.removeAll()
            planSnapshotRequestedSessionIDs.removeAll()
            hasInitializedWorkbenchFocus = false
            lastWorkbenchFocusKey = nil
            workbenchSelectedAt = nil
        }
        let offline = !state.connectionMode.isLive
        if model.hostOffline != offline { model.hostOffline = offline }
        if model.motionTier != state.motionTier { model.motionTier = state.motionTier }

        let mainVisible = hasVisibleMainWindow
        let mainWindowForeground = NSApp.isActive && mainVisible

        let nextAppUsageFocus = buildAppUsageFocus(state: state, now: Date(), mainVisible: mainVisible)
        if model.appUsageFocus != nextAppUsageFocus {
            model.appUsageFocus = nextAppUsageFocus
        }

        // Sarto in front with its running panel expanded: the panel says what runs, so the island
        // keeps quiet about non-urgent running/unread/cache states.
        let quiet = mainWindowForeground && railShowing
        if model.quietForeground != quiet { model.quietForeground = quiet }

        // Reconcile foreground session visibility with active and pooled hosts so every host tracks
        // `inFront` and `attention` accurately across synced devices.
        state.updateForegroundPresence(isInForeground: mainWindowForeground)

        // One pass over every online host's sessions: the snapshots an approval or a plan needs,
        // the transitions that pop, and the Dock badge. Only this Mac and the active host pop or
        // count in the badge.
        let hostSources = state.allLiveHostSourcesForIsland()
        var popsToEmit: [(rowKey: String, kind: String, title: String, body: String)] = []
        var nextStatuses: [String: SessionStatus] = [:]
        var nextEndings: [String: LastTurn] = [:]
        var awaitingKeys = Set<String>()
        var activePlanKeys = Set<String>()
        var badgeCount = 0
        let initialized = !previousStatuses.isEmpty

        for source in hostSources {
            let shouldNotify = state.shouldNotifyForHost(source.hostId)
            for summary in source.sessions where IslandProjector.isListed(summary) {
                let trackKey = "\(source.hostId)::\(summary.id)"
                let rowKey = source.isLocal ? summary.id : trackKey
                let hasReplica = source.replicas[summary.id] != nil

                if summary.permissionCount > 0 || summary.status == .awaitingPermission {
                    awaitingKeys.insert(trackKey)
                    if shouldNotify { badgeCount += max(1, summary.permissionCount) }
                    if !hasReplica, snapshotDue(trackKey, uptime: uptime) {
                        requestSnapshot(summary.id, onHost: source.hostId, state: state)
                    }
                }
                if (summary.status == .running || summary.status == .starting || summary.status == .awaitingPermission)
                    && (summary.plan.map { $0.total > 0 && $0.done < $0.total } ?? false) {
                    activePlanKeys.insert(trackKey)
                    if !hasReplica, planSnapshotRequestedSessionIDs.insert(trackKey).inserted {
                        requestSnapshot(summary.id, onHost: source.hostId, state: state)
                    }
                }
                if shouldNotify && summary.attention == "unread" { badgeCount += 1 }

                let prev = previousStatuses[trackKey]
                nextStatuses[trackKey] = summary.status
                let prevEnding = previousEndings[trackKey]
                let ending = summary.lastTurn
                if let ending { nextEndings[trackKey] = ending }

                // A turn that ended before its host marked it unread pops once the host does,
                // unless it was looked at on any device in between.
                if let endedAt = endedAwaitingUnread[trackKey] {
                    if summary.status != .ready || uptime - endedAt > Self.endedUnreadWindow {
                        endedAwaitingUnread.removeValue(forKey: trackKey)
                    } else if summary.attention == "unread" {
                        endedAwaitingUnread.removeValue(forKey: trackKey)
                        if shouldNotify, state.notificationPrefs.turnEnded {
                            let body = IslandProjector.endingPop(ending, strings: strings, nowMs: nowMs)?.body
                                ?? strings.text("pop.turnEndedBody")
                            popsToEmit.append((rowKey, "turn-ended", sessionTitle(summary, source, state, strings), body))
                        }
                    }
                }

                guard initialized, let prev else { continue }
                let statusChanged = prev != summary.status
                let errorEndingArrived = ending != prevEnding && ending?.reason.isError == true
                guard statusChanged || errorEndingArrived else { continue }
                guard shouldNotify else { continue }

                let viewingInFront = mainWindowForeground
                    && !state.showStudioHome
                    && state.activeHostID == source.hostId
                    && state.selectedSessionID == summary.id
                let title = sessionTitle(summary, source, state, strings)
                let endingPop = IslandProjector.endingPop(ending, strings: strings, nowMs: nowMs)
                let errorPop = endingPop.flatMap { $0.kind == "turn-ended" ? nil : $0 }
                let hostHasUnread = summary.attention == "unread"
                let hostHasError = summary.status == .failed || summary.attention == "error"

                if statusChanged && (prev == .running || prev == .starting || prev == .awaitingPermission) && summary.status == .ready {
                    if !viewingInFront {
                        if let errorPop {
                            if hostHasError || hostHasUnread, state.notificationPrefs.error {
                                popsToEmit.append((rowKey, errorPop.kind, title, errorPop.body))
                            }
                        } else if hostHasUnread {
                            if state.notificationPrefs.turnEnded {
                                let body = endingPop?.body ?? strings.text("pop.turnEndedBody")
                                popsToEmit.append((rowKey, "turn-ended", title, body))
                            }
                        } else {
                            endedAwaitingUnread[trackKey] = uptime
                        }
                    }
                } else if statusChanged && prev != .failed && summary.status == .failed {
                    if !viewingInFront, state.notificationPrefs.error {
                        popsToEmit.append((
                            rowKey,
                            errorPop?.kind ?? "error",
                            title,
                            errorPop?.body ?? strings.text("pop.errorBody")
                        ))
                    }
                } else if errorEndingArrived, summary.status == .ready || summary.status == .failed, let errorPop {
                    if !viewingInFront, (hostHasError || hostHasUnread), state.notificationPrefs.error {
                        popsToEmit.append((rowKey, errorPop.kind, title, errorPop.body))
                    }
                }
            }
        }

        // Sessions that left (closed, archived, or their host went offline) are forgotten, so a
        // host coming back does not pop for what changed while it was away.
        previousStatuses = nextStatuses
        previousEndings = nextEndings
        endedAwaitingUnread = endedAwaitingUnread.filter { nextStatuses[$0.key] != nil }
        snapshotRetry = snapshotRetry.filter { awaitingKeys.contains($0.key) }
        planSnapshotRequestedSessionIDs.formIntersection(activePlanKeys)

        let eligibleProviderIds: Set<String>? = usageStore.ready
            ? Set(settingsStore.visible(usageStore.providers).filter(\.eligible).map(\.id))
            : nil
        let built = IslandProjector.buildSnapshot(
            state: state,
            strings: strings,
            nowMs: nowMs,
            sources: hostSources,
            eligibleProviderIds: eligibleProviderIds
        )
        let (requests, newRequestKeys) = stampRequests(built.requests, uptime: uptime, nowMs: nowMs)
        let snapshot = IslandViewSnapshot(
            rows: built.rows,
            requests: requests,
            notices: built.notices,
            summary: built.summary,
            telemetry: built.telemetry,
            quotas: built.quotas
        )

        // The Dock badge: approvals waiting and finished sessions unread.
        let badge: String? = state.notificationPrefs.dockBadgeEnabled && badgeCount > 0 ? "\(badgeCount)" : nil
        if badge != lastDockBadge {
            lastDockBadge = badge
            NSApp.dockTile.badgeLabel = badge
        }

        model.apply(snapshot: snapshot, strings: strings, visible: isEnabled)
        systemAlerts.withdrawRequests(except: Set(snapshot.requests.map(\.key)))

        // New approvals on a host that notifies, unless the user is looking at that session.
        var newRequests: [IslandPendingRequest] = []
        if !newRequestKeys.isEmpty, state.notificationPrefs.permissionNeeded {
            newRequests = snapshot.requests.filter { req in
                guard newRequestKeys.contains(req.key) else { return false }
                let hostId = req.hostId ?? SartoState.localHostID
                let viewingSameInFront = mainWindowForeground
                    && !state.showStudioHome
                    && hostId == state.activeHostID
                    && req.sessionId == state.selectedSessionID
                return state.shouldNotifyForHost(hostId) && !viewingSameInFront
            }
        }

        // With the island off, the same events arrive as macOS notifications instead.
        guard isEnabled else {
            let sound = state.notificationPrefs.soundEnabled
            var alerts = newRequests.map { req in
                SystemAlertNotifier.Alert(
                    id: SystemAlertNotifier.requestID(req.key),
                    title: req.title,
                    body: req.lines.first ?? "",
                    sessionId: req.sessionId,
                    sound: sound
                )
            }
            for pop in popsToEmit {
                let sessionId = pop.rowKey.components(separatedBy: "::").last
                alerts.append(SystemAlertNotifier.Alert(
                    id: "\(pop.kind):\(pop.rowKey)",
                    title: pop.title,
                    body: pop.body,
                    sessionId: sessionId,
                    sound: sound
                ))
            }
            systemAlerts.post(alerts)
            return
        }

        // The island opens to the approval card for the first new request; the card lists the rest.
        var didNotify = false
        if let firstNew = newRequests.first {
            model.pushPop(
                rowKey: firstNew.rowKey,
                kind: "permission",
                title: firstNew.title,
                body: firstNew.lines.first ?? ""
            )
            didNotify = true
        }

        for pop in popsToEmit {
            model.pushPop(rowKey: pop.rowKey, kind: pop.kind, title: pop.title, body: pop.body)
            didNotify = true
        }

        if didNotify, state.notificationPrefs.soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    private func sessionTitle(
        _ summary: SessionSummary,
        _ source: LiveHostIslandSource,
        _ state: SartoState,
        _ strings: IslandStrings
    ) -> String {
        let base = (summary.title?.isEmpty == false ? summary.title! : strings.text("untitled"))
        return (state.hasMultipleHosts && !source.isLocal) ? "\(base) · \(source.hostName)" : base
    }

    /// Whether to ask for a waiting session's replica now: first at once, then again after a
    /// wait that doubles up to a minute while the session still waits without one.
    private func snapshotDue(_ key: String, uptime: TimeInterval) -> Bool {
        if let retry = snapshotRetry[key] {
            guard uptime >= retry.due else { return false }
            let wait = min(60, retry.wait * 2)
            snapshotRetry[key] = (uptime + wait, wait)
        } else {
            snapshotRetry[key] = (uptime + 3, 3)
        }
        return true
    }

    private func requestSnapshot(_ sessionId: String, onHost hostId: String, state: SartoState) {
        Task { [weak state] in
            await state?.fetchSessionSnapshotIfNeeded(sessionId, onHost: hostId)
        }
    }

    /// Gives each request the time it was first seen, orders them by it, and returns the keys
    /// seen for the first time; a request gone for longer than `requestForgetAfter` is forgotten.
    private func stampRequests(
        _ requests: [IslandPendingRequest],
        uptime: TimeInterval,
        nowMs: Double
    ) -> (requests: [IslandPendingRequest], newKeys: Set<String>) {
        var newKeys = Set<String>()
        var stamped: [IslandPendingRequest] = []
        stamped.reserveCapacity(requests.count)
        for var request in requests {
            if let sighting = requestSightings[request.key] {
                request.askedAt = sighting.firstSeenMs
                requestSightings[request.key] = (sighting.firstSeenMs, uptime)
            } else {
                let firstSeen = min(request.askedAt ?? nowMs, nowMs)
                request.askedAt = firstSeen
                requestSightings[request.key] = (firstSeen, uptime)
                newKeys.insert(request.key)
            }
            stamped.append(request)
        }
        requestSightings = requestSightings.filter { uptime - $0.value.lastSeen < Self.requestForgetAfter }
        stamped.sort { lhs, rhs in
            let l = lhs.askedAt ?? .infinity
            let r = rhs.askedAt ?? .infinity
            return l != r ? l < r : lhs.key < rhs.key
        }
        return (stamped, newKeys)
    }

    // MARK: - IslandActionSink

    func islandOpenApp(sessionId: String?) {
        let hadVisibleWindow = bringMainWindowToFront()
        guard let sessionId else { return }
        Task { @MainActor [weak self] in
            if !hadVisibleWindow {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await self?.appState?.selectSession(sessionId)
        }
    }

    func islandStartNewSession() {
        let hadVisibleWindow = bringMainWindowToFront()
        if hadVisibleWindow {
            newSessionRequestToken += 1
        } else {
            // Give SwiftUI `openWindow(id: "main")` a brief 100ms yield so `MacWorkbenchView`
            // mounts and subscribes to `.onChange(of: island.newSessionRequestToken)` first.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.newSessionRequestToken += 1
            }
        }
    }

    /// Answers on the host that asked, whichever host is active, and reports only that answer's
    /// own outcome.
    func islandAnswerRequest(_ request: IslandPendingRequest, option: IslandRequestOption) async -> IslandAnswerNote {
        let offlineNote = IslandAnswerNote(
            text: model.strings.text("answerFailed", ["message": model.strings.text("offline")]),
            ok: false
        )
        guard let state = appState else { return offlineNote }
        let answers: [QuestionAnswer]? = {
            if let qIdx = option.questionIndex, let cIdx = option.choiceIndex {
                return [QuestionAnswer(question: qIdx, choices: [cIdx])]
            }
            return nil
        }()
        let optionId = answers == nil ? option.id : nil

        let failure = await state.respondPermission(
            sessionId: request.sessionId,
            requestId: request.requestId,
            optionId: optionId,
            answers: answers,
            onHost: request.hostId
        )
        let hostId = request.hostId ?? state.activeHostID
        snapshotRetry.removeValue(forKey: "\(hostId)::\(request.sessionId)")

        switch failure {
        case nil:
            return IslandAnswerNote(text: model.strings.text("answered"), ok: true)
        case .hostUnavailable?:
            return offlineNote
        case .failed(let message)?:
            let shown = message.isEmpty ? model.strings.text("offline") : message
            return IslandAnswerNote(text: model.strings.text("answerFailed", ["message": shown]), ok: false)
        }
    }

    func islandExpandedDidAppear() {
        let now = Date()
        guard now.timeIntervalSince(lastLimitsRefresh) >= 60 else { return }
        lastLimitsRefresh = now
        Task { [weak self] in
            await self?.appState?.refreshAgentLimits()
        }
    }

    func islandOpenMenuBarPanel(page: MenuBarPage) {
        openMenuBarPanel(page: page)
    }

    func islandOpenSettings(section: PrismSettingsSection?) {
        statusPanel?.close()
        onRequestOpenSettings?(section)
    }

    func islandToggleDisplay(_ display: DisplayInfo) {
        settingsStore.toggleIslandDisplay(display)
    }

    func islandUseAutomaticDisplays() {
        settingsStore.useAutomaticIslandDisplays()
    }

    func islandRequestHide() {
        isEnabled = false
    }

    func islandTriggerDemoPop() {
        guard isEnabled else { return }
        let lead = model.rows.first
        let title = lead.map { model.title(of: $0) } ?? model.strings.text("label")
        model.pushPop(
            rowKey: lead?.key,
            kind: "turn-ended",
            title: title,
            body: model.strings.text("pop.turnEndedBody"),
            agent: lead?.agent
        )
    }

    func islandTriggerDemoApproval() {
        guard isEnabled else { return }
        let lead = model.rows.first
        let demo = IslandPendingRequest(
            key: "demo#permission",
            sessionId: lead?.sessionId ?? "demo",
            requestId: "demo-req",
            rowKey: lead?.key ?? "",
            kind: "permission",
            title: model.strings.text("request.tool.execute"),
            lines: ["swift test --package-path apps/apple/Packages/SartoProtocol"],
            code: true,
            options: [
                IslandRequestOption(id: "deny", label: model.strings.text("request.answer.deny"), style: "deny", questionIndex: nil, choiceIndex: nil),
                IslandRequestOption(id: "once", label: model.strings.text("request.answer.allowOnce"), style: "allow_once", questionIndex: nil, choiceIndex: nil),
                IslandRequestOption(id: "always", label: model.strings.text("request.answer.allowAlways"), style: "allow_always", questionIndex: nil, choiceIndex: nil),
            ],
            askedAt: Date().timeIntervalSince1970 * 1000 - 12_000,
            isDemo: true
        )
        model.demoRequest = demo
        model.refresh(visible: true)
        model.expand(by: .request)
    }

    /// Settings' previews; they show only while the island is on, and never turn it on.
    func triggerPreviewPop() {
        islandTriggerDemoPop()
    }

    func triggerPreviewApproval() {
        islandTriggerDemoApproval()
    }

    private var hasVisibleMainWindow: Bool {
        NSApp.windows.contains { win in
            !(win is PrismIslandPanel)
                && !(win is NSPanel)
                && win.canBecomeMain
                && !(win.identifier?.rawValue.contains("prism-settings") ?? false)
                && win.isVisible
                && !win.isMiniaturized
        }
    }

    private func buildAppUsageFocus(state: SartoState, now: Date, mainVisible: Bool) -> AppUsageFocusContext? {
        guard state.connectionMode.isLive || !state.sessions.isEmpty || !state.agents.isEmpty else {
            return nil
        }

        let agentsById = Dictionary(state.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let appForeground = NSApp.isActive && mainVisible
        let isLocalHost = !state.connectionMode.isRemote

        func modelChoices(for agentId: String) -> [ConfigChoice] {
            state.agentOptionsById[agentId]?
                .config
                .first(where: { $0.category == "model" && $0.type == "select" })?
                .choices ?? []
        }

        func sessionModelHints(for summary: SessionSummary) -> [String] {
            if let opt = state.replicas[summary.id]?.session.config.first(where: { $0.category == "model" && $0.type == "select" }) {
                return Self.resolveModelHints(rawValue: opt.value.stringValue, choices: opt.choices ?? [])
            }
            return Self.resolveModelHints(rawValue: summary.model, choices: modelChoices(for: summary.agentId))
        }

        func isSessionLive(_ summary: SessionSummary) -> Bool {
            summary.status == .running
                || summary.status == .starting
                || summary.status == .awaitingPermission
                || summary.permissionCount > 0
        }

        // Best listed session per usage provider (live sessions first, then most recently updated).
        var bestByProvider: [String: AppUsageFocusCandidate] = [:]
        for summary in state.sessions where IslandProjector.isListed(summary) {
            let harnessId = agentsById[summary.agentId]?.harnessId
            guard let providerId = LiveUsageSources.providerId(forAgentId: summary.agentId, harnessId: harnessId) else {
                continue
            }
            let live = isSessionLive(summary)
            let tsMs = live ? max(summary.updatedAt, summary.turnStartedAt ?? 0) : summary.updatedAt
            let activityAt = tsMs > 0 ? Date(timeIntervalSince1970: tsMs / 1000) : .distantPast
            let candidate = AppUsageFocusCandidate(
                providerId: providerId,
                modelHints: sessionModelHints(for: summary),
                activityAt: activityAt,
                isWorkbenchSelection: false,
                isLiveSession: live,
                isLocalHost: isLocalHost
            )
            if let existing = bestByProvider[providerId] {
                let beats = (candidate.isLiveSession && !existing.isLiveSession)
                    || (candidate.isLiveSession == existing.isLiveSession && candidate.activityAt > existing.activityAt)
                if beats {
                    bestByProvider[providerId] = candidate
                }
            } else {
                bestByProvider[providerId] = candidate
            }
        }
        let recentSessions = bestByProvider.values.sorted { lhs, rhs in
            if lhs.isLiveSession != rhs.isLiveSession { return lhs.isLiveSession }
            return lhs.activityAt > rhs.activityAt
        }

        // Current workbench selection (New Session stage, pending agent switch, or open session).
        let workbench: AppUsageFocusCandidate? = {
            let agentId: String
            let sessionId: String?
            let modelHints: [String]
            let sessionUpdatedAt: Date?
            let live: Bool

            if state.showStudioHome {
                guard !state.agents.isEmpty else { return nil }
                agentId = state.selectedAgentID
                sessionId = nil
                let opt = state.activeModelConfigOption
                modelHints = Self.resolveModelHints(rawValue: opt?.value.stringValue, choices: opt?.choices ?? [])
                sessionUpdatedAt = nil
                live = false
            } else if let pendingId = state.pendingSwitchAgentID {
                agentId = pendingId
                sessionId = state.selectedSessionSummary?.id
                let opt = state.activeModelConfigOption
                modelHints = Self.resolveModelHints(rawValue: opt?.value.stringValue, choices: opt?.choices ?? [])
                if let summary = state.selectedSessionSummary, summary.updatedAt > 0 {
                    sessionUpdatedAt = Date(timeIntervalSince1970: summary.updatedAt / 1000)
                } else {
                    sessionUpdatedAt = nil
                }
                live = false
            } else if let summary = state.selectedSessionSummary {
                agentId = state.activeReplica?.session.agentId ?? summary.agentId
                sessionId = summary.id
                if let opt = state.activeModelConfigOption {
                    modelHints = Self.resolveModelHints(rawValue: opt.value.stringValue, choices: opt.choices ?? [])
                } else {
                    modelHints = Self.resolveModelHints(rawValue: summary.model, choices: modelChoices(for: agentId))
                }
                let tsMs = max(summary.updatedAt, summary.turnStartedAt ?? 0)
                sessionUpdatedAt = tsMs > 0 ? Date(timeIntervalSince1970: tsMs / 1000) : nil
                live = isSessionLive(summary)
            } else {
                return nil
            }

            let key = WorkbenchFocusKey(
                showStudioHome: state.showStudioHome,
                sessionId: sessionId,
                agentId: agentId,
                modelHints: modelHints
            )

            if !hasInitializedWorkbenchFocus {
                if state.connectionMode.isLive && !state.agents.isEmpty {
                    hasInitializedWorkbenchFocus = true
                    lastWorkbenchFocusKey = key
                    workbenchSelectedAt = sessionUpdatedAt
                }
            } else if key != lastWorkbenchFocusKey {
                let prev = lastWorkbenchFocusKey
                // Async hydration filling in model hints for an already-selected background session
                // should not look like a fresh user click.
                let isBackgroundHydration = !appForeground
                    && prev?.showStudioHome == key.showStudioHome
                    && prev?.sessionId == key.sessionId
                    && prev?.agentId == key.agentId
                    && prev?.modelHints.isEmpty == true
                if !isBackgroundHydration {
                    workbenchSelectedAt = now
                }
                lastWorkbenchFocusKey = key
            }

            let harnessId = agentsById[agentId]?.harnessId
            guard let providerId = LiveUsageSources.providerId(forAgentId: agentId, harnessId: harnessId) else {
                return nil
            }
            let effectiveAt = max(workbenchSelectedAt ?? .distantPast, sessionUpdatedAt ?? .distantPast)
            return AppUsageFocusCandidate(
                providerId: providerId,
                modelHints: modelHints,
                activityAt: effectiveAt,
                isWorkbenchSelection: true,
                isLiveSession: live,
                isLocalHost: isLocalHost
            )
        }()

        return AppUsageFocusContext(
            isAppForeground: appForeground,
            hasVisibleMainWindow: mainVisible,
            workbench: workbench,
            recentSessions: recentSessions
        )
    }

    private static func resolveModelHints(rawValue: String?, choices: [ConfigChoice]) -> [String] {
        var out: [String] = []
        func add(_ candidate: String?) {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty
            else { return }
            let lower = raw.lowercased()
            if lower == "default" || lower.hasPrefix("default ") || lower.hasPrefix("default(") {
                return
            }
            if !out.contains(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
                out.append(raw)
            }
        }

        let directChoice = rawValue.flatMap { val in choices.first { $0.value == val } }
        let shownChoice = directChoice?.shownAs.flatMap { alias in
            alias.isEmpty ? nil : choices.first { $0.value == alias }
        }

        add(shownChoice?.modelId)
        add(directChoice?.modelId)
        add(shownChoice?.value)
        add(directChoice?.shownAs)
        add(shownChoice?.name)
        add(rawValue)
        add(directChoice?.name)
        return out
    }

    /// Activates Sarto and brings its main workbench window to front, returning `true` when
    /// an existing visible main window was already mounted.
    @discardableResult
    private func bringMainWindowToFront() -> Bool {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            !($0 is PrismIslandPanel)
                && !($0 is NSPanel)
                && $0.canBecomeMain
                && !($0.identifier?.rawValue.contains("prism-settings") ?? false)
        }) {
            let wasVisible = window.isVisible && !window.isMiniaturized
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return wasVisible
        } else {
            onRequestOpenMainWindow?()
            return false
        }
    }
}

/// What the island's tokens and status item label are built from; `PrismTokens` itself cannot be compared.
private struct IslandThemeKey: Equatable {
    let palette: PrismPalette
    let accent: PrismAccentMode
    /// Only for the status item's localized label.
    let language: PrismLanguage
}

private struct WorkbenchFocusKey: Equatable {
    let showStudioHome: Bool
    let sessionId: String?
    let agentId: String
    let modelHints: [String]
}
