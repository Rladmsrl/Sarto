import AppKit
import Foundation
import SartoProtocol
import Observation
import PrismDesign
import SwiftUI
import UsageCore

// MARK: - Prompt Cache Expiry (faithful port of src/shared/prompt-cache.ts)

enum IslandPromptCache {
    private static let minuteMs: Double = 60_000
    private static let hourMs: Double = 60 * 60_000

    static func cacheWindow(
        agentId: String,
        cache: PromptCacheInfo?,
        model: String?,
        account: AgentAccountInfo?
    ) -> IslandCacheWindow? {
        guard let cache else { return nil }
        if let ttl = cache.ttl {
            return IslandCacheWindow(
                expiresAt: cache.lastRequestAt + ttl,
                endingMs: endingWindow(ttl: ttl),
                estimate: false
            )
        }
        guard let documented = documentedTtl(provider: providerOf(agentId: agentId, model: model, account: account), model: model) else {
            return nil
        }
        return IslandCacheWindow(
            expiresAt: cache.lastRequestAt + documented,
            endingMs: endingWindow(ttl: documented),
            estimate: true
        )
    }

    private static func endingWindow(ttl: Double) -> Double {
        ttl >= hourMs ? 5 * minuteMs : minuteMs
    }

    private static func providerOf(agentId: String, model: String?, account: AgentAccountInfo?) -> String? {
        if agentId == "codex" {
            return (account?.kind == "account" || account?.kind == "api_key") ? "openai" : nil
        }
        if agentId == "claude-code" {
            return "anthropic"
        }
        if agentId == "antigravity", let model, model.lowercased().contains("claude") {
            return "anthropic"
        }
        if agentId == "opencode", let model, let slash = model.firstIndex(of: "/"), slash > model.startIndex {
            return String(model[..<slash]).lowercased()
        }
        return nil
    }

    private static func documentedTtl(provider: String?, model: String?) -> Double? {
        if provider == "anthropic" { return 5 * minuteMs }
        guard provider == "openai" else { return nil }
        if let model, isGpt55OrLater(model) { return 30 * minuteMs }
        return 5 * minuteMs
    }

    private static func isGpt55OrLater(_ model: String) -> Bool {
        let lower = model.lowercased()
        let base = lower.split(separator: "/").last.map(String.init) ?? lower
        guard base.hasPrefix("gpt-") else { return false }
        let rest = base.dropFirst(4)
        let parts = rest.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0.prefix(while: \.isNumber)) }) else { return false }
        let minor = parts.count > 1 ? (Int(parts[1].prefix(while: \.isNumber)) ?? 0) : 0
        return major > 5 || (major == 5 && minor >= 5)
    }
}

// MARK: - View Projection (faithful Swift port of src/main/island/view.ts & notices.ts)

enum IslandProjector {
    private static let finishedRowsLimit = 5
    private static let idleRowsLimit = 6
    private static let idleWithinMs: Double = 24 * 60 * 60_000
    private static let maxRequestLines = 6
    private static let maxLineChars = 240
    private static let fileToolKinds: Set<String> = ["read", "edit", "delete", "move"]

    /// Matches `listed` in `src/shared/session-groups.ts`: subagents and prepared sessions
    /// stay out of the island, and so do closed ones.
    static func isListed(_ summary: SessionSummary) -> Bool {
        summary.archivedAt == nil
            && summary.status != .closed
            && summary.origin != "subagent"
            && summary.prepared == nil
    }

    @MainActor
    static func buildSnapshot(
        state: SartoState,
        strings: IslandStrings,
        nowMs: Double,
        sources prebuilt: [LiveHostIslandSource]? = nil,
        eligibleProviderIds: Set<String>? = nil
    ) -> IslandViewSnapshot {
        let sources = prebuilt ?? state.allLiveHostSourcesForIsland()
        let multiHost = state.hasMultipleHosts

        struct TaggedSession {
            let source: LiveHostIslandSource
            let summary: SessionSummary
            let agentsById: [String: AgentStatusInfo]
        }

        var allTagged: [TaggedSession] = []
        var needsYouList: [TaggedSession] = []
        var runningList: [TaggedSession] = []
        var finishedList: [TaggedSession] = []
        var idleList: [TaggedSession] = []

        for source in sources {
            let agentsById = Dictionary(source.agents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for summary in source.sessions where isListed(summary) {
                let item = TaggedSession(source: source, summary: summary, agentsById: agentsById)
                allTagged.append(item)
                let waiting = summary.status == .awaitingPermission || summary.permissionCount > 0 || summary.status == .authRequired
                if waiting {
                    needsYouList.append(item)
                } else if summary.status == .running || summary.status == .starting
                            || summary.stillRunning?.hasWork == true {
                    runningList.append(item)
                } else if summary.status == .failed || summary.attention == "error" || summary.attention == "unread" {
                    finishedList.append(item)
                } else if summary.parentId == nil && (nowMs - summary.updatedAt) < idleWithinMs {
                    idleList.append(item)
                }
            }
        }

        func isFailure(_ summary: SessionSummary) -> Bool {
            summary.status == .failed || summary.attention == "error"
        }
        needsYouList.sort { $0.summary.updatedAt > $1.summary.updatedAt }
        runningList.sort { ($0.summary.turnStartedAt ?? $0.summary.updatedAt) > ($1.summary.turnStartedAt ?? $1.summary.updatedAt) }
        // Failures lead the finished group, so newer finished work on a busy host never pushes
        // one out of the capped list.
        finishedList.sort { lhs, rhs in
            let lFailed = isFailure(lhs.summary)
            let rFailed = isFailure(rhs.summary)
            if lFailed != rFailed { return lFailed }
            return lhs.summary.updatedAt > rhs.summary.updatedAt
        }
        idleList.sort { $0.summary.updatedAt > $1.summary.updatedAt }

        let ordered: [(TaggedSession, String)] =
            needsYouList.map { ($0, "needs_you") }
            + runningList.map { ($0, "running") }
            + finishedList.prefix(finishedRowsLimit).map { ($0, "finished") }
            + idleList.prefix(idleRowsLimit).map { ($0, "idle") }

        var rows: [IslandRowItem] = []
        var requests: [IslandPendingRequest] = []

        for (tagged, group) in ordered {
            let summary = tagged.summary
            let source = tagged.source
            let agent = tagged.agentsById[summary.agentId]
            let replica = source.replicas[summary.id]
            // Only a session that is waiting can hold a request; reading `pendingTools` walks the
            // whole thread, so the others skip it.
            let mayAsk = summary.permissionCount > 0 || summary.status == .awaitingPermission
            let pendingTools = mayAsk ? (replica?.pendingTools ?? []) : []
            // A session whose model runs on another computer is held by that computer's plan.
            let limit = summary.modelHost != nil ? nil : reachedLimit(
                agent: agent,
                agentConfig: source.agentOptionsById[summary.agentId]?.config,
                model: summary.model,
                nowMs: nowMs
            )
            let remoteHostName: String? = (multiHost && !source.isLocal) ? source.hostName : nil
            let scopedKey = "\(source.hostId)::\(summary.id)"
            let rowKey = source.isLocal ? summary.id : scopedKey

            let row = buildRow(
                rowKey: rowKey,
                hostId: source.hostId,
                hostName: remoteHostName,
                summary: summary,
                group: group,
                agent: agent,
                replica: replica,
                firstPendingTool: pendingTools.first,
                limit: limit,
                isUnread: summary.attention == "unread",
                strings: strings,
                nowMs: nowMs
            )
            rows.append(row)

            if mayAsk {
                for tool in pendingTools {
                    if let req = buildRequest(
                        tool: tool,
                        summary: summary,
                        rowKey: row.key,
                        hostId: source.hostId,
                        hostName: remoteHostName,
                        strings: strings
                    ) {
                        requests.append(req)
                    }
                }
            }
        }

        requests.sort { ($0.askedAt ?? Double.infinity) < ($1.askedAt ?? Double.infinity) }

        let midnight = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: nowMs / 1000)).timeIntervalSince1970 * 1000
        let todayCount = allTagged.filter { $0.summary.parentId == nil && $0.summary.updatedAt >= midnight }.count
        let shownFailed = rows.filter { $0.status == "failed" }.count
        let cappedFailed = finishedList.dropFirst(finishedRowsLimit).filter { isFailure($0.summary) }.count
        let summaryCounts = IslandSummaryCounts(
            running: rows.filter { $0.status == "running" || $0.status == "starting" }.count,
            waiting: rows.filter { $0.status == "waiting" || $0.status == "sign_in" }.count,
            failed: shownFailed + cappedFailed,
            today: todayCount
        )

        // Plan windows are this Mac's first, as the usage the island shows is this Mac's; the
        // active host adds the agents this Mac does not have.
        let planAgents = limitAgents(state: state, sources: sources)
        let notices = buildLimitNotices(
            agents: planAgents,
            strings: strings,
            nowMs: nowMs,
            eligibleProviderIds: eligibleProviderIds
        )
        var quotas: [String: [IslandQuotaWindow]] = [:]
        for agent in planAgents {
            let windows = (agent.limits ?? []).compactMap { limit -> IslandQuotaWindow? in
                if let resets = limit.resetsAt, resets <= nowMs { return nil }
                let used = limit.state == "reached" ? 100 : (limit.usedPercent ?? 0)
                return IslandQuotaWindow(
                    label: limit.label,
                    remaining: max(0, min(1, 1 - used / 100)),
                    resetsAt: limit.resetsAt
                )
            }
            if !windows.isEmpty { quotas[agent.id] = windows }
        }

        return IslandViewSnapshot(
            rows: rows,
            requests: requests,
            notices: notices,
            summary: summaryCounts,
            telemetry: buildTelemetry(state: state),
            quotas: quotas
        )
    }

    @MainActor
    private static func limitAgents(state: SartoState, sources: [LiveHostIslandSource]) -> [AgentStatusInfo] {
        guard let local = sources.first(where: \.isLocal), local.hostId != state.activeHostID else {
            return state.agents
        }
        let localIds = Set(local.agents.map(\.id))
        return local.agents + state.agents.filter { !localIds.contains($0.id) }
    }

    /// The selected session's live metrics. Reading them registers the coordinator's telemetry
    /// observation, which updates only `PrismIslandModel.telemetry`, never the rows.
    @MainActor
    static func buildTelemetry(state: SartoState) -> IslandLiveTelemetry? {
        let hasMetric = state.currentTPS != nil
            || state.currentCacheHit != nil
            || state.activeContextTotal > 0
            || state.activeIsStreaming
        guard hasMetric else { return nil }
        return IslandLiveTelemetry(
            sessionId: state.selectedSessionSummary?.id,
            tps: state.currentTPS,
            tpsIsApprox: state.currentTPSIsApprox,
            cacheHitPercent: state.currentCacheHit ?? state.currentSessionCacheHit,
            contextFillRatio: state.activeContextFill,
            contextUsed: state.activeContextUsed,
            contextTotal: state.activeContextTotal,
            isStreaming: state.activeIsStreaming
        )
    }

    private static func buildRow(
        rowKey: String,
        hostId: String?,
        hostName: String?,
        summary: SessionSummary,
        group: String,
        agent: AgentStatusInfo?,
        replica: ThreadReplica?,
        firstPendingTool: ToolEntryData?,
        limit: PlanLimitInfo?,
        isUnread: Bool,
        strings: IslandStrings,
        nowMs: Double
    ) -> IslandRowItem {
        let waiting = summary.status == .awaitingPermission || summary.permissionCount > 0
        // A turn refused by a window that is still used up reads as that limit, not as a failure.
        let endedLimit: LastTurnLimit? = summary.lastTurn.flatMap { last in
            guard last.reason == .limit, let window = last.limit, window.holds(nowMs: nowMs) else { return nil }
            return window
        }
        let status: String
        var shownLimit = limit.map { IslandLimitSnapshot(label: $0.label, resetsAt: $0.resetsAt) }
        if waiting {
            status = "waiting"
        } else if summary.status == .running {
            status = "running"
        } else if summary.status == .starting {
            status = "starting"
        } else if summary.status == .authRequired {
            status = "sign_in"
        } else if summary.status == .failed || summary.attention == "error" {
            if let endedLimit {
                status = "limited"
                shownLimit = IslandLimitSnapshot(label: endedLimit.label, resetsAt: endedLimit.resetsAt)
            } else {
                status = "failed"
            }
        } else if limit != nil {
            status = "limited"
        } else if isUnread {
            status = "unread"
        } else {
            status = "idle"
        }

        let agentName = agent?.name ?? defaultAgentName(summary.agentId)
        let identity = IslandAgentIdentity(
            id: summary.agentId,
            name: agentName,
            harness: agent?.harnessId ?? summary.agentId,
            color: agent?.color
        )

        let backgroundWork: StillRunningInfo? = ["running", "starting", "waiting", "sign_in"].contains(status)
            ? nil
            : summary.stillRunning.flatMap { $0.hasWork ? $0 : nil }

        let phase = status == "running" ? resolvedPhase(summary) : nil
        let line: String
        switch status {
        case "waiting":
            line = waitingLine(tool: firstPendingTool, projectPath: summary.projectPath, strings: strings)
        case "running":
            line = runningLine(summary: summary, phase: phase, strings: strings)
        case "sign_in":
            line = strings.text("line.signIn", ["agent": agentName])
        case "limited":
            line = strings.text("line.limited", ["window": shownLimit?.label ?? ""])
        case "starting":
            line = strings.text("line.starting")
        default:
            if let still = backgroundWork, status == "idle" || status == "unread" {
                line = backgroundLine(still, strings: strings)
            } else {
                line = endingLine(summary.lastTurn, strings: strings) ?? strings.text("line.\(status)")
            }
        }

        let cacheInfo = summary.cache ?? replica?.session.usage?.cache
        let cache = status == "running"
            ? nil
            : IslandPromptCache.cacheWindow(
                agentId: summary.agentId,
                cache: cacheInfo,
                model: summary.model,
                account: agent?.account
            )

        let projectName = (summary.scratch == true || summary.projectPath.isEmpty)
            ? ""
            : URL(fileURLWithPath: summary.projectPath).lastPathComponent

        // Hide completed plans (e.g. 4/4) so the island falls back to live tok/s or elapsed time
        // until a new incomplete plan starts. Include full step items from the cached replica when
        // available so the right-hand running rail can show the complete Todo battle list.
        let showsPlan = backgroundWork != nil || ["running", "starting", "waiting", "sign_in"].contains(status)
        let planSnapshot: IslandPlanSnapshot? = showsPlan
            ? Self.buildPlanSnapshot(summaryPlan: summary.plan, replica: replica)
            : nil

        let since = status == "running" ? (summary.turnStartedAt ?? summary.updatedAt) : summary.updatedAt

        return IslandRowItem(
            key: rowKey,
            sessionId: summary.id,
            title: summary.title ?? "",
            project: projectName,
            agent: identity,
            model: summary.model,
            group: group,
            status: status,
            since: since,
            line: line,
            toolSince: status == "running" ? summary.activity?.startedAt : nil,
            toolKind: status == "running" ? summary.activity?.toolKind : nil,
            turnStartedAt: summary.turnStartedAt,
            plan: planSnapshot,
            limit: shownLimit,
            phase: phase,
            cache: cache,
            isSubagent: summary.parentId != nil,
            hostId: hostId,
            hostName: hostName,
            background: backgroundWork != nil
        )
    }

    private static func backgroundLine(_ still: StillRunningInfo, strings: IslandStrings) -> String {
        if still.commands > 0 && still.subagents > 0 {
            return strings.text("line.backgroundBoth", [
                "commands": String(still.commands),
                "subagents": String(still.subagents),
            ])
        }
        if still.commands > 0 {
            let key = still.commands == 1 ? "line.commands_one" : "line.commands_other"
            return strings.text(key, ["count": String(still.commands)])
        }
        let key = still.subagents == 1 ? "line.subagents_one" : "line.subagents_other"
        return strings.text(key, ["count": String(still.subagents)])
    }

    private static func buildPlanSnapshot(
        summaryPlan: PlanProgress?,
        replica: ThreadReplica?
    ) -> IslandPlanSnapshot? {
        if let summaryPlan, summaryPlan.total == 0 || summaryPlan.done >= summaryPlan.total {
            return nil
        }
        var replicaItems: [PlanItem]? = replica?.snapshotPlan
        // The newest plan entry wins; a long thread is read from its end, not walked whole.
        if let replica {
            for id in replica.order.reversed() {
                if case .plan(_, let items)? = replica.byId[id], !items.isEmpty {
                    replicaItems = items
                    break
                }
            }
        }

        let mappedReplicaSteps: [IslandPlanStep]? = replicaItems.flatMap { items in
            guard !items.isEmpty else { return nil }
            return items.enumerated().map { idx, item in
                IslandPlanStep(index: idx, content: item.content, status: item.status)
            }
        }

        if let summaryPlan {
            guard summaryPlan.total > 0, summaryPlan.done < summaryPlan.total else { return nil }
            if let steps = mappedReplicaSteps,
               steps.count == summaryPlan.total {
                let replicaDone = steps.filter { $0.status == "completed" }.count
                if replicaDone == summaryPlan.done || replicaDone > summaryPlan.done {
                    let activeText = steps.first(where: { $0.status == "in_progress" })?.content
                        ?? steps.first(where: { $0.status != "completed" })?.content
                        ?? summaryPlan.current?.text
                    return IslandPlanSnapshot(
                        done: replicaDone,
                        total: steps.count,
                        current: activeText,
                        items: steps
                    )
                }
            }
            return IslandPlanSnapshot(
                done: summaryPlan.done,
                total: summaryPlan.total,
                current: summaryPlan.current?.text,
                items: []
            )
        }

        if let steps = mappedReplicaSteps {
            let done = steps.filter { $0.status == "completed" }.count
            guard done < steps.count else { return nil }
            let activeText = steps.first(where: { $0.status == "in_progress" })?.content
                ?? steps.first(where: { $0.status != "completed" })?.content
            return IslandPlanSnapshot(
                done: done,
                total: steps.count,
                current: activeText,
                items: steps
            )
        }

        return nil
    }

    private static func buildRequest(
        tool: ToolEntryData,
        summary: SessionSummary,
        rowKey: String,
        hostId: String?,
        hostName: String?,
        strings: IslandStrings
    ) -> IslandPendingRequest? {
        guard let permission = tool.permission else { return nil }
        let key = "\(rowKey)#\(tool.id)"

        // Question card (single-select non-secret questions can be answered directly from the island)
        if let questions = permission.questions, let first = questions.first {
            if questions.count > 1 || first.multiSelect || first.secret {
                return IslandPendingRequest(
                    key: key,
                    sessionId: summary.id,
                    requestId: permission.requestId,
                    rowKey: rowKey,
                    kind: "sarto",
                    title: strings.text(questions.count > 1 ? "request.questions" : "request.question"),
                    lines: [clip(first.question)],
                    code: false,
                    options: [],
                    askedAt: summary.updatedAt,
                    isDemo: false,
                    hostId: hostId,
                    hostName: hostName
                )
            }
            let opts = first.options.enumerated().map { idx, opt in
                IslandRequestOption(
                    id: "q\(idx)",
                    label: clip(opt.label),
                    style: "normal",
                    questionIndex: 0,
                    choiceIndex: idx
                )
            }
            return IslandPendingRequest(
                key: key,
                sessionId: summary.id,
                requestId: permission.requestId,
                rowKey: rowKey,
                kind: "question",
                title: strings.text("request.question"),
                lines: [clip(first.question)],
                code: false,
                options: opts,
                askedAt: summary.updatedAt,
                isDemo: false,
                hostId: hostId,
                hostName: hostName
            )
        }

        // Plan approval card
        if let plan = permission.plan {
            let choices = permission.options.filter { $0.note != true }
            let opts = choices.map { opt -> IslandRequestOption in
                let style = opt.preferred == true ? "recommended" : optionStyle(for: opt.kind)
                return IslandRequestOption(
                    id: opt.id,
                    label: clip(opt.name.replacingOccurrences(of: "`", with: "")),
                    style: style,
                    questionIndex: nil,
                    choiceIndex: nil
                )
            }
            let lines = plan.markdown
                .split(separator: "\n")
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    let stripped = trimmed.replacingOccurrences(
                        of: #"^(#+|[-*]|\d+\.)\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    return clip(stripped)
                }
                .filter { !$0.isEmpty }
                .prefix(maxRequestLines)
            return IslandPendingRequest(
                key: key,
                sessionId: summary.id,
                requestId: permission.requestId,
                rowKey: rowKey,
                kind: "plan",
                title: strings.text("request.plan"),
                lines: Array(lines),
                code: false,
                options: opts,
                askedAt: summary.updatedAt,
                isDemo: false,
                hostId: hostId,
                hostName: hostName
            )
        }

        // Standard tool permission card: deny / allow_once / allow_always
        let deny = permission.options.first { $0.kind == "reject_once" }
            ?? permission.options.first { $0.kind == "reject_always" }
        let once = permission.options.first { $0.kind == "allow_once" }
        let always = permission.options.first { $0.kind == "allow_always" }
        let orderedChoices = [deny, once, always].compactMap { $0 }
        let opts = orderedChoices.map { opt -> IslandRequestOption in
            let style = optionStyle(for: opt.kind)
            let label: String
            switch style {
            case "deny": label = strings.text("request.answer.deny")
            case "allow_once": label = strings.text("request.answer.allowOnce")
            case "allow_always": label = strings.text("request.answer.allowAlways")
            default: label = clip(opt.name.replacingOccurrences(of: "`", with: ""))
            }
            return IslandRequestOption(
                id: opt.id,
                label: label,
                style: style,
                questionIndex: nil,
                choiceIndex: nil
            )
        }

        let toolKey = toolLocalizationKey(tool.toolKind)
        let title = strings.text("request.tool.\(toolKey)")
        if tool.toolKind == "execute" {
            let cmd = tool.rawInput ?? tool.title.replacingOccurrences(
                of: #"^run\s+"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            let lines = cmd.split(separator: "\n")
                .map { clip(String($0)) }
                .filter { !$0.isEmpty }
                .prefix(maxRequestLines)
            return IslandPendingRequest(
                key: key,
                sessionId: summary.id,
                requestId: permission.requestId,
                rowKey: rowKey,
                kind: "permission",
                title: title,
                lines: Array(lines),
                code: true,
                options: opts,
                askedAt: summary.updatedAt,
                isDemo: false,
                hostId: hostId,
                hostName: hostName
            )
        }

        let files = fileToolKinds.contains(tool.toolKind)
            ? tool.locations.map { shownPath($0.path, projectPath: summary.projectPath) }
            : []
        let lines = files.isEmpty ? [clip(tool.title)] : Array(files.prefix(maxRequestLines))
        return IslandPendingRequest(
            key: key,
            sessionId: summary.id,
            requestId: permission.requestId,
            rowKey: rowKey,
            kind: "permission",
            title: title,
            lines: lines,
            code: false,
            options: opts,
            askedAt: summary.updatedAt,
            isDemo: false,
            hostId: hostId,
            hostName: hostName
        )
    }

    @MainActor
    private static func buildLimitNotices(
        agents: [AgentStatusInfo],
        strings: IslandStrings,
        nowMs: Double,
        eligibleProviderIds: Set<String>? = nil
    ) -> [IslandNoticeItem] {
        var best: (agent: AgentStatusInfo, limit: PlanLimitInfo, used: Double)?
        for agent in agents {
            if let eligibleProviderIds {
                guard let providerId = LiveUsageSources.providerId(forAgentId: agent.id, harnessId: agent.harnessId),
                      eligibleProviderIds.contains(providerId)
                else { continue }
            }
            for limit in agent.limits ?? [] {
                if let resets = limit.resetsAt, resets <= nowMs { continue }
                let reached = limit.state == "reached"
                let pct = limit.usedPercent ?? 0
                guard reached || pct >= 90 else { continue }
                let score = reached ? Double.infinity : pct
                if best == nil || score > best!.used {
                    best = (agent, limit, score)
                }
            }
        }
        guard let best else { return [] }
        let reached = best.limit.state == "reached"
        let pct = reached ? 100.0 : round(best.limit.usedPercent ?? 0)
        let trailing: String? = best.limit.resetsAt.map { resetsAt in
            strings.text("notice.resets", ["time": formatResetShort(resetsAtMs: resetsAt, nowMs: nowMs, localeId: strings.localeIdentifier)])
        }
        let mark = IslandAgentIdentity(
            id: best.agent.id,
            name: best.agent.name,
            harness: best.agent.harnessId ?? best.agent.id,
            color: best.agent.color
        )
        return [
            IslandNoticeItem(
                key: "limit",
                kind: "limit",
                marks: [mark],
                title: best.agent.account?.label ?? best.agent.name,
                detail: best.limit.label,
                meter: IslandNoticeMeter(
                    percent: pct,
                    reached: reached,
                    text: reached ? strings.text("notice.usedUp") : "\(Int(pct))%"
                ),
                trailing: trailing
            )
        ]
    }

    /// A used-up window that counts on the session's model holds it
    /// back, unless extra usage covers it.
    private static func reachedLimit(
        agent: AgentStatusInfo?,
        agentConfig: [ConfigOption]?,
        model: String?,
        nowMs: Double
    ) -> PlanLimitInfo? {
        guard let limits = agent?.limits, !limits.isEmpty else { return nil }
        let scoped = PlanLimitScope.limits(limits, agentConfig: agentConfig, model: model)
        return PlanLimitScope.heldBack(scoped, nowMs: nowMs)
    }

    /// How a finished row reads its last turn's ending; nil for a plain end or none.
    static func endingLine(_ last: LastTurn?, strings: IslandStrings) -> String? {
        guard let last else { return nil }
        switch last.reason {
        case .failed: return last.errorLine.map(clip)
        case .limit:
            return last.limit.map { strings.text("line.limitEnded", ["window": $0.label]) } ?? last.errorLine.map(clip)
        case .cancelled: return strings.text("line.cancelled")
        case .maxTokens: return strings.text("line.maxTokens")
        case .maxTurnRequests: return strings.text("line.maxTurnRequests")
        case .refusal: return strings.text("line.refusal")
        case .endTurn, .unknown: return nil
        }
    }

    /// The pop a turn that just ended raises for its ending: an error, the limit that refused it
    /// with its reset, or a turn-ended pop saying why it stopped; nil for a plain end or none.
    @MainActor
    static func endingPop(_ last: LastTurn?, strings: IslandStrings, nowMs: Double) -> (kind: String, body: String)? {
        guard let last else { return nil }
        switch last.reason {
        case .failed:
            return ("error", last.errorLine.map(clip) ?? strings.text("pop.errorBody"))
        case .limit:
            guard let window = last.limit else {
                return ("error", last.errorLine.map(clip) ?? strings.text("pop.errorBody"))
            }
            if let resetsAt = window.resetsAt, resetsAt > nowMs {
                let time = formatResetShort(resetsAtMs: resetsAt, nowMs: nowMs, localeId: strings.localeIdentifier)
                return ("limit-reached", strings.text("pop.limitEnded", ["window": window.label, "time": time]))
            }
            return ("limit-reached", strings.text("line.limited", ["window": window.label]))
        case .cancelled, .maxTokens, .maxTurnRequests, .refusal:
            return endingLine(last, strings: strings).map { ("turn-ended", $0) }
        case .endTurn, .unknown:
            return nil
        }
    }

    private static func resolvedPhase(_ summary: SessionSummary) -> String {
        switch summary.phase {
        case "thinking": return "think"
        case "execute", "working": return "execute"
        case "read": return "read"
        case "search": return "search"
        case "fetch": return "fetch"
        case "edit": return "edit"
        case "writing": return "write"
        case "compacting": return "compact"
        default:
            switch summary.activity?.toolKind {
            case "read": return "read"
            case "search": return "search"
            case "fetch": return "fetch"
            case "edit", "delete", "move": return "edit"
            default: return "execute"
            }
        }
    }

    private static func runningLine(summary: SessionSummary, phase: String?, strings: IslandStrings) -> String {
        if phase == "compact" { return strings.text("line.compacting") }
        if let act = summary.activity {
            return toolLine(kind: act.toolKind, title: act.title, detail: act.detail, projectPath: summary.projectPath, strings: strings)
        }
        if phase == "think" { return strings.text("line.thinking") }
        if phase == "write" { return strings.text("line.writing") }
        return strings.text("line.working")
    }

    private static func waitingLine(tool: ToolEntryData?, projectPath: String, strings: IslandStrings) -> String {
        guard let tool else { return strings.text("request.other") }
        if let q = tool.permission?.questions?.first?.question {
            return strings.text("line.question", ["question": clip(q)])
        }
        if tool.permission?.plan != nil {
            return strings.text("request.plan")
        }
        let detail = tool.toolKind == "execute"
            ? tool.rawInput?.split(separator: "\n").first.map(String.init)
            : tool.locations.first?.path
        return toolLine(kind: tool.toolKind, title: tool.title, detail: detail, projectPath: projectPath, strings: strings)
    }

    private static func toolLine(
        kind: String,
        title: String,
        detail: String?,
        projectPath: String,
        strings: IslandStrings
    ) -> String {
        if kind == "execute" {
            let cmd = detail ?? title.replacingOccurrences(of: #"^run\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            return strings.text("line.run", ["command": clip(cmd)])
        }
        if fileToolKinds.contains(kind), let detail, !detail.isEmpty {
            return strings.text("line.\(kind)", ["path": shownPath(detail, projectPath: projectPath)])
        }
        if (kind == "search" || kind == "fetch"), let detail, !detail.isEmpty {
            return strings.text("line.\(kind)", ["text": clip(detail)])
        }
        return clip(title)
    }

    private static func toolLocalizationKey(_ kind: String) -> String {
        switch kind {
        case "read", "edit", "delete", "move", "search", "execute", "fetch": return kind
        case "switch_mode": return "switchMode"
        default: return "other"
        }
    }

    private static func optionStyle(for kind: String) -> String {
        switch kind {
        case "allow_once": return "allow_once"
        case "allow_always": return "allow_always"
        case "reject_once", "reject_always": return "deny"
        default: return "normal"
        }
    }

    private static func clip(_ text: String) -> String {
        let squashed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard squashed.count > maxLineChars else { return squashed }
        return String(squashed.prefix(maxLineChars - 1)) + "…"
    }

    private static func shownPath(_ path: String, projectPath: String) -> String {
        guard !projectPath.isEmpty, path.hasPrefix(projectPath) else { return path }
        let suffix = path.dropFirst(projectPath.count)
        if suffix.hasPrefix("/") { return String(suffix.dropFirst()) }
        return path
    }

    private static func defaultAgentName(_ agentId: String) -> String {
        switch agentId {
        case "antigravity": return "Antigravity"
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "pi": return "Pi"
        default: return agentId
        }
    }

    @MainActor
    private static func formatResetShort(resetsAtMs: Double, nowMs: Double, localeId: String) -> String {
        IslandDateFormatters.formatResetShort(resetsAtMs: resetsAtMs, nowMs: nowMs, localeId: localeId)
    }
}

@MainActor
private enum IslandDateFormatters {
    private static var cache: [String: DateFormatter] = [:]

    /// A time within 20 hours, a weekday within six days (never today's), a date beyond.
    static func formatResetShort(resetsAtMs: Double, nowMs: Double, localeId: String) -> String {
        let left = resetsAtMs - nowMs
        let template = left < 20 * 3600 * 1000 ? "jmm" : (left < 6 * 24 * 3600 * 1000 ? "EEE" : "MMMd")
        let key = "\(localeId)|\(template)"
        let formatter: DateFormatter
        if let existing = cache[key] {
            formatter = existing
        } else {
            let built = DateFormatter()
            built.locale = Locale(identifier: localeId)
            built.setLocalizedDateFormatFromTemplate(template)
            cache[key] = built
            formatter = built
        }
        return formatter.string(from: Date(timeIntervalSince1970: resetsAtMs / 1000))
    }
}

// MARK: - Reactive Island State Machine (ported from native/island/Sources/Model.swift)

@MainActor
@Observable
final class PrismIslandModel {
    private(set) var mode: IslandMode = .hidden
    private(set) var collapsed: IslandCollapsedState?
    // Narrow copy of `collapsed` for the chassis: its rim depends on this alone, so a fact that
    // changes at token rate (tok/s) only re-renders the collapsed content.
    private(set) var collapsedSignal: IslandSignal?
    /// Sarto is in front with its running panel and the island has nothing more urgent than
    /// what the panel shows: it keeps to the notch.
    private(set) var collapsedQuiet: Bool = false
    /// Set by the coordinator: Sarto's main window is in front and the running panel is on.
    var quietForeground: Bool = false
    private(set) var pop: IslandPopItem? {
        didSet { updateChassis() }
    }
    private(set) var queuedPops: Int = 0
    private(set) var note: IslandAnswerNote?
    private(set) var pendingRequestKeys: Set<String> = []
    private(set) var now: Date = Date()

    // The snapshot's parts are observed apart, so a view that reads the counts does not redraw
    // when a row's text changes. Live telemetry is kept in `telemetry` for the same reason.
    private(set) var rows: [IslandRowItem] = []
    private var snapshotRequests: [IslandPendingRequest] = []
    private(set) var notices: [IslandNoticeItem] = []
    private(set) var summary = IslandSummaryCounts(running: 0, waiting: 0, failed: 0, today: 0)
    private(set) var quotas: [String: [IslandQuotaWindow]] = [:]
    private(set) var telemetry: IslandLiveTelemetry? = nil

    // What the chassis shows, kept as stored values so the root view, which every display
    // renders, does not depend on the rows or on the 1 Hz clock; `updateChassis` refreshes them.
    private(set) var auraState: IslandAuraState = .calm
    private(set) var isIdleForUsage = true
    /// The daemon is not connected, so an empty list says so instead of "no sessions yet".
    var hostOffline = false
    /// Real-time active channel/model context projected from `SartoState` for usage focus resolution.
    var appUsageFocus: AppUsageFocusContext? = nil
    var demoRequest: IslandPendingRequest? = nil {
        didSet { updateChassis() }
    }

    private(set) var strings: IslandStrings = IslandStrings(language: .system)
    var geometry = IslandGeometry()
    /// Assigned only when its inputs change (`PrismTokens` is not Equatable).
    var prismTokens: PrismTokens = .resolved(palette: .obsidian)
    /// Displays offered by the island's context menu, refreshed when screens or settings change
    /// so the menu never enumerates screens during a body pass.
    var displayMenuItems: [IslandDisplayMenuItem] = []
    /// The island picks its display itself (no display chosen in Settings).
    var displaysAutomatic = true
    var suspended: Bool = false
    var hasLowUsageAlert: Bool = false
    var userPinnedTab: IslandExpandedTab? = nil
    var activeScreenID: UInt32? = nil
    var reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    /// The app's motion tier, which caps the island's own animation style.
    var motionTier: PrismMotionTier = .ultra
    var selectedRowKey: String? = nil
    /// How the running animations move; the coordinator copies it from the settings.
    var motionStyle: IslandMotionStyle = .lively
    /// Plan windows the usage store reads (the menu bar's), by its provider id: only the providers
    /// whose quota shows (installed, used within 30 days, measured).
    var usageQuotas: [String: [IslandQuotaWindow]] = [:]
    /// Those providers' names, by provider id.
    var usageQuotaNames: [String: String] = [:]
    /// The usage store answered once, so `usageQuotas` decides which quotas show.
    var usageReady = false
    var panelHeight: CGFloat = 0
    private var panelHeightsByScreen: [UInt32: CGFloat] = [:]
    var measuring: Bool = false
    /// Screen currently measuring the expanded body, so multi-monitor setups never mount duplicate
    /// hidden measurement trees or clobber another screen's measured height.
    var measuringScreenID: UInt32? = nil

    private(set) var opener: IslandOpener = .hover
    var openedByClick: Bool { opener == .click }
    var pointerInside: Bool = false

    weak var actionSink: (any IslandActionSink)?
    var onModeChange: ((IslandMode) -> Void)?
    var onAnnounce: ((String) -> Void)?
    var onHitAreaChange: (() -> Void)?

    private let stuckAfterMs: Double = 5 * 60_000
    private var pops: [IslandPopItem] = []
    private var nextPopId = 1
    @ObservationIgnored private nonisolated(unsafe) var popTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var tickTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var noteTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var stuckTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var cacheTimer: Timer?
    @ObservationIgnored private nonisolated(unsafe) var measureTimeout: Timer?
    @ObservationIgnored private nonisolated(unsafe) var expandWorkItem: DispatchWorkItem?
    @ObservationIgnored private var cacheTickDue: Date?
    @ObservationIgnored private var stuckCheckDue: Date?
    private var seenDoneKeys: Set<String> = []

    deinit {
        popTimer?.invalidate()
        tickTimer?.invalidate()
        noteTimer?.invalidate()
        stuckTimer?.invalidate()
        cacheTimer?.invalidate()
        measureTimeout?.invalidate()
        expandWorkItem?.cancel()
    }

    // MARK: Derived Views

    var snapshot: IslandViewSnapshot {
        IslandViewSnapshot(
            rows: rows,
            requests: snapshotRequests,
            notices: notices,
            summary: summary,
            telemetry: nil,
            quotas: quotas
        )
    }

    var listRows: [IslandRowItem] { Array(rows.prefix(IslandMetrics.listRows)) }

    var requests: [IslandPendingRequest] {
        if let demo = demoRequest {
            return [demo] + snapshotRequests
        }
        return snapshotRequests
    }

    var asking: Bool { note != nil || !requests.isEmpty }

    /// Calm when no Sarto session is active/waiting/failed/unread and no prompt cache is expiring soon.
    /// In this state the collapsed island seamlessly switches to the live llm-usage-island dual-bar meter.
    private var computedIdleForUsage: Bool {
        !collapsedQuiet
            && collapsedSignal == nil
            && cacheLeft(rows.first?.cache)?.ending != true
            && requests.isEmpty
    }

    var effectiveExpandedTab: IslandExpandedTab {
        if let userPinnedTab { return userPinnedTab }
        if summary.running > 0
            || summary.waiting > 0
            || summary.failed > 0
            || collapsedSignal == .unread
        {
            return .sessions
        }
        return .usage
    }

    func effectiveMode(for screenID: UInt32) -> IslandMode {
        if mode == .hidden { return .hidden }
        if mode == .open, let activeScreenID, activeScreenID != screenID {
            return .collapsed
        }
        return mode
    }

    func openWidth(for g: IslandGeometry) -> CGFloat {
        max(IslandMetrics.openWidth, g.notchWidth + IslandMetrics.openWings)
    }

    func middleWidth(for g: IslandGeometry) -> CGFloat {
        g.hasNotch ? g.notchWidth : IslandMetrics.plainMiddle
    }

    var openWidth: CGFloat { openWidth(for: geometry) }
    var middleWidth: CGFloat { middleWidth(for: geometry) }

    /// Active whenever at least one session is actively running and not blocked by an approval/error
    /// so the collapsed Dynamic Island displays the Scheme C duplex pulse crossfire (App ⇄ Agents).
    var isRunningStrikeActive: Bool {
        guard !collapsedQuiet,
              !computedIdleForUsage,
              let sig = collapsedSignal,
              case .running = sig
        else { return false }
        return true
    }

    /// Plan windows for an agent, as the window's running rail shows them: the menu bar's reading
    /// for the agent's tool; before the usage store first answers, what the host reports.
    func quotaWindows(for agent: IslandAgentIdentity) -> [IslandQuotaWindow] {
        if let provider = LiveUsageSources.providerId(forAgentId: agent.id, harnessId: agent.harness),
           let windows = usageQuotas[provider], !windows.isEmpty
        {
            return Array(windows.prefix(2))
        }
        if usageReady { return [] }
        return Array((quotas[agent.id] ?? []).prefix(2))
    }

    func collapsedWingWidth(for g: IslandGeometry) -> CGFloat {
        guard g.hasNotch else { return 0 }
        return max(
            IslandMetrics.collapsedNotchWing,
            ((IslandMetrics.collapsedWidth - g.notchWidth) / 2).rounded(.up)
        )
    }

    func collapsedWidth(for g: IslandGeometry) -> CGFloat {
        if g.hasNotch {
            return g.notchWidth + 2 * collapsedWingWidth(for: g)
        }
        return IslandMetrics.collapsedWidth
    }

    private var computedAura: IslandAuraState {
        if mode == .grown, let pop {
            switch pop.kind {
            case "error", "limit-reached": return .failed
            case "permission", "limit-near": return .waiting
            case "turn-ended": return .done
            default: break
            }
        }
        if !requests.isEmpty || summary.waiting > 0 { return .waiting }
        if summary.failed > 0 && collapsedSignal == .failed { return .failed }
        if summary.running > 0 { return .running }
        if collapsedSignal == .unread { return .done }
        return .calm
    }

    /// Writes the chassis values that changed; called wherever their inputs change.
    private func updateChassis() {
        let aura = computedAura
        if auraState != aura { auraState = aura }
        let idle = computedIdleForUsage
        if isIdleForUsage != idle { isIdleForUsage = idle }
    }

    func row(for key: String?) -> IslandRowItem? {
        guard let key else { return nil }
        return rows.first { $0.key == key }
    }

    func status(of row: IslandRowItem) -> String {
        if row.status == "running",
           let since = row.toolSince,
           now.timeIntervalSince1970 * 1000 - since > stuckAfterMs
        {
            return "stuck"
        }
        return row.status
    }

    func signal(of row: IslandRowItem) -> IslandSignal? {
        switch status(of: row) {
        case "waiting", "sign_in": return .waiting
        case "failed": return .failed
        case "running": return .running(IslandTurnDots.Pattern(phase: row.phase))
        case "starting": return .running(.think)
        case "stuck": return .stuck
        case "limited": return .limited
        case "unread": return .unread
        default: return nil
        }
    }

    func title(of row: IslandRowItem) -> String {
        row.title.isEmpty ? strings.text("untitled") : row.title
    }

    var summaryText: String {
        let s = summary
        var items: [String] = []
        let waitTotal = max(s.waiting, requests.count)
        if waitTotal > 0 { items.append(strings.text("summary.waiting", ["count": "\(waitTotal)"])) }
        if s.running > 0 { items.append(strings.text("summary.running", ["count": "\(s.running)"])) }
        if s.failed > 0 { items.append(strings.text("summary.failed", ["count": "\(s.failed)"])) }
        let done = rows.filter { $0.status == "unread" }.count
        if done > 0 { items.append(strings.text("summary.done", ["count": "\(done)"])) }
        if items.isEmpty && s.today > 0 {
            items.append(strings.text("today", ["count": "\(s.today)"]))
        }
        return items.joined(separator: " · ")
    }

    var islandAccessibilityLabel: String {
        let summary = summaryText
        return strings.text("a11y.island", ["summary": summary.isEmpty ? strings.text("a11y.quiet") : summary])
    }

    // MARK: Sizing

    func panelHeight(for screenID: UInt32?) -> CGFloat {
        if let screenID, let h = panelHeightsByScreen[screenID] {
            return h
        }
        return panelHeight
    }

    func setPanelHeight(_ height: CGFloat, for screenID: UInt32? = nil) {
        if let screenID {
            let prev = panelHeightsByScreen[screenID] ?? 0
            if abs(height - prev) > 0.5 {
                panelHeightsByScreen[screenID] = height
            }
        }
        guard abs(height - panelHeight) > 0.5 else { return }
        panelHeight = height
    }

    func frameSize(for g: IslandGeometry, mode targetMode: IslandMode? = nil, screenID: UInt32? = nil) -> CGSize {
        let m = targetMode ?? mode
        switch m {
        case .hidden:
            return CGSize(width: max(g.notchWidth, 1), height: g.notchHeight)
        case .collapsed:
            if collapsedQuiet {
                return CGSize(width: max(g.notchWidth, 1), height: g.notchHeight)
            }
            return CGSize(width: collapsedWidth(for: g), height: g.notchHeight)
        case .grown:
            return CGSize(
                width: max(IslandMetrics.grownWidth, collapsedWidth(for: g)),
                height: g.notchHeight + IslandMetrics.grownBody
            )
        case .open:
            let measured = panelHeight(for: screenID)
            let body = min(max(measured, 72), g.maxHeight - g.notchHeight)
            return CGSize(width: openWidth(for: g), height: g.notchHeight + body)
        }
    }

    func frameSize() -> CGSize {
        frameSize(for: geometry, mode: mode)
    }

    func radius(for targetMode: IslandMode? = nil) -> CGFloat {
        switch targetMode ?? mode {
        case .hidden, .collapsed: return IslandMetrics.collapsedRadius
        case .grown: return IslandMetrics.grownRadius
        case .open: return IslandMetrics.openRadius
        }
    }

    func shoulderWidth(for targetMode: IslandMode? = nil) -> CGFloat {
        switch targetMode ?? mode {
        case .hidden, .collapsed: return 6
        case .grown: return 9
        case .open: return 12
        }
    }

    /// The island's animation style after the app's motion tier and Reduce Motion cap it.
    var effectiveMotion: IslandMotionStyle {
        motionStyle.capped(by: motionTier, reduceMotion: reduceMotion)
    }

    /// No animation with Reduce Motion or the motion tier off, an ease for the still style; the
    /// lively style gives the chassis a slight overshoot as it grows, the calm one settles.
    func animation(to target: IslandMode) -> Animation? {
        if reduceMotion || motionTier == .off { return nil }
        if effectiveMotion == .still { return .easeInOut(duration: 0.2) }
        let lively = effectiveMotion == .lively
        let spec: PrismSpringSpec
        switch target {
        case .open: spec = lively ? .islandOpenLively : .islandOpenCalm
        case .grown: spec = lively ? .islandGrowLively : .islandGrowCalm
        case .collapsed, .hidden: spec = lively ? .islandSettleLively : .islandSettleCalm
        }
        return spec.animation(tier: motionTier, reduceMotion: reduceMotion)
    }

    /// Whether the running animations move: off with Reduce Motion, the motion tier off or the
    /// still style.
    var animatesStrikes: Bool {
        effectiveMotion != .still
    }

    /// Frame rate the running animations ask for; the energy policy caps it further.
    var strikeFramesPerSecond: Double {
        effectiveMotion.framesPerSecond
    }

    // MARK: Time & Cache Formatting

    func duration(since ms: Double?) -> String? {
        duration(since: ms, at: now)
    }

    func duration(since ms: Double?, at referenceDate: Date) -> String? {
        guard let ms else { return nil }
        let seconds = max(0, Int(referenceDate.timeIntervalSince1970 - ms / 1000))
        if seconds < 60 { return strings.text("duration.seconds", ["s": "\(seconds)"]) }
        let minutes = seconds / 60
        if minutes < 60 { return strings.text("duration.minutes", ["m": "\(minutes)"]) }
        if minutes < 24 * 60 {
            return strings.text("duration.hoursMinutes", ["h": "\(minutes / 60)", "m": "\(minutes % 60)"])
        }
        return strings.text("duration.days", ["d": "\(minutes / (24 * 60))"])
    }

    func ago(since ms: Double?) -> String? {
        guard let ms else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince1970 - ms / 1000))
        let time: String
        if seconds < 60 {
            time = strings.text("duration.seconds", ["s": "\(seconds)"])
        } else if seconds < 3600 {
            time = strings.text("duration.minutes", ["m": "\(seconds / 60)"])
        } else if seconds < 24 * 3600 {
            time = strings.text("duration.hours", ["h": "\(seconds / 3600)"])
        } else {
            time = strings.text("duration.days", ["d": "\(seconds / (24 * 3600))"])
        }
        return strings.text("ago", ["time": time])
    }

    func resetDay(_ ms: Double) -> String {
        IslandDateFormatters.formatResetShort(
            resetsAtMs: ms,
            nowMs: now.timeIntervalSince1970 * 1000,
            localeId: strings.localeIdentifier
        )
    }

    func cacheLeft(_ cache: IslandCacheWindow?) -> (text: String, ending: Bool)? {
        guard let cache else { return nil }
        let left = cache.expiresAt - now.timeIntervalSince1970 * 1000
        guard left > 0 else { return nil }
        let ending = left <= cache.endingMs
        var time: String
        if ending {
            let seconds = Int((left / 1000).rounded(.up))
            time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        } else if left >= 3_600_000 {
            time = strings.text("duration.hours", ["h": "\(Int(left / 3_600_000))"])
        } else {
            time = strings.text("duration.minutes", ["m": "\(max(1, Int(left / 60_000)))"])
        }
        if cache.estimate { time = strings.text("cache.about", ["time": time]) }
        return (time, ending)
    }

    func cacheEndingShare(_ cache: IslandCacheWindow?) -> Double? {
        guard let cache, cache.endingMs > 0 else { return nil }
        let left = cache.expiresAt - now.timeIntervalSince1970 * 1000
        guard left > 0, left <= cache.endingMs else { return nil }
        return left / cache.endingMs
    }

    // MARK: Applying Snapshots

    func apply(snapshot next: IslandViewSnapshot, strings nextStrings: IslandStrings, visible: Bool) {
        // Every assignment notifies the observing panels, so only what changed is written.
        if strings != nextStrings { strings = nextStrings }
        if rows != next.rows { rows = next.rows }
        if snapshotRequests != next.requests { snapshotRequests = next.requests }
        if notices != next.notices { notices = next.notices }
        if summary != next.summary { summary = next.summary }
        if quotas != next.quotas { quotas = next.quotas }
        refresh(visible: visible, forceClock: false)
    }

    func applyTelemetry(_ next: IslandLiveTelemetry?) {
        if telemetry != next { telemetry = next }
    }

    /// `forceClock: false` lets a data sync reuse a clock less than a second old; the timers that
    /// exist to advance the clock pass `true`.
    func refresh(visible: Bool = true, forceClock: Bool = true) {
        let current = Date()
        if forceClock || current.timeIntervalSince(now) >= 1 || current < now {
            now = current
        }
        let all = rows
        let liveDone = Set(all.filter { Self.marksDone($0) }.map(seenKey))
        seenDoneKeys.formIntersection(liveDone)
        recomputeCollapsed(all)
        if let selectedRowKey, row(for: selectedRowKey) == nil {
            self.selectedRowKey = nil
        }

        if !visible {
            leave()
            updateChassis()
            return
        }
        if mode == .hidden {
            setMode(.collapsed)
        }
        updateChassis()
        scheduleStuckCheck(all)
        scheduleCacheTick()
        settleRequest()
    }

    private func recomputeCollapsed(_ rows: [IslandRowItem]) {
        let prevQuiet = collapsedQuiet

        let collapsed = computeCollapsed(rows)
        setCollapsed(collapsed.state)
        // Suppress unread/cache/running (ranks 4..6) while Sarto is in front with its running rail
        // visible; rank 7 (idle) stays visible because the rail itself hides when no sessions run.
        let quiet = quietForeground && collapsed.rank > 3 && collapsed.rank < 7
        if collapsedQuiet != quiet { collapsedQuiet = quiet }

        if prevQuiet != collapsedQuiet {
            onHitAreaChange?()
        }
    }

    private func setCollapsed(_ next: IslandCollapsedState) {
        if collapsed != next { collapsed = next }
        if collapsedSignal != next.signal { collapsedSignal = next.signal }
    }

    /// Changes when a new turn ends, not when the finished session's summary is touched again.
    private func seenKey(_ row: IslandRowItem) -> String {
        "\(row.key)@\(row.status)@\(Int(row.turnStartedAt ?? row.since ?? 0))"
    }

    private static func marksDone(_ row: IslandRowItem) -> Bool {
        row.status == "failed" || row.status == "unread"
    }

    /// The collapsed island says one thing, the first that holds, in this order: approvals,
    /// a used-up plan window, a failure, finished work not yet seen, a prompt cache about to
    /// expire, sessions running, and when idle the scarcest plan window. While Sarto is in front
    /// with its running panel, only the first three show; the rest the panel already says.
    private func computeCollapsed(_ rows: [IslandRowItem]) -> (state: IslandCollapsedState, rank: Int) {
        func uniqueAgents(_ list: [IslandRowItem]) -> [IslandAgentIdentity] {
            var seen = Set<String>()
            return list.map(\.agent).filter { seen.insert("\($0.harness)/\($0.color ?? "")").inserted }
        }

        let waiting = rows.filter { $0.status == "waiting" || $0.status == "sign_in" }
        if !waiting.isEmpty || !requests.isEmpty {
            let firstReq = requests.first
            let lead = firstReq.flatMap { row(for: $0.rowKey) } ?? waiting.first
            let count = max(summary.waiting, waiting.count, requests.count, 1)
            return (IslandCollapsedState(
                agents: lead.map { [$0.agent] } ?? [],
                signal: .waiting,
                fact: .pending(count),
                title: lead.map(title(of:)) ?? firstReq?.title
            ), 1)
        }

        let limited = rows.filter { $0.status == "limited" }
        if !limited.isEmpty {
            let reset = limited.compactMap { $0.limit?.resetsAt }.min()
            return (IslandCollapsedState(
                agents: uniqueAgents(limited),
                signal: .limited,
                fact: reset.map { .resumeAt($0) },
                title: limited.first?.limit?.label ?? limited.first.map(title(of:))
            ), 2)
        }

        let unseen = rows.filter { Self.marksDone($0) && !seenDoneKeys.contains(seenKey($0)) }
        let failed = unseen.filter { $0.status == "failed" }
        if !failed.isEmpty {
            return (IslandCollapsedState(
                agents: uniqueAgents(failed),
                signal: .failed,
                fact: .failed,
                title: failed.first.map(title(of:))
            ), 3)
        }

        let done = unseen.filter { $0.status == "unread" }
        if !done.isEmpty {
            return (IslandCollapsedState(
                agents: uniqueAgents(done),
                signal: .unread,
                fact: .done(done.count),
                title: done.first.map(title(of:))
            ), 4)
        }

        let latest = rows.first
        if let latest, let left = cacheLeft(latest.cache), left.ending {
            return (IslandCollapsedState(
                agents: [latest.agent],
                signal: nil,
                fact: .cache(strings.text("cache.short", ["time": left.text]), ending: true),
                title: title(of: latest)
            ), 5)
        }

        let running = rows.filter { $0.status == "running" || $0.status == "starting" }
        if !running.isEmpty {
            let moving = running.filter { status(of: $0) != "stuck" }
            let longest = running.compactMap { $0.turnStartedAt ?? $0.since }.min()
            let fact = IslandCollapsedFact.running(count: running.count, since: longest)
            if moving.isEmpty {
                return (IslandCollapsedState(
                    agents: uniqueAgents(running),
                    signal: .stuck,
                    fact: fact,
                    title: running.first.map(title(of:))
                ), 6)
            }
            let lead = moving[0]
            let sig: IslandSignal = lead.status == "starting"
                ? .running(.think)
                : .running(IslandTurnDots.Pattern(phase: lead.phase))
            return (IslandCollapsedState(
                agents: uniqueAgents(moving),
                signal: sig,
                fact: fact,
                title: title(of: lead)
            ), 6)
        }

        // Idle: hand off to `IslandCompactUsageStrip` (active focused tool dual-window meter).
        return (IslandCollapsedState(
            agents: [],
            signal: nil,
            fact: nil,
            title: latest.map(title(of:))
        ), 7)
    }

    // MARK: Pops & Notifications

    func pushPop(
        rowKey: String?,
        kind: String,
        title: String,
        body: String,
        agent: IslandAgentIdentity? = nil,
        percent: Double? = nil
    ) {
        guard mode != .hidden else { return }
        let item = IslandPopItem(
            id: nextPopId,
            rowKey: rowKey,
            kind: kind,
            title: title,
            body: body,
            agent: agent,
            percent: percent
        )
        nextPopId += 1
        onAnnounce?([title, body].filter { !$0.isEmpty }.joined(separator: ", "))

        if kind == "permission" {
            if mode == .open {
                if opener == .hover { opener = .request }
            } else if !requests.isEmpty {
                expand(by: .request)
            }
            return
        }
        if mode == .open { return }

        if mode == .grown, let showing = pop, showing.rowKey != nil, showing.rowKey == item.rowKey {
            if !pops.isEmpty { pops[0] = item }
            pop = item
            holdPop()
            return
        }

        pops.removeAll { $0.rowKey != nil && $0.rowKey == item.rowKey && $0.id != pop?.id }
        pops.append(item)
        let rank: [String: Int] = [
            "permission": 0, "error": 1, "limit-reached": 1,
            "limit-near": 2, "turn-ended": 3, "info": 4,
        ]
        let showing = pops.first { $0.id == pop?.id }
        let rest = pops.filter { $0.id != pop?.id }.sorted { (rank[$0.kind] ?? 5) < (rank[$1.kind] ?? 5) }
        pops = (showing.map { [$0] } ?? []) + rest
        queuedPops = max(0, pops.count - 1)
        if mode != .grown { showNextPop() }
    }

    private func showNextPop() {
        popTimer?.invalidate()
        guard let next = pops.first else {
            pop = nil
            queuedPops = 0
            setMode(.collapsed)
            return
        }
        pop = next
        queuedPops = pops.count - 1
        setMode(.grown)
        holdPop()
    }

    func holdPop(paused: Bool = false) {
        popTimer?.invalidate()
        guard mode == .grown, let pop, !paused else { return }
        let seconds: Double =
            ["turn-ended", "limit-reset"].contains(pop.kind) ? 2.6 :
            ["limit-near", "info"].contains(pop.kind) ? 4.0 : 6.0
        popTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.pops.isEmpty else { return }
                self.pops.removeFirst()
                self.showNextPop()
            }
        }
    }

    func pillInfo(for kind: String) -> (String, Color) {
        switch kind {
        case "permission": return (strings.text("status.waiting"), IslandTheme.attention)
        case "error": return (strings.text("status.failed"), IslandTheme.danger)
        case "limit-near": return ("", IslandTheme.usageRed)
        case "limit-reached": return (strings.text("pop.limitReached"), IslandTheme.danger)
        case "limit-reset": return (strings.text("pop.limitReset"), IslandTheme.success)
        default: return (strings.text("status.unread"), IslandTheme.success)
        }
    }

    // MARK: User Actions

    private func armMeasureTimeout() {
        measureTimeout?.invalidate()
        measureTimeout = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mode != .open else { return }
                self.measuring = false
                self.measuringScreenID = nil
            }
        }
    }

    func cancelMeasurement() {
        measureTimeout?.invalidate()
        measureTimeout = nil
        expandWorkItem?.cancel()
        expandWorkItem = nil
        measuring = false
        measuringScreenID = nil
    }

    func selectTab(_ tab: IslandExpandedTab) {
        guard effectiveExpandedTab != tab else { return }
        userPinnedTab = tab
    }

    func openMenuBarPanel(page: MenuBarPage) {
        actionSink?.islandOpenMenuBarPanel(page: page)
        collapse()
    }

    func openSettings(section: PrismSettingsSection? = .islandAndMenuBar) {
        actionSink?.islandOpenSettings(section: section)
        collapse()
    }

    func toggleDisplay(_ display: DisplayInfo) {
        actionSink?.islandToggleDisplay(display)
    }

    func expand(byClick: Bool, onScreen screenID: UInt32? = nil) {
        expand(by: byClick ? .click : .hover, onScreen: screenID)
    }

    func expand(by cause: IslandOpener, onScreen screenID: UInt32? = nil) {
        guard mode != .open else {
            measuring = false
            if cause == .click {
                opener = .click
                if let screenID { activeScreenID = screenID }
                onModeChange?(.open)
            }
            return
        }
        if !measuring {
            measuringScreenID = screenID ?? activeScreenID ?? Displays.preferredScreen().map(Displays.id(of:))
            measuring = true
            armMeasureTimeout()
            expandWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.mode != .hidden else { return }
                    self.expandWorkItem = nil
                    self.expand(by: cause, onScreen: screenID)
                }
            }
            expandWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
            return
        }
        cancelMeasurement()
        opener = cause
        // A request opens on the display the user is at, not on every display at once.
        activeScreenID = screenID ?? (cause == .request ? Displays.preferredScreen().map(Displays.id(of:)) : nil)
        popTimer?.invalidate()
        pops.removeAll()
        pop = nil
        queuedPops = 0
        for row in rows where Self.marksDone(row) {
            seenDoneKeys.insert(seenKey(row))
        }
        now = Date()
        recomputeCollapsed(rows)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.now = Date()
                self?.updateChassis()
            }
        }
        setMode(.open)
        actionSink?.islandExpandedDidAppear()
    }

    func collapse() {
        tickTimer?.invalidate()
        tickTimer = nil
        cancelMeasurement()
        demoRequest = nil
        opener = .hover
        selectedRowKey = nil
        userPinnedTab = nil
        activeScreenID = nil
        guard mode == .open || mode == .grown else { return }
        popTimer?.invalidate()
        pops.removeAll()
        pop = nil
        queuedPops = 0
        setMode(.collapsed)
    }

    func leave() {
        tickTimer?.invalidate()
        tickTimer = nil
        popTimer?.invalidate()
        popTimer = nil
        noteTimer?.invalidate()
        noteTimer = nil
        stuckTimer?.invalidate()
        stuckTimer = nil
        cacheTimer?.invalidate()
        cacheTimer = nil
        cancelMeasurement()
        pops.removeAll()
        pop = nil
        note = nil
        queuedPops = 0
        userPinnedTab = nil
        activeScreenID = nil
        setMode(.hidden)
    }

    func openRow(_ rowKey: String?) {
        let sessionId = rowKey.flatMap { row(for: $0)?.sessionId }
        actionSink?.islandOpenApp(sessionId: sessionId)
        collapse()
    }

    func openRequest(_ request: IslandPendingRequest) {
        if request.isDemo {
            demoRequest = nil
            collapse()
            return
        }
        actionSink?.islandOpenApp(sessionId: request.sessionId)
        collapse()
    }

    func newSession() {
        actionSink?.islandStartNewSession()
        collapse()
    }

    /// Opens on the display that was tapped only, not on every display.
    func tapPop(onScreen screenID: UInt32?) {
        if let rowKey = pop?.rowKey, let sessionId = row(for: rowKey)?.sessionId {
            actionSink?.islandOpenApp(sessionId: sessionId)
            collapse()
        } else {
            expand(by: .click, onScreen: screenID)
        }
    }

    /// Number keys answer only question cards, whose options show their numbers. Permission and
    /// plan cards take no digits, so a stray key can never grant a permanent approval.
    func digitOption(_ digit: Int, for request: IslandPendingRequest) -> IslandRequestOption? {
        guard request.kind == "question",
              (1...9).contains(digit),
              digit <= request.options.count
        else { return nil }
        return request.options[digit - 1]
    }

    func answer(_ request: IslandPendingRequest, option: IslandRequestOption) {
        guard !pendingRequestKeys.contains(request.key) else { return }
        if request.isDemo {
            demoRequest = nil
            showAnswerNote(IslandAnswerNote(text: strings.text("answered"), ok: true))
            return
        }
        pendingRequestKeys.insert(request.key)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.actionSink?.islandAnswerRequest(request, option: option)
                ?? IslandAnswerNote(text: self.strings.text("answerFailed", ["message": self.strings.text("offline")]), ok: false)
            self.pendingRequestKeys.remove(request.key)
            self.showAnswerNote(result)
        }
    }

    func moveSelection(_ step: Int) {
        guard !asking else { return }
        let keys = listRows.map(\.key)
        guard !keys.isEmpty else { return }
        let idx = selectedRowKey.flatMap { keys.firstIndex(of: $0) } ?? (step > 0 ? -1 : keys.count)
        selectedRowKey = keys[max(0, min(keys.count - 1, idx + step))]
    }

    private func showAnswerNote(_ next: IslandAnswerNote) {
        note = next
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.note = nil
                self?.settleRequest()
            }
        }
    }

    private func settleRequest() {
        guard mode == .open, opener == .request, !asking else { return }
        if pointerInside {
            opener = .hover
        } else {
            collapse()
        }
    }

    // MARK: On-Demand Timers (0% CPU when idle without warm cache or running tools)

    /// Collapsed, only the first row's cache shows; open, the panel's 1 Hz clock moves the rest.
    private func scheduleCacheTick() {
        let nowMs = now.timeIntervalSince1970 * 1000
        let watched = mode == .open ? Array(rows.prefix(IslandMetrics.listRows)) : Array(rows.prefix(1))
        var waitMs: Double?
        for cache in watched.compactMap(\.cache) {
            let left = cache.expiresAt - nowMs
            guard left > 0 else { continue }
            let next = left <= cache.endingMs
                ? 1000 - left.truncatingRemainder(dividingBy: 1000)
                : min(left - cache.endingMs, left.truncatingRemainder(dividingBy: 60_000))
            waitMs = min(waitMs ?? next, max(next, 50))
        }
        let due = waitMs.map { now.addingTimeInterval($0 / 1000 + 0.02) }
        rearm(&cacheTimer, due: due, current: &cacheTickDue)
    }

    private func scheduleStuckCheck(_ rows: [IslandRowItem]) {
        let nowMs = now.timeIntervalSince1970 * 1000
        var waitMs: Double?
        for row in rows where row.status == "running" {
            guard let since = row.toolSince else { continue }
            let due = since + stuckAfterMs
            let next = due > nowMs ? due - nowMs : 60_000 - (nowMs - due).truncatingRemainder(dividingBy: 60_000)
            waitMs = min(waitMs ?? next, next)
        }
        let due = waitMs.map { now.addingTimeInterval(max(1, $0 / 1000)) }
        rearm(&stuckTimer, due: due, current: &stuckCheckDue)
    }

    /// Keeps a one-shot refresh timer that already fires at about the same moment, so a sync
    /// every 80 ms does not tear down and rebuild it each time.
    private func rearm(_ timer: inout Timer?, due: Date?, current: inout Date?) {
        if let due, let current, timer?.isValid == true, abs(due.timeIntervalSince(current)) < 0.25 {
            return
        }
        timer?.invalidate()
        timer = nil
        current = due
        guard let due else { return }
        let fired = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh(visible: self?.mode != .hidden) }
        }
        RunLoop.main.add(fired, forMode: .common)
        timer = fired
    }

    private func setMode(_ next: IslandMode) {
        if next == .open || next == .collapsed || next == .hidden {
            measuring = false
            measuringScreenID = nil
            measureTimeout?.invalidate()
            measureTimeout = nil
        }
        guard next != mode else { return }
        mode = next
        updateChassis()
        onModeChange?(next)
    }
}
