import Foundation

// MARK: - Last Turn Ending (src/shared/agent-host.ts `LastTurn`, `LastTurnLimit`)

/// How a session's last turn ended. `failed` and `limit` are turns that ended with an error, the
/// latter refused by a used-up plan limit window; the others are the agent's own stop reasons.
/// A summary carries none while a turn runs or before any ended, and older hosts send none.
public struct LastTurn: Codable, Sendable, Equatable {
    public enum Reason: Sendable, Equatable, Hashable {
        case endTurn
        case maxTokens
        case maxTurnRequests
        case refusal
        case cancelled
        case failed
        case limit
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "end_turn": self = .endTurn
            case "max_tokens": self = .maxTokens
            case "max_turn_requests": self = .maxTurnRequests
            case "refusal": self = .refusal
            case "cancelled": self = .cancelled
            case "failed": self = .failed
            case "limit": self = .limit
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .endTurn: return "end_turn"
            case .maxTokens: return "max_tokens"
            case .maxTurnRequests: return "max_turn_requests"
            case .refusal: return "refusal"
            case .cancelled: return "cancelled"
            case .failed: return "failed"
            case .limit: return "limit"
            case .unknown(let raw): return raw
            }
        }

        /// The turn ended with an error rather than a stop reason of the agent's.
        public var isError: Bool { self == .failed || self == .limit }
    }

    public let reason: Reason
    /// When it ended, in ms since the epoch.
    public let endedAt: Double
    /// The error's first line, for `failed` and `limit`.
    public let error: String?
    /// The window that stopped it, for `limit`.
    public let limit: LastTurnLimit?

    enum CodingKeys: String, CodingKey {
        case reason, endedAt, error, limit
    }

    public init(reason: Reason, endedAt: Double, error: String? = nil, limit: LastTurnLimit? = nil) {
        self.reason = reason
        self.endedAt = endedAt
        self.error = error
        self.limit = limit
    }

    // A malformed ending must not fail the summary, and with it a whole `sessions.list`, so every
    // field decodes leniently and an unreadable one reads as an unknown reason.
    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            self.init(reason: .unknown(""), endedAt: 0)
            return
        }
        let raw = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
        self.init(
            reason: Reason(rawValue: raw ?? ""),
            endedAt: ((try? c.decodeIfPresent(Double.self, forKey: .endedAt)) ?? nil) ?? 0,
            error: (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil,
            limit: (try? c.decodeIfPresent(LastTurnLimit.self, forKey: .limit)) ?? nil
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reason.rawValue, forKey: .reason)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(limit, forKey: .limit)
    }

    /// The error's first non-empty line, trimmed; nil without one.
    public var errorLine: String? {
        guard let error else { return nil }
        for line in error.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// The plan window that stopped a turn, as the session's summary names it.
public struct LastTurnLimit: Codable, Sendable, Equatable {
    /// Such as `five_hour` or `seven_day`.
    public let window: String
    /// The window's name, such as "5-hour".
    public let label: String
    /// The account as the agent names it, or the agent's name without one.
    public let account: String
    /// When the window resets, in ms since the epoch; nil when unknown.
    public let resetsAt: Double?

    public init(window: String, label: String, account: String, resetsAt: Double?) {
        self.window = window
        self.label = label
        self.account = account
        self.resetsAt = resetsAt
    }

    /// Whether the window still holds at `nowMs`: it has not reset, or its reset is unknown.
    public func holds(nowMs: Double) -> Bool {
        resetsAt.map { $0 > nowMs } ?? true
    }
}

// MARK: - Plan Windows Per Model & Extra Usage (src/shared/plan-limits.ts, session-groups.ts)

public extension PlanLimitInfo {
    /// Set while extra usage covers this used-up window: the plan refuses requests and extra
    /// usage lets them through.
    var isCoveredByExtraUsage: Bool { extraUsage == true }

    /// Used up and not reset yet at `nowMs`.
    func isReached(nowMs: Double) -> Bool {
        state == "reached" && (resetsAt.map { $0 > nowMs } ?? true)
    }
}

public enum PlanLimitScope {
    /// The windows that hold back the model `value` names among `choices`, as Sarto's
    /// `limitsForModel`: a per-model weekly window such as `seven_day_opus` counts only on a model
    /// that names it, a window naming none of the menu's models counts for all, and so does every
    /// window when the model is unknown. A group's window that lists its models counts only on
    /// them, unless no group lists the chosen model.
    public static func limits(
        _ limits: [PlanLimitInfo],
        choices: [ConfigChoice],
        model value: String?
    ) -> [PlanLimitInfo] {
        guard let value, let current = choices.first(where: { $0.value == value }) else { return limits }
        var known = Set<String>()
        for choice in choices {
            known.formUnion(words(choice.value, choice.name, choice.modelId))
        }
        let own = words(current.value, current.name, current.modelId, current.description)
        let names = { (limit: PlanLimitInfo) in limit.models ?? [] }
        let grouped = limits.contains { limit in names(limit).contains { has(own, $0) } }
        return limits.filter { limit in
            let models = names(limit)
            if !models.isEmpty { return !grouped || models.contains { has(own, $0) } }
            let prefix = "seven_day_"
            guard limit.window.hasPrefix(prefix), limit.window.count > prefix.count else { return true }
            let scoped = limit.window.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false).map(String.init)
            if scoped.isEmpty || !scoped.allSatisfy({ known.contains($0) }) { return true }
            return scoped.allSatisfy { own.contains($0) }
        }
    }

    /// `limits(_:choices:model:)` for a session: the agent's model option names the choices and
    /// the session's summary the model it chose.
    public static func limits(
        _ limits: [PlanLimitInfo],
        agentConfig: [ConfigOption]?,
        model value: String?
    ) -> [PlanLimitInfo] {
        let option = agentConfig?.first { $0.category == "model" }
        return self.limits(limits, choices: option?.choices ?? [], model: value)
    }

    /// The used-up window that holds a session back, unless extra usage covers it, as Sarto's
    /// `reachedLimit`; nil when none does.
    public static func heldBack(_ limits: [PlanLimitInfo], nowMs: Double) -> PlanLimitInfo? {
        limits.first { $0.isReached(nowMs: nowMs) && !$0.isCoveredByExtraUsage }
    }

    /// The used-up window extra usage lets requests through; nil when none.
    public static func coveredByExtraUsage(_ limits: [PlanLimitInfo], nowMs: Double) -> PlanLimitInfo? {
        limits.first { $0.isReached(nowMs: nowMs) && $0.isCoveredByExtraUsage }
    }

    private static func words(_ texts: String?...) -> Set<String> {
        var out = Set<String>()
        for text in texts {
            guard let text else { continue }
            var word = ""
            for scalar in text.lowercased().unicodeScalars {
                if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                    word.unicodeScalars.append(scalar)
                } else if !word.isEmpty {
                    out.insert(word)
                    word = ""
                }
            }
            if !word.isEmpty { out.insert(word) }
        }
        return out
    }

    private static func has(_ own: Set<String>, _ name: String) -> Bool {
        words(name).allSatisfy { own.contains($0) }
    }
}
