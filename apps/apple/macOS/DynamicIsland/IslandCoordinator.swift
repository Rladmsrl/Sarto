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
    let rpgStore = AgentRPGStore()
    let launchAtLogin = PrismLaunchAtLogin()
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

    private var previousStatuses: [String: SessionStatus] = [:]
    /// Each session's last turn ending as last seen, so an ending that arrives after its status
    /// change, or a failure a later limit notice turns into a limit, still pops.
    private var previousEndings: [String: LastTurn] = [:]
    private var previousRequestKeys: Set<String> = []
    /// Live-transition unread sessions keyed as `hostId::sessionId`, pruned against host-side
    /// `summary.attention == "unread"` and the current notification host scope.
    private var unreadSessionKeys: Set<String> = []
    /// Tracks background sessions for which a permission snapshot fetch has already been requested
    /// in the current connection cycle, preventing an infinite 12-16Hz RPC loop when a session's
    /// replica remains nil or has no pending tool entries.
    private var snapshotRequestedSessionIDs: Set<String> = []
    /// Tracks running sessions with active plans whose full step list has been requested once.
    private var planSnapshotRequestedSessionIDs: Set<String> = []
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

        NumFont.register()
        Fmt.symbol = "$"
        IslandMarkImageCache.warmUp()

        syncTheme(from: state)

        if islandHub == nil {
            islandHub = PrismIslandHub(
                model: model,
                usageStore: usageStore,
                settingsStore: settingsStore
            )
        }

        if statusPanel == nil {
            setupStatusPanel(state: state)
        }

        applySettings(settingsStore.settings)
        installUsageSubscriptions()
        usageStore.start()
        state.onWorkFacts = { [weak self] hostId, facts in
            self?.receiveWorkFacts(facts, fromHost: hostId)
        }
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

    /// Hands the facts hosts tell of their sessions' work to the Agent RPG, while its game is on.
    private func receiveWorkFacts(_ facts: [WorkFact], fromHost hostId: String) {
        guard let state = appState,
              settingsStore.settings.islandMotion.enablesIdleGame,
              !facts.isEmpty
        else { return }
        rpgStore.apply(facts) { agentId in
            guard let agent = state.agentStatus(agentId, onHost: hostId) else { return nil }
            return (agent.name, agent.harnessId ?? agentId)
        }
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
            setPinned: { [weak self] pinned in
                self?.statusPanel?.pinned = pinned
            },
            previewPop: { [weak self] in
                guard let self else { return }
                if !self.isEnabled { self.isEnabled = true }
                self.statusPanel?.close()
                self.islandTriggerDemoPop()
            },
            previewApproval: { [weak self] in
                guard let self else { return }
                if !self.isEnabled { self.isEnabled = true }
                self.statusPanel?.close()
                self.islandTriggerDemoApproval()
            },
            refresh: { [weak self] in
                guard let self else { return }
                self.snapshotRequestedSessionIDs.removeAll()
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
                    launch: self.launchAtLogin,
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
                self.snapshotRequestedSessionIDs.removeAll()
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
                self.model.hasLowUsageAlert = self.usageStore.lowestWindow != nil
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
                      !self.settingsStore.settings.subtleReminders,
                      self.isEnabled
                else { return }
                switch event {
                case .runningLow(let provider, let label, let remaining, _):
                    let remPct = Int((remaining * 100).rounded())
                    let usedPct = max(0, min(100, (1 - remaining) * 100))
                    self.model.pushPop(
                        rowKey: nil,
                        kind: "limit-near",
                        title: provider.name,
                        body: self.currentStrings.text(
                            "pop.lowUsageBody",
                            ["window": label, "percent": "\(remPct)"]
                        ),
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
    }

    private func applySettings(_ settings: UsageIslandSettings) {
        let stack = IslandStackOptions(
            enabled: settings.islandSessionStack,
            maxRows: settings.islandMaxRows,
            showQuota: settings.islandShowQuota,
            motion: settings.islandMotion
        )
        if model.stackOptions != stack { model.stackOptions = stack }
        if _islandEnabledMirror != settings.islandEnabled {
            _islandEnabledMirror = settings.islandEnabled
        }
        if _menubarEnabledMirror != settings.menubarEnabled {
            _menubarEnabledMirror = settings.menubarEnabled
        }
        if islandDisplays != settings.islandDisplays {
            islandDisplays = settings.islandDisplays
        }

        statusPanel?.statusItemVisible = settings.menubarEnabled
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

    private func refreshDisplayMenu() {
        let activeIDs = Set(Displays.screens(for: settingsStore.settings.islandDisplays).map(Displays.id(of:)))
        let items = Displays.all().map { IslandDisplayMenuItem(display: $0, isActive: activeIDs.contains($0.id)) }
        if model.displayMenuItems != items {
            model.displayMenuItems = items
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
        if settingsStore.settings.islandMotion.enablesIdleGame,
           let telemetry,
           let agentId = state.selectedSessionSummary?.agentId {
            rpgStore.recordTelemetry(
                agentId: agentId,
                tps: telemetry.tps,
                cacheHit: telemetry.cacheHitPercent
            )
        }
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
        let strings = IslandStrings(language: state.language)
        let nowMs = Date().timeIntervalSince1970 * 1000

        if state.connectionMode != previousConnectionMode {
            previousConnectionMode = state.connectionMode
            snapshotRequestedSessionIDs.removeAll()
            hasInitializedWorkbenchFocus = false
            lastWorkbenchFocusKey = nil
            workbenchSelectedAt = nil
        }

        let nextAppUsageFocus = buildAppUsageFocus(state: state, now: Date())
        if model.appUsageFocus != nextAppUsageFocus {
            model.appUsageFocus = nextAppUsageFocus
        }

        // Sarto in front with its running panel on: the panel says what runs, so the island keeps
        // quiet about anything that does not need the user.
        let railOn = UserDefaults.standard.object(forKey: "sarto.runningRail.enabled") as? Bool ?? true
        let quiet = NSApp.isActive && hasVisibleMainWindow && railOn
        if model.quietForeground != quiet { model.quietForeground = quiet }

        // Reconcile foreground session visibility with active and pooled hosts so every host tracks
        // `inFront` and `attention` accurately across synced devices.
        let appFocused = NSApp.isActive
        let mainWindowForeground = appFocused && hasVisibleMainWindow
        state.updateForegroundPresence(isInForeground: mainWindowForeground)

        // Clear unread flag once the user views that session in the foreground main window.
        if mainWindowForeground, !state.showStudioHome, let selected = state.selectedSessionID {
            unreadSessionKeys.remove("\(state.activeHostID)::\(selected)")
        }

        // Auto-fetch snapshots across all online hosts (local + pooled remotes) at most once per
        // awaiting-permission transition so an unloaded replica never triggers a 16Hz RPC loop.
        let hostSources = state.allLiveHostSourcesForIsland()
        var awaitingKeys = Set<String>()
        var activePlanKeys = Set<String>()
        for source in hostSources {
            for summary in source.sessions where IslandProjector.isListed(summary) {
                let scopedKey = "\(source.hostId)::\(summary.id)"
                if summary.permissionCount > 0 || summary.status == .awaitingPermission {
                    awaitingKeys.insert(scopedKey)
                }
                if (summary.status == .running || summary.status == .starting || summary.status == .awaitingPermission)
                    && (summary.plan.map { $0.total > 0 && $0.done < $0.total } ?? false) {
                    activePlanKeys.insert(scopedKey)
                }
            }
        }
        snapshotRequestedSessionIDs.formIntersection(awaitingKeys)
        planSnapshotRequestedSessionIDs.formIntersection(activePlanKeys)

        for source in hostSources {
            for summary in source.sessions where IslandProjector.isListed(summary) {
                let scopedKey = "\(source.hostId)::\(summary.id)"
                if awaitingKeys.contains(scopedKey) {
                    let hasPending = (source.replicas[summary.id]?.pendingTools.isEmpty == false)
                    if !hasPending, snapshotRequestedSessionIDs.insert(scopedKey).inserted {
                        let sid = summary.id
                        let hid = source.hostId
                        Task { [weak state] in
                            await state?.fetchSessionSnapshotIfNeeded(sid, onHost: hid)
                        }
                    }
                }
                if activePlanKeys.contains(scopedKey) {
                    if source.replicas[summary.id] == nil, planSnapshotRequestedSessionIDs.insert(scopedKey).inserted {
                        let sid = summary.id
                        let hid = source.hostId
                        Task { [weak state] in
                            await state?.fetchSessionSnapshotIfNeeded(sid, onHost: hid)
                        }
                    }
                }
            }
        }

        // Detect live status transitions across all online hosts for automatic Pops & permission alerts.
        // Only this Mac and the currently active remote host emit notifications, pops, or badge counts.
        var popsToEmit: [(rowKey: String, kind: String, title: String, body: String)] = []
        var activeUnreadKeys = Set<String>()
        let initialized = !previousStatuses.isEmpty

        for source in hostSources {
            let shouldNotify = state.shouldNotifyForHost(source.hostId)
            for summary in source.sessions where IslandProjector.isListed(summary) {
                let trackKey = "\(source.hostId)::\(summary.id)"
                let rowKey = source.isLocal ? summary.id : trackKey
                if shouldNotify && summary.attention == "unread" {
                    activeUnreadKeys.insert(trackKey)
                }
                let prev = previousStatuses[trackKey]
                previousStatuses[trackKey] = summary.status
                let prevEnding = previousEndings[trackKey]
                let ending = summary.lastTurn
                previousEndings[trackKey] = ending
                guard initialized, let prev else { continue }
                let statusChanged = prev != summary.status
                let errorEndingArrived = ending != prevEnding && ending?.reason.isError == true
                guard statusChanged || errorEndingArrived else { continue }
                guard shouldNotify else { continue }

                let viewingInFront = mainWindowForeground
                    && !state.showStudioHome
                    && state.activeHostID == source.hostId
                    && state.selectedSessionID == summary.id
                let baseTitle = (summary.title?.isEmpty == false ? summary.title! : strings.text("untitled"))
                let sessionTitle = (state.hasMultipleHosts && !source.isLocal)
                    ? "\(baseTitle) · \(source.hostName)"
                    : baseTitle
                let endingPop = IslandProjector.endingPop(ending, strings: strings, nowMs: nowMs)
                let errorPop = endingPop.flatMap { $0.kind == "turn-ended" ? nil : $0 }
                let hostHasUnread = summary.attention == "unread"
                let hostHasError = summary.status == .failed || summary.attention == "error"

                if statusChanged && (prev == .running || prev == .starting || prev == .awaitingPermission) && summary.status == .ready {
                    if !viewingInFront {
                        if let errorPop {
                            if hostHasError || hostHasUnread {
                                if hostHasUnread {
                                    unreadSessionKeys.insert(trackKey)
                                }
                                if state.notificationPrefs.error {
                                    popsToEmit.append((rowKey, errorPop.kind, sessionTitle, errorPop.body))
                                }
                            }
                        } else if hostHasUnread {
                            unreadSessionKeys.insert(trackKey)
                            if state.notificationPrefs.turnEnded {
                                let body = endingPop?.body ?? strings.text("pop.turnEndedBody")
                                popsToEmit.append((rowKey, "turn-ended", sessionTitle, body))
                            }
                        }
                    }
                } else if statusChanged && prev != .failed && summary.status == .failed {
                    if !viewingInFront, state.notificationPrefs.error {
                        popsToEmit.append((
                            rowKey,
                            errorPop?.kind ?? "error",
                            sessionTitle,
                            errorPop?.body ?? strings.text("pop.errorBody")
                        ))
                    }
                } else if errorEndingArrived, summary.status == .ready || summary.status == .failed, let errorPop {
                    if !viewingInFront, (hostHasError || hostHasUnread), state.notificationPrefs.error {
                        popsToEmit.append((rowKey, errorPop.kind, sessionTitle, errorPop.body))
                    }
                }
            }
        }

        // Prune unread entries that were read on any device, removed, or belong to a non-notifying host.
        unreadSessionKeys.formIntersection(activeUnreadKeys)

        let snapshot = IslandProjector.buildSnapshot(
            state: state,
            strings: strings,
            unreadSessionKeys: unreadSessionKeys,
            nowMs: nowMs,
            sources: hostSources
        )

        if settingsStore.settings.islandMotion.enablesIdleGame {
            rpgStore.noteConcurrency(running: snapshot.summary.running)
        }

        // Update Dock badge count when enabled (local host + currently active remote host only).
        if state.notificationPrefs.dockBadgeEnabled {
            let badgeRequestsCount = snapshot.requests.reduce(0) { acc, req in
                let hostId = req.hostId ?? SartoState.localHostID
                return acc + (state.shouldNotifyForHost(hostId) ? 1 : 0)
            }
            let badgeTotal = badgeRequestsCount + unreadSessionKeys.count
            NSApp.dockTile.badgeLabel = badgeTotal > 0 ? "\(badgeTotal)" : nil
        } else if NSApp.dockTile.badgeLabel != nil {
            NSApp.dockTile.badgeLabel = nil
        }

        model.apply(snapshot: snapshot, strings: strings, visible: isEnabled)

        guard isEnabled else { return }

        // Automatically open the island to the approval card whenever a brand-new pending permission arrives.
        let nextRequestKeys = Set(snapshot.requests.map(\.key))
        let newRequests = nextRequestKeys.subtracting(previousRequestKeys)
        previousRequestKeys = nextRequestKeys
        var didNotify = false
        if !newRequests.isEmpty, state.notificationPrefs.permissionNeeded {
            let firstNew = snapshot.requests.first { req in
                guard newRequests.contains(req.key) else { return false }
                let hostId = req.hostId ?? SartoState.localHostID
                return state.shouldNotifyForHost(hostId)
            }
            if let firstNew {
                let firstHostId = firstNew.hostId ?? SartoState.localHostID
                let viewingSameInFront = mainWindowForeground
                    && !state.showStudioHome
                    && firstHostId == state.activeHostID
                    && firstNew.sessionId == state.selectedSessionID
                if !viewingSameInFront {
                    model.pushPop(
                        rowKey: firstNew.rowKey,
                        kind: "permission",
                        title: firstNew.title,
                        body: firstNew.lines.first ?? ""
                    )
                    didNotify = true
                }
            }
        }

        for pop in popsToEmit {
            model.pushPop(rowKey: pop.rowKey, kind: pop.kind, title: pop.title, body: pop.body)
            didNotify = true
        }

        if didNotify, state.notificationPrefs.soundEnabled {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    // MARK: - IslandActionSink

    func islandOpenApp(sessionId: String?) {
        let hadVisibleWindow = bringMainWindowToFront()
        guard let sessionId else { return }
        unreadSessionKeys = unreadSessionKeys.filter { !$0.hasSuffix("::\(sessionId)") }
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

    func islandAnswerRequest(_ request: IslandPendingRequest, option: IslandRequestOption) async -> IslandAnswerNote {
        guard let state = appState, state.connectionMode.isLive else {
            return IslandAnswerNote(
                text: model.strings.text("answerFailed", ["message": model.strings.text("offline")]),
                ok: false
            )
        }
        let answers: [QuestionAnswer]? = {
            if let qIdx = option.questionIndex, let cIdx = option.choiceIndex {
                return [QuestionAnswer(question: qIdx, choices: [cIdx])]
            }
            return nil
        }()
        let optionId = answers == nil ? option.id : nil

        state.connectionError = nil
        await state.respondPermission(
            sessionId: request.sessionId,
            requestId: request.requestId,
            optionId: optionId,
            answers: answers,
            onHost: request.hostId
        )
        let respondError = state.connectionError
        if let hid = request.hostId {
            snapshotRequestedSessionIDs.remove("\(hid)::\(request.sessionId)")
        } else {
            snapshotRequestedSessionIDs.remove(request.sessionId)
        }
        await state.fetchSessionSnapshotIfNeeded(request.sessionId, onHost: request.hostId)

        if let err = respondError, !err.isEmpty {
            return IslandAnswerNote(text: model.strings.text("answerFailed", ["message": err]), ok: false)
        }
        if let fetchErr = state.connectionError, !fetchErr.isEmpty {
            return IslandAnswerNote(text: model.strings.text("answerFailed", ["message": fetchErr]), ok: false)
        }
        return IslandAnswerNote(text: model.strings.text("answered"), ok: true)
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

    func islandRequestHide() {
        isEnabled = false
    }

    func islandTriggerDemoPop() {
        guard isEnabled else { return }
        let lead = model.rows.first
        let title = lead.map { model.title(of: $0) } ?? "Sarto Dynamic Island"
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

    func triggerPreviewPop() {
        if !isEnabled { isEnabled = true }
        islandTriggerDemoPop()
    }

    func triggerPreviewApproval() {
        if !isEnabled { isEnabled = true }
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

    private func buildAppUsageFocus(state: SartoState, now: Date) -> AppUsageFocusContext? {
        guard state.connectionMode.isLive || !state.sessions.isEmpty || !state.agents.isEmpty else {
            return nil
        }

        let agentsById = Dictionary(state.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mainVisible = hasVisibleMainWindow
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
