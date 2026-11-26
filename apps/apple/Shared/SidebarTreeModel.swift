import Foundation
import SartoProtocol
import PrismDesign

// MARK: - Sidebar Tree & Status Models

public struct SidebarRowStatus: Sendable, Equatable {
    public let waiting: Int
    public let failed: Bool
    public let running: Bool
    public let starting: Bool
    public let unread: Bool
    public let cacheExpiringMinutes: Int?
    public let cacheExpired: Bool
    /// How the row's own last turn ended, when that is worth a mark.
    public let ending: SidebarTurnEnding?
}

/// A finished session's last turn ending worth a mark in its row: every ending but a plain
/// `end_turn`. Derived once per summary, when the sidebar index is built.
public struct SidebarTurnEnding: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case failed
        case limit
        case cancelled
        case maxTokens
        case maxTurnRequests
        case refusal
    }

    public let kind: Kind
    public let endedAt: Double
    /// The error's first line, for `failed` and `limit`.
    public let error: String?
    /// The plan window that stopped the turn, for `limit`.
    public let limitLabel: String?
    public let resetsAt: Double?

    public init?(summary: SessionSummary) {
        guard let last = summary.lastTurn else { return nil }
        // Hosts clear the ending when a turn starts; a summary that still carries one while it runs
        // is stale.
        switch summary.status {
        case .running, .starting, .awaitingPermission: return nil
        default: break
        }
        switch last.reason {
        case .failed: kind = .failed
        case .limit: kind = .limit
        case .cancelled: kind = .cancelled
        case .maxTokens: kind = .maxTokens
        case .maxTurnRequests: kind = .maxTurnRequests
        case .refusal: kind = .refusal
        case .endTurn, .unknown: return nil
        }
        endedAt = last.endedAt
        error = last.errorLine
        let label = last.limit?.label.trimmingCharacters(in: .whitespaces)
        limitLabel = (label?.isEmpty ?? true) ? nil : label
        resetsAt = last.limit?.resetsAt
    }

    public var isError: Bool { kind == .failed || kind == .limit }

    /// A limit whose window has not reset yet, so the session would be refused again.
    public func limitHolds(nowMs: Double) -> Bool {
        kind == .limit && (resetsAt.map { $0 > nowMs } ?? true)
    }

    public func title(l10n: PrismL10n) -> String {
        switch kind {
        case .failed: return l10n.tr("sidebar.ending.failed")
        case .limit:
            return limitLabel.map { l10n.tr("sidebar.ending.limit", $0) } ?? l10n.tr("sidebar.ending.planLimit")
        case .cancelled: return l10n.tr("sidebar.ending.cancelled")
        case .maxTokens: return l10n.tr("sidebar.ending.maxTokens")
        case .maxTurnRequests: return l10n.tr("sidebar.ending.maxTurnRequests")
        case .refusal: return l10n.tr("sidebar.ending.refusal")
        }
    }

    /// The error's first line for a failure, or when a limit's window resets while it holds.
    public func detail(l10n: PrismL10n, nowMs: Double) -> String? {
        switch kind {
        case .failed:
            return error
        case .limit:
            guard let resetsAt, resetsAt > nowMs else { return nil }
            return l10n.tr("sidebar.ending.resets", Self.resetTime(resetsAt, nowMs: nowMs, locale: l10n.language.resolvedLocale))
        default:
            return nil
        }
    }

    /// One line for a tooltip: the ending and its detail.
    public func summaryLine(l10n: PrismL10n, nowMs: Double) -> String {
        [title(l10n: l10n), detail(l10n: l10n, nowMs: nowMs)].compactMap { $0 }.joined(separator: " · ")
    }

    /// A reset within the day as a time, a later one as its weekday.
    public static func resetTime(_ ms: Double, nowMs: Double, locale: Locale) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        if ms - nowMs < 20 * 3_600_000 {
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        }
        return date.formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute().locale(locale))
    }
}

public struct SidebarSessionNode: Identifiable, Sendable, Equatable {
    public var id: String { summary.id }
    public let summary: SessionSummary
    /// User-created sub-sessions (one level deep, sorted by creation time).
    public let children: [SidebarSessionNode]
    /// Agent-spawned subagents folded into the parent row's badge (never standalone rows).
    public let subagents: [SessionSummary]
    public let ownWaiting: Int
    public let ownRunning: Bool
    public let totalWaiting: Int
    public let totalRunning: Bool
    public let ending: SidebarTurnEnding?

    public init(
        summary: SessionSummary,
        children: [SidebarSessionNode],
        subagents: [SessionSummary],
        ownWaiting: Int,
        ownRunning: Bool,
        totalWaiting: Int,
        totalRunning: Bool
    ) {
        self.summary = summary
        self.children = children
        self.subagents = subagents
        self.ownWaiting = ownWaiting
        self.ownRunning = ownRunning
        self.totalWaiting = totalWaiting
        self.totalRunning = totalRunning
        self.ending = SidebarTurnEnding(summary: summary)
    }

    public func rowStatus(rolledUp: Bool, nowMs: Double) -> SidebarRowStatus {
        let ownFailed = summary.attention == "error" || summary.status == .failed
        let ownStarting = summary.status == .starting
        let ownUnread = summary.attention == "unread"
        let (expiringMin, expired) = SidebarTreeBuilder.cacheState(for: summary, nowMs: nowMs)

        if !rolledUp || children.isEmpty {
            return SidebarRowStatus(
                waiting: ownWaiting,
                failed: ownFailed,
                running: ownRunning,
                starting: ownStarting,
                unread: ownUnread,
                cacheExpiringMinutes: expiringMin,
                cacheExpired: expired,
                ending: ending
            )
        }

        let anyChildFailed = children.contains { $0.summary.attention == "error" || $0.summary.status == .failed }
        let anyChildUnread = children.contains { $0.summary.attention == "unread" }
        return SidebarRowStatus(
            waiting: totalWaiting,
            failed: ownFailed || anyChildFailed,
            running: totalRunning,
            starting: ownStarting,
            unread: ownUnread || anyChildUnread,
            cacheExpiringMinutes: expiringMin,
            cacheExpired: expired,
            ending: ending
        )
    }
}

/// Every sidebar tree grouped in one pass over the sessions, so a body pass reads prebuilt nodes
/// instead of rescanning all sessions once per project.
public struct SidebarSessionIndex: Sendable {
    public let pinned: [SidebarSessionNode]
    public let scratch: [SidebarSessionNode]
    public let archived: [SessionSummary]
    public let hasNoProject: Bool
    private let byProject: [String: [SidebarSessionNode]]
    /// Latest `updatedAt` of the listed top-level sessions per project path, for orphan detection.
    private let latestByProjectPath: [String: Double]

    public static let empty = SidebarSessionIndex(sessions: [])

    public init(sessions: [SessionSummary]) {
        var byID: [String: SessionSummary] = [:]
        byID.reserveCapacity(sessions.count)
        for s in sessions {
            byID[s.id] = s
        }

        func topLevelAncestorID(of session: SessionSummary) -> String? {
            guard let pid = session.parentId else { return nil }
            var cursor = pid
            var depth = 0
            while let parent = byID[cursor], let grandParent = parent.parentId, depth < 6 {
                cursor = grandParent
                depth += 1
            }
            return byID[cursor] != nil ? cursor : nil
        }

        // Group subagents and user sub-sessions under their top-level ancestor (1 level deep).
        var subagentsByRoot: [String: [SessionSummary]] = [:]
        var userChildrenByRoot: [String: [SessionSummary]] = [:]
        var pinnedRoots: [SessionSummary] = []
        var scratchRoots: [SessionSummary] = []
        var projectRoots: [String: [SessionSummary]] = [:]
        var latest: [String: Double] = [:]
        var archived: [SessionSummary] = []
        var hasNoProject = false

        for s in sessions {
            let listed = SidebarTreeBuilder.isListedOrigin(s)
            let subagent = SidebarTreeBuilder.isSubagent(s)
            guard listed else { continue }

            if s.archivedAt == nil, let rootID = topLevelAncestorID(of: s) {
                if subagent {
                    subagentsByRoot[rootID, default: []].append(s)
                } else {
                    userChildrenByRoot[rootID, default: []].append(s)
                }
            }
            guard !subagent else { continue }

            if s.archivedAt != nil {
                if s.parentId == nil { archived.append(s) }
                continue
            }
            if s.scratch == true {
                hasNoProject = true
            } else if s.parentId == nil, !s.projectPath.isEmpty {
                latest[s.projectPath] = max(latest[s.projectPath] ?? 0, s.updatedAt)
            }

            // Keep as root if no parent or if parent isn't in the list (e.g., archived parent left child behind).
            if let pid = s.parentId, let parent = byID[pid], parent.archivedAt == nil, !SidebarTreeBuilder.isSubagent(parent) {
                continue
            }
            if s.pinnedAt != nil {
                pinnedRoots.append(s)
            } else if s.scratch == true {
                scratchRoots.append(s)
            } else {
                projectRoots[s.projectPath, default: []].append(s)
            }
        }

        func node(for root: SessionSummary) -> SidebarSessionNode {
            let rootSubs = (subagentsByRoot[root.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            let rawChildren = (userChildrenByRoot[root.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            let childNodes: [SidebarSessionNode] = rawChildren.map { child in
                let childSubs = (subagentsByRoot[child.id] ?? []).sorted { $0.createdAt < $1.createdAt }
                let ownW = child.permissionCount + childSubs.reduce(0) { $0 + $1.permissionCount }
                let ownR = child.status == .running
                return SidebarSessionNode(
                    summary: child,
                    children: [],
                    subagents: childSubs,
                    ownWaiting: ownW,
                    ownRunning: ownR,
                    totalWaiting: ownW,
                    totalRunning: ownR
                )
            }
            let ownW = root.permissionCount + rootSubs.reduce(0) { $0 + $1.permissionCount }
            let ownR = root.status == .running
            let totalW = ownW + childNodes.reduce(0) { $0 + $1.totalWaiting }
            let totalR = ownR || childNodes.contains(where: \.totalRunning)
            return SidebarSessionNode(
                summary: root,
                children: childNodes,
                subagents: rootSubs,
                ownWaiting: ownW,
                ownRunning: ownR,
                totalWaiting: totalW,
                totalRunning: totalR
            )
        }

        self.pinned = pinnedRoots
            .sorted { ($0.pinnedAt ?? 0) < ($1.pinnedAt ?? 0) }
            .map(node(for:))
        self.scratch = scratchRoots
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(node(for:))
        self.byProject = projectRoots.mapValues { roots in
            roots.sorted { $0.updatedAt > $1.updatedAt }.map(node(for:))
        }
        self.archived = archived.sorted { $0.updatedAt > $1.updatedAt }
        self.hasNoProject = hasNoProject
        self.latestByProjectPath = latest
    }

    /// Top-level unpinned, unarchived sessions for one project folder (or `nil` for No Project / scratch), newest first.
    public func nodes(forProject projectPath: String?) -> [SidebarSessionNode] {
        guard let projectPath else { return scratch }
        return byProject[projectPath] ?? []
    }

    /// Project folders that have sessions but are missing from `knownProjects`, newest first.
    /// Prevents orphaned sessions from vanishing if the daemon returned a session before `projects.list`.
    public func orphanProjects(knownProjects: [ProjectInfo]) -> [ProjectInfo] {
        let knownSet = Set(knownProjects.map(\.path))
        return latestByProjectPath
            .filter { !knownSet.contains($0.key) }
            .sorted { $0.value > $1.value }
            .map { path, updated in
                let name = (path as NSString).lastPathComponent
                return ProjectInfo(
                    path: path,
                    name: name.isEmpty ? path : name,
                    missing: false,
                    lastOpenedAt: updated,
                    pinnedAt: nil,
                    order: nil
                )
            }
    }
}

/// Rebuilds the sidebar index only when the sessions change. An unchanged array shares its
/// buffer, so the equality check is constant time on body passes caused by anything else.
public final class SidebarSessionIndexCache {
    private var sessions: [SessionSummary] = []
    private var cached: SidebarSessionIndex = .empty

    public init() {}

    public func index(for next: [SessionSummary]) -> SidebarSessionIndex {
        if next != sessions {
            sessions = next
            cached = SidebarSessionIndex(sessions: next)
        }
        return cached
    }
}

public enum SidebarTreeBuilder {
    public static let rowsShownPerProject = 5

    /// Routine runs and workflow task steps live outside project session lists.
    public static func isListedOrigin(_ summary: SessionSummary) -> Bool {
        summary.origin != "routine" && summary.origin != "task"
    }

    public static func isSubagent(_ summary: SessionSummary) -> Bool {
        summary.origin == "subagent"
    }

    public static func isRunningStatus(_ summary: SessionSummary) -> Bool {
        summary.status == .running || summary.status == .awaitingPermission
    }

    /// Top-level pinned sessions across all projects, ordered by `pinnedAt` ascending (oldest pin first).
    public static func buildPinnedTree(sessions: [SessionSummary]) -> [SidebarSessionNode] {
        SidebarSessionIndex(sessions: sessions).pinned
    }

    /// Top-level unpinned, unarchived sessions for one project folder (or `nil` for No Project / scratch), newest first.
    public static func buildProjectTree(
        sessions: [SessionSummary],
        projectPath: String?
    ) -> [SidebarSessionNode] {
        SidebarSessionIndex(sessions: sessions).nodes(forProject: projectPath)
    }

    /// Top-level sessions whose `projectPath` is not in `knownProjectPaths` and not `scratch`.
    public static func buildOrphanProjectPaths(
        sessions: [SessionSummary],
        knownProjects: [ProjectInfo]
    ) -> [ProjectInfo] {
        SidebarSessionIndex(sessions: sessions).orphanProjects(knownProjects: knownProjects)
    }

    public static func hasNoProjectSessions(_ sessions: [SessionSummary]) -> Bool {
        sessions.contains { isListedOrigin($0) && !isSubagent($0) && $0.scratch == true && $0.archivedAt == nil }
    }

    public static func archivedSessions(from sessions: [SessionSummary]) -> [SessionSummary] {
        SidebarSessionIndex(sessions: sessions).archived
    }

    /// Applies Sarto's 5-row cap per project while always keeping running, waiting, or currently-viewed sessions in sight.
    public static func limitRows(
        _ nodes: [SidebarSessionNode],
        showAll: Bool,
        shownSessionID: String?
    ) -> (visible: [SidebarSessionNode], hiddenCount: Int) {
        guard !showAll, nodes.count > rowsShownPerProject else {
            return (nodes, 0)
        }
        let visible = nodes.enumerated().compactMap { idx, node -> SidebarSessionNode? in
            if idx < rowsShownPerProject || keepInSight(node, shownSessionID: shownSessionID) {
                return node
            }
            return nil
        }
        return (visible, max(0, nodes.count - visible.count))
    }

    public static func keepInSight(_ node: SidebarSessionNode, shownSessionID: String?) -> Bool {
        if node.totalWaiting > 0 || node.totalRunning { return true }
        guard let shownSessionID else { return false }
        if node.id == shownSessionID { return true }
        if node.children.contains(where: { $0.id == shownSessionID }) { return true }
        if node.subagents.contains(where: { $0.id == shownSessionID }) { return true }
        return false
    }

    /// Disambiguates projects that share the same folder basename by returning the shortest distinguishing parent segment.
    public static func projectNameHints(for projects: [ProjectInfo]) -> [String: String] {
        var byName: [String: [ProjectInfo]] = [:]
        for p in projects {
            byName[p.name.lowercased(), default: []].append(p)
        }
        var hints: [String: String] = [:]
        for (_, group) in byName where group.count > 1 {
            let comps = group.map { ($0.path, URL(fileURLWithPath: $0.path).pathComponents.filter { $0 != "/" }) }
            for (path, parts) in comps {
                guard parts.count >= 2 else { continue }
                let parent = parts[parts.count - 2]
                let clashes = comps.filter { otherPath, otherParts in
                    otherPath != path && otherParts.count >= 2 && otherParts[otherParts.count - 2] == parent
                }
                if clashes.isEmpty {
                    hints[path] = parent
                } else if parts.count >= 3 {
                    hints[path] = "\(parts[parts.count - 3])/\(parent)"
                } else {
                    hints[path] = parent
                }
            }
        }
        return hints
    }

    /// Computes prompt cache status for a sidebar row (mirrors `session-cache.ts`).
    public static func cacheState(for summary: SessionSummary, nowMs: Double) -> (expiringMinutes: Int?, expired: Bool) {
        guard !isSubagent(summary),
              summary.status != .running,
              summary.status != .awaitingPermission
        else { return (nil, false) }

        guard let cache = summary.cache, let ttl = cache.ttl, let expiresAt = cache.expiresAt else {
            return (nil, false)
        }
        let remainingMs = expiresAt - nowMs
        if remainingMs <= 0 {
            return (nil, true)
        }
        let endingWindowMs: Double = ttl >= 3_600_000.0 ? 5 * 60_000.0 : 60_000.0
        if remainingMs <= endingWindowMs {
            let mins = max(1, Int(ceil(remainingMs / 60_000.0)))
            return (mins, false)
        }
        return (nil, false)
    }

    /// Builds the CLI resume command for a session when supported.
    public static func resumeCommand(for summary: SessionSummary) -> String? {
        guard let acpId = summary.acpSessionId, !acpId.isEmpty else { return nil }
        let cd = "cd \(quotePosix(summary.projectPath)) && "
        switch summary.agentId {
        case "claude-code":
            return "\(cd)claude --resume \(quotePosix(acpId))"
        case "codex":
            return "\(cd)codex resume \(quotePosix(acpId))"
        case "antigravity":
            return "\(cd)agy --conversation \(quotePosix(acpId))"
        default:
            return nil
        }
    }

    public static func relativeTimeLabel(updatedAtMs: Double, nowMs: Double, l10n: PrismL10n) -> String {
        let deltaSec = max(0, Int((nowMs - updatedAtMs) / 1000.0))
        if deltaSec < 60 { return l10n.tr("sidebar.cardJustNow") }
        let mins = deltaSec / 60
        if mins < 60 { return l10n.tr("sidebar.cardMinutesAgo", mins) }
        let hours = mins / 60
        if hours < 24 { return l10n.tr("sidebar.cardHoursAgo", hours) }
        let days = hours / 24
        return l10n.tr("sidebar.cardDaysAgo", days)
    }

    private static let fencedPreviewRegex = try! NSRegularExpression(pattern: "```[\\s\\S]*?(?:```|$)", options: [])
    private static let imageLinkPreviewRegex = try! NSRegularExpression(pattern: "!\\[([^\\]]*)\\]\\([^)]*\\)", options: [])
    private static let inlineLinkPreviewRegex = try! NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)", options: [])
    private static let backticksPreviewRegex = try! NSRegularExpression(pattern: "`+", options: [])
    private static let asterisksPreviewRegex = try! NSRegularExpression(pattern: "\\*+", options: [])
    private static let headingPreviewRegex = try! NSRegularExpression(pattern: "#{1,6}\\s+", options: [])

    public static func plainPreviewExcerpt(_ markdown: String) -> String {
        var stripped = fencedPreviewRegex.stringByReplacingMatches(
            in: markdown,
            range: NSRange(markdown.startIndex..., in: markdown),
            withTemplate: " "
        )
        stripped = imageLinkPreviewRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: "$1"
        )
        stripped = inlineLinkPreviewRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: "$1"
        )
        stripped = backticksPreviewRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: ""
        )
        stripped = asterisksPreviewRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: ""
        )
        stripped = stripped.replacingOccurrences(of: "~~", with: "")
        stripped = headingPreviewRegex.stringByReplacingMatches(
            in: stripped,
            range: NSRange(stripped.startIndex..., in: stripped),
            withTemplate: ""
        )
        return stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func quotePosix(_ arg: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !arg.isEmpty && arg.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return arg
        }
        return "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
