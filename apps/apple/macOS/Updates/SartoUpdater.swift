import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog
import PrismDesign
import SartoProtocol
import SartoUpdate
import Security

/// Sarto.app's updater: it checks the sources of a signed list for an update file
/// the release key signed, downloads the zip it names, checks its SHA-512 and the new app's code
/// signature against this one's, and swaps the bundles when Sarto restarts or quits. See
/// docs/sarto-update-design.md.
@MainActor
@Observable
final class SartoUpdater {
    private(set) var state: UpdateState
    /// How this build updates, even while updates are off.
    let mode: UpdateMode
    /// Whether this copy of Sarto can replace itself where it is.
    let canInstallHere: Bool
    /// The running semantic version (`SartoVersion` when set, else `CFBundleShortVersionString`).
    let current: String
    /// The build channel stamped into this bundle (`stable`, `beta` or `dev`).
    let buildChannel: BuildChannel
    /// The monotonic build number stamped into `CFBundleVersion`, when present.
    let buildNumber: String?
    /// The git commit SHA stamped into `SartoGitCommit`, when present.
    let gitCommit: String?
    /// Set for the first launch after an update, until dismissed.
    private(set) var updatedFrom: String?
    /// The highlights of the running version, kept from the update that installed it.
    private(set) var currentNotes: [String: [String]] = [:]
    private(set) var dismissed: String?

    var choice: UpdateChoice {
        didSet {
            defaults.set(choice.rawValue, forKey: Keys.choice)
            if oldValue == .off, choice != .off { scheduleChecks(after: .seconds(5)) }
        }
    }

    var channelChoice: UpdateChannel {
        didSet {
            defaults.set(channelChoice.rawValue, forKey: Keys.channel)
            guard oldValue != channelChoice else { return }
            found = nil
            lastAvailable = nil
            downloadURL = nil
            leaveOtherChannel()
            switch state {
            case .idle, .available, .error: Task { await self.check() }
            default: break
            }
        }
    }

    /// Drops a beta update staged or downloading once the channel no longer takes it, so the
    /// updater neither offers it nor stays ready with nothing to install.
    private func leaveOtherChannel() {
        if let staged, !SartoVersion.isChannelVersion(staged.version, channel: channelChoice) {
            discardStaged(staged)
            if case .ready = state {
                state = .idle(checkedAt: lastCheckedAt)
                onStateChange?()
            }
        }
        if case .downloading(let version, _, _) = state,
           !SartoVersion.isChannelVersion(version, channel: channelChoice) {
            downloading?.cancel()
        }
    }

    var sourceChoice: SourceChoice {
        didSet { defaults.set(sourceChoice.rawValue, forKey: Keys.source) }
    }

    /// Install or Link: what an update found now leads to on this Mac.
    var effectiveMode: UpdateMode { mode == .install && canInstallHere ? .install : .link }

    /// Whether the notice for the update or the "Updated to" one shows.
    var showsNotice: Bool {
        let target = UpdateMachine.dismissTarget(state: state, current: current, updatedFrom: updatedFrom)
        return target != nil && target != dismissed
    }

    @ObservationIgnored var l10n: () -> PrismL10n = { PrismL10n(language: PrismLanguage.loadSaved()) }
    /// Asks the app to restart for the update: it confirms, stops the daemon when the update
    /// replaces it, installs with `installForRestart` and quits, after `relaunchAfterExit`.
    @ObservationIgnored var onRequestRestart: (() -> Void)?
    /// Headless restart triggered by another paired Mac requesting a remote app update.
    @ObservationIgnored var onRequestRemoteRestart: (() -> Void)?
    @ObservationIgnored private var pendingRemoteInstall = false
    /// The daemon the app runs now: its runtime folder, whether the app manages it, and whether it
    /// runs another runtime than the app carries.
    @ObservationIgnored var daemonRuntime: @MainActor () -> (folder: String?, managed: Bool, outdated: Bool) = { (nil, false, false) }
    /// Whether the daemon has tasks a restart would end: turns running, or terminals running commands.
    @ObservationIgnored var daemonBusy: @MainActor () async -> Bool = { false }
    /// Called when the state changes, for the menu bar icon's update dot.
    @ObservationIgnored var onStateChange: (@MainActor () -> Void)?
    /// Carries out what `AutoInstall` decided; the app calls `autoInstallFinished` when it did not quit.
    @ObservationIgnored var onAutoInstall: (@MainActor (AutoInstall.Action) -> Void)?

    /// Whether the running daemon is from another runtime than the app's, waiting to be restarted.
    var daemonOutdated: Bool { daemonRuntime().outdated }

    /// Whether installing the staged update replaces the running daemon, which ends its tasks.
    var stagedRestartsDaemon: Bool {
        guard let staged else { return true }
        let daemon = daemonRuntime()
        return AutoInstall.restartsDaemon(updateRuntime: staged.runtime, runningFolder: daemon.folder, daemonManaged: daemon.managed)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Logger(subsystem: "dev.sarto.mac", category: "updater")
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var downloading: Task<Void, Never>?
    @ObservationIgnored private var found: UpdateFile?
    @ObservationIgnored private var run: SourceRun?
    /// When a check last finished, for the time Settings shows.
    private(set) var lastCheckedAt: Date?
    @ObservationIgnored private var lastAvailable: String?
    @ObservationIgnored private var downloadURL: URL?
    @ObservationIgnored private var staged: StagedUpdate?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// Since when the daemon has had no tasks, while an automatic install waits for it to be quiet.
    @ObservationIgnored private var quietSince: Date?
    /// Set while the app carries out an automatic install.
    @ObservationIgnored private var acting = false
    /// Set once this process has swapped the new app in; it then only quits, or relaunches.
    @ObservationIgnored private var installed = false

    private static let firstCheckDelay: Duration = .seconds(30)
    private static let watchInterval: Duration = .seconds(15)
    /// The launch argument (`-SartoLaunchHidden YES`) that opens Sarto in the menu bar only.
    static let launchHiddenKey = "SartoLaunchHidden"
    /// SARTO_UPDATE_QUIET_SECONDS shortens the quiet period, to test a release.
    private static let quietPeriod: TimeInterval = ProcessInfo.processInfo.environment["SARTO_UPDATE_QUIET_SECONDS"]
        .flatMap(TimeInterval.init) ?? AutoInstall.quietPeriod
    private static let checkInterval: Duration = .seconds(60 * 60)
    private static let arch = "arm64"
    private nonisolated static let maxSmallFile = 256 * 1024

    private enum Keys {
        static let choice = "sarto.updates.automatic"
        static let channel = "sarto.updates.channel"
        static let source = "sarto.updates.source"
        static let lastRun = "sarto.updates.lastRunVersion"
        static let dismissed = "sarto.updates.dismissed"
        static let sources = "sarto.updates.sources"
        static let staged = "sarto.updates.staged"
        static let installedNotes = "sarto.updates.installedNotes"
    }

    private struct InstalledNotes: Codable {
        let version: String
        let notes: [String: [String]]
    }

    @inline(never)
    private static func resolveInitialChannel(
        environment: [String: String],
        defaults: UserDefaults,
        stampedChannel: BuildChannel
    ) -> UpdateChannel {
        if let raw = environment["SARTO_UPDATE_CHANNEL"]?.trimmingCharacters(in: .whitespaces),
           let envChannel = UpdateChannel(rawValue: raw) {
            return envChannel
        }
        if let raw = defaults.string(forKey: Keys.channel),
           let savedChannel = UpdateChannel(rawValue: raw) {
            return savedChannel
        }
        return stampedChannel == .beta ? .beta : .stable
    }

    @inline(never)
    private static func resolveInitialState(
        version: String,
        configured: UpdateMode?,
        hasPinnedSource: Bool
    ) -> UpdateState {
        guard configured != nil else { return .off(.development) }
        if SartoVersion.isRelease(version) || SartoVersion.isBeta(version) {
            return .idle(checkedAt: nil)
        }
        if hasPinnedSource && SartoVersion.isDev(version) {
            return .idle(checkedAt: nil)
        }
        return .off(.development)
    }

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let info = bundle.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let version = SartoVersion.bundleVersion(info: info)
        current = version
        let stampedChannel = SartoVersion.buildChannel(version: version, configured: info["SartoBuildChannel"])
        buildChannel = stampedChannel
        buildNumber = (info["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        gitCommit = (info["SartoGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let configured = UpdateMode.configured(info["SartoUpdateMode"])
            ?? UpdateMode.configured(env["SARTO_UPDATE_MODE"])
        mode = configured ?? .link
        canInstallHere = Self.canReplace(bundle.bundleURL)
        choice = UpdateChoice(rawValue: defaults.string(forKey: Keys.choice) ?? "") ?? .download
        channelChoice = Self.resolveInitialChannel(environment: env, defaults: defaults, stampedChannel: stampedChannel)
        sourceChoice = SourceChoice(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .auto
        dismissed = defaults.string(forKey: Keys.dismissed)
        state = Self.resolveInitialState(
            version: version,
            configured: configured,
            hasPinnedSource: Self.pinnedSource() != nil
        )

        // A development build shares the installed app's preferences, so it leaves the version the
        // "Updated to" notice compares with alone.
        if stampedChannel != .dev {
            updatedFrom = SartoVersion.updatedFrom(lastRunVersion: defaults.string(forKey: Keys.lastRun), current: version)
            defaults.set(version, forKey: Keys.lastRun)
        }
        if let data = defaults.data(forKey: Keys.installedNotes),
           let kept = try? JSONDecoder().decode(InstalledNotes.self, from: data),
           kept.version == version {
            currentNotes = kept.notes
        }
        staged = defaults.data(forKey: Keys.staged).flatMap { try? JSONDecoder().decode(StagedUpdate.self, from: $0) }
    }

    // MARK: Schedule

    /// Cleans up after the last update, offers a staged one again, and checks 30 s from now and
    /// then every hour.
    func start() {
        guard !started else { return }
        started = true
        guard case .idle = state else { return }
        log.info("Updates in \(self.mode.rawValue, privacy: .public) mode, \(self.canInstallHere ? "installable" : "not installable here", privacy: .public)")
        Task { await self.restoreStaged() }
        scheduleChecks(after: Self.firstCheckDelay)
        watchForAutoInstall()
    }

    // MARK: Automatic install

    private func watchForAutoInstall() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval)
                await self?.considerAutoInstall()
            }
        }
    }

    private func considerAutoInstall() async {
        guard !acting else { return }
        let daemon = daemonRuntime()
        var ready = false
        if case .ready = state { ready = staged != nil }
        let restarts = ready && stagedRestartsDaemon
        if restarts || (!ready && daemon.outdated) {
            if await daemonBusy() {
                quietSince = nil
            } else if quietSince == nil {
                quietSince = Date()
            }
        } else {
            quietSince = nil
        }
        let situation = AutoInstall.Situation(
            choice: choice,
            staged: ready,
            stagedRestartsDaemon: restarts,
            daemonOutdated: daemon.outdated,
            userAway: Self.userAway(),
            quietFor: quietSince.map { Date().timeIntervalSince($0) }
        )
        let action = AutoInstall.decide(situation, quietPeriod: Self.quietPeriod)
        guard action != .wait, let onAutoInstall else { return }
        log.info("Installing on its own: \(String(describing: action), privacy: .public)")
        acting = true
        quietSince = nil
        onAutoInstall(action)
    }

    /// The app carried out an automatic install without quitting, or could not.
    func autoInstallFinished() {
        acting = false
    }

    /// Sarto is not in front, or nobody has touched the keyboard or mouse for a while.
    private static func userAway() -> Bool {
        if !NSApp.isActive { return true }
        let idle: TimeInterval
        if let any = CGEventType(rawValue: ~0) {
            idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        } else {
            let kinds: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
            idle = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        }
        return idle >= AutoInstall.awayAfter
    }

    private func scheduleChecks(after delay: Duration) {
        guard started, !isOff else { return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                if UpdateMachine.checksAutomatically(choice: self.choice) {
                    await self.runCheck(manual: false)
                }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    private var isOff: Bool {
        if case .off = state { return true }
        return false
    }

    // MARK: Actions

    /// A check the user asked for; its errors are shown.
    func check() async {
        switch state {
        case .off, .downloading, .ready: return
        default: await runCheck(manual: true)
        }
    }

    /// Wire-friendly snapshot of this Mac's current app version and updater state for multi-device Settings.
    func statusSnapshot(overrideState: String? = nil) -> AppUpdateStatusInfo {
        let modeStr: String = {
            if case .off = state { return "unavailable" }
            return effectiveMode == .install ? "install" : "link"
        }()
        let canInstallNow = modeStr == "install"
        if let overrideState {
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: overrideState,
                mode: modeStr,
                canInstall: canInstallNow,
                availableVersion: state.version,
                updatedAt: Date().timeIntervalSince1970 * 1000.0
            )
        }
        switch state {
        case .off:
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "off",
                mode: "unavailable",
                canInstall: false
            )
        case .idle:
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "idle",
                mode: modeStr,
                canInstall: canInstallNow
            )
        case .checking:
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "checking",
                mode: modeStr,
                canInstall: canInstallNow
            )
        case .available(let version, _, _):
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "available",
                mode: modeStr,
                canInstall: canInstallNow,
                availableVersion: version
            )
        case .downloading(let version, let percent, _):
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "downloading",
                mode: modeStr,
                canInstall: canInstallNow,
                availableVersion: version,
                progress: percent
            )
        case .ready(let version, _):
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "ready",
                mode: modeStr,
                canInstall: canInstallNow,
                availableVersion: version
            )
        case .error(let message, _):
            return AppUpdateStatusInfo(
                currentVersion: current,
                state: "error",
                mode: modeStr,
                canInstall: canInstallNow,
                error: message
            )
        }
    }

    /// Executes a `check` or `install` command received from another paired Mac over the encrypted channel.
    /// Runs the exact same signed-release & code-signature verification pipeline as a local update.
    func handleRemoteCommand(_ action: String) async {
        if action == "check" {
            await check()
            onStateChange?()
            return
        }
        guard action == "install" else { return }
        if case .ready = state {
            pendingRemoteInstall = false
            onRequestRemoteRestart?()
            return
        }
        guard effectiveMode == .install, !isOff else {
            onStateChange?()
            return
        }
        pendingRemoteInstall = true
        if case .available(let version, _, _) = state {
            startDownload(version: version, startedBy: .user)
            return
        }
        await check()
        switch state {
        case .available(let version, _, _):
            startDownload(version: version, startedBy: .user)
        case .ready:
            pendingRemoteInstall = false
            onRequestRemoteRestart?()
        case .downloading:
            break
        default:
            pendingRemoteInstall = false
            onStateChange?()
        }
    }

    /// Update: downloads the update found, which then waits for a restart.
    func update() {
        guard case .available(let version, _, _) = state else { return }
        if effectiveMode == .link {
            openDownload()
            return
        }
        startDownload(version: version, startedBy: .user)
    }

    /// Link mode's Download: the release's disk image in the browser.
    func openDownload() {
        let url = downloadURL ?? found.flatMap { file in
            file.diskImage(arch: Self.arch).flatMap {
                (run?.current ?? UpdateSources.official).releaseFileURL(tag: file.releaseTag, name: $0.name)
            }
        }
        if let url { NSWorkspace.shared.open(url) }
    }

    func restart() {
        guard case .ready = state else { return }
        onRequestRestart?()
    }

    func dismiss() {
        guard let target = UpdateMachine.dismissTarget(state: state, current: current, updatedFrom: updatedFrom) else { return }
        dismissed = target
        defaults.set(target, forKey: Keys.dismissed)
    }

    // MARK: Install

    /// Whether quitting now installs the staged update.
    var installsOnQuit: Bool {
        guard let staged, case .ready = state else { return false }
        return UpdateMachine.installOnQuit(choice: choice, startedBy: staged.startedBy)
    }

    /// Swaps the staged app in, as the app quits for good. The daemon must have stopped first.
    /// The staged app is checked here, on the main thread: the app is terminating, and nothing
    /// may come between the check and the swap.
    @discardableResult
    func installOnQuit() -> Bool {
        guard installsOnQuit, !installed, let staged else { return false }
        do {
            try Self.verifyApp(
                URL(fileURLWithPath: staged.appPath), version: staged.version, ownID: Bundle.main.bundleIdentifier
            )
        } catch {
            refuseStaged(staged, error)
            return false
        }
        return swapIn(staged)
    }

    /// Swaps the staged app in for a restart, once the daemon has stopped. False when it could not,
    /// with the error in the state, and Sarto then carries on as it was.
    func installForRestart() async -> Bool {
        if installed { return true }
        guard let staged else { return false }
        do {
            try await Self.checkApp(URL(fileURLWithPath: staged.appPath), version: staged.version)
        } catch {
            if self.staged == staged { refuseStaged(staged, error) }
            return installed
        }
        // Another install may have finished, or the staged update changed, during the check.
        guard !installed, self.staged == staged else { return installed }
        return swapIn(staged)
    }

    /// A staged app that fails the checks it passed when it was staged, as one changed on disk
    /// since, is never installed: it is deleted and forgotten, and the next check downloads the
    /// update again.
    private func refuseStaged(_ staged: StagedUpdate, _ error: Error) {
        let failure = error as? UpdateFailure
        log.error("The staged \(staged.version, privacy: .public) is not installed: \(failure?.log ?? String(describing: error), privacy: .public)")
        discardStaged(staged)
        let message = failure?.message(l10n()) ?? l10n().tr("updates.error.codeSignature")
        dispatch(.error(message: message, manual: true))
    }

    /// Puts `staged`, which the caller has just checked, in place of the running app.
    private func swapIn(_ staged: StagedUpdate) -> Bool {
        let app = Bundle.main.bundleURL
        do {
            try BundleSwap.install(staged: URL(fileURLWithPath: staged.appPath), over: app)
        } catch {
            log.error("Installing \(staged.version, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            dispatch(.error(message: l10n().tr("updates.error.install", error.localizedDescription), manual: true))
            return false
        }
        if let notes = try? JSONEncoder().encode(InstalledNotes(version: staged.version, notes: staged.notes)) {
            defaults.set(notes, forKey: Keys.installedNotes)
        }
        setStaged(nil)
        installed = true
        log.info("Installed \(staged.version, privacy: .public) over \(self.current, privacy: .public)")
        return true
    }

    /// Opens the app at its path again once this process has exited: in the background when
    /// `background`, without taking the user away from what they do, and with no window but the
    /// menu bar's when `hidden`, as Sarto was before.
    func relaunchAfterExit(background: Bool = false, hidden: Bool = false) {
        var open: [String] = []
        if background { open.append("-g") }
        if hidden { open.append("-j") }
        // `open` starts the app with launchd's environment; the variables Sarto and its daemon read
        // go along, so a build started with its own data folder or release source keeps them.
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
        where key.hasPrefix("SARTO_") {
            open.append(contentsOf: ["--env", "\(key)=\(value)"])
        }
        open.append(Bundle.main.bundleURL.path)
        if hidden { open.append(contentsOf: ["--args", "-\(Self.launchHiddenKey)", "YES"]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "pid=$1; shift; while /bin/kill -0 \"$pid\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$@\"",
            "sarto-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
        ] + open
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            log.error("Could not schedule the relaunch: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Checking

    private func runCheck(manual: Bool) async {
        if let checking {
            await checking.value
            return
        }
        let task = Task { await self.performCheck(manual: manual) }
        checking = task
        await task.value
        checking = nil
    }

    private func performCheck(manual: Bool) async {
        guard !isOff else { return }
        if !manual, case .downloading = state { return }
        if case .ready = state { return }
        dispatch(.checking(manual: manual))
        do {
            let (file, answered) = try await findLatest()
            lastCheckedAt = Date()
            // The channel may have changed while the check ran.
            guard let file,
                  SartoVersion.isNewer(file.version, than: current),
                  SartoVersion.isChannelVersion(file.version, channel: channelChoice),
                  file.supports(system: ProcessInfo.processInfo.operatingSystemVersion)
            else {
                dispatch(.notAvailable(at: lastCheckedAt ?? Date()))
                return
            }
            found = file
            run = answered
            lastAvailable = file.version
            downloadURL = file.diskImage(arch: Self.arch).flatMap {
                answered.current.releaseFileURL(tag: file.releaseTag, name: $0.name)
            }
            log.info("\(file.version, privacy: .public) (\(file.channel.rawValue, privacy: .public)) is out, from \(answered.current.id, privacy: .public)")
            dispatch(.available(version: file.version))
            if case .downloading = state {
                startDownload(version: file.version, startedBy: .auto)
            }
        } catch {
            log.error("Checking for updates failed: \(String(describing: error), privacy: .public)")
            dispatch(.error(message: l10n().tr("updates.error.noSource"), manual: manual))
        }
    }

    /// Fetches and verifies one channel's signed update file (`latest-mac.json` or `beta-mac.json`);
    /// returns nil when the source answers 404 for that channel file.
    private nonisolated static func fetchChannelUpdateFile(
        source: UpdateSource,
        channel: UpdateChannel,
        timeout: Int,
        userAgent: String
    ) async throws -> UpdateFile? {
        let fileName = UpdateFile.name(for: channel)
        guard let fileURL = source.latestFileURL(fileName),
              let sigURL = source.latestFileURL("\(fileName).sig")
        else { throw URLError(.badURL) }
        let body: Data
        do {
            body = try await fetchSmall(fileURL, timeout: timeout, userAgent: userAgent)
        } catch FileDownload.Failure.status(404) {
            return nil
        }
        let signature = try await fetchSmall(sigURL, timeout: timeout, userAgent: userAgent)
        return try UpdateFile.verified(body, signatureFile: signature, channel: channel).get()
    }

    /// The newest update file for the selected channel that the sources offer, asked in turn as
    /// `UpdateSearch` says, with the sources from the one that offered it. It throws when no source
    /// offered a file the release key signed.
    private func findLatest() async throws -> (UpdateFile?, SourceRun) {
        var run = SourceRun(list: await sourceList())
        var search = UpdateSearch(channel: channelChoice, current: current)
        var lastError: Error = URLError(.cannotFindHost)
        repeat {
            let source = run.current
            let timeout = run.connectTimeoutSeconds + run.stallSeconds
            var files: [UpdateChannel: UpdateFile] = [:]
            for channel in search.channel == .beta ? [UpdateChannel.beta, .stable] : [.stable] {
                do {
                    if let file = try await Self.fetchChannelUpdateFile(
                        source: source, channel: channel, timeout: timeout, userAgent: userAgent
                    ) {
                        files[channel] = file
                    } else {
                        lastError = FileDownload.Failure.status(404)
                    }
                } catch {
                    log.error("\(source.id, privacy: .public) could not answer for \(channel.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                    lastError = error
                }
            }
            if search.take(own: files[search.channel], stable: files[.stable], from: run.fromCurrent()) { break }
            log.info("\(source.id, privacy: .public) has no answer for \(search.channel.rawValue, privacy: .public) as new as \(self.current, privacy: .public)")
        } while run.next() != nil
        guard let found = search.found else { throw lastError }
        return (found.file, found.run)
    }

    /// The sources to try: SARTO_RELEASES_URL alone when set, the official source alone when
    /// chosen, or else the signed list, refreshed now, kept from before, or built in.
    private func sourceList() async -> SourceList {
        if let pinned = Self.pinnedSource() {
            return SourceList(serial: 0, sources: [pinned], connectTimeoutSeconds: 10, stallSeconds: 15)
        }
        if sourceChoice == .official { return UpdateSources.officialOnly }
        var kept: (SourceList, SignedSourceList)?
        if let data = defaults.data(forKey: Keys.sources),
           let envelope = try? JSONDecoder().decode(SignedSourceList.self, from: data),
           case .ok(let list, let signed) = UpdateSources.verify(envelope, minSerial: 0) {
            kept = (list, signed)
        }
        do {
            let body = try await Self.fetchSmall(UpdateSources.sourcesURL, timeout: 20, userAgent: userAgent)
            switch UpdateSources.parse(body, minSerial: kept?.0.serial ?? 0) {
            case .ok(let list, let signed):
                if let data = try? JSONEncoder().encode(signed) { defaults.set(data, forKey: Keys.sources) }
                return list
            case .failed(let reason):
                log.error("The source list was refused: \(reason, privacy: .public)")
            }
        } catch {
            log.info("No source list: \(String(describing: error), privacy: .public)")
        }
        return kept?.0 ?? UpdateSources.builtIn
    }

    /// A source named for testing: https, or http on this computer.
    private static func pinnedSource() -> UpdateSource? {
        guard let raw = ProcessInfo.processInfo.environment["SARTO_RELEASES_URL"]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return nil }
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URLComponents(string: trimmed), let host = url.host else { return nil }
        let local = url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host)
        guard url.scheme == "https" || local else { return nil }
        return UpdateSource(id: "pinned", url: trimmed)
    }

    private var userAgent: String { UpdateMachine.userAgent(version: current, arch: Self.arch) }

    /// A file that must be small, as the update file, its signature and the source list. The
    /// download ends as soon as it is longer than `maxSmallFile`, so no source can fill memory.
    private nonisolated static func fetchSmall(_ url: URL, timeout: Int, userAgent: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: TimeInterval(timeout))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            bytes.task.cancel()
            throw FileDownload.Failure.status((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // The length a source announces is unknown (-1) for some; the count below holds either way.
        guard response.expectedContentLength <= Int64(maxSmallFile) else {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maxSmallFile else {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }

    // MARK: Downloading

    private func startDownload(version: String, startedBy: StartedBy) {
        guard downloading == nil, let file = found, file.version == version, let run else { return }
        guard let asset = file.archive(arch: Self.arch) else {
            dispatch(.error(message: l10n().tr("updates.error.download"), manual: startedBy == .user))
            return
        }
        if case .downloading = state {} else {
            dispatch(.downloadStarted(version: version, manual: startedBy == .user))
        }
        downloading = Task {
            defer { self.downloading = nil }
            do {
                let app = try await self.fetchAndStage(file: file, asset: asset, run: run.again())
                // The channel may have changed while the update downloaded.
                guard SartoVersion.isChannelVersion(version, channel: self.channelChoice) else {
                    Self.removeStagingFolder(app.deletingLastPathComponent())
                    throw CancellationError()
                }
                let update = StagedUpdate(
                    version: version, appPath: app.path, startedBy: startedBy, notes: file.notes, runtime: file.runtime
                )
                self.setStaged(update)
                self.log.info("\(version, privacy: .public) is ready to install")
                self.dispatch(.downloaded(version: version, notes: file.notes))
            } catch is CancellationError {
                self.dispatch(.downloadCancelled)
                if !SartoVersion.isChannelVersion(version, channel: self.channelChoice) {
                    // Runs once this download has finished, so a newer stable release can download.
                    Task { await self.runCheck(manual: false) }
                }
            } catch let error as UpdateFailure {
                self.log.error("Updating to \(version, privacy: .public) failed: \(error.log, privacy: .public)")
                self.dispatch(.error(message: error.message(self.l10n()), manual: startedBy == .user))
            } catch {
                self.log.error("Updating to \(version, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.dispatch(.error(message: self.l10n().tr("updates.error.download"), manual: startedBy == .user))
            }
        }
    }

    private enum UpdateFailure: Error {
        case download(String)
        case mismatch(String)
        case codeSignature(String)

        var log: String {
            switch self {
            case .download(let text), .mismatch(let text), .codeSignature(let text): return text
            }
        }

        @MainActor func message(_ l10n: PrismL10n) -> String {
            switch self {
            case .download: return l10n.tr("updates.error.download")
            case .mismatch: return l10n.tr("updates.error.mismatch")
            case .codeSignature: return l10n.tr("updates.error.codeSignature")
            }
        }
    }

    /// Downloads the zip from the sources of `run` in turn, checks it, unpacks it and checks the
    /// app inside; returns the staged app.
    private func fetchAndStage(file: UpdateFile, asset: UpdateAsset, run: SourceRun) async throws -> URL {
        let root = try Self.stagingRoot()
        let appName = Bundle.main.bundleURL.lastPathComponent
        // A delta from the running version builds the new app from this one, for a fraction of the
        // download; anything wrong with it falls back to the whole app.
        if let delta = file.delta(from: current, arch: Self.arch) {
            let folder = root.appendingPathComponent("\(file.version)-delta-\(UUID().uuidString.prefix(8))", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let deltaFile = folder.appendingPathComponent(delta.name)
                try await fetch(delta, tag: file.releaseTag, run: run, to: deltaFile)
                let app = folder.appendingPathComponent(appName, isDirectory: true)
                try await Self.applyDelta(deltaFile, from: current, to: file.version, into: app)
                try? FileManager.default.removeItem(at: deltaFile)
                try await verifyStaged(app, file: file)
                log.info("Built \(file.version, privacy: .public) from a delta of \(delta.size) bytes")
                return app
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: folder)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: folder)
                log.error("The delta to \(file.version, privacy: .public) could not be used, so the whole app downloads: \(String(describing: error), privacy: .public)")
            }
        }

        let folder = root.appendingPathComponent("\(file.version)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent(asset.name)
        do {
            try await fetch(asset, tag: file.releaseTag, run: run, to: zip)
            try await Self.unpack(zip, into: folder)
            try? FileManager.default.removeItem(at: zip)
            let app = folder.appendingPathComponent(appName, isDirectory: true)
            try await verifyStaged(app, file: file)
            return app
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Downloads `asset` of release `tag` from the sources of `run` in turn and checks its
    /// size and SHA-512.
    private func fetch(_ asset: UpdateAsset, tag: String, run: SourceRun, to destination: URL) async throws {
        var run = run
        var failure: Error = UpdateFailure.download("no source")
        repeat {
            try Task.checkCancellation()
            guard let url = run.current.releaseFileURL(tag: tag, name: asset.name) else { continue }
            do {
                _ = try await FileDownload.run(url, to: destination, userAgent: userAgent, stallSeconds: run.stallSeconds) { [weak self] percent in
                    Task { @MainActor in self?.dispatch(.progress(percent: percent)) }
                }
                try await Self.checkFile(destination, against: asset)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                log.error("\(run.current.id, privacy: .public) could not send \(asset.name, privacy: .public): \(String(describing: error), privacy: .public)")
                failure = error
            }
        } while run.next() != nil
        throw failure is UpdateFailure ? failure : UpdateFailure.download(String(describing: failure))
    }

    /// The staged app must pass `checkApp`, and carry the runtime the signed update file names, or
    /// the updater would keep a daemon the new app does not match.
    private func verifyStaged(_ app: URL, file: UpdateFile) async throws {
        try await Self.checkApp(app, version: file.version)
        if let runtime = file.runtime, Bundle(url: app).flatMap({ DaemonRuntime.bundled(in: $0) })?.fingerprint != runtime {
            throw UpdateFailure.mismatch("the app in the update carries another runtime than its update file names")
        }
    }

    private nonisolated static func applyDelta(_ delta: URL, from: String, to: String, into app: URL) async throws {
        let running = Bundle.main.bundleURL
        try await Task.detached(priority: .utility) {
            let summary = try UpdateDelta.apply(delta: delta, oldApp: running, newApp: app)
            guard summary.from == from, summary.to == to else {
                throw UpdateFailure.mismatch("the delta builds \(summary.to) from \(summary.from), not \(to) from \(from)")
            }
        }.value
    }

    private nonisolated static func checkFile(_ url: URL, against asset: UpdateAsset) async throws {
        try await Task.detached(priority: .utility) {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            guard size == asset.size else {
                throw UpdateFailure.mismatch("\(asset.name) has \(size ?? -1) bytes, not \(asset.size)")
            }
            guard try FileDigest.sha512(of: url) == asset.sha512 else {
                throw UpdateFailure.mismatch("\(asset.name) does not match its SHA-512")
            }
        }.value
    }

    private nonisolated static func unpack(_ zip: URL, into folder: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw UpdateFailure.mismatch("ditto could not unpack \(zip.lastPathComponent) (\(status))") }
    }

    /// `verifyApp`, off the main actor.
    private nonisolated static func checkApp(_ app: URL, version: String) async throws {
        let ownID = Bundle.main.bundleIdentifier
        try await Task.detached(priority: .utility) {
            try verifyApp(app, version: version, ownID: ownID)
        }.value
    }

    /// The staged app must be this app, at the update's version, signed by this app's team
    /// (`UpdateRequirement`), or for an app without a team, so that its designated requirement
    /// holds, as Squirrel.Mac checks. It reads every file of the app, so only a quit calls it on
    /// the main thread.
    private nonisolated static func verifyApp(_ app: URL, version: String, ownID: String?) throws {
        guard let ownID,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == ownID,
              SartoVersion.bundleVersion(info: info) == version
        else { throw UpdateFailure.mismatch("the app in the update is not Sarto \(version)") }
        let requirement = try runningAppRequirement(bundleIdentifier: ownID)
        var staged: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staged) == errSecSuccess, let staged else {
            throw UpdateFailure.codeSignature("the new app's signature could not be read")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(staged, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateFailure.codeSignature("the new app fails the running app's requirement (\(status))")
        }
    }

    /// The requirement a new app must meet: signed by this app's team, or for an app without a
    /// team, this app's designated requirement.
    private nonisolated static func runningAppRequirement(bundleIdentifier: String) throws -> SecRequirement {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic
        else { throw UpdateFailure.codeSignature("the running app's signature could not be read") }
        var information: CFDictionary?
        _ = SecCodeCopySigningInformation(selfStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        var requirement: SecRequirement?
        if let text = UpdateRequirement.text(bundleIdentifier: bundleIdentifier, teamIdentifier: team) {
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
                throw UpdateFailure.codeSignature("the team requirement could not be made")
            }
            return requirement
        }
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateFailure.codeSignature("the running app's designated requirement could not be read")
        }
        return requirement
    }

    // MARK: Staging

    private nonisolated static func stagingRoot() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.sarto.mac", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Forgets `staged` and deletes the folder it was unpacked in.
    private func discardStaged(_ staged: StagedUpdate) {
        setStaged(nil)
        Self.removeStagingFolder(URL(fileURLWithPath: staged.appPath).deletingLastPathComponent())
    }

    private nonisolated static func removeStagingFolder(_ folder: URL) {
        Task.detached(priority: .utility) {
            // The path comes from the preferences, so only a folder of the staging folder goes.
            guard let root = try? stagingRoot(),
                  folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
            else { return }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func setStaged(_ update: StagedUpdate?) {
        staged = update
        if let update, let data = try? JSONEncoder().encode(update) {
            defaults.set(data, forKey: Keys.staged)
        } else {
            defaults.removeObject(forKey: Keys.staged)
        }
    }

    /// Deletes what earlier updates left, the bundles they replaced among it, and offers a staged
    /// update again once its app passes the checks once more.
    private func restoreStaged() async {
        var keep: URL?
        if let staged, SartoVersion.isNewer(staged.version, than: current),
           SartoVersion.isChannelVersion(staged.version, channel: channelChoice) {
            let app = URL(fileURLWithPath: staged.appPath)
            do {
                try await Self.checkApp(app, version: staged.version)
                keep = app.deletingLastPathComponent()
            } catch {
                log.error("The staged \(staged.version, privacy: .public) no longer passes: \(String(describing: error), privacy: .public)")
                setStaged(nil)
            }
        } else if staged != nil {
            setStaged(nil)
        }
        if let root = try? Self.stagingRoot(),
           let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for entry in entries where entry.standardizedFileURL != keep?.standardizedFileURL {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        let running = Bundle.main.bundleURL
        Task.detached(priority: .utility) { BundleSwap.removeLeftovers(beside: running) }
        if keep != nil, let staged, case .idle = state {
            found = nil
            dispatch(.downloaded(version: staged.version, notes: staged.notes))
        }
    }

    // MARK: State

    private func dispatch(_ event: UpdaterEvent) {
        let context = TransitionContext(
            mode: effectiveMode,
            autoDownload: UpdateMachine.autoDownload(choice: choice, mode: mode, canInstall: canInstallHere),
            lastCheckedAt: lastCheckedAt,
            lastAvailable: lastAvailable,
            downloadURL: downloadURL
        )
        let next = UpdateMachine.next(state, event, context)
        guard next != state else { return }
        state = next
        onStateChange?()
        if pendingRemoteInstall {
            switch next {
            case .ready:
                pendingRemoteInstall = false
                onRequestRemoteRestart?()
            case .error, .off:
                pendingRemoteInstall = false
            default:
                break
            }
        }
    }

    /// Whether this app's bundle can be swapped where it is: not translocated by Gatekeeper, on a
    /// writable volume, in a folder it may write to.
    nonisolated static func canReplace(_ bundle: URL) -> Bool {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return false }
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return false
        }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path) && fm.isWritableFile(atPath: path)
    }
}
