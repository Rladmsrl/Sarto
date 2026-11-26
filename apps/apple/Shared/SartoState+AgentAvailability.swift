import Foundation
import SartoProtocol
import Observation
import PrismDesign

/// The window a request to install an agent or confirm its update is shown in.
enum AgentActionSurface: Sendable, Equatable {
    case workbench
    case settings
}

/// A step that asks before it runs: the install sheet, or an update command to confirm.
struct AgentAvailabilityRequest: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case install
        case confirmUpdate(command: String)
    }

    let id = UUID()
    let agentId: String
    let kind: Kind
    let surface: AgentActionSurface
}

/// Agent availability's own state: the request a surface shows, the install errors the host could
/// not put in a status, and the entries worked out once per change of what they depend on.
@MainActor
@Observable
final class AgentAvailabilityModel {
    var request: AgentAvailabilityRequest?
    /// Why an install failed before its host could say it in the agent's status, by agent.
    var installErrors: [String: String] = [:]

    struct Key: Equatable {
        let agents: [AgentStatusInfo]
        let options: [String: AgentOptionsInfo]
        let picks: [String: [String: JSONValue]]
        let preparedAgentID: String?
        let preparedConfig: [ConfigOption]?
        let minute: Int
        let language: PrismLanguage
    }

    struct Snapshot {
        var entries: [String: AgentAvailabilityEntry] = [:]
        var noAgent: NoAgentReason?
    }

    // Arrays and dictionaries compare by storage identity first, so an unchanged key is O(1).
    @ObservationIgnored private var key: Key?
    @ObservationIgnored private var cached = Snapshot()

    func snapshot(for key: Key, compute: () -> Snapshot) -> Snapshot {
        if key == self.key { return cached }
        let next = compute()
        self.key = key
        cached = next
        return next
    }
}

extension SartoState {
    /// Each agent's availability by id: what it needs, why it cannot run, its menu tag and fix.
    /// Worked out again only when the agents, their start options, the minute or the language
    /// change, never on a plain body pass.
    var agentAvailability: [String: AgentAvailabilityEntry] {
        agentAvailabilitySnapshot.entries
    }

    /// While no agent New session could start can start, what stops them.
    var noAgentCanStart: NoAgentReason? {
        agentAvailabilitySnapshot.noAgent
    }

    private var agentAvailabilitySnapshot: AgentAvailabilityModel.Snapshot {
        let prepared = preparedSession
        let key = AgentAvailabilityModel.Key(
            agents: agents,
            options: agentOptionsById,
            picks: newSessionOptionPicks,
            preparedAgentID: prepared?.agentId,
            preparedConfig: prepared?.prepared?.config,
            minute: Int(Date().timeIntervalSince1970 / 60),
            language: language
        )
        return agentAvailabilityModel.snapshot(for: key) {
            let entries = computeAgentAvailability()
            let candidates = selectableAgents
            return AgentAvailabilityModel.Snapshot(
                entries: entries,
                noAgent: candidates.isEmpty ? nil : AgentAvailability.noAgentCanStart(candidates, entries: entries)
            )
        }
    }

    private func computeAgentAvailability() -> [String: AgentAvailabilityEntry] {
        let l10n = self.l10n
        let nowMs = Date().timeIntervalSince1970 * 1000
        var out: [String: AgentAvailabilityEntry] = [:]
        for status in agents {
            let need = AgentAvailability.need(status)
            let problem = AgentAvailability.problem(status, l10n: l10n)
            let fix = AgentAvailability.fixAction(status, need: need, problem: problem)
            out[status.id] = AgentAvailabilityEntry(
                need: need,
                canStart: AgentAvailability.canStart(status, need: need),
                problem: problem,
                tag: AgentAvailability.tag(
                    status,
                    need: need,
                    problem: problem,
                    model: startModelOption(for: status.id),
                    nowMs: nowMs,
                    l10n: l10n
                ),
                fix: fix,
                fixTitle: fix?.title(l10n)
            )
        }
        return out
    }

    /// The model a new session with the agent starts on, as its options say.
    private func startModelOption(for agentId: String) -> ConfigOption? {
        guard agentOptionsById[agentId] != nil || preparedSession?.agentId == agentId else { return nil }
        let prepared = preparedSession?.agentId == agentId ? preparedSession?.prepared?.config : nil
        return configOptions(
            forAgent: agentId,
            overrides: newSessionOptionPicks[agentId] ?? [:],
            includeStartMode: true,
            preparedOverride: prepared
        )
        .first { $0.category == "model" && $0.type == "select" }
    }

    // MARK: Requests a surface shows

    func requestAgentInstall(_ agentId: String, from surface: AgentActionSurface) {
        agentAvailabilityModel.installErrors[agentId] = nil
        agentAvailabilityModel.request = AgentAvailabilityRequest(agentId: agentId, kind: .install, surface: surface)
    }

    func requestAgentUpdate(_ agentId: String, command: String, from surface: AgentActionSurface) {
        agentAvailabilityModel.request = AgentAvailabilityRequest(
            agentId: agentId,
            kind: .confirmUpdate(command: command),
            surface: surface
        )
    }

    func dismissAgentRequest(_ id: UUID) {
        if agentAvailabilityModel.request?.id == id {
            agentAvailabilityModel.request = nil
        }
    }

    // MARK: Host calls

    /// What each way of installing the agent's harness brings. An older host without
    /// `agents.installOffer` gets the offer its status implies, when it implies one.
    func installOffer(for agentId: String) async throws -> InstallOffer {
        guard let host = activeHostSession else {
            throw HostRPCError.disconnected(l10n.tr("error.daemonNotConnected"))
        }
        do {
            return try await host.agentInstallOffer(agentId: agentId)
        } catch {
            if let status = agents.first(where: { $0.id == agentId }) {
                let fallback = InstallOffer(fallbackFor: status)
                if !fallback.routes.isEmpty { return fallback }
            }
            throw error
        }
    }

    /// Installs by the route picked, or Sarto's own copy when nil, and waits for the install to
    /// finish; its progress arrives as agent statuses meanwhile. A failure the status does not
    /// carry is kept in `installErrors`.
    func installAgent(_ agentId: String, route: InstallRoute?) async -> Bool {
        guard let host = activeHostSession else { return false }
        agentAvailabilityModel.installErrors[agentId] = nil
        do {
            try await host.installAgent(agentId: agentId, method: route?.method)
            await refreshAgentStatus(agentId)
            return true
        } catch {
            await refreshAgentStatus(agentId)
            if agents.first(where: { $0.id == agentId })?.task?.state != "failed" {
                agentAvailabilityModel.installErrors[agentId] = error.localizedDescription
            }
            return false
        }
    }

    /// Updates the user's own program with the command its install uses.
    func updateAgentProgram(_ agentId: String) async throws {
        guard let host = activeHostSession else { return }
        try await host.updateAgentCli(agentId: agentId)
        await refreshAgentStatus(agentId)
    }

    func retryAgentStart(_ agentId: String) async throws {
        guard let host = activeHostSession else { return }
        try await host.retryAgent(agentId: agentId)
        await refreshAgentStatus(agentId)
    }

    /// Detects the agent's harness again and takes its new status.
    func refreshAgentStatus(_ agentId: String) async {
        guard let host = activeHostSession,
              let checked = try? await host.checkAgents(agentId: agentId)
        else { return }
        mergeAgentStatuses(checked)
    }

    func mergeAgentStatuses(_ statuses: [AgentStatusInfo]) {
        guard !statuses.isEmpty else { return }
        var next = agents
        for status in statuses {
            if let index = next.firstIndex(where: { $0.id == status.id }) {
                if next[index] != status { next[index] = status }
            } else {
                next.append(status)
            }
        }
        if next != agents { agents = next }
    }
}
