import Combine
import Foundation
import MenuBarKit
import PrismDesign
import SartoProtocol
import SwiftUI

// Monochrome provider marks (drawn as 24x24 template SVGs).
enum ProviderMarkPaths {
    static let anthropic = "M13.827 3.52h3.603L24 20h-3.603l-6.57-16.48zm-7.258 0h3.767L16.906 20h-3.674l-1.343-3.461H5.017l-1.344 3.461H0L6.57 3.52zm4.132 9.876L8.453 7.247 6.205 13.396z"
    static let openai = "M22.282 9.821a5.985 5.985 0 0 0-.516-4.91 6.046 6.046 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a5.985 5.985 0 0 0-3.998 2.9 6.046 6.046 0 0 0 .743 7.097 5.98 5.98 0 0 0 .51 4.911 6.051 6.051 0 0 0 6.515 2.9A5.985 5.985 0 0 0 13.26 24a6.056 6.056 0 0 0 5.772-4.206 5.99 5.99 0 0 0 3.997-2.9 6.056 6.056 0 0 0-.747-7.073zM13.26 22.43a4.476 4.476 0 0 1-2.876-1.04l.142-.08 4.778-2.758a.795.795 0 0 0 .393-.681v-6.737l2.02 1.168a.071.071 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.495 4.494zM3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085 4.783 2.759a.771.771 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646zM2.34 7.896a4.485 4.485 0 0 1 2.366-1.973V11.6a.766.766 0 0 0 .388.676l5.815 3.355-2.02 1.168a.076.076 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855l-5.833-3.387L15.119 7.2a.076.076 0 0 1 .071 0l4.83 2.787a4.49 4.49 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.674zm2.01-3.026l-.142-.085-4.774-2.782a.776.776 0 0 0-.785 0L9.409 9.23V6.897a.066.066 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135l-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.795.795 0 0 0-.393.681zm1.097-2.365l2.602-1.5 2.607 1.5v2.999l-2.607 1.5-2.602-1.5z"
    static let gemini = "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 01-3.81-2.58 12.3 12.3 0 01-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 01-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81"
}

enum UsageLogo {
    static func filled(_ path: String) -> String {
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"24\" height=\"24\" viewBox=\"0 0 24 24\"><path fill=\"#000\" d=\"\(path)\"/></svg>"
    }
}

/// The usage model's own words, in the language Sarto shows. A change of language reaches them at
/// the next refresh.
enum UsageText {
    static var l10n: PrismL10n { PrismL10n(language: PrismLanguage.loadSaved()) }
}

enum UsageCountdown {
    static func countdown(to date: Date?, now: Date = Date(), l10n: PrismL10n) -> String {
        guard let date else { return "—" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 60 * 24 { return l10n.tr("usage.countdown.daysHours", minutes / 1440, minutes % 1440 / 60) }
        if minutes >= 60 { return l10n.tr("usage.countdown.hoursMinutes", minutes / 60, minutes % 60) }
        return l10n.tr("usage.countdown.minutes", minutes)
    }

    static func shortCountdown(to date: Date?, now: Date = Date(), l10n: PrismL10n) -> String {
        guard let date else { return "—" }
        let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
        if minutes >= 1440 { return l10n.tr("usage.countdown.shortDaysHours", minutes / 1440, minutes % 1440 / 60) }
        if minutes >= 60 { return "\(minutes / 60)h\(String(format: "%02d", minutes % 60))" }
        return "\(minutes)m"
    }
}

enum UsageAgo {
    static func text(_ date: Date?, now: Date = Date(), l10n: PrismL10n) -> String {
        guard let date else { return "—" }
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return l10n.tr("usage.ago.justNow") }
        if minutes < 60 { return l10n.tr("usage.ago.minutes", minutes) }
        if minutes < 1440 { return l10n.tr("usage.ago.hours", minutes / 60) }
        return l10n.tr("usage.ago.days", minutes / 1440)
    }
}

enum ProviderKind: Sendable {
    case quota
    case balance
    case payg
}

/// A window's burn-rate forecast, as the daemon makes it.
struct WindowForecast: Equatable, Sendable {
    typealias Status = UsageForecastStatus

    let status: Status
    /// Tokens left in the window, by the account's tokens per 1% used; nil when too little is known.
    let estimatedRemainingTokens: Double?
    /// The account's tokens counted in the window so far.
    let windowTokens: Double
}

/// One plan quota window, as the daemon gives it.
struct QuotaWindow: Equatable, Sendable {
    enum Kind: Sendable, Equatable { case session, weekly, scoped, other }

    let id: String
    let kind: Kind
    /// The models a scoped window counts, as the agent names them ("Fable"); nil for the plan.
    let scope: String?
    /// Its name in the daemon's language.
    let label: String
    let minutes: Double?
    /// 0...1
    let remaining: Double
    let resetsAt: Date?
    /// Its reset time has passed and the agent has not measured the new window yet.
    let reset: Bool
    let forecast: WindowForecast
    /// What the share is of, when the agent tells an amount: Cursor's $27.06 of $400.
    var amount: UsageQuotaAmountInfo? = nil

    var isFiveHour: Bool { minutes == 300 || (minutes == nil && kind == .session) }

    /// The window as it stands at `now`: past its reset time it shows as reset until the daemon
    /// reads the new one, instead of the old number as if it were current.
    func current(at now: Date) -> QuotaWindow {
        guard !reset, let resetsAt, resetsAt <= now else { return self }
        return QuotaWindow(
            id: id, kind: kind, scope: scope, label: label, minutes: minutes, remaining: 1,
            resetsAt: nil, reset: true,
            forecast: WindowForecast(status: .reset, estimatedRemainingTokens: nil, windowTokens: 0)
        )
    }
}

enum PriceMatch: Equatable, Sendable {
    /// The model's own list price.
    case exact(String)
    /// No price for this version; a sibling of the same family stands in.
    case family(String)
    case unpriced
}

/// The account a quota tube shows, as the daemon names it: the agent it was read for and the
/// account's fingerprint.
struct QuotaAccountRef: Equatable {
    let agentId: String
    let account: String
}

struct ProviderUsage: Identifiable, Equatable {
    let id: String
    let name: String
    let plan: String
    let color: Color
    let logo: String
    let kind: ProviderKind
    var remaining: Double?
    var weeklyRemaining: Double?
    var balance: Double?
    var topUp: Double?
    var resetsAt: Date?
    var todaySpend: Double
    var todayTokens: Double
    var requests: Int
    var windowLabel = UsageText.l10n.tr("usage.window.fiveHourWindow")
    var weeklyLabel = UsageText.l10n.tr("usage.window.thisWeek")
    var scopedWindows: [QuotaWindow] = []
    var allWindows: [QuotaWindow] = []
    var quotaObservedAt: Date?
    var quotaDevice: String?
    /// The account of the quota shown; nil when the agent names none.
    var quotaAccount: QuotaAccountRef?
    var note: String?
    var unpricedTokens = 0.0
    var lastActivity: Date?
    var localLastActivity: Date?
    var lastModel: String?
    var localLastModel: String?
    var available = true
    /// Whether its quota shows: installed, used within 30 days and measured, as the daemon decides.
    /// The tubes, the island's quota and the low-quota alerts take only these.
    var eligible = false
    var windowReset = false
    var warnAt = 0.3
    /// The same tool's other accounts that other Macs use, each its own quota tube; their usage
    /// stays counted in this provider, as the daemon counts usage by agent, not by account.
    var otherAccounts: [ProviderUsage] = []

    @MainActor var spendText: String {
        spendText(privacy: false)
    }

    @MainActor func spendText(privacy: Bool) -> String {
        if privacy { return "\(Fmt.symbol)••••" }
        if todaySpend < 0.005 && todayTokens > 0 { return "\(Fmt.tokens(todayTokens)) tokens" }
        return Fmt.money(todaySpend)
    }

    var level: String {
        guard let remaining else { return "ok" }
        if remaining <= 0.1 { return "error" }
        if remaining <= warnAt { return "warn" }
        return "ok"
    }
}

struct ModelUsage: Identifiable, Equatable {
    var id: String { providerId + "|" + name }
    let name: String
    let providerId: String
    var money: Double
    var tokens: Double
    var requests: Int
    var priceMatch: PriceMatch = .exact("")

    @MainActor var moneyText: String {
        moneyText(privacy: false)
    }

    @MainActor func moneyText(privacy: Bool) -> String {
        switch priceMatch {
        case .unpriced: return Fmt.tokens(tokens)
        case .family: return privacy ? "≈\(Fmt.symbol)••••" : "≈" + Fmt.money(money)
        case .exact: return privacy ? "\(Fmt.symbol)••••" : Fmt.money(money)
        }
    }
}

struct DayUsage: Equatable {
    let date: Date
    /// Indexed like the store's providers.
    var money: [Double]
    var tokens: [Double]
}

/// A Mac of the usage sync, as the daemon lists it.
struct UsageDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// When it last shared its usage (for this Mac: when the sync last took it).
    let updatedAt: Date?
    let isThisMac: Bool
}

/// Whether the store reaches this Mac's Sarto daemon.
enum UsageConnection: Equatable, Sendable {
    /// Before the first answer, or while reconnecting.
    case connecting
    case connected
    /// The daemon did not answer the last tries.
    case offline
}

enum UsageAlertEvent {
    case runningLow(provider: ProviderUsage, label: String, remaining: Double, resetsAt: Date?)
}

/// The daemon's usage overview mapped onto the views' models; nothing is computed here beyond
/// putting each agent under the provider the views show it as.
enum LiveUsageSources {
    struct Meta {
        let id: String
        let name: String
        let color: Color
        let logo: String
    }

    /// The providers whose logs the daemon reads, first in the views' default order; the others
    /// follow in the daemon's agent order.
    static let leadingIds = ["claude", "codex", "antigravity"]

    /// The providers whose requests the daemon reads (its LOG_READERS), so today's tokens count.
    static let loggedIds: Set<String> = ["claude", "codex", "antigravity", "opencode", "cursor"]

    /// A provider's name, color and mark: the three log providers' own, else the harness's island
    /// mark and the name the daemon gives.
    static func meta(_ id: String, name: String? = nil) -> Meta {
        switch id {
        case "claude":
            return Meta(id: "claude", name: "Claude Code", color: Palette.solid(0xD97757), logo: UsageLogo.filled(ProviderMarkPaths.anthropic))
        case "codex":
            return Meta(id: "codex", name: "Codex", color: Palette.solid(0x7A9DFF), logo: UsageLogo.filled(ProviderMarkPaths.openai))
        case "antigravity":
            return Meta(id: "antigravity", name: "Antigravity", color: Palette.dynamicHex(0x2F7BF5, 0x5B9BFF), logo: UsageLogo.filled(ProviderMarkPaths.gemini))
        default:
            let logo = IslandAssets.markSVG[id] ?? UsageLogo.filled(ProviderMarkPaths.gemini)
            return Meta(id: id, name: name ?? id, color: color(for: id), logo: logo)
        }
    }

    private static let otherColors: [Color] = [
        Palette.dynamicHex(0x8E8E93, 0xAEAEB2),
        Palette.solid(0x9B72CB),
        Palette.solid(0x50A37B),
        Palette.solid(0xE0A63A),
        Palette.solid(0xD9688F),
        Palette.solid(0x3FA7B5),
    ]

    private static func color(for id: String) -> Color {
        if id == "cursor" { return otherColors[0] }
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return otherColors[1 + hash % (otherColors.count - 1)]
    }

    /// Maps a Sarto `agentId` (and optional `harnessId` for multi-profile agents such as
    /// `claude-code~work`) to the matching `UsageStore` provider ID: the harness, with Claude Code
    /// as `claude`, as the views' settings name it.
    static func providerId(forAgentId agentId: String, harnessId: String? = nil) -> String? {
        let raw = (harnessId?.isEmpty == false ? harnessId! : agentId).lowercased()
        let harness = raw.split(separator: "~", maxSplits: 1).first.map(String.init) ?? raw
        switch harness {
        case "claude-code", "claude":
            return "claude"
        case "codex":
            return "codex"
        case "antigravity":
            return "antigravity"
        default:
            if harness.contains("claude") { return "claude" }
            if harness.contains("codex") { return "codex" }
            if harness.contains("antigravity") { return "antigravity" }
            return harness.isEmpty ? nil : harness
        }
    }

    static func folder(for id: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch id {
        case "claude": return home.appendingPathComponent(".claude/projects")
        case "codex": return home.appendingPathComponent(".codex/sessions")
        case "antigravity": return home.appendingPathComponent(".gemini/antigravity")
        default: return nil
        }
    }

    static func placeholders() -> [ProviderUsage] {
        leadingIds.map { id in
            let m = meta(id)
            return ProviderUsage(
                id: m.id, name: m.name, plan: UsageText.l10n.tr("usage.plan.loading"), color: m.color, logo: m.logo, kind: .payg,
                todaySpend: 0, todayTokens: 0, requests: 0
            )
        }
    }

    /// Everything the views show, from one overview.
    struct ViewData {
        var providers: [ProviderUsage]
        var modelsByRange: [Int: [ModelUsage]]
        var history: [DayUsage]
        var hourlyByProvider: [[Double]]
        var devices: [UsageDevice]
        var unpricedModels: [String]
        var familyPriced: [(String, String)]
        var generatedAt: Date
    }

    static let modelRanges = [1, 7, 30, 90]

    static func viewData(_ overview: UsageOverviewInfo, warnAt: Double) -> ViewData {
        var byProvider: [String: [UsageOverviewAgentInfo]] = [:]
        var listed: [String] = []
        for agent in overview.agents {
            guard let id = providerId(forAgentId: agent.agentId, harnessId: agent.harnessId) else { continue }
            if byProvider[id] == nil { listed.append(id) }
            byProvider[id, default: []].append(agent)
        }
        let ids = providerOrder(listed)
        let providers = ids.map { provider($0, agents: byProvider[$0] ?? [], warnAt: warnAt) }

        var ranges: [Int: [ModelUsage]] = [:]
        for days in modelRanges {
            ranges[days] = models(overview.models(days: days))
        }

        return ViewData(
            providers: providers,
            modelsByRange: ranges,
            history: series(overview.daily, ids: ids).map { DayUsage(date: $0.date, money: $0.cost, tokens: $0.tokens) },
            hourlyByProvider: hourly(overview.hourly, ids: ids),
            devices: overview.devices.map {
                UsageDevice(id: $0.id, name: $0.name, updatedAt: $0.updatedAt.map(date), isThisMac: $0.thisComputer)
            },
            unpricedModels: overview.unpricedModels,
            familyPriced: overview.familyPriced.map { ($0.model, $0.standIn) },
            generatedAt: date(overview.generatedAt)
        )
    }

    /// The three log providers always, then every other provider the overview lists.
    static func providerOrder(_ listed: [String]) -> [String] {
        leadingIds + listed.filter { !leadingIds.contains($0) }
    }

    static func date(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }

    /// One provider from the agents the daemon lists under it: the agent itself first, then its
    /// profiles (`claude-code~work`), whose figures add up and whose other accounts join the tubes.
    static func provider(_ id: String, agents unordered: [UsageOverviewAgentInfo], warnAt: Double) -> ProviderUsage {
        let agents = unordered.sorted { !$0.agentId.contains("~") && $1.agentId.contains("~") }
        let m = meta(id, name: agents.first?.name)
        let lead = agents.first { $0.quota != nil }
        let quota = lead?.quota
        let windows = quota?.windows.map(window) ?? []
        let primary = quota?.primaryWindow.map(window)
        let secondary = quota?.secondaryWindow.map(window)
        let signedOut = agents.contains { $0.signedOut }
        let l10n = UsageText.l10n
        let plan = quota?.plan ?? l10n.tr(id == "antigravity" ? "usage.plan.tierUnread" : "usage.plan.localRecords")
        var provider = ProviderUsage(
            id: m.id, name: m.name, plan: plan, color: m.color, logo: m.logo,
            kind: primary == nil ? .payg : .quota,
            remaining: primary?.remaining,
            weeklyRemaining: secondary?.remaining,
            resetsAt: primary?.resetsAt,
            todaySpend: agents.reduce(0) { $0 + $1.today.cost },
            todayTokens: agents.reduce(0) { $0 + $1.today.tokens },
            requests: agents.reduce(0) { $0 + $1.today.requests }
        )
        provider.windowLabel = primary?.label ?? l10n.tr("usage.window.quota")
        provider.weeklyLabel = secondary?.label ?? ""
        provider.scopedWindows = windows.filter { $0.kind == .scoped }
        provider.allWindows = windows
        provider.quotaObservedAt = quota?.observedAt.map(date)
        provider.quotaDevice = quota?.device?.name
        provider.quotaAccount = lead.flatMap { lead in
            quota?.account.map { QuotaAccountRef(agentId: lead.agentId, account: $0) }
        }
        provider.note = signedOut && id == "antigravity" ? l10n.tr("usage.note.agySignedOut") : nil
        provider.unpricedTokens = agents.reduce(0) { $0 + $1.today.unpricedTokens }
        let newest = agents.compactMap(\.activity).max { $0.at < $1.at }
        let localNewest = agents.compactMap(\.localActivity).max { $0.at < $1.at }
        provider.lastActivity = newest.map { date($0.at) }
        provider.lastModel = newest?.model
        provider.localLastActivity = localNewest.map { date($0.at) }
        provider.localLastModel = localNewest?.model
        provider.available = agents.contains { $0.available }
        // An older daemon does not decide; it read quotas of the log providers alone.
        provider.eligible = agents.contains { $0.eligible ?? ($0.quota != nil && leadingIds.contains(id)) }
        provider.windowReset = primary?.reset ?? false
        provider.warnAt = warnAt

        var others: [(agentId: String, quota: UsageQuotaInfo)] =
            (lead?.otherAccounts ?? []).map { (lead!.agentId, $0) }
        for agent in agents where agent.agentId != lead?.agentId {
            others += ((agent.quota.map { [$0] } ?? []) + agent.otherAccounts).map { (agent.agentId, $0) }
        }
        var seen = Set([quota?.account].compactMap { $0 })
        others = others.filter { other in
            guard let account = other.quota.account else { return true }
            return seen.insert(account).inserted
        }
        provider.otherAccounts = others.enumerated().map { index, other in
            var tube = accountTube(other.quota, ordinal: index + 2, of: provider, warnAt: warnAt)
            tube.quotaAccount = other.quota.account.map { QuotaAccountRef(agentId: other.agentId, account: $0) }
            tube.eligible = provider.eligible
            return tube
        }
        return provider
    }

    /// Another account's tube. Its name tells it apart from the main one by plan, or by an
    /// ordinal when the plans match; the Mac it came from shows in its detail.
    static func accountTube(_ other: UsageQuotaInfo, ordinal: Int, of base: ProviderUsage, warnAt: Double) -> ProviderUsage {
        let windows = other.windows.map(window)
        let primary = other.primaryWindow.map(window)
        let secondary = other.secondaryWindow.map(window)
        let suffix = other.plan.flatMap { $0 != base.plan ? $0 : nil } ?? "\(ordinal)"
        let key = other.account ?? other.device?.id ?? "\(ordinal)"
        var tube = ProviderUsage(
            id: "\(base.id)@\(key)", name: "\(base.name) \(suffix)",
            plan: other.plan ?? base.plan, color: base.color, logo: base.logo,
            kind: primary == nil ? .payg : .quota,
            remaining: primary?.remaining,
            weeklyRemaining: secondary?.remaining,
            resetsAt: primary?.resetsAt,
            todaySpend: 0,
            todayTokens: 0,
            requests: 0
        )
        tube.windowLabel = primary?.label ?? UsageText.l10n.tr("usage.window.quota")
        tube.weeklyLabel = secondary?.label ?? ""
        tube.scopedWindows = windows.filter { $0.kind == .scoped }
        tube.allWindows = windows
        tube.quotaObservedAt = other.observedAt.map(date)
        tube.quotaDevice = other.device?.name
        tube.windowReset = primary?.reset ?? false
        tube.warnAt = warnAt
        return tube
    }

    static func window(_ w: UsageQuotaWindowInfo) -> QuotaWindow {
        let kind: QuotaWindow.Kind
        switch w.kind {
        case .session: kind = .session
        case .weekly: kind = .weekly
        case .scoped: kind = .scoped
        case .other: kind = .other
        }
        return QuotaWindow(
            id: w.id, kind: kind, scope: w.scope, label: w.label, minutes: w.minutes,
            remaining: w.remaining, resetsAt: w.resetsAt.map(date), reset: w.reset,
            forecast: WindowForecast(
                status: w.forecast.status,
                estimatedRemainingTokens: w.forecast.estimatedRemainingTokens,
                windowTokens: w.forecast.windowTokens
            ),
            amount: w.amount
        )
    }

    /// A range's models under the views' providers, a model the daemon lists under several of a
    /// provider's agents as one, in the daemon's order: by cost, then tokens.
    static func models(_ list: [UsageOverviewModelInfo]) -> [ModelUsage] {
        var out: [ModelUsage] = []
        var index: [String: Int] = [:]
        for m in list {
            guard let providerId = providerId(forAgentId: m.agentId) else { continue }
            let match: PriceMatch
            switch m.price.kind {
            case .exact: match = .exact(m.price.model ?? m.model)
            case .family: match = .family(m.price.model ?? "")
            case .unpriced: match = .unpriced
            }
            let model = ModelUsage(name: m.model, providerId: providerId, money: m.cost, tokens: m.tokens,
                                   requests: m.requests, priceMatch: match)
            if let at = index[model.id] {
                out[at].money += model.money
                out[at].tokens += model.tokens
                out[at].requests += model.requests
            } else {
                index[model.id] = out.count
                out.append(model)
            }
        }
        if out.count == list.count { return out }
        return out.sorted { ($0.money, $0.tokens) > ($1.money, $1.tokens) }
    }

    /// A series' periods with each provider's sums, indexed like `ids`, the store's providers.
    static func series(_ s: UsageSeriesInfo, ids: [String]) -> [(date: Date, tokens: [Double], cost: [Double])] {
        var tokens = Array(repeating: Array(repeating: 0.0, count: ids.count), count: s.starts.count)
        var cost = tokens
        for line in s.agents {
            guard let id = providerId(forAgentId: line.agentId), let p = ids.firstIndex(of: id) else { continue }
            for (i, value) in line.tokens.prefix(s.starts.count).enumerated() { tokens[i][p] += value }
            for (i, value) in line.cost.prefix(s.starts.count).enumerated() { cost[i][p] += value }
        }
        return s.starts.enumerated().map { i, start in (date(start), tokens[i], cost[i]) }
    }

    /// Each provider's cost per hour over the last 24 hours, the current hour last.
    static func hourly(_ s: UsageSeriesInfo, ids: [String]) -> [[Double]] {
        let periods = series(s, ids: ids)
        return ids.indices.map { p in periods.map { $0.cost[p] } }
    }
}

/// The usage the menu bar, the Dynamic Island and Settings show, as this Mac's Sarto daemon
/// computes it (`usage.overview`). It reads the overview again when the daemon says the figures
/// changed, and between those at a slow pace, faster while a usage view is on screen.
@MainActor
final class PrismUsageStore: ObservableObject {
    @Published var providers: [ProviderUsage]
    @Published var models: [ModelUsage] = []
    @Published var history: [DayUsage] = []
    @Published var hourlyByProvider: [[Double]] = []
    @Published var updatedAt = Date()
    @Published var refreshToken = 0
    /// True once the first overview arrived.
    @Published var ready = false
    @Published private(set) var connection: UsageConnection = .connecting
    @Published var modelsByRange: [Int: [ModelUsage]] = [:]
    @Published var unpricedModels: [String] = []
    @Published var excluded: Set<String> = []
    @Published var familyPriced: [(String, String)] = []
    @Published var devices: [UsageDevice] = []
    /// Each agent's tokens over the last 30 days, by the usage's agent id; the agent menus rank by it.
    @Published var agentTokens: [String: Double] = [:]
    /// Why removing a Mac's usage failed, until the next removal.
    @Published var syncError: String?
    @Published var lowThreshold = 0.3 {
        didSet {
            guard lowThreshold != oldValue else { return }
            for index in providers.indices { providers[index].warnAt = lowThreshold }
        }
    }

    let events = PassthroughSubject<UsageAlertEvent, Never>()

    /// Opens a connection of the store's own to this Mac's agent host; the app sets it.
    var openHost: (@MainActor () async throws -> SartoHostSession)? {
        didSet { if started { fetch() } }
    }
    /// Removes another Mac's usage record through the daemon's sync; the app sets it.
    var removeRecord: (@MainActor (String) async throws -> Void)?
    /// `all` for every Mac of the sync, `computer` for this Mac alone.
    var scope: UsageOverviewScope = .all {
        didSet { if scope != oldValue { fetch() } }
    }

    /// Between the daemon's change events, while a usage view is on screen and while not. The
    /// daemon reads the quota files every 45 s without an event, so the polls also bring those.
    private static let visibleInterval: TimeInterval = 15
    private static let backgroundInterval: TimeInterval = 30
    private static let retryInterval: TimeInterval = 2
    /// The daemon's own scan of the agents' logs, asked for when a usage view opens, at most this often.
    private static let syncInterval: TimeInterval = 60

    private var started = false
    private var active = true
    private var visible = false
    private var shownViews = 0
    private var host: SartoHostSession?
    private var hostEvents: Task<Void, Never>?
    private var fetching = false
    private var fetchAgain = false
    private var syncRequested = false
    private var lastSync = Date.distantPast
    private var failures = 0
    private var pollTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var windowRemaining: [String: Double] = [:]

    init() {
        self.providers = LiveUsageSources.placeholders()
    }

    var included: [ProviderUsage] { providers.filter { !excluded.contains($0.id) } }
    var todaySpend: Double { included.reduce(0) { $0 + $1.todaySpend } }
    var todayTokens: Double { included.reduce(0) { $0 + $1.todayTokens } }
    var todayRequests: Int { included.reduce(0) { $0 + $1.requests } }

    var includedHistory: [DayUsage] {
        let off = Set(providers.indices.filter { excluded.contains(providers[$0].id) })
        guard !off.isEmpty else { return history }
        return history.map { day in
            DayUsage(
                date: day.date,
                money: day.money.enumerated().map { off.contains($0.offset) ? 0 : $0.element },
                tokens: day.tokens.enumerated().map { off.contains($0.offset) ? 0 : $0.element }
            )
        }
    }

    var hourly: [Double] {
        var totals = Array(repeating: 0.0, count: 24)
        for (provider, slots) in zip(providers, hourlyByProvider) where !excluded.contains(provider.id) {
            for (hour, value) in slots.prefix(24).enumerated() { totals[hour] += value }
        }
        return totals
    }

    func rankedModels(days: Int) -> [ModelUsage] {
        (modelsByRange[days] ?? []).filter { !excluded.contains($0.providerId) }
    }

    /// The providers whose quota shows, as the tubes take them.
    var measured: [ProviderUsage] { included.filter(\.eligible) }

    var lowestWindow: (provider: ProviderUsage, label: String, remaining: Double)? {
        var best: (ProviderUsage, String, Double)?
        for provider in measured {
            var windows: [(String, Double)] = provider.remaining.map { [(provider.windowLabel, $0)] } ?? []
            windows += provider.scopedWindows.map { ($0.label, $0.remaining) }
            for (label, remaining) in windows where remaining <= lowThreshold {
                if best == nil || remaining < best!.2 { best = (provider, label, remaining) }
            }
        }
        return best.map { (provider: $0.0, label: $0.1, remaining: $0.2) }
    }

    var lowestRemaining: Double? {
        measured.flatMap { provider in (provider.remaining.map { [$0] } ?? []) + provider.scopedWindows.map(\.remaining) }.min()
    }

    /// A provider, or one of its other accounts' tubes.
    func provider(_ id: String) -> ProviderUsage? {
        providers.lazy.flatMap { [$0] + $0.otherAccounts }.first { $0.id == id }
    }

    func start() {
        guard !started else { return }
        started = true
        fetch()
    }

    /// Off while nothing shows usage: the store then neither asks nor listens.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        guard started else { return }
        if on {
            fetch()
        } else {
            pollTask?.cancel()
            changeTask?.cancel()
            changeTask = nil
            Task { await self.dropHost() }
        }
    }

    /// While the menu bar panel or a Settings page shows usage; reads more often.
    func setVisible(_ on: Bool) {
        updateVisible(panel: on)
    }

    /// For a view inside another surface, such as the island's usage tab, as it appears and goes.
    func setShown(_ shown: Bool) {
        shownViews = max(0, shownViews + (shown ? 1 : -1))
        updateVisible(panel: nil)
    }

    private var panelVisible = false

    private func updateVisible(panel: Bool?) {
        if let panel { panelVisible = panel }
        let next = panelVisible || shownViews > 0
        guard next != visible else { return }
        visible = next
        guard started, active else { return }
        if next {
            if Date().timeIntervalSince(lastSync) >= Self.syncInterval { syncRequested = true }
            fetch()
        } else {
            schedulePoll()
        }
    }

    /// The panel's refresh: the daemon reads the agents' logs now, then the overview is read again.
    func refresh() {
        refreshToken += 1
        syncRequested = true
        fetch()
    }

    /// Reads the overview now, as after the daemon (re)connects or the sync turns on or off.
    func reload() {
        fetch()
    }

    /// Removes an account from the usage views: the daemon leaves its readings until now out, here
    /// and in what this Mac shares, and shows it again once the account is used again.
    func forgetAccount(_ ref: QuotaAccountRef) async throws {
        guard let session = host else { throw PortRPCError.disconnected() }
        try await session.usageForgetAccount(agentId: ref.agentId, account: ref.account)
        fetch()
    }

    /// Removes another Mac's usage from the sync; it leaves the list at once, and the daemon's
    /// next overview no longer has it.
    func removeDevice(_ id: String) {
        guard let removeRecord else { return }
        devices.removeAll { $0.id == id }
        Task { [weak self] in
            do {
                try await removeRecord(id)
                self?.syncError = nil
            } catch {
                self?.syncError = error.localizedDescription
            }
            self?.fetch()
        }
    }

    // MARK: Reading

    private func fetch() {
        guard started, active, openHost != nil else { return }
        if fetching {
            fetchAgain = true
            return
        }
        fetching = true
        pollTask?.cancel()
        Task { [weak self] in
            await self?.performFetch()
        }
    }

    private func performFetch() async {
        let scope = self.scope
        var answered: SartoHostSession?
        do {
            let session = try await connectedHost()
            let overview = try await session.usageOverview(scope: scope)
            answered = session
            failures = 0
            if connection != .connected { connection = .connected }
            if scope == self.scope { apply(overview) } else { fetchAgain = true }
        } catch {
            if Self.isDisconnect(error) { await dropHost() }
            failures += 1
            // A daemon that is still starting gets a few tries before the views say it is away.
            if failures >= (ready ? 2 : 5), connection != .offline { connection = .offline }
        }
        if syncRequested, let host = answered {
            syncRequested = false
            lastSync = Date()
            Task { [weak self] in
                try? await host.usageSync()
                self?.fetch()
            }
        }
        fetching = false
        if fetchAgain {
            fetchAgain = false
            fetch()
        } else {
            schedulePoll()
        }
    }

    private func schedulePoll(after interval: TimeInterval? = nil) {
        pollTask?.cancel()
        guard started, active else { return }
        let delay = interval ?? (failures > 0 && failures < 5 ? Self.retryInterval
            : (visible ? Self.visibleInterval : Self.backgroundInterval))
        pollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.fetch()
        }
    }

    /// The daemon's figures changed: read them again shortly, once for a burst of changes.
    private func usageChanged() {
        guard started, active, changeTask == nil else { return }
        let delay: TimeInterval = visible ? 0.5 : 3
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.changeTask = nil
            self.fetch()
        }
    }

    private func connectedHost() async throws -> SartoHostSession {
        if let host { return host }
        guard let openHost else { throw PortRPCError.disconnected() }
        let session = try await openHost()
        // Fetches run one at a time, so no other one opened a connection meanwhile.
        host = session
        hostEvents = Task.detached { [weak self] in
            for await event in session.events {
                if case .usageChanged = event { await self?.usageChanged() }
            }
            await self?.hostClosed(session)
        }
        return session
    }

    private func hostClosed(_ session: SartoHostSession) {
        guard host === session else { return }
        host = nil
        hostEvents = nil
        // The daemon restarted or quit: try again shortly.
        schedulePoll(after: Self.retryInterval)
    }

    private func dropHost() async {
        guard let session = host else { return }
        host = nil
        hostEvents?.cancel()
        hostEvents = nil
        await session.close()
    }

    private static func isDisconnect(_ error: Error) -> Bool {
        if error is UnixSocketError { return true }
        return (error as? PortRPCError)?.code == "host_offline"
    }

    /// Each agent's tokens over the series' last `days` periods.
    static func recentTokens(_ series: UsageSeriesInfo, days: Int) -> [String: Double] {
        var totals: [String: Double] = [:]
        for agent in series.agents {
            totals[agent.agentId, default: 0] += agent.tokens.suffix(days).reduce(0, +)
        }
        return totals
    }

    /// Assigns only what changed: every assignment notifies the views and the coordinator's
    /// subscribers, which redraw the status item.
    private func apply(_ overview: UsageOverviewInfo) {
        let data = LiveUsageSources.viewData(overview, warnAt: lowThreshold)
        if providers != data.providers { providers = data.providers }
        let todayModels = data.modelsByRange[1] ?? []
        if models != todayModels { models = todayModels }
        if modelsByRange != data.modelsByRange { modelsByRange = data.modelsByRange }
        if history != data.history { history = data.history }
        if hourlyByProvider != data.hourlyByProvider { hourlyByProvider = data.hourlyByProvider }
        if unpricedModels != data.unpricedModels { unpricedModels = data.unpricedModels }
        if !familyPriced.elementsEqual(data.familyPriced, by: ==) { familyPriced = data.familyPriced }
        if devices != data.devices { devices = data.devices }
        let tokens = Self.recentTokens(overview.daily, days: 30)
        if agentTokens != tokens { agentTokens = tokens }
        updatedAt = data.generatedAt

        // Low-quota alerts, from the windows received: a window crossing the threshold since the
        // last overview raises one. Hidden providers still have their levels tracked, so showing one
        // again does not replay an old crossing, but they raise none.
        var remaining: [String: Double] = [:]
        for provider in data.providers {
            let alerts = !excluded.contains(provider.id) && provider.eligible
            for window in provider.allWindows {
                let key = provider.id + "|" + window.id
                remaining[key] = window.remaining
                if alerts, ready, let before = windowRemaining[key], before > lowThreshold, window.remaining <= lowThreshold {
                    events.send(.runningLow(provider: provider, label: window.label, remaining: window.remaining, resetsAt: window.resetsAt))
                }
            }
        }
        windowRemaining = remaining
        if !ready { ready = true }
    }
}
