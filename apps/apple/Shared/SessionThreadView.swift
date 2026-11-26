import SartoProtocol
import PrismDesign
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Obsidian Prism conversation stream:
/// - Calm, folded 1-line Work Run rows ("Read 3 files · Edited MacWorkbenchView.swift +59 −16 · Ran 2 commands")
///   that unfold on demand into a vertical step timeline rail (where each step ALSO starts collapsed!)
/// - Compact unified-diff hunk previews (computed via UnifiedDiffEngine, never dumping raw 800-line files)
/// - Per-turn Changes Card summarizing modified files with +ins −del counts & click-to-inspect hunks
/// - Structured Markdown rendering for agent replies with auto-folded code blocks (>20 lines -> 7 lines)
/// - Prominent standalone Permission / Question approval cards (never buried inside folded work)
/// - Live ticking Turn Status row (clock + current phase) and compact pinned Execution Plan pill
public struct SessionThreadView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.prismTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let replica: ThreadReplica
    public let onRespondPermission: (String, String?, String?, [QuestionAnswer]?) -> Void
    public let onLoadBlob: ((String) async -> Data?)?
    public let isLoadingOlder: Bool
    public let onLoadOlder: (() -> Void)?
    public let onRetryTurn: (() -> Void)?
    public let onSendTextReply: ((String) -> Void)?
    public let canForkSession: Bool
    public let canForkAtMessage: Bool
    public let onForkTurn: ((String) -> Void)?
    public let onSelectSession: ((String) -> Void)?
    public let resolveSessionSummary: ((String) -> SessionSummary?)?
    public let onOpenFileDiff: ((String) -> Void)?
    public let onOpenProjectFile: ((String) -> Void)?
    public let onOpenURLInBrowser: ((URL) -> Void)?
    public let onFindInSession: ((String?) -> Void)?
    public let scrollTargetEntryID: String?
    public let scrollTargetToken: Int
    public let highlightedEntryID: String?
    public let findQuery: String
    public let forceScrollToBottomToken: Int
    public let outlineEntries: [OutlineEntryInfo]
    public let onLoadThroughPos: ((Int) async -> Bool)?
    public let onQuoteReply: ((String) -> Void)?
    public let onAddPassageComment: ((String?, String, String) -> Void)?
    public let onRunCommandInTerminal: ((String) -> Void)?
    public let cardActions: ThreadEntryCardActions
    public let isRemoteConnection: Bool
    /// Whether the session's sent messages can be edited from; each message is then checked on its own.
    public let canEditFromMessage: Bool
    /// Whether editing from a sent message also reverts modified files (e.g. OpenCode).
    public let canRewindFiles: Bool
    public let onEditFromMessage: ((String) -> Void)?
    /// Hides the pinned top execution plan pill when the right-hand running rail already displays it.
    public let showsPlanHeader: Bool
    /// Hydrates a digested tool entry on demand via `sessions.entry`.
    public let onLoadToolEntry: ((String) async -> Void)?

    @State private var expandedRuns: Set<String> = []
    @State private var expandedSteps: Set<String> = []
    @State private var expandedCodeBlocks: Set<String> = []
    @State private var expandedChangeRows: Set<String> = []
    @State private var expandedChangeCards: Set<String> = []
    @State private var expandedFullDiffs: Set<String> = []
    @State private var expandedResolvedPerms: Set<String> = []
    @State private var loadingEntryIDs: Set<String> = []
    @State private var dismissedTextQuestionIDs: Set<String> = []
    @State private var permissionNotes: [String: String] = [:]
    @State private var isPlanExpanded: Bool = false
    @State private var isFollowingBottom: Bool = true
    @State private var commentingFooterID: String? = nil
    @State private var commentingPassage: String = ""
    @State private var commentingNote: String = ""
    @State private var contextCommentDraft: ContextCommentDraft? = nil
    @State private var contextCommentNote: String = ""
    @FocusState private var isContextCommentFocused: Bool

    private struct ContextCommentDraft: Identifiable, Equatable {
        let id = UUID()
        let entryID: String
        let passage: String
    }
    /// Following the bottom, but held in place because the user is selecting text in the thread.
    @State private var selectionPausedFollow: Bool = false
    @State private var isScrolledAwayFromBottom: Bool = false
    @State private var lastAutoFollowSeq: Int = 0
    @State private var isScrollable: Bool = false
    @State private var hasUnseenTurnEnd: Bool = false
    @State private var wasTurnRunning: Bool = false
    @State private var isJumpHovered: Bool = false
    @State private var olderPrependAnchor: OlderPrependAnchor? = nil
    @State private var olderAnchorGeneration: Int = 0
    @State private var olderLoadObservedStart: Bool = false
    @State private var isSettlingInitialScroll: Bool = true
    /// The session whose opening scroll has settled. Until it matches the shown session, scroll
    /// callbacks belong to the switch: the follow state and offsets they would compare against are
    /// still the previous session's.
    @State private var settledSessionID: String? = nil
    /// Short window after a live patch where multi-frame text wrapping continues to snap flush
    /// to the bottom when `contentHeight` grows.
    @State private var followGrowthUntil: TimeInterval = 0
    /// Short window after the user toggles an inline disclosure so expanding a card never yanks
    /// the viewport to the bottom.
    @State private var suppressAutoFollowUntil: TimeInterval = 0
    /// True while an animated jump-to-bottom is in flight so streaming patches do not issue a
    /// competing un-animated `scrollTo` that freezes macOS `NSScrollView` mid-flight.
    @State private var isJumpAnimating: Bool = false
    @State private var activeJumpTask: Task<Void, Never>? = nil
    @State private var copiedIDs: Set<String> = []
    /// The message whose Edit from here confirmation is open, which keeps its actions shown.
    @State private var editConfirmEntryID: String?
    @State private var loadedBlobs: [String: Data] = [:]
    @State private var answeredPermissionRequestIDs: Set<String> = []
    @State private var previewItem: PrismImagePreviewItem? = nil
    @State private var stageSize: CGSize = .zero
    @State private var tracker = ThreadScrollTracker()
    @AppStorage("prism.threadWideWidth") private var threadWideWidth: Bool = false

    private struct ThreadScrollMetrics: Equatable {
        let distanceFromBottom: Int
        let offset: Int
        let isScrollable: Bool
        let contentHeight: Int
    }

    /// The first row when an older page was requested, plus its first thread entry: a prepended
    /// page can fold that entry into a work run with a new row id.
    private struct OlderPrependAnchor: Equatable {
        let itemID: String
        let entryID: String?
    }

    private struct OlderPageState: Equatable {
        let older: Int?
        let isLoading: Bool
    }

    private struct LinkedSessionDigest: Equatable {
        let id: String
        let status: SessionStatus?
        let title: String?
        let updatedAt: Double?
    }

    /// Equatable snapshot of view state that can alter how settled timeline rows render, allowing
    /// SwiftUI to skip diffing unchanged historical chunks during live token streaming.
    private struct SettledChunkRenderState: Equatable {
        let palette: PrismPalette
        let accentMode: PrismAccentMode
        let radiusBase: CGFloat
        let language: PrismLanguage
        let typography: PrismTypographyPrefs
        let motionTier: PrismMotionTier
        let reduceMotion: Bool
        let threadWideWidth: Bool
        let highlightedEntryID: String?
        let findQuery: String
        let canForkSession: Bool
        let canForkAtMessage: Bool
        let canEditFromMessage: Bool
        let isRemoteConnection: Bool
        let projectPath: String
        let sessionStatus: SessionStatus
        let editableIDs: Set<String>
        let expandedRuns: Set<String>
        let expandedSteps: Set<String>
        let expandedCodeBlocks: Set<String>
        let expandedChangeRows: Set<String>
        let expandedChangeCards: Set<String>
        let expandedFullDiffs: Set<String>
        let expandedResolvedPerms: Set<String>
        let dismissedTextQuestionIDs: Set<String>
        let permissionNotes: [String: String]
        let copiedIDs: Set<String>
        let editConfirmEntryID: String?
        let commentingFooterID: String?
        let commentingPassage: String
        let commentingNote: String
        let loadedBlobKeys: Set<String>
        let answeredPermissionRequestIDs: Set<String>
    }

    private struct SettledChunk: Identifiable {
        let id: String
        let items: ArraySlice<ThreadTimelineItem>
        let linkedSessions: [LinkedSessionDigest]
    }

    private static let settledChunkSize = 16
    private static let liveTailCount = 2

    private func settledChunks(for items: [ThreadTimelineItem]) -> (chunks: [SettledChunk], tailStart: Int) {
        let settledEnd = max(0, items.count - Self.liveTailCount)
        guard settledEnd > 0 else { return ([], 0) }
        var chunks: [SettledChunk] = []
        chunks.reserveCapacity((settledEnd + Self.settledChunkSize - 1) / Self.settledChunkSize)
        var start = 0
        while start < settledEnd {
            let end = min(start + Self.settledChunkSize, settledEnd)
            let slice = items[start..<end]
            var linked: [LinkedSessionDigest] = []
            if let resolveSessionSummary {
                for item in slice {
                    let sid: String?
                    switch item {
                    case .subagent(_, let id), .sessionStarted(_, let id):
                        sid = id
                    case .sessionMessage(_, let senderId, _, _):
                        sid = senderId
                    case .sessionReport(_, let from, _, _, _):
                        sid = from.sessionId
                    default:
                        sid = nil
                    }
                    if let sid {
                        let summary = resolveSessionSummary(sid)
                        linked.append(LinkedSessionDigest(
                            id: sid,
                            status: summary?.status,
                            title: summary?.title,
                            updatedAt: summary?.updatedAt
                        ))
                    }
                }
            }
            chunks.append(SettledChunk(id: slice[start].id, items: slice, linkedSessions: linked))
            start = end
        }
        return (chunks, settledEnd)
    }

    private func currentSettledRenderState() -> SettledChunkRenderState {
        SettledChunkRenderState(
            palette: tokens.palette,
            accentMode: tokens.accentMode,
            radiusBase: tokens.radiusBase,
            language: l10n.language,
            typography: typography,
            motionTier: motionTier,
            reduceMotion: reduceMotion,
            threadWideWidth: threadWideWidth,
            highlightedEntryID: highlightedEntryID,
            findQuery: findQuery,
            canForkSession: canForkSession,
            canForkAtMessage: canForkAtMessage,
            canEditFromMessage: canEditFromMessage,
            isRemoteConnection: isRemoteConnection,
            projectPath: replica.session.projectPath,
            sessionStatus: replica.session.status,
            editableIDs: canEditFromMessage ? EditableMessageMemo.shared.ids(for: replica) : [],
            expandedRuns: expandedRuns,
            expandedSteps: expandedSteps,
            expandedCodeBlocks: expandedCodeBlocks,
            expandedChangeRows: expandedChangeRows,
            expandedChangeCards: expandedChangeCards,
            expandedFullDiffs: expandedFullDiffs,
            expandedResolvedPerms: expandedResolvedPerms,
            dismissedTextQuestionIDs: dismissedTextQuestionIDs,
            permissionNotes: permissionNotes,
            copiedIDs: copiedIDs,
            editConfirmEntryID: editConfirmEntryID,
            commentingFooterID: commentingFooterID,
            commentingPassage: commentingPassage,
            commentingNote: commentingNote,
            loadedBlobKeys: Set(loadedBlobs.keys),
            answeredPermissionRequestIDs: answeredPermissionRequestIDs
        )
    }

    private struct ThreadSettledChunkView<RowContent: View>: View, Equatable {
        let items: ArraySlice<ThreadTimelineItem>
        let linkedSessions: [LinkedSessionDigest]
        let renderState: SettledChunkRenderState
        let rowBuilder: (ThreadTimelineItem) -> RowContent

        nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.renderState == rhs.renderState
                && lhs.linkedSessions == rhs.linkedSessions
                && lhs.items == rhs.items
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(items) { item in
                    rowBuilder(item)
                }
            }
        }
    }

    private func suppressAutoFollowBriefly() {
        suppressAutoFollowUntil = ProcessInfo.processInfo.systemUptime + 0.45
        followGrowthUntil = 0
    }

    private func jumpToBottom(proxy: ScrollViewProxy, animated: Bool) {
        activeJumpTask?.cancel()
        activeJumpTask = nil
        ThreadScrollInput.clearRecent()
        isFollowingBottom = true
        selectionPausedFollow = false
        hasUnseenTurnEnd = false
        lastAutoFollowSeq = replica.seq
        suppressAutoFollowUntil = 0
        followGrowthUntil = 0
        SessionReadingPositionStore.shared.save(
            sessionId: replica.session.id,
            anchorItemID: nil,
            followingBottom: true
        )
        if animated,
           let anim = PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion) {
            let sessionID = replica.session.id
            isJumpAnimating = true
            withAnimation(anim) {
                proxy.scrollTo("thread-bottom", anchor: .bottom)
            }
            activeJumpTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(360))
                guard !Task.isCancelled, replica.session.id == sessionID else { return }
                isJumpAnimating = false
                activeJumpTask = nil
                guard isFollowingBottom, !tracker.isUserScrolling else { return }
                // Snap cleanly to absorb any streaming growth or async card sizing that occurred
                // while the spring animation was in flight.
                proxy.scrollTo("thread-bottom", anchor: .bottom)
                lastAutoFollowSeq = replica.seq
                followGrowthUntil = ProcessInfo.processInfo.systemUptime + 0.25
            }
        } else {
            isJumpAnimating = false
            proxy.scrollTo("thread-bottom", anchor: .bottom)
            followGrowthUntil = ProcessInfo.processInfo.systemUptime + 0.25
        }
    }

    private func timelineRowView(_ item: ThreadTimelineItem) -> some View {
        let isHighlighted = highlightedEntryID != nil && item.rawEntryID == highlightedEntryID
        return timelineItemView(item)
            .padding(isHighlighted ? 6 : 0)
            .background(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .fill(isHighlighted ? tokens.primarySoft : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(isHighlighted ? tokens.primaryBorder : Color.clear, lineWidth: 1)
            )
            .modifier(UserTurnPositionReporter(
                isUserTurn: item.isUserTurn,
                itemID: item.id,
                tracker: tracker
            ))
            .id(item.id)
    }

    @ViewBuilder
    private func stillRunningRow(_ still: StillRunningInfo) -> some View {
        let primaryText: String = {
            if still.commands > 0 && still.subagents > 0 {
                return l10n.tr("session.stillRunning.both", still.commands, still.subagents)
            } else if still.commands > 0 {
                return still.commands == 1
                    ? l10n.tr("session.stillRunning.commands", 1)
                    : l10n.tr("session.stillRunning.commandsPlural", still.commands)
            } else {
                return still.subagents == 1
                    ? l10n.tr("session.stillRunning.subagents", 1)
                    : l10n.tr("session.stillRunning.subagentsPlural", still.subagents)
            }
        }()

        HStack(alignment: .center, spacing: 8) {
            PrismStepPulseDot(size: 12)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(primaryText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tokens.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)

                if still.reportsBack {
                    Text(l10n.tr("session.stillRunning.reportsBack"))
                        .font(.system(size: 11))
                        .foregroundStyle(tokens.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .fill(tokens.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    public init(
        replica: ThreadReplica,
        onRespondPermission: @escaping (String, String?, String?, [QuestionAnswer]?) -> Void,
        onLoadBlob: ((String) async -> Data?)? = nil,
        isLoadingOlder: Bool = false,
        onLoadOlder: (() -> Void)? = nil,
        onRetryTurn: (() -> Void)? = nil,
        onSendTextReply: ((String) -> Void)? = nil,
        canForkSession: Bool = false,
        canForkAtMessage: Bool = false,
        onForkTurn: ((String) -> Void)? = nil,
        onSelectSession: ((String) -> Void)? = nil,
        resolveSessionSummary: ((String) -> SessionSummary?)? = nil,
        onOpenFileDiff: ((String) -> Void)? = nil,
        onOpenProjectFile: ((String) -> Void)? = nil,
        onOpenURLInBrowser: ((URL) -> Void)? = nil,
        onFindInSession: ((String?) -> Void)? = nil,
        scrollTargetEntryID: String? = nil,
        scrollTargetToken: Int = 0,
        highlightedEntryID: String? = nil,
        findQuery: String = "",
        forceScrollToBottomToken: Int = 0,
        outlineEntries: [OutlineEntryInfo] = [],
        onLoadThroughPos: ((Int) async -> Bool)? = nil,
        onQuoteReply: ((String) -> Void)? = nil,
        onAddPassageComment: ((String?, String, String) -> Void)? = nil,
        onRunCommandInTerminal: ((String) -> Void)? = nil,
        cardActions: ThreadEntryCardActions = .init(),
        isRemoteConnection: Bool = false,
        canEditFromMessage: Bool = false,
        canRewindFiles: Bool = false,
        onEditFromMessage: ((String) -> Void)? = nil,
        showsPlanHeader: Bool = true,
        onLoadToolEntry: ((String) async -> Void)? = nil
    ) {
        self.replica = replica
        self.onRespondPermission = onRespondPermission
        self.onLoadBlob = onLoadBlob
        self.isLoadingOlder = isLoadingOlder
        self.onLoadOlder = onLoadOlder
        self.onRetryTurn = onRetryTurn
        self.onSendTextReply = onSendTextReply
        self.canForkSession = canForkSession
        self.canForkAtMessage = canForkAtMessage
        self.onForkTurn = onForkTurn
        self.onSelectSession = onSelectSession
        self.resolveSessionSummary = resolveSessionSummary
        self.onOpenFileDiff = onOpenFileDiff
        self.onOpenProjectFile = onOpenProjectFile
        self.onOpenURLInBrowser = onOpenURLInBrowser
        self.onFindInSession = onFindInSession
        self.scrollTargetEntryID = scrollTargetEntryID
        self.scrollTargetToken = scrollTargetToken
        self.highlightedEntryID = highlightedEntryID
        self.findQuery = findQuery
        self.forceScrollToBottomToken = forceScrollToBottomToken
        self.outlineEntries = outlineEntries
        self.onLoadThroughPos = onLoadThroughPos
        self.onQuoteReply = onQuoteReply
        self.onAddPassageComment = onAddPassageComment
        self.onRunCommandInTerminal = onRunCommandInTerminal
        self.cardActions = cardActions
        self.isRemoteConnection = isRemoteConnection
        self.canEditFromMessage = canEditFromMessage
        self.canRewindFiles = canRewindFiles
        self.onEditFromMessage = onEditFromMessage
        self.showsPlanHeader = showsPlanHeader
        self.onLoadToolEntry = onLoadToolEntry
    }

    public var body: some View {
        let timeline = ThreadTimelineBuilder.build(
            replica: replica,
            l10n: l10n,
            canForkSession: canForkSession,
            canForkAtMessage: canForkAtMessage
        )
        let hasPendingPerm = timeline.hasPendingPermission

        VStack(spacing: 0) {
            if showsPlanHeader,
               let planItems = timeline.latestPlan,
               !planItems.isEmpty,
               !planItems.allSatisfy({ $0.status == "completed" }) {
                compactPlanHeader(items: planItems)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                let savedReading = SessionReadingPositionStore.shared.load(sessionId: replica.session.id)
                let startsAtBottom: Bool = {
                    guard let savedReading, !savedReading.followingBottom,
                          let anchorID = savedReading.anchorItemID,
                          timeline.items.contains(where: { $0.id == anchorID })
                    else { return true }
                    return false
                }()

                GeometryReader { outerGeo in
                    ZStack(alignment: .bottom) {
                        ScrollView {
                            // Avoid LazyVStack inside bottom-anchored conversation threads: on
                            // macOS, variable-height Markdown rows followed by short rows corrupt
                            // LazyVStack's height estimator, causing blank viewports, phantom
                            // scroll growth during streaming, and broken jump-to-bottom. Settled
                            // history is isolated into Equatable chunks so streaming only diffs
                            // the active tail.
                            VStack(alignment: .leading, spacing: 14) {
                                if let older = replica.older, older > 0, let onLoadOlder {
                                    loadOlderHeader(count: older) {
                                        beginLoadingOlder(timeline: timeline, onLoadOlder: onLoadOlder)
                                    }
                                }

                                if replica.session.status == .authRequired {
                                    authRequiredBanner()
                                }

                                if timeline.items.isEmpty && replica.session.status == .ready {
                                    emptySessionPlaceholder()
                                } else {
                                    let (chunks, tailStart) = settledChunks(for: timeline.items)
                                    if !chunks.isEmpty {
                                        let renderState = currentSettledRenderState()
                                        ForEach(chunks) { chunk in
                                            ThreadSettledChunkView(
                                                items: chunk.items,
                                                linkedSessions: chunk.linkedSessions,
                                                renderState: renderState,
                                                rowBuilder: { item in timelineRowView(item) }
                                            )
                                            .equatable()
                                        }
                                    }

                                    ForEach(timeline.items.suffix(from: tailStart)) { item in
                                        timelineRowView(item)
                                    }
                                }

                                if let summary = resolveSessionSummary?(replica.session.id),
                                   let still = summary.stillRunning,
                                   still.hasWork,
                                   replica.session.status != .running,
                                   replica.session.status != .starting,
                                   summary.status != .running,
                                   summary.status != .starting {
                                    stillRunningRow(still)
                                        .transition(.opacity)
                                }

                                // Keep the bottom anchor flush with scroll content (no outer
                                // `.padding(.bottom)`) so `scrollTo("thread-bottom", anchor: .bottom)`
                                // reaches distanceFromBottom == 0 and preserves native bottom anchoring.
                                Color.clear.frame(height: 36).id("thread-bottom")
                            }
                            .frame(maxWidth: threadWideWidth ? 960 : 760, alignment: .leading)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: max(0, outerGeo.size.height - 14),
                                alignment: .top
                            )
                            .padding(.horizontal, 24)
                            .padding(.top, 14)
                            .coordinateSpace(name: "thread-scroll-content")
                        }
                        #if os(macOS)
                        .background(ThreadScrollViewportProbe())
                        #endif
                        .id(replica.session.id)
                        .defaultScrollAnchor(startsAtBottom ? .bottom : .top)
                        .scrollIndicators(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        .onScrollPhaseChange { _, newPhase in
                            let active = (newPhase == .interacting || newPhase == .decelerating)
                            if tracker.isUserScrolling != active {
                                tracker.isUserScrolling = active
                            }
                        }
                        .onScrollGeometryChange(for: ThreadScrollMetrics.self) { geo in
                            // Use `visibleRect.maxY` rather than `contentSize - containerSize` so safe-area
                            // and scroll insets never distort the distance from bottom.
                            let distBottom = max(0, geo.contentSize.height - geo.visibleRect.maxY)
                            let canScroll = geo.contentSize.height > geo.visibleRect.height + 24
                            return ThreadScrollMetrics(
                                distanceFromBottom: Int((distBottom / 4.0).rounded()) * 4,
                                offset: Int((geo.visibleRect.minY / 4.0).rounded()) * 4,
                                isScrollable: canScroll,
                                contentHeight: Int((geo.contentSize.height / 8.0).rounded()) * 8
                            )
                        } action: { old, metrics in
                            handleScrollMetrics(old: old, new: metrics, timeline: timeline, proxy: proxy)
                        }
                        .task(id: replica.session.id) {
                            let sessionID = replica.session.id
                            activeJumpTask?.cancel()
                            activeJumpTask = nil
                            isJumpAnimating = false
                            ThreadScrollInput.start()
                            ThreadScrollInput.clearRecent()
                            isSettlingInitialScroll = true
                            isScrolledAwayFromBottom = false
                            selectionPausedFollow = false
                            lastAutoFollowSeq = replica.seq
                            followGrowthUntil = 0
                            suppressAutoFollowUntil = 0
                            hasUnseenTurnEnd = false
                            wasTurnRunning = (replica.session.status == .running || replica.session.status == .starting)
                            olderPrependAnchor = nil
                            tracker.reset()
                            loadedBlobs.removeAll()
                            expandedRuns.removeAll()
                            expandedSteps.removeAll()
                            expandedCodeBlocks.removeAll()
                            expandedChangeRows.removeAll()
                            expandedChangeCards.removeAll()
                            expandedFullDiffs.removeAll()
                            expandedResolvedPerms.removeAll()
                            dismissedTextQuestionIDs.removeAll()
                            permissionNotes.removeAll()

                            if !startsAtBottom, let anchorID = savedReading?.anchorItemID {
                                isFollowingBottom = false
                                proxy.scrollTo(anchorID, anchor: .top)
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                proxy.scrollTo(anchorID, anchor: .top)
                                try? await Task.sleep(for: .milliseconds(80))
                                guard !Task.isCancelled else { return }
                                isSettlingInitialScroll = false
                                settledSessionID = sessionID
                            } else {
                                isFollowingBottom = true
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                proxy.scrollTo("thread-bottom", anchor: .bottom)
                                try? await Task.sleep(for: .milliseconds(60))
                                guard !Task.isCancelled else { return }
                                if !tracker.isUserScrolling {
                                    // Catch any streaming growth that arrived during the settle window.
                                    proxy.scrollTo("thread-bottom", anchor: .bottom)
                                    lastAutoFollowSeq = replica.seq
                                    followGrowthUntil = ProcessInfo.processInfo.systemUptime + 0.35
                                    SessionReadingPositionStore.shared.save(
                                        sessionId: sessionID,
                                        anchorItemID: nil,
                                        followingBottom: true
                                    )
                                }
                                isSettlingInitialScroll = false
                                settledSessionID = sessionID
                            }
                        }
                        .task(id: olderAnchorGeneration) {
                            // An older-page request the state ignored never reports loading; drop
                            // its anchor so auto-load works again and no later entry jumps the view.
                            guard olderPrependAnchor != nil else { return }
                            try? await Task.sleep(for: .seconds(2))
                            guard !Task.isCancelled, olderPrependAnchor != nil, !olderLoadObservedStart else { return }
                            olderPrependAnchor = nil
                        }
                    .onChange(of: OlderPageState(older: replica.older, isLoading: isLoadingOlder)) { old, new in
                        handleOlderPageChange(old: old, new: new, timeline: timeline, proxy: proxy)
                    }
                    .onChange(of: replica.seq) { _, _ in
                        let runningNow = (replica.session.status == .running || replica.session.status == .starting)
                        if wasTurnRunning && !runningNow && !isFollowingBottom {
                            hasUnseenTurnEnd = true
                        }
                        wasTurnRunning = runningNow
                        guard settledSessionID == replica.session.id else { return }

                        // A restored reading position sets `isFollowingBottom` to false, so this never
                        // yanks a returning session to the bottom while it settles.
                        guard isFollowingBottom, !tracker.isUserScrolling, !isJumpAnimating else { return }
                        let now = ProcessInfo.processInfo.systemUptime
                        guard now >= suppressAutoFollowUntil else { return }
                        if Self.hasActiveThreadTextSelection() {
                            if !selectionPausedFollow { selectionPausedFollow = true }
                        } else {
                            if selectionPausedFollow { selectionPausedFollow = false }
                            followGrowthUntil = now + 0.35
                            proxy.scrollTo("thread-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: forceScrollToBottomToken) { _, _ in
                        jumpToBottom(proxy: proxy, animated: true)
                    }
                    .onChange(of: scrollTargetToken) { _, _ in
                        if let entryID = scrollTargetEntryID,
                           let targetID = ThreadTimelineBuilder.scrollTargetID(for: entryID, in: timeline.items) {
                            activeJumpTask?.cancel()
                            activeJumpTask = nil
                            isJumpAnimating = false
                            followGrowthUntil = 0
                            isFollowingBottom = false
                            selectionPausedFollow = false
                            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }

                    // Left-edge conversation timeline rail (spans full session outline; auto-hides on narrow windows)
                    #if os(macOS)
                    let mergedNavEntries = ThreadTimelineBuilder.mergeNavEntries(
                        outline: outlineEntries,
                        loaded: timeline.navEntries
                    )
                    if mergedNavEntries.count >= 2 {
                        ThreadNavRailHost(
                            tracker: tracker,
                            entries: mergedNavEntries,
                            isFollowingBottom: isFollowingBottom,
                            stageSize: stageSize,
                            contentMaxWidth: threadWideWidth ? 960 : 760,
                            onJump: { idx, entry in
                                jumpToNavEntry(index: idx, entry: entry, proxy: proxy)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    #endif

                    // Stateful Jump to Latest button (shown ONLY when user actually scrolled up!)
                    let isRunningNow = replica.session.status == .running || replica.session.status == .starting
                    let isFailedNow = replica.session.status == .failed
                    let showJump = (!isFollowingBottom || selectionPausedFollow)
                        && isScrollable
                        && isScrolledAwayFromBottom
                        && !isSettlingInitialScroll
                        && settledSessionID == replica.session.id
                        && contextCommentDraft == nil
                    if showJump {
                        let livePhase: PrismTurnPhase = {
                            if case .liveStatus(let s)? = timeline.items.last { return s.phase }
                            return .working
                        }()

                        Button {
                            jumpToBottom(proxy: proxy, animated: true)
                        } label: {
                            HStack(spacing: 6) {
                                if hasPendingPerm {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(tokens.warning)
                                } else if isRunningNow && !isJumpHovered {
                                    PrismTurnDotsView(phase: livePhase, size: 11)
                                } else {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(
                                            isFailedNow ? tokens.danger
                                                : (hasUnseenTurnEnd ? tokens.primary : tokens.foreground)
                                        )
                                }
                                Text(
                                    hasPendingPerm
                                        ? l10n.tr("thread.jumpToPermission")
                                        : (isFailedNow && hasUnseenTurnEnd
                                            ? l10n.tr("thread.jumpFailed")
                                            : (hasUnseenTurnEnd ? l10n.tr("thread.jumpNewReply") : l10n.tr("thread.jumpToLatest")))
                                )
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(
                                    hasPendingPerm ? tokens.warning
                                        : (isFailedNow && hasUnseenTurnEnd ? tokens.danger
                                            : (hasUnseenTurnEnd ? tokens.primary : tokens.foreground))
                                )
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .prismSurface(elevation: .floating, cornerRadius: 999)
                            .overlay(
                                Capsule().strokeBorder(
                                    hasPendingPerm
                                        ? tokens.warning.opacity(0.55)
                                        : (hasUnseenTurnEnd ? tokens.primary.opacity(0.55) : tokens.borderStrong),
                                    lineWidth: 1
                                )
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { isJumpHovered = $0 }
                        .padding(.bottom, 12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    if let draft = contextCommentDraft {
                        contextCommentOverlayCard(draft: draft)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    }
                    .frame(width: outerGeo.size.width, height: outerGeo.size.height)
                    .onGeometryChange(for: CGSize.self) { proxy in
                        CGSize(
                            width: (proxy.size.width / 8.0).rounded() * 8.0,
                            height: (proxy.size.height / 8.0).rounded() * 8.0
                        )
                    } action: { _, next in
                        if stageSize != next {
                            stageSize = next
                        }
                    }
                }
            }
        }
        .sheet(item: $previewItem) { item in
            PrismImageLightboxView(item: item)
                .environment(\.prismTokens, tokens)
                .environment(\.prismL10n, l10n)
                .preferredColorScheme(tokens.palette.colorScheme)
        }
        #if os(macOS)
        .onDisappear {
            PrismContextMenuPresenter.shared.dismiss()
        }
        #endif
    }

    // MARK: - Scroll Following, Older History & Rail Jumps

    private func handleScrollMetrics(
        old: ThreadScrollMetrics,
        new metrics: ThreadScrollMetrics,
        timeline: ThreadTimelineSnapshot,
        proxy: ScrollViewProxy
    ) {
        let distBottom = CGFloat(metrics.distanceFromBottom)
        let distTop = CGFloat(max(0, metrics.offset))
        let nextAway = isScrolledAwayFromBottom ? (distBottom > 40) : (distBottom > 48)
        if isScrolledAwayFromBottom != nextAway {
            isScrolledAwayFromBottom = nextAway
        }
        if isScrollable != metrics.isScrollable {
            isScrollable = metrics.isScrollable
        }

        let viewportTop = (CGFloat(metrics.offset) / 16.0).rounded() * 16.0
        let viewportTopChanged = tracker.viewportTop != viewportTop
        if viewportTopChanged {
            tracker.viewportTop = viewportTop
            tracker.wakeToken &+= 1
        }

        guard !isSettlingInitialScroll, settledSessionID == replica.session.id else { return }

        // Scroll phases only report drags and flings, so the content offset itself tells whether the
        // view moved: an upward move the content did not cause (wheel, keyboard, VoiceOver, a jump)
        // lets go of the bottom, while growing content alone never does.
        let movedUp = metrics.offset < old.offset && metrics.contentHeight >= old.contentHeight
        let movedDown = metrics.offset > old.offset
        let isUserScrolling = tracker.isUserScrolling
        let wasFollowing = isFollowingBottom
        // SwiftUI also moves the offset up by itself while a stream lays out: a `scrollTo` lands
        // past the bottom it then settles on. Only a move that input caused lets go of the bottom.
        let userMovedUp = movedUp && (isUserScrolling || ThreadScrollInput.isRecent)

        let now = ProcessInfo.processInfo.systemUptime
        let contentGrew = metrics.contentHeight > old.contentHeight
        let allowAutoFollow = !isJumpAnimating
            && now >= suppressAutoFollowUntil
            && (replica.seq != lastAutoFollowSeq || (contentGrew && now < followGrowthUntil))

        if !metrics.isScrollable {
            if !isFollowingBottom { isFollowingBottom = true }
            if selectionPausedFollow { selectionPausedFollow = false }
            if hasUnseenTurnEnd { hasUnseenTurnEnd = false }
            lastAutoFollowSeq = replica.seq
        } else if isFollowingBottom && distBottom > 12 && (userMovedUp || (isUserScrolling && !movedDown)) {
            activeJumpTask?.cancel()
            activeJumpTask = nil
            isJumpAnimating = false
            isFollowingBottom = false
            followGrowthUntil = 0
            if selectionPausedFollow { selectionPausedFollow = false }
        } else if !isFollowingBottom && distBottom <= 16 && (movedDown || isUserScrolling) {
            isFollowingBottom = true
            if selectionPausedFollow { selectionPausedFollow = false }
            hasUnseenTurnEnd = false
            lastAutoFollowSeq = replica.seq
        } else if isFollowingBottom
                    && !isUserScrolling
                    && distBottom > 2
                    && allowAutoFollow {
            // Pin to bottom when new streaming patches arrive or finish multi-frame text wrapping,
            // never when the user expands a folded Work Run, Code Block, or Diff Card in place.
            if Self.hasActiveThreadTextSelection() {
                if !selectionPausedFollow { selectionPausedFollow = true }
            } else {
                if selectionPausedFollow { selectionPausedFollow = false }
                if replica.seq != lastAutoFollowSeq {
                    lastAutoFollowSeq = replica.seq
                    followGrowthUntil = max(followGrowthUntil, now + 0.35)
                }
                proxy.scrollTo("thread-bottom", anchor: .bottom)
            }
        }

        if viewportTopChanged || wasFollowing != isFollowingBottom {
            let anchor: String? = isFollowingBottom ? nil : nearestVisibleUserTurnID(
                viewportTop: viewportTop,
                items: timeline.items
            )
            SessionReadingPositionStore.shared.save(
                sessionId: replica.session.id,
                anchorItemID: anchor,
                followingBottom: isFollowingBottom
            )
        }

        if distTop < 120,
           isUserScrolling || movedUp,
           !isLoadingOlder,
           olderPrependAnchor == nil,
           let older = replica.older, older > 0,
           let onLoadOlder {
            beginLoadingOlder(timeline: timeline, onLoadOlder: onLoadOlder)
        }
    }

    private func beginLoadingOlder(timeline: ThreadTimelineSnapshot, onLoadOlder: () -> Void) {
        olderPrependAnchor = timeline.items.first.map { first in
            OlderPrependAnchor(
                itemID: first.id,
                entryID: timeline.items.lazy.compactMap(\.rawEntryID).first
            )
        }
        olderLoadObservedStart = isLoadingOlder
        olderAnchorGeneration &+= 1
        onLoadOlder()
    }

    /// Restores the reading anchor once the older page lands (`replica.older` changes), and drops it
    /// when loading ends without a page, so a failed load neither blocks auto-load nor lets a later
    /// streamed entry consume the anchor.
    private func handleOlderPageChange(
        old: OlderPageState,
        new: OlderPageState,
        timeline: ThreadTimelineSnapshot,
        proxy: ScrollViewProxy
    ) {
        if new.isLoading && !old.isLoading {
            olderLoadObservedStart = true
        }
        guard let anchor = olderPrependAnchor else { return }
        if new.older != old.older {
            olderPrependAnchor = nil
            tracker.userTurnYByID.removeAll(keepingCapacity: true)
            let targetID: String? = timeline.items.contains(where: { $0.id == anchor.itemID })
                ? anchor.itemID
                : anchor.entryID.flatMap { ThreadTimelineBuilder.scrollTargetID(for: $0, in: timeline.items) }
            if let targetID {
                DispatchQueue.main.async {
                    proxy.scrollTo(targetID, anchor: .top)
                }
            }
        } else if old.isLoading && !new.isLoading {
            olderPrependAnchor = nil
        }
    }

    private func jumpToNavEntry(index: Int, entry: ThreadTimelineNavEntry, proxy: ScrollViewProxy) {
        activeJumpTask?.cancel()
        activeJumpTask = nil
        isJumpAnimating = false
        followGrowthUntil = 0
        isFollowingBottom = false
        selectionPausedFollow = false
        let tracker = tracker
        tracker.pendingNavIndex = index
        tracker.pendingNavTask?.cancel()
        tracker.pendingNavTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            tracker.pendingNavIndex = nil
        }
        if entry.isLoaded {
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                proxy.scrollTo(entry.scrollItemID, anchor: .top)
            }
        } else if let pos = entry.pos, let onLoadThroughPos {
            let animation = PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)
            Task { @MainActor in
                let ok = await onLoadThroughPos(pos)
                guard ok else { return }
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(animation) {
                    proxy.scrollTo(entry.scrollItemID, anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineItemView(_ item: ThreadTimelineItem) -> some View {
        switch item {
        case .user(let id, let text, let content, let at, let steered):
            userBubble(id: id, text: text, content: content, at: at, steered: steered)
                .padding(.top, 6)

        case .agent(let id, let markdown, let streaming, _, let attachments):
            agentReplyBlock(entryID: id, markdown: markdown, streaming: streaming, attachments: attachments)

        case .workRun(let run):
            workRunView(run)

        case .permissionCard(let data):
            standalonePermissionCard(data)

        case .textQuestionCard(let id, let questions):
            if !dismissedTextQuestionIDs.contains(id) {
                acpTextQuestionCard(id: id, questions: questions)
            }

        case .subagent(_, let sessionId):
            subagentCardView(sessionId: sessionId)

        case .sessionStarted(_, let sessionId):
            linkedSessionRow(sessionId: sessionId)

        case .sessionMessage(_, let senderId, let senderTitle, let text):
            sessionMessageRow(senderId: senderId, senderTitle: senderTitle, text: text)

        case .sessionReport(_, let from, let ended, let at, let steered):
            sessionReportRow(from: from, ended: ended, at: at, steered: steered)

        case .takeover(_, let agentId, let turns, let omitted, let summarize):
            takeoverDivider(agentId: agentId, turns: turns, omitted: omitted, summarize: summarize)

        case .notice(_, let severity, let title, let description, _, let canRetry):
            noticeBanner(severity: severity, title: title, description: description, canRetry: canRetry)

        case .compaction(_, let status, let summary):
            HStack(spacing: 8) {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                Text(l10n.tr("thread.compaction", status, summary))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
            }
            .padding(.vertical, 4)

        case .git(let payload):
            GitEventEntryRow(payload: payload)

        case .memory(let payload):
            MemoryWriteEntryCardView(payload: payload, actions: cardActions)

        case .settingsChange(let payload):
            SettingsChangeEntryCardView(payload: payload, actions: cardActions)

        case .browserOrigin(let payload):
            ProtocolApprovalEntryCardView(
                icon: "globe",
                title: l10n.tr("thread.browser.originTitle", payload.origin),
                subtitle: nil,
                details: [],
                isPending: payload.decision == nil,
                settledBadge: payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerBrowserOrigin?(payload.id, "allow") }),
                    (l10n.tr("thread.entry.alwaysAllow"), false, { cardActions.onAnswerBrowserOrigin?(payload.id, "always") }),
                    (l10n.tr("thread.entry.deny"), false, { cardActions.onAnswerBrowserOrigin?(payload.id, "deny") }),
                ]
            )

        case .controlAsk(let payload):
            ProtocolApprovalEntryCardView(
                icon: "person.badge.shield.checkmark",
                title: l10n.tr("thread.control.askTitle", payload.target ?? payload.surface),
                subtitle: payload.reason,
                details: [],
                isPending: payload.outcome == nil,
                settledBadge: payload.outcome,
                buttons: [
                    (l10n.tr("thread.entry.done"), true, { cardActions.onAnswerControlAsk?(payload.id, "done") }),
                    (l10n.tr("thread.entry.skip"), false, { cardActions.onAnswerControlAsk?(payload.id, "skip") }),
                ]
            )

        case .controlNote(let payload):
            ControlNoteEntryRow(payload: payload)

        case .deviceAccess(let payload):
            ProtocolApprovalEntryCardView(
                icon: "iphone",
                title: l10n.tr("thread.device.accessTitle", payload.deviceName.isEmpty ? payload.deviceId : payload.deviceName),
                subtitle: nil,
                details: [],
                isPending: payload.decision == nil,
                settledBadge: payload.revoked == true ? "revoked" : payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerDeviceAccess?(payload.id, "allow") }),
                    (l10n.tr("thread.entry.alwaysAllow"), false, { cardActions.onAnswerDeviceAccess?(payload.id, "always") }),
                    (l10n.tr("thread.entry.deny"), false, { cardActions.onAnswerDeviceAccess?(payload.id, "deny") }),
                ]
            )

        case .surfaceAccess(let payload):
            ProtocolApprovalEntryCardView(
                icon: payload.surface == "terminal" ? "terminal" : "safari",
                title: l10n.tr("thread.surface.accessTitle", payload.targetName.isEmpty ? payload.surface : payload.targetName),
                subtitle: payload.rename.map { "→ \($0)" },
                details: [],
                isPending: payload.decision == nil,
                settledBadge: payload.revoked == true ? "revoked" : payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerSurfaceAccess?(payload.id, "allow") }),
                    (l10n.tr("thread.entry.deny"), false, { cardActions.onAnswerSurfaceAccess?(payload.id, "deny") }),
                ]
            )

        case .computerApp(let payload):
            ProtocolApprovalEntryCardView(
                icon: "macwindow",
                title: l10n.tr("thread.computer.appTitle", payload.appName.isEmpty ? payload.appId : payload.appName),
                subtitle: nil,
                details: [],
                isPending: payload.decision == nil,
                settledBadge: payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerComputerApp?(payload.id, "allow") }),
                    (l10n.tr("thread.entry.alwaysAllow"), false, { cardActions.onAnswerComputerApp?(payload.id, "always") }),
                    (l10n.tr("thread.entry.deny"), false, { cardActions.onAnswerComputerApp?(payload.id, "deny") }),
                ]
            )

        case .computerSetup(let payload):
            ProtocolApprovalEntryCardView(
                icon: "hand.raised.square",
                title: l10n.tr("thread.computer.setupTitle"),
                subtitle: nil,
                details: payload.steps.map { step in (payload.done.contains(step) ? "✓ " : "○ ") + step },
                isPending: payload.outcome == nil,
                settledBadge: payload.outcome,
                buttons: [
                    (l10n.tr("thread.entry.notNow"), false, { cardActions.onDeclineComputerSetup?(payload.id) }),
                ]
            )

        case .projectMcp(let payload):
            ProtocolApprovalEntryCardView(
                icon: "server.rack",
                title: l10n.tr("thread.mcp.title"),
                subtitle: nil,
                details: payload.servers.map { "\($0.name): \($0.target)" },
                isPending: payload.decision == nil,
                settledBadge: payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerProjectMcp?(payload.id, "use") }),
                    (l10n.tr("thread.entry.allowAll"), false, { cardActions.onAnswerProjectMcp?(payload.id, "all") }),
                    (l10n.tr("thread.entry.skip"), false, { cardActions.onAnswerProjectMcp?(payload.id, "skip") }),
                ]
            )

        case .projectHooks(let payload):
            ProtocolApprovalEntryCardView(
                icon: "bolt.shield",
                title: l10n.tr("thread.hooks.title"),
                subtitle: nil,
                details: payload.hooks.map { "[\($0.event)] \($0.target)" },
                isPending: payload.decision == nil,
                settledBadge: payload.decision,
                buttons: [
                    (l10n.tr("thread.entry.allow"), true, { cardActions.onAnswerProjectHooks?(payload.id, "use") }),
                    (l10n.tr("thread.entry.allowAll"), false, { cardActions.onAnswerProjectHooks?(payload.id, "all") }),
                    (l10n.tr("thread.entry.skip"), false, { cardActions.onAnswerProjectHooks?(payload.id, "skip") }),
                ]
            )

        case .problemReport(let payload):
            ProblemReportEntryCardView(
                payload: payload,
                isSignedIn: cardActions.isCloudSignedIn,
                onSubmitDirectly: cardActions.onSubmitProblemReport,
                onEdit: cardActions.onOpenProblemReport,
                onSkip: { cardActions.onAnswerProblemReport?(payload.id, "skipped") }
            )

        case .marketPublish(let payload):
            ProtocolApprovalEntryCardView(
                icon: "shippingbox",
                title: l10n.tr("thread.market.publishTitle", payload.action, payload.item.name.isEmpty ? payload.item.slug : payload.item.name),
                subtitle: payload.notes ?? payload.item.description,
                details: [payload.folder, payload.version.map { "v\($0)" }].compactMap { $0 }.filter { !$0.isEmpty },
                isPending: payload.outcome == nil,
                settledBadge: payload.outcome?.kind,
                buttons: [
                    (l10n.tr("thread.entry.confirm"), true, { cardActions.onAnswerMarketPublish?(payload.id, "confirm") }),
                    (l10n.tr("thread.entry.notNow"), false, { cardActions.onAnswerMarketPublish?(payload.id, "later") }),
                ]
            )

        case .turnFooter(let footer):
            turnFooterView(footer)

        case .liveStatus(let status):
            liveTurnStatusRow(status)
        }
    }

    private func loadOlderHeader(count: Int, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: 6) {
                    if isLoadingOlder {
                        PrismTurnDotsView(phase: .thinking, size: 11)
                        Text(l10n.tr("thread.loadingOlder"))
                            .font(.system(size: 11.5, weight: .medium))
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium))
                        Text(l10n.tr("thread.loadOlder", count))
                            .font(.system(size: 11.5, weight: .medium))
                    }
                }
                .foregroundStyle(tokens.secondaryForeground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(tokens.surface1))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(isLoadingOlder)
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func authRequiredBanner() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(tokens.warning)
                Text(l10n.tr("thread.authRequiredTitle"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.warning)
            }
            Text(l10n.tr("thread.authRequiredBody", replica.session.agentId))
                .font(.system(size: 12))
                .foregroundStyle(tokens.secondaryForeground)
            if let onRetryTurn {
                Button(action: onRetryTurn) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text(l10n.tr("thread.retryTurn"))
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(tokens.warningSoft))
                    .overlay(Capsule().strokeBorder(tokens.warning.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.45), lineWidth: 1)
        )
    }

    private func emptySessionPlaceholder() -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 22))
                .foregroundStyle(tokens.prismCobalt.opacity(0.75))
            Text(l10n.tr("thread.emptyTitle"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tokens.foreground)
            Text(l10n.tr("thread.emptySubtitle"))
                .font(.system(size: 12))
                .foregroundStyle(tokens.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    // MARK: - 1. Compact Pinned Execution Plan Bar (replaces duplicate inline plan cards)

    private func compactPlanHeader(items: [PlanItem]) -> some View {
        let done = items.filter { $0.status == "completed" }.count
        let activeItem = items.first(where: { $0.status == "in_progress" })

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                suppressAutoFollowBriefly()
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    isPlanExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.prismCobalt)

                    Text(l10n.tr("thread.planTitle"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tokens.secondaryForeground)

                    Text("\(done)/\(items.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(done == items.count ? tokens.success : tokens.prismCobalt)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(done == items.count ? tokens.successSoft : tokens.prismCobalt.opacity(0.14)))

                    if !isPlanExpanded, let active = activeItem {
                        Text("· \(active.content)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                        .rotationEffect(.degrees(isPlanExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isPlanExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : (item.status == "in_progress" ? "circle.inset.filled" : "circle"))
                                .font(.system(size: 10.5))
                                .foregroundStyle(item.status == "completed" ? tokens.success : (item.status == "in_progress" ? tokens.prismCobalt : tokens.placeholder))
                            Text(item.content)
                                .font(.system(size: 12))
                                .foregroundStyle(item.status == "completed" ? tokens.mutedForeground : tokens.foreground)
                                .strikethrough(item.status == "completed", color: tokens.placeholder)
                        }
                    }
                }
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: threadWideWidth ? 960 : 760, alignment: .leading)
        .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
    }

    // MARK: - 2. User Bubble (with Attachments, Image Thumbnails, Timestamp & Hover Copy)

    @ViewBuilder
    private func userBubble(id: String, text: String, content: [UserContent], at: Double?, steered: Bool) -> some View {
        let refs = content.compactMap(\.ref)
        let copyKey = "user-\(id)"
        let isCopied = copiedIDs.contains(copyKey)
        let editFrom = editFromAction(for: id)

        if !text.isEmpty || !refs.isEmpty {
            // Hover lives in a child so entering a bubble re-renders only that bubble.
            HoverTracking { isHovered in
                VStack(alignment: .trailing, spacing: 5) {
                    if steered {
                        Text(l10n.tr("thread.steeredBadge"))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tokens.primarySoft))
                    }

                    if !refs.isEmpty {
                        userRefsStrip(refs)
                    }

                    if !text.isEmpty {
                        userTextRendered(text)
                            .font(.system(size: 14.5))
                            .lineSpacing(4)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(tokens.foreground.opacity(0.95))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .fill(tokens.userBubbleBackground)
                                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.white.opacity(tokens.palette.isDark ? 0.045 : 0.45), Color.clear],
                                                startPoint: .topTrailing,
                                                endPoint: .center
                                            )
                                        )
                                }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .strokeBorder(tokens.border, lineWidth: 1)
                            )
                            .overlay(alignment: .top) {
                                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                    .stroke(tokens.specular, lineWidth: 1)
                                    .mask(VStack(spacing: 0) { Rectangle().frame(height: 1.5); Spacer(minLength: 0) })
                                    .allowsHitTesting(false)
                            }
                    }

                    if at != nil || !text.isEmpty || editFrom != nil {
                        HStack(spacing: 8) {
                            if let at, at > 0 {
                                Text(Self.formatMessageTime(at))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                            }
                            if let editFrom {
                                UserMessageEditButton(
                                    prepare: {
                                        replica.rewindFacts(from: id).map {
                                            RewindConfirmationModel(
                                                facts: $0,
                                                cache: replica.session.usage?.cache,
                                                rewindFiles: canRewindFiles
                                            )
                                        }
                                    },
                                    onEdit: editFrom,
                                    onAskingChange: { open in
                                        if open {
                                            editConfirmEntryID = id
                                        } else if editConfirmEntryID == id {
                                            editConfirmEntryID = nil
                                        }
                                    }
                                )
                            }
                            if !text.isEmpty {
                                Button {
                                    triggerCopy(id: copyKey, text: text)
                                } label: {
                                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(isCopied ? tokens.success : tokens.placeholder)
                                }
                                .buttonStyle(.plain)
                                .help(l10n.tr("thread.copy"))
                            }
                        }
                        .opacity(isHovered || isCopied || editConfirmEntryID == id ? 1 : 0)
                        .frame(height: 14)
                    }
                }
                .padding(.leading, 72)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Edit from here for a sent message the session lets the user edit from, nil for any other.
    private func editFromAction(for entryID: String) -> (() -> Void)? {
        guard canEditFromMessage,
              let onEditFromMessage,
              EditableMessageMemo.shared.ids(for: replica).contains(entryID)
        else { return nil }
        return { onEditFromMessage(entryID) }
    }

    private func userTextRendered(_ raw: String) -> Text {
        if !findQuery.isEmpty {
            var attr = AttributedString(raw)
            CodeSyntaxHighlighter.applySearchHighlights(to: &attr, query: findQuery, isDark: tokens.palette.isDark)
            return Text(attr)
        }
        return Text(raw)
    }

    @MainActor
    private static let messageTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return fmt
    }()

    private static func formatMessageTime(_ ms: Double) -> String {
        let secs = ms > 10_000_000_000 ? ms / 1000.0 : ms
        let date = Date(timeIntervalSince1970: secs)
        return messageTimeFormatter.string(from: date)
    }

    // MARK: - 3. Folded Work Run (Calm 1-Line Progress + Expandable Timeline Rail)

    private func workRunView(_ run: WorkRunSummary) -> some View {
        let isExpanded = expandedRuns.contains(run.id)

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                suppressAutoFollowBriefly()
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    if isExpanded { expandedRuns.remove(run.id) }
                    else { expandedRuns.insert(run.id) }
                }
            } label: {
                let icons = run.stackedIcons.isEmpty ? ["sparkle"] : run.stackedIcons
                let liveText = run.isLive ? run.liveHeadline.flatMap({ $0.isEmpty ? nil : $0 }) : nil
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)

                    // Calm stacked tool icon tiles always stay in place
                    // so toggling running state never jumps width or height.
                    HStack(spacing: -4) {
                        ForEach(Array(icons.enumerated()), id: \.offset) { idx, sym in
                            let highlight = run.isLive && idx == icons.count - 1
                            Image(systemName: sym)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(highlight ? tokens.primary : tokens.mutedForeground)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(tokens.surface1))
                                .overlay(
                                    Circle().strokeBorder(
                                        highlight ? tokens.primary.opacity(0.45) : tokens.borderEtched,
                                        lineWidth: 0.75
                                    )
                                )
                        }
                    }

                    Text(liveText ?? run.summaryText)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(run.isLive ? tokens.foreground.opacity(0.92) : tokens.secondaryForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    if run.totalInsertions > 0 || run.totalDeletions > 0 {
                        diffCountPill(insertions: run.totalInsertions, deletions: run.totalDeletions)
                            .fixedSize()
                    }

                    if run.failedCount > 0 {
                        Text(l10n.tr("thread.summary.failedBadge", run.failedCount))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.danger)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.dangerSoft))
                            .fixedSize()
                    }

                    Spacer(minLength: 4)

                    // Inline image thumbnails produced by this work run
                    if !isExpanded && !run.imageRefs.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(run.imageRefs.prefix(3).enumerated()), id: \.offset) { _, ref in
                                workRunMiniThumb(ref)
                            }
                        }
                    }

                    if liveText != nil && run.steps.count > 1 {
                        Text(l10n.tr("thread.summary.toolMany", run.steps.count))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .fixedSize()
                    } else if let ms = run.totalDurationMs, ms >= 200 {
                        Text(ThreadTimelineBuilder.formatDuration(ms))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .fill(isExpanded ? tokens.hoverWash.opacity(0.65) : Color.clear)
                )
                .contentShape(Rectangle())
                .transaction { $0.animation = nil }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.steps) { step in
                        workStepRow(step)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tokens.borderEtched)
                        .frame(width: 1)
                        .padding(.leading, 9)
                        .padding(.vertical, 4)
                }
                .padding(.leading, 2)
                .transition(.opacity)
            }
        }
    }

    private func workStepRow(_ step: WorkStepPresentation) -> some View {
        let isOpen = expandedSteps.contains(step.id)

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                guard step.hasDetails else { return }
                suppressAutoFollowBriefly()
                let willOpen = !isOpen
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    if isOpen { expandedSteps.remove(step.id) }
                    else { expandedSteps.insert(step.id) }
                }
                if willOpen, case .tool(let data) = step.entry, data.hasDigestedContent {
                    hydrateEntry(data.id)
                }
            } label: {
                HStack(spacing: 7) {
                    if step.isRunning {
                        PrismStepPulseDot(size: 14)
                    } else {
                        Image(systemName: step.iconName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(step.isFailed ? tokens.danger : (step.isCancelled ? tokens.placeholder : tokens.mutedForeground))
                            .frame(width: 14)
                    }

                    Text(step.verb)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(step.isFailed ? tokens.danger : tokens.secondaryForeground)

                    if !step.target.isEmpty {
                        Text(step.target)
                            .font(.system(size: 11.5, design: step.iconName == "sparkle" ? .default : .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if step.insertions > 0 || step.deletions > 0 {
                        diffCountPill(insertions: step.insertions, deletions: step.deletions)
                    }

                    if step.isFailed {
                        Text(l10n.tr("thread.step.failed"))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.danger)
                    } else if step.isCancelled {
                        Text(l10n.tr("thread.step.cancelled"))
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }

                    Spacer(minLength: 4)

                    if let ms = step.durationMs, ms >= 200 {
                        Text(ThreadTimelineBuilder.formatDuration(ms))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }

                    if step.hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(tokens.placeholder)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(isOpen ? tokens.surface1.opacity(0.65) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen && step.hasDetails {
                stepDetailBody(step)
                    .padding(.leading, 22)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func stepDetailBody(_ step: WorkStepPresentation) -> some View {
        switch step.entry {
        case .thought(_, let markdown, _, _):
            Text(markdown)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(tokens.secondaryForeground.opacity(0.86))
                .textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tokens.prismCobalt.opacity(0.35))
                        .frame(width: 1.5)
                }

        case .tool(let data):
            let isShell = data.toolKind == "execute"
            let combinedShellOut: String = isShell
                ? data.content.compactMap { item -> String? in
                    if case .markdown(let md) = item { return stripOuterFence(md) }
                    return nil
                }.joined(separator: "\n")
                : ""

            VStack(alignment: .leading, spacing: 8) {
                if isShell {
                    ANSIShellBlockView(
                        command: extractShellCommand(from: data),
                        output: combinedShellOut,
                        isFailed: data.status == "failed",
                        findQuery: findQuery,
                        onRunInTerminal: onRunCommandInTerminal
                    )
                } else if let rawInput = data.rawInput, !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    toolInputBlock(id: "cmd-\(data.id)", tool: data, rawInput: rawInput)
                } else if let digestInfo = data.rawInputDigestInfo {
                    toolDigestRow(
                        entryId: data.id,
                        of: "input",
                        path: nil,
                        lines: digestInfo.lines,
                        size: digestInfo.size,
                        added: nil,
                        removed: nil
                    )
                } else if data.rawInputDigest != nil {
                    toolDigestRow(
                        entryId: data.id,
                        of: "input",
                        path: nil,
                        lines: nil,
                        size: nil,
                        added: nil,
                        removed: nil
                    )
                }

                if data.status == "failed", data.content.isEmpty {
                    failedToolReasonHint(data)
                }

                ForEach(Array(data.content.enumerated()), id: \.offset) { idx, item in
                    switch item {
                    case .diff(let path, let oldText, let newText):
                        compactDiffHunkCard(
                            id: "\(data.id)-diff-\(idx)",
                            path: path,
                            oldText: oldText,
                            newText: newText
                        )

                    case .markdown(let md):
                        if !isShell {
                            compactToolOutputBlock(markdown: md)
                        }

                    case .digest(let of, let path, let lines, let size, let added, let removed):
                        toolDigestRow(
                            entryId: data.id,
                            of: of,
                            path: path,
                            lines: lines,
                            size: size,
                            added: added,
                            removed: removed
                        )

                    case .ref(let ref):
                        userRefsStrip([ref])

                    case .other:
                        EmptyView()
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    private func hydrateEntry(_ entryId: String) {
        guard let onLoadToolEntry, !loadingEntryIDs.contains(entryId) else { return }
        loadingEntryIDs.insert(entryId)
        Task {
            await onLoadToolEntry(entryId)
            loadingEntryIDs.remove(entryId)
        }
    }

    private func hydrateEntries(_ entryIDs: [String]) {
        for entryId in entryIDs {
            hydrateEntry(entryId)
        }
    }

    private func formatDigestBytes(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576.0)
        }
        if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024.0)
        }
        return "\(bytes) B"
    }

    @ViewBuilder
    private func toolDigestRow(
        entryId: String,
        of: String,
        path: String?,
        lines: Int?,
        size: Int?,
        added: Int?,
        removed: Int?
    ) -> some View {
        let isLoading = loadingEntryIDs.contains(entryId)
        let displayPath = path.map {
            ThreadTimelineBuilder.relativeDisplayPath($0, projectPath: replica.session.projectPath)
        }
        let parts: [String] = {
            var list: [String] = []
            if let displayPath, !displayPath.isEmpty {
                list.append(displayPath)
            } else {
                list.append(of)
            }
            if let lines, lines > 0 {
                list.append("\(lines) lines")
            }
            if let sizeText = formatDigestBytes(size) {
                list.append(sizeText)
            }
            if added != nil || removed != nil {
                list.append("+\(added ?? 0)/-\(removed ?? 0)")
            }
            return list
        }()

        Button {
            hydrateEntry(entryId)
        } label: {
            HStack(spacing: 7) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                }
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(tokens.surface1.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .strokeBorder(tokens.borderEtched, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || onLoadToolEntry == nil)
    }

    // MARK: - 4. Compact Unified Diff Hunks (never dumps whole unmodified files!)

    private func compactDiffHunkCard(id: String, path: String, oldText: String?, newText: String) -> some View {
        let computed = ThreadDiffCache.shared.computeWithLines(path: path, oldText: oldText, newText: newText)
        let allLines = computed.lines
        let showFull = expandedFullDiffs.contains(id)
        let previewLimit = 22
        let isFoldable = allLines.count > previewLimit
        let displayPath = ThreadTimelineBuilder.relativeDisplayPath(path, projectPath: replica.session.projectPath)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(displayPath)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if oldText == nil {
                    Text(l10n.tr("thread.diff.newFile"))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tokens.success)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tokens.successSoft))
                }

                Spacer()
                diffCountPill(insertions: computed.diff.insertions, deletions: computed.diff.deletions)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            if showFull && isFoldable {
                ThreadDiffLinesView(lines: allLines)
                    .background(tokens.codeBackground)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(allLines.prefix(previewLimit)) { line in
                            ThreadDiffLineRow(line: line)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .background(tokens.codeBackground)
            }

            if isFoldable {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                Button {
                    suppressAutoFollowBriefly()
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        if showFull { expandedFullDiffs.remove(id) }
                        else { expandedFullDiffs.insert(id) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showFull ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(showFull ? l10n.tr("thread.diff.collapse") : l10n.tr("thread.diff.showAll", allLines.count))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tokens.codeHeaderBackground.opacity(0.8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func toolInputBlock(id: String, tool: ToolEntryData, rawInput: String) -> some View {
        if tool.toolKind == "execute" {
            commandHeaderBlock(id: id, command: rawInput)
        } else {
            structuredToolInputBlock(id: id, tool: tool, rawInput: rawInput)
        }
    }

    private func structuredToolInputBlock(id: String, tool: ToolEntryData, rawInput: String) -> some View {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.parseStructuredToolInput(trimmed, projectPath: replica.session.projectPath)
        let isCopied = copiedIDs.contains(id)

        return HStack(alignment: .top, spacing: 8) {
            if let parsed {
                VStack(alignment: .leading, spacing: 4) {
                    if let displayPath = parsed.displayPath {
                        HStack(spacing: 6) {
                            Text(displayPath)
                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.secondaryForeground)
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)

                            if let lineRange = parsed.lineRange {
                                Text(l10n.tr("thread.tool.linesRange", lineRange))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(tokens.hoverWash))
                                    .fixedSize()
                            }
                        }
                    }

                    ForEach(Array(parsed.extraPairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(pair.key)
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(tokens.placeholder)
                                .fixedSize()
                            Text(pair.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(trimmed)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(tokens.secondaryForeground)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            copyIconButton(id: id, text: parsed?.rawPath ?? trimmed, isCopied: isCopied)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tokens.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func failedToolReasonHint(_ data: ToolEntryData) -> some View {
        FailedToolReasonHint(tool: data, isRemoteConnection: isRemoteConnection)
    }

    /// Says why a tool failed without details. Whether its file is missing is checked off the main
    /// thread, since a file system call must never run in a view body.
    private struct FailedToolReasonHint: View {
        @Environment(\.prismTokens) private var tokens
        @Environment(\.prismL10n) private var l10n

        let tool: ToolEntryData
        let isRemoteConnection: Bool

        @State private var missingFile = false

        var body: some View {
            hint(missingFile: missingFile)
                .task(id: tool.id) {
                    let tool = tool
                    let isRemote = isRemoteConnection
                    let missing = await Task.detached(priority: .utility) {
                        SessionThreadView.detectMissingLocalFile(for: tool, isRemoteConnection: isRemote)
                    }.value
                    guard !Task.isCancelled, missing != missingFile else { return }
                    missingFile = missing
                }
        }

        private func hint(missingFile: Bool) -> some View {
            let message = missingFile
                ? l10n.tr("thread.tool.fileNotFound")
                : l10n.tr("thread.tool.failedNoDetail")

            return HStack(spacing: 6) {
                Image(systemName: missingFile ? "doc.questionmark" : "exclamationmark.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.danger)
                Text(message)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.danger.opacity(0.92))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .fill(tokens.dangerSoft.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .strokeBorder(tokens.danger.opacity(0.24), lineWidth: 1)
            )
        }
    }

    private struct ParsedToolInput {
        let rawPath: String?
        let displayPath: String?
        let lineRange: String?
        let extraPairs: [(key: String, value: String)]
    }

    private static func parseStructuredToolInput(_ raw: String, projectPath: String) -> ParsedToolInput? {
        guard raw.first == "{",
              let data = raw.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !dict.isEmpty
        else { return nil }

        let pathKeys = ["Path", "path", "file_path", "AbsolutePath", "FilePath"]
        let rawPath = pathKeys.compactMap { dict[$0] as? String }.first
        let displayPath = rawPath.map { ThreadTimelineBuilder.relativeDisplayPath($0, projectPath: projectPath) }

        let startLine = (dict["StartLine"] as? NSNumber)?.intValue ?? (dict["offset"] as? NSNumber)?.intValue
        let endLine = (dict["EndLine"] as? NSNumber)?.intValue
        let limit = (dict["limit"] as? NSNumber)?.intValue
        let lineRange: String? = {
            if let s = startLine, let e = endLine { return "\(s)–\(e)" }
            if let s = startLine, let l = limit { return "\(s)–\(s + max(0, l - 1))" }
            if let s = startLine { return "\(s)+" }
            if let e = endLine { return "1–\(e)" }
            return nil
        }()

        let consumedKeys: Set<String> = [
            "Path", "path", "file_path", "AbsolutePath", "FilePath",
            "StartLine", "EndLine", "offset", "limit",
            "Content", "Target", "Replacement", "old_string", "new_string", "content",
        ]
        var pairs: [(key: String, value: String)] = []
        for key in dict.keys.sorted() where !consumedKeys.contains(key) {
            let val = dict[key]
            let rendered: String
            if let s = val as? String {
                let single = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if single.isEmpty { continue }
                rendered = single.count > 120 ? String(single.prefix(119)) + "…" : single
            } else if let b = val as? Bool {
                rendered = b ? "true" : "false"
            } else if let n = val as? NSNumber {
                rendered = n.stringValue
            } else {
                continue
            }
            pairs.append((key: key, value: rendered))
            if pairs.count >= 4 { break }
        }

        guard displayPath != nil || !pairs.isEmpty else { return nil }
        return ParsedToolInput(rawPath: rawPath, displayPath: displayPath, lineRange: lineRange, extraPairs: pairs)
    }

    nonisolated fileprivate static func detectMissingLocalFile(for tool: ToolEntryData, isRemoteConnection: Bool) -> Bool {
        guard !isRemoteConnection else { return false }
        #if os(macOS)
        let fileKinds: Set<String> = ["read", "edit", "delete", "move"]
        guard fileKinds.contains(tool.toolKind) else { return false }
        var candidate = tool.locations.first?.path
        if candidate == nil,
           let raw = tool.rawInput?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.first == "{",
           let jsonData = raw.data(using: .utf8),
           let dict = (try? JSONSerialization.jsonObject(with: jsonData)) as? [String: Any]
        {
            candidate = ["Path", "path", "file_path", "AbsolutePath", "FilePath"]
                .compactMap { dict[$0] as? String }
                .first
        }
        guard let path = candidate, path.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: path)
        #else
        return false
        #endif
    }

    private func commandHeaderBlock(id: String, command: String) -> some View {
        let isCopied = copiedIDs.contains(id)
        return HStack(alignment: .top, spacing: 8) {
            Text("$ \(command)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(tokens.secondaryForeground)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            copyIconButton(id: id, text: command, isCopied: isCopied)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tokens.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func compactToolOutputBlock(markdown: String) -> some View {
        ThreadToolOutputBlock(markdown: markdown)
    }

    // MARK: - 5. Structured Agent Markdown Reply (with Syntax Highlighting, Alerts, Diagrams, Math & Attachments)

    #if os(macOS)
    private enum ReplyRenderSegment: Identifiable {
        case prose(id: Int, blocks: [MarkdownBlock])
        case block(MarkdownBlock)

        var id: Int {
            switch self {
            case .prose(let id, _): return id
            case .block(let block): return block.id
            }
        }
    }

    private static func isMergeableProseBlock(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList, .blockquote, .divider:
            return true
        case .alert, .table, .codeBlock, .mermaid, .svg, .mathBlock, .image:
            return false
        }
    }

    private static func groupedReplySegments(_ blocks: [MarkdownBlock]) -> [ReplyRenderSegment] {
        var segments: [ReplyRenderSegment] = []
        segments.reserveCapacity(blocks.count)
        var proseBuffer: [MarkdownBlock] = []

        func flushProse() {
            guard let first = proseBuffer.first else { return }
            segments.append(.prose(id: first.id, blocks: proseBuffer))
            proseBuffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if isMergeableProseBlock(block) {
                proseBuffer.append(block)
            } else {
                flushProse()
                segments.append(.block(block))
            }
        }
        flushProse()
        return segments
    }
    #endif

    private func agentReplyBlock(entryID: String, markdown: String, streaming: Bool, attachments: [ContentRef]) -> some View {
        let blocks = MarkdownBlockParser.parseCached(entryID: entryID, markdown: markdown)
        return VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            let segments = Self.groupedReplySegments(blocks)
            ForEach(segments) { segment in
                switch segment {
                case .prose(_, let proseBlocks):
                    ThreadProseTextView(
                        blocks: proseBlocks,
                        tokens: tokens,
                        typography: typography,
                        findQuery: findQuery,
                        projectPath: replica.session.projectPath,
                        onOpenProjectFile: onOpenProjectFile,
                        contextMenuConfig: ThreadProseContextMenuConfig(
                            l10n: l10n,
                            motionTier: motionTier,
                            reduceMotion: reduceMotion,
                            entryID: entryID,
                            fullReplyMarkdown: markdown,
                            isRemoteConnection: isRemoteConnection,
                            onOpenURLInBrowser: onOpenURLInBrowser,
                            onQuoteReply: onQuoteReply,
                            onRequestPassageComment: onAddPassageComment == nil ? nil : { targetEntryID, passage in
                                contextCommentNote = ""
                                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                    contextCommentDraft = ContextCommentDraft(entryID: targetEntryID, passage: passage)
                                }
                                DispatchQueue.main.async {
                                    isContextCommentFocused = true
                                }
                            },
                            onFindInSession: onFindInSession
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .block(let block):
                    markdownBlockView(entryID: entryID, block: block)
                }
            }
            #else
            ForEach(blocks) { block in
                markdownBlockView(entryID: entryID, block: block)
            }
            #endif

            if !attachments.isEmpty {
                userRefsStrip(attachments)
            }

            if streaming {
                HStack(spacing: 8) {
                    PrismTurnDotsView(phase: .writing, size: 12)
                    Text(l10n.tr("thread.streaming"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .frame(height: 22)
                .padding(.top, 2)
                .transaction { $0.animation = nil }
            }
        }
        .padding(.horizontal, 2)
        .environment(\.openURL, OpenURLAction { url in
            #if os(macOS)
            if let filePath = ThreadProseTextView.resolveLocalFilePath(url: url, projectPath: replica.session.projectPath) {
                // Agent text must never hand a local file to the system, which could launch it.
                guard let onOpenProjectFile else { return .discarded }
                let rel = ThreadTimelineBuilder.relativeDisplayPath(filePath, projectPath: replica.session.projectPath)
                onOpenProjectFile(rel)
                return .handled
            }
            #else
            if url.isFileURL {
                guard let onOpenProjectFile else { return .discarded }
                let rel = ThreadTimelineBuilder.relativeDisplayPath(url.path, projectPath: replica.session.projectPath)
                onOpenProjectFile(rel)
                return .handled
            }
            #endif
            // Links come from agent output, so only web and mail links reach the system; other
            // schemes could open arbitrary apps.
            switch url.scheme?.lowercased() {
            case "http", "https", "mailto":
                return .systemAction
            default:
                return .discarded
            }
        })
    }

    @ViewBuilder
    private func markdownBlockView(entryID: String, block: MarkdownBlock) -> some View {
        switch block {
        case .heading(_, let level, let text):
            let size: CGFloat = level == 1 ? 18 : (level == 2 ? 16.5 : 15)
            inlineMarkdownText(text)
                .font(typography.proseFont(size: size, weight: .semibold))
                .foregroundStyle(tokens.foreground)
                .padding(.top, level <= 2 ? 6 : 3)
                .textSelection(.enabled)

        case .paragraph(_, let text):
            inlineMarkdownText(text)
                .font(typography.proseFont(size: 14.5))
                .lineSpacing(5)
                .foregroundStyle(tokens.foreground.opacity(0.94))
                .textSelection(.enabled)

        case .bulletList(_, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(tokens.mutedForeground.opacity(0.7))
                            .frame(width: 4.5, height: 4.5)
                            .padding(.top, 8)
                        inlineMarkdownText(item)
                            .font(typography.proseFont(size: 14.5))
                            .lineSpacing(4.5)
                            .foregroundStyle(tokens.foreground.opacity(0.94))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 4)

        case .orderedList(_, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 7) {
                        Text("\(item.number).")
                            .font(typography.codeFont(size: 13.5, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                            .frame(minWidth: 20, alignment: .trailing)
                        inlineMarkdownText(item.text)
                            .font(typography.proseFont(size: 14.5))
                            .lineSpacing(4.5)
                            .foregroundStyle(tokens.foreground.opacity(0.94))
                            .textSelection(.enabled)
                    }
                }
            }

        case .blockquote(_, let text):
            inlineMarkdownText(text)
                .font(typography.proseFont(size: 13.5))
                .lineSpacing(4.5)
                .foregroundStyle(tokens.secondaryForeground)
                .textSelection(.enabled)
                .padding(.leading, 12)
                .padding(.vertical, 2)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tokens.prismCobalt.opacity(0.45))
                        .frame(width: 2)
                }

        case .alert(_, let kind, let text):
            GitHubAlertCardView(kind: kind, text: text, findQuery: findQuery)

        case .table(_, let headers, let rows):
            markdownTableView(headers: headers, rows: rows)

        case .mermaid(_, let source):
            OfflineDiagramCardView(kind: .mermaid(source), findQuery: findQuery)

        case .svg(_, let source):
            OfflineDiagramCardView(kind: .svg(source), findQuery: findQuery)

        case .mathBlock(_, let latex):
            OfflineDiagramCardView(kind: .math(latex), findQuery: findQuery)

        case .image(_, let alt, let url):
            MarkdownImageBlockView(
                alt: alt,
                url: url,
                projectPath: replica.session.projectPath,
                onPreview: { item in previewItem = item }
            )

        case .divider:
            Rectangle()
                .fill(tokens.borderEtched)
                .frame(height: 1)
                .padding(.vertical, 4)

        case .codeBlock(let blockID, let language, let filename, let code, let lineCount):
            foldableCodeBlock(
                key: "\(entryID)-code-\(blockID)",
                language: language,
                filename: filename,
                code: code,
                lineCount: lineCount
            )
        }
    }

    private func markdownTableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        inlineMarkdownText(header)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .textSelection(.enabled)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(tokens.codeHeaderBackground)

                ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                    Rectangle()
                        .fill(tokens.borderEtched)
                        .frame(height: 1)
                        .gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inlineMarkdownText(cell)
                                .font(.system(size: 12.5))
                                .foregroundStyle(tokens.foreground.opacity(0.9))
                                .textSelection(.enabled)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .background(rIdx % 2 == 1 ? tokens.surface1.opacity(0.45) : tokens.codeBackground)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func foldableCodeBlock(
        key: String,
        language: String?,
        filename: String?,
        code: String,
        lineCount: Int
    ) -> some View {
        let isExpanded = expandedCodeBlocks.contains(key)
        let isFoldable = lineCount > MarkdownBlockParser.foldOverLines
        let preview = MarkdownBlockParser.previewCode(code, lineCount: lineCount, expanded: isExpanded)
        let isCopied = copiedIDs.contains(key)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(filename ?? language ?? l10n.tr("thread.code.plain"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)

                if filename != nil, let language {
                    Text(language)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }

                Spacer()

                if isFoldable {
                    Text("\(lineCount) L")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }

                if let lang = language?.lowercased(),
                   ["sh", "bash", "zsh", "shell", "console"].contains(lang),
                   let onRunCommandInTerminal {
                    Button {
                        onRunCommandInTerminal(code)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 8.5))
                            Text(l10n.tr("thread.code.runInTerminal"))
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(tokens.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }

                copyIconButton(id: key, text: code, isCopied: isCopied)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            ZStack(alignment: .bottom) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(CodeSyntaxHighlighter.highlight(preview.shown, language: language, tokens: tokens, findQuery: findQuery))
                        .font(typography.codeFont(size: 12))
                        .lineSpacing(3.5)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(tokens.codeBackground)

                if preview.hiddenCount > 0 {
                    LinearGradient(
                        colors: [tokens.codeBackground.opacity(0), tokens.codeBackground.opacity(0.96)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 28)
                    .allowsHitTesting(false)
                }
            }

            if isFoldable {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                Button {
                    suppressAutoFollowBriefly()
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        if isExpanded { expandedCodeBlocks.remove(key) }
                        else { expandedCodeBlocks.insert(key) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(isExpanded ? l10n.tr("thread.code.showLess") : l10n.tr("thread.code.showMore", preview.hiddenCount))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(tokens.mutedForeground)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(tokens.codeHeaderBackground.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    private func inlineMarkdownText(_ raw: String) -> Text {
        if let attr = InlineMarkdownEngine.render(raw, findQuery: findQuery, isDark: tokens.palette.isDark) {
            return Text(attr)
        }
        return Text(raw)
    }

    // MARK: - 6. Turn Footer: Sarto ChangesCard + Quiet Action Row

    @ViewBuilder
    private func contextCommentOverlayCard(draft: ContextCommentDraft) -> some View {
        let trimmedNote = contextCommentNote.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.primary)
                Text(l10n.tr("contextMenu.addComment"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                Button {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        contextCommentDraft = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text(draft.passage.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(2)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tokens.primary.opacity(0.65))
                        .frame(width: 2)
                }

            HStack(spacing: 8) {
                TextField(l10n.tr("composer.comments.addPlaceholder"), text: $contextCommentNote)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(tokens.foreground)
                    .focused($isContextCommentFocused)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface2.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    .onSubmit {
                        let note = contextCommentNote.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !note.isEmpty else { return }
                        onAddPassageComment?(draft.entryID, draft.passage, note)
                        contextCommentNote = ""
                        contextCommentDraft = nil
                    }

                Button {
                    guard !trimmedNote.isEmpty else { return }
                    onAddPassageComment?(draft.entryID, draft.passage, trimmedNote)
                    contextCommentNote = ""
                    contextCommentDraft = nil
                } label: {
                    Text(l10n.tr("composer.comments.save"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(trimmedNote.isEmpty ? tokens.placeholder : tokens.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background(
                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                .fill(trimmedNote.isEmpty ? Color.clear : tokens.primarySoft)
                        )
                }
                .buttonStyle(.plain)
                .disabled(trimmedNote.isEmpty)
            }
        }
        .padding(11)
        .frame(maxWidth: 420)
        .prismSurface(elevation: .popover, cornerRadius: tokens.rMD)
        .onExitCommand {
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                contextCommentDraft = nil
            }
        }
    }

    private func turnFooterView(_ footer: TurnFooterSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !footer.changedFiles.isEmpty {
                turnChangesCard(footer)
            }

            HStack(spacing: 12) {
                if !footer.replyText.isEmpty {
                    let copyKey = "reply-\(footer.id)"
                    let isCopied = copiedIDs.contains(copyKey)
                    Button {
                        triggerCopy(id: copyKey, text: footer.replyText)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10))
                            Text(isCopied ? l10n.tr("thread.copied") : l10n.tr("thread.copy"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(isCopied ? tokens.success : tokens.placeholder)
                    }
                    .buttonStyle(.plain)

                    if let onQuoteReply {
                        Button {
                            let picked = Self.currentThreadSelectedText() ?? ThreadTimelineBuilder.truncateSingleLine(footer.replyText, maxChars: 240)
                            onQuoteReply(picked)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "quote.opening")
                                    .font(.system(size: 9.5))
                                Text(l10n.tr("thread.quoteReply"))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(tokens.placeholder)
                        }
                        .buttonStyle(.plain)
                    }

                    if let onAddPassageComment {
                        Button {
                            commentingPassage = Self.currentThreadSelectedText() ?? ThreadTimelineBuilder.truncateSingleLine(footer.replyText, maxChars: 240)
                            commentingNote = ""
                            commentingFooterID = footer.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "text.bubble")
                                    .font(.system(size: 9.5))
                                Text(l10n.tr("composer.comments.addAction"))
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(commentingFooterID == footer.id ? tokens.primary : tokens.placeholder)
                        }
                        .buttonStyle(.plain)
                        .popover(
                            isPresented: Binding(
                                get: { commentingFooterID == footer.id },
                                set: { if !$0 && commentingFooterID == footer.id { commentingFooterID = nil } }
                            ),
                            arrowEdge: .top
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(commentingPassage.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 11))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .lineLimit(2)
                                    .padding(.leading, 7)
                                    .overlay(alignment: .leading) {
                                        Rectangle().fill(tokens.borderStrong).frame(width: 2)
                                    }

                                TextField(l10n.tr("composer.comments.addPlaceholder"), text: $commentingNote)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundStyle(tokens.foreground)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: tokens.rXS).fill(tokens.surface2.opacity(0.65)))
                                    .overlay(RoundedRectangle(cornerRadius: tokens.rXS).strokeBorder(tokens.borderEtched, lineWidth: 1))
                                    .onSubmit {
                                        let trimmed = commentingNote.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !trimmed.isEmpty else { return }
                                        onAddPassageComment(footer.forkEntryID, commentingPassage, trimmed)
                                        commentingFooterID = nil
                                    }

                                HStack {
                                    Spacer()
                                    Button(l10n.tr("composer.comments.save")) {
                                        let trimmed = commentingNote.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !trimmed.isEmpty else { return }
                                        onAddPassageComment(footer.forkEntryID, commentingPassage, trimmed)
                                        commentingFooterID = nil
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(commentingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tokens.placeholder : tokens.primary)
                                    .disabled(commentingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                            }
                            .padding(11)
                            .frame(width: 310)
                            .background(tokens.surface1)
                            .focusEffectDisabled()
                            .presentationBackground(tokens.surface1)
                            .environment(\.prismTokens, tokens)
                            .environment(\.prismL10n, l10n)
                            .preferredColorScheme(tokens.palette.colorScheme)
                        }
                    }
                }

                if let forkEntryID = footer.forkEntryID, let onForkTurn {
                    Button {
                        onForkTurn(forkEntryID)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 10))
                            Text(forkEntryID == "__latest__" ? l10n.tr("thread.forkSession") : l10n.tr("thread.forkTurn"))
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(tokens.placeholder)
                    }
                    .buttonStyle(.plain)
                }

                if let reason = footer.stopReason {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(reason == "end_turn" ? tokens.success.opacity(0.8) : tokens.warning)
                            .frame(width: 4.5, height: 4.5)
                        Text(localizedStopReason(reason, durationMs: footer.durationMs))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func turnChangesCard(_ footer: TurnFooterSummary) -> some View {
        let showAll = expandedChangeCards.contains(footer.id)
        let shownLimit = 3
        let visibleFiles = showAll ? footer.changedFiles : Array(footer.changedFiles.prefix(shownLimit))
        let hiddenCount = max(0, footer.changedFiles.count - shownLimit)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.prismCobalt)
                Text(l10n.tr("thread.changes.title", footer.changedFiles.count))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                diffCountPill(insertions: footer.totalInsertions, deletions: footer.totalDeletions)
                if let firstFile = footer.changedFiles.first, let onOpenFileDiff {
                    Button {
                        onOpenFileDiff(firstFile.displayPath)
                    } label: {
                        Text(l10n.tr("thread.changes.review"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            VStack(spacing: 0) {
                ForEach(visibleFiles) { file in
                    let rowKey = "\(footer.id)::\(file.path)"
                    let isOpen = expandedChangeRows.contains(rowKey)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 6) {
                            Button {
                                suppressAutoFollowBriefly()
                                let willOpen = !isOpen
                                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                    if isOpen { expandedChangeRows.remove(rowKey) }
                                    else { expandedChangeRows.insert(rowKey) }
                                }
                                if willOpen, !file.digestEntryIDs.isEmpty {
                                    hydrateEntries(file.digestEntryIDs)
                                }
                            } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(tokens.placeholder)
                                        .rotationEffect(.degrees(isOpen ? 90 : 0))

                                    Image(systemName: PrismImageDecoder.symbolName(for: file.fileName, mimeType: nil, type: "file"))
                                        .font(.system(size: 11))
                                        .foregroundStyle(tokens.mutedForeground)

                                    HStack(spacing: 0) {
                                        if !file.directoryPrefix.isEmpty {
                                            Text(file.directoryPrefix)
                                                .foregroundStyle(tokens.placeholder)
                                        }
                                        Text(file.fileName)
                                            .foregroundStyle(tokens.foreground)
                                    }
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                    Spacer(minLength: 8)
                                    diffCountPill(insertions: file.insertions, deletions: file.deletions)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if let onOpenFileDiff {
                                Button {
                                    onOpenFileDiff(file.displayPath)
                                } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                                .buttonStyle(.plain)
                                .help(l10n.tr("thread.changes.review"))
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 32)

                        if isOpen {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(file.diffs.enumerated()), id: \.offset) { idx, d in
                                    compactDiffHunkCard(
                                        id: "\(rowKey)-\(idx)",
                                        path: d.path,
                                        oldText: d.oldText,
                                        newText: d.newText
                                    )
                                }
                                if !file.digestEntryIDs.isEmpty {
                                    let isAnyLoading = file.digestEntryIDs.contains { loadingEntryIDs.contains($0) }
                                    Button {
                                        hydrateEntries(file.digestEntryIDs)
                                    } label: {
                                        HStack(spacing: 7) {
                                            if isAnyLoading {
                                                ProgressView()
                                                    .controlSize(.mini)
                                                    .scaleEffect(0.75)
                                                    .frame(width: 12, height: 12)
                                            } else {
                                                Image(systemName: "arrow.down.circle")
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundStyle(tokens.mutedForeground)
                                            }
                                            Text("\(file.fileName) · +\(file.insertions)/-\(file.deletions)")
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                                .fill(tokens.surface1.opacity(0.65))
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                                                .strokeBorder(tokens.borderEtched, lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isAnyLoading || onLoadToolEntry == nil)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }

                    if file.id != visibleFiles.last?.id || hiddenCount > 0 {
                        Rectangle().fill(tokens.borderEtched.opacity(0.65)).frame(height: 1)
                    }
                }

                if hiddenCount > 0 {
                    Button {
                        suppressAutoFollowBriefly()
                        withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                            if showAll { expandedChangeCards.remove(footer.id) }
                            else { expandedChangeCards.insert(footer.id) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showAll ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(showAll ? l10n.tr("thread.changes.fewer") : l10n.tr("thread.changes.more", hiddenCount))
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(tokens.surface1.opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    // MARK: - 7. Live Turn Status Row (Sarto 9-Dot Phase Indicator + Drift-Free Clock)

    private func liveTurnStatusRow(_ status: LiveTurnStatus) -> some View {
        HStack(spacing: 8) {
            PrismTurnDotsView(phase: status.isWaiting ? .waiting : status.phase, size: 12)

            if let startedMs = status.startedAtMs {
                LiveTurnClockLabel(startedAtMs: startedMs)
                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.placeholder.opacity(0.65))
            }

            Text(status.phaseText)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(status.isWaiting ? tokens.warning : tokens.mutedForeground)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.identity)
        }
        .padding(.horizontal, 4)
        .frame(height: 22, alignment: .leading)
        .transaction { $0.animation = nil }
    }

    /// Isolated 1Hz elapsed clock anchored to the turn's fixed start timestamp so rapid streaming
    /// re-renders of the parent thread view never reset or jitter the tick cadence.
    private struct LiveTurnClockLabel: View {
        @Environment(\.prismTokens) private var tokens
        let startedAtMs: Double

        var body: some View {
            let startSec = floor(startedAtMs / 1000.0)
            let anchor = Date(timeIntervalSince1970: startSec)
            TimelineView(.periodic(from: anchor, by: 1.0)) { context in
                let elapsedSec = max(0, Int(floor(context.date.timeIntervalSince1970 - startSec)))
                Text(elapsedSec < 60 ? "\(elapsedSec)s" : "\(elapsedSec / 60)m \(elapsedSec % 60)s")
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tokens.placeholder)
                    .contentTransition(.identity)
            }
        }
    }

    // MARK: - 8. Standalone Permission / Plan / Question Approval Card (Never Folded!)

    @ViewBuilder
    private func standalonePermissionCard(_ tool: ToolEntryData) -> some View {
        if let perm = tool.permission, let plan = perm.plan {
            PlanApprovalCardView(
                tool: tool,
                permission: perm,
                plan: plan,
                onRespond: onRespondPermission
            )
        } else if let perm = tool.permission, let elic = perm.elicitation {
            ElicitationCardView(
                requestId: perm.requestId,
                elicitation: elic,
                options: perm.options
            ) { reqId, optId, values in
                if let onRespondElic = cardActions.onRespondElicitation {
                    onRespondElic(reqId, optId, values)
                } else {
                    onRespondPermission(reqId, optId, nil, nil)
                }
            }
        } else if let perm = tool.permission {
            waitingPermissionCard(tool, permission: perm)
        } else {
            resolvedPermissionRow(tool)
        }
    }

    private func waitingPermissionCard(_ tool: ToolEntryData, permission perm: PendingPermission) -> some View {
        let supportsNote = perm.options.contains(where: { $0.note == true })
        let noteBinding = Binding<String>(
            get: { permissionNotes[perm.requestId] ?? "" },
            set: { permissionNotes[perm.requestId] = $0 }
        )

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tokens.warning)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: tokens.warning.opacity(0.55), radius: 4)

                Text(tool.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)

                Spacer()

                Text(l10n.tr("thread.awaitingApproval"))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 6.5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.warningSoft))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                if let rawInput = tool.rawInput, !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    toolInputBlock(id: "perm-cmd-\(tool.id)", tool: tool, rawInput: rawInput)
                }

                ForEach(Array(tool.content.enumerated()), id: \.offset) { idx, item in
                    switch item {
                    case .diff(let path, let oldText, let newText):
                        compactDiffHunkCard(id: "perm-diff-\(tool.id)-\(idx)", path: path, oldText: oldText, newText: newText)
                    case .markdown(let md):
                        compactToolOutputBlock(markdown: md)
                    case .digest(let of, let path, let lines, let size, let added, let removed):
                        toolDigestRow(
                            entryId: tool.id,
                            of: of,
                            path: path,
                            lines: lines,
                            size: size,
                            added: added,
                            removed: removed
                        )
                    case .ref(let ref):
                        userRefsStrip([ref])
                    case .other:
                        EmptyView()
                    }
                }

                if let questions = perm.questions, !questions.isEmpty {
                    let cancelOption = perm.options.first(where: { $0.kind.contains("reject") })
                    MultiQuestionCardView(
                        requestId: perm.requestId,
                        questions: questions,
                        onSubmit: { answers in
                            onRespondPermission(perm.requestId, nil, nil, answers)
                        },
                        onCancel: {
                            if let cancelOption {
                                onRespondPermission(perm.requestId, cancelOption.id, nil, nil)
                            } else {
                                onRespondPermission(perm.requestId, nil, nil, [])
                            }
                        }
                    )
                } else {
                    if supportsNote {
                        TextField(l10n.tr("thread.permission.notePlaceholder"), text: noteBinding)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6.5)
                            .background(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).fill(tokens.surface1))
                            .overlay(RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
                    }

                    let inFlight = answeredPermissionRequestIDs.contains(perm.requestId)
                    HStack(spacing: 8) {
                        Spacer()
                        ForEach(perm.options) { opt in
                            let isPrimary = opt.preferred == true || opt.kind == "allow_once"
                            let isReject = opt.kind.contains("reject")
                            Button {
                                let rawNote = (permissionNotes[perm.requestId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                let noteToSend = (opt.note == true && !rawNote.isEmpty) ? rawNote : nil
                                respondToPermissionOnce(requestID: perm.requestId, optionID: opt.id, note: noteToSend)
                            } label: {
                                Text(opt.name)
                                    .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
                                    .foregroundStyle(
                                        isPrimary
                                            ? tokens.inverseInk
                                            : (isReject ? tokens.danger : tokens.secondaryForeground)
                                    )
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(
                                                isPrimary
                                                    ? tokens.inverseFill
                                                    : (isReject ? tokens.dangerSoft : tokens.hoverWash)
                                            )
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(
                                                isPrimary ? Color.clear : (isReject ? tokens.danger.opacity(0.32) : tokens.border),
                                                lineWidth: 1
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .disabled(inFlight)
                    .opacity(inFlight ? 0.55 : 1)
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(tokens.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.45), lineWidth: 1)
        )
        .prismSemanticAura(.waiting, cornerRadius: tokens.rSM)
    }

    /// Sends one answer per request: further clicks are ignored until the host clears the request,
    /// or until the lock times out because the answer never arrived.
    private func respondToPermissionOnce(requestID: String, optionID: String, note: String?) {
        guard !answeredPermissionRequestIDs.contains(requestID) else { return }
        answeredPermissionRequestIDs.insert(requestID)
        onRespondPermission(requestID, optionID, note, nil)
        Task { @MainActor in
            try? await Task.sleep(for: threadAnswerLockTimeout)
            answeredPermissionRequestIDs.remove(requestID)
        }
    }

    /// Interactive multi/single-select question card synthesized for ACP agents (like `agy acp`) that
    /// fall back to plain-text Q&A when calling `ask_question`. Submitting sends a clean text-only reply.
    private func acpTextQuestionCard(id: String, questions: [PendingQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(tokens.warning)
                Text(l10n.tr("thread.question.acpTitle"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer(minLength: 8)
                Text(l10n.tr("thread.question.textReplyBadge"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tokens.warningSoft))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(tokens.codeHeaderBackground)

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            MultiQuestionCardView(
                requestId: "acp-q-\(id)",
                questions: questions,
                onSubmit: { answers in
                    let formatted = Self.formatTextQuestionAnswers(questions: questions, answers: answers)
                    guard !formatted.isEmpty else { return }
                    onSendTextReply?(formatted)
                },
                onCancel: {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        _ = dismissedTextQuestionIDs.insert(id)
                    }
                }
            )
            .padding(12)
            .background(tokens.codeBackground)
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.warning.opacity(0.42), lineWidth: 1)
        )
        .prismSemanticAura(.waiting, cornerRadius: tokens.rSM)
    }

    private static func formatTextQuestionAnswers(
        questions: [PendingQuestion],
        answers: [QuestionAnswer]
    ) -> String {
        let byIndex = Dictionary(uniqueKeysWithValues: answers.map { ($0.question, $0) })
        var lines: [String] = []
        for (qIdx, q) in questions.enumerated() {
            guard let ans = byIndex[qIdx] else { continue }
            var parts: [String] = ans.choices.sorted().compactMap { cIdx in
                guard q.options.indices.contains(cIdx) else { return nil }
                return "[\(cIdx + 1)] \(q.options[cIdx].label)"
            }
            if let custom = ans.text?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                parts.append(custom)
            }
            guard !parts.isEmpty else { continue }
            let joined = parts.joined(separator: "; ")
            if questions.count > 1 {
                lines.append("Q\(qIdx + 1): \(joined)")
            } else {
                lines.append(joined)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func resolvedPermissionRow(_ tool: ToolEntryData) -> some View {
        let isOpen = expandedResolvedPerms.contains(tool.id)
        let rawStringOutcome = tool.permissionResult?.stringValue
        let resObj = tool.permissionResult?.objectValue
        let outcome = rawStringOutcome ?? resObj?["outcome"]?.stringValue ?? ""
        let kind = resObj?["kind"]?.stringValue ?? ""
        let optionName = resObj?["name"]?.stringValue ?? resObj?["optionName"]?.stringValue
        let questionsArr = resObj?["questions"]?.arrayValue ?? resObj?["answers"]?.arrayValue
        let fieldsArr = resObj?["fields"]?.arrayValue
        let noteText = resObj?["note"]?.stringValue

        let isCancelledOutcome = outcome == "cancelled"
        let isWithdrawnOutcome = outcome == "withdrawn"
        let isRejected = isCancelledOutcome || kind.contains("reject")
        let isAnswered = !isRejected && !isWithdrawnOutcome && (questionsArr != nil || fieldsArr != nil || tool.question != nil)
        let badgeColor: Color = {
            if isWithdrawnOutcome { return tokens.mutedForeground }
            if isCancelledOutcome { return tokens.mutedForeground }
            if isRejected { return tokens.danger }
            if isAnswered { return tokens.prismCobalt }
            return tokens.success
        }()
        let badgeBg: Color = {
            if isWithdrawnOutcome || isCancelledOutcome { return tokens.hoverWash }
            if isRejected { return tokens.dangerSoft }
            if isAnswered { return tokens.primarySoft }
            return tokens.successSoft
        }()
        let badgeLabel: String = {
            if let optionName, !optionName.isEmpty { return optionName }
            if isWithdrawnOutcome { return "Withdrawn" }
            if isCancelledOutcome { return l10n.tr("thread.step.cancelled") }
            if isRejected { return l10n.tr("thread.permission.rejected") }
            if isAnswered { return l10n.tr("thread.permission.answered") }
            return l10n.tr("thread.permission.allowed")
        }()
        let leadingIcon: String = {
            if isWithdrawnOutcome { return "minus.circle" }
            if isRejected { return "xmark.circle.fill" }
            if isAnswered { return "questionmark.circle.fill" }
            return "checkmark.shield.fill"
        }()
        let hasDetails = !tool.content.isEmpty
            || !(tool.rawInput?.isEmpty ?? true)
            || tool.hasDigestedContent
            || !(questionsArr?.isEmpty ?? true)
            || !(fieldsArr?.isEmpty ?? true)
            || !(noteText?.isEmpty ?? true)

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetails else { return }
                suppressAutoFollowBriefly()
                let willOpen = !isOpen
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    if isOpen { expandedResolvedPerms.remove(tool.id) }
                    else { expandedResolvedPerms.insert(tool.id) }
                }
                if willOpen, tool.hasDigestedContent {
                    hydrateEntry(tool.id)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: leadingIcon)
                        .font(.system(size: 11.5))
                        .foregroundStyle(badgeColor)

                    Text(tool.planVersion.map { l10n.tr("thread.plan.version", $0) } ?? tool.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)

                    if let noteText, !noteText.isEmpty {
                        Text("· \(noteText)")
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Text(badgeLabel)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(badgeBg))

                    if hasDetails {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(tokens.placeholder)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen && hasDetails {
                Rectangle().fill(tokens.borderEtched).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    if let questionsArr, !questionsArr.isEmpty {
                        ForEach(Array(questionsArr.enumerated()), id: \.offset) { _, ans in
                            let obj = ans.objectValue
                            let qText = obj?["question"]?.stringValue ?? ""
                            let wasAnswered = obj?["answered"]?.boolValue ?? true
                            let aText = obj?["answer"]?.stringValue ?? (wasAnswered ? "•••" : "-")
                            VStack(alignment: .leading, spacing: 2) {
                                if !qText.isEmpty {
                                    Text(qText)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                                Text(aText)
                                    .font(.system(size: 12))
                                    .foregroundStyle(wasAnswered ? tokens.foreground : tokens.mutedForeground)
                            }
                        }
                    }

                    if let fieldsArr, !fieldsArr.isEmpty {
                        ForEach(Array(fieldsArr.enumerated()), id: \.offset) { _, field in
                            let obj = field.objectValue
                            let fTitle = obj?["title"]?.stringValue ?? ""
                            let fValue = obj?["value"]?.stringValue ?? ""
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if !fTitle.isEmpty {
                                    Text("\(fTitle):")
                                        .font(.system(size: 11.5, weight: .medium))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                                Text(fValue)
                                    .font(.system(size: 12))
                                    .foregroundStyle(tokens.foreground)
                            }
                        }
                    }

                    if let rawInput = tool.rawInput, !rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        toolInputBlock(id: "res-cmd-\(tool.id)", tool: tool, rawInput: rawInput)
                    } else if let digestInfo = tool.rawInputDigestInfo {
                        toolDigestRow(
                            entryId: tool.id,
                            of: "input",
                            path: nil,
                            lines: digestInfo.lines,
                            size: digestInfo.size,
                            added: nil,
                            removed: nil
                        )
                    } else if tool.rawInputDigest != nil {
                        toolDigestRow(
                            entryId: tool.id,
                            of: "input",
                            path: nil,
                            lines: nil,
                            size: nil,
                            added: nil,
                            removed: nil
                        )
                    }

                    ForEach(Array(tool.content.enumerated()), id: \.offset) { idx, item in
                        switch item {
                        case .diff(let path, let oldText, let newText):
                            compactDiffHunkCard(id: "res-diff-\(tool.id)-\(idx)", path: path, oldText: oldText, newText: newText)
                        case .markdown(let md):
                            compactToolOutputBlock(markdown: md)
                        case .digest(let of, let path, let lines, let size, let added, let removed):
                            toolDigestRow(
                                entryId: tool.id,
                                of: of,
                                path: path,
                                lines: lines,
                                size: size,
                                added: added,
                                removed: removed
                            )
                        default:
                            EmptyView()
                        }
                    }
                }
                .padding(11)
                .background(tokens.codeBackground)
            }
        }
        .background(tokens.surface1.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(tokens.borderEtched, lineWidth: 1)
        )
    }

    // MARK: - 8b. Subagent Progress Card, Linked Sessions & Agent Takeover Divider (Items 8 & 10)

    private func subagentCardView(sessionId: String) -> some View {
        let child = resolveSessionSummary?(sessionId)
        let isRunning = child?.status == .running || child?.status == .starting
        let isWaiting = child?.status == .awaitingPermission || (child?.permissionCount ?? 0) > 0
        let isFailed = child?.status == .failed
        let statusColor = isWaiting ? tokens.warning : (isFailed ? tokens.danger : (isRunning ? tokens.prismCobalt : tokens.success))
        let statusLabel: String = {
            if isWaiting { return l10n.tr("thread.subagent.waiting") }
            if isFailed { return l10n.tr("thread.subagent.failed") }
            if isRunning { return l10n.tr("thread.subagent.running") }
            return l10n.tr("thread.subagent.done")
        }()

        return Button {
            onSelectSession?(sessionId)
        } label: {
            HStack(spacing: 10) {
                if isRunning {
                    PrismTurnDotsView(phase: .working, size: 12)
                        .frame(width: 18)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                        .frame(width: 18)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(l10n.tr("thread.subagent.badge"))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))

                        Text(child?.title ?? sessionId)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                            .lineLimit(1)
                    }

                    if let desc = child?.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.secondaryForeground)
                            .lineLimit(1)
                    }

                    if let act = child?.activity, isRunning {
                        Text(act.detail.map { "\(act.title) · \($0)" } ?? act.title)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(statusColor.opacity(0.14)))

                if onSelectSession != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.placeholder)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .prismSurface(elevation: .raised, cornerRadius: tokens.rSM)
            .overlay(
                RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                    .strokeBorder(isWaiting ? tokens.warning.opacity(0.45) : tokens.borderEtched, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(l10n.tr("thread.subagent.open"))
    }

    private func linkedSessionRow(sessionId: String) -> some View {
        let target = resolveSessionSummary?(sessionId)
        return Button {
            onSelectSession?(sessionId)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.prismCobalt)
                Text(l10n.tr("thread.sessionStarted.label"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.mutedForeground)
                Text(target?.title ?? sessionId)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .prismSurface(elevation: .flat, cornerRadius: tokens.rSM)
        }
        .buttonStyle(.plain)
    }

    private func sessionMessageRow(senderId: String?, senderTitle fallbackTitle: String?, text: String) -> some View {
        let liveTitle = senderId.flatMap { resolveSessionSummary?($0)?.title }
        let senderTitle = (liveTitle?.isEmpty == false ? liveTitle : nil)
            ?? (fallbackTitle?.isEmpty == false ? fallbackTitle : nil)
            ?? senderId
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "envelope.open")
                    .font(.system(size: 10.5))
                    .foregroundStyle(tokens.prismCobalt)
                Text(senderTitle.map { "\(l10n.tr("thread.sessionMessage.label")) · \($0)" } ?? l10n.tr("thread.sessionMessage.label"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.secondaryForeground)
                Spacer(minLength: 8)
                if let senderId, !senderId.isEmpty, let onSelectSession {
                    Button {
                        onSelectSession(senderId)
                    } label: {
                        HStack(spacing: 3) {
                            Text(l10n.tr("board.openSubagent"))
                                .font(.system(size: 10.5, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8.5, weight: .semibold))
                        }
                        .foregroundStyle(tokens.prismCobalt)
                    }
                    .buttonStyle(.plain)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tokens.foreground.opacity(0.9))
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSurface(elevation: .flat, cornerRadius: tokens.rSM)
    }

    private func sessionReportRow(
        from: FromSession,
        ended: FromSessionEnded,
        at: Double?,
        steered: Bool
    ) -> some View {
        let style = SessionReportStyle.resolve(stopReason: ended.stopReason, tokens: tokens)
        let liveTitle = resolveSessionSummary?(from.sessionId)?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = from.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (liveTitle?.isEmpty == false ? liveTitle : nil)
            ?? (!fallback.isEmpty ? fallback : String(from.sessionId.prefix(8)))

        return HoverTracking { isHovered in
            Button {
                onSelectSession?(from.sessionId)
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: style.icon)
                            .font(.system(size: 10, weight: .semibold))
                        Text(ended.agent)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                    .foregroundStyle(style.tint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(style.softFill))
                    .overlay(Capsule().strokeBorder(style.tint.opacity(0.24), lineWidth: 0.75))
                    .fixedSize(horizontal: true, vertical: false)

                    Text(displayTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(l10n.tr(style.threadStatusKey))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 8)

                    if steered {
                        Text(l10n.tr("thread.steeredBadge"))
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                    }

                    if let at, at > 0 {
                        Text(Self.formatMessageTime(at))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isHovered ? tokens.prismCobalt : tokens.placeholder)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .prismSurface(elevation: .flat, cornerRadius: tokens.rSM)
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(isHovered ? tokens.prismCobalt.opacity(0.35) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(l10n.tr("thread.subagent.open"))
        }
        .padding(.top, 4)
    }

    private func takeoverDivider(agentId: String, turns: Int, omitted: Int, summarize: Bool) -> some View {
        let extra = (omitted > 0 ? l10n.tr("thread.takeover.omitted", omitted) : "")
            + (summarize ? l10n.tr("thread.takeover.summarized") : "")
        return HStack(spacing: 10) {
            Rectangle().fill(tokens.borderEtched).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tokens.prismIris)
                Text(l10n.tr("thread.takeover.title", agentId))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                if turns > 0 {
                    Text(l10n.tr("thread.takeover.detail", turns, extra))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tokens.surface1))
            .overlay(Capsule().strokeBorder(tokens.prismIris.opacity(0.35), lineWidth: 1))
            Rectangle().fill(tokens.borderEtched).frame(height: 1)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 9. Notice (with Failed-Turn Retry) & User Attachment Thumbnails

    private func noticeBanner(severity: String, title: String, description: String?, canRetry: Bool) -> some View {
        let color: Color = severity == "error" ? tokens.danger : (severity == "warning" ? tokens.warning : tokens.prismCobalt)
        let isPendingQuestionImageError: Bool = {
            guard let desc = description?.lowercased() else { return false }
            return desc.contains("pending question") && desc.contains("reply in text")
        }()
        let resolvedTitle: String = {
            if isPendingQuestionImageError {
                return l10n.tr("thread.notice.pendingQuestionTextOnlyTitle")
            }
            if title == "The turn failed" {
                return l10n.tr("thread.notice.turnFailed")
            }
            return title
        }()
        let resolvedDescription: String? = isPendingQuestionImageError
            ? l10n.tr("thread.notice.pendingQuestionTextOnlyBody")
            : description
        let allowRetry = canRetry && !isPendingQuestionImageError

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resolvedTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(color)
                    if let resolvedDescription, !resolvedDescription.isEmpty {
                        Text(resolvedDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.secondaryForeground)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    if severity == "error", let onReportTurnError = cardActions.onReportTurnError {
                        Button {
                            let errSummary = [resolvedTitle, resolvedDescription]
                                .compactMap { $0 }
                                .filter { !$0.isEmpty }
                                .joined(separator: "\n")
                            onReportTurnError(errSummary)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "ladybug")
                                    .font(.system(size: 10.5, weight: .medium))
                                Text(l10n.tr("report.turnCard.report"))
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(tokens.secondaryForeground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tokens.surface2))
                            .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                    if allowRetry, let onRetryTurn {
                        Button(action: onRetryTurn) {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10.5, weight: .semibold))
                                Text(l10n.tr("thread.retryTurn"))
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(tokens.hoverWash))
                            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .prismSurface(elevation: .flat, cornerRadius: tokens.rSM)
        .overlay(
            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                .strokeBorder(severity == "error" ? tokens.danger.opacity(0.35) : tokens.borderEtched, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func userRefsStrip(_ refs: [ContentRef]) -> some View {
        let imageRefs = refs.filter { ref in
            switch ref {
            case .imageData, .imageBlob: return true
            case .attachment(let att): return att.type == "image"
            default: return false
            }
        }
        let otherRefs = refs.filter { ref in
            switch ref {
            case .imageData, .imageBlob: return false
            case .attachment(let att): return att.type != "image"
            default: return true
            }
        }

        VStack(alignment: .trailing, spacing: 6) {
            if !imageRefs.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(imageRefs.enumerated()), id: \.offset) { _, ref in
                        userImageRefCard(ref)
                    }
                }
            }

            if !otherRefs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(otherRefs.enumerated()), id: \.offset) { _, ref in
                        userFileRefChip(ref)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func userImageRefCard(_ ref: ContentRef) -> some View {
        switch ref {
        case .attachment(let att):
            let blobData = att.blob.flatMap { loadedBlobs[$0] }
            let thumbData = blobData == nil ? PrismImageDecoder.decodeDataURL(att.thumb) : nil
            let displayData = blobData ?? thumbData
            let imageKey: String? = blobData != nil
                ? att.blob.map { "blob:\($0)" }
                : "attachment-thumb:\(att.id):\(att.thumb?.utf8.count ?? 0)"
            Button {
                openImagePreview(title: att.name, immediateData: displayData, blobHash: att.blob)
            } label: {
                ZStack {
                    if let img = PrismImageDecoder.swiftUIImage(from: displayData, cacheKey: imageKey) {
                        img
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 160)
                    } else {
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(tokens.surface2)
                            .frame(width: 144, height: 96)
                            .overlay(
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 18))
                                        .foregroundStyle(tokens.mutedForeground)
                                    Text(att.name)
                                        .font(.system(size: 10))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                }
                            )
                    }
                }
                .background(tokens.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(tokens.borderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(att.name)
            .task(id: att.blob) {
                if let hash = att.blob, loadedBlobs[hash] == nil, let loader = onLoadBlob {
                    if let data = await loader(hash) {
                        loadedBlobs[hash] = data
                    }
                }
            }

        case .imageData(_, let b64):
            let data = ThreadInlineImageData.shared.decode(b64)
            Button {
                if let data { previewItem = PrismImagePreviewItem(title: "Image", data: data) }
            } label: {
                if let img = PrismImageDecoder.swiftUIImage(from: data) {
                    img
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 160)
                        .background(tokens.codeBackground)
                        .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                                .strokeBorder(tokens.borderStrong, lineWidth: 1)
                        )
                }
            }
            .buttonStyle(.plain)

        case .imageBlob(_, let hash):
            let data = loadedBlobs[hash]
            Button {
                openImagePreview(title: "Image", immediateData: data, blobHash: hash)
            } label: {
                ZStack {
                    if let img = PrismImageDecoder.swiftUIImage(from: data, cacheKey: "blob:\(hash)") {
                        img
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 160)
                    } else {
                        RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                            .fill(tokens.surface2)
                            .frame(width: 144, height: 96)
                            .overlay(PrismTurnDotsView(phase: .thinking, size: 14))
                    }
                }
                .background(tokens.codeBackground)
                .clipShape(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous)
                        .strokeBorder(tokens.borderStrong, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .task(id: hash) {
                if loadedBlobs[hash] == nil, let loader = onLoadBlob {
                    if let loaded = await loader(hash) {
                        loadedBlobs[hash] = loaded
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func userFileRefChip(_ ref: ContentRef) -> some View {
        switch ref {
        case .attachment(let att):
            HStack(spacing: 6) {
                Image(systemName: PrismImageDecoder.symbolName(for: att.name, mimeType: att.mimeType, type: att.type))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tokens.prismCobalt)
                Text(att.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let sizeStr = PrismImageDecoder.formatByteCount(att.size)
                if !sizeStr.isEmpty {
                    Text(sizeStr)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
            .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

        case .link(let uri, let name):
            if let url = URL(string: uri),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link(destination: url) {
                    mediaBadgeChip(icon: "link", title: name, subtitle: url.host)
                }
            } else {
                mediaBadgeChip(icon: "link", title: name, subtitle: nil)
            }

        case .audio(_, let size, let name):
            mediaBadgeChip(icon: "waveform", title: name ?? "Audio", subtitle: PrismImageDecoder.formatByteCount(size))

        case .video(_, let size, let name):
            mediaBadgeChip(icon: "film", title: name ?? "Video", subtitle: PrismImageDecoder.formatByteCount(size))

        case .terminal(_, let name):
            mediaBadgeChip(icon: "terminal", title: name, subtitle: nil)

        case .page(_, let name):
            mediaBadgeChip(icon: "safari", title: name, subtitle: nil)

        case .device(_, let name):
            mediaBadgeChip(icon: "iphone", title: name, subtitle: nil)

        case .unsupported(let label):
            mediaBadgeChip(icon: "doc.questionmark", title: label, subtitle: nil)

        default:
            EmptyView()
        }
    }

    private func mediaBadgeChip(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tokens.prismCobalt)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))
    }

    @ViewBuilder
    private func workRunMiniThumb(_ ref: ContentRef) -> some View {
        switch ref {
        case .imageData(_, let b64):
            let data = ThreadInlineImageData.shared.decode(b64)
            if let img = PrismImageDecoder.swiftUIImage(from: data) {
                Button { openImagePreview(title: "Image", immediateData: data, blobHash: nil) } label: {
                    img.resizable().scaledToFill().frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        case .imageBlob(_, let hash):
            let data = loadedBlobs[hash]
            Button { openImagePreview(title: "Image", immediateData: data, blobHash: hash) } label: {
                ZStack {
                    if let img = PrismImageDecoder.swiftUIImage(from: data, cacheKey: "blob:\(hash)") {
                        img.resizable().scaledToFill()
                    } else {
                        tokens.surface2
                    }
                }
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 0.75))
            }
            .buttonStyle(.plain)
            .task(id: hash) {
                guard loadedBlobs[hash] == nil, let onLoadBlob else { return }
                if let fetched = await onLoadBlob(hash) { loadedBlobs[hash] = fetched }
            }
        case .attachment(let att):
            let decodedThumb = PrismImageDecoder.decodeDataURL(att.thumb)
            let thumbData = decodedThumb ?? (att.blob.flatMap { loadedBlobs[$0] })
            let thumbKey: String? = decodedThumb != nil
                ? "attachment-thumb:\(att.id):\(att.thumb?.utf8.count ?? 0)"
                : att.blob.map { "blob:\($0)" }
            if let img = PrismImageDecoder.swiftUIImage(from: thumbData, cacheKey: thumbKey) {
                Button { openImagePreview(title: att.name, immediateData: thumbData, blobHash: att.blob) } label: {
                    img.resizable().scaledToFill().frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tokens.borderStrong, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
        default:
            EmptyView()
        }
    }

    private func extractShellCommand(from data: ToolEntryData) -> String? {
        guard let raw = data.rawInput?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return data.description ?? data.title
        }
        if raw.hasPrefix("{"),
           let jsonData = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            if let cmd = (obj["command"] ?? obj["CommandLine"] ?? obj["cmd"]) as? String, !cmd.isEmpty {
                return cmd
            }
        }
        return raw
    }

    private func nearestVisibleUserTurnID(viewportTop: CGFloat, items: [ThreadTimelineItem]) -> String? {
        var best: (id: String, y: CGFloat)? = nil
        var top: (id: String, y: CGFloat)? = nil
        for (id, y) in tracker.userTurnYByID {
            if y <= viewportTop + 80, best.map({ y > $0.y }) ?? true {
                best = (id, y)
            }
            if top.map({ y < $0.y }) ?? true {
                top = (id, y)
            }
        }
        return best?.id ?? top?.id ?? items.first?.id
    }

    /// Detects whether the user is actively selecting text inside the thread (not the composer),
    /// so streaming output never yanks selected text away.
    private static func hasActiveThreadTextSelection() -> Bool {
        currentThreadSelectedText() != nil
    }

    private static func currentThreadSelectedText() -> String? {
        #if os(macOS)
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        guard !tv.isEditable else { return nil }
        let range = tv.selectedRange()
        guard range.length > 0 else { return nil }
        let ns = tv.string as NSString
        guard NSMaxRange(range) <= ns.length else { return nil }
        let selected = ns.substring(with: range)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
        #else
        return nil
        #endif
    }

    // MARK: - Shared UI Helpers

    private func diffCountPill(insertions: Int, deletions: Int) -> some View {
        DiffCountStatText(insertions: insertions, deletions: deletions, fontSize: 11)
    }

    private func copyIconButton(id: String, text: String, isCopied: Bool) -> some View {
        Button {
            triggerCopy(id: id, text: text)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                Text(isCopied ? l10n.tr("thread.copied") : l10n.tr("thread.copy"))
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(isCopied ? tokens.success : tokens.mutedForeground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                    .strokeBorder(isCopied ? tokens.success.opacity(0.45) : tokens.borderEtched, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func triggerCopy(id: String, text: String) {
        copyToPasteboard(text)
        withAnimation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion)) {
            _ = copiedIDs.insert(id)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { _ = copiedIDs.remove(id) }
        }
    }

    private func localizedStopReason(_ stopReason: String, durationMs: Double?) -> String {
        switch stopReason {
        case "end_turn":
            let dur = ThreadTimelineBuilder.formatDuration(durationMs ?? 0)
            return l10n.tr("thread.stop.endTurn", dur)
        case "cancelled":
            return l10n.tr("thread.stop.cancelled")
        case "max_tokens":
            return l10n.tr("thread.stop.maxTokens")
        case "refusal":
            return l10n.tr("thread.stop.refusal")
        default:
            let dur = ThreadTimelineBuilder.formatDuration(durationMs ?? 0)
            return "\(stopReason) · \(dur)"
        }
    }

    private func stripOuterFence(_ markdown: String) -> String {
        threadStripOuterFence(markdown)
    }

    private func openImagePreview(title: String, immediateData: Data?, blobHash: String?) {
        if let hash = blobHash, let cached = loadedBlobs[hash] {
            previewItem = PrismImagePreviewItem(title: title, data: cached)
            return
        }
        if let immediateData {
            previewItem = PrismImagePreviewItem(title: title, data: immediateData)
        }
        if let hash = blobHash, let loader = onLoadBlob {
            Task {
                if let full = await loader(hash) {
                    loadedBlobs[hash] = full
                    previewItem = PrismImagePreviewItem(title: title, data: full)
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

private extension ThreadTimelineItem {
    var isUserTurn: Bool {
        if case .user(_, _, _, _, let steered) = self {
            return !steered
        }
        return false
    }
}

/// Single-line CoreText diff stat label (`+N -M`) using SF Pro tabular digits and optically
/// cap-centered `+` / `-` signs (`baselineOffset`) so signs and digits align to the exact pixel.
struct DiffCountStatText: View {
    @Environment(\.prismTokens) private var tokens

    let insertions: Int
    let deletions: Int
    var fontSize: CGFloat = 11
    var showZero: Bool = false

    var body: some View {
        let signOffset = fontSize * 0.072
        var attr = AttributedString()

        if showZero || insertions > 0 {
            var plus = AttributedString("+")
            plus.foregroundColor = tokens.success
            plus.baselineOffset = signOffset
            var num = AttributedString("\(insertions)")
            num.foregroundColor = tokens.success
            attr.append(plus)
            attr.append(num)
        }
        if showZero || deletions > 0 {
            if !attr.characters.isEmpty {
                var sep = AttributedString(" ")
                sep.kern = 2.0
                attr.append(sep)
            }
            var minus = AttributedString("-")
            minus.foregroundColor = tokens.danger
            minus.baselineOffset = signOffset
            var num = AttributedString("\(deletions)")
            num.foregroundColor = tokens.danger
            attr.append(minus)
            attr.append(num)
        }

        return Text(attr)
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
    }
}

/// Scroll and rail positions that change many times a second. They live outside the thread view's
/// own state so that scrolling re-renders only the rail, which reads them, not every row.
/// When the user last scrolled the thread viewport by wheel, trackpad or keyboard. Scroll phases
/// miss a mouse wheel and the keyboard, so on macOS a local event monitor scoped to the thread
/// viewport tells thread input apart from sidebar/drawer scrolling, composer typing, or layout.
@MainActor
private enum ThreadScrollInput {
    private static var lastAt: TimeInterval = 0

    #if os(macOS)
    private final class WeakViewBox {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var viewportBoxes: [WeakViewBox] = []

    static func registerViewport(_ view: NSView) {
        viewportBoxes.removeAll { $0.view == nil || $0.view === view }
        viewportBoxes.append(WeakViewBox(view))
    }

    static func unregisterViewport(_ view: NSView) {
        viewportBoxes.removeAll { $0.view == nil || $0.view === view }
    }

    private static func isPointerInThreadViewport(windowNumber: Int, pointInWindow: NSPoint) -> Bool {
        for box in viewportBoxes {
            guard let host = box.view,
                  let window = host.window,
                  window.windowNumber == windowNumber,
                  !host.isHiddenOrHasHiddenAncestor
            else { continue }
            let local = host.convert(pointInWindow, from: nil)
            if host.bounds.contains(local) {
                return true
            }
        }
        return false
    }

    private static func windowWithThreadViewport(windowNumber: Int) -> NSWindow? {
        for box in viewportBoxes {
            guard let host = box.view,
                  let window = host.window,
                  window.windowNumber == windowNumber,
                  !host.isHiddenOrHasHiddenAncestor
            else { continue }
            return window
        }
        return nil
    }

    private static func isEditableTextFocused(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if let tv = responder as? NSTextView, tv.isEditable {
            return true
        }
        if responder is NSTextField {
            return true
        }
        return false
    }

    private static let monitor: Any? = NSEvent.addLocalMonitorForEvents(
        matching: [.scrollWheel, .keyDown]
    ) { event in
        let isWheel = event.type == .scrollWheel
        let hasVerticalDelta = isWheel && abs(event.scrollingDeltaY) >= 0.01
        let keyCode = isWheel ? -1 : Int(event.keyCode)
        let windowNumber = event.windowNumber
        let locationInWindow = event.locationInWindow
        // Local monitors run on the main thread.
        MainActor.assumeIsolated {
            if isWheel {
                if hasVerticalDelta
                    && isPointerInThreadViewport(windowNumber: windowNumber, pointInWindow: locationInWindow) {
                    lastAt = ProcessInfo.processInfo.systemUptime
                }
            } else if scrollKeys.contains(keyCode),
                      let window = windowWithThreadViewport(windowNumber: windowNumber),
                      !isEditableTextFocused(in: window) {
                lastAt = ProcessInfo.processInfo.systemUptime
            }
        }
        return event
    }

    /// Page Up, Page Down, Home, End, the up and down arrows and Space.
    private static let scrollKeys: Set<Int> = [116, 121, 115, 119, 126, 125, 49]
    #endif

    /// Starts watching input; the thread calls it when it appears.
    static func start() {
        #if os(macOS)
        _ = monitor
        #endif
    }

    static func clearRecent() {
        lastAt = 0
    }

    static var isRecent: Bool {
        ProcessInfo.processInfo.systemUptime - lastAt < 0.5
    }
}

#if os(macOS)
/// Transparent NSView attached to the thread ScrollView background so ThreadScrollInput only counts
/// scroll-wheel events whose pointer falls inside the thread viewport.
private struct ThreadScrollViewportProbe: NSViewRepresentable {
    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                ThreadScrollInput.registerViewport(self)
            } else {
                ThreadScrollInput.unregisterViewport(self)
            }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView(frame: .zero)
        v.isHidden = false
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        if nsView.window != nil {
            ThreadScrollInput.registerViewport(nsView)
        }
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        ThreadScrollInput.unregisterViewport(nsView)
    }
}
#endif

@Observable
private final class ThreadScrollTracker {
    var viewportTop: CGFloat = 0
    var wakeToken: Int = 0
    var userTurnYByID: [String: CGFloat] = [:]
    var mountedUserTurnIDs: Set<String> = []
    var pendingNavIndex: Int? = nil
    var isUserScrolling = false
    @ObservationIgnored var pendingNavTask: Task<Void, Never>? = nil

    func reset() {
        isUserScrolling = false
        userTurnYByID = [:]
        mountedUserTurnIDs.removeAll()
        pendingNavIndex = nil
        pendingNavTask?.cancel()
        pendingNavTask = nil
    }
}

/// Reports quantized content-space minY ONLY for non-steered user turns, avoiding per-pixel scroll churn.
private struct UserTurnPositionReporter: ViewModifier {
    let isUserTurn: Bool
    let itemID: String
    let tracker: ThreadScrollTracker

    func body(content: Content) -> some View {
        if isUserTurn {
            content
                .onAppear { tracker.mountedUserTurnIDs.insert(itemID) }
                .onDisappear { tracker.mountedUserTurnIDs.remove(itemID) }
                .onGeometryChange(for: Int.self) { proxy in
                    Int((proxy.frame(in: .named("thread-scroll-content")).minY / 4.0).rounded()) * 4
                } action: { _, quantizedY in
                    let y = CGFloat(quantizedY)
                    if tracker.userTurnYByID[itemID] != y {
                        tracker.userTurnYByID[itemID] = y
                    }
                }
        } else {
            content
        }
    }
}

/// Tracks hover for one piece of content, so hovering re-renders only that content.
private struct HoverTracking<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { inside in
                if isHovered != inside {
                    isHovered = inside
                }
            }
    }
}

/// Base64 image payloads decoded once. The cache keeps each source string, so a hit is confirmed by
/// a pointer comparison while the entry keeps its storage.
private final class ThreadInlineImageData: @unchecked Sendable {
    static let shared = ThreadInlineImageData()

    private final class Entry {
        let source: String
        let data: Data?

        init(source: String, data: Data?) {
            self.source = source
            self.data = data
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 256
    }

    func decode(_ base64: String) -> Data? {
        let key = Self.key(for: base64) as NSString
        if let hit = cache.object(forKey: key), hit.source == base64 {
            return hit.data
        }
        let data = Data(base64Encoded: base64)
        cache.setObject(Entry(source: base64, data: data), forKey: key, cost: data?.count ?? 64)
        return data
    }

    private static func key(for base64: String) -> String {
        let utf8 = base64.utf8
        var hasher = Hasher()
        for byte in utf8.prefix(96) { hasher.combine(byte) }
        for byte in utf8.suffix(96) { hasher.combine(byte) }
        return "\(utf8.count):\(hasher.finalize())"
    }
}

#if os(macOS)
/// Hosts the timeline rail and works out its active turn from the scroll tracker, so the thread
/// view itself never reads the scroll position while the user scrolls.
private struct ThreadNavRailHost: View {
    let tracker: ThreadScrollTracker
    let entries: [ThreadTimelineNavEntry]
    let isFollowingBottom: Bool
    let stageSize: CGSize
    let contentMaxWidth: CGFloat
    let onJump: (Int, ThreadTimelineNavEntry) -> Void

    var body: some View {
        let activeIndex = activeEntryIndex()
        SessionTimelineRailView(
            entries: entries,
            activeIndex: activeIndex,
            pendingIndex: tracker.pendingNavIndex,
            stageWidth: stageSize.width,
            stageHeight: stageSize.height,
            contentMaxWidth: contentMaxWidth,
            scrollWakeToken: tracker.wakeToken,
            onJump: onJump
        )
        .onChange(of: activeIndex) { _, newActive in
            if let pending = tracker.pendingNavIndex, pending == newActive {
                tracker.pendingNavIndex = nil
                tracker.pendingNavTask?.cancel()
            }
        }
    }

    /// The last user prompt at or above the viewport top + 40pt. Mounted LazyVStack rows win, so
    /// stale coordinates of recycled rows never hijack the marker.
    private func activeEntryIndex() -> Int {
        guard !entries.isEmpty else { return 0 }
        if isFollowingBottom && !tracker.isUserScrolling {
            return entries.count - 1
        }

        let anchorY = tracker.viewportTop + 40
        let positions = tracker.userTurnYByID
        let mounted = tracker.mountedUserTurnIDs

        var lastMountedAtOrAboveAnchor: Int?
        var firstMountedBelowAnchor: Int?
        var lastAnyAtOrAboveAnchor: Int?
        var firstAnyMeasured: Int?

        for (idx, entry) in entries.enumerated() {
            guard let y = positions[entry.scrollItemID] else { continue }
            let isMounted = mounted.contains(entry.scrollItemID)
            if firstAnyMeasured == nil {
                firstAnyMeasured = idx
            }
            if y <= anchorY {
                lastAnyAtOrAboveAnchor = idx
                if isMounted {
                    lastMountedAtOrAboveAnchor = idx
                }
            } else if isMounted && firstMountedBelowAnchor == nil {
                firstMountedBelowAnchor = idx
            }
        }

        if let hit = lastMountedAtOrAboveAnchor { return hit }
        if let below = firstMountedBelowAnchor { return max(0, below - 1) }
        if let any = lastAnyAtOrAboveAnchor { return any }
        if let first = firstAnyMeasured { return first }
        return isFollowingBottom ? entries.count - 1 : 0
    }
}
#endif

#if os(macOS)
/// Left-edge conversation timeline rail inspired by makecindy/cindy's MessageNavRail (Apache-2.0,
/// https://github.com/makecindy/cindy). Renders compact tick marks in the left gutter that bloom
/// into a continuous Gaussian Dock-wave with vertical fisheye lens spread on hover/drag-scrub,
/// tactile haptic detents, and a spring-gliding glass preview card aligned to the focused tick.
/// Single-layer Animatable Canvas renderer for the left-edge Dock wave timeline rail.
/// Draws all ticks deterministically in one pass with true circular capsule endcaps and
/// only 2 animated scalar floats (anchorY, engagement), preventing per-tick CALayer/shadow
/// animation glitches and minimizing GPU/CPU overhead at 60/120Hz.
private struct SessionTimelineWaveCanvas: View, @preconcurrency Animatable {
    let tickCount: Int
    let hiddenEarlierCount: Int
    let effectiveActive: Int
    let focusedLocalIndex: Int?
    let pitch: CGFloat
    let waveSigma: CGFloat
    let spreadAmp: CGFloat
    let spreadSigma: CGFloat
    let verticalPad: CGFloat
    let canvasPadX: CGFloat
    let restTickWidth: CGFloat
    let engagedBaseWidth: CGFloat
    let activeTickWidth: CGFloat
    let maxTickWidth: CGFloat
    let restTickHeight: CGFloat
    let activeTickHeight: CGFloat
    let maxTickHeight: CGFloat
    let maxXNudge: CGFloat
    let motionDisabled: Bool
    let tokens: PrismTokens

    var anchorY: CGFloat
    var engagement: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(anchorY, engagement) }
        set {
            anchorY = newValue.first
            engagement = newValue.second
        }
    }

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, _ in
            guard tickCount > 0 else { return }
            let trackHeight = CGFloat(tickCount) * pitch
            let eng = max(0, min(1, engagement))

            // Subtle vertical frosted aura behind the active wave so ticks pop over ASCII/Nebula
            if eng > 0.01 {
                let clampedAnchor = max(0, min(trackHeight, anchorY))
                let auraHeight = min(trackHeight + 64, 152)
                let auraRect = CGRect(
                    x: max(0, canvasPadX - 8),
                    y: verticalPad + clampedAnchor - auraHeight / 2,
                    width: maxTickWidth + 24,
                    height: auraHeight
                )
                let auraPath = Path(roundedRect: auraRect, cornerRadius: 14, style: .continuous)
                let peakAlpha = (tokens.palette.isDark ? 0.58 : 0.68) * Double(eng)
                let gradient = Gradient(colors: [
                    tokens.background.opacity(0),
                    tokens.background.opacity(peakAlpha),
                    tokens.background.opacity(0),
                ])
                context.fill(
                    auraPath,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: auraRect.midX, y: auraRect.minY),
                        endPoint: CGPoint(x: auraRect.midX, y: auraRect.maxY)
                    )
                )
            }

            struct HighlightTick {
                let path: Path
                let fill: Color
                let glow: Color
                let glowRadius: CGFloat
            }
            var highlights: [HighlightTick] = []
            highlights.reserveCapacity(2)

            for localIdx in 0..<tickCount {
                let origIdx = hiddenEarlierCount + localIdx
                let isActive = origIdx == effectiveActive
                let isFocused = eng > 0.25 && focusedLocalIndex == localIdx
                let restCenterY = (CGFloat(localIdx) + 0.5) * pitch
                let d = restCenterY - anchorY

                let influence: CGFloat = eng > 0.001
                    ? exp(-(d * d) / (2 * waveSigma * waveSigma))
                    : 0
                let wave = influence * eng

                let shift: CGFloat = motionDisabled || eng <= 0.001
                    ? 0
                    : eng * spreadAmp * CGFloat(tanh(Double(d / spreadSigma)))
                let visualCenterY = verticalPad + restCenterY + shift

                let baseW: CGFloat = isActive
                    ? activeTickWidth
                    : (restTickWidth + (engagedBaseWidth - restTickWidth) * eng)
                let w = baseW + (maxTickWidth - baseW) * wave

                let baseH: CGFloat = isActive ? activeTickHeight : restTickHeight
                let h = baseH + (maxTickHeight - baseH) * pow(wave, 1.25)

                let x = canvasPadX + (motionDisabled ? 0 : maxXNudge * wave)
                let rect = CGRect(x: x, y: visualCenterY - h / 2, width: w, height: h)
                let pill = Path(roundedRect: rect, cornerRadius: h / 2, style: .continuous)

                if isActive {
                    let activeColor: Color = (tokens.accentMode == .mono && eng > 0.1 && !isFocused)
                        ? tokens.primary.opacity(0.68)
                        : tokens.primary
                    let glowColor = tokens.primary.opacity(0.44 + 0.24 * Double(wave))
                    highlights.append(HighlightTick(
                        path: pill,
                        fill: activeColor,
                        glow: glowColor,
                        glowRadius: isFocused ? 7.0 : 4.0
                    ))
                } else if isFocused {
                    highlights.append(HighlightTick(
                        path: pill,
                        fill: tokens.foreground,
                        glow: tokens.prismCobalt.opacity(0.42 * Double(eng)),
                        glowRadius: 7.0
                    ))
                } else {
                    let alpha = 0.30 + 0.70 * pow(max(0.0, min(1.0, Double(wave))), 0.85)
                    context.fill(pill, with: .color(tokens.foreground.opacity(alpha)))
                }
            }

            // Draw active & focused ticks on top with crisp soft glow
            for item in highlights {
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: item.glow, radius: item.glowRadius, x: 0, y: 0))
                    layer.fill(item.path, with: .color(item.fill))
                }
            }
        }
    }
}

private struct SessionTimelineRailView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.prismTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entries: [ThreadTimelineNavEntry]
    let activeIndex: Int
    let pendingIndex: Int?
    let stageWidth: CGFloat
    let stageHeight: CGFloat
    let contentMaxWidth: CGFloat
    let scrollWakeToken: Int
    let onJump: (Int, ThreadTimelineNavEntry) -> Void

    @State private var isAwake = false
    @State private var isRailHovered = false
    @State private var isEngaged = false
    @State private var animAnchorY: CGFloat = 0
    @State private var animEngagement: CGFloat = 0
    @State private var hoveredLocalIndex: Int? = nil
    @State private var draggedLocalIndex: Int? = nil
    @State private var previewCardHeight: CGFloat = 27
    @State private var idleTask: Task<Void, Never>? = nil
    @State private var foldTask: Task<Void, Never>? = nil

    private enum Spec {
        static let minEntries = 2
        static let horizontalPadding: CGFloat = 24
        static let minGutterWidth: CGFloat = 32
        static let topInset: CGFloat = 44
        static let bottomInset: CGFloat = 56
        static let minAvailHeight: CGFloat = 36
        static let standardPitch: CGFloat = 10
        static let minPitch: CGFloat = 5
        static let maxTickWidth: CGFloat = 50
        static let maxTickHeight: CGFloat = 5.0
        static let restTickWidth: CGFloat = 10
        static let activeTickWidth: CGFloat = 20
        static let engagedBaseWidth: CGFloat = 12
        static let restTickHeight: CGFloat = 2.2
        static let activeTickHeight: CGFloat = 3.0
        static let maxXNudge: CGFloat = 5.5
        static let canvasPadX: CGFloat = 10
        static let canvasPadRight: CGFloat = 18
        static let verticalHitPad: CGFloat = 38
        static let earlierMarkerHeight: CGFloat = 20
        static let idleHideSeconds: Double = 2.2
        static let foldGraceMs: UInt64 = 150
        static let idleOpacity: Double = 0.54
        static let previewMaxWidth: CGFloat = 216
    }

    private struct RailPlan {
        let visibleEntries: [ThreadTimelineNavEntry]
        let hiddenEarlierCount: Int
        let pitch: CGFloat
        let leadingPad: CGFloat
        let railTopY: CGFloat
        let markerHeight: CGFloat

        var trackHeight: CGFloat {
            CGFloat(visibleEntries.count) * pitch
        }

        /// Vertical fisheye lens amplitude: automatically expands dense 5pt threads to ~13pt local spacing
        /// and 10pt threads to ~18.5pt local spacing right under the pointer.
        var spreadAmp: CGFloat {
            let densityFactor = max(0, min(1, (11.5 - pitch) / 6.5))
            return 22.0 + densityFactor * 16.0
        }

        var spreadSigma: CGFloat {
            max(22.0, pitch * 2.9)
        }

        var waveSigma: CGFloat {
            max(19.0, pitch * 2.35)
        }
    }

    private var motionDisabled: Bool {
        reduceMotion || motionTier == .off
    }

    private var plan: RailPlan? {
        guard entries.count >= Spec.minEntries else { return nil }
        let actualLeftGutter: CGFloat = stageWidth > (contentMaxWidth + Spec.horizontalPadding * 2)
            ? (stageWidth - contentMaxWidth) / 2
            : Spec.horizontalPadding
        let availHeight = max(0, stageHeight - Spec.topInset - Spec.bottomInset)
        guard actualLeftGutter >= Spec.minGutterWidth, availHeight >= Spec.minAvailHeight else {
            return nil
        }

        let total = entries.count
        let pitch: CGFloat
        let hiddenEarlier: Int
        let slice: [ThreadTimelineNavEntry]

        if CGFloat(total) * Spec.standardPitch <= availHeight {
            pitch = Spec.standardPitch
            hiddenEarlier = 0
            slice = entries
        } else {
            let compressed = availHeight / CGFloat(total)
            if compressed >= Spec.minPitch {
                pitch = compressed
                hiddenEarlier = 0
                slice = entries
            } else {
                let budget = max(Spec.minPitch, availHeight - Spec.earlierMarkerHeight)
                let maxVisible = max(1, Int(floor(budget / Spec.minPitch)))
                hiddenEarlier = max(0, total - maxVisible)
                pitch = Spec.minPitch
                slice = Array(entries.suffix(maxVisible))
            }
        }

        let markerH: CGFloat = hiddenEarlier > 0 ? Spec.earlierMarkerHeight : 0
        let totalRailH = markerH + CGFloat(slice.count) * pitch
        let railTop = Spec.topInset + max(0, (availHeight - totalRailH) * 0.45)
        let leading = min(18, max(8, (actualLeftGutter - Spec.activeTickWidth) * 0.24))

        return RailPlan(
            visibleEntries: slice,
            hiddenEarlierCount: hiddenEarlier,
            pitch: pitch,
            leadingPad: leading,
            railTopY: railTop,
            markerHeight: markerH
        )
    }

    var body: some View {
        if let plan {
            let focusLocalIdx = draggedLocalIndex ?? hoveredLocalIndex
            let effectiveActive = pendingIndex ?? activeIndex
            let isInteracting = isRailHovered || isEngaged || focusLocalIdx != nil
            let railOpacity = (isAwake || isInteracting) ? 1.0 : Spec.idleOpacity
            let ticksOriginY = plan.railTopY + plan.markerHeight
            let canvasWidth = Spec.canvasPadX + Spec.maxTickWidth + Spec.maxXNudge + Spec.canvasPadRight
            let canvasHeight = plan.trackHeight + Spec.verticalHitPad * 2

            ZStack(alignment: .topLeading) {
                // Earlier-turns overflow jump badge (+N)
                if plan.hiddenEarlierCount > 0, let earliest = entries.first {
                    let topShift = motionDisabled ? 0 : fisheyeShift(
                        restY: 0,
                        anchorY: animAnchorY,
                        engagement: isEngaged ? 1.0 : 0.0,
                        plan: plan
                    )
                    Button {
                        onJump(0, earliest)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 8.5, weight: .semibold))
                            Text("+\(plan.hiddenEarlierCount)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                        }
                        .foregroundStyle(isEngaged ? tokens.secondaryForeground : tokens.placeholder)
                        .frame(height: plan.markerHeight, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .help(l10n.tr("navRail.earlierCount", plan.hiddenEarlierCount))
                    .offset(x: plan.leadingPad, y: max(8, plan.railTopY + topShift - 4))
                    .animation(
                        motionDisabled ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.84),
                        value: animAnchorY
                    )
                    .animation(
                        motionDisabled ? nil : .spring(response: 0.26, dampingFraction: 0.78),
                        value: isEngaged
                    )
                    .opacity(railOpacity)
                }

                // Single-layer Animatable Canvas Dock Wave Tick Track
                SessionTimelineWaveCanvas(
                    tickCount: plan.visibleEntries.count,
                    hiddenEarlierCount: plan.hiddenEarlierCount,
                    effectiveActive: effectiveActive,
                    focusedLocalIndex: focusLocalIdx,
                    pitch: plan.pitch,
                    waveSigma: plan.waveSigma,
                    spreadAmp: plan.spreadAmp,
                    spreadSigma: plan.spreadSigma,
                    verticalPad: Spec.verticalHitPad,
                    canvasPadX: Spec.canvasPadX,
                    restTickWidth: Spec.restTickWidth,
                    engagedBaseWidth: Spec.engagedBaseWidth,
                    activeTickWidth: Spec.activeTickWidth,
                    maxTickWidth: Spec.maxTickWidth,
                    restTickHeight: Spec.restTickHeight,
                    activeTickHeight: Spec.activeTickHeight,
                    maxTickHeight: Spec.maxTickHeight,
                    maxXNudge: Spec.maxXNudge,
                    motionDisabled: motionDisabled,
                    tokens: tokens,
                    anchorY: animAnchorY,
                    engagement: animEngagement
                )
                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        let trackY = max(0, min(plan.trackHeight, location.y - Spec.verticalHitPad))
                        cancelFold()
                        let wasEngaged = isEngaged
                        if !isRailHovered { isRailHovered = true }
                        if !wasEngaged {
                            animAnchorY = trackY
                            isEngaged = true
                            withAnimation(motionDisabled ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
                                animEngagement = 1.0
                            }
                        } else {
                            withAnimation(motionDisabled ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.84)) {
                                animAnchorY = trackY
                            }
                        }
                        let idx = clampedIndex(forY: trackY, count: plan.visibleEntries.count, pitch: plan.pitch)
                        if hoveredLocalIndex != idx {
                            hoveredLocalIndex = idx
                        }
                    case .ended:
                        isRailHovered = false
                        if draggedLocalIndex == nil {
                            scheduleFold()
                        }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let trackY = max(0, min(plan.trackHeight, value.location.y - Spec.verticalHitPad))
                            cancelFold()
                            let wasEngaged = isEngaged
                            if !wasEngaged {
                                animAnchorY = trackY
                                isEngaged = true
                                withAnimation(motionDisabled ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
                                    animEngagement = 1.0
                                }
                            } else {
                                withAnimation(motionDisabled ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.84)) {
                                    animAnchorY = trackY
                                }
                            }
                            let idx = clampedIndex(forY: trackY, count: plan.visibleEntries.count, pitch: plan.pitch)
                            if draggedLocalIndex != idx {
                                draggedLocalIndex = idx
                                hoveredLocalIndex = idx
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                let entry = plan.visibleEntries[idx]
                                onJump(plan.hiddenEarlierCount + idx, entry)
                            }
                        }
                        .onEnded { value in
                            let trackY = max(0, min(plan.trackHeight, value.location.y - Spec.verticalHitPad))
                            let idx = clampedIndex(forY: trackY, count: plan.visibleEntries.count, pitch: plan.pitch)
                            let entry = plan.visibleEntries[idx]
                            onJump(plan.hiddenEarlierCount + idx, entry)
                            draggedLocalIndex = nil
                            if !isRailHovered {
                                scheduleFold()
                            } else {
                                wakeBriefly()
                            }
                        }
                )
                .opacity(railOpacity)
                .animation(motionDisabled ? nil : .easeOut(duration: 0.22), value: railOpacity)
                .offset(x: plan.leadingPad - Spec.canvasPadX, y: ticksOriginY - Spec.verticalHitPad)

                // Compact hug-content floating pill aligned to the focused bar
                if isEngaged, let focusIdx = focusLocalIdx, plan.visibleEntries.indices.contains(focusIdx) {
                    let entry = plan.visibleEntries[focusIdx]
                    let isTargetActive = (plan.hiddenEarlierCount + focusIdx) == effectiveActive
                    let restFocusY = (CGFloat(focusIdx) + 0.5) * plan.pitch
                    let visualFocusY = ticksOriginY + restFocusY + (
                        motionDisabled ? 0 : fisheyeShift(
                            restY: restFocusY,
                            anchorY: animAnchorY,
                            engagement: 1.0,
                            plan: plan
                        )
                    )
                    let cardX = plan.leadingPad + Spec.maxTickWidth + Spec.maxXNudge + 10
                    let maxCardWidth = min(Spec.previewMaxWidth, max(120, stageWidth - cardX - 20))
                    let cardTopY = min(
                        max(12, visualFocusY - previewCardHeight / 2),
                        max(12, stageHeight - previewCardHeight - 12)
                    )

                    navPreviewCard(
                        entry: entry,
                        isActive: isTargetActive,
                        maxWidth: maxCardWidth
                    )
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { _, h in
                        if abs(previewCardHeight - h) > 0.5 {
                            previewCardHeight = h
                        }
                    }
                    .offset(x: cardX, y: cardTopY)
                    .animation(
                        motionDisabled ? nil : .interactiveSpring(response: 0.14, dampingFraction: 0.84),
                        value: cardTopY
                    )
                    .allowsHitTesting(false)
                    .transition(
                        .asymmetric(
                            insertion: .opacity
                                .combined(with: .scale(scale: 0.96, anchor: .leading))
                                .combined(with: .offset(x: -5)),
                            removal: .opacity
                                .combined(with: .scale(scale: 0.97, anchor: .leading))
                                .combined(with: .offset(x: -4))
                        )
                    )
                }
            }
            .animation(
                motionDisabled ? nil : .spring(response: 0.24, dampingFraction: 0.82),
                value: isEngaged
            )
            .onChange(of: scrollWakeToken) { _, _ in
                wakeBriefly()
            }
            .onDisappear {
                idleTask?.cancel()
                foldTask?.cancel()
            }
        }
    }

    private func fisheyeShift(
        restY: CGFloat,
        anchorY: CGFloat,
        engagement: CGFloat,
        plan: RailPlan
    ) -> CGFloat {
        guard engagement > 0 else { return 0 }
        let d = restY - anchorY
        return engagement * plan.spreadAmp * CGFloat(tanh(Double(d / plan.spreadSigma)))
    }

    private func navPreviewCard(
        entry: ThreadTimelineNavEntry,
        isActive: Bool,
        maxWidth: CGFloat
    ) -> some View {
        let rawPrompt: String = {
            if !entry.promptPreview.isEmpty {
                return entry.promptPreview
            }
            return l10n.tr("navRail.attachmentsOnly", max(1, entry.attachmentCount))
        }()
        let compactPrompt = rawPrompt
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shape = RoundedRectangle(cornerRadius: 7.5, style: .continuous)

        return HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 4) {
                if isActive {
                    Circle()
                        .fill(tokens.primary)
                        .frame(width: 4.5, height: 4.5)
                }
                Text("#\(entry.turnNumber)")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? tokens.primary : tokens.mutedForeground)
            }
            .layoutPriority(1)

            Rectangle()
                .fill(tokens.border)
                .frame(width: 1, height: 10)
                .layoutPriority(1)

            Text(compactPrompt)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(tokens.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 9.5)
        .padding(.vertical, 5)
        .background(
            ZStack {
                shape.fill(tokens.popoverBackground)
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(tokens.palette.isDark ? 0.045 : 0.65),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        )
        .overlay(
            shape.strokeBorder(
                isActive ? tokens.primaryBorder : tokens.border,
                lineWidth: 0.75
            )
        )
        .shadow(
            color: Color.black.opacity(tokens.palette.isDark ? 0.36 : 0.11),
            radius: 8,
            x: 0,
            y: 3
        )
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    private func clampedIndex(forY y: CGFloat, count: Int, pitch: CGFloat) -> Int {
        guard count > 0, pitch > 0 else { return 0 }
        let raw = Int(floor(y / pitch))
        return max(0, min(count - 1, raw))
    }

    private func cancelFold() {
        foldTask?.cancel()
        foldTask = nil
    }

    private func scheduleFold() {
        foldTask?.cancel()
        foldTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Spec.foldGraceMs * 1_000_000)
            guard !Task.isCancelled else { return }
            if !isRailHovered && draggedLocalIndex == nil {
                isEngaged = false
                hoveredLocalIndex = nil
                withAnimation(motionDisabled ? nil : .spring(response: 0.28, dampingFraction: 0.80)) {
                    animEngagement = 0.0
                }
                wakeBriefly()
            }
        }
    }

    private func wakeBriefly() {
        idleTask?.cancel()
        if !isAwake {
            isAwake = true
        }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Spec.idleHideSeconds))
            guard !Task.isCancelled else { return }
            if !isRailHovered && !isEngaged && draggedLocalIndex == nil {
                isAwake = false
            }
        }
    }
}
#endif

// MARK: - Per-Session Reading Position Store (mirrors src/renderer/src/features/session/reading-position.ts)

@MainActor
private final class SessionReadingPositionStore {
    struct SavedPosition {
        let anchorItemID: String?
        let followingBottom: Bool
    }

    static let shared = SessionReadingPositionStore()
    private var positions: [String: SavedPosition] = [:]

    func save(sessionId: String, anchorItemID: String?, followingBottom: Bool) {
        if positions.count >= 64 && positions[sessionId] == nil {
            positions.removeAll(keepingCapacity: true)
        }
        positions[sessionId] = SavedPosition(anchorItemID: anchorItemID, followingBottom: followingBottom)
    }

    func load(sessionId: String) -> SavedPosition? {
        positions[sessionId]
    }
}
