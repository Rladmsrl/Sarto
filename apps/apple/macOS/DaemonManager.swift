import Darwin
import Foundation
import SartoProtocol
import SartoUpdate
import Observation
import PrismDesign

public enum DaemonState: Sendable, Equatable {
    case stopped
    case starting
    case running(pid: Int32)
    case connectedExternal(socketPath: String)
    case failed(String)
}

/// Manages Sarto's Node.js daemon on macOS and speaks its local control.sock
/// (src/daemon/control.ts) to attach directly to agent-host and terminal-host.
@MainActor
@Observable
public final class LocalDaemonManager {
    public private(set) var state: DaemonState = .stopped
    public private(set) var recentLogs: [String] = []
    public private(set) var accountStatus: CloudAccountStatusInfo = CloudAccountStatusInfo()
    public private(set) var accountDevices: [CloudDeviceInfo] = []
    public private(set) var accountPreferences: CloudAccountPreferencesInfo = CloudAccountPreferencesInfo()
    public private(set) var syncStatus: SartoSyncStatusInfo? = nil
    public private(set) var syncedUsageSnapshot: SyncUsageSnapshotResult? = nil
    /// One-time recovery key kept across Settings tab/window switches until the user confirms saving it.
    public var pendingRecoveryKey: String? = nil
    public var dataDirectory: String = SartoDaemonPaths.defaultDataDirectory()
    @ObservationIgnored public var onAccountStatusUpdated: ((CloudAccountStatusInfo) -> Void)? = nil
    @ObservationIgnored public var onSyncStatusUpdated: ((SartoSyncStatusInfo) -> Void)? = nil
    @ObservationIgnored public var onSyncUsageUpdated: ((SyncUsageSnapshotResult) -> Void)? = nil
    /// The other hosts the daemon connects to as a device (docs/sarto-remote-design.md).
    public private(set) var otherHosts: [OtherHostStatus] = []
    @ObservationIgnored public var onOtherHostsUpdated: (([OtherHostStatus]) -> Void)? = nil
    /// The idle game's link status and the frames the game service sends, as the daemon relays them.
    @ObservationIgnored public var onGameEvent: ((HostEvent) -> Void)? = nil
    private var gameWatching = false

    private var process: Process?
    /// The runtime folder the connected daemon runs from; nil when unknown, as for a daemon an
    /// older app started from inside its bundle, or one this build does not manage.
    public private(set) var runningRuntimeFolder: String?
    /// The connected daemon is one this app manages, not a service the user installed.
    public private(set) var managesDaemon = false
    /// The connected daemon runs another runtime than this app carries; the updater restarts it
    /// once it has been quiet (`AutoInstall`).
    public private(set) var runtimeOutdated = false
    /// Set once the app hands the daemon over to the app that opens after an update, which keeps
    /// it running through this app's quit.
    private var releasedForAppRestart = false
    private var controlSession: SartoHostSession?
    private var inFlightControlOpen: Task<SartoHostSession, Error>?
    /// The daemon process this app attached to, as it was then, so a signal on quit cannot reach a
    /// process that took its pid since.
    private var attachedDaemon: DaemonProcessIdentity?
    private var attachedDaemonIsService: Bool = false
    private var inFlightConnectTask: Task<(agent: SartoHostSession, terminal: SartoTerminalSession?), Error>?
    /// Dedicated control socket session subscribed to live `sync.updated` events from SartoSyncService.
    private var syncSession: SartoHostSession?
    private var syncTask: Task<Void, Never>?
    private var syncReconnectTask: Task<Void, Never>?
    private var syncStartGeneration: UInt64 = 0
    /// Asks `syncSession` again for the subscriptions the daemon could not give yet, as while it starts.
    private var subscribeRetryTask: Task<Void, Never>?

    public init() {}

    public var isStartingOrRunning: Bool {
        switch state {
        case .starting, .running, .connectedExternal:
            return true
        case .stopped, .failed:
            return false
        }
    }

    /// PID of the currently running or attached local daemon process, if known.
    public var activePID: Int32? {
        switch state {
        case .running(let pid):
            return pid
        case .connectedExternal:
            return process?.processIdentifier ?? attachedDaemon?.pid
        case .stopped, .starting, .failed:
            return nil
        }
    }

    /// Whether the connected daemon is managed by launchd (`sarto service install`).
    public var isLaunchdService: Bool {
        attachedDaemonIsService
    }

    /// Whether Sarto can safely stop and relaunch the local daemon process itself.
    public var canRestartLocally: Bool {
        if process != nil { return true }
        return attachedDaemon != nil && !attachedDaemonIsService && !Self.allowsMultipleInstances
    }

    /// The control socket of the daemon in use.
    public var controlSocketPath: String {
        SartoDaemonPaths.controlSocketPath(dataDirectory: dataDirectory)
    }

    /// Probes `control.sock` off the main thread. Only unlinks `socketPath` when the kernel confirms
    /// no process is listening (`ECONNREFUSED` / `ENOTSOCK`), never on transient errors like `EAGAIN`.
    private func openControlTransportIfAlive(socketPath: String) async -> UnixSocketPortTransport? {
        let probe = await Task.detached(priority: .userInitiated) {
            Self.openControlTransportSync(socketPath: socketPath)
        }.value
        if probe.removedStale {
            appendLog("Removed stale control socket at \(socketPath)")
        }
        return probe.transport
    }

    private nonisolated static func openControlTransportSync(
        socketPath: String
    ) -> (transport: UnixSocketPortTransport?, removedStale: Bool) {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return (nil, false)
        }
        do {
            let transport = try UnixSocketPortTransport(socketPath: socketPath)
            return (transport, false)
        } catch let UnixSocketError.connectFailed(err) where err == ECONNREFUSED || err == ENOTSOCK {
            _ = Darwin.unlink(socketPath)
            return (nil, true)
        } catch {
            return (nil, false)
        }
    }

    private nonisolated static func connectSocketAsync(socketPath: String) async throws -> UnixSocketPortTransport {
        try await Task.detached(priority: .userInitiated) {
            try UnixSocketPortTransport(socketPath: socketPath)
        }.value
    }

    private func closeControlSession() async {
        guard let existing = controlSession else { return }
        controlSession = nil
        await existing.close()
    }

    private func closeSyncSession() async {
        subscribeRetryTask?.cancel()
        subscribeRetryTask = nil
        syncTask?.cancel()
        syncTask = nil
        guard let existing = syncSession else { return }
        syncSession = nil
        await existing.close()
    }

    private func startSyncSubscription() async {
        syncStartGeneration &+= 1
        let gen = syncStartGeneration
        syncReconnectTask?.cancel()
        syncReconnectTask = nil
        await closeSyncSession()
        guard gen == syncStartGeneration else { return }
        guard let transport = await openControlTransportIfAlive(socketPath: controlSocketPath) else {
            return
        }
        guard gen == syncStartGeneration else {
            await transport.close()
            return
        }
        let session = SartoHostSession(transport: transport)
        self.syncSession = session
        // The account and the sync service start apart in the daemon. One that is not ready yet
        // must not cost the other its events, or a browser sign-in that finishes goes unseen.
        let accountSubscribed = await subscribeAccount(on: session)
        let syncSubscribed = await subscribeSync(on: session)
        let hostsSubscribed = await subscribeOtherHosts(on: session)
        let gameSubscribed = await subscribeGame(on: session)
        guard gen == syncStartGeneration, self.syncSession === session else { return }
        syncTask = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .accountUpdated(let next):
                    self.accountStatus = next
                    self.onAccountStatusUpdated?(next)
                case .syncUpdated(let next):
                    let wasReady = self.syncStatus?.isVaultReady ?? false
                    self.syncStatus = next
                    self.onSyncStatusUpdated?(next)
                    if next.isVaultReady && !wasReady {
                        if let usage = try? await self.getSyncUsage() {
                            self.syncedUsageSnapshot = usage
                            self.onSyncUsageUpdated?(usage)
                        }
                    } else if !next.isVaultReady && wasReady {
                        self.syncedUsageSnapshot = nil
                    }
                case .syncUsageUpdated(let ownDeviceId, let records):
                    let snap = SyncUsageSnapshotResult(ownDeviceId: ownDeviceId, records: records)
                    self.syncedUsageSnapshot = snap
                    self.onSyncUsageUpdated?(snap)
                case .otherHostsUpdated(let hosts):
                    self.setOtherHosts(hosts)
                case .gameStatus, .gameFrame:
                    self.onGameEvent?(event)
                default:
                    break
                }
            }
            // Re-subscribe automatically with backoff if the local daemon restarts and closes the event stream.
            guard let self, !Task.isCancelled, self.syncSession === session else { return }
            self.subscribeRetryTask?.cancel()
            self.subscribeRetryTask = nil
            self.syncSession = nil
            self.syncTask = nil
            self.syncReconnectTask?.cancel()
            self.syncReconnectTask = Task { @MainActor [weak self] in
                var delay: Duration = .seconds(2)
                for _ in 0..<20 {
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled, self.syncSession == nil else { return }
                    await self.startSyncSubscription()
                    if self.syncSession != nil { return }
                    delay = min(delay * 2, .seconds(15))
                }
            }
        }
        guard !accountSubscribed || !syncSubscribed || !hostsSubscribed || !gameSubscribed else { return }
        subscribeRetryTask = Task { [weak self] in
            var needAccount = !accountSubscribed
            var needSync = !syncSubscribed
            var needHosts = !hostsSubscribed
            var needGame = !gameSubscribed
            var delay: Duration = .milliseconds(500)
            for _ in 0..<40 where needAccount || needSync || needHosts || needGame {
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.syncSession === session else { return }
                if needAccount { needAccount = !(await self.subscribeAccount(on: session)) }
                if needSync { needSync = !(await self.subscribeSync(on: session)) }
                if needHosts { needHosts = !(await self.subscribeOtherHosts(on: session)) }
                if needGame { needGame = !(await self.subscribeGame(on: session)) }
                delay = min(delay * 2, .seconds(10))
            }
        }
    }

    /// Subscribes `session` to `account.updated`; false while the daemon cannot give it yet.
    private func subscribeAccount(on session: SartoHostSession) async -> Bool {
        guard let initial = try? await session.daemonAccountSubscribe() else { return false }
        guard syncSession === session else { return true }
        accountStatus = initial
        onAccountStatusUpdated?(initial)
        return true
    }

    /// Subscribes `session` to `sync.updated`; false while the daemon's sync service is starting.
    private func subscribeSync(on session: SartoHostSession) async -> Bool {
        guard let initial = try? await session.daemonSyncSubscribe() else { return false }
        guard syncSession === session else { return true }
        syncStatus = initial
        onSyncStatusUpdated?(initial)
        if initial.isVaultReady, let usage = try? await session.daemonSyncGetUsage() {
            syncedUsageSnapshot = usage
            onSyncUsageUpdated?(usage)
        }
        return true
    }

    /// Subscribes `session` to `hosts.updated`; false while the daemon cannot give it yet. A daemon
    /// from before it connected to other hosts answers `unknown_method`, which ends the asking.
    private func subscribeOtherHosts(on session: SartoHostSession) async -> Bool {
        do {
            let initial = try await session.daemonHostsSubscribe()
            guard syncSession === session else { return true }
            setOtherHosts(initial)
            return true
        } catch let error as PortRPCError where error.code == "unknown_method" {
            return true
        } catch {
            return false
        }
    }

    /// Subscribes `session` to the idle game; false while the daemon's game link is starting. A
    /// daemon from before the game answers `unknown_method`, which ends the asking.
    private func subscribeGame(on session: SartoHostSession) async -> Bool {
        do {
            let (status, state) = try await session.daemonGameSubscribe()
            guard syncSession === session else { return true }
            if gameWatching { try? await session.daemonGameWatch(true) }
            onGameEvent?(.gameStatus(status))
            if let state { onGameEvent?(.gameFrame(.state(state))) }
            return true
        } catch let error as PortRPCError where error.code == "unknown_method" {
            return true
        } catch {
            return false
        }
    }

    public func setGameWatching(_ watching: Bool) {
        gameWatching = watching
        guard let session = syncSession else { return }
        Task { try? await session.daemonGameWatch(watching) }
    }

    public func sendGameCommand(type: String, args: [String: JSONValue] = [:]) async -> GameCommandOutcome {
        guard let session = syncSession else {
            return GameCommandOutcome(.object(["ok": .bool(false), "error": .string("daemon disconnected")]))
        }
        do {
            return try await session.daemonGameCommand(type: type, args: args)
        } catch {
            return GameCommandOutcome(.object(["ok": .bool(false), "error": .string(error.localizedDescription)]))
        }
    }

    private func setOtherHosts(_ hosts: [OtherHostStatus]) {
        guard hosts != otherHosts else { return }
        otherHosts = hosts
        onOtherHostsUpdated?(hosts)
    }

    // MARK: - Other Hosts Through the Daemon (docs/sarto-remote-design.md)

    /// Opens this app's sessions with another host on the daemon's hosts socket: one connection for
    /// its agent host and one for its terminal, each naming the host first.
    public func openOtherHost(id: String) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession) {
        let socketPath = try await withControlSession { try await $0.daemonHostSocketPath(host: "hosts") }
        let agentTransport = try await Self.connectSocketAsync(socketPath: socketPath)
        do {
            try await agentTransport.sendHostsConnect(hostId: id)
            let terminalTransport = try await Self.connectSocketAsync(socketPath: socketPath)
            do {
                try await terminalTransport.sendHostsConnect(hostId: id)
            } catch {
                await terminalTransport.close()
                throw error
            }
            return (SartoHostSession(transport: agentTransport), SartoTerminalSession(transport: terminalTransport))
        } catch {
            await agentTransport.close()
            throw error
        }
    }

    /// Forgets another host in the daemon.
    public func removeOtherHost(id: String) async throws {
        try await withControlSession { try await $0.daemonHostsRemove(id: id) }
    }

    /// The key the daemon connects to other hosts with, which this install publishes as its device.
    public func daemonDeviceKey() async throws -> DaemonDeviceKeyInfo {
        try await withControlSession { try await $0.daemonHostsDevice() }
    }

    private static func isTransportDisconnect(_ error: Error) -> Bool {
        if error is UnixSocketError || error is HostRPCError {
            return true
        }
        return false
    }

    /// Connects to an already-running local Sarto daemon via control.sock, or launches
    /// out/daemon/main.cjs if available, coalescing concurrent callers into a single flight.
    public func connectOrStartHosts(
        daemonEntryPath: String? = nil,
        relayOrigin: String
    ) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession?) {
        if let existing = inFlightConnectTask {
            return try await existing.value
        }
        let task = Task { @MainActor in
            defer { self.inFlightConnectTask = nil }
            return try await self.performConnectOrStartHosts(
                daemonEntryPath: daemonEntryPath,
                relayOrigin: relayOrigin
            )
        }
        inFlightConnectTask = task
        return try await task.value
    }

    /// A connection of its own to the local agent host, for the usage views: they show this Mac's
    /// usage whichever host the window is connected to, and listen for its `usage.changed`.
    public func connectLocalAgentHost() async throws -> SartoHostSession {
        let socketPath = try await withControlSession { try await $0.daemonHostSocketPath(host: "agent") }
        let transport = try await Self.connectSocketAsync(socketPath: socketPath)
        return SartoHostSession(transport: transport)
    }

    /// Lazily connects to Sarto's `device-host` Unix socket on demand (only when the user opens
    /// the iOS/Android Preview tab or an agent invokes a `device_*` tool), so `device-host` is
    /// never spawned and `xcrun`/`adb` never polls while mobile previews are unused.
    public func connectLocalDeviceHost() async throws -> SartoDeviceSession {
        let control: SartoHostSession
        if let existing = controlSession {
            control = existing
        } else if let transport = await openControlTransportIfAlive(socketPath: controlSocketPath) {
            let fresh = SartoHostSession(transport: transport)
            self.controlSession = fresh
            control = fresh
        } else {
            let msg = PrismL10n(language: PrismLanguage.loadSaved()).tr("error.daemonMissing", controlSocketPath)
            throw PortRPCError(code: "host_offline", message: msg)
        }

        let devSocketPath = try await control.daemonHostSocketPath(host: "device")
        let devTransport = try await Self.connectSocketAsync(socketPath: devSocketPath)
        appendLog("Lazily attached to Sarto device-host at \(devSocketPath)")
        return SartoDeviceSession(transport: devTransport)
    }

    private func performConnectOrStartHosts(
        daemonEntryPath: String? = nil,
        relayOrigin: String
    ) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession?) {
        await closeControlSession()

        var controlTransport = await openControlTransportIfAlive(socketPath: controlSocketPath)
        var spawnedDaemon = false

        if controlTransport == nil,
           let daemonEntryPath,
           FileManager.default.fileExists(atPath: daemonEntryPath) {
            await startProcess(daemonEntryPath: daemonEntryPath, relayOrigin: relayOrigin)
            if case .failed(let message) = state {
                throw PortRPCError(code: "host_offline", message: message)
            }
            spawnedDaemon = (process != nil)
            let sockPath = controlSocketPath
            for _ in 0..<30 {
                if let connected = try? await Self.connectSocketAsync(socketPath: sockPath) {
                    controlTransport = connected
                    break
                }
                if process == nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if controlTransport == nil, process != nil {
                // A daemon that never opened its socket would otherwise keep running unseen, and the
                // next start would spawn a second one beside it.
                appendLog("Sarto daemon did not open \(sockPath) in time; stopping it")
                await terminateSpawnedProcess()
            }
        }

        guard let activeControlTransport = controlTransport else {
            let msg = PrismL10n(language: PrismLanguage.loadSaved()).tr("error.daemonMissing", controlSocketPath)
            state = .failed(msg)
            throw PortRPCError(code: "host_offline", message: msg)
        }

        let control = SartoHostSession(transport: activeControlTransport)
        self.controlSession = control

        // Retry briefly while a freshly spawned daemon finishes bringing up agent-host.
        var resolvedAgentSocket: String?
        var lastError: Error?
        for _ in 0..<20 {
            do {
                resolvedAgentSocket = try await control.daemonHostSocketPath(host: "agent")
                break
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let agentSocketPath = resolvedAgentSocket else {
            await closeControlSession()
            throw lastError ?? PortRPCError(code: "unavailable", message: "agent-host socket unavailable")
        }

        let agentTransport: UnixSocketPortTransport
        do {
            agentTransport = try await Self.connectSocketAsync(socketPath: agentSocketPath)
            // Identify this local desktop port with `browser: true` so agent-host routes MCP `browser_*`
            // tool calls straight to Sarto's native WKWebView browser pane.
            try await agentTransport.sendLocalBrowserConnect()
        } catch {
            await closeControlSession()
            throw error
        }
        let agentSession = SartoHostSession(transport: agentTransport)

        var terminalSession: SartoTerminalSession? = nil
        if let termSocketPath = try? await control.daemonHostSocketPath(host: "terminal"),
           let termTransport = try? await Self.connectSocketAsync(socketPath: termSocketPath) {
            terminalSession = SartoTerminalSession(transport: termTransport)
            appendLog("Attached to Sarto terminal-host at \(termSocketPath)")
        }

        if let status = try? await control.daemonStatus() {
            let pid = Int32(exactly: status.pid) ?? 0
            attachedDaemon = await Task.detached(priority: .userInitiated) {
                DaemonProcessIdentity.current(pid: pid)
            }.value
            attachedDaemonIsService = status.service
            noteRuntime(pid: pid, service: status.service, entryPath: daemonEntryPath)
        } else {
            // A pid kept from an earlier attach may belong to another process by now.
            attachedDaemon = nil
            attachedDaemonIsService = false
        }

        if !spawnedDaemon && process == nil {
            state = .connectedExternal(socketPath: controlSocketPath)
        }
        await startSyncSubscription()
        appendLog("Connected to local Sarto agent-host at \(agentSocketPath)")
        return (agentSession, terminalSession)
    }

    // MARK: - Daemon Control Socket Queries & Mutations

    /// Ensures a live control socket session, reconnecting once ONLY on transport disconnect/EOF
    /// (never retrying application `PortRPCError` or `CancellationError`).
    private func ensureControlSession() async throws -> SartoHostSession {
        if let existing = controlSession {
            return existing
        }
        if let pending = inFlightControlOpen {
            return try await pending.value
        }
        let task = Task<SartoHostSession, Error> { @MainActor in
            defer { self.inFlightControlOpen = nil }
            guard let transport = await openControlTransportIfAlive(socketPath: controlSocketPath) else {
                let msg = PrismL10n(language: PrismLanguage.loadSaved()).tr("error.daemonMissing", controlSocketPath)
                throw PortRPCError(code: "host_offline", message: msg)
            }
            if let existing = self.controlSession {
                await transport.close()
                return existing
            }
            let fresh = SartoHostSession(transport: transport)
            self.controlSession = fresh
            return fresh
        }
        inFlightControlOpen = task
        return try await task.value
    }

    public func withControlSession<T: Sendable>(_ work: (SartoHostSession) async throws -> T) async throws -> T {
        if let existing = controlSession {
            do {
                return try await work(existing)
            } catch {
                guard Self.isTransportDisconnect(error) else {
                    throw error
                }
                if self.controlSession === existing {
                    await closeControlSession()
                }
            }
        }
        let fresh = try await ensureControlSession()
        return try await work(fresh)
    }

    public func fetchStatus() async throws -> DaemonStatusInfo {
        try await withControlSession { try await $0.daemonStatus() }
    }

    public func listPairedDevices() async throws -> [PairedDeviceSummary] {
        try await withControlSession { try await $0.daemonListDevices() }
    }

    public func removePairedDevice(id: String) async throws {
        try await withControlSession { try await $0.daemonRemoveDevice(id: id) }
    }

    public func fetchRemoteTerminalAllowed() async throws -> Bool {
        try await withControlSession { try await $0.daemonTerminalAllowedGet() }
    }

    public func setRemoteTerminalAllowed(_ allowed: Bool) async throws -> Bool {
        try await withControlSession { try await $0.daemonTerminalAllowedSet(allowed) }
    }

    public func setVerboseLogging(_ on: Bool) async throws -> Double? {
        try await withControlSession { try await $0.daemonSetVerbose(on) }
    }

    public func buildDiagnosticReport(description: String = "") async throws -> ReportBuildResultInfo {
        try await withControlSession { try await $0.daemonBuildReport(description: description) }
    }

    public func prepareProblemReport(
        description: String,
        rangeKind: String,
        extras: [String],
        sessionId: String? = nil,
        agentId: String? = nil,
        error: String? = nil,
        client: ReportClientPayloadInfo? = nil
    ) async throws -> PreparedReportInfo {
        try await withControlSession {
            try await $0.daemonPrepareReport(
                description: description,
                rangeKind: rangeKind,
                extras: extras,
                sessionId: sessionId,
                agentId: agentId,
                error: error,
                client: client
            )
        }
    }

    public func adoptProblemReport(
        zipBase64: String,
        files: [ReportFileInfo],
        redactionCount: Int? = nil
    ) async throws -> PreparedReportInfo {
        try await withControlSession {
            try await $0.daemonAdoptReport(zipBase64: zipBase64, files: files, redactionCount: redactionCount)
        }
    }

    public func readProblemReportFile(id: String, path: String) async throws -> ReportFileViewInfo {
        try await withControlSession { try await $0.daemonReadReportFile(id: id, path: path) }
    }

    public func saveProblemReport(id: String, destination: String, overwrite: Bool = true) async throws -> ReportSaveResultInfo {
        try await withControlSession { try await $0.daemonSaveReport(id: id, destination: destination, overwrite: overwrite) }
    }

    public func submitProblemReport(id: String, allowAnonymous: Bool = true) async throws -> ReportSubmitResultInfo {
        try await withControlSession { try await $0.daemonSubmitReport(id: id, allowAnonymous: allowAnonymous) }
    }

    public func dropProblemReport(id: String) async throws {
        try await withControlSession { try await $0.daemonDropReport(id: id) }
    }

    public func listProblemReports(limit: Int = 20, status: String? = nil) async throws -> CloudReportListInfo {
        try await withControlSession { try await $0.daemonListReports(limit: limit, status: status) }
    }

    /// Reads Host settings via control.sock `admin` -> `settings.get` (plus local `diagnostics.verboseUntil`),
    /// falling back to `settings.json` on disk when attached to an older daemon build.
    public func fetchHostSettings() async throws -> (snapshot: HostSettingsSnapshot, liveRPC: Bool) {
        let dir = dataDirectory
        do {
            var snap = try await withControlSession { try await $0.daemonSettingsGet() }
            if snap.verboseUntil == nil {
                snap.verboseUntil = await Task.detached(priority: .utility) {
                    Self.readLocalSettingsJSON(dataPath: dir)?.verboseUntil
                }.value
            }
            return (snap, true)
        } catch let err as PortRPCError where err.code != "unknown_method" && err.code != "host_offline" {
            throw err
        } catch {
            let statusDataPath = (try? await fetchStatus())?.dataPath
            let fallback = await Task.detached(priority: .utility) { () -> HostSettingsSnapshot? in
                if let statusDataPath, let snap = Self.readLocalSettingsJSON(dataPath: statusDataPath) {
                    return snap
                }
                return Self.readLocalSettingsJSON(dataPath: dir)
            }.value
            if let fallback {
                return (fallback, false)
            }
            throw error
        }
    }

    public func updateHostSettings(_ patch: [String: JSONValue]) async throws -> HostSettingsSnapshot {
        try await withControlSession { try await $0.daemonSettingsUpdate(patch) }
    }

    public func setHostAgentBinary(harnessId: String, path: String) async throws -> HostSettingsSnapshot {
        try await withControlSession { try await $0.daemonSetAgentBinary(harnessId: harnessId, path: path) }
    }

    public func setHostShellPath(_ path: String) async throws -> HostSettingsSnapshot {
        try await withControlSession { try await $0.daemonSetShellPath(path) }
    }

    public func setMarketplaceKeys(serverId: String, values: [String: String?]) async throws -> [String: [String]] {
        try await withControlSession { try await $0.daemonMarketplaceSetKeys(serverId: serverId, values: values) }
    }

    public func setMarketplaceAgentEnv(agentId: String, variable: String, value: String?) async throws {
        try await withControlSession { try await $0.daemonMarketplaceSetAgentEnv(agentId: agentId, variable: variable, value: value) }
    }

    // MARK: - Sarto Cloud Account & E2EE Multi-Device Workspace Sync Control Calls

    @discardableResult
    public func fetchAccountStatus() async throws -> CloudAccountStatusInfo {
        let next = try await withControlSession { try await $0.daemonAccountStatus() }
        self.accountStatus = next
        self.onAccountStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func signInAccount(
        serverUrl: String? = nil,
        openBrowser: Bool? = nil
    ) async throws -> CloudAccountStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonAccountSignIn(serverUrl: serverUrl, openBrowser: openBrowser)
        }
        self.accountStatus = next
        self.onAccountStatusUpdated?(next)
        if syncSession == nil {
            await startSyncSubscription()
        }
        return next
    }

    @discardableResult
    public func cancelSignInAccount() async throws -> CloudAccountStatusInfo {
        let next = try await withControlSession { try await $0.daemonAccountCancelSignIn() }
        self.accountStatus = next
        self.onAccountStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func signOutAccount() async throws -> CloudAccountStatusInfo {
        let next = try await withControlSession { try await $0.daemonAccountSignOut() }
        self.accountStatus = next
        self.accountDevices = []
        self.syncedUsageSnapshot = nil
        self.pendingRecoveryKey = nil
        self.onAccountStatusUpdated?(next)
        if let st = try? await fetchSyncStatus() {
            self.syncStatus = st
        }
        return next
    }

    @discardableResult
    public func checkAccount() async throws -> CloudAccountStatusInfo {
        let next = try await withControlSession { try await $0.daemonAccountCheck() }
        self.accountStatus = next
        self.onAccountStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func listAccountDevices() async throws -> [CloudDeviceInfo] {
        let list = try await withControlSession { try await $0.daemonAccountDevices() }
        self.accountDevices = list
        return list
    }

    public func removeAccountDevice(id: String) async throws {
        try await withControlSession { try await $0.daemonAccountRemoveDevice(id: id) }
        self.accountDevices.removeAll { $0.id == id }
    }

    public func fetchAccountRelayToken() async throws -> CloudRelayTokenInfo {
        try await withControlSession { try await $0.daemonAccountRelayToken() }
    }

    @discardableResult
    public func fetchAccountPreferences() async throws -> CloudAccountPreferencesInfo {
        let prefs = try await withControlSession { try await $0.daemonAccountPreferences() }
        self.accountPreferences = prefs
        return prefs
    }

    @discardableResult
    public func setAccountPreferences(
        appTheme: String? = nil
    ) async throws -> CloudAccountPreferencesInfo {
        let prefs = try await withControlSession {
            try await $0.daemonAccountSetPreferences(appTheme: appTheme)
        }
        self.accountPreferences = prefs
        return prefs
    }

    @discardableResult
    public func fetchSyncStatus() async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession { try await $0.daemonSyncStatus() }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    public func setupSyncVault() async throws -> SyncVaultSetupResult {
        let res = try await withControlSession { try await $0.daemonSyncSetupVault() }
        self.syncStatus = res.status
        self.onSyncStatusUpdated?(res.status)
        if syncSession == nil {
            await startSyncSubscription()
        }
        return res
    }

    @discardableResult
    public func unlockSyncRecovery(recoveryKey: String) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncUnlockRecovery(recoveryKey: recoveryKey)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func approveSyncDevice(deviceId: String) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncApproveDevice(deviceId: deviceId)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func confirmSyncApproval(matches: Bool) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncConfirmApproval(matches: matches)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func rejectSyncDevice(deviceId: String) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncRejectDevice(deviceId: deviceId)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func removeSyncDeviceWrap(deviceId: String) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncRemoveDeviceWrap(deviceId: deviceId)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func getSyncUsage() async throws -> SyncUsageSnapshotResult {
        let snap = try await withControlSession { try await $0.daemonSyncGetUsage() }
        self.syncedUsageSnapshot = snap
        self.onSyncUsageUpdated?(snap)
        return snap
    }

    @discardableResult
    public func removeSyncUsage(deviceId: String) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncRemoveUsage(deviceId: deviceId)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func disconnectSync() async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession { try await $0.daemonSyncDisconnect() }
        self.syncStatus = next
        self.syncedUsageSnapshot = nil
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func syncNow() async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession { try await $0.daemonSyncNow() }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    @discardableResult
    public func pushClientSyncState(
        uiPrefs: [String: SartoSyncedUiPrefEntry]? = nil,
        device: SartoTrustedDeviceInput? = nil
    ) async throws -> SartoSyncStatusInfo {
        let next = try await withControlSession {
            try await $0.daemonSyncPushClientState(uiPrefs: uiPrefs, device: device)
        }
        self.syncStatus = next
        self.onSyncStatusUpdated?(next)
        return next
    }

    private nonisolated static func readLocalSettingsJSON(dataPath: String) -> HostSettingsSnapshot? {
        guard !dataPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: dataPath).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return nil }
        return HostSettingsSnapshot.from(json: json)
    }

    // MARK: - Robust Off-Main-Thread Node >= 22 Discovery

    private func resolveNodeExecutable() async -> String? {
        await Task.detached(priority: .userInitiated) {
            Self.resolveNodeExecutableSync()
        }.value
    }

    private nonisolated static func resolveNodeExecutableSync() -> String? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let home = fm.homeDirectoryForCurrentUser.path

        if let explicit = env["SARTO_NODE_BINARY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty,
           fm.isExecutableFile(atPath: explicit),
           (nodeMajorVersion(at: explicit) ?? 0) >= 22 {
            return explicit
        }

        // A packaged app carries the Node.js its daemon was built and tested with; the user's own
        // Node.js below is only a fallback for development builds run from the checkout.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime/node/bin/node").path,
           fm.isExecutableFile(atPath: bundled) {
            return bundled
        }

        var candidates: [String] = [
            "/opt/homebrew/opt/node@24/bin/node",
            "/opt/homebrew/opt/node@22/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/opt/node@24/bin/node",
            "/usr/local/opt/node@22/bin/node",
            "/usr/local/bin/node",
            "\(home)/.volta/bin/node",
        ]

        candidates.append(contentsOf: expandVersionedNodeDirs(
            parentDir: "\(home)/.nvm/versions/node",
            relativeBinary: "bin/node"
        ))
        candidates.append(contentsOf: expandVersionedNodeDirs(
            parentDir: "\(home)/.fnm/node-versions",
            relativeBinary: "installation/bin/node"
        ))
        candidates.append(contentsOf: expandVersionedNodeDirs(
            parentDir: "\(home)/.local/share/mise/installs/node",
            relativeBinary: "bin/node"
        ))
        candidates.append("/usr/bin/node")

        var seen: Set<String> = []
        for path in candidates {
            guard seen.insert(path).inserted else { continue }
            guard fm.isExecutableFile(atPath: path) else { continue }
            if let major = nodeMajorVersion(at: path), major >= 22 {
                return path
            }
        }

        if let shellResolved = resolveNodeViaLoginShell(),
           !seen.contains(shellResolved),
           fm.isExecutableFile(atPath: shellResolved),
           let major = nodeMajorVersion(at: shellResolved),
           major >= 22 {
            return shellResolved
        }

        return nil
    }

    private nonisolated static func expandVersionedNodeDirs(
        parentDir: String,
        relativeBinary: String
    ) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parentDir) else {
            return []
        }
        let sorted = entries.sorted { lhs, rhs in
            parseSemverTuple(lhs) > parseSemverTuple(rhs)
        }
        return sorted.map { "\(parentDir)/\($0)/\(relativeBinary)" }
    }

    private nonisolated static func parseSemverTuple(_ raw: String) -> (Int, Int, Int) {
        let trimmed = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let parts = trimmed.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let major = parts.count > 0 ? parts[0] : 0
        let minor = parts.count > 1 ? parts[1] : 0
        let patch = parts.count > 2 ? parts[2] : 0
        return (major, minor, patch)
    }

    private nonisolated static func nodeMajorVersion(at binaryPath: String) -> Int? {
        guard let output = runQuickCommand(executable: binaryPath, arguments: ["--version"], timeoutSeconds: 2.0) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionBody = trimmed.hasPrefix("v") ? Substring(trimmed.dropFirst()) : Substring(trimmed)
        let digits = versionBody.prefix(while: \.isNumber)
        return Int(digits)
    }

    private nonisolated static func resolveNodeViaLoginShell() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh"),
              let output = runQuickCommand(executable: "/bin/zsh", arguments: ["-lc", "command -v node"], timeoutSeconds: 3.0)
        else { return nil }
        let lastLine = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
        guard let path = lastLine, path.hasPrefix("/") else { return nil }
        return path
    }

    private nonisolated static func runQuickCommand(
        executable: String,
        arguments: [String],
        timeoutSeconds: TimeInterval = 3.0
    ) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            try? outPipe.fileHandleForWriting.close()
            final class OutputBox: @unchecked Sendable {
                var data = Data()
            }
            let done = DispatchSemaphore(value: 0)
            let box = OutputBox()
            DispatchQueue.global(qos: .utility).async {
                box.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                done.signal()
            }
            if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                proc.terminate()
                return nil
            }
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return String(decoding: box.data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    // MARK: - Daemon Child Process Lifecycle

    private func startProcess(daemonEntryPath: String, relayOrigin: String) async {
        // Whatever `state` says, a live child means a daemon is already up (or still starting).
        if let proc = process, proc.isRunning {
            if case .failed = state {
                state = .running(pid: proc.processIdentifier)
            }
            return
        }
        if case .starting = state { return }
        state = .starting

        guard let target = await launchTarget(entryPath: daemonEntryPath) else {
            state = .failed(PrismL10n(language: PrismLanguage.loadSaved()).tr("error.nodeMissing"))
            return
        }
        let resolvedNode = target.node

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolvedNode)
        proc.arguments = [target.entry, "run"]

        var env = ProcessInfo.processInfo.environment
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let nodeBinDir = (resolvedNode as NSString).deletingLastPathComponent
        let extraPaths = [
            nodeBinDir,
            "\(homeDir)/.local/bin",
            "\(homeDir)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existingPath = env["PATH"] ?? ""
        let mergedPath = (extraPaths + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, entry in
                if !entry.isEmpty && !acc.contains(entry) { acc.append(entry) }
            }
            .joined(separator: ":")
        env["PATH"] = mergedPath
        env["SARTO_DAEMON_DATA"] = dataDirectory
        env["SARTO_DISABLE_REPORTS"] = env["SARTO_DISABLE_REPORTS"] ?? "1"
        proc.environment = env

        let output = outputHandle()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = output ?? FileHandle.nullDevice
        proc.standardError = output ?? FileHandle.nullDevice

        proc.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminated else { return }
                self.process = nil
                self.state = terminated.terminationStatus == 0
                    ? .stopped
                    : .failed("Exited with status \(terminated.terminationStatus)")
            }
        }

        do {
            try proc.run()
            try? output?.close()
            self.process = proc
            self.state = .running(pid: proc.processIdentifier)
            appendLog("Started Sarto daemon (pid \(proc.processIdentifier)) using \(resolvedNode)")
        } catch {
            try? output?.close()
            self.state = .failed(error.localizedDescription)
        }
    }

    /// Stops the daemon this manager spawned without blocking the main actor: SIGTERM, then SIGKILL
    /// if it has not exited within about two seconds.
    private func terminateSpawnedProcess() async {
        guard let proc = process else { return }
        proc.terminationHandler = nil
        process = nil
        if proc.isRunning {
            proc.terminate()
            for _ in 0..<20 where proc.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if proc.isRunning {
                _ = Darwin.kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// Whether `entryPath` is the daemon in this app's own runtime, which runs from its installed
    /// copy (`DaemonRuntime`); false for a daemon from a checkout.
    private static func isBundledEntry(_ entryPath: String?) -> Bool {
        guard let entryPath,
              let runtime = Bundle.main.resourceURL?.appendingPathComponent("runtime").standardizedFileURL.path
        else { return false }
        return URL(fileURLWithPath: entryPath).standardizedFileURL.path.hasPrefix(runtime + "/")
    }

    /// Records which runtime the connected daemon runs, and whether it is this app's, and deletes
    /// installed runtimes neither uses.
    private func noteRuntime(pid: Int32, service: Bool, entryPath: String?) {
        let bundled = Self.isBundledEntry(entryPath) ? DaemonRuntime.bundled() : nil
        let program = DaemonRuntime.programPath(pid: pid)
        let running = program.flatMap(RuntimeFingerprint.folderName(inNodePath:))
        runningRuntimeFolder = running
        managesDaemon = bundled != nil && !service && !Self.allowsMultipleInstances
            && program.map(RuntimeFingerprint.startedByApp(nodePath:)) == true
        runtimeOutdated = managesDaemon && running != bundled?.folderName
        if runtimeOutdated {
            appendLog("Sarto daemon runs runtime \(running ?? "inside an app"), not \(bundled?.folderName ?? "?")")
        }
        guard let bundled else { return }
        let keeping = Set([bundled.folderName] + (running.map { [$0] } ?? []))
        Task.detached(priority: .utility) { DaemonRuntime.removeUnused(keeping: keeping) }
    }

    /// The daemon entry and Node.js to start: the installed copy of this app's runtime for its own
    /// daemon, or else `entryPath` on the Node.js found for it.
    private func launchTarget(entryPath: String) async -> (entry: String, node: String)? {
        if Self.isBundledEntry(entryPath), let bundled = DaemonRuntime.bundled() {
            let installed = await Task.detached(priority: .userInitiated) { () -> URL? in
                try? DaemonRuntime.install(bundled)
            }.value
            if let installed {
                return (
                    installed.appendingPathComponent("daemon/main.cjs").path,
                    installed.appendingPathComponent("node/bin/node").path
                )
            }
            appendLog("Could not install the daemon runtime; starting it from the app")
        }
        guard let node = await resolveNodeExecutable() else { return nil }
        return (entryPath, node)
    }

    /// Where a daemon this app starts writes its output: a file, not a pipe to the app, so the
    /// daemon keeps running when the app quits for an update. It is in the app's folder, since the
    /// daemon makes its data folder itself.
    private func outputHandle() -> FileHandle? {
        let fm = FileManager.default
        let file = SartoAppPaths.daemonOutput()
        let logs = file.deletingLastPathComponent()
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue, size > 5_000_000 {
            let previous = logs.appendingPathComponent("daemon-output.1.log")
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: file, to: previous)
        }
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }

    /// Hands the daemon to the app that opens after an update that keeps it: closes this app's
    /// connections and forgets the process, so quitting leaves the daemon and its sessions running.
    public func releaseForAppRestart() async {
        releasedForAppRestart = true
        await closeSyncSession()
        await closeControlSession()
        process?.terminationHandler = nil
        process = nil
        attachedDaemon = nil
    }

    /// Undoes `releaseForAppRestart` when the update could not be installed after all.
    public func cancelReleaseForAppRestart() {
        releasedForAppRestart = false
    }

    private static var allowsMultipleInstances: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SARTO_ALLOW_MULTI_INSTANCE"] == "1"
    }

    /// SIGTERM, then SIGKILL once `patience` has passed, off the main actor and only while the pid is
    /// still `daemon`. The daemon may take eight seconds to stop its hosts and let its socket go.
    private static func stopProcess(_ daemon: DaemonProcessIdentity, patience: Duration) async {
        await Task.detached(priority: .userInitiated) {
            await daemon.stop(patience: patience)
        }.value
    }

    /// Stops the daemon this app runs before an update replaces its files, and waits for it: the
    /// one it started, or one it attached to that is not a service.
    public func stopForUpdate() async {
        await closeSyncSession()
        await closeControlSession()
        if let proc = process {
            proc.terminationHandler = nil
            process = nil
            if proc.isRunning {
                proc.terminate()
                let deadline = ContinuousClock.now + .seconds(10)
                while proc.isRunning, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if proc.isRunning { _ = Darwin.kill(proc.processIdentifier, SIGKILL) }
            }
        } else if let daemon = attachedDaemon, !attachedDaemonIsService, !Self.allowsMultipleInstances {
            await Self.stopProcess(daemon, patience: .seconds(10))
        }
        attachedDaemon = nil
        attachedDaemonIsService = false
        runningRuntimeFolder = nil
        runtimeOutdated = false
        state = .stopped
    }

    /// Whether stopping the daemon now leaves one to start again. A service or another instance's
    /// daemon is never stopped; any other needs its entry on disk, which an app bundle stripped of
    /// `runtime/daemon` lacks, and stopping it then would leave this Mac with no daemon at all.
    public func canRestartBoundDaemon(daemonEntryPath: String?) -> Bool {
        let stops = process != nil
            || (attachedDaemon != nil && !attachedDaemonIsService && !Self.allowsMultipleInstances)
        guard stops else { return true }
        guard let daemonEntryPath else { return false }
        return FileManager.default.fileExists(atPath: daemonEntryPath)
    }

    /// Cleanly stops the app-managed local daemon and immediately starts a fresh instance
    /// using the latest bundled runtime (if any), returning new host sessions.
    public func restartBoundDaemon(
        daemonEntryPath: String?,
        relayOrigin: String
    ) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession?) {
        guard canRestartBoundDaemon(daemonEntryPath: daemonEntryPath) else {
            appendLog("Kept the Sarto daemon running: no daemon entry to start it again")
            let msg = PrismL10n(language: PrismLanguage.loadSaved()).tr("error.daemonEntryMissing")
            throw PortRPCError(code: "unavailable", message: msg)
        }
        if let pending = inFlightConnectTask {
            pending.cancel()
            if let stale = try? await pending.value {
                await stale.agent.close()
                if let term = stale.terminal { await term.close() }
            }
            inFlightConnectTask = nil
        }
        await stopForUpdate()
        return try await connectOrStartHosts(
            daemonEntryPath: daemonEntryPath,
            relayOrigin: relayOrigin
        )
    }

    /// Cleanly stops the app-bound daemon (both direct child processes and non-launchd local daemons
    /// attached on `controlSocketPath`) when the user confirms "Quit Completely". `patience` is
    /// longer when an update installs next, which must not replace files a daemon still runs.
    public func shutdownBoundDaemon(patience: TimeInterval = 1.2) {
        guard !releasedForAppRestart else { return }
        syncTask?.cancel()
        syncTask = nil
        if let existingSync = syncSession {
            syncSession = nil
            Task { await existingSync.close() }
        }
        if let existing = controlSession {
            controlSession = nil
            Task { await existing.close() }
        }
        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                let deadline = Date().addingTimeInterval(patience)
                while proc.isRunning && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                // A hung daemon must not outlive Quit Completely. It is the app's own child, whose
                // pid no other process can take before Process reaps it.
                if proc.isRunning {
                    _ = Darwin.kill(proc.processIdentifier, SIGKILL)
                    let killDeadline = Date().addingTimeInterval(0.5)
                    while proc.isRunning && Date() < killDeadline {
                        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                    }
                }
            }
            process = nil
        } else if let daemon = attachedDaemon,
                  !attachedDaemonIsService,
                  !Self.allowsMultipleInstances {
            // The app is quitting: willTerminate returns only once the daemon is gone, so this
            // waits on the main thread, as the spawned daemon's branch does.
            daemon.stopBlocking(patience: max(1.0, patience - 0.2))
        }
        attachedDaemon = nil
        attachedDaemonIsService = false
        state = .stopped
    }

    public func terminateSpawnedDaemonIfNeeded() {
        shutdownBoundDaemon()
    }

    public func stop() async {
        await closeSyncSession()
        await closeControlSession()
        if let proc = process {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                for _ in 0..<15 where proc.isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        process = nil
        state = .stopped
    }

    private func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        recentLogs.append("[\(Date().ISO8601Format())] \(line)")
        if recentLogs.count > 80 {
            recentLogs.removeFirst(recentLogs.count - 80)
        }
    }
}
