import Foundation
import SartoProtocol
import PrismDesign

// MARK: - Cached Unified Diff Computation (keeps 120/144 Hz scrolling smooth)

public struct ToolDiffPayload: Sendable, Equatable {
    public let path: String
    public let oldText: String?
    public let newText: String

    public init(path: String, oldText: String?, newText: String) {
        self.path = path
        self.oldText = oldText
        self.newText = newText
    }
}

/// A small least-recently-used store. Callers serialize access to it.
final class ThreadLRUStore<Key: Hashable, Value> {
    /// A class, so a hit refreshes its recency without writing the dictionary (and hashing) again.
    private final class Slot {
        let value: Value
        var tick: UInt64

        init(value: Value, tick: UInt64) {
            self.value = value
            self.tick = tick
        }
    }

    private var storage: [Key: Slot] = [:]
    private var tick: UInt64 = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(4, capacity)
    }

    func value(for key: Key) -> Value? {
        guard let slot = storage[key] else { return nil }
        tick &+= 1
        slot.tick = tick
        return slot.value
    }

    func set(_ value: Value, for key: Key) {
        tick &+= 1
        storage[key] = Slot(value: value, tick: tick)
        if storage.count > capacity {
            evictOldest()
        }
    }

    /// Drops the least recently used quarter in one pass, so the sort is paid once per many inserts.
    private func evictOldest() {
        let dropCount = max(1, storage.count - capacity * 3 / 4)
        let oldest = storage.sorted { $0.value.tick < $1.value.tick }.prefix(dropCount).map(\.key)
        for key in oldest {
            storage.removeValue(forKey: key)
        }
    }
}

public final class ThreadDiffCache: @unchecked Sendable {
    public static let shared = ThreadDiffCache()

    /// Only the path and text lengths are hashed: hashing whole file texts on every lookup costs
    /// about as much as the diff it guards. Texts are compared on a hit, which is a pointer check
    /// when both sides share storage, as an unchanged thread entry does.
    private struct Key: Hashable {
        let path: String
        let oldLength: Int
        let newLength: Int
    }

    private struct Entry {
        let oldText: String?
        let newText: String
        let diff: ComputedDiff
        let lines: [DiffLine]
    }

    private let lock = NSLock()
    private let store = ThreadLRUStore<Key, [Entry]>(capacity: 400)

    private init() {}

    public func compute(path: String, oldText: String?, newText: String) -> ComputedDiff {
        entry(path: path, oldText: oldText, newText: newText).diff
    }

    /// The diff with its hunk lines flattened once, for views that list every line.
    public func computeWithLines(path: String, oldText: String?, newText: String) -> (diff: ComputedDiff, lines: [DiffLine]) {
        let hit = entry(path: path, oldText: oldText, newText: newText)
        return (hit.diff, hit.lines)
    }

    private func entry(path: String, oldText: String?, newText: String) -> Entry {
        let key = Key(path: path, oldLength: oldText?.utf8.count ?? -1, newLength: newText.utf8.count)

        lock.lock()
        let bucket = store.value(for: key) ?? []
        lock.unlock()
        if let hit = bucket.first(where: { $0.newText == newText && $0.oldText == oldText }) {
            return hit
        }

        let computed: ComputedDiff
        if oldText == nil {
            let lines = Self.splitLines(newText)
            let diffLines = lines.enumerated().map { idx, text in
                DiffLine(id: idx, kind: .added, oldLineNumber: nil, newLineNumber: idx + 1, text: text)
            }
            let hunk = DiffHunk(id: 0, oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count, lines: diffLines)
            computed = ComputedDiff(hunks: lines.isEmpty ? [] : [hunk], insertions: lines.count, deletions: 0)
        } else if newText.isEmpty, let oldText {
            let lines = Self.splitLines(oldText)
            let diffLines = lines.enumerated().map { idx, text in
                DiffLine(id: idx, kind: .deleted, oldLineNumber: idx + 1, newLineNumber: nil, text: text)
            }
            let hunk = DiffHunk(id: 0, oldStart: 1, oldCount: lines.count, newStart: 0, newCount: 0, lines: diffLines)
            computed = ComputedDiff(hunks: lines.isEmpty ? [] : [hunk], insertions: 0, deletions: lines.count)
        } else {
            computed = UnifiedDiffEngine.compute(oldText: oldText, newText: newText, contextLines: 3)
        }
        let made = Entry(
            oldText: oldText,
            newText: newText,
            diff: computed,
            lines: computed.hunks.count == 1 ? computed.hunks[0].lines : computed.hunks.flatMap(\.lines)
        )

        lock.lock()
        var fresh = store.value(for: key) ?? []
        if fresh.count >= 4 {
            fresh.removeFirst()
        }
        fresh.append(made)
        store.set(fresh, for: key)
        lock.unlock()

        return made
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let utf8 = text.utf8
        var slices = utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if utf8.last == UInt8(ascii: "\n"), let tail = slices.last, tail.isEmpty {
            slices.removeLast()
        }
        var result: [String] = []
        result.reserveCapacity(slices.count)
        for slice in slices {
            let trimmed = slice.last == UInt8(ascii: "\r") ? slice.dropLast() : slice
            result.append(String(decoding: trimmed, as: UTF8.self))
        }
        return result
    }
}

// MARK: - Timeline Models (mirroring src/renderer/src/features/session/thread-items.ts & run-group.tsx)

public struct WorkStepPresentation: Identifiable, Sendable, Equatable {
    public let id: String
    public let entry: ThreadEntry
    public let iconName: String
    public let verb: String
    public let target: String
    public let isRunning: Bool
    public let isFailed: Bool
    public let isCancelled: Bool
    public let insertions: Int
    public let deletions: Int
    public let durationMs: Double?
    public let hasDetails: Bool
}

public struct WorkRunSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let steps: [WorkStepPresentation]
    public let isRunning: Bool
    public let isLive: Bool
    public let failedCount: Int
    public let summaryText: String
    public let liveHeadline: String?
    public let stackedIcons: [String]
    public let imageRefs: [ContentRef]
    public let totalInsertions: Int
    public let totalDeletions: Int
    public let totalDurationMs: Double?
}

public struct TurnFileChange: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public let path: String
    public let displayPath: String
    public let directoryPrefix: String
    public let fileName: String
    public let diffs: [ToolDiffPayload]
    public let insertions: Int
    public let deletions: Int
    public let isNewFile: Bool
    /// Tool entry IDs whose diff payloads for this file are still digested and need `sessions.entry`.
    public let digestEntryIDs: [String]

    public init(
        path: String,
        displayPath: String,
        directoryPrefix: String,
        fileName: String,
        diffs: [ToolDiffPayload],
        insertions: Int,
        deletions: Int,
        isNewFile: Bool,
        digestEntryIDs: [String] = []
    ) {
        self.path = path
        self.displayPath = displayPath
        self.directoryPrefix = directoryPrefix
        self.fileName = fileName
        self.diffs = diffs
        self.insertions = insertions
        self.deletions = deletions
        self.isNewFile = isNewFile
        self.digestEntryIDs = digestEntryIDs
    }
}

public struct TurnFooterSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let replyText: String
    public let forkEntryID: String?
    public let changedFiles: [TurnFileChange]
    public let totalInsertions: Int
    public let totalDeletions: Int
    public let stopReason: String?
    public let durationMs: Double?
}

public struct LiveTurnStatus: Identifiable, Sendable, Equatable {
    public let id = "live-turn-status"
    public let phase: PrismTurnPhase
    public let phaseText: String
    public let isWaiting: Bool
    public let startedAtMs: Double?
}

public enum ThreadTimelineItem: Identifiable, Sendable, Equatable {
    case user(id: String, text: String, content: [UserContent], at: Double?, steered: Bool)
    case agent(id: String, markdown: String, streaming: Bool, at: Double?, attachments: [ContentRef])
    case workRun(WorkRunSummary)
    case permissionCard(ToolEntryData)
    case textQuestionCard(id: String, questions: [PendingQuestion])
    case subagent(id: String, sessionId: String)
    case sessionStarted(id: String, sessionId: String)
    case sessionMessage(id: String, senderId: String?, senderTitle: String?, text: String)
    case sessionReport(id: String, from: FromSession, ended: FromSessionEnded, at: Double?, steered: Bool)
    case takeover(id: String, agentId: String, turns: Int, omitted: Int, summarize: Bool)
    case notice(id: String, severity: String, title: String, description: String?, cause: String?, canRetry: Bool)
    case compaction(id: String, status: String, summary: String)
    case git(GitEntryPayload)
    case memory(MemoryWriteEntryPayload)
    case settingsChange(SettingsChangeEntryPayload)
    case browserOrigin(BrowserOriginEntryPayload)
    case controlAsk(ControlAskEntryPayload)
    case controlNote(ControlNoteEntryPayload)
    case deviceAccess(DeviceAccessEntryPayload)
    case surfaceAccess(SurfaceAccessEntryPayload)
    case computerApp(ComputerAppEntryPayload)
    case computerSetup(ComputerSetupEntryPayload)
    case projectMcp(ProjectMcpEntryPayload)
    case projectHooks(ProjectHooksEntryPayload)
    case problemReport(ProblemReportEntryPayload)
    case marketPublish(MarketPublishEntryPayload)
    case turnFooter(TurnFooterSummary)
    case liveStatus(LiveTurnStatus)

    public var id: String {
        switch self {
        case .user(let id, _, _, _, _): return "u:\(id)"
        case .agent(let id, _, _, _, _): return "a:\(id)"
        case .workRun(let run): return "run:\(run.id)"
        case .permissionCard(let tool): return "perm:\(tool.id)"
        case .textQuestionCard(let id, _): return "txtq:\(id)"
        case .subagent(let id, _): return "sub:\(id)"
        case .sessionStarted(let id, _): return "sstart:\(id)"
        case .sessionMessage(let id, _, _, _): return "smsg:\(id)"
        case .sessionReport(let id, _, _, _, _): return "srep:\(id)"
        case .takeover(let id, _, _, _, _): return "tk:\(id)"
        case .notice(let id, _, _, _, _, _): return "notice:\(id)"
        case .compaction(let id, _, _): return "compact:\(id)"
        case .git(let p): return "git:\(p.id)"
        case .memory(let p): return "mem:\(p.id)"
        case .settingsChange(let p): return "set:\(p.id)"
        case .browserOrigin(let p): return "borig:\(p.id)"
        case .controlAsk(let p): return "cask:\(p.id)"
        case .controlNote(let p): return "cnote:\(p.id)"
        case .deviceAccess(let p): return "dacc:\(p.id)"
        case .surfaceAccess(let p): return "sacc:\(p.id)"
        case .computerApp(let p): return "capp:\(p.id)"
        case .computerSetup(let p): return "cset:\(p.id)"
        case .projectMcp(let p): return "pmcp:\(p.id)"
        case .projectHooks(let p): return "phook:\(p.id)"
        case .problemReport(let p): return "prep:\(p.id)"
        case .marketPublish(let p): return "mpub:\(p.id)"
        case .turnFooter(let footer): return "footer:\(footer.id)"
        case .liveStatus(let status): return status.id
        }
    }

    public var rawEntryID: String? {
        switch self {
        case .user(let id, _, _, _, _),
             .agent(let id, _, _, _, _),
             .subagent(let id, _),
             .sessionStarted(let id, _),
             .sessionMessage(let id, _, _, _),
             .sessionReport(let id, _, _, _, _),
             .takeover(let id, _, _, _, _),
             .notice(let id, _, _, _, _, _),
             .compaction(let id, _, _):
            return id
        case .permissionCard(let tool):
            return tool.id
        case .textQuestionCard(let id, _):
            return id
        case .workRun(let run):
            return run.id
        case .git(let p): return p.id
        case .memory(let p): return p.id
        case .settingsChange(let p): return p.id
        case .browserOrigin(let p): return p.id
        case .controlAsk(let p): return p.id
        case .controlNote(let p): return p.id
        case .deviceAccess(let p): return p.id
        case .surfaceAccess(let p): return p.id
        case .computerApp(let p): return p.id
        case .computerSetup(let p): return p.id
        case .projectMcp(let p): return p.id
        case .projectHooks(let p): return p.id
        case .problemReport(let p): return p.id
        case .marketPublish(let p): return p.id
        case .turnFooter, .liveStatus:
            return nil
        }
    }
}

/// One real user-prompt turn entry for the left-edge conversation timeline rail.
/// Inspired by makecindy/cindy's MessageNavRail (Apache-2.0): stores both the prompt preview
/// and the turn's final assistant reply excerpt so short prompts ("continue / ok") stay recognizable.
public struct ThreadTimelineNavEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let entryID: String
    public let scrollItemID: String
    public let turnNumber: Int
    public let promptPreview: String
    public let attachmentCount: Int
    public let answerExcerpt: String?
    public let pos: Int?
    public let isLoaded: Bool

    public init(
        id: String,
        entryID: String,
        scrollItemID: String,
        turnNumber: Int,
        promptPreview: String,
        attachmentCount: Int,
        answerExcerpt: String?,
        pos: Int? = nil,
        isLoaded: Bool = true
    ) {
        self.id = id
        self.entryID = entryID
        self.scrollItemID = scrollItemID
        self.turnNumber = turnNumber
        self.promptPreview = promptPreview
        self.attachmentCount = attachmentCount
        self.answerExcerpt = answerExcerpt
        self.pos = pos
        self.isLoaded = isLoaded
    }
}

public struct ThreadTimelineSnapshot: Sendable {
    public let latestPlan: [PlanItem]?
    public let items: [ThreadTimelineItem]
    public let navEntries: [ThreadTimelineNavEntry]
    /// Whether any tool entry is waiting on a permission answer.
    public let hasPendingPermission: Bool
}

// MARK: - Timeline Builder

public enum ThreadTimelineBuilder {
    private struct SnapshotCacheKey: Equatable {
        let sessionId: String
        let seq: Int
        let entryCount: Int
        let status: SessionStatus
        let language: PrismLanguage
        let canForkSession: Bool
        let canForkAtMessage: Bool
        let snapshotPlanCount: Int
        let turnStartedAt: Double?
    }

    /// Everything outside its own entries that shapes a segment's rows.
    private struct SegmentContext: Equatable {
        let turnStartID: String
        let isFinal: Bool
        let isLive: Bool
        let forkAllowedNow: Bool
        let canForkAtMessage: Bool
        let language: PrismLanguage
        let projectPath: String
        let activeWritingID: String?
        let latestAgentID: String?
        let retryableNoticeID: String?
    }

    /// Rows built for one segment of the thread: the entries from a real user prompt, or from just
    /// after a turn end, up to the next one. Closed segments are reused while their entries and
    /// context compare equal, so a streamed token rebuilds only the live segment.
    private struct BuiltSegment {
        let entries: [ThreadEntry]
        let entryExtras: [String: ThreadEntryExtras]
        let context: SegmentContext
        let items: [ThreadTimelineItem]
        let nextTurnStartID: String
    }

    private struct RunContext: Equatable {
        let isSessionLive: Bool
        let isLatestLive: Bool
        let language: PrismLanguage
        let projectPath: String
    }

    private struct BuiltRun {
        let entries: [ThreadEntry]
        let context: RunContext
        let summary: WorkRunSummary
    }

    private final class TimelineMemoCache: @unchecked Sendable {
        struct SessionMemo {
            var key: SnapshotCacheKey
            var snapshot: ThreadTimelineSnapshot
            var segments: [String: BuiltSegment]
            var runs: [String: BuiltRun]
        }

        private let lock = NSLock()
        private let bySession = ThreadLRUStore<String, SessionMemo>(capacity: 12)

        func lookup(_ key: SnapshotCacheKey) -> ThreadTimelineSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            guard let memo = bySession.value(for: key.sessionId), memo.key == key else { return nil }
            return memo.snapshot
        }

        func parts(for sessionId: String) -> (segments: [String: BuiltSegment], runs: [String: BuiltRun]) {
            lock.lock()
            defer { lock.unlock() }
            guard let memo = bySession.value(for: sessionId) else { return ([:], [:]) }
            return (memo.segments, memo.runs)
        }

        func store(_ memo: SessionMemo) {
            lock.lock()
            defer { lock.unlock() }
            bySession.set(memo, for: memo.key.sessionId)
        }
    }

    /// Flattened excerpts keyed by entry and text length, so the nav rail never re-runs the
    /// fence regex over text it has already seen.
    private final class ExcerptCache: @unchecked Sendable {
        struct Key: Hashable {
            let id: String
            let length: Int
            let sample: Int
            let maxChars: Int
        }

        private let lock = NSLock()
        private let store = ThreadLRUStore<Key, String>(capacity: 2048)

        func excerpt(id: String, text: String, maxChars: Int) -> String {
            // Length plus a sample of the head guards against an edit that keeps the length.
            var hasher = Hasher()
            for byte in text.utf8.prefix(48) { hasher.combine(byte) }
            let key = Key(id: id, length: text.utf8.count, sample: hasher.finalize(), maxChars: maxChars)
            lock.lock()
            let hit = store.value(for: key)
            lock.unlock()
            if let hit { return hit }
            let made = ThreadTimelineBuilder.flattenExcerpt(text, maxChars: maxChars)
            lock.lock()
            store.set(made, for: key)
            lock.unlock()
            return made
        }
    }

    private final class NavMergeMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var last: (outline: [OutlineEntryInfo], loaded: [ThreadTimelineNavEntry], merged: [ThreadTimelineNavEntry])?

        func lookup(outline: [OutlineEntryInfo], loaded: [ThreadTimelineNavEntry]) -> [ThreadTimelineNavEntry]? {
            lock.lock()
            defer { lock.unlock() }
            guard let last, last.outline == outline, last.loaded == loaded else { return nil }
            return last.merged
        }

        func store(outline: [OutlineEntryInfo], loaded: [ThreadTimelineNavEntry], merged: [ThreadTimelineNavEntry]) {
            lock.lock()
            defer { lock.unlock() }
            last = (outline, loaded, merged)
        }
    }

    private static let memoCache = TimelineMemoCache()
    private static let excerptCache = ExcerptCache()
    private static let navMergeMemo = NavMergeMemo()

    public static func scrollTargetID(for entryID: String, in items: [ThreadTimelineItem]) -> String? {
        for item in items {
            if item.rawEntryID == entryID {
                return item.id
            }
            if case .workRun(let run) = item, run.steps.contains(where: { $0.id == entryID }) {
                return item.id
            }
        }
        return nil
    }

    /// Returns raw entry IDs matching a case-insensitive in-session find query (mirroring `find-in-session.tsx`).
    public static func findMatchingEntryIDs(query: String, in items: [ThreadTimelineItem]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var matches: [String] = []
        for item in items {
            switch item {
            case .user(let id, let text, _, _, _):
                if text.lowercased().contains(needle) { matches.append(id) }
            case .sessionMessage(let id, _, let senderTitle, let text):
                if text.lowercased().contains(needle)
                    || (senderTitle?.lowercased().contains(needle) ?? false) {
                    matches.append(id)
                }
            case .sessionReport(let id, let from, let ended, _, _):
                if from.title.lowercased().contains(needle)
                    || ended.agent.lowercased().contains(needle) {
                    matches.append(id)
                }
            case .agent(let id, let markdown, _, _, _):
                if markdown.lowercased().contains(needle) { matches.append(id) }
            case .workRun(let run):
                if run.summaryText.lowercased().contains(needle)
                    || (run.liveHeadline?.lowercased().contains(needle) ?? false)
                    || run.steps.contains(where: {
                        $0.verb.lowercased().contains(needle)
                            || $0.target.lowercased().contains(needle)
                    }) {
                    matches.append(run.id)
                }
            case .notice(let id, _, let title, let desc, _, _):
                if title.lowercased().contains(needle) || (desc?.lowercased().contains(needle) ?? false) {
                    matches.append(id)
                }
            case .memory(let p):
                if p.title.lowercased().contains(needle)
                    || (p.draft?.body?.lowercased().contains(needle) ?? false) {
                    matches.append(p.id)
                }
            case .git(let p):
                if (p.branch?.lowercased().contains(needle) ?? false)
                    || p.commits.contains(where: { $0.subject.lowercased().contains(needle) || $0.oid.lowercased().contains(needle) }) {
                    matches.append(p.id)
                }
            case .permissionCard(let tool):
                if tool.title.lowercased().contains(needle)
                    || (tool.question?.lowercased().contains(needle) ?? false) {
                    matches.append(tool.id)
                }
            default:
                break
            }
        }
        return matches
    }

    public static func build(
        replica: ThreadReplica,
        l10n: PrismL10n,
        canForkSession: Bool = false,
        canForkAtMessage: Bool = false
    ) -> ThreadTimelineSnapshot {
        let cacheKey = SnapshotCacheKey(
            sessionId: replica.session.id,
            seq: replica.seq,
            entryCount: replica.order.count,
            status: replica.session.status,
            language: l10n.language,
            canForkSession: canForkSession,
            canForkAtMessage: canForkAtMessage,
            snapshotPlanCount: replica.snapshotPlan?.count ?? -1,
            turnStartedAt: replica.session.turnStartedAt
        )
        if let cached = memoCache.lookup(cacheKey) {
            return cached
        }
        let previous = memoCache.parts(for: replica.session.id)
        let projectPath = replica.session.projectPath
        let isLive = replica.session.status == .running || replica.session.status == .starting
        let forkAllowedNow = canForkSession
            && replica.session.status != .starting
            && replica.session.status != .failed
            && replica.session.status != .authRequired

        var latestPlan: [PlanItem]? = replica.snapshotPlan
        var visible: [ThreadEntry] = []
        visible.reserveCapacity(replica.order.count)
        var hasPendingPermission = false

        for entry in replica.entries {
            switch entry {
            case .plan(_, let items):
                if !items.isEmpty { latestPlan = items }
            case .user(_, _, _, _, let approval, _):
                if !approval { visible.append(entry) }
            case .tool(let data):
                if data.permission != nil { hasPendingPermission = true }
                visible.append(entry)
            case .unknown:
                break
            default:
                visible.append(entry)
            }
        }

        // The single actively-streaming agent message. Once the turn
        // stops running or any other entry follows, an agent message is never shown as streaming.
        var activeWritingIndex: Int? = nil
        if isLive {
            for idx in stride(from: visible.count - 1, through: 0, by: -1) {
                if case .notice = visible[idx] { continue }
                if case .agent(_, _, let streaming, _, _) = visible[idx], streaming {
                    activeWritingIndex = idx
                }
                break
            }
        }

        // The latest agent message in the whole thread.
        let latestAgentIndex = visible.lastIndex { entry in
            if case .agent = entry { return true }
            return false
        }

        // The latest retryable failed-turn notice.
        var retryableNoticeIndex: Int? = nil
        if !isLive && replica.session.status != .awaitingPermission {
            scan: for idx in stride(from: visible.count - 1, through: 0, by: -1) {
                switch visible[idx] {
                case .notice(_, _, _, _, let cause, _):
                    if let cause, !cause.isEmpty {
                        retryableNoticeIndex = idx
                        break scan
                    }
                case .user:
                    break scan
                default:
                    continue
                }
            }
        }

        var items: [ThreadTimelineItem] = []
        items.reserveCapacity(visible.count)
        var segments: [String: BuiltSegment] = [:]
        var runs: [String: BuiltRun] = [:]
        var turnStartID: String = visible.first?.id ?? "turn-0"
        var segmentStart = 0

        while segmentStart < visible.count {
            let segmentEnd = endOfSegment(in: visible, from: segmentStart)
            let range = segmentStart..<segmentEnd
            func idIfInSegment(_ index: Int?) -> String? {
                guard let index, range.contains(index) else { return nil }
                return visible[index].id
            }
            let context = SegmentContext(
                turnStartID: turnStartID,
                isFinal: segmentEnd == visible.count,
                isLive: isLive,
                forkAllowedNow: forkAllowedNow,
                canForkAtMessage: canForkAtMessage,
                language: l10n.language,
                projectPath: projectPath,
                activeWritingID: idIfInSegment(activeWritingIndex),
                latestAgentID: idIfInSegment(latestAgentIndex),
                retryableNoticeID: idIfInSegment(retryableNoticeIndex)
            )
            let slice = Array(visible[range])
            var sliceExtras: [String: ThreadEntryExtras] = [:]
            if !replica.entryExtras.isEmpty {
                for entry in slice {
                    if let extra = replica.entryExtras[entry.id] {
                        sliceExtras[entry.id] = extra
                    }
                }
            }
            let segmentID = slice[0].id
            let segment: BuiltSegment
            if let prior = previous.segments[segmentID],
               prior.context == context,
               prior.entries == slice,
               prior.entryExtras == sliceExtras {
                segment = prior
                for item in prior.items {
                    if case .workRun(let run) = item, let builtRun = previous.runs[run.id] {
                        runs[run.id] = builtRun
                    }
                }
            } else {
                segment = buildSegment(
                    slice,
                    entryExtras: sliceExtras,
                    context: context,
                    l10n: l10n,
                    previousRuns: previous.runs,
                    runs: &runs
                )
            }
            segments[segmentID] = segment
            items.append(contentsOf: segment.items)
            turnStartID = segment.nextTurnStartID
            segmentStart = segmentEnd
        }

        // Live Turn Status row (hidden while the latest agent message is actively streaming prose).
        if (isLive || replica.session.status == .awaitingPermission) && activeWritingIndex == nil {
            let status = computeLiveStatus(
                entries: visible,
                sessionStatus: replica.session.status,
                turnStartedAt: replica.session.turnStartedAt,
                l10n: l10n
            )
            items.append(.liveStatus(status))
        }

        // ACP text-fallback question card (e.g. Antigravity `agy acp` cancels `ask_question` and prints
        // `[1] [2] [3]` as plain text while holding an internal text-only pending question state).
        if !isLive && !hasPendingPermission,
           let pending = extractPendingAcpTextQuestions(from: visible)
        {
            items.append(.textQuestionCard(id: pending.id, questions: pending.questions))
        }

        #if os(macOS)
        let navEntries = Self.extractNavEntries(from: visible, entryExtras: replica.entryExtras, l10n: l10n)
        #else
        // Only the macOS timeline rail reads these.
        let navEntries: [ThreadTimelineNavEntry] = []
        #endif
        let snapshot = ThreadTimelineSnapshot(
            latestPlan: latestPlan,
            items: items,
            navEntries: navEntries,
            hasPendingPermission: hasPendingPermission
        )
        memoCache.store(.init(key: cacheKey, snapshot: snapshot, segments: segments, runs: runs))
        return snapshot
    }

    /// A segment ends after a turn end, or before the next real (not steered) user prompt. Work
    /// runs never cross either, and a notice or compaction marker never looks past them.
    private static func endOfSegment(in visible: [ThreadEntry], from start: Int) -> Int {
        var idx = start
        while idx < visible.count {
            switch visible[idx] {
            case .user(_, _, _, _, _, let steered) where !steered && idx > start:
                return idx
            case .turnEnd:
                return idx + 1
            default:
                idx += 1
            }
        }
        return idx
    }

    private static func buildSegment(
        _ entries: [ThreadEntry],
        entryExtras: [String: ThreadEntryExtras],
        context ctx: SegmentContext,
        l10n: PrismL10n,
        previousRuns: [String: BuiltRun],
        runs: inout [String: BuiltRun]
    ) -> BuiltSegment {
        var items: [ThreadTimelineItem] = []
        var turnAgentTexts: [String] = []
        var turnLastAgentID: String? = nil
        var turnTools: [ToolEntryData] = []
        var turnStartID = ctx.turnStartID

        func flushTurnFooter(stopReason: String?, durationMs: Double?, keyID: String) {
            let changes = aggregateChanges(from: turnTools, projectPath: ctx.projectPath)
            let replyText = turnAgentTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !changes.isEmpty || !replyText.isEmpty || (stopReason != nil && stopReason != "end_turn") {
                let totalIns = changes.reduce(0) { $0 + $1.insertions }
                let totalDel = changes.reduce(0) { $0 + $1.deletions }
                // Latest reply forks the whole session ("__latest__" -> entryId nil),
                // earlier replies only offer Fork if the agent supports forkAtMessage.
                let resolvedForkID: String? = {
                    guard ctx.forkAllowedNow, let lastID = turnLastAgentID else { return nil }
                    if lastID == ctx.latestAgentID {
                        return "__latest__"
                    }
                    return ctx.canForkAtMessage ? lastID : nil
                }()
                items.append(.turnFooter(TurnFooterSummary(
                    id: keyID,
                    replyText: replyText,
                    forkEntryID: resolvedForkID,
                    changedFiles: changes,
                    totalInsertions: totalIns,
                    totalDeletions: totalDel,
                    stopReason: stopReason,
                    durationMs: durationMs
                )))
            }
            turnAgentTexts = []
            turnLastAgentID = nil
            turnTools = []
        }

        var i = 0
        while i < entries.count {
            let entry = entries[i]

            if foldsIntoWorkRun(entry) {
                var end = i
                while end + 1 < entries.count && foldsIntoWorkRun(entries[end + 1]) {
                    end += 1
                }
                let slice = Array(entries[i...end])
                for step in slice {
                    if case .tool(let data) = step {
                        turnTools.append(data)
                    }
                }
                let runContext = RunContext(
                    isSessionLive: ctx.isLive,
                    isLatestLive: end == entries.count - 1 && ctx.isFinal && ctx.isLive,
                    language: ctx.language,
                    projectPath: ctx.projectPath
                )
                let runID = slice[0].id
                let summary: WorkRunSummary
                if let prior = previousRuns[runID], prior.context == runContext, prior.entries == slice {
                    summary = prior.summary
                } else {
                    summary = buildWorkRun(
                        entries: slice,
                        projectPath: ctx.projectPath,
                        isSessionLive: runContext.isSessionLive,
                        isLatestLive: runContext.isLatestLive,
                        l10n: l10n
                    )
                }
                runs[runID] = BuiltRun(entries: slice, context: runContext, summary: summary)
                items.append(.workRun(summary))
                i = end + 1
                continue
            }

            switch entry {
            case .user(let id, let text, let content, let at, _, let steered):
                if !steered && (!turnAgentTexts.isEmpty || !turnTools.isEmpty) {
                    flushTurnFooter(stopReason: nil, durationMs: nil, keyID: "hist-\(turnStartID)")
                }
                if !steered {
                    turnStartID = id
                }
                if let from = entryExtras[id]?.from, let ended = from.ended {
                    items.append(.sessionReport(id: id, from: from, ended: ended, at: at, steered: steered))
                } else if let from = entryExtras[id]?.from {
                    items.append(.sessionMessage(
                        id: id,
                        senderId: from.sessionId,
                        senderTitle: from.title.isEmpty ? nil : from.title,
                        text: text
                    ))
                } else {
                    items.append(.user(id: id, text: text, content: content, at: at, steered: steered))
                }

            case .agent(let id, let markdown, _, let at, let attachments):
                if !isBlank(markdown) {
                    turnAgentTexts.append(markdown)
                }
                turnLastAgentID = id
                items.append(.agent(id: id, markdown: markdown, streaming: id == ctx.activeWritingID, at: at, attachments: attachments))

            case .tool(let data):
                // Standalone waiting OR answered permission / plan / question / elicitation card.
                turnTools.append(data)
                items.append(.permissionCard(data))

            case .subagent(let id, let sessionId):
                items.append(.subagent(id: id, sessionId: sessionId))

            case .sessionStarted(let id, let sessionId, _):
                items.append(.sessionStarted(id: id, sessionId: sessionId))

            case .sessionMessage(let id, let senderId, let content):
                let joined = content.compactMap(\.text).joined(separator: "\n")
                items.append(.sessionMessage(id: id, senderId: senderId, senderTitle: nil, text: joined))

            case .takeover(let id, let agentId, let turns, let omitted, _, let summarize):
                items.append(.takeover(id: id, agentId: agentId, turns: turns, omitted: omitted, summarize: summarize ?? false))

            case .notice(let id, let severity, let title, let description, let cause, _):
                // Collapse consecutive identical notices (e.g. repeated error banners) to the latest one.
                if i + 1 < entries.count,
                   case .notice(_, let nextSev, let nextTitle, let nextDesc, let nextCause, _) = entries[i + 1],
                   nextSev == severity,
                   nextTitle == title,
                   nextDesc == description,
                   nextCause == cause {
                    break
                }
                items.append(.notice(
                    id: id,
                    severity: severity,
                    title: title,
                    description: description,
                    cause: cause,
                    canRetry: id == ctx.retryableNoticeID
                ))

            case .compaction(let id, let status, let summary):
                // Collapse consecutive compaction markers to the latest one.
                if i + 1 < entries.count, case .compaction = entries[i + 1] {
                    break
                }
                items.append(.compaction(id: id, status: status, summary: summary))

            case .git(let payload):
                items.append(.git(payload))
            case .artifact:
                break
            case .memory(let payload):
                items.append(.memory(payload))
            case .settingsChange(let payload):
                items.append(.settingsChange(payload))
            case .browserOrigin(let payload):
                items.append(.browserOrigin(payload))
            case .controlAsk(let payload):
                items.append(.controlAsk(payload))
            case .controlNote(let payload):
                items.append(.controlNote(payload))
            case .deviceAccess(let payload):
                items.append(.deviceAccess(payload))
            case .surfaceAccess(let payload):
                items.append(.surfaceAccess(payload))
            case .computerApp(let payload):
                items.append(.computerApp(payload))
            case .computerSetup(let payload):
                items.append(.computerSetup(payload))
            case .projectMcp(let payload):
                items.append(.projectMcp(payload))
            case .projectHooks(let payload):
                items.append(.projectHooks(payload))
            case .problemReport(let payload):
                items.append(.problemReport(payload))
            case .marketPublish(let payload):
                items.append(.marketPublish(payload))

            case .turnEnd(let id, let stopReason, let durationMs):
                flushTurnFooter(stopReason: stopReason, durationMs: durationMs, keyID: id)

            case .thought, .plan, .unknown:
                break
            }
            i += 1
        }

        if !turnAgentTexts.isEmpty || !turnTools.isEmpty {
            if !ctx.isFinal {
                // The next segment opens with a real user prompt, which closes this turn.
                flushTurnFooter(stopReason: nil, durationMs: nil, keyID: "hist-\(turnStartID)")
            } else if !ctx.isLive {
                // History session without trailing turnEnd: still show changes/copy/fork footer once not running.
                flushTurnFooter(stopReason: nil, durationMs: nil, keyID: "tail-\(turnStartID)")
            }
        }

        return BuiltSegment(entries: entries, entryExtras: entryExtras, context: ctx, items: items, nextTurnStartID: turnStartID)
    }

    /// Extracts chronological real user turns + each turn's final assistant answer excerpt for the left timeline rail.
    private static func extractNavEntries(
        from visible: [ThreadEntry],
        entryExtras: [String: ThreadEntryExtras],
        l10n: PrismL10n
    ) -> [ThreadTimelineNavEntry] {
        struct DraftNav {
            let entryID: String
            let promptPreview: String
            let attachmentCount: Int
            var answers: [(id: String, markdown: String)]
        }

        var drafts: [DraftNav] = []
        for entry in visible {
            switch entry {
            case .user(let id, let text, let content, _, let approval, let steered):
                guard !approval, !steered else { continue }
                let preview: String
                if let from = entryExtras[id]?.from, let ended = from.ended {
                    let title = from.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let display = title.isEmpty ? String(from.sessionId.prefix(8)) : title
                    preview = l10n.tr("thread.sessionReport.nav", ended.agent, display)
                } else {
                    preview = excerptCache.excerpt(id: id, text: text, maxChars: 120)
                }
                let attCount = content.reduce(0) { acc, part in
                    if case .ref = part { return acc + 1 }
                    return acc
                }
                guard !preview.isEmpty || attCount > 0 else { continue }
                drafts.append(DraftNav(
                    entryID: id,
                    promptPreview: preview,
                    attachmentCount: attCount,
                    answers: []
                ))

            case .agent(let id, let markdown, _, _, _):
                guard !drafts.isEmpty else { continue }
                drafts[drafts.count - 1].answers.append((id, markdown))

            default:
                break
            }
        }

        return drafts.enumerated().map { idx, d in
            // Only the turn's last non-empty answer is shown, so earlier replies are never flattened.
            var lastAnswer: String? = nil
            for answer in d.answers.reversed() {
                let excerpt = excerptCache.excerpt(id: answer.id, text: answer.markdown, maxChars: 200)
                if !excerpt.isEmpty {
                    lastAnswer = excerpt
                    break
                }
            }
            return ThreadTimelineNavEntry(
                id: d.entryID,
                entryID: d.entryID,
                scrollItemID: "u:\(d.entryID)",
                turnNumber: idx + 1,
                promptPreview: d.promptPreview,
                attachmentCount: d.attachmentCount,
                answerExcerpt: lastAnswer,
                pos: nil,
                isLoaded: true
            )
        }
    }

    /// Merges the host's full-session `sessions.outline` list (which spans unloaded older pages)
    /// with the currently loaded `navEntries` (which carry attachment counts & final AI reply excerpts).
    /// Mirrors `src/renderer/src/features/session/outline/use-outline.ts`.
    public static func mergeNavEntries(
        outline: [OutlineEntryInfo],
        loaded: [ThreadTimelineNavEntry]
    ) -> [ThreadTimelineNavEntry] {
        guard !outline.isEmpty else { return loaded }
        if let memo = navMergeMemo.lookup(outline: outline, loaded: loaded) {
            return memo
        }

        var loadedByID: [String: ThreadTimelineNavEntry] = [:]
        loadedByID.reserveCapacity(loaded.count)
        for item in loaded {
            loadedByID[item.entryID] = item
        }

        var merged: [ThreadTimelineNavEntry] = []
        merged.reserveCapacity(max(outline.count, loaded.count))
        var seen: Set<String> = []
        seen.reserveCapacity(outline.count + loaded.count)

        for row in outline {
            guard seen.insert(row.entryId).inserted else { continue }
            if let rich = loadedByID[row.entryId] {
                let preferredPrompt: String = {
                    if let t = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                        return excerptCache.excerpt(id: "outline:\(row.entryId)", text: t, maxChars: 120)
                    }
                    return rich.promptPreview
                }()
                merged.append(ThreadTimelineNavEntry(
                    id: rich.id,
                    entryID: rich.entryID,
                    scrollItemID: rich.scrollItemID,
                    turnNumber: merged.count + 1,
                    promptPreview: preferredPrompt,
                    attachmentCount: rich.attachmentCount,
                    answerExcerpt: rich.answerExcerpt,
                    pos: row.pos,
                    isLoaded: true
                ))
            } else {
                let rawLabel = (row.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? row.text
                let preview = excerptCache.excerpt(id: "outline:\(row.entryId)", text: rawLabel, maxChars: 120)
                merged.append(ThreadTimelineNavEntry(
                    id: row.entryId,
                    entryID: row.entryId,
                    scrollItemID: "u:\(row.entryId)",
                    turnNumber: merged.count + 1,
                    promptPreview: preview,
                    attachmentCount: 0,
                    answerExcerpt: nil,
                    pos: row.pos,
                    isLoaded: false
                ))
            }
        }

        // Append brand-new live loaded user turns not yet reflected in the cached host outline.
        for item in loaded where !seen.contains(item.entryID) {
            merged.append(ThreadTimelineNavEntry(
                id: item.id,
                entryID: item.entryID,
                scrollItemID: item.scrollItemID,
                turnNumber: merged.count + 1,
                promptPreview: item.promptPreview,
                attachmentCount: item.attachmentCount,
                answerExcerpt: item.answerExcerpt,
                pos: item.pos,
                isLoaded: true
            ))
        }

        navMergeMemo.store(outline: outline, loaded: loaded, merged: merged)
        return merged
    }

    private static let fencedExcerptRegex = try! NSRegularExpression(pattern: "```[\\s\\S]*?```", options: [])

    /// Excerpts keep at most a couple of hundred characters, so only a bounded head of the text is
    /// flattened; a reply streaming in would otherwise be scanned in full on every token.
    private static let excerptSourceLimit = 4096

    private static func flattenExcerpt(_ raw: String, maxChars: Int) -> String {
        let source = raw.utf8.count > excerptSourceLimit ? String(raw.prefix(excerptSourceLimit)) : raw
        let withoutFences = fencedExcerptRegex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: " [code] "
        )
        let stripped = withoutFences
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .replacingOccurrences(of: "#", with: "")
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars - 1)) + "…"
    }

    /// Whether `text` has no visible characters, without copying it the way trimming does.
    static func isBlank(_ text: String) -> Bool {
        !text.unicodeScalars.contains { !$0.properties.isWhitespace }
    }
    /// Detects an unanswered ACP `ask_question` tool call whose agent fell back to plain-text Q&A
    /// (notably `agy acp`, which cancels the tool call, prints numbered options as markdown, and waits
    /// for a plain-text next prompt without image attachments).
    private static func extractPendingAcpTextQuestions(
        from visible: [ThreadEntry]
    ) -> (id: String, questions: [PendingQuestion])? {
        // Locate the most recent `ask_question` tool entry without a native permission payload.
        var matchIndex: Int? = nil
        var matchTool: ToolEntryData? = nil

        for idx in stride(from: visible.count - 1, through: 0, by: -1) {
            switch visible[idx] {
            case .tool(let data):
                if data.permission == nil,
                   let parsed = parseAcpQuestionRawInput(data.rawInput, title: data.title),
                   !parsed.isEmpty
                {
                    matchIndex = idx
                    matchTool = data
                    break
                }
                // A newer non-question tool means the agent already moved past any earlier question.
                return nil
            default:
                continue
            }
            if matchIndex != nil { break }
        }

        guard let startIdx = matchIndex,
              let tool = matchTool,
              let questions = parseAcpQuestionRawInput(tool.rawInput, title: tool.title),
              !questions.isEmpty
        else { return nil }

        // Walk forward from the `ask_question` tool call:
        // - Ignore the immediate assistant text mirror & its `turnEnd` from the same turn.
        // - After that turn ends, any agent reply, tool call, or text-only user message means answered.
        // - User messages containing images that failed with `"pending question ... reply in text"`
        //   did NOT clear the agent's pending question, so keep the card active.
        var sawTurnEnd = false
        var idx = startIdx + 1
        while idx < visible.count {
            let entry = visible[idx]
            if !sawTurnEnd {
                if case .turnEnd = entry {
                    sawTurnEnd = true
                } else if case .user = entry {
                    sawTurnEnd = true
                    continue
                }
                idx += 1
                continue
            }

            switch entry {
            case .agent, .tool:
                return nil
            case .user(_, _, let content, _, _, _):
                let hasImage = content.contains { part in
                    if case .ref(let ref) = part {
                        switch ref {
                        case .imageData, .imageBlob: return true
                        case .attachment(let att): return att.type == "image"
                        default: return false
                        }
                    }
                    return false
                }
                if !hasImage {
                    return nil
                }
                // Image prompt: only still pending if immediately rejected with a pending-question notice.
                var rejectedForPendingQuestion = false
                var lookahead = idx + 1
                while lookahead < visible.count {
                    if case .notice(_, _, _, let desc, _, _) = visible[lookahead] {
                        let lower = (desc ?? "").lowercased()
                        if lower.contains("pending question") && lower.contains("reply in text") {
                            rejectedForPendingQuestion = true
                        }
                        lookahead += 1
                    } else {
                        break
                    }
                }
                if !rejectedForPendingQuestion {
                    return nil
                }
            default:
                break
            }
            idx += 1
        }

        return (id: tool.id, questions: questions)
    }

    private static func parseAcpQuestionRawInput(_ rawInput: String?, title: String) -> [PendingQuestion]? {
        guard let raw = rawInput?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.first == "{",
              title.lowercased().contains("ask_question") || raw.contains("\"questions\""),
              let data = raw.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["questions"] as? [[String: Any]],
              !list.isEmpty
        else { return nil }

        var parsed: [PendingQuestion] = []
        for item in list {
            guard let prompt = item["question"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let multi = (item["is_multi_select"] as? Bool)
                ?? (item["multiSelect"] as? Bool)
                ?? (item["multi_select"] as? Bool)
                ?? false
            let header = (item["header"] as? String) ?? ""

            var options: [PendingQuestionOption] = []
            if let strOptions = item["options"] as? [String] {
                options = strOptions
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { PendingQuestionOption(label: $0) }
            } else if let objOptions = item["options"] as? [[String: Any]] {
                options = objOptions.compactMap { obj in
                    guard let label = (obj["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !label.isEmpty
                    else { return nil }
                    return PendingQuestionOption(label: label, description: obj["description"] as? String)
                }
            }
            guard !options.isEmpty else { continue }

            parsed.append(PendingQuestion(
                header: header,
                question: prompt,
                multiSelect: multi,
                options: options,
                allowsText: true,
                secret: false
            ))
        }

        return parsed.isEmpty ? nil : parsed
    }

    private static func foldsIntoWorkRun(_ entry: ThreadEntry) -> Bool {
        switch entry {
        case .thought:
            return true
        case .tool(let data):
            if data.permission != nil || data.question != nil || data.planVersion != nil || data.elicitation != nil {
                return false
            }
            if let permRes = data.permissionResult, permRes != .null {
                if permRes.stringValue == "cancelled" || permRes.stringValue == "withdrawn" {
                    return false
                }
                if permRes.objectValue != nil {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    private static func buildWorkRun(
        entries: [ThreadEntry],
        projectPath: String,
        isSessionLive: Bool,
        isLatestLive: Bool,
        l10n: PrismL10n
    ) -> WorkRunSummary {
        let firstID = entries.first?.id ?? UUID().uuidString
        var steps: [WorkStepPresentation] = []
        steps.reserveCapacity(entries.count)

        var createdPaths: Set<String> = []
        for entry in entries {
            if case .tool(let data) = entry {
                for item in data.content {
                    if case .diff(let path, let oldText, _) = item, oldText == nil {
                        createdPaths.insert(path)
                    }
                }
            }
        }

        var totalIns = 0
        var totalDel = 0
        var failedCount = 0
        var anyRunning = false
        var totalThoughtMs: Double = 0
        var hasDuration = false

        enum SummaryKind: Hashable {
            case read, create, edit, delete, move, execute, search, fetch, other, thought
        }

        var kindOrder: [SummaryKind] = []
        var pathsByKind: [SummaryKind: [String?]] = [:]
        var countsByKind: [SummaryKind: Int] = [:]
        var singleCommandDesc: String? = nil
        var ownLabels: [String] = []

        func recordKind(_ kind: SummaryKind, path: String? = nil) {
            if !kindOrder.contains(kind) { kindOrder.append(kind) }
            countsByKind[kind, default: 0] += 1
            if let path {
                pathsByKind[kind, default: []].append(path)
            } else if kind == .read || kind == .create || kind == .edit || kind == .delete || kind == .move {
                pathsByKind[kind, default: []].append(nil)
            }
        }

        for entry in entries {
            switch entry {
            case .thought(let id, let markdown, let streaming, let durationMs):
                let activeStreaming = streaming && isSessionLive && isLatestLive
                if activeStreaming { anyRunning = true }
                if let ms = durationMs {
                    totalThoughtMs += ms
                    hasDuration = true
                }
                recordKind(.thought)
                let title = thoughtTitle(markdown) ?? (activeStreaming ? l10n.tr("thread.thinkingActive") : l10n.tr("thread.thinkingDone"))
                steps.append(WorkStepPresentation(
                    id: id,
                    entry: entry,
                    iconName: "sparkle",
                    verb: activeStreaming ? l10n.tr("thread.thinkingActive") : l10n.tr("thread.thinkingDone"),
                    target: title == l10n.tr("thread.thinkingActive") || title == l10n.tr("thread.thinkingDone") ? "" : title,
                    isRunning: activeStreaming,
                    isFailed: false,
                    isCancelled: false,
                    insertions: 0,
                    deletions: 0,
                    durationMs: durationMs,
                    hasDetails: !isBlank(markdown)
                ))

            case .tool(let data):
                let running = isSessionLive && (data.status == "pending" || data.status == "in_progress")
                let failed = data.status == "failed"
                let cancelled = data.status == "cancelled"
                if running { anyRunning = true }
                if failed { failedCount += 1 }
                if let lbl = data.label, !lbl.isEmpty, !ownLabels.contains(lbl) {
                    ownLabels.append(lbl)
                }

                var stepIns = 0
                var stepDel = 0
                var diffPaths: [String] = []
                for item in data.content {
                    switch item {
                    case .diff(let path, let oldText, let newText):
                        diffPaths.append(path)
                        let stats = ThreadDiffCache.shared.compute(path: path, oldText: oldText, newText: newText)
                        stepIns += stats.insertions
                        stepDel += stats.deletions
                    case .digest(let of, let path?, _, _, let added, let removed) where of == "diff":
                        diffPaths.append(path)
                        stepIns += added ?? 0
                        stepDel += removed ?? 0
                    default:
                        break
                    }
                }
                totalIns += stepIns
                totalDel += stepDel

                let effectiveKind = inferredToolKind(data)
                let primaryPath = diffPaths.first ?? data.locations.first?.path ?? extractPathFromTitle(data.title)

                switch effectiveKind {
                case "edit":
                    let touched = !diffPaths.isEmpty ? Array(Set(diffPaths)) : (primaryPath.map { [$0] } ?? [])
                    if touched.isEmpty {
                        recordKind(.edit, path: nil)
                    } else {
                        for p in touched {
                            recordKind(createdPaths.contains(p) ? .create : .edit, path: p)
                        }
                    }
                case "read":
                    recordKind(.read, path: primaryPath)
                case "delete":
                    recordKind(.delete, path: primaryPath)
                case "move":
                    recordKind(.move, path: primaryPath)
                case "execute":
                    recordKind(.execute)
                    if singleCommandDesc == nil, let desc = data.description, !desc.isEmpty {
                        singleCommandDesc = desc
                    }
                case "search":
                    recordKind(.search)
                case "fetch":
                    recordKind(.fetch)
                default:
                    recordKind(.other)
                }

                let isCreated = primaryPath.map { createdPaths.contains($0) } ?? false
                let (verb, target) = formatStepLabel(
                    data: data,
                    effectiveKind: effectiveKind,
                    primaryPath: primaryPath,
                    isCreated: isCreated,
                    projectPath: projectPath,
                    l10n: l10n
                )
                let hasDetails = !data.content.isEmpty
                    || !(data.rawInput.map(isBlank) ?? true)
                    || data.hasDigestedContent
                    || failed

                steps.append(WorkStepPresentation(
                    id: data.id,
                    entry: entry,
                    iconName: iconForToolKind(effectiveKind),
                    verb: verb,
                    target: target,
                    isRunning: running,
                    isFailed: failed,
                    isCancelled: cancelled,
                    insertions: stepIns,
                    deletions: stepDel,
                    durationMs: nil,
                    hasDetails: hasDetails
                ))

            default:
                break
            }
        }

        // Build concise summary parts ("Read a.swift · Edited b.swift · Ran 2 commands")
        let nonThoughtKinds = kindOrder.filter { $0 != .thought }
        let chosenKinds = nonThoughtKinds.isEmpty ? kindOrder : nonThoughtKinds
        var summaryParts: [String] = []

        if !ownLabels.isEmpty {
            summaryParts.append(contentsOf: ownLabels.prefix(2))
        }

        for kind in chosenKinds {
            if !ownLabels.isEmpty && (kind == .read || kind == .search || kind == .fetch) {
                continue
            }
            let count = countsByKind[kind] ?? 0
            switch kind {
            case .read:
                summaryParts.append(formatFilePart(prefix: "read", paths: pathsByKind[.read] ?? [], l10n: l10n))
            case .create:
                summaryParts.append(formatFilePart(prefix: "create", paths: pathsByKind[.create] ?? [], l10n: l10n))
            case .edit:
                summaryParts.append(formatFilePart(prefix: "edit", paths: pathsByKind[.edit] ?? [], l10n: l10n))
            case .delete:
                summaryParts.append(formatFilePart(prefix: "delete", paths: pathsByKind[.delete] ?? [], l10n: l10n))
            case .move:
                summaryParts.append(formatFilePart(prefix: "move", paths: pathsByKind[.move] ?? [], l10n: l10n))
            case .execute:
                if count == 1, let desc = singleCommandDesc {
                    summaryParts.append(desc)
                } else if count == 1 {
                    summaryParts.append(l10n.tr("thread.summary.executeOne"))
                } else {
                    summaryParts.append(l10n.tr("thread.summary.executeMany", count))
                }
            case .search:
                summaryParts.append(count == 1 ? l10n.tr("thread.summary.searchOne") : l10n.tr("thread.summary.searchMany", count))
            case .fetch:
                summaryParts.append(count == 1 ? l10n.tr("thread.summary.fetchOne") : l10n.tr("thread.summary.fetchMany", count))
            case .other:
                if count == 1, let onlyStep = steps.first(where: {
                    if case .tool = $0.entry { return true }
                    return false
                }) {
                    summaryParts.append(onlyStep.target.isEmpty ? onlyStep.verb : "\(onlyStep.verb) \(onlyStep.target)")
                } else {
                    summaryParts.append(count == 1 ? l10n.tr("thread.summary.toolOne") : l10n.tr("thread.summary.toolMany", count))
                }
            case .thought:
                if anyRunning {
                    summaryParts.append(l10n.tr("thread.thinkingActive"))
                } else if totalThoughtMs >= 1000 {
                    summaryParts.append(l10n.tr("thread.summary.thoughtFor", formatDuration(totalThoughtMs)))
                } else {
                    summaryParts.append(l10n.tr("thread.thinkingDone"))
                }
            }
        }

        let summaryText = summaryParts.isEmpty
            ? l10n.tr("thread.summary.working")
            : summaryParts.joined(separator: l10n.tr("thread.summary.separator"))

        let isLiveRun = anyRunning || isLatestLive
        let liveHeadline: String? = isLiveRun
            ? computeLiveRunHeadline(steps: steps, l10n: l10n)
            : nil

        // Stacked icons of latest distinct step kinds (up to 3).
        // When a step is actively running, keep its icon rightmost so the highlight matches liveHeadline.
        var stacked: [String] = []
        for step in steps.reversed() {
            if !stacked.contains(step.iconName) {
                stacked.insert(step.iconName, at: 0)
                if stacked.count >= 3 { break }
            }
        }
        if isLiveRun, let activeIcon = steps.last(where: { $0.isRunning })?.iconName {
            stacked.removeAll { $0 == activeIcon }
            stacked.append(activeIcon)
            if stacked.count > 3 {
                stacked.removeFirst(stacked.count - 3)
            }
        }

        // Collect image refs produced by tool steps for inline RowThumbs previews (up to 4).
        var imageRefs: [ContentRef] = []
        for entry in entries {
            if case .tool(let data) = entry {
                for item in data.content {
                    if case .ref(let ref) = item {
                        switch ref {
                        case .imageData, .imageBlob:
                            imageRefs.append(ref)
                        case .attachment(let att) where att.type == "image":
                            imageRefs.append(ref)
                        default:
                            break
                        }
                        if imageRefs.count >= 4 { break }
                    }
                }
            }
            if imageRefs.count >= 4 { break }
        }

        return WorkRunSummary(
            id: firstID,
            steps: steps,
            isRunning: anyRunning,
            isLive: isLiveRun,
            failedCount: failedCount,
            summaryText: summaryText,
            liveHeadline: liveHeadline,
            stackedIcons: stacked,
            imageRefs: imageRefs,
            totalInsertions: totalIns,
            totalDeletions: totalDel,
            totalDurationMs: hasDuration && !isLiveRun ? totalThoughtMs : nil
        )
    }

    private static func aggregateChanges(
        from tools: [ToolEntryData],
        projectPath: String
    ) -> [TurnFileChange] {
        var order: [String] = []
        var seenPaths: Set<String> = []
        var diffsByPath: [String: [ToolDiffPayload]] = [:]
        var digestInsByPath: [String: Int] = [:]
        var digestDelByPath: [String: Int] = [:]
        var digestEntryIDsByPath: [String: [String]] = [:]

        for tool in tools {
            guard tool.status == "completed" || tool.status == "in_progress" else { continue }
            for item in tool.content {
                switch item {
                case .diff(let path, let oldText, let newText):
                    if seenPaths.insert(path).inserted { order.append(path) }
                    diffsByPath[path, default: []].append(ToolDiffPayload(path: path, oldText: oldText, newText: newText))
                case .digest(let of, let path?, _, _, let added, let removed) where of == "diff":
                    if seenPaths.insert(path).inserted { order.append(path) }
                    digestInsByPath[path, default: 0] += added ?? 0
                    digestDelByPath[path, default: 0] += removed ?? 0
                    var ids = digestEntryIDsByPath[path] ?? []
                    if !ids.contains(tool.id) {
                        ids.append(tool.id)
                        digestEntryIDsByPath[path] = ids
                    }
                default:
                    break
                }
            }
        }

        return order.map { path in
            let diffs = diffsByPath[path] ?? []
            var ins = digestInsByPath[path] ?? 0
            var del = digestDelByPath[path] ?? 0
            var isNew = false
            for d in diffs {
                if d.oldText == nil { isNew = true }
                let stats = ThreadDiffCache.shared.compute(path: d.path, oldText: d.oldText, newText: d.newText)
                ins += stats.insertions
                del += stats.deletions
            }
            let rel = relativeDisplayPath(path, projectPath: projectPath)
            let parts = splitDirAndFile(rel)
            return TurnFileChange(
                path: path,
                displayPath: rel,
                directoryPrefix: parts.dir,
                fileName: parts.file,
                diffs: diffs,
                insertions: ins,
                deletions: del,
                isNewFile: isNew,
                digestEntryIDs: digestEntryIDsByPath[path] ?? []
            )
        }
    }

    private static func computeLiveStatus(
        entries: [ThreadEntry],
        sessionStatus: SessionStatus,
        turnStartedAt: Double?,
        l10n: PrismL10n
    ) -> LiveTurnStatus {
        if sessionStatus == .awaitingPermission {
            return LiveTurnStatus(phase: .waiting, phaseText: l10n.tr("thread.phase.waiting"), isWaiting: true, startedAtMs: turnStartedAt)
        }
        var sawTools = false
        for entry in entries.reversed() {
            switch entry {
            case .tool(let data):
                if data.permission != nil {
                    return LiveTurnStatus(phase: .waiting, phaseText: l10n.tr("thread.phase.waiting"), isWaiting: true, startedAtMs: turnStartedAt)
                }
                if data.status == "pending" || data.status == "in_progress" {
                    let kind = inferredToolKind(data)
                    let phase: PrismTurnPhase
                    let key: String
                    switch kind {
                    case "read":
                        phase = .read
                        key = "thread.phase.reading"
                    case "edit", "delete", "move":
                        phase = .edit
                        key = "thread.phase.editing"
                    case "search":
                        phase = .search
                        key = "thread.phase.searching"
                    case "fetch":
                        phase = .fetch
                        key = "thread.phase.searching"
                    case "execute":
                        phase = .execute
                        key = "thread.phase.executing"
                    default:
                        phase = .working
                        key = "thread.phase.working"
                    }
                    return LiveTurnStatus(phase: phase, phaseText: l10n.tr(key), isWaiting: false, startedAtMs: turnStartedAt)
                }
                sawTools = true
                continue
            case .compaction(_, let status, _):
                if status == "running" || status == "in_progress" {
                    return LiveTurnStatus(phase: .compacting, phaseText: l10n.tr("thread.phase.working"), isWaiting: false, startedAtMs: turnStartedAt)
                }
                break
            case .thought(_, _, let streaming, _):
                if sawTools { break }
                if streaming {
                    return LiveTurnStatus(phase: .thinking, phaseText: l10n.tr("thread.phase.thinking"), isWaiting: false, startedAtMs: turnStartedAt)
                }
                break
            case .user, .turnEnd, .agent:
                break
            default:
                continue
            }
            break
        }
        return LiveTurnStatus(phase: .thinking, phaseText: l10n.tr("thread.phase.thinking"), isWaiting: false, startedAtMs: turnStartedAt)
    }

    // MARK: - Formatting Helpers

    private static func computeLiveRunHeadline(
        steps: [WorkStepPresentation],
        l10n: PrismL10n
    ) -> String? {
        var latestRunningTool: WorkStepPresentation? = nil
        var runningToolCount = 0
        for step in steps.reversed() {
            guard step.isRunning else { continue }
            if case .tool = step.entry {
                if latestRunningTool == nil { latestRunningTool = step }
                runningToolCount += 1
            }
        }
        if let activeTool = latestRunningTool,
           let text = formatLiveStepHeadline(activeTool) {
            return runningToolCount > 1 ? "\(text) (+\(runningToolCount - 1))" : text
        }

        for step in steps.reversed() {
            if step.isRunning, case .thought(_, let md, _, _) = step.entry {
                return liveThoughtHeadline(md) ?? thoughtTitle(md) ?? l10n.tr("thread.thinkingActive")
            }
        }

        // Between steps in a live turn, keep showing the most recent operation instead of
        // jumping back to an older thought or flickering to the static summary.
        for step in steps.reversed() {
            switch step.entry {
            case .tool:
                if let text = formatLiveStepHeadline(step) { return text }
            case .thought(_, let md, _, _):
                if let text = liveThoughtHeadline(md) ?? thoughtTitle(md) { return text }
            default:
                continue
            }
        }
        return nil
    }

    private static func formatLiveStepHeadline(_ step: WorkStepPresentation) -> String? {
        guard case .tool(let data) = step.entry else { return nil }
        let effectiveKind = inferredToolKind(data)
        if effectiveKind == "execute", let desc = data.description, !isBlank(desc) {
            return truncateSingleLine(desc, maxChars: 96)
        }
        if (effectiveKind == "search" || effectiveKind == "fetch"),
           let summary = extractToolSummary(data.rawInput) {
            return truncateSingleLine(summary, maxChars: 96)
        }
        if effectiveKind == "other" {
            if let label = data.label, !isBlank(label) {
                return truncateSingleLine(label, maxChars: 96)
            }
            if let desc = data.description, !isBlank(desc) {
                return truncateSingleLine(desc, maxChars: 96)
            }
            if let summary = extractToolSummary(data.rawInput) {
                return truncateSingleLine(summary, maxChars: 96)
            }
        }
        let combined = step.target.isEmpty ? step.verb : "\(step.verb) \(step.target)"
        return isBlank(combined) ? nil : truncateSingleLine(combined, maxChars: 96)
    }

    private static func localizedAgyToolLabel(_ data: ToolEntryData, l10n: PrismL10n) -> String? {
        let trimmed = data.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName: String
        if trimmed.hasPrefix("Run ") {
            rawName = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        } else {
            rawName = trimmed
        }
        let tool = rawName.lowercased()
        let rawObj: [String: Any]? = {
            guard let raw = data.rawInput,
                  raw.contains("{"),
                  let bytes = raw.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
            else { return nil }
            return obj
        }()
        switch tool {
        case "invoke_subagent":
            let base = l10n.tr("thread.agyTool.invoke_subagent")
            if let role = rawObj?["Role"] as? String, !isBlank(role) {
                return "\(base): \(role.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return base
        case "send_message":
            return l10n.tr("thread.agyTool.send_message")
        case "wait":
            return l10n.tr("thread.agyTool.wait")
        case "cron":
            return l10n.tr("thread.agyTool.cron")
        case "schedule":
            return l10n.tr("thread.agyTool.schedule")
        case "manage_task":
            let action = (rawObj?["Action"] as? String)?.lowercased() ?? ""
            switch action {
            case "list", "status", "kill", "send_input":
                return l10n.tr("thread.agyTool.manage_task.\(action)")
            default:
                return l10n.tr("thread.agyTool.manage_task.default")
            }
        case "manage_subagents":
            let action = (rawObj?["Action"] as? String)?.lowercased() ?? ""
            switch action {
            case "list", "kill", "kill_all":
                return l10n.tr("thread.agyTool.manage_subagents.\(action)")
            default:
                return l10n.tr("thread.agyTool.manage_subagents.default")
            }
        default:
            return nil
        }
    }

    private static func extractToolSummary(_ rawInput: String?) -> String? {
        guard let raw = rawInput,
              raw.contains("\"toolSummary\""),
              let data = raw.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = obj["toolSummary"] as? String,
              !isBlank(summary)
        else { return nil }
        return truncateSingleLine(summary, maxChars: 96)
    }

    private static func inferredToolKind(_ data: ToolEntryData) -> String {
        if data.toolKind != "other" && !data.toolKind.isEmpty {
            return data.toolKind
        }
        if data.content.contains(where: { if case .diff = $0 { return true }; return false }) {
            return "edit"
        }
        let lower = data.title.lowercased()
        if lower.hasPrefix("read ") || lower.contains("read_file") { return "read" }
        if lower.hasPrefix("edit ") || lower.hasPrefix("write ") || lower.contains("write_file") { return "edit" }
        if lower.hasPrefix("search") || lower.hasPrefix("grep") || lower.hasPrefix("find") { return "search" }
        if lower.hasPrefix("run ") {
            let rest = lower.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let isSnakeToolName = rest.contains("_") && !rest.contains(where: \.isWhitespace)
            if !isSnakeToolName { return "execute" }
        }
        if lower.contains("command") || lower.contains("shell") || lower.contains("bash") { return "execute" }
        return "other"
    }

    private static func formatStepLabel(
        data: ToolEntryData,
        effectiveKind: String,
        primaryPath: String?,
        isCreated: Bool,
        projectPath: String,
        l10n: PrismL10n
    ) -> (verb: String, target: String) {
        let done = data.status == "completed"
        let prefix = done ? "thread.verbDone." : "thread.verb."

        if let primaryPath, ["read", "edit", "delete", "move"].contains(effectiveKind) {
            let key = (effectiveKind == "edit" && isCreated) ? "\(prefix)create" : "\(prefix)\(effectiveKind)"
            return (l10n.tr(key), relativeDisplayPath(primaryPath, projectPath: projectPath))
        }
        if effectiveKind == "execute" {
            let cmd = data.description
                ?? data.rawInput?.split(separator: "\n", maxSplits: 1).first.map(String.init)
                ?? data.title
            return (l10n.tr("\(prefix)execute"), truncateSingleLine(cmd, maxChars: 72))
        }
        if effectiveKind == "search" {
            return (l10n.tr("\(prefix)search"), truncateSingleLine(data.title, maxChars: 68))
        }
        if effectiveKind == "fetch" {
            return (l10n.tr("\(prefix)fetch"), truncateSingleLine(data.title, maxChars: 68))
        }
        let otherTitle = data.label.flatMap { isBlank($0) ? nil : $0 }
            ?? data.description.flatMap { isBlank($0) ? nil : $0 }
            ?? extractToolSummary(data.rawInput)
            ?? localizedAgyToolLabel(data, l10n: l10n)
            ?? data.title
        return (truncateSingleLine(otherTitle, maxChars: 68), "")
    }

    private static func formatFilePart(prefix: String, paths: [String?], l10n: PrismL10n) -> String {
        var uniqueKnown: [String] = []
        var unknownCount = 0
        for p in paths {
            if let p, !p.isEmpty {
                if !uniqueKnown.contains(p) { uniqueKnown.append(p) }
            } else {
                unknownCount += 1
            }
        }
        let total = uniqueKnown.count + unknownCount
        if uniqueKnown.isEmpty {
            return l10n.tr("thread.summary.\(prefix)Count", max(1, total))
        }
        var distinctBasenames: [String] = []
        for path in uniqueKnown {
            let base = (path as NSString).lastPathComponent
            if !base.isEmpty, !distinctBasenames.contains(base) {
                distinctBasenames.append(base)
                if distinctBasenames.count >= 2 { break }
            }
        }
        let shown: [String]
        if distinctBasenames.count >= 2 {
            shown = distinctBasenames
        } else if uniqueKnown.count >= 2 {
            var disambiguated: [String] = []
            for path in uniqueKnown.prefix(2) {
                let ns = path as NSString
                let base = ns.lastPathComponent
                let parent = (ns.deletingLastPathComponent as NSString).lastPathComponent
                let label = (!parent.isEmpty && parent != "/" && parent != ".") ? "\(parent)/\(base)" : base
                if !disambiguated.contains(label) { disambiguated.append(label) }
            }
            shown = disambiguated.count >= 2 ? disambiguated : Array(distinctBasenames.prefix(1))
        } else {
            shown = Array(distinctBasenames.prefix(1))
        }
        let names = shown.joined(separator: ", ")
        let more = total - shown.count
        if more <= 0 {
            return l10n.tr("thread.summary.\(prefix)Named", names)
        }
        return l10n.tr("thread.summary.\(prefix)More", names, more)
    }

    public static func iconForToolKind(_ kind: String) -> String {
        switch kind {
        case "read": return "doc.text"
        case "edit": return "pencil.line"
        case "delete": return "trash"
        case "move": return "arrow.left.arrow.right"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "fetch": return "globe"
        case "think": return "sparkle"
        default: return "wrench"
        }
    }

    /// Extracts the latest heading or active line from the tail of a streaming thought so long
    /// multi-paragraph thoughts visibly advance instead of staying pinned to the opening sentence.
    public static func liveThoughtHeadline(_ markdown: String) -> String? {
        guard !isBlank(markdown) else { return nil }
        let tail = markdown.count > 2048 ? String(markdown.suffix(2048)) : markdown
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true)

        var checkedNonEmpty = 0
        for rawLine in lines.reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            checkedNonEmpty += 1
            if trimmed.hasPrefix("**"),
               let start = trimmed.index(trimmed.startIndex, offsetBy: 2, limitedBy: trimmed.endIndex),
               let end = trimmed.range(of: "**", range: start..<trimmed.endIndex) {
                let bold = String(trimmed[start..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !bold.isEmpty {
                    return truncateSingleLine(bold, maxChars: 96)
                }
            }
            if checkedNonEmpty >= 8 { break }
        }

        var fallback: String? = nil
        for rawLine in lines.reversed() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("```") || line.hasPrefix("~~~")
                || line == "---" || line == "***" || line == "___" {
                continue
            }
            while line.hasPrefix(">") || line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    line = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                } else {
                    line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
            }
            let cleaned = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            if fallback == nil { fallback = cleaned }
            let hasWideScalar = cleaned.unicodeScalars.contains { $0.value > 0x2E7F }
            let minChars = hasWideScalar ? 6 : 12
            if cleaned.count >= minChars {
                return truncateSingleLine(cleaned, maxChars: 96)
            }
        }
        return fallback.map { truncateSingleLine($0, maxChars: 96) }
    }

    public static func thoughtTitle(_ markdown: String) -> String? {
        // A title only comes from the head of the thought, so a long thought is never copied whole.
        guard let start = markdown.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let trimmed = String(markdown[start...].prefix(1024))
        if trimmed.hasPrefix("**"), let endRange = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 2)..<trimmed.endIndex) {
            let bold = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !bold.isEmpty { return truncateSingleLine(bold, maxChars: 64) }
        }
        let firstLine = trimmed.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? trimmed
        let cleaned = firstLine
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : truncateSingleLine(cleaned, maxChars: 64)
    }

    public static func relativeDisplayPath(_ rawPath: String, projectPath: String) -> String {
        guard !projectPath.isEmpty else { return rawPath }
        let normalizedRoot = projectPath.hasSuffix("/") ? projectPath : "\(projectPath)/"
        if rawPath.hasPrefix(normalizedRoot) {
            return String(rawPath.dropFirst(normalizedRoot.count))
        }
        return rawPath
    }

    private static func splitDirAndFile(_ path: String) -> (dir: String, file: String) {
        if let slash = path.lastIndex(of: "/") {
            let next = path.index(after: slash)
            return (String(path[..<next]), String(path[next...]))
        }
        return ("", path)
    }

    private static func extractPathFromTitle(_ title: String) -> String? {
        let parts = title.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let candidate = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.contains("/") || candidate.contains(".") {
            return candidate
        }
        return nil
    }

    public static func truncateSingleLine(_ text: String, maxChars: Int) -> String {
        let single = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard single.count > maxChars else { return single }
        return String(single.prefix(maxChars - 1)) + "…"
    }

    public static func formatDuration(_ ms: Double) -> String {
        let sec = ms / 1000.0
        if sec < 60 {
            return String(format: "%.1fs", sec)
        }
        let mins = Int(sec) / 60
        let rem = Int(sec) % 60
        return "\(mins)m \(rem)s"
    }
}

// MARK: - Structured Markdown Block Parser (with Sarto's FOLD_OVER=20 / FOLDED_LINES=7 code folding)

public enum GitHubAlertKind: String, Sendable, Equatable {
    case note
    case tip
    case important
    case warning
    case caution

    public var title: String {
        switch self {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        }
    }

    public var systemImage: String {
        switch self {
        case .note: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .important: return "exclamationmark.bubble.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "xmark.octagon.fill"
        }
    }
}

public enum MarkdownBlock: Identifiable, Sendable, Equatable {
    case heading(id: Int, level: Int, text: String)
    case paragraph(id: Int, text: String)
    case bulletList(id: Int, items: [String])
    case orderedList(id: Int, items: [(number: Int, text: String)])
    case blockquote(id: Int, text: String)
    case alert(id: Int, kind: GitHubAlertKind, text: String)
    case table(id: Int, headers: [String], rows: [[String]])
    case codeBlock(id: Int, language: String?, filename: String?, code: String, lineCount: Int)
    case mermaid(id: Int, source: String)
    case svg(id: Int, source: String)
    case mathBlock(id: Int, latex: String)
    case image(id: Int, alt: String, url: String)
    case divider(id: Int)

    public var id: Int {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .bulletList(let id, _),
             .orderedList(let id, _),
             .blockquote(let id, _),
             .alert(let id, _, _),
             .table(let id, _, _),
             .codeBlock(let id, _, _, _, _),
             .mermaid(let id, _),
             .svg(let id, _),
             .mathBlock(let id, _),
             .image(let id, _, _),
             .divider(let id):
            return id
        }
    }

    public static func == (lhs: MarkdownBlock, rhs: MarkdownBlock) -> Bool {
        switch (lhs, rhs) {
        case (.heading(let a, let l1, let t1), .heading(let b, let l2, let t2)):
            return a == b && l1 == l2 && t1 == t2
        case (.paragraph(let a, let t1), .paragraph(let b, let t2)):
            return a == b && t1 == t2
        case (.bulletList(let a, let i1), .bulletList(let b, let i2)):
            return a == b && i1 == i2
        case (.orderedList(let a, let i1), .orderedList(let b, let i2)):
            return a == b && i1.count == i2.count && zip(i1, i2).allSatisfy { $0.number == $1.number && $0.text == $1.text }
        case (.blockquote(let a, let t1), .blockquote(let b, let t2)):
            return a == b && t1 == t2
        case (.alert(let a, let k1, let t1), .alert(let b, let k2, let t2)):
            return a == b && k1 == k2 && t1 == t2
        case (.table(let a, let h1, let r1), .table(let b, let h2, let r2)):
            return a == b && h1 == h2 && r1 == r2
        case (.codeBlock(let a, let l1, let f1, let c1, let n1), .codeBlock(let b, let l2, let f2, let c2, let n2)):
            return a == b && l1 == l2 && f1 == f2 && c1 == c2 && n1 == n2
        case (.mermaid(let a, let s1), .mermaid(let b, let s2)):
            return a == b && s1 == s2
        case (.svg(let a, let s1), .svg(let b, let s2)):
            return a == b && s1 == s2
        case (.mathBlock(let a, let m1), .mathBlock(let b, let m2)):
            return a == b && m1 == m2
        case (.image(let a, let al1, let u1), .image(let b, let al2, let u2)):
            return a == b && al1 == al2 && u1 == u2
        case (.divider(let a), .divider(let b)):
            return a == b
        default:
            return false
        }
    }
}

public enum MarkdownBlockParser {
    /// Matches src/renderer/src/features/session/markdown/code-meta.ts
    public static let foldOverLines = 20
    public static let foldedPreviewLines = 7

    /// Blocks that end before a top-level blank line. Text appended later cannot change them,
    /// because the parser never looks back past such a line.
    private struct StablePrefix {
        let utf8Length: Int
        let blockCount: Int
        let nextID: Int
    }

    private struct ParseOutput {
        let blocks: [MarkdownBlock]
        let stable: StablePrefix?
    }

    /// One parse per entry, replaced whenever the entry's text changes. A streamed reply only
    /// grows, so the blocks before its last stable boundary are kept and only the text after it
    /// is parsed again; re-parsing the whole reply on every token is quadratic.
    private final class BlockParseCache: @unchecked Sendable {
        struct Entry {
            let markdown: String
            let output: ParseOutput
        }

        private let lock = NSLock()
        private let store = ThreadLRUStore<String, Entry>(capacity: 256)

        func entry(for entryID: String) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            return store.value(for: entryID)
        }

        func set(_ entry: Entry, for entryID: String) {
            lock.lock()
            defer { lock.unlock() }
            store.set(entry, for: entryID)
        }
    }

    private static let blockCache = BlockParseCache()

    public static func parseCached(entryID: String, markdown: String) -> [MarkdownBlock] {
        let previous = blockCache.entry(for: entryID)
        if let previous, previous.markdown == markdown {
            return previous.output.blocks
        }
        let output: ParseOutput
        if let previous,
           let stable = previous.output.stable,
           markdown.utf8.count > previous.markdown.utf8.count,
           utf8Prefix(of: markdown, matches: previous.markdown, length: stable.utf8Length),
           !markdown.utf8.dropFirst(stable.utf8Length).contains(UInt8(ascii: "\r"))
        {
            output = parseTail(markdown, after: stable, previousBlocks: previous.output.blocks)
        } else {
            output = parseFull(markdown)
        }
        blockCache.set(.init(markdown: markdown, output: output), for: entryID)
        return output.blocks
    }

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        parseCached(entryID: "", markdown: markdown)
    }

    private static func utf8Prefix(of text: String, matches other: String, length: Int) -> Bool {
        guard text.utf8.count >= length, other.utf8.count >= length else { return false }
        guard length > 0 else { return true }
        if let fast = text.utf8.withContiguousStorageIfAvailable({ lhs in
            other.utf8.withContiguousStorageIfAvailable { rhs in
                memcmp(lhs.baseAddress!, rhs.baseAddress!, length) == 0
            }
        }), let result = fast {
            return result
        }
        return text.utf8.prefix(length).elementsEqual(other.utf8.prefix(length))
    }

    private static func parseFull(_ markdown: String) -> ParseOutput {
        let hasCarriageReturn = markdown.utf8.contains(UInt8(ascii: "\r"))
        let normalized = hasCarriageReturn ? markdown.replacingOccurrences(of: "\r\n", with: "\n") : markdown
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = parseLines(lines, firstID: 0)
        // Normalizing shifts byte offsets, so text with carriage returns is always parsed whole.
        guard !hasCarriageReturn, let boundary = parsed.boundary else {
            return ParseOutput(blocks: parsed.blocks, stable: nil)
        }
        return ParseOutput(
            blocks: parsed.blocks,
            stable: StablePrefix(utf8Length: boundary.utf8Offset, blockCount: boundary.blockCount, nextID: boundary.nextID)
        )
    }

    private static func parseTail(_ markdown: String, after stable: StablePrefix, previousBlocks: [MarkdownBlock]) -> ParseOutput {
        let start = markdown.utf8.index(markdown.utf8.startIndex, offsetBy: stable.utf8Length)
        let lines = markdown[start...].split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let parsed = parseLines(lines, firstID: stable.nextID)
        var blocks = Array(previousBlocks.prefix(stable.blockCount))
        blocks.append(contentsOf: parsed.blocks)
        guard let boundary = parsed.boundary else {
            return ParseOutput(blocks: blocks, stable: stable)
        }
        return ParseOutput(
            blocks: blocks,
            stable: StablePrefix(
                utf8Length: stable.utf8Length + boundary.utf8Offset,
                blockCount: stable.blockCount + boundary.blockCount,
                nextID: boundary.nextID
            )
        )
    }

    private static func parseLines(
        _ lines: [String],
        firstID: Int
    ) -> (blocks: [MarkdownBlock], boundary: (utf8Offset: Int, blockCount: Int, nextID: Int)?) {
        var blocks: [MarkdownBlock] = []
        var nextID = firstID
        var i = 0
        var boundaryLine: (index: Int, blockCount: Int, nextID: Int)? = nil

        func allocID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // A blank line reached at top level ends every open block. It is only stable once
                // a newline follows it, since appended text would otherwise extend it.
                if i + 1 < lines.count {
                    boundaryLine = (i + 1, blocks.count, nextID)
                }
                i += 1
                continue
            }

            // 1. Fenced code block (``` or ~~~)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fenceChar = trimmed.first!
                let fenceCount = trimmed.prefix(while: { $0 == fenceChar }).count
                let fenceStr = String(repeating: fenceChar, count: fenceCount)
                let metaRaw = String(trimmed.dropFirst(fenceCount)).trimmingCharacters(in: .whitespaces)
                let (lang, file) = parseFenceMeta(metaRaw)

                var codeLines: [String] = []
                var isClosed = false
                i += 1
                while i < lines.count {
                    let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fenceStr) && candidate.dropFirst(fenceCount).trimmingCharacters(in: .whitespaces).isEmpty {
                        isClosed = true
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                let lowerLang = lang?.lowercased()
                // Diagrams render in a web view, which would reload on every streamed token, so a
                // fence still being written shows as source until it closes.
                if isClosed && lowerLang == "mermaid" {
                    blocks.append(.mermaid(id: allocID(), source: code))
                } else if isClosed && lowerLang == "svg" {
                    blocks.append(.svg(id: allocID(), source: code))
                } else if isClosed && (lowerLang == "math" || lowerLang == "latex" || lowerLang == "tex") {
                    blocks.append(.mathBlock(id: allocID(), latex: code))
                } else {
                    blocks.append(.codeBlock(id: allocID(), language: lang, filename: file, code: code, lineCount: codeLines.count))
                }
                continue
            }

            // 1b. Display LaTeX math block ($$ ... $$)
            if trimmed.hasPrefix("$$") {
                if trimmed.count > 4 && trimmed.hasSuffix("$$") {
                    let body = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !body.isEmpty {
                        blocks.append(.mathBlock(id: allocID(), latex: body))
                        i += 1
                        continue
                    }
                } else {
                    var mathLines: [String] = []
                    var isClosed = false
                    let firstTail = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !firstTail.isEmpty { mathLines.append(firstTail) }
                    i += 1
                    while i < lines.count {
                        let candidate = lines[i].trimmingCharacters(in: .whitespaces)
                        if candidate.hasSuffix("$$") {
                            let head = String(candidate.dropLast(2)).trimmingCharacters(in: .whitespaces)
                            if !head.isEmpty { mathLines.append(head) }
                            isClosed = true
                            i += 1
                            break
                        }
                        mathLines.append(lines[i])
                        i += 1
                    }
                    let latex = mathLines.joined(separator: "\n")
                    if isClosed {
                        blocks.append(.mathBlock(id: allocID(), latex: latex))
                    } else {
                        blocks.append(.codeBlock(id: allocID(), language: "latex", filename: nil, code: latex, lineCount: mathLines.count))
                    }
                    continue
                }
            }

            // 1c. Standalone markdown image line (![alt](url))
            if let img = parseStandaloneImage(trimmed) {
                blocks.append(.image(id: allocID(), alt: img.alt, url: img.url))
                i += 1
                continue
            }

            // 2. Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider(id: allocID()))
                i += 1
                continue
            }

            // 3. Heading (# ... ####)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" }).count
                if hashes <= 4 {
                    let afterHashes = trimmed.dropFirst(hashes)
                    if afterHashes.first == " " {
                        let text = String(afterHashes).trimmingCharacters(in: .whitespaces)
                        blocks.append(.heading(id: allocID(), level: hashes, text: text))
                        i += 1
                        continue
                    }
                }
            }

            // 4. Blockquote / GitHub Alert (> [!NOTE] / > ...)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let qTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qTrim.hasPrefix(">") else { break }
                    var content = String(qTrim.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    i += 1
                }
                if let first = quoteLines.first, let alert = parseGitHubAlertHeader(first) {
                    var bodyLines = Array(quoteLines.dropFirst())
                    if !alert.remainder.isEmpty {
                        bodyLines.insert(alert.remainder, at: 0)
                    }
                    blocks.append(.alert(id: allocID(), kind: alert.kind, text: bodyLines.joined(separator: "\n")))
                } else {
                    blocks.append(.blockquote(id: allocID(), text: quoteLines.joined(separator: "\n")))
                }
                continue
            }

            // 5. Bullet list (- / * / •)
            if isBulletLine(trimmed) {
                var items: [String] = []
                while i < lines.count {
                    let lTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    if let body = extractBulletBody(lTrim) {
                        items.append(body)
                        i += 1
                    } else if !lTrim.isEmpty && (lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t")) && !items.isEmpty {
                        items[items.count - 1] += "\n" + lTrim
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(id: allocID(), items: items))
                continue
            }

            // 6. Ordered list (1. ...)
            if parseOrderedLine(trimmed) != nil {
                var items: [(number: Int, text: String)] = []
                while i < lines.count {
                    let lTrim = lines[i].trimmingCharacters(in: .whitespaces)
                    if let parsed = parseOrderedLine(lTrim) {
                        items.append(parsed)
                        i += 1
                    } else if !lTrim.isEmpty && !isBulletLine(lTrim) && (lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t")) && !items.isEmpty {
                        items[items.count - 1].text += "\n" + lTrim
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(id: allocID(), items: items))
                continue
            }

            // 6b. GFM Pipe Table (| h1 | h2 | \n | --- | --- | \n | c1 | c2 |)
            if trimmed.contains("|"),
               i + 1 < lines.count,
               isTableSeparatorRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = splitTableCells(trimmed)
                if !headers.isEmpty {
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count {
                        let rTrim = lines[i].trimmingCharacters(in: .whitespaces)
                        guard !rTrim.isEmpty, rTrim.contains("|") else { break }
                        let cells = splitTableCells(rTrim)
                        if cells.isEmpty { break }
                        var normalizedRow = cells
                        while normalizedRow.count < headers.count { normalizedRow.append("") }
                        if normalizedRow.count > headers.count {
                            normalizedRow = Array(normalizedRow.prefix(headers.count))
                        }
                        rows.append(normalizedRow)
                        i += 1
                    }
                    blocks.append(.table(id: allocID(), headers: headers, rows: rows))
                    continue
                }
            }

            // 7. Paragraph (consume until blank line or next structural block)
            var paraLines: [String] = [raw]
            i += 1
            while i < lines.count {
                let nextRaw = lines[i]
                let nextTrim = nextRaw.trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty
                    || nextTrim.hasPrefix("```")
                    || nextTrim.hasPrefix("~~~")
                    || nextTrim.hasPrefix("$$")
                    || parseStandaloneImage(nextTrim) != nil
                    || nextTrim.hasPrefix("#")
                    || nextTrim.hasPrefix(">")
                    || nextTrim == "---"
                    || isBulletLine(nextTrim)
                    || parseOrderedLine(nextTrim) != nil
                    || (nextTrim.contains("|") && i + 1 < lines.count && isTableSeparatorRow(lines[i + 1].trimmingCharacters(in: .whitespaces))) {
                    break
                }
                paraLines.append(nextRaw)
                i += 1
            }
            blocks.append(.paragraph(id: allocID(), text: paraLines.joined(separator: "\n")))
        }

        let boundary = boundaryLine.map { line in
            (
                utf8Offset: lines[..<line.index].reduce(0) { $0 + $1.utf8.count + 1 },
                blockCount: line.blockCount,
                nextID: line.nextID
            )
        }
        return (blocks, boundary)
    }

    private static func parseGitHubAlertHeader(_ line: String) -> (kind: GitHubAlertKind, remainder: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), let close = trimmed.firstIndex(of: "]") else { return nil }
        let tag = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<close]).lowercased()
        guard let kind = GitHubAlertKind(rawValue: tag) else { return nil }
        let rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return (kind, rest)
    }

    private static func parseStandaloneImage(_ trimmed: String) -> (alt: String, url: String)? {
        guard trimmed.hasPrefix("!["),
              let mid = trimmed.range(of: "]("),
              trimmed.hasSuffix(")")
        else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<mid.lowerBound])
        var url = String(trimmed[mid.upperBound..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        // Strip optional title after space inside (...)
        if let quoteStart = url.firstIndex(of: "\"") {
            url = String(url[..<quoteStart]).trimmingCharacters(in: .whitespaces)
        }
        guard !url.isEmpty, !url.contains("](") else { return nil }
        return (alt, url)
    }

    private static func isTableSeparatorRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("|") || trimmed.contains("-") else { return false }
        let cells = splitTableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let cleaned = cell.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { return false }
            let core = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return core.count >= 3 && core.allSatisfy({ $0 == "-" })
        }
    }

    private static func splitTableCells(_ trimmed: String) -> [String] {
        var s = trimmed
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    public static func previewCode(_ code: String, lineCount: Int, expanded: Bool) -> (shown: String, hiddenCount: Int) {
        if expanded || lineCount <= foldOverLines {
            return (code, 0)
        }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = lines.prefix(foldedPreviewLines).joined(separator: "\n")
        return (shown, max(0, lines.count - foldedPreviewLines))
    }

    private static func parseFenceMeta(_ meta: String) -> (language: String?, filename: String?) {
        guard !meta.isEmpty else { return (nil, nil) }
        let parts = meta.split(separator: " ", maxSplits: 1).map(String.init)
        let first = parts[0]
        var lang: String? = first
        var filename: String? = nil

        if let colon = first.firstIndex(of: ":"), colon > first.startIndex {
            lang = String(first[..<colon])
            let after = String(first[first.index(after: colon)...])
            if !after.isEmpty { filename = after }
        }
        if parts.count > 1, filename == nil {
            let rest = parts[1].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty && !rest.hasPrefix("{") {
                filename = rest
                    .replacingOccurrences(of: "title=", with: "")
                    .replacingOccurrences(of: "file=", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return (lang?.isEmpty == true ? nil : lang, filename)
    }

    private static func isBulletLine(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
    }

    private static func extractBulletBody(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func parseOrderedLine(_ trimmed: String) -> (number: Int, text: String)? {
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, let num = Int(digits) else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.hasPrefix(". ") else { return nil }
        return (num, String(afterDigits.dropFirst(2)))
    }
}
