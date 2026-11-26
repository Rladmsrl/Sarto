import Foundation
import Observation
import SartoProtocol
#if os(macOS)
import SystemConfiguration
#endif

// MARK: - Unified Multi-Host Models

/// Immutable, observable snapshot of one computer (local Mac or paired remote host) for the
/// unified sidebar tree, top-bar host badge, global search, and cross-host running rail.
public struct UnifiedHostSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    /// Clean display name (trailing `.local` stripped for readability).
    public let name: String
    /// Full hostname or advertised name for tooltips and diagnostics.
    public let fullName: String
    public let platform: String
    public let version: String
    public let isLocal: Bool
    /// `online`, `connecting`, `offline`, or `stopped`.
    public let connectionState: String
    public let viaRelay: Bool
    public let allowsTerminal: Bool
    public let sessions: [SessionSummary]
    public let projects: [ProjectInfo]
    public let noProjectInfo: NoProjectInfo
    public let agents: [AgentStatusInfo]
    public let isLoaded: Bool
    public let error: String?

    public var isOnline: Bool { connectionState == "online" }
    public var isConnecting: Bool { connectionState == "connecting" }

    /// Native SF Symbol representing this computer's hardware form factor.
    public var deviceSymbolName: String {
        let plat = platform.lowercased()
        if plat == "linux" { return "server.rack" }
        if plat == "win32" || plat == "windows" { return "pc" }
        let lower = fullName.lowercased()
        if lower.contains("mini") { return "macmini" }
        if lower.contains("studio") { return "macstudio" }
        if lower.contains("imac") { return "desktopcomputer" }
        if lower.contains("macpro") || lower.contains("mac pro") { return "macpro.gen3" }
        return "laptopcomputer"
    }

    /// Count of non-archived, non-subagent sessions currently awaiting permission or sign-in.
    public var waitingCount: Int {
        sessions.reduce(0) { acc, s in
            guard s.archivedAt == nil, s.origin != "subagent", s.prepared == nil else { return acc }
            if s.permissionCount > 0 { return acc + s.permissionCount }
            if s.status == .awaitingPermission || s.status == .authRequired { return acc + 1 }
            return acc
        }
    }

    /// Count of non-archived, non-subagent sessions currently running or starting.
    public var runningCount: Int {
        sessions.reduce(0) { acc, s in
            guard s.archivedAt == nil, s.origin != "subagent", s.prepared == nil else { return acc }
            return acc + ((s.status == .running || s.status == .starting) ? 1 : 0)
        }
    }
}

/// Cross-host data bundle projected into the Dynamic Island and Right Running Sessions Rail.
public struct LiveHostIslandSource {
    public let hostId: String
    public let hostName: String
    public let isLocal: Bool
    public let sessions: [SessionSummary]
    public let agents: [AgentStatusInfo]
    public let agentOptionsById: [String: AgentOptionsInfo]
    public let replicas: [String: ThreadReplica]
}

/// One background host's published snapshot, observed on its own: a view that reads it redraws
/// when that host changes, never when another does, as it would reading `backgroundHostSnapshots`.
@MainActor
@Observable
final class HostSnapshotCell {
    var snapshot: UnifiedHostSnapshot?

    init(snapshot: UnifiedHostSnapshot?) {
        self.snapshot = snapshot
    }
}

/// Persistent connection & cached state for one connected host in `SartoState.hostPool`.
@MainActor
final class HostPoolSlot {
    let hostId: String
    let isLocal: Bool
    var agent: SartoHostSession
    var terminal: SartoTerminalSession?
    var mode: ConnectionMode
    var eventTask: Task<Void, Never>?
    var linkDropped: Bool = false

    var sessions: [SessionSummary] = []
    /// Where `sessions` stands in the host's index, for reading only its changes again.
    var sessionsCursor: SessionsCursorInfo? = nil
    var projects: [ProjectInfo] = []
    var noProjectInfo: NoProjectInfo = NoProjectInfo()
    var agents: [AgentStatusInfo] = []
    var agentOptionsById: [String: AgentOptionsInfo] = [:]
    var replicas: [String: ThreadReplica] = [:]
    var watchedSessionOrder: [String] = []
    var replicaAccessOrder: [String] = []
    var inFlightSnapshotSessionIDs: Set<String> = []
    var snapshotRetryBySession: [String: SartoState.SnapshotRetryState] = [:]
    var outlineBySession: [String: [OutlineEntryInfo]] = [:]
    var gitStatusByProject: [String: GitStatusInfo] = [:]
    var gitBranchesByProject: [String: BranchListInfo] = [:]
    var lastSelectedSessionID: String? = nil
    var lastNewSessionProjectPath: String? = nil
    var lastNewSessionIsScratch: Bool = false
    var isLoaded: Bool = false
    var error: String? = nil

    init(
        hostId: String,
        isLocal: Bool,
        agent: SartoHostSession,
        terminal: SartoTerminalSession?,
        mode: ConnectionMode
    ) {
        self.hostId = hostId
        self.isLocal = isLocal
        self.agent = agent
        self.terminal = terminal
        self.mode = mode
    }
}

// MARK: - Multi-Host Unified Tree Pool Management

@MainActor
public extension SartoState {
    static func resolveLocalHostDisplayName() -> String {
        #if os(macOS)
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty {
            return cleanHostDisplayName(hostName)
        }
        return "Mac"
        #else
        return "This Device"
        #endif
    }

    static func cleanHostDisplayName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Mac" }
        if trimmed.lowercased().hasSuffix(".local") {
            let stripped = String(trimmed.dropLast(6))
            if !stripped.isEmpty { return stripped }
        }
        return trimmed
    }

    /// True on macOS when signed in and at least one remote computer is visible beside this Mac.
    /// When false, the sidebar and top bar stay 100% identical to the single-Mac layout.
    var hasMultipleHosts: Bool {
        guard daemonOtherHosts != nil, cloudAccountStatus.account.isSignedIn else { return false }
        // `unifiedHosts.count > 1`, without building every host's snapshot: each sidebar row asks
        // this as it draws, and would otherwise also redraw whenever any host's sessions change.
        return otherHosts.contains { !hiddenHostIDs.contains($0.id) }
    }

    /// True when the foreground stage is currently displaying a remote computer's workspace.
    var isViewingRemoteHost: Bool {
        activeHostID != Self.localHostID
    }

    /// Ordered snapshots of every known computer (local Mac first, followed by account-paired remote
    /// computers when signed in), regardless of sidebar visibility.
    var allUnifiedHosts: [UnifiedHostSnapshot] {
        var result: [UnifiedHostSnapshot] = []
        result.append(buildLocalHostSnapshot())
        guard daemonOtherHosts == nil || cloudAccountStatus.account.isSignedIn else {
            return result
        }
        result.reserveCapacity(1 + otherHosts.count)
        for other in otherHosts {
            result.append(buildRemoteHostSnapshot(for: other))
        }
        return result
    }

    /// Ordered snapshots of computers currently visible in the sidebar, top bar, search, and running rail.
    /// This Mac is always included and cannot be hidden.
    var unifiedHosts: [UnifiedHostSnapshot] {
        allUnifiedHosts.filter { $0.isLocal || !hiddenHostIDs.contains($0.id) }
    }

    var visibleHostsCount: Int {
        unifiedHosts.count
    }

    /// The ids of `unifiedHosts`, in order, without building any host's snapshot, so a view that
    /// lists the hosts does not follow their sessions.
    var unifiedHostIDs: [String] {
        var ids = [Self.localHostID]
        guard daemonOtherHosts == nil || cloudAccountStatus.account.isSignedIn else { return ids }
        for other in otherHosts where !hiddenHostIDs.contains(other.id) {
            ids.append(other.id)
        }
        return ids
    }

    /// One computer's snapshot for its own part of the sidebar: the host in front's from the live
    /// state, another's from its cell, so that part redraws only as its host changes.
    func sidebarHostSnapshot(_ hostId: String) -> UnifiedHostSnapshot? {
        if hostId == activeHostID { return activeHostSnapshot }
        if hostId == Self.localHostID { return buildLocalHostSnapshot() }
        guard let other = otherHosts.first(where: { $0.id == hostId }) else { return nil }
        return buildRemoteHostSnapshot(for: other)
    }

    func isHostVisible(_ hostId: String) -> Bool {
        if hostId == Self.localHostID { return true }
        return !hiddenHostIDs.contains(hostId)
    }

    /// Shows or hides a remote computer in the unified sidebar tree, search, and running rail.
    /// The local Mac (`Self.localHostID`) can never be hidden.
    func setHostVisible(_ hostId: String, visible: Bool) async {
        guard hostId != Self.localHostID else { return }

        if visible {
            guard hiddenHostIDs.remove(hostId) != nil else { return }
            reconcileRemoteHostPool(with: otherHosts)
            return
        }

        guard !hiddenHostIDs.contains(hostId) else { return }
        hiddenHostIDs.insert(hostId)

        if activeHostID == hostId {
            let switched = await switchActiveHost(to: Self.localHostID)
            guard switched else {
                hiddenHostIDs.remove(hostId)
                return
            }
        }

        backgroundHostSnapshots.removeValue(forKey: hostId)
        dirtyBackgroundSnapshotHostIDs.remove(hostId)
        remoteHostErrors.removeValue(forKey: hostId)
        if let removedSlot = hostPool.removeValue(forKey: hostId) {
            removedSlot.eventTask?.cancel()
            await removedSlot.agent.close()
            if let term = removedSlot.terminal {
                await term.close()
            }
        }
    }

    /// Snapshot of the host currently driving the main stage.
    var activeHostSnapshot: UnifiedHostSnapshot {
        if activeHostID == Self.localHostID {
            return buildLocalHostSnapshot()
        }
        if let other = otherHosts.first(where: { $0.id == activeHostID }) {
            return buildRemoteHostSnapshot(for: other)
        }
        return buildLocalHostSnapshot()
    }

    var onlineHostsCount: Int {
        unifiedHosts.filter(\.isOnline).count
    }

    var onlineDevicesCount: Int {
        allUnifiedHosts.filter(\.isOnline).count
    }

    /// All online hosts' live sessions, agents, and cached replicas for cross-host
    /// Running Sessions Rail & Dynamic Island projection.
    func allLiveHostSourcesForIsland() -> [LiveHostIslandSource] {
        // Register Observation dependencies on background snapshots and background replica updates.
        _ = backgroundHostSnapshots
        _ = backgroundReplicaRevision

        guard hasMultipleHosts else {
            let snap = activeHostSnapshot
            return [
                LiveHostIslandSource(
                    hostId: activeHostID,
                    hostName: snap.name,
                    isLocal: snap.isLocal,
                    sessions: sessions,
                    agents: agents,
                    agentOptionsById: agentOptionsById,
                    replicas: replicas
                )
            ]
        }

        var list: [LiveHostIslandSource] = []
        for snap in unifiedHosts where snap.isOnline {
            if snap.id == activeHostID {
                list.append(
                    LiveHostIslandSource(
                        hostId: snap.id,
                        hostName: snap.name,
                        isLocal: snap.isLocal,
                        sessions: sessions,
                        agents: agents,
                        agentOptionsById: agentOptionsById,
                        replicas: replicas
                    )
                )
            } else if let slot = hostPool[snap.id] {
                list.append(
                    LiveHostIslandSource(
                        hostId: snap.id,
                        hostName: snap.name,
                        isLocal: snap.isLocal,
                        sessions: slot.sessions,
                        agents: slot.agents,
                        agentOptionsById: slot.agentOptionsById,
                        replicas: slot.replicas
                    )
                )
            }
        }
        return list
    }

    /// Finds which connected host owns a session id (checking active host first, then pool).
    func hostID(owningSession sessionId: String) -> String? {
        if sessions.contains(where: { $0.id == sessionId }) {
            return activeHostID
        }
        for (hid, slot) in hostPool where hid != activeHostID {
            if slot.sessions.contains(where: { $0.id == sessionId }) {
                return hid
            }
        }
        return nil
    }

    /// An agent as the host that runs it lists it: the host in front's from `agents`, another's
    /// from its pool slot.
    func agentStatus(_ agentId: String, onHost hostId: String) -> AgentStatusInfo? {
        if hostId == activeHostID {
            return agents.first { $0.id == agentId }
        }
        return hostPool[hostId]?.agents.first { $0.id == agentId }
    }

    /// A host's session index: what changed since `cursor` merged into `current`, or the whole
    /// index when the changes cannot be merged or the host predates `sessions.changes`. Reading
    /// only the changes keeps a reconnect to a host of many sessions from fetching them all.
    nonisolated static func loadSessionIndex(
        _ session: SartoHostSession,
        current: [SessionSummary],
        cursor: SessionsCursorInfo?
    ) async throws -> (sessions: [SessionSummary], cursor: SessionsCursorInfo?) {
        do {
            let changes = try await session.sessionChanges(since: cursor)
            if let merged = changes.applied(to: current) { return (merged, changes.cursor) }
            let whole = try await session.sessionChanges(since: nil)
            return (whole.applied(to: []) ?? whole.summaries, whole.cursor)
        } catch let error as PortRPCError where error.code == "unknown_method" || error.code == "method_not_found" {
            return (try await session.listSessions(), nil)
        }
    }

    /// Returns the `SartoHostSession` for `hostId` (or the active host when `nil`).
    internal func resolveHostSession(for hostId: String?) -> SartoHostSession? {
        guard let hostId, hostId != activeHostID else { return hostSession }
        return hostPool[hostId]?.agent
    }

    // MARK: - Pool Reconciliation

    /// Keeps persistent background connections open to all online remote hosts reported by the
    /// local daemon, and cleanly drops hosts that were removed from the account or unpaired.
    internal func reconcileRemoteHostPool(with hosts: [OtherHostStatus]) {
        guard daemonOtherHosts != nil else { return }

        // Multi-host pairing requires signing in; drop remote slots whenever signed out.
        if !cloudAccountStatus.account.isSignedIn {
            for hid in Array(hostPool.keys) where hid != Self.localHostID {
                let removedSlot = hostPool.removeValue(forKey: hid)
                backgroundHostSnapshots.removeValue(forKey: hid)
                remoteHostErrors.removeValue(forKey: hid)
                remoteAppUpdateStatusByHost.removeValue(forKey: hid)
                if activeHostID == hid {
                    // Detach foreground references before switching so `saveActiveHostToPool`
                    // never resurrects the closing slot back into `hostPool`.
                    hostSession = nil
                    terminalSession = nil
                    eventLoopTask = nil
                    Task { @MainActor [weak self] in
                        _ = await self?.switchActiveHost(to: Self.localHostID)
                    }
                }
                if let removedSlot {
                    removedSlot.eventTask?.cancel()
                    let a = removedSlot.agent
                    let t = removedSlot.terminal
                    Task {
                        await a.close()
                        if let t { await t.close() }
                    }
                }
            }
            return
        }

        let knownIDs = Set(hosts.map(\.id))

        // Close slots for hosts that were removed.
        for hid in Array(hostPool.keys) where hid != Self.localHostID && !knownIDs.contains(hid) {
            let removedSlot = hostPool.removeValue(forKey: hid)
            backgroundHostSnapshots.removeValue(forKey: hid)
            remoteHostErrors.removeValue(forKey: hid)
            remoteAppUpdateStatusByHost.removeValue(forKey: hid)
            if activeHostID == hid {
                hostSession = nil
                terminalSession = nil
                eventLoopTask = nil
                Task { @MainActor [weak self] in
                    _ = await self?.switchActiveHost(to: Self.localHostID)
                }
            }
            if let removedSlot {
                removedSlot.eventTask?.cancel()
                let a = removedSlot.agent
                let t = removedSlot.terminal
                Task {
                    await a.close()
                    if let t { await t.close() }
                }
            }
        }

        // Refresh metadata and open missing online visible remote hosts in the background.
        for host in hosts {
            if hiddenHostIDs.contains(host.id) && host.id != activeHostID {
                if let removedSlot = hostPool.removeValue(forKey: host.id) {
                    removedSlot.eventTask?.cancel()
                    let a = removedSlot.agent
                    let t = removedSlot.terminal
                    Task {
                        await a.close()
                        if let t { await t.close() }
                    }
                }
                backgroundHostSnapshots.removeValue(forKey: host.id)
                continue
            }

            if let existing = hostPool[host.id] {
                let nextMode = ConnectionMode.remoteHost(name: host.name, viaRelay: host.connection.viaRelay)
                existing.mode = nextMode
                if host.id != activeHostID {
                    publishBackgroundSnapshot(for: host.id)
                }
                if host.connection.isOnline && !existing.isLoaded {
                    Task { @MainActor [weak self] in
                        await self?.reloadBackgroundSlot(hostId: host.id)
                    }
                }
                continue
            }

            if host.connection.isOnline {
                Task { @MainActor [weak self] in
                    await self?.openRemoteHostIntoPool(host)
                }
            } else {
                backgroundHostSnapshots[host.id] = buildRemoteHostSnapshot(for: host)
            }
        }
    }

    /// Opens a remote host on the local daemon's `hosts` socket, loads its initial index,
    /// and starts its persistent event loop without disturbing the currently active host.
    @discardableResult
    internal func openRemoteHostIntoPool(_ host: OtherHostStatus) async -> HostPoolSlot? {
        if let existing = hostPool[host.id] {
            return existing
        }
        if let inFlight = openingRemoteHostTasks[host.id] {
            return await inFlight.value
        }
        guard let daemon = daemonOtherHosts else { return nil }
        let task = Task<HostPoolSlot?, Never> { @MainActor [weak self] in
            guard let self else { return nil }
            defer { self.openingRemoteHostTasks.removeValue(forKey: host.id) }
            do {
                let opened = try await daemon.open(host.id)
                // Ensure host wasn't removed, hidden, or signed out while opening.
                guard self.cloudAccountStatus.account.isSignedIn,
                      self.otherHosts.contains(where: { $0.id == host.id }),
                      !self.hiddenHostIDs.contains(host.id)
                else {
                    await opened.agent.close()
                    await opened.terminal.close()
                    return nil
                }
                let mode = ConnectionMode.remoteHost(name: host.name, viaRelay: host.connection.viaRelay)
                let slot = HostPoolSlot(
                    hostId: host.id,
                    isLocal: false,
                    agent: opened.agent,
                    terminal: opened.terminal,
                    mode: mode
                )
                self.hostPool[host.id] = slot
                self.remoteHostErrors.removeValue(forKey: host.id)
                self.startPooledEventLoop(for: host.id, session: opened.agent)
                await self.reloadBackgroundSlot(hostId: host.id)
                return slot
            } catch {
                guard !Self.isCancellationError(error), !Task.isCancelled else { return nil }
                self.remoteHostErrors[host.id] = error.localizedDescription
                self.backgroundHostSnapshots[host.id] = self.buildRemoteHostSnapshot(for: host)
                return nil
            }
        }
        openingRemoteHostTasks[host.id] = task
        return await task.value
    }

    /// Reloads the initial index (`sessions`, `projects`, `noProject`, `agents`, `agentOptions`)
    /// into a background slot and publishes its observable snapshot.
    internal func reloadBackgroundSlot(hostId: String) async {
        guard let slot = hostPool[hostId] else { return }
        let session = slot.agent
        let isActive = activeHostID == hostId
        let current = isActive ? sessions : slot.sessions
        let cursor = isActive ? sessionsCursor : slot.sessionsCursor
        do {
            async let sessionsReq = Self.loadSessionIndex(session, current: current, cursor: cursor)
            async let projectsReq = session.listProjects()
            async let noProjectReq = session.noProjectState()
            async let agentsReq = session.listAgents()
            async let optionsReq = session.listAgentOptions()
            async let updateReq = session.appUpdateStatus()

            let index = try await sessionsReq
            let loadedSessions = index.sessions
            let loadedProjects = (try? await projectsReq) ?? slot.projects
            let loadedNoProject = (try? await noProjectReq) ?? slot.noProjectInfo
            let loadedAgents = (try? await agentsReq) ?? slot.agents
            let loadedOptions = try? await optionsReq
            let loadedUpdate = try? await updateReq

            guard hostPool[hostId]?.agent === session else { return }

            if let loadedUpdate {
                remoteAppUpdateStatusByHost[hostId] = loadedUpdate
            }

            if activeHostID == hostId {
                self.sessions = loadedSessions
                self.sessionsCursor = index.cursor
                self.projects = loadedProjects
                self.noProjectInfo = loadedNoProject
                self.agents = loadedAgents
                if let loadedOptions {
                    var map: [String: AgentOptionsInfo] = [:]
                    for item in loadedOptions { map[item.agentId] = item }
                    self.agentOptionsById = map
                }
                slot.isLoaded = true
                slot.error = nil
            } else {
                slot.sessions = loadedSessions
                slot.sessionsCursor = index.cursor
                slot.projects = loadedProjects
                slot.noProjectInfo = loadedNoProject
                slot.agents = loadedAgents
                if let loadedOptions {
                    var map: [String: AgentOptionsInfo] = [:]
                    for item in loadedOptions { map[item.agentId] = item }
                    slot.agentOptionsById = map
                }
                slot.isLoaded = true
                slot.error = nil
                remoteHostErrors.removeValue(forKey: hostId)
                publishBackgroundSnapshot(for: hostId)
            }
        } catch {
            guard !Self.isCancellationError(error), !Task.isCancelled else { return }
            guard hostPool[hostId]?.agent === session else { return }
            slot.error = error.localizedDescription
            if hostId != Self.localHostID {
                remoteHostErrors[hostId] = error.localizedDescription
            }
            if activeHostID != hostId {
                publishBackgroundSnapshot(for: hostId)
            }
        }
    }

    // MARK: - Persistent Pooled Event Loop

    internal func startPooledEventLoop(for hostId: String, session: SartoHostSession) {
        guard let slot = hostPool[hostId], slot.agent === session else { return }
        slot.eventTask?.cancel()
        slot.eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { return }
                if self.activeHostID == hostId && self.hostSession === session {
                    await self.handleHostEvent(event)
                } else {
                    await self.handleBackgroundHostEvent(event, for: hostId, session: session)
                }
            }
            guard let self, !Task.isCancelled else { return }
            await self.handlePooledDisconnect(hostId: hostId, session: session)
        }
        if activeHostID == hostId {
            eventLoopTask = slot.eventTask
        }
    }

    private func handleBackgroundHostEvent(
        _ event: HostEvent,
        for hostId: String,
        session: SartoHostSession
    ) async {
        guard let slot = hostPool[hostId], slot.agent === session else { return }

        switch event {
        case .sessionSummary(let summary):
            if summary.prepared != nil { return }
            let previousSummary = slot.sessions.first(where: { $0.id == summary.id })
            if let idx = slot.sessions.firstIndex(where: { $0.id == summary.id }) {
                slot.sessions[idx] = summary
            } else {
                slot.sessions.insert(summary, at: 0)
            }
            maybeShowFocusedAttentionNotice(previous: previousSummary, next: summary, hostId: hostId)
            if var cached = slot.replicas[summary.id] {
                let unwatchedWaiting = !slot.watchedSessionOrder.contains(summary.id)
                    && (summary.permissionCount > 0 || summary.status == .awaitingPermission)
                    && cached.pendingTools.isEmpty
                let nextTitle = summary.title ?? cached.session.title
                if cached.session.status != summary.status
                    || cached.session.turnStartedAt != summary.turnStartedAt
                    || cached.session.title != nextTitle {
                    cached.session.status = summary.status
                    cached.session.turnStartedAt = summary.turnStartedAt
                    cached.session.title = nextTitle
                    slot.replicas[summary.id] = cached
                    backgroundReplicaRevision &+= 1
                }
                if unwatchedWaiting {
                    slot.replicas.removeValue(forKey: summary.id)
                    backgroundReplicaRevision &+= 1
                    Task { @MainActor [weak self] in
                        await self?.fetchSessionSnapshotIfNeeded(summary.id, onHost: hostId)
                    }
                }
            }
            scheduleBackgroundSnapshotPublish(for: hostId)

        case .sessionPatches(let batch):
            guard var replica = slot.replicas[batch.sessionId] else { return }
            if batch.seq <= replica.seq { return }
            if (batch.from ?? batch.seq) <= replica.seq + 1, replica.apply(batch) {
                slot.replicas[batch.sessionId] = replica
                // The slot is not observed: only what the island and the rail show is announced.
                if Self.patchesTouchIsland(batch, in: replica) {
                    backgroundReplicaRevision &+= 1
                }
            } else {
                // Evict stale background replica so next select or island fetch reloads cleanly.
                slot.replicas.removeValue(forKey: batch.sessionId)
                backgroundReplicaRevision &+= 1
            }

        case .sessionRemoved(let sid):
            slot.sessions.removeAll { $0.id == sid }
            slot.replicas.removeValue(forKey: sid)
            slot.watchedSessionOrder.removeAll { $0 == sid }
            slot.replicaAccessOrder.removeAll { $0 == sid }
            slot.snapshotRetryBySession.removeValue(forKey: sid)
            if slot.lastSelectedSessionID == sid {
                slot.lastSelectedSessionID = nil
            }
            publishBackgroundSnapshot(for: hostId)

        case .projectsChanged(let nextProjects, let nextNoProject):
            slot.projects = nextProjects
            if let nextNoProject {
                slot.noProjectInfo = nextNoProject
            }
            publishBackgroundSnapshot(for: hostId)

        case .agentStatus(let status):
            if let idx = slot.agents.firstIndex(where: { $0.id == status.id }) {
                slot.agents[idx] = status
            } else {
                slot.agents.append(status)
            }
            publishBackgroundSnapshot(for: hostId)

        case .agentOptions(let options):
            slot.agentOptionsById[options.agentId] = options

        case .hostLinkClosed:
            slot.linkDropped = true
            publishBackgroundSnapshot(for: hostId)

        case .hostLinkOpen:
            let shouldReload = slot.linkDropped || !slot.isLoaded
            slot.linkDropped = false
            if shouldReload {
                await reloadBackgroundSlot(hostId: hostId)
            }

        case .resync:
            await reloadBackgroundSlot(hostId: hostId)

        case .appUpdateState(let status):
            remoteAppUpdateStatusByHost[hostId] = status
            publishBackgroundSnapshot(for: hostId)

        case .appUpdateCommand(let action):
            if hostId == Self.localHostID {
                onHostAppUpdateCommand?(action)
            }

        case .hostLoad(let load):
            hostLoadsByHostID[hostId] = load

        case .gameStatus, .gameFrame:
            // The game comes from the daemon's control connection, never from a host port.
            break

        case .remoteClaudeActiveChanged(let active):
            if hostId == Self.localHostID {
                remoteClaudeActiveRuns = active
            }

        default:
            break
        }
    }

    private func handlePooledDisconnect(hostId: String, session: SartoHostSession) async {
        guard let slot = hostPool[hostId], slot.agent === session else { return }
        hostPool.removeValue(forKey: hostId)

        if activeHostID == hostId && hostSession === session {
            // Active host dropped: if a remote host socket itself died (daemon restart) and local is
            // gone too, let existing reconnect handle it. If remote died while local is alive, switch
            // back gracefully if removed, or run reconnect.
            await handleUnexpectedDisconnect(from: session)
            return
        }

        // Background slot closed cleanly; close its terminal and refresh snapshot.
        if let term = slot.terminal {
            await term.close()
        }
        if hostId == Self.localHostID && !isManualDisconnect {
            // Reconnect local daemon in background with exponential backoff if it restarted while viewing a remote host.
            Task { @MainActor [weak self] in
                var delay: Duration = .milliseconds(1500)
                for _ in 0..<12 {
                    try? await Task.sleep(for: delay)
                    guard let self, !self.isManualDisconnect, self.hostPool[Self.localHostID] == nil else { return }
                    guard let reconnector = self.onReconnectLocalDaemon else { return }
                    if let hosts = try? await reconnector() {
                        guard self.hostPool[Self.localHostID] == nil else {
                            await hosts.agent.close()
                            if let term = hosts.terminal { await term.close() }
                            return
                        }
                        let localMode = ConnectionMode.localDaemon(socketPath: "")
                        let nextSlot = HostPoolSlot(
                            hostId: Self.localHostID,
                            isLocal: true,
                            agent: hosts.agent,
                            terminal: hosts.terminal,
                            mode: localMode
                        )
                        self.hostPool[Self.localHostID] = nextSlot
                        self.startPooledEventLoop(for: Self.localHostID, session: hosts.agent)
                        self.onLocalDaemonAttached?()
                        await self.reloadBackgroundSlot(hostId: Self.localHostID)
                        return
                    }
                    delay = min(delay * 2, .seconds(15))
                }
            }
        } else if let other = otherHosts.first(where: { $0.id == hostId }) {
            backgroundHostSnapshots[hostId] = buildRemoteHostSnapshot(for: other)
        }
    }

    // MARK: - Zero-RTT Instant Host Foregrounding

    /// Switches the foreground workbench to `targetHostID` without tearing down the outgoing host.
    /// Optionally selects a specific session or opens the New Session stage on a project on that host.
    @discardableResult
    public func switchActiveHost(
        to targetHostID: String,
        selectingSession targetSessionID: String? = nil,
        openNewSessionOnProject newProject: (path: String?, scratch: Bool?, parentId: String?)? = nil,
        cancelsReconnect: Bool = true
    ) async -> Bool {
        if cancelsReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        hostSwitchGeneration &+= 1
        let switchGen = hostSwitchGeneration
        // Explicitly switching to a hidden host makes it visible again.
        hiddenHostIDs.remove(targetHostID)

        if targetHostID == activeHostID && hostSession != nil {
            if let sid = targetSessionID {
                await selectSession(sid)
            } else if let np = newProject {
                openNewSession(projectPath: np.path, scratch: np.scratch, parentId: np.parentId)
            }
            return true
        }

        // Ensure target host slot is open & loaded in the pool.
        let incoming: HostPoolSlot
        if let existing = hostPool[targetHostID] {
            incoming = existing
            if !incoming.isLoaded {
                await reloadBackgroundSlot(hostId: targetHostID)
                guard switchGen == hostSwitchGeneration else { return false }
            }
        } else if targetHostID == Self.localHostID {
            guard let reconnector = onReconnectLocalDaemon else {
                connectionError = l10n.tr("studio.daemonOffline")
                return false
            }
            isConnecting = true
            defer { isConnecting = false }
            do {
                let opened = try await reconnector()
                guard switchGen == hostSwitchGeneration else {
                    await opened.agent.close()
                    if let term = opened.terminal { await term.close() }
                    return false
                }
                let mode = ConnectionMode.localDaemon(socketPath: "")
                let attached = await attachLiveSession(
                    opened.agent,
                    terminal: opened.terminal,
                    mode: mode,
                    cancelsReconnect: cancelsReconnect
                )
                if attached {
                    if let sid = targetSessionID {
                        await selectSession(sid)
                    } else if let np = newProject {
                        openNewSession(projectPath: np.path, scratch: np.scratch, parentId: np.parentId)
                    }
                }
                return attached
            } catch {
                if switchGen == hostSwitchGeneration {
                    reportConnectionError(error)
                }
                return false
            }
        } else {
            guard let other = otherHosts.first(where: { $0.id == targetHostID }) else {
                connectionError = l10n.tr("hosts.hostNotFound")
                return false
            }
            isConnecting = true
            connectionError = nil
            defer { isConnecting = false }
            guard let opened = await openRemoteHostIntoPool(other) else {
                if switchGen == hostSwitchGeneration {
                    connectionError = remoteHostErrors[targetHostID] ?? l10n.tr("hosts.hostOfflineNamed", Self.cleanHostDisplayName(other.name))
                }
                return false
            }
            guard switchGen == hostSwitchGeneration else { return false }
            incoming = opened
        }

        // 1. Snapshot outgoing foreground host into its persistent pool slot (keep sockets alive!),
        // and clear its shown-session presence so it knows this Mac is no longer viewing it in front.
        if let prev = lastReportedShownSession,
           prev.hostId == activeHostID,
           !prev.ids.isEmpty,
           let outgoing = hostSession,
           ObjectIdentifier(outgoing) == prev.sessionObjectId {
            Task { try? await outgoing.showSessions([]) }
            lastReportedShownSession = nil
        }
        saveActiveHostToPool()

        // 2. Swap incoming host into the foreground synchronously (zero teardown, zero re-dial!).
        connectionGeneration &+= 1
        let generation = connectionGeneration
        prefetchTask?.cancel()
        prefetchTask = nil
        for (_, task) in activeOpenTasks { task.cancel() }
        activeOpenTasks.removeAll()
        preparedSession = nil
        preparedTargetKey = nil
        isPreparingSession = false
        earlyAttachedSessionIDs.removeAll()

        activeHostID = targetHostID
        hostSession = incoming.agent
        terminalSession = incoming.terminal
        eventLoopTask = incoming.eventTask
        connectionMode = incoming.mode
        lastAttachedMode = incoming.mode
        lastOtherHostID = incoming.isLocal ? nil : targetHostID
        hostLinkDropped = incoming.linkDropped
        connectionError = nil
        statusMessage = incoming.linkDropped
            ? l10n.tr("hosts.linkReconnecting", activeHostSnapshot.name)
            : nil

        sessions = incoming.sessions
        sessionsCursor = incoming.sessionsCursor
        projects = incoming.projects
        noProjectInfo = incoming.noProjectInfo
        agents = incoming.agents
        agentOptionsById = incoming.agentOptionsById
        replicas = incoming.replicas
        watchedSessionOrder = incoming.watchedSessionOrder
        replicaAccessOrder = incoming.replicaAccessOrder
        inFlightSnapshotSessionIDs = incoming.inFlightSnapshotSessionIDs
        snapshotRetryBySession = incoming.snapshotRetryBySession
        outlineBySession = incoming.outlineBySession
        gitStatusByProject = incoming.gitStatusByProject
        gitBranchesByProject = incoming.gitBranchesByProject
        newSessionProjectPath = incoming.lastNewSessionProjectPath
        newSessionIsScratch = incoming.lastNewSessionIsScratch
        backgroundHostSnapshots.removeValue(forKey: targetHostID)

        if incoming.isLocal {
            devices.tearDown()
        } else {
            devices.attach(remoteHostSession: incoming.agent)
        }

        // 3. Pick target session or new-session stage and re-attach workspace controller.
        let desiredSessionID: String? = {
            if let sid = targetSessionID { return sid }
            if newProject != nil { return nil }
            if let prev = incoming.lastSelectedSessionID, sessions.contains(where: { $0.id == prev }) {
                return prev
            }
            return prioritizedSessions.first?.id
        }()

        let desiredPath: String = {
            if let npPath = newProject?.path, !npPath.isEmpty { return npPath }
            if let sid = desiredSessionID, let s = sessionSummary(for: sid), !s.projectPath.isEmpty {
                return s.worktree?.path ?? s.projectPath
            }
            return projects.first(where: { !$0.isMissing })?.path
                ?? projects.first?.path
                ?? ""
        }()

        workspace.attach(
            host: incoming.agent,
            terminal: incoming.terminal,
            projectPath: desiredPath,
            hostId: targetHostID,
            isRemote: !incoming.isLocal
        )

        if let sid = desiredSessionID {
            await selectSession(sid)
        } else if let np = newProject {
            openNewSession(projectPath: np.path, scratch: np.scratch, parentId: np.parentId)
        } else {
            openNewSession(projectPath: projects.first(where: { !$0.isMissing })?.path, scratch: projects.isEmpty, parentId: nil)
        }

        guard generation == connectionGeneration else { return true }

        // Keep usage summary and recent sessions warm on the newly active host.
        let activeAgent = incoming.agent
        Task { [weak self] in
            guard let self, self.hostSession === activeAgent else { return }
            await self.refreshUsageSummary()
        }
        scheduleRecentSessionPrefetch(excluding: desiredSessionID)
        return true
    }

    /// Convenience for sidebar / new-session clicks targeting a specific computer.
    public func openNewSession(
        onHost hostId: String,
        projectPath: String? = nil,
        scratch: Bool? = nil,
        parentId: String? = nil
    ) async {
        if hostId == activeHostID {
            openNewSession(projectPath: projectPath, scratch: scratch, parentId: parentId)
        } else {
            _ = await switchActiveHost(
                to: hostId,
                selectingSession: nil,
                openNewSessionOnProject: (projectPath, scratch, parentId)
            )
        }
    }

    /// Saves the currently active host's foreground arrays/caches back into its persistent `HostPoolSlot`.
    internal func saveActiveHostToPool() {
        guard let currentAgent = hostSession else { return }
        let slot: HostPoolSlot
        if let existing = hostPool[activeHostID], existing.agent === currentAgent {
            slot = existing
        } else {
            slot = HostPoolSlot(
                hostId: activeHostID,
                isLocal: activeHostID == Self.localHostID,
                agent: currentAgent,
                terminal: terminalSession,
                mode: connectionMode
            )
            slot.eventTask = eventLoopTask
            hostPool[activeHostID] = slot
        }

        slot.terminal = terminalSession
        slot.mode = connectionMode
        slot.eventTask = eventLoopTask
        slot.linkDropped = hostLinkDropped
        slot.sessions = sessions
        slot.sessionsCursor = sessionsCursor
        slot.projects = projects
        slot.noProjectInfo = noProjectInfo
        slot.agents = agents
        slot.agentOptionsById = agentOptionsById
        slot.replicas = replicas
        slot.watchedSessionOrder = watchedSessionOrder
        slot.replicaAccessOrder = replicaAccessOrder
        slot.inFlightSnapshotSessionIDs = inFlightSnapshotSessionIDs
        slot.snapshotRetryBySession = snapshotRetryBySession
        slot.outlineBySession = outlineBySession
        slot.gitStatusByProject = gitStatusByProject
        slot.gitBranchesByProject = gitBranchesByProject
        slot.lastSelectedSessionID = selectedSessionID
        slot.lastNewSessionProjectPath = newSessionProjectPath
        slot.lastNewSessionIsScratch = newSessionIsScratch
        slot.isLoaded = true
        slot.error = nil

        publishBackgroundSnapshot(for: activeHostID)
    }

    /// Closes every pooled host connection (used on full manual disconnect).
    internal func tearDownAllHostPoolSlots() async {
        let slots = Array(hostPool.values)
        hostPool.removeAll()
        backgroundSnapshotFlushTask?.cancel()
        backgroundSnapshotFlushTask = nil
        dirtyBackgroundSnapshotHostIDs.removeAll()
        lastReportedShownSession = nil
        backgroundHostSnapshots.removeAll()
        remoteHostErrors.removeAll()
        remoteAppUpdateStatusByHost.removeAll()
        for (_, task) in openingRemoteHostTasks { task.cancel() }
        openingRemoteHostTasks.removeAll()
        activeHostID = Self.localHostID
        for slot in slots {
            slot.eventTask?.cancel()
            await slot.agent.close()
            if let term = slot.terminal {
                await term.close()
            }
        }
    }

    /// Fetches a background host's session snapshot into its slot replica cache (used by
    /// Dynamic Island / Running Rail when a remote session waits for permission).
    public func fetchSessionSnapshotIfNeeded(_ sessionId: String, onHost hostId: String?) async {
        guard let hostId, hostId != activeHostID else {
            await fetchSessionSnapshotIfNeeded(sessionId)
            return
        }
        guard let slot = hostPool[hostId], slot.replicas[sessionId] == nil else { return }
        if let retry = slot.snapshotRetryBySession[sessionId], Date() < retry.nextAllowedAt {
            return
        }
        guard slot.inFlightSnapshotSessionIDs.insert(sessionId).inserted else { return }
        defer { slot.inFlightSnapshotSessionIDs.remove(sessionId) }
        let agent = slot.agent
        do {
            let snapshot = try await agent.openSession(sessionId: sessionId)
            guard hostPool[hostId]?.agent === agent else { return }
            slot.snapshotRetryBySession.removeValue(forKey: sessionId)
            slot.replicas[sessionId] = ThreadReplica(snapshot: snapshot)
            slot.replicaAccessOrder.removeAll(where: { $0 == sessionId })
            slot.replicaAccessOrder.append(sessionId)
            let maxBackgroundReplicas = 24
            while slot.replicaAccessOrder.count > maxBackgroundReplicas {
                let oldest = slot.replicaAccessOrder.removeFirst()
                slot.replicas.removeValue(forKey: oldest)
            }
            backgroundReplicaRevision &+= 1
            publishBackgroundSnapshot(for: hostId)
        } catch {
            guard hostPool[hostId]?.agent === agent else { return }
            var state = slot.snapshotRetryBySession[sessionId] ?? SartoState.SnapshotRetryState()
            state.consecutiveFailures += 1
            let delaySeconds = min(30.0, pow(2.0, Double(min(state.consecutiveFailures, 5))))
            state.nextAllowedAt = Date().addingTimeInterval(delaySeconds)
            slot.snapshotRetryBySession[sessionId] = state
        }
    }

    /// Background-host-aware session outputs fetch for sidebar hover preview cards.
    public func fetchSessionOutputs(sessionId: String, onHost hostId: String?) async -> SessionOutputsInfo? {
        guard let hostId, hostId != activeHostID else {
            return await fetchSessionOutputs(sessionId: sessionId)
        }
        let cacheKey = "\(hostId)::\(sessionId)"
        let now = Date().timeIntervalSince1970
        if let cached = outputsCache[cacheKey], (now - cached.fetchedAt) < 12.0 {
            return cached.info
        }
        guard let host = hostPool[hostId]?.agent else { return nil }
        if let info = try? await host.sessionOutputs(sessionId: sessionId) {
            outputsCache[cacheKey] = (now, info)
            return info
        }
        return nil
    }

    /// Runs full-text session search (`sessions.search`) concurrently across every online host.
    public func searchAllHosts(query: String) async -> [(hostId: String, hostName: String, isLocal: Bool, hits: [ConversationHitInfo], indexing: SearchIndexingInfo?)] {
        let targets: [(hostId: String, hostName: String, isLocal: Bool, session: SartoHostSession)] = unifiedHosts.compactMap { snap in
            guard snap.isOnline, let session = resolveHostSession(for: snap.id) else { return nil }
            return (snap.id, snap.name, snap.isLocal, session)
        }
        guard !targets.isEmpty else { return [] }
        return await withTaskGroup(
            of: (Int, String, String, Bool, [ConversationHitInfo], SearchIndexingInfo?)?.self
        ) { group in
            for (idx, target) in targets.enumerated() {
                group.addTask {
                    guard let res = try? await target.session.searchSessions(query: query) else {
                        return nil
                    }
                    return (idx, target.hostId, target.hostName, target.isLocal, res.hits, res.indexing)
                }
            }
            var collected: [(Int, String, String, Bool, [ConversationHitInfo], SearchIndexingInfo?)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
                .sorted { $0.0 < $1.0 }
                .map { ($0.1, $0.2, $0.3, $0.4, $0.5) }
        }
    }

    // MARK: - Cross-Host App Version & Remote Update

    /// Reports this Mac's current app version and updater state to the local daemon so paired
    /// devices can inspect it and receive live progress events.
    func reportLocalAppUpdateState(_ status: AppUpdateStatusInfo) async {
        remoteAppUpdateStatusByHost[Self.localHostID] = status
        guard let localSession = resolveHostSession(for: Self.localHostID) else { return }
        try? await localSession.reportAppUpdateState(status)
    }

    /// Queries the latest app version and updater status from a connected or online host.
    func refreshHostAppUpdateStatus(hostId: String) async {
        if let existing = resolveHostSession(for: hostId) {
            if let status = try? await existing.appUpdateStatus() {
                remoteAppUpdateStatusByHost[hostId] = status
                if hostId != activeHostID {
                    publishBackgroundSnapshot(for: hostId)
                }
            }
            return
        }
        guard hostId != Self.localHostID,
              let daemon = daemonOtherHosts,
              let other = otherHosts.first(where: { $0.id == hostId && $0.connection.isOnline })
        else { return }
        guard let opened = try? await daemon.open(other.id) else { return }
        defer {
            let a = opened.agent
            let t = opened.terminal
            Task {
                await a.close()
                await t.close()
            }
        }
        if let status = try? await opened.agent.appUpdateStatus() {
            remoteAppUpdateStatusByHost[hostId] = status
            publishBackgroundSnapshot(for: hostId)
        }
    }

    /// Sends a `check` or `install` app-update command to a remote computer over the E2EE channel.
    /// The remote Mac's own updater verifies release signatures, SHA-512, and code signing before installing.
    func requestRemoteAppUpdate(hostId: String, action: String) async -> (accepted: Bool, message: String?) {
        var transient: (agent: SartoHostSession, terminal: SartoTerminalSession)? = nil
        let targetSession: SartoHostSession
        if let existing = resolveHostSession(for: hostId) {
            targetSession = existing
        } else if hostId != Self.localHostID,
                  let daemon = daemonOtherHosts,
                  let other = otherHosts.first(where: { $0.id == hostId && $0.connection.isOnline }) {
            do {
                let opened = try await daemon.open(other.id)
                transient = opened
                targetSession = opened.agent
            } catch {
                return (false, error.localizedDescription)
            }
        } else {
            return (false, l10n.tr("settings.remote.updateHostOffline"))
        }

        defer {
            if let transient {
                let a = transient.agent
                let t = transient.terminal
                Task {
                    await a.close()
                    await t.close()
                }
            }
        }

        do {
            let result = try await targetSession.requestAppUpdate(action: action)
            remoteAppUpdateStatusByHost[hostId] = result.status
            if hostId != activeHostID {
                publishBackgroundSnapshot(for: hostId)
            }
            if result.accepted {
                return (true, nil)
            }
            switch result.reason {
            case "app_not_running":
                return (false, l10n.tr("settings.remote.updateAppNotRunning"))
            case "install_unavailable":
                return (false, l10n.tr("settings.remote.updateInstallUnavailable"))
            default:
                return (false, l10n.tr("settings.remote.updateFailed"))
            }
        } catch let rpcError as PortRPCError {
            if rpcError.code == "unknown_method"
                || rpcError.code == "method_not_found"
                || rpcError.message.localizedCaseInsensitiveContains("unknown method") {
                return (false, l10n.tr("settings.remote.updateUnsupportedOldHost"))
            }
            return (false, rpcError.localizedDescription)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Snapshot Builders

    private var localAppVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "SartoVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0"
    }

    /// Keeps each host's cell equal to `backgroundHostSnapshots`, writing only the ones that changed.
    internal func syncHostSnapshotCells() {
        let snapshots = backgroundHostSnapshots
        for (hostId, cell) in hostSnapshotCells {
            let next = snapshots[hostId]
            if cell.snapshot != next { cell.snapshot = next }
        }
        for (hostId, snapshot) in snapshots where hostSnapshotCells[hostId] == nil {
            hostSnapshotCells[hostId] = HostSnapshotCell(snapshot: snapshot)
        }
    }

    /// A background host's published snapshot, following that host alone. A host without one gets
    /// an empty cell, which `syncHostSnapshotCells` fills once it has one.
    internal func cachedHostSnapshot(_ hostId: String) -> UnifiedHostSnapshot? {
        if let cell = hostSnapshotCells[hostId] { return cell.snapshot }
        let cell = HostSnapshotCell(snapshot: nil)
        hostSnapshotCells[hostId] = cell
        return cell.snapshot
    }

    internal func publishBackgroundSnapshot(for hostId: String) {
        dirtyBackgroundSnapshotHostIDs.remove(hostId)
        let next: UnifiedHostSnapshot
        if hostId == Self.localHostID {
            next = buildLocalHostSnapshot(preferSlot: true)
        } else if let other = otherHosts.first(where: { $0.id == hostId }) {
            next = buildRemoteHostSnapshot(for: other, preferSlot: true)
        } else {
            return
        }
        // Every write redraws all that reads any host's snapshot, as the whole sidebar does.
        if backgroundHostSnapshots[hostId] != next {
            backgroundHostSnapshots[hostId] = next
        }
    }

    /// Publishes a background host's snapshot within `backgroundSnapshotCoalesce`, with every other
    /// host's that changed meanwhile: a host streams a summary for each tool call of each running
    /// session, and each publish redraws the sidebar and reruns the island's projection.
    internal func scheduleBackgroundSnapshotPublish(for hostId: String) {
        dirtyBackgroundSnapshotHostIDs.insert(hostId)
        guard backgroundSnapshotFlushTask == nil else { return }
        backgroundSnapshotFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.backgroundSnapshotCoalesce)
            guard let self else { return }
            self.backgroundSnapshotFlushTask = nil
            let dirty = self.dirtyBackgroundSnapshotHostIDs
            for hostId in dirty where hostId != self.activeHostID && self.hostPool[hostId] != nil {
                self.publishBackgroundSnapshot(for: hostId)
            }
            self.dirtyBackgroundSnapshotHostIDs.removeAll()
        }
    }

    internal static let backgroundSnapshotCoalesce: Duration = .milliseconds(120)

    private func buildLocalHostSnapshot(preferSlot: Bool = false) -> UnifiedHostSnapshot {
        let display = localHostDisplayName
        let version = localAppVersion
        if !preferSlot && activeHostID == Self.localHostID {
            return UnifiedHostSnapshot(
                id: Self.localHostID,
                name: display,
                fullName: display,
                platform: "darwin",
                version: version,
                isLocal: true,
                connectionState: connectionMode.isLive ? "online" : "offline",
                viaRelay: false,
                allowsTerminal: true,
                sessions: sessions,
                projects: projects,
                noProjectInfo: noProjectInfo,
                agents: agents,
                isLoaded: connectionMode.isLive,
                error: nil
            )
        }
        if !preferSlot, let cached = cachedHostSnapshot(Self.localHostID), cached.version == version {
            return cached
        }
        if let slot = hostPool[Self.localHostID] {
            return UnifiedHostSnapshot(
                id: Self.localHostID,
                name: display,
                fullName: display,
                platform: "darwin",
                version: version,
                isLocal: true,
                connectionState: "online",
                viaRelay: false,
                allowsTerminal: true,
                sessions: slot.sessions,
                projects: slot.projects,
                noProjectInfo: slot.noProjectInfo,
                agents: slot.agents,
                isLoaded: slot.isLoaded,
                error: slot.error
            )
        }
        return UnifiedHostSnapshot(
            id: Self.localHostID,
            name: display,
            fullName: display,
            platform: "darwin",
            version: version,
            isLocal: true,
            connectionState: "offline",
            viaRelay: false,
            allowsTerminal: true,
            sessions: [],
            projects: [],
            noProjectInfo: NoProjectInfo(),
            agents: [],
            isLoaded: false,
            error: nil
        )
    }

    private func buildRemoteHostSnapshot(
        for other: OtherHostStatus,
        preferSlot: Bool = false
    ) -> UnifiedHostSnapshot {
        let cleanName = Self.cleanHostDisplayName(other.name)
        let reportedVersion = remoteAppUpdateStatusByHost[other.id]?.currentVersion
        let resolvedVersion: String = {
            if let reportedVersion, !reportedVersion.isEmpty { return reportedVersion }
            return other.version.isEmpty ? "0.0.0" : other.version
        }()
        if !preferSlot && activeHostID == other.id {
            return UnifiedHostSnapshot(
                id: other.id,
                name: cleanName,
                fullName: other.name,
                platform: other.platform,
                version: resolvedVersion,
                isLocal: false,
                connectionState: hostLinkDropped ? "connecting" : other.connection.state,
                viaRelay: other.connection.viaRelay,
                allowsTerminal: other.connection.allowsTerminal,
                sessions: sessions,
                projects: projects,
                noProjectInfo: noProjectInfo,
                agents: agents,
                isLoaded: true,
                error: nil
            )
        }
        if !preferSlot, let cached = cachedHostSnapshot(other.id) {
            let liveState = hostPool[other.id]?.linkDropped == true ? "connecting" : other.connection.state
            if cached.connectionState == liveState
                && cached.viaRelay == other.connection.viaRelay
                && cached.allowsTerminal == other.connection.allowsTerminal
                && cached.fullName == other.name
                && cached.version == resolvedVersion
                && cached.error == (hostPool[other.id]?.error ?? remoteHostErrors[other.id]) {
                return cached
            }
        }
        if let slot = hostPool[other.id] {
            return UnifiedHostSnapshot(
                id: other.id,
                name: cleanName,
                fullName: other.name,
                platform: other.platform,
                version: resolvedVersion,
                isLocal: false,
                connectionState: slot.linkDropped ? "connecting" : other.connection.state,
                viaRelay: other.connection.viaRelay,
                allowsTerminal: other.connection.allowsTerminal,
                sessions: slot.sessions,
                projects: slot.projects,
                noProjectInfo: slot.noProjectInfo,
                agents: slot.agents,
                isLoaded: slot.isLoaded,
                error: slot.error ?? remoteHostErrors[other.id]
            )
        }
        return UnifiedHostSnapshot(
            id: other.id,
            name: cleanName,
            fullName: other.name,
            platform: other.platform,
            version: resolvedVersion,
            isLocal: false,
            connectionState: other.connection.state,
            viaRelay: other.connection.viaRelay,
            allowsTerminal: other.connection.allowsTerminal,
            sessions: [],
            projects: [],
            noProjectInfo: NoProjectInfo(),
            agents: [],
            isLoaded: false,
            error: remoteHostErrors[other.id]
        )
    }
}
