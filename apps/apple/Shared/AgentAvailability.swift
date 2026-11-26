import Foundation
import SartoProtocol
import PrismDesign

// Why an agent cannot start and what fixes it, said the same way wherever it is named: the agent
// menu's tags, its options pane, New session and Settings › Agents.

/// What an agent needs before a new session can start it. `install` is missing from the machine
/// and `adapter` a package whose copy is not installed: neither starts until installed. `update`
/// is the user's own program, too old; `blocked` a harness on the machine that cannot run for
/// another reason. `setup` has the user's program but not its adapter, which its first start
/// installs.
enum AgentNeed: Sendable, Equatable {
    case install
    case update
    case blocked
    case installing
    case failed
    case adapter
    case setup
    case signIn
}

/// What fixes a harness that cannot run: installing it, a tool it needs, updating or choosing its
/// program.
enum AgentProblemFix: String, Sendable, Equatable {
    case install
    case node
    case npm
    case uv
    case update
    case choose

    /// Where each tool is installed from, by the guide its makers keep.
    var guideURL: URL? {
        switch self {
        case .node: return URL(string: "https://nodejs.org/en/download")
        case .npm: return URL(string: "https://docs.npmjs.com/downloading-and-installing-node-js-and-npm")
        case .uv: return URL(string: "https://docs.astral.sh/uv/getting-started/installation/")
        case .install, .update, .choose: return nil
        }
    }
}

/// Why a harness cannot run: the short state, the sentence and the fix.
struct AgentHarnessProblem: Sendable, Equatable {
    let reason: HarnessReason
    /// As a list, a pill or a menu says it: "Needs Node.js 22 or later".
    let label: String
    /// The short state without its version, where little room is left.
    let shortLabel: String
    /// The sentence, which for a program that cannot run also says why.
    let text: String
    let fix: AgentProblemFix?
}

/// What a fix's button does outside Settings.
enum AgentFixAction: Sendable, Equatable {
    case install
    case openGuide(AgentProblemFix)
    case updateProgram(command: String)
    case chooseProgram
    case retry
    case openSettings

    func title(_ l10n: PrismL10n) -> String {
        switch self {
        case .install: return l10n.tr("agents.problem.fix.install")
        case .openGuide(let tool): return l10n.tr("agents.problem.fix.\(tool.rawValue)")
        case .updateProgram: return l10n.tr("agents.problem.fix.update")
        case .chooseProgram: return l10n.tr("agents.problem.fix.choose")
        case .retry: return l10n.tr("agents.problem.fix.retry")
        case .openSettings: return l10n.tr("agents.problem.fix.openSettings")
        }
    }
}

/// One agent's availability, worked out once per change of the agents and read by every surface.
struct AgentAvailabilityEntry: Sendable, Equatable {
    let need: AgentNeed?
    /// A new session can start it now.
    let canStart: Bool
    let problem: AgentHarnessProblem?
    /// The agent menu's tag: only what stops it, nil when nothing does.
    let tag: PrismAgentTag?
    let fix: AgentFixAction?
    let fixTitle: String?
}

/// While no agent can start: the reason they share and the agents and harnesses it stops.
struct NoAgentReason: Sendable, Equatable {
    /// Nil when none has a reason of its harness, as when none is on.
    let reason: HarnessReason?
    let agents: [String]
    let harnesses: [String]
}

enum AgentAvailability {
    private static let missingStates: Set<String> = ["not-installed", "node-missing", "node-outdated"]

    // MARK: Readiness

    private enum Readiness {
        case ready, signIn, installing, starting, failed, missing
    }

    private static func readiness(_ status: AgentStatusInfo) -> Readiness {
        if missingStates.contains(status.state) { return .missing }
        switch status.state {
        case "installing": return .installing
        case "starting": return .starting
        case "failed": return .failed
        default: return status.signIn == "required" ? .signIn : .ready
        }
    }

    static func isInstalled(_ status: AgentStatusInfo) -> Bool {
        !missingStates.contains(status.state)
    }

    /// Its harness's program is on the machine, even one that cannot run yet.
    static func hasProgram(_ status: AgentStatusInfo) -> Bool {
        isInstalled(status) || status.cli?.installed != nil
    }

    /// Ready to install but not installed: the adapter Sarto installs into its data folder, or the
    /// SDK while the user's own CLI is missing too.
    static func awaitsPackage(_ status: AgentStatusInfo) -> Bool {
        guard let pkg = status.availability.package else { return false }
        return !pkg.installed && status.state == "available" && !(pkg.isSdk && status.cli?.installed != nil)
    }

    /// The oldest version the user's program must be, when it is found but older than needed.
    static func cliOutdated(_ status: AgentStatusInfo) -> String? {
        if case .tooOld(let minimum)? = status.cli?.installed?.problem { return minimum }
        return nil
    }

    /// Listed with the installed agents: it can run now. Claude Code's SDK beside the user's own
    /// CLI counts, since its first start installs it.
    private static func listedInstalled(_ status: AgentStatusInfo) -> Bool {
        if readiness(status) == .missing { return false }
        guard let pkg = status.availability.package else { return true }
        return pkg.installed || (pkg.isSdk && status.cli?.installed != nil)
    }

    // MARK: Why it cannot run

    /// Why the harness cannot run, or nil when it can.
    static func harnessReason(_ status: AgentStatusInfo) -> HarnessReason? {
        if missingStates.contains(status.state) {
            return status.availability.reason ?? olderReason(status)
        }
        return awaitsPackage(status) ? .notInstalled : nil
    }

    /// The reason an older host, which names none, says only by its state and its program.
    private static func olderReason(_ status: AgentStatusInfo) -> HarnessReason {
        guard status.state == "not-installed" else {
            return .needsNode(minimum: nil, installed: nil, unreadable: false)
        }
        let installed = status.cli?.installed
        switch installed?.problem {
        case .tooOld(let minimum)?: return .tooOld(minimum: minimum, installed: installed?.version)
        case .some: return .cannotRun(why: status.detail ?? "")
        case nil: return .notInstalled
        }
    }

    /// Its program, or Sarto's install of it, is on the machine, even one that cannot run.
    static func programHere(_ status: AgentStatusInfo) -> Bool {
        if hasProgram(status) { return true }
        switch harnessReason(status) {
        case nil, .notInstalled?, .noVersion?: return false
        default: return status.availability.package?.installed == true || status.binaryOverride != nil
        }
    }

    static func reasonLabel(_ reason: HarnessReason, l10n: PrismL10n) -> String {
        switch reason {
        case .notInstalled:
            return l10n.tr("agents.problem.notInstalled")
        case .needsNode(let minimum, _, _):
            return minimum.map { l10n.tr("agents.problem.needsNodeAt", $0) } ?? l10n.tr("agents.problem.needsNode")
        case .needsNpm:
            return l10n.tr("agents.problem.needsNpm")
        case .needsUv(let minimum, _):
            return minimum.map { l10n.tr("agents.problem.needsUvAt", $0) } ?? l10n.tr("agents.problem.needsUv")
        case .tooOld(let minimum, _):
            return minimum.isEmpty ? l10n.tr("agents.problem.tooOld") : l10n.tr("agents.problem.tooOldAt", minimum)
        case .cannotRun, .unknown:
            return l10n.tr("agents.problem.cannotRun")
        case .noVersion:
            return l10n.tr("agents.problem.noVersion")
        }
    }

    private static func shortLabel(_ reason: HarnessReason, l10n: PrismL10n) -> String {
        switch reason {
        case .needsNode(_, let installed, let unreadable):
            return reasonLabel(.needsNode(minimum: nil, installed: installed, unreadable: unreadable), l10n: l10n)
        case .needsUv(_, let installed):
            return reasonLabel(.needsUv(minimum: nil, installed: installed), l10n: l10n)
        case .tooOld(_, let installed):
            return reasonLabel(.tooOld(minimum: "", installed: installed), l10n: l10n)
        default:
            return reasonLabel(reason, l10n: l10n)
        }
    }

    private static func fixOf(_ status: AgentStatusInfo, _ reason: HarnessReason) -> AgentProblemFix? {
        switch reason {
        case .notInstalled: return .install
        case .needsNode: return .node
        case .needsNpm: return .npm
        case .needsUv: return .uv
        case .tooOld: return .update
        case .cannotRun, .unknown:
            return status.availability.program != nil || status.binaryCommand != nil ? .choose : nil
        case .noVersion: return nil
        }
    }

    /// Why the harness cannot run, as every surface says it, or nil when it can.
    static func problem(_ status: AgentStatusInfo, l10n: PrismL10n) -> AgentHarnessProblem? {
        guard let reason = harnessReason(status) else { return nil }
        let label = reasonLabel(reason, l10n: l10n)
        let text: String
        if case .cannotRun(let why) = reason, !why.isEmpty {
            text = l10n.tr("agents.problem.cannotRunWhy", why)
        } else {
            text = label
        }
        return AgentHarnessProblem(
            reason: reason,
            label: label,
            shortLabel: shortLabel(reason, l10n: l10n),
            text: text,
            fix: fixOf(status, reason)
        )
    }

    // MARK: What it needs

    static func need(_ status: AgentStatusInfo) -> AgentNeed? {
        if cliOutdated(status) != nil { return .update }
        let r = readiness(status)
        switch r {
        case .missing: return programHere(status) ? .blocked : .install
        case .installing: return .installing
        case .failed: return .failed
        case .ready, .signIn, .starting: break
        }
        if !listedInstalled(status) { return status.cli != nil ? .setup : .adapter }
        return r == .signIn ? .signIn : nil
    }

    static func canStart(_ status: AgentStatusInfo, need: AgentNeed?) -> Bool {
        guard status.registered != false, status.disabled != true else { return false }
        switch need {
        case .install?, .adapter?, .update?, .blocked?: return false
        default: return true
        }
    }

    /// The harness installs by one of its routes or as Sarto's copy, rather than only updating.
    static func needsInstall(_ status: AgentStatusInfo) -> Bool {
        if cliOutdated(status) != nil { return false }
        if status.state == "not-installed", status.cli?.installed == nil, !status.availability.installMethods.isEmpty {
            return true
        }
        if let pkg = status.availability.package, !pkg.installed, status.state == "available" { return true }
        return missingStates.contains(status.state)
    }

    /// What the fix's button does: a tool's guide, the install sheet, the update command shown
    /// before it runs, the program chosen in an open panel, a retry, or the agent's settings.
    static func fixAction(_ status: AgentStatusInfo, need: AgentNeed?, problem: AgentHarnessProblem?) -> AgentFixAction? {
        let update: AgentFixAction = status.cli?.update.map { .updateProgram(command: $0.command) } ?? .openSettings
        switch need {
        case .update?:
            return update
        case .install?, .blocked?:
            switch problem?.fix {
            case .install?: return .install
            case .node?: return .openGuide(.node)
            case .npm?: return .openGuide(.npm)
            case .uv?: return .openGuide(.uv)
            case .update?: return update
            case .choose?: return .chooseProgram
            case nil: return .openSettings
            }
        case .adapter?:
            return .install
        case .failed?:
            return .retry
        case .installing?, .setup?, .signIn?, nil:
            return nil
        }
    }

    // MARK: The menu's tag

    /// The tag of an agent's row, the first of these that applies: a version Sarto's checks reject,
    /// what the agent needs before it starts, a used-up balance, a used-up plan window that extra
    /// usage covers, a used-up plan window, a window at 90% or more. `model` is the one a new
    /// session starts on, since a window of another model does not hold it back. Nil when nothing
    /// is wrong.
    static func tag(
        _ status: AgentStatusInfo,
        need: AgentNeed?,
        problem: AgentHarnessProblem?,
        model: ConfigOption?,
        nowMs: Double,
        l10n: PrismL10n
    ) -> PrismAgentTag? {
        // An outdated program is told to update before its version is called unsupported.
        if need != .update, let warning = status.versionWarning {
            let key = warning.broken || warning.supported == nil ? "agents.tag.versionBroken" : "agents.tag.versionUnsupported"
            return PrismAgentTag(text: l10n.tr("agents.tag.unsupported"), tone: .attention, title: l10n.tr(key, warning.version))
        }
        switch need {
        case .update?:
            let task = status.task?.kind == "update" ? status.task : nil
            if task?.isRunning == true {
                return PrismAgentTag(text: l10n.tr("agents.tag.updating"), tone: .muted)
            }
            let failed = task?.state == "failed" ? task?.error.flatMap { $0.isEmpty ? nil : $0 } : nil
            return PrismAgentTag(
                text: l10n.tr("agents.tag.update"),
                tone: failed == nil ? .attention : .danger,
                title: failed ?? l10n.tr("agents.tag.needsUpdate", problem?.text ?? l10n.tr("agents.problem.tooOld"))
            )
        case .blocked?:
            return PrismAgentTag(
                text: problem?.shortLabel ?? l10n.tr("agents.problem.cannotRun"),
                tone: .danger,
                title: problem?.text
            )
        case .install?, .adapter?:
            return PrismAgentTag(
                text: problem?.shortLabel ?? l10n.tr("agents.problem.notInstalled"),
                tone: .muted,
                title: problem.map(\.text).flatMap { $0 == problem?.shortLabel ? nil : $0 }
            )
        case .failed?:
            let detail = status.detail.flatMap { $0.isEmpty ? nil : $0 }
            return PrismAgentTag(text: l10n.tr("agents.tag.failed"), tone: .danger, title: detail ?? l10n.tr("agents.tag.failedTitle"))
        case .signIn?:
            return PrismAgentTag(text: l10n.tr("agents.tag.signIn"), tone: .attention, title: l10n.tr("agents.tag.signedOut"))
        case .installing?:
            return PrismAgentTag(text: l10n.tr("agents.tag.installing"), tone: .muted)
        case .setup?:
            return PrismAgentTag(text: l10n.tr("agents.tag.setsUp"), tone: .muted, title: l10n.tr("agents.tag.setsUpTitle"))
        case nil:
            break
        }
        if balanceUsedUp(status, model: model) {
            return PrismAgentTag(text: l10n.tr("agents.tag.noBalance"), tone: .danger, title: l10n.tr("agents.tag.balanceUsedUp"))
        }
        guard let held = holdingLimit(limitsOf(status, model: model), model: model, nowMs: nowMs) else { return nil }
        let limit = plain(held.limit)
        let window = windowName(limit, l10n: l10n)
        let phrase = limit.label
        // A used-up window that extra usage covers still lets a session start.
        if held.reached, limit.extraUsage == true {
            return PrismAgentTag(
                text: l10n.tr("agents.tag.extraUsage"),
                tone: .attention,
                title: l10n.tr("agents.tag.limitExtraUsage", phrase)
            )
        }
        if held.reached {
            guard let at = limit.resetsAt else {
                return PrismAgentTag(
                    text: l10n.tr("agents.tag.usedUp", window),
                    tone: .danger,
                    title: l10n.tr("agents.tag.limitReached", phrase)
                )
            }
            return PrismAgentTag(
                text: l10n.tr("agents.tag.resets", window, resetDay(at, nowMs: nowMs, l10n: l10n)),
                tone: .danger,
                title: l10n.tr("agents.tag.limitReachedResets", phrase, resetTime(at, nowMs: nowMs, l10n: l10n))
            )
        }
        let left = max(0, min(100, 100 - Int((limit.usedPercent ?? 0).rounded())))
        return PrismAgentTag(
            text: l10n.tr("agents.tag.left", window, left),
            tone: .attention,
            title: l10n.tr("agents.tag.limitLeft", phrase, left)
        )
    }

    /// The model's provider, which an OpenCode model value starts with: `deepseek/deepseek-v4-pro`.
    private static func providerOf(_ model: ConfigOption?) -> String? {
        guard let value = model?.value.stringValue else { return nil }
        return value.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    private static func spent(_ balances: [AgentBalanceInfo]) -> Bool {
        !balances.isEmpty && balances.allSatisfy { $0.amount <= 0 }
    }

    /// The agent is paid from a balance alone and it is used up: DeepSeek Harness on the official
    /// key, and OpenCode on a DeepSeek or OpenRouter model.
    private static func balanceUsedUp(_ status: AgentStatusInfo, model: ConfigOption?) -> Bool {
        switch status.harnessId ?? status.id {
        case "deepseek":
            guard status.account?.kind == "api_key", let balance = status.availability.balance else { return false }
            return balance.state == "ready" && spent(balance.balances)
        case "opencode":
            guard let provider = providerOf(model), provider == "deepseek" || provider == "openrouter",
                  let usage = status.availability.providers?.first(where: { $0.id == provider })?.usage
            else { return false }
            return usage.state == "ready" && spent(usage.balances)
        default:
            return false
        }
    }

    /// The limits that can hold back the model: an OpenCode provider's windows only its own
    /// models, and never extra usage, which says nothing of whether the plan lets a session start.
    private static func limitsOf(_ status: AgentStatusInfo, model: ConfigOption?) -> [PlanLimitInfo] {
        let provider = (status.harnessId ?? status.id) == "opencode" ? providerOf(model) : nil
        return (status.limits ?? []).filter { limit in
            limit.window != "overage" && (provider.map { limit.window.hasPrefix("\($0):") } ?? true)
        }
    }

    // MARK: Plan windows (src/shared/plan-limits.ts)

    private static func words(_ texts: [String?]) -> Set<String> {
        let joined = texts.compactMap { $0 }.joined(separator: " ").lowercased()
        let parts = joined.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return Set(parts.map(String.init))
    }

    private static func has(_ own: Set<String>, _ name: String) -> Bool {
        words([name]).allSatisfy(own.contains)
    }

    /// The windows that hold back the model chosen. A per-model weekly window counts only on a
    /// model that names it; a window naming none of the menu's models counts for all of them, and
    /// so does every window when the model is not known. A group's window counts only on the
    /// models it lists, unless no group lists the chosen model.
    static func limitsForModel(_ limits: [PlanLimitInfo], model: ConfigOption?) -> [PlanLimitInfo] {
        let choices = model?.choices ?? []
        guard let value = model?.value.stringValue, let current = choices.first(where: { $0.value == value }) else {
            return limits
        }
        let known = words(choices.flatMap { [$0.value, $0.name, $0.modelId] })
        let own = words([current.value, current.name, current.modelId, current.description])
        let grouped = limits.contains { $0.models?.contains { has(own, $0) } == true }
        return limits.filter { limit in
            if let models = limit.models, !models.isEmpty {
                return !grouped || models.contains { has(own, $0) }
            }
            let prefix = "seven_day_"
            guard limit.window.hasPrefix(prefix) else { return true }
            let names = limit.window.dropFirst(prefix.count).split(separator: "_").map(String.init)
            if names.isEmpty || !names.allSatisfy(known.contains) { return true }
            return names.allSatisfy(own.contains)
        }
    }

    /// The one window that tells whether an agent would stop a session on `model`: the used-up one
    /// that resets last, else the fullest at 90% or more, the later reset on a tie. A window past
    /// its reset is skipped, since its reading is from before it.
    static func holdingLimit(
        _ limits: [PlanLimitInfo],
        model: ConfigOption?,
        nowMs: Double
    ) -> (limit: PlanLimitInfo, reached: Bool)? {
        let current = limitsForModel(limits, model: model).filter { limit in
            limit.resetsAt.map { $0 > nowMs } ?? true
        }
        func resets(_ limit: PlanLimitInfo) -> Double { limit.resetsAt ?? .infinity }
        if let reached = current.filter({ $0.state == "reached" }).max(by: { resets($0) < resets($1) }) {
            return (reached, true)
        }
        func used(_ limit: PlanLimitInfo) -> Int { Int((limit.usedPercent ?? -1).rounded()) }
        let near = current
            .filter { used($0) >= 90 }
            .max { used($0) != used($1) ? used($0) < used($1) : resets($0) < resets($1) }
        return near.map { ($0, false) }
    }

    // Names some windows go by besides the ones the interface knows.
    private static let windowAliases: [String: String] = [
        "rolling": "five_hour",
        "weekly": "seven_day",
        "1_day": "daily",
    ]

    /// A window under the names the interface knows, without its OpenCode provider.
    private static func plain(_ limit: PlanLimitInfo) -> PlanLimitInfo {
        let own = limit.window.firstIndex(of: ":").map { String(limit.window[limit.window.index(after: $0)...]) } ?? limit.window
        let window = windowAliases[own] ?? own
        guard window != limit.window else { return limit }
        let label = limit.window.contains(":")
            ? (limit.label.components(separatedBy: " · ").last ?? limit.label)
            : limit.label
        return PlanLimitInfo(
            window: window,
            label: label,
            usedPercent: limit.usedPercent,
            resetsAt: limit.resetsAt,
            state: limit.state,
            observedAt: limit.observedAt,
            models: limit.models,
            extraUsage: limit.extraUsage
        )
    }

    private static let shortWindows: Set<String> = [
        "five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "daily", "monthly", "annual",
    ]

    /// A window's short name for a tag, the length first: 5h, 7d, 30d, "7d Fable".
    private static func windowName(_ limit: PlanLimitInfo, l10n: PrismL10n) -> String {
        if shortWindows.contains(limit.window) { return l10n.tr("agents.window.\(limit.window)") }
        // A model's or a group's window names it in its label, and a group's name ends in "Models".
        func scope(after prefix: String) -> String {
            let name = limit.label.hasPrefix(prefix) ? String(limit.label.dropFirst(prefix.count)) : limit.label
            return name.replacingOccurrences(of: #"\s+models?$"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        if limit.window.hasPrefix("seven_day_") {
            return l10n.tr("agents.window.weeklyOf", scope(after: "Weekly · "))
        }
        if limit.window.hasPrefix("five_hour_") {
            return l10n.tr("agents.window.fiveHourOf", scope(after: "5-hour · "))
        }
        let parts = limit.window.split(separator: "_")
        if parts.count == 2, let count = Int(parts[0]) {
            switch parts[1] {
            case "minute": return l10n.tr("agents.window.minutes", count)
            case "hour": return l10n.tr("agents.window.hours", count)
            case "day": return l10n.tr("agents.window.days", count)
            default: break
            }
        }
        return limit.label
    }

    /// Calendar days from now to a reset, so a day across a clock change still counts as one.
    private static func daysAhead(_ at: Date, _ now: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: at)).day ?? 0
    }

    /// When a limit resets, for a tag with little room: the time today, the weekday within six
    /// days, the date beyond.
    private static func resetDay(_ atMs: Double, nowMs: Double, l10n: PrismL10n) -> String {
        let at = Date(timeIntervalSince1970: atMs / 1000)
        let locale = l10n.language.resolvedLocale
        let days = daysAhead(at, Date(timeIntervalSince1970: nowMs / 1000))
        if days == 0 { return at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)) }
        if (1...6).contains(days) { return at.formatted(.dateTime.weekday(.abbreviated).locale(locale)) }
        return at.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    /// When a limit resets, in a sentence: the time today, with the weekday within six days, else
    /// the date.
    private static func resetTime(_ atMs: Double, nowMs: Double, l10n: PrismL10n) -> String {
        let at = Date(timeIntervalSince1970: atMs / 1000)
        let locale = l10n.language.resolvedLocale
        let days = daysAhead(at, Date(timeIntervalSince1970: nowMs / 1000))
        if days == 0 { return at.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)) }
        if (1...6).contains(days) {
            return at.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(locale))
        }
        return at.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    // MARK: No agent can start

    // Which reason is named first: installing Node.js serves every agent waiting for it.
    private static let reasonOrder = [
        "needs-node", "too-old", "needs-npm", "needs-uv", "cannot-run", "not-installed", "no-version",
    ]

    /// While no agent can start, what stops them; nil once one can start.
    static func noAgentCanStart(
        _ statuses: [AgentStatusInfo],
        entries: [String: AgentAvailabilityEntry]
    ) -> NoAgentReason? {
        if statuses.contains(where: { entries[$0.id]?.canStart == true }) { return nil }
        let stopped = statuses.compactMap { status in harnessReason(status).map { (status, $0) } }
        for kind in reasonOrder {
            let group = stopped.filter { $0.1.kind == kind }
            guard !group.isEmpty else { continue }
            var harnesses: [String] = []
            for (status, _) in group {
                let harness = status.harnessId ?? status.id
                if !harnesses.contains(harness) { harnesses.append(harness) }
            }
            return NoAgentReason(
                reason: sharedReason(group.map(\.1)),
                agents: group.map { $0.0.name },
                harnesses: harnesses
            )
        }
        return NoAgentReason(reason: nil, agents: [], harnesses: [])
    }

    /// The reason several agents share, said once: Node.js or uv at the newest minimum among them,
    /// which serves them all, and a too old program without a version when theirs differ.
    private static func sharedReason(_ reasons: [HarnessReason]) -> HarnessReason? {
        guard let first = reasons.first else { return nil }
        switch first {
        case .needsNode:
            let minimums = reasons.compactMap { reason -> String? in
                if case .needsNode(let minimum, _, _) = reason { return minimum }
                return nil
            }
            return .needsNode(minimum: newest(minimums), installed: nil, unreadable: false)
        case .needsUv:
            let minimums = reasons.compactMap { reason -> String? in
                if case .needsUv(let minimum, _) = reason { return minimum }
                return nil
            }
            return .needsUv(minimum: newest(minimums), installed: nil)
        case .tooOld(let minimum, _):
            let same = reasons.allSatisfy { reason in
                if case .tooOld(let other, _) = reason { return other == minimum }
                return false
            }
            return same ? first : .tooOld(minimum: "", installed: nil)
        case .cannotRun:
            return .cannotRun(why: "")
        default:
            return first
        }
    }

    private static func newest(_ versions: [String]) -> String? {
        versions.reduce(nil as String?) { top, version in
            guard let top else { return version }
            return isNewer(version, than: top) ? version : top
        }
    }

    /// Whether dotted version `a` is newer than `b`.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            (v.hasPrefix("v") ? String(v.dropFirst()) : v).split(separator: ".").map { Int($0) ?? 0 }
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p > q }
        }
        return false
    }
}
