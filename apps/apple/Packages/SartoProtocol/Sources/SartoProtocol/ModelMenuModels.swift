import Foundation

/// The limits of the models a host keeps for each agent's model menu (`MAX_PINNED_MODELS` and
/// `MAX_RECENT_MODELS` in `src/shared/agent-host.ts`).
public enum ModelMenuLimits {
    /// How many models an agent's model menu may have pinned; the host refuses a fifth.
    public static let maxPinnedModels = 4
    /// How many of an agent's recently used models the host keeps.
    public static let maxRecentModels = 8
}

/// The params of `agents.pinModel`: pins `model` to the top of the agent's model menu, or unpins it.
public struct AgentPinModelParams: Codable, Sendable, Equatable {
    public let agentId: String
    public let model: String
    public let pinned: Bool

    public init(agentId: String, model: String, pinned: Bool) {
        self.agentId = agentId
        self.model = model
        self.pinned = pinned
    }

    public var jsonValue: JSONValue {
        .object([
            "agentId": .string(agentId),
            "model": .string(model),
            "pinned": .bool(pinned),
        ])
    }
}

/// The params of `agents.setPinnedModels`: sets the agent's pinned models in order, or clears them.
public struct AgentSetPinnedModelsParams: Codable, Sendable, Equatable {
    public let agentId: String
    public let models: [String]

    public init(agentId: String, models: [String]) {
        self.agentId = agentId
        self.models = models
    }

    public var jsonValue: JSONValue {
        .object([
            "agentId": .string(agentId),
            "models": .array(models.map(JSONValue.string)),
        ])
    }
}

/// What the host keeps of an agent's models: the ones pinned and the ones last used.
public struct KeptModels: Sendable, Equatable {
    public var pinned: [String]
    public var recent: [String]

    public init(pinned: [String] = [], recent: [String] = []) {
        self.pinned = pinned
        self.recent = recent
    }
}

/// Why a pin cannot be applied locally before the host is asked.
public enum ModelPinRefusal: Error, Sendable, Equatable {
    /// The agent already has `ModelMenuLimits.maxPinnedModels` pins.
    case full(limit: Int)
}

public extension AgentOptionsInfo {
    var keptModels: KeptModels {
        KeptModels(pinned: pinned ?? [], recent: recent ?? [])
    }

    func isPinned(_ model: String) -> Bool {
        pinned?.contains(model) == true
    }

    /// The pinned list after pinning `model` (after the ones pinned before) or unpinning it, the
    /// way the host's `AgentOptionsStore.pin` changes it. Nil stands for no pins at all.
    func pinnedModels(setting model: String, pinned isPinned: Bool) throws(ModelPinRefusal) -> [String]? {
        let before = pinned ?? []
        let has = before.contains(model)
        if isPinned && !has && before.count >= ModelMenuLimits.maxPinnedModels {
            throw .full(limit: ModelMenuLimits.maxPinnedModels)
        }
        let next = isPinned ? (has ? before : before + [model]) : before.filter { $0 != model }
        return next.isEmpty ? nil : next
    }

    /// The same options with `pinned` replaced.
    func replacingPinned(_ pinned: [String]?) -> AgentOptionsInfo {
        AgentOptionsInfo(
            agentId: agentId,
            config: config,
            levels: levels,
            remembered: remembered,
            defaults: defaults,
            observedAt: observedAt,
            provisional: provisional,
            startMode: startMode,
            pinned: pinned,
            recent: recent
        )
    }

    /// A kept list of model values as a host may send it: strings only, each once, empty as nil.
    internal static func modelList(_ values: [JSONValue]?) -> [String]? {
        guard let values else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for value in values {
            guard let model = value.stringValue, !model.isEmpty, seen.insert(model).inserted else { continue }
            out.append(model)
        }
        return out.isEmpty ? nil : out
    }
}

public extension SartoHostSession {
    /// Pins a model to the top of the agent's model menu, or unpins it (`agents.pinModel`). The
    /// host answers with an `agent.options` event carrying the new list; older hosts lack the method.
    func pinModel(agentId: String, model: String, pinned: Bool) async throws {
        let params = AgentPinModelParams(agentId: agentId, model: model, pinned: pinned)
        _ = try await request("agents.pinModel", params: params.jsonValue)
    }

    /// Sets the agent's pinned models in order, at most `ModelMenuLimits.maxPinnedModels`, or clears
    /// them with an empty list (`agents.setPinnedModels`). The host answers with an `agent.options`
    /// event carrying the new list; older hosts lack the method.
    func setPinnedModels(agentId: String, models: [String]) async throws {
        let params = AgentSetPinnedModelsParams(agentId: agentId, models: models)
        _ = try await request("agents.setPinnedModels", params: params.jsonValue)
    }
}
