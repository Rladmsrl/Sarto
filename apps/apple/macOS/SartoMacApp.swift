import AppKit
import Darwin
import SartoProtocol
import SartoUpdate
import PrismDesign
import SwiftUI
import SystemConfiguration

@MainActor
final class PrismMacAppDelegate: NSObject, NSApplicationDelegate {
    private static let reopenNotificationName = Notification.Name("dev.sarto.mac.reopenMainWindow")

    struct QuitDialogCopy {
        let menuBarTitle: String
        let menuBarBody: String
        let quitCompletely: String
        let cancel: String
    }

    var onReopenMainWindow: (() -> Void)?
    var onWillTerminate: (() -> Void)?
    /// Runs last as the app quits for an update, which has been installed: schedules the relaunch.
    private var afterTermination: (() -> Void)?
    /// Set once a launch that an automatic update asked to stay in the menu bar has hidden its window.
    var appliedLaunchHidden = false

    /// Whether a window of Sarto's is open, minimized ones included.
    var showsWindows: Bool { hasAnyOpenStandardWindow() }
    var onEnsureMenuBarVisible: (() -> Void)?
    var makeQuitCopy: (() -> QuitDialogCopy)?
    var onSystemAppearanceChanged: ((Bool) -> Void)?

    private var appearanceObservation: NSKeyValueObservation?
    private var windowCloseObserver: NSObjectProtocol?
    private var distributedReopenObserver: NSObjectProtocol?
    private var singleInstanceLockFD: Int32 = -1
    private var confirmedCompleteQuit = false
    /// Set when the user logs out, restarts or shuts down, the one time a quit from outside the
    /// menu bar really quits.
    private var systemSessionEnding = false
    private var powerOffObserver: NSObjectProtocol?
    let quitCountdown = QuitCountdown()

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !acquireSingleInstanceLock() {
            DistributedNotificationCenter.default().postNotificationName(
                Self.reopenNotificationName,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            let myPID = ProcessInfo.processInfo.processIdentifier
            if let bundleID = Bundle.main.bundleIdentifier {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                where running.processIdentifier != myPID {
                    running.activate(options: [.activateAllWindows])
                }
            }
            Darwin._exit(0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SartoAppIconManager.applySavedFromDefaults()
        DispatchQueue.main.async {
            SartoAppIconManager.applySavedFromDefaults()
        }

        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemSessionEnding = true }
        }

        distributedReopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.restoreRegularDockPresence()
                self.onReopenMainWindow?()
            }
        }

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self?.onSystemAppearanceChanged?(isDark)
            }
        }

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let closedWindow = note.object as? NSWindow
            Task { @MainActor [weak self] in
                guard let self, !self.confirmedCompleteQuit else { return }
                if let win = closedWindow, self.isStandardAppWindow(win) {
                    // Defer one runloop turn so `win.isVisible` reflects the closed state.
                    DispatchQueue.main.async { [weak self] in
                        self?.syncActivationPolicyForOpenWindows()
                    }
                }
            }
        }
    }

    /// Keep Sarto alive in the Menu Bar & Dynamic Island even when the user closes all windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func restoreRegularDockPresence() {
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        SartoAppIconManager.applySavedFromDefaults()
    }

    func hideToMenuBarResident() {
        onEnsureMenuBarVisible?()
        for win in NSApp.windows where isStandardAppWindow(win) && (win.isVisible || win.isMiniaturized) {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.close()
        }
        if NSApp.activationPolicy() != .accessory {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    func syncActivationPolicyForOpenWindows() {
        guard !confirmedCompleteQuit else { return }
        let hasOpenWindow = hasAnyOpenStandardWindow()
        if !hasOpenWindow {
            onEnsureMenuBarVisible?()
            if NSApp.activationPolicy() != .accessory {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        } else if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
            SartoAppIconManager.applySavedFromDefaults()
        }
    }

    /// Invoked from the Menu Bar power button (or ⌘Q while inside the Menu Bar popover).
    func requestCompleteQuitFromMenuBar() {
        let copy = resolvedQuitCopy()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = copy.menuBarTitle
        alert.informativeText = copy.menuBarBody
        let quitBtn = alert.addButton(withTitle: copy.quitCompletely)
        quitBtn.hasDestructiveAction = true
        alert.addButton(withTitle: copy.cancel)

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            confirmedCompleteQuit = true
            NSApp.terminate(nil)
        }
    }

    /// ⌘Q, through the app menu's own item: asks twice, then closes the windows (`QuitCountdown`).
    func quitShortcutPressed() {
        let anchor = NSApp.keyWindow.flatMap { isStandardAppWindow($0) ? $0 : nil }
            ?? NSApp.windows.first { isStandardAppWindow($0) && $0.isVisible && !$0.isMiniaturized }
        quitCountdown.press(over: anchor)
    }

    /// Quits for an update the user restarted for, once it is installed: the quit is let through,
    /// and `then` runs after everything else at termination.
    func quitForUpdate(then: @escaping () -> Void) {
        afterTermination = then
        confirmedCompleteQuit = true
        NSApp.terminate(nil)
    }

    /// Only the menu bar quits Sarto and its daemon. Any other quit, as from the Dock or a script,
    /// closes the windows instead, except when the session ends, which must not be held up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmedCompleteQuit || systemSessionEnding || isSessionEndingQuitEvent() {
            confirmedCompleteQuit = true
            return .terminateNow
        }
        hideToMenuBarResident()
        return .terminateCancel
    }

    /// A quit Apple event sent for a logout, restart or shutdown, should the power-off notice not
    /// have come first.
    private func isSessionEndingQuitEvent() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEQuitApplication)
        else { return false }
        let keyword = AEKeyword(kAEQuitReason)
        guard let reason = (event.attributeDescriptor(forKeyword: keyword)
            ?? event.paramDescriptor(forKeyword: keyword))?.enumCodeValue
        else { return false }
        let sessionEnding = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
        return sessionEnding.contains { OSType($0) == reason }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        restoreRegularDockPresence()
        let hasMainVisible = sender.windows.contains { win in
            win.isVisible && !win.isMiniaturized && (win.identifier?.rawValue.contains("main") == true)
        }
        if !flag || !hasMainVisible {
            onReopenMainWindow?()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
        afterTermination?()
        afterTermination = nil
        if singleInstanceLockFD >= 0 {
            Darwin.close(singleInstanceLockFD)
            singleInstanceLockFD = -1
        }
    }

    /// Acquires a kernel-managed `F_SETLK` write lock across all bundle paths (`/Applications`, Xcode DerivedData, `/tmp`)
    /// so launching a second `.app` copy wakes the existing Menu Bar resident instead of spawning a duplicate.
    /// Set `SARTO_ALLOW_MULTI_INSTANCE=1` to run an isolated preview copy beside another running build.
    private func acquireSingleInstanceLock() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SARTO_ALLOW_MULTI_INSTANCE"] == "1" {
            return true
        }
        // Not in the daemon's data folder, which the daemon makes itself so it can move an older
        // one into its place.
        let lock = SartoAppPaths.instanceLock(dataDirectory: SartoDaemonPaths.defaultDataDirectory())
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = lock.path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return true }
        var fl = Darwin.flock(
            l_start: 0,
            l_len: 0,
            l_pid: Darwin.getpid(),
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        if Darwin.fcntl(fd, F_SETLK, &fl) == -1 {
            Darwin.close(fd)
            return false
        }
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        singleInstanceLockFD = fd
        return true
    }

    private func isStandardAppWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain
    }

    private func hasAnyOpenStandardWindow() -> Bool {
        NSApp.windows.contains { win in
            isStandardAppWindow(win) && (win.isVisible || win.isMiniaturized)
        }
    }

    private func resolvedQuitCopy() -> QuitDialogCopy {
        makeQuitCopy?() ?? QuitDialogCopy(
            menuBarTitle: "Quit Sarto Completely?",
            menuBarBody: "Quitting completely will stop the background daemon and remote connections.",
            quitCompletely: "Quit Completely",
            cancel: "Cancel"
        )
    }
}

/// The sync approval requests already brought to the user's attention in this run.
@MainActor
private final class AnnouncedApprovals {
    var deviceIds: Set<String> = []
}

@main
struct SartoMacApp: App {
    @NSApplicationDelegateAdaptor(PrismMacAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var appState = SartoState()
    @State private var daemonManager = LocalDaemonManager()
    @State private var islandCoordinator = PrismDynamicIslandCoordinator()
    @State private var settingsRouter = PrismSettingsRouter()
    @State private var updater = SartoUpdater()
    @State private var problemReport = ProblemReportCoordinator()
    @State private var didWireAppLifecycle = false
    @State private var didBootstrapBoundDaemon = false
    @State private var announcedApprovals = AnnouncedApprovals()
    @State private var syncApprovalPanel = SyncApprovalPanelController()
    @State private var pushSyncTask: Task<Void, Never>? = nil
    @State private var lastObservedIslandSettings: UsageIslandSettings? = nil

    var body: some Scene {
        Window("Sarto", id: "main") {
            MacWorkbenchView(
                state: appState,
                daemon: daemonManager,
                island: islandCoordinator,
                settingsRouter: settingsRouter
            )
            .frame(minWidth: 1020, minHeight: 660)
            .environment(updater)
            .environment(problemReport)
            .focusEffectDisabled()
            .onAppear {
                wireAppLifecycle()
            }
            .onChange(of: appState.appIconStyle) { _, next in
                SartoAppIconManager.apply(next)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(appState.l10n.tr("settings.updates.menuCheck")) {
                    wireAppLifecycle()
                    settingsRouter.open(section: .advancedAndAbout, rowID: "advanced.updates")
                    Task { await updater.check() }
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button(appState.l10n.tr("quitHint.menuItem")) {
                    appDelegate.quitShortcutPressed()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button(appState.l10n.tr("settings.menuOpen")) {
                    wireAppLifecycle()
                    settingsRouter.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(appState.l10n.tr("sidebar.searchSessions")) {
                    appState.showGlobalSearchSheet = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button(appState.l10n.tr("report.menuItem")) {
                    wireAppLifecycle()
                    let isRemote = appState.activeHostID != SartoState.localHostID
                    let remoteName = isRemote
                        ? appState.otherHosts.first(where: { $0.id == appState.activeHostID })?.name
                        : nil
                    problemReport.open(
                        target: .main,
                        remoteHostId: isRemote ? appState.activeHostID : nil,
                        remoteHostName: remoteName
                    )
                }
                Divider()
                Button(appState.l10n.tr("privacy.menuPolicy")) {
                    if let url = appState.privacyPolicyURL {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Window(appState.l10n.tr("settings.windowTitle"), id: "prism-settings") {
            PrismSettingsWindowView(
                state: appState,
                daemon: daemonManager,
                island: islandCoordinator,
                router: settingsRouter
            )
            .environment(updater)
            .environment(problemReport)
            .focusEffectDisabled()
            .onAppear {
                wireAppLifecycle()
            }
            .onChange(of: appState.appIconStyle) { _, next in
                SartoAppIconManager.apply(next)
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 920, height: 640)
    }

    private func wireAppLifecycle() {
        guard !didWireAppLifecycle else { return }
        didWireAppLifecycle = true
        let reopenMain: () -> Void = { [appDelegate] in
            appDelegate.restoreRegularDockPresence()
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        let openSettingsWindow: () -> Void = { [appDelegate] in
            appDelegate.restoreRegularDockPresence()
            openWindow(id: "prism-settings")
            NSApp.activate(ignoringOtherApps: true)
        }

        settingsRouter.openWindowAction = openSettingsWindow
        problemReport.onRequestOpenMainWindow = reopenMain
        problemReport.checkAndMarkRunningOnLaunch()
        appState.onHostOpenSettings = { [settingsRouter] section, item, row in
            settingsRouter.openFromHost(section: section, item: item, row: row)
        }
        appState.onHostAppUpdateCommand = { [updater] action in
            Task { @MainActor in
                await updater.handleRemoteCommand(action)
            }
        }
        appState.onLocalDaemonAttached = { [appState, updater] in
            let snapshot = updater.statusSnapshot()
            Task { @MainActor in
                await appState.reportLocalAppUpdateState(snapshot)
            }
        }
        appDelegate.onReopenMainWindow = reopenMain
        appDelegate.onEnsureMenuBarVisible = { [islandCoordinator] in
            if !islandCoordinator.isMenuBarEnabled {
                islandCoordinator.isMenuBarEnabled = true
            }
        }
        appDelegate.onWillTerminate = { [daemonManager, appState, updater, problemReport] in
            problemReport.removeCrashMarkerOnCleanQuit()
            appState.flushDraftsNow()
            // A quit that installs an update waits for the daemon, whose files it replaces.
            daemonManager.shutdownBoundDaemon(patience: updater.installsOnQuit ? 9 : 1.2)
            updater.installOnQuit()
        }
        updater.l10n = { [appState] in appState.l10n }
        let installParts = UpdateInstallFlow.Parts(
            delegate: appDelegate, daemon: daemonManager, state: appState, updater: updater
        )
        updater.onRequestRestart = {
            Task { @MainActor in await UpdateInstallFlow.restart(installParts) }
        }
        updater.onRequestRemoteRestart = {
            Task { @MainActor in await UpdateInstallFlow.restartFromRemote(installParts) }
        }
        updater.onAutoInstall = { action in
            Task { @MainActor in await UpdateInstallFlow.auto(action, installParts) }
        }
        updater.daemonRuntime = { [daemonManager] in
            (daemonManager.runningRuntimeFolder, daemonManager.managesDaemon, daemonManager.runtimeOutdated)
        }
        updater.daemonBusy = { [appState] in
            // The sessions shown are another host's while the window is on one; this Mac's daemon
            // may be busy with its devices' turns, which the app cannot see then.
            guard case .localDaemon = appState.connectionMode else { return true }
            if appState.hasRunningTurns { return true }
            return await appState.hasBusyTerminals()
        }
        updater.start()
        // An automatic update opens Sarto again as it was: in the menu bar only, with no window.
        if UserDefaults.standard.bool(forKey: SartoUpdater.launchHiddenKey), !appDelegate.appliedLaunchHidden {
            appDelegate.appliedLaunchHidden = true
            DispatchQueue.main.async { appDelegate.hideToMenuBarResident() }
        }
        appDelegate.quitCountdown.close = { [appDelegate] in
            appDelegate.hideToMenuBarResident()
        }
        appDelegate.quitCountdown.style = { [appState] in
            QuitCountdown.Style(tokens: appState.tokens, l10n: appState.l10n, motionTier: appState.motionTier)
        }
        appDelegate.makeQuitCopy = { [appState] in
            let l10n = appState.l10n
            let running = appState.hasRunningTurns
            return PrismMacAppDelegate.QuitDialogCopy(
                menuBarTitle: l10n.tr("settings.quitMenuBar.title"),
                menuBarBody: l10n.tr(running ? "settings.quitMenuBar.runningBody" : "settings.quitMenuBar.body"),
                quitCompletely: l10n.tr("settings.quitConfirm.quitAll"),
                cancel: l10n.tr("thread.entry.cancel")
            )
        }
        appDelegate.onSystemAppearanceChanged = { [appState] isDark in
            appState.applySystemAppearance(isDark: isDark)
        }
        let isDarkNow = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        appState.applySystemAppearance(isDark: isDarkNow)
        SartoAppIconManager.apply(appState.appIconStyle)

        islandCoordinator.onRequestOpenMainWindow = reopenMain
        islandCoordinator.onRequestOpenSettings = { [settingsRouter] section in
            settingsRouter.open(section: section)
        }
        islandCoordinator.onRequestQuitFromMenuBar = { [appDelegate] in
            appDelegate.requestCompleteQuitFromMenuBar()
        }
        islandCoordinator.updateReadyVersion = { [updater] in
            if case .ready(let version, _) = updater.state { return version }
            return nil
        }
        islandCoordinator.onRequestOpenUpdates = { [settingsRouter] in
            settingsRouter.open(section: .advancedAndAbout, rowID: "advanced.updates")
        }
        updater.onStateChange = { [islandCoordinator, appState, updater] in
            islandCoordinator.refreshUpdateBadge()
            let snapshot = updater.statusSnapshot()
            Task { @MainActor in
                await appState.reportLocalAppUpdateState(snapshot)
            }
        }
        if appState.connectionMode.isLive {
            let snapshot = updater.statusSnapshot()
            Task { @MainActor in
                await appState.reportLocalAppUpdateState(snapshot)
            }
        }
        islandCoordinator.attach(to: appState)
        wireWorkspaceSyncBridge()

        bootstrapBoundDaemonIfNeeded()
    }

    private func wireWorkspaceSyncBridge() {
        appState.relayTokenProvider = { [daemonManager] in
            (try? await daemonManager.fetchAccountRelayToken())?.token
        }

        // Other hosts go through this Mac's daemon, which dials, pairs and keeps them
        // (docs/sarto-remote-design.md).
        appState.daemonOtherHosts = DaemonOtherHosts(
            open: { [daemonManager] id in try await daemonManager.openOtherHost(id: id) },
            remove: { [daemonManager] id in try await daemonManager.removeOtherHost(id: id) }
        )
        appState.applyOtherHosts(daemonManager.otherHosts)
        daemonManager.onOtherHostsUpdated = { [appState] hosts in
            appState.applyOtherHosts(hosts)
        }

        daemonManager.onAccountStatusUpdated = { [appState, daemonManager, settingsRouter] status in
            let wasSigningIn = appState.cloudAccountStatus.account.isSigningIn
            let wasSignedIn = appState.cloudAccountStatus.account.isSignedIn
            appState.applyAccountStatus(status)
            if status.account.isSignedIn && !wasSignedIn {
                let activeTheme = appState.palette.rawValue
                Task { @MainActor in
                    _ = try? await daemonManager.setAccountPreferences(appTheme: activeTheme)
                }
                scheduleClientSyncPush(immediate: true)
            }
            // A browser sign-in ends with the browser in front: bring Sarto back to the account,
            // where the next step (or why it failed) is.
            guard wasSigningIn, !status.account.isSigningIn else { return }
            settingsRouter.open(section: .remoteAndCloud, rowID: "remote.sync")
            if status.account.isSignedIn {
                let profile = status.account.account
                let who = profile?.email.isEmpty == false ? profile?.email : profile?.name
                settingsRouter.pendingNotice = appState.l10n.tr("settings.account.signedInNotice", who ?? "Sarto")
            }
        }

        // The usage views read this Mac's daemon, whichever host the window shows.
        islandCoordinator.usageStore.removeRecord = { [daemonManager] deviceId in
            _ = try await daemonManager.removeSyncUsage(deviceId: deviceId)
        }
        islandCoordinator.usageStore.openHost = { [daemonManager] in
            try await daemonManager.connectLocalAgentHost()
        }

        daemonManager.onSyncUsageUpdated = { [appState] _ in
            Task { @MainActor in
                await appState.refreshUsageSummary()
            }
        }

        let announcedApprovals = self.announcedApprovals
        let syncApprovalPanel = self.syncApprovalPanel
        daemonManager.onSyncStatusUpdated = { [appState, islandCoordinator, settingsRouter, daemonManager] status in
            let wasReady = appState.sartoSyncStatus.isVaultReady
            appState.applySyncedStatus(status)
            // Present an Apple-style floating approval modal when another device requests access.
            syncApprovalPanel.sync(
                pendingApprovals: status.pendingApprovals,
                state: appState,
                daemon: daemonManager
            )
            let fresh = status.pendingApprovals.filter { !announcedApprovals.deviceIds.contains($0.deviceId) }
            if let first = fresh.first {
                announcedApprovals.deviceIds.formUnion(fresh.map(\.deviceId))
                settingsRouter.pendingNotice = appState.l10n.tr("settings.vault.approvalRequestNotice", first.deviceName)
            }
            if status.isVaultReady != wasReady {
                islandCoordinator.usageStore.reload()
            }
            if status.isVaultReady && !wasReady {
                Task { @MainActor in
                    await pushLocalClientStateToDaemon()
                    await appState.refreshUsageSummary()
                }
            } else if wasReady && !status.isVaultReady {
                Task { @MainActor in
                    await appState.refreshUsageSummary()
                }
            }
        }

        appState.includeRemoteDaemonUsage = islandCoordinator.settingsStore.settings.usageScope == .allMacs

        appState.onApplySyncedIslandPrefs = { [islandCoordinator, appState] prefs, timestamps in
            let store = islandCoordinator.settingsStore
            var next = store.settings

            func shouldAdopt(_ key: String, _ remote: SartoSyncedUiPrefEntry) -> Bool {
                let localTs = timestamps[key] ?? 0
                return remote.updatedAt > localTs || (localTs == 0 && remote.updatedAt == 0)
            }

            func record(_ key: String, _ remote: SartoSyncedUiPrefEntry) {
                if timestamps[key] != remote.updatedAt {
                    timestamps[key] = remote.updatedAt
                }
            }

            if let e = prefs["islandEnabled"], shouldAdopt("islandEnabled", e), let b = e.value.boolValue {
                next.islandEnabled = b
                record("islandEnabled", e)
            }
            if let e = prefs["islandSessionStack"], shouldAdopt("islandSessionStack", e), let b = e.value.boolValue {
                next.islandSessionStack = b
                record("islandSessionStack", e)
            }
            if let e = prefs["islandMaxRows"], shouldAdopt("islandMaxRows", e), let d = e.value.doubleValue {
                if let val = Int.wholePart(of: d), IslandStackOptions.rowChoices.contains(val) {
                    next.islandMaxRows = val
                }
                record("islandMaxRows", e)
            }
            if let e = prefs["islandShowQuota"], shouldAdopt("islandShowQuota", e), let b = e.value.boolValue {
                next.islandShowQuota = b
                record("islandShowQuota", e)
            }
            if let e = prefs["islandMotion"], shouldAdopt("islandMotion", e),
               let s = e.value.stringValue, let m = IslandMotionStyle(rawValue: s) {
                next.islandMotion = m
                record("islandMotion", e)
            }
            if let e = prefs["subtleReminders"], shouldAdopt("subtleReminders", e), let b = e.value.boolValue {
                next.subtleReminders = b
                record("subtleReminders", e)
            }
            if let e = prefs["menubarEnabled"], shouldAdopt("menubarEnabled", e), let b = e.value.boolValue {
                next.menubarEnabled = b
                record("menubarEnabled", e)
            }
            if let e = prefs["statusText"], shouldAdopt("statusText", e),
               let s = e.value.stringValue, let m = StatusTextMode(rawValue: s) {
                next.statusText = m
                record("statusText", e)
            }
            if let e = prefs["providerOrder"], shouldAdopt("providerOrder", e),
               let arr = e.value.arrayValue {
                next.order = arr.compactMap(\.stringValue)
                record("providerOrder", e)
            }
            if let e = prefs["providerHidden"], shouldAdopt("providerHidden", e),
               let arr = e.value.arrayValue {
                next.hidden = arr.compactMap(\.stringValue)
                record("providerHidden", e)
            }
            if let e = prefs["usageScope"], shouldAdopt("usageScope", e),
               let s = e.value.stringValue, let sc = UsageScope(rawValue: s) {
                next.usageScope = sc
                appState.includeRemoteDaemonUsage = (sc == .allMacs)
                record("usageScope", e)
            }
            if let e = prefs["lowAlert"], shouldAdopt("lowAlert", e), let b = e.value.boolValue {
                next.lowAlert = b
                record("lowAlert", e)
            }
            if let e = prefs["lowThreshold"], shouldAdopt("lowThreshold", e), let d = e.value.doubleValue {
                if let val = Int.wholePart(of: d), UsageIslandSettings.lowThresholds.contains(val) {
                    next.lowThreshold = val
                }
                record("lowThreshold", e)
            }
            if let e = prefs["usagePrivacy"], shouldAdopt("usagePrivacy", e), let b = e.value.boolValue {
                next.privacy = b
                record("usagePrivacy", e)
            }

            lastObservedIslandSettings = next
            store.applySynced(next)
        }

        appState.onLocalUiPrefsMutated = {
            scheduleClientSyncPush()
        }

        appState.onEffectivePaletteChanged = { [appState, daemonManager] next in
            guard appState.cloudAccountStatus.account.isSignedIn else { return }
            Task { @MainActor in
                _ = try? await daemonManager.setAccountPreferences(appTheme: next.rawValue)
            }
        }

        if lastObservedIslandSettings == nil {
            lastObservedIslandSettings = islandCoordinator.settingsStore.settings
        }

        islandCoordinator.settingsStore.onLocalMutation = { [appState] next in
            let prev = lastObservedIslandSettings ?? UsageIslandSettings()
            lastObservedIslandSettings = next
            var changed: [String] = []
            if prev.islandEnabled != next.islandEnabled { changed.append("islandEnabled") }
            if prev.islandSessionStack != next.islandSessionStack { changed.append("islandSessionStack") }
            if prev.islandMaxRows != next.islandMaxRows { changed.append("islandMaxRows") }
            if prev.islandShowQuota != next.islandShowQuota { changed.append("islandShowQuota") }
            if prev.islandMotion != next.islandMotion { changed.append("islandMotion") }
            if prev.subtleReminders != next.subtleReminders { changed.append("subtleReminders") }
            if prev.menubarEnabled != next.menubarEnabled { changed.append("menubarEnabled") }
            if prev.statusText != next.statusText { changed.append("statusText") }
            if prev.order != next.order { changed.append("providerOrder") }
            if prev.hidden != next.hidden { changed.append("providerHidden") }
            if prev.usageScope != next.usageScope {
                changed.append("usageScope")
                appState.includeRemoteDaemonUsage = (next.usageScope == .allMacs)
                Task { @MainActor in
                    await appState.refreshUsageSummary()
                }
            }
            if prev.lowAlert != next.lowAlert { changed.append("lowAlert") }
            if prev.lowThreshold != next.lowThreshold { changed.append("lowThreshold") }
            if prev.privacy != next.privacy { changed.append("usagePrivacy") }
            if !changed.isEmpty {
                appState.markUiPrefsMutated(changed)
            }
        }
    }

    private func scheduleClientSyncPush(immediate: Bool = false) {
        pushSyncTask?.cancel()
        pushSyncTask = Task { @MainActor in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            await pushLocalClientStateToDaemon()
        }
    }

    private func pushLocalClientStateToDaemon() async {
        let s = islandCoordinator.settingsStore.settings
        let extraPrefs: [String: JSONValue] = [
            "islandEnabled": .bool(s.islandEnabled),
            "islandSessionStack": .bool(s.islandSessionStack),
            "islandMaxRows": .number(Double(s.islandMaxRows)),
            "islandShowQuota": .bool(s.islandShowQuota),
            "islandMotion": .string(s.islandMotion.rawValue),
            "subtleReminders": .bool(s.subtleReminders),
            "menubarEnabled": .bool(s.menubarEnabled),
            "statusText": .string(s.statusText.rawValue),
            "providerOrder": .array(s.order.map(JSONValue.string)),
            "providerHidden": .array(s.hidden.map(JSONValue.string)),
            "usageScope": .string(s.usageScope.rawValue),
            "lowAlert": .bool(s.lowAlert),
            "lowThreshold": .number(Double(s.lowThreshold)),
            "usagePrivacy": .bool(s.privacy),
        ]
        let macName = Self.computerName()
        // The daemon's key, which connects to the account's other hosts; the sync replaces any key
        // this install published before with it. Without it this time, the device is left as it is.
        let devInput = (try? await daemonManager.daemonDeviceKey()).map { key in
            SartoTrustedDeviceInput(
                id: key.id,
                publicKey: key.publicKey,
                name: macName,
                kind: "desktop",
                platform: "darwin",
                model: "Mac"
            )
        }
        let uiPayload = appState.buildSyncedUiPrefsPayload(extraPrefs: extraPrefs)
        _ = try? await daemonManager.pushClientSyncState(
            uiPrefs: uiPayload,
            device: devInput
        )
    }

    /// The computer name from System Settings > General > Sharing.
    private static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
    }

    private func bootstrapBoundDaemonIfNeeded() {
        appState.devices.onRequestLocalDeviceSession = { [daemonManager] in
            try await daemonManager.connectLocalDeviceHost()
        }
        appState.onReconnectLocalDaemon = { [daemonManager, appState] in
            try await daemonManager.connectOrStartHosts(
                daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                relayOrigin: appState.relayOrigin
            )
        }
        guard !didBootstrapBoundDaemon else { return }
        didBootstrapBoundDaemon = true
        Task { @MainActor in
            guard !appState.connectionMode.isLive else { return }
            do {
                let hosts = try await daemonManager.connectOrStartHosts(
                    daemonEntryPath: SartoState.resolveDaemonBundlePath(),
                    relayOrigin: appState.relayOrigin
                )
                await appState.attachLiveSession(
                    hosts.agent,
                    terminal: hosts.terminal,
                    mode: .localDaemon(socketPath: daemonManager.controlSocketPath)
                )
                islandCoordinator.usageStore.reload()
                await pushLocalClientStateToDaemon()
            } catch {
                appState.connectionError = error.localizedDescription
            }
        }
    }
}
