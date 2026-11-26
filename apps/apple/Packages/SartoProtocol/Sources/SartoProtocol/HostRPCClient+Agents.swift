import Foundation

// Installing a harness (src/shared/agent-host.ts `agents.installOffer`, `agents.install`).

public extension SartoHostSession {
    /// What each way of installing the harness brings, before anything runs. Hosts older than
    /// `agents.installOffer` reject the method; `InstallOffer(fallbackFor:)` stands in for them.
    func agentInstallOffer(agentId: String) async throws -> InstallOffer {
        try await request(
            "agents.installOffer",
            params: Self.installOfferParams(agentId: agentId),
            as: InstallOffer.self
        )
    }

    /// Installs the harness by one of its methods, or Sarto's own copy of its package when
    /// `method` is nil. It returns once the install task started; its progress arrives as
    /// `agent.status` events.
    func installAgent(agentId: String, method: String? = nil) async throws {
        _ = try await request("agents.install", params: Self.installParams(agentId: agentId, method: method))
    }

    /// Stops the install or update the host runs for the agent.
    func cancelAgentTask(agentId: String) async throws {
        _ = try await request("agents.cancelTask", params: .object(["agentId": .string(agentId)]))
    }

    static func installOfferParams(agentId: String) -> JSONValue {
        .object(["agentId": .string(agentId)])
    }

    /// `method` is left out for Sarto's copy, since the host's validator rejects anything but a
    /// known method id.
    static func installParams(agentId: String, method: String?) -> JSONValue {
        var params: [String: JSONValue] = ["agentId": .string(agentId)]
        if let method, method != InstallRoute.copyID {
            params["method"] = .string(method)
        }
        return .object(params)
    }
}
