import Foundation

// The usage overview (`usage.overview`, `UsageOverview` in src/shared/usage.ts): everything the
// Mac app's usage views show, computed by the agent host, so the app only displays it. Every type
// decodes leniently: a field an older host leaves out takes its empty value, an element that
// cannot be read is dropped, and a kind a newer host adds reads as the nearest known one.

/// Which numbers an overview counts: this computer's logs, Sarto's own record, or all synced Macs.
public enum UsageOverviewScope: String, Sendable, Equatable, CaseIterable {
    case computer
    case sarto
    case all
}

public struct UsageOverviewInfo: Decodable, Sendable, Equatable {
    /// Epoch milliseconds.
    public let generatedAt: Double
    public let scope: String
    /// Agents with usage, a quota or a reading under the scope, in the agents' order.
    public let agents: [UsageOverviewAgentInfo]
    /// For each range of the last 1, 7, 30 and 90 days, its models by cost, then tokens.
    public let models: [UsageModelRangeInfo]
    /// The last 24 hours by the hour, the current hour last.
    public let hourly: UsageSeriesInfo
    /// The last 90 local days, today last.
    public let daily: UsageSeriesInfo
    /// This computer first, then the others by name; empty while the sync is off.
    public let devices: [UsageDeviceInfo]
    public let unpricedModels: [String]
    public let familyPriced: [UsageFamilyPriceInfo]
    public let pricesAsOf: String

    private enum CodingKeys: String, CodingKey {
        case generatedAt, scope, agents, models, hourly, daily, devices, unpricedModels, familyPriced, pricesAsOf
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = c.usageValue(.generatedAt, or: 0.0)
        scope = c.usageValue(.scope, or: "")
        agents = c.usageList(.agents)
        models = c.usageList(.models)
        hourly = c.usageValue(.hourly, or: .empty)
        daily = c.usageValue(.daily, or: .empty)
        devices = c.usageList(.devices)
        unpricedModels = c.usageList(.unpricedModels)
        familyPriced = c.usageList(.familyPriced)
        pricesAsOf = c.usageValue(.pricesAsOf, or: "")
    }

    /// The ranked models of the last `days` days; empty for a range the host does not give.
    public func models(days: Int) -> [UsageOverviewModelInfo] {
        models.first { $0.days == days }?.models ?? []
    }
}

/// One agent's line of the overview.
public struct UsageOverviewAgentInfo: Decodable, Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public let agentId: String
    /// Its logs or record are on this computer, or another computer shares its usage or quota.
    public let available: Bool
    /// Signed out on this computer, so its quota is not read here.
    public let signedOut: Bool
    /// Today, in the host's time zone, under the overview's scope.
    public let today: UsageTodayInfo
    /// The newest request counted under the scope, across computers in the `all` scope.
    public let activity: UsageActivityInfo?
    /// The newest request on this computer.
    public let localActivity: UsageActivityInfo?
    /// This computer's account, or in the `all` scope the account read most recently.
    public let quota: UsageQuotaInfo?
    /// In the `all` scope, the other accounts other computers use, freshest first.
    public let otherAccounts: [UsageQuotaInfo]
    /// Its name and harness as the host lists them; nil for an agent the host does not know.
    public let name: String?
    public let harnessId: String?
    /// Whether the usage views show its quota: installed, used within 30 days, and measured.
    /// Nil from an older host, which does not decide.
    public let eligible: Bool?

    private enum CodingKeys: String, CodingKey {
        case agentId, available, signedOut, today, activity, localActivity, quota, otherAccounts
        case name, harnessId, eligible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(String.self, forKey: .agentId)
        available = c.usageValue(.available, or: true)
        signedOut = c.usageValue(.signedOut, or: false)
        today = c.usageValue(.today, or: .zero)
        activity = c.usageOptional(.activity)
        localActivity = c.usageOptional(.localActivity)
        quota = c.usageOptional(.quota)
        otherAccounts = c.usageList(.otherAccounts)
        name = c.usageOptional(.name)
        harnessId = c.usageOptional(.harnessId)
        eligible = c.usageOptional(.eligible)
    }
}

public struct UsageTodayInfo: Decodable, Sendable, Equatable {
    public let tokens: Double
    /// Dollars over the priced models; 0 when none is priced.
    public let cost: Double
    public let requests: Int
    /// Tokens of models with no price, which `cost` leaves out.
    public let unpricedTokens: Double

    static let zero = UsageTodayInfo(tokens: 0, cost: 0, requests: 0, unpricedTokens: 0)

    private init(tokens: Double, cost: Double, requests: Int, unpricedTokens: Double) {
        self.tokens = tokens
        self.cost = cost
        self.requests = requests
        self.unpricedTokens = unpricedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, cost, requests, unpricedTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = c.usageValue(.tokens, or: 0.0)
        cost = c.usageValue(.cost, or: 0.0)
        requests = c.usageCount(.requests)
        unpricedTokens = c.usageValue(.unpricedTokens, or: 0.0)
    }
}

public struct UsageActivityInfo: Decodable, Sendable, Equatable {
    /// Epoch milliseconds.
    public let at: Double
    /// The model, normalized; nil when no recent request names one.
    public let model: String?

    private enum CodingKeys: String, CodingKey {
        case at, model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at)
        model = c.usageOptional(.model)
    }
}

/// One account's quota, as the computer that read it last saw it.
public struct UsageQuotaInfo: Decodable, Sendable, Equatable {
    /// The account's fingerprint; nil when the agent names none.
    public let account: String?
    public let plan: String?
    /// Epoch milliseconds.
    public let observedAt: Double?
    /// The computer the reading came from; nil for this computer's own.
    public let device: UsageQuotaDeviceInfo?
    /// Session windows first, then weekly, other and scoped (model-specific) ones.
    public let windows: [UsageQuotaWindowInfo]
    /// The id of the plan-wide window with the least left, which the tube shows.
    public let primary: String?
    /// The id of another plan-wide window, the tube's second line.
    public let secondary: String?

    private enum CodingKeys: String, CodingKey {
        case account, plan, observedAt, device, windows, primary, secondary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        account = c.usageOptional(.account)
        plan = c.usageOptional(.plan)
        observedAt = c.usageOptional(.observedAt)
        device = c.usageOptional(.device)
        windows = c.usageList(.windows)
        primary = c.usageOptional(.primary)
        secondary = c.usageOptional(.secondary)
    }

    public var primaryWindow: UsageQuotaWindowInfo? {
        primary.flatMap { id in windows.first { $0.id == id } }
    }

    public var secondaryWindow: UsageQuotaWindowInfo? {
        secondary.flatMap { id in windows.first { $0.id == id } }
    }
}

public struct UsageQuotaDeviceInfo: Decodable, Sendable, Equatable {
    public let id: String
    public let name: String
}

/// What a quota window covers; a kind a newer host adds reads as `other`.
public enum UsageQuotaWindowKind: String, Decodable, Sendable, Equatable {
    case session
    case weekly
    case scoped
    case other

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = UsageQuotaWindowKind(rawValue: raw) ?? .other
    }
}

/// One quota window, ready to show: past its reset time it shows as reset, at 0% used.
public struct UsageQuotaWindowInfo: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: UsageQuotaWindowKind
    /// The models a scoped window counts, as the agent names them; nil for the plan.
    public let scope: String?
    /// Its name in the host's language: "5-hour", "Weekly", "Weekly - Fable".
    public let label: String
    public let minutes: Double?
    /// 0 to 100; 0 once reset.
    public let usedPercent: Double
    /// 0 to 1, what the tube fills to.
    public let remaining: Double
    /// Epoch milliseconds; nil once reset, until the agent measures the new window.
    public let resetsAt: Double?
    public let reset: Bool
    public let observedAt: Double?
    public let forecast: UsageWindowForecastInfo
    /// What the share is of, when the agent tells an amount: Cursor's $27.06 of $400.
    public let amount: UsageQuotaAmountInfo?

    private enum CodingKeys: String, CodingKey {
        case id, kind, scope, label, minutes, usedPercent, remaining, resetsAt, reset, observedAt, forecast, amount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.usageValue(.kind, or: .other)
        scope = c.usageOptional(.scope)
        label = c.usageValue(.label, or: id)
        minutes = c.usageOptional(.minutes)
        usedPercent = c.usageValue(.usedPercent, or: 0.0)
        remaining = c.usageOptional(.remaining) ?? max(0, min(1, 1 - usedPercent / 100))
        resetsAt = c.usageOptional(.resetsAt)
        reset = c.usageValue(.reset, or: false)
        observedAt = c.usageOptional(.observedAt)
        forecast = c.usageValue(.forecast, or: UsageWindowForecastInfo(status: reset ? .reset : .insufficient))
        amount = c.usageOptional(.amount)
    }
}

public struct UsageQuotaAmountInfo: Decodable, Sendable, Equatable {
    public let used: Double
    public let total: Double
    /// `USD`, `credits`, `requests`.
    public let unit: String
}

/// A window's burn-rate forecast, from the usage of the computers on the window's account.
public struct UsageWindowForecastInfo: Decodable, Sendable, Equatable {
    public let status: UsageForecastStatus
    /// Tokens left in the window, by the account's tokens per 1% used; nil when too little is known.
    public let estimatedRemainingTokens: Double?
    /// The account's tokens counted in the window so far.
    public let windowTokens: Double

    init(status: UsageForecastStatus) {
        self.status = status
        self.estimatedRemainingTokens = nil
        self.windowTokens = 0
    }

    private enum CodingKeys: String, CodingKey {
        case status, estimatedRemainingTokens, windowTokens
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.usageValue(.status, or: .insufficient)
        estimatedRemainingTokens = c.usageOptional(.estimatedRemainingTokens)
        windowTokens = c.usageValue(.windowTokens, or: 0.0)
    }
}

/// A forecast's verdict on a window (`ForecastStatus`); a kind a newer host adds reads as
/// `insufficient`.
public enum UsageForecastStatus: Decodable, Sendable, Equatable {
    /// Runs out `seconds` from now, before it resets.
    case exhausts(seconds: Double)
    /// Lasts until it resets, with `remainingAtReset` (0 to 1) of it left then.
    case survives(remainingAtReset: Double)
    /// So little is used that it holds until it resets.
    case steady
    /// Its reset time has passed; the agent has not measured the new window yet.
    case reset
    /// Not enough is known, such as when it resets.
    case insufficient

    private enum CodingKeys: String, CodingKey {
        case kind, seconds, remainingAtReset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch c.usageValue(.kind, or: "") {
        case "exhausts":
            if let seconds: Double = c.usageOptional(.seconds) {
                self = .exhausts(seconds: seconds)
            } else {
                self = .insufficient
            }
        case "survives":
            if let left: Double = c.usageOptional(.remainingAtReset) {
                self = .survives(remainingAtReset: left)
            } else {
                self = .insufficient
            }
        case "steady": self = .steady
        case "reset": self = .reset
        default: self = .insufficient
        }
    }
}

public struct UsageModelRangeInfo: Decodable, Sendable, Equatable {
    public let days: Int
    public let models: [UsageOverviewModelInfo]

    private enum CodingKeys: String, CodingKey {
        case days, models
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.usageCount(.days)
        models = c.usageList(.models)
    }
}

/// A model's figures over a range.
public struct UsageOverviewModelInfo: Decodable, Sendable, Equatable {
    public let agentId: String
    public let model: String
    public let tokens: Double
    /// Dollars; 0 when unpriced.
    public let cost: Double
    public let requests: Int
    public let price: UsagePriceMatchInfo

    private enum CodingKeys: String, CodingKey {
        case agentId, model, tokens, cost, requests, price
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(String.self, forKey: .agentId)
        model = try c.decode(String.self, forKey: .model)
        tokens = c.usageValue(.tokens, or: 0.0)
        cost = c.usageValue(.cost, or: 0.0)
        requests = c.usageCount(.requests)
        price = c.usageValue(.price, or: .unpriced)
    }
}

/// How a model is priced: under its own name, at a sibling version's price (`family`), or not.
public struct UsagePriceMatchInfo: Decodable, Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case exact
        case family
        case unpriced
    }

    public let kind: Kind
    /// The name the price is listed under; nil when unpriced.
    public let model: String?
    /// `override`, `server`, `bundled` or `registry`; nil when unpriced.
    public let origin: String?

    static let unpriced = UsagePriceMatchInfo(kind: .unpriced, model: nil, origin: nil)

    private init(kind: Kind, model: String?, origin: String?) {
        self.kind = kind
        self.model = model
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case kind, model, origin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = Kind(rawValue: c.usageValue(.kind, or: "")) ?? .unpriced
        model = c.usageOptional(.model)
        origin = c.usageOptional(.origin)
    }
}

/// Sums per period: `starts` oldest first, the current period last; each agent's arrays alike.
public struct UsageSeriesInfo: Decodable, Sendable, Equatable {
    /// Epoch milliseconds of each period's start.
    public let starts: [Double]
    public let agents: [UsageSeriesAgentInfo]

    static let empty = UsageSeriesInfo(starts: [], agents: [])

    private init(starts: [Double], agents: [UsageSeriesAgentInfo]) {
        self.starts = starts
        self.agents = agents
    }

    private enum CodingKeys: String, CodingKey {
        case starts, agents
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starts = c.usageList(.starts)
        agents = c.usageList(.agents)
    }
}

public struct UsageSeriesAgentInfo: Decodable, Sendable, Equatable {
    public let agentId: String
    public let tokens: [Double]
    public let cost: [Double]

    private enum CodingKeys: String, CodingKey {
        case agentId, tokens, cost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(String.self, forKey: .agentId)
        tokens = c.usageValue(.tokens, or: [])
        cost = c.usageValue(.cost, or: [])
    }
}

/// A computer of the sync.
public struct UsageDeviceInfo: Decodable, Sendable, Equatable, Identifiable {
    /// The sync's id for the computer, which `sync.removeUsage` takes.
    public let id: String
    public let name: String
    /// When it last shared its usage, epoch milliseconds.
    public let updatedAt: Double?
    public let thisComputer: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, updatedAt, thisComputer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.usageValue(.name, or: "Mac")
        updatedAt = c.usageOptional(.updatedAt)
        thisComputer = c.usageValue(.thisComputer, or: false)
    }
}

/// A model priced from a sibling version, and that sibling.
public struct UsageFamilyPriceInfo: Decodable, Sendable, Equatable {
    public let model: String
    public let standIn: String
}

/// Decodes one element of an array, keeping nil instead of failing the whole array.
private struct LossyUsageElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private extension KeyedDecodingContainer {
    func usageValue<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func usageOptional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }

    func usageList<T: Decodable>(_ key: Key) -> [T] {
        let read = (try? decodeIfPresent([LossyUsageElement<T>].self, forKey: key)) ?? nil
        return read?.compactMap(\.value) ?? []
    }

    /// A count the host sends as a JSON number, whole or not.
    func usageCount(_ key: Key) -> Int {
        let value = usageValue(key, or: 0.0)
        return value.isFinite ? Int(value.rounded()) : 0
    }
}
