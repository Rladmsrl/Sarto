import CryptoKit
import Foundation
import SartoProtocol
import Observation
import PrismDesign
import Security
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

public struct FocusedAttentionNotice: Equatable, Sendable, Identifiable {
    public enum Kind: String, Equatable, Sendable {
        case turnEnded
        case permission
        case error
    }

    public let id: UUID
    public let hostId: String
    public let sessionId: String
    public let title: String
    public let kind: Kind
    public let extraCount: Int

    public init(
        id: UUID = UUID(),
        hostId: String,
        sessionId: String,
        title: String,
        kind: Kind,
        extraCount: Int = 0
    ) {
        self.id = id
        self.hostId = hostId
        self.sessionId = sessionId
        self.title = title
        self.kind = kind
        self.extraCount = extraCount
    }
}

public enum ConnectionMode: Sendable, Equatable {
    case disconnected
    case localDaemon(socketPath: String)
    case remoteHost(name: String, viaRelay: Bool)

    public var isLive: Bool {
        if case .disconnected = self { return false }
        return true
    }

    public var isRemote: Bool {
        if case .remoteHost = self { return true }
        return false
    }

    public var isRemoteDirect: Bool {
        if case .remoteHost(_, let viaRelay) = self { return !viaRelay }
        return false
    }

    public var isRemoteRelay: Bool {
        if case .remoteHost(_, let viaRelay) = self { return viaRelay }
        return false
    }

    public var badgeLabel: String {
        switch self {
        case .disconnected: return "Offline"
        case .localDaemon: return "Daemon Live"
        case .remoteHost(let name, let viaRelay):
            return viaRelay ? "\(name) · Relay" : "\(name) · Direct"
        }
    }
}

/// macOS: other hosts through the local daemon, which dials, pairs and keeps them
/// (docs/sarto-remote-design.md). The Mac app fills it from `LocalDaemonManager`.
public struct DaemonOtherHosts {
    /// This app's sessions with a host, by its id: its agent host's and its terminal's.
    public var open: (String) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession)
    /// Forgets a host.
    public var remove: (String) async throws -> Void

    public init(
        open: @escaping (String) async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession),
        remove: @escaping (String) async throws -> Void
    ) {
        self.open = open
        self.remove = remove
    }
}

public enum RelayProbeStatus: Sendable, Equatable {
    case idle
    case checking
    case online(regionCount: Int, features: [String])
    case failed(String)
}

/// Shared observable state machine for Sarto clients.
/// Backed 100% by real SartoHostSession RPCs, streaming ThreadReplicas, real `usage.summary`,
/// and real `agents.refreshLimits` — zero mock metrics.
@MainActor
@Observable
public final class SartoState {
    // MARK: - Appearance, Language, Typography & Client Preferences (Persisted)
    private enum PrefKey {
        static let palette = "dev.sarto.pref.palette"
        static let darkPalette = "dev.sarto.pref.darkPalette"
        static let lightPalette = "dev.sarto.pref.lightPalette"
        static let colorMode = "dev.sarto.pref.colorMode"
        static let accentMode = "dev.sarto.pref.accentMode"
        static let appIconStyle = "dev.sarto.pref.appIconStyle"
        static let motionTier = "dev.sarto.pref.motionTier"
        static let sendKeyMode = "dev.sarto.pref.sendKeyMode"
        static let defaultAgentID = "dev.sarto.pref.defaultAgentID"
        static let restoreLastSession = "dev.sarto.pref.restoreLastSession"
        static let lastSelectedSessionID = "dev.sarto.pref.lastSelectedSessionID"
        static let textSize = "dev.sarto.pref.textSize"
        static let uiFontFamily = "dev.sarto.pref.uiFontFamily"
        static let proseFontFamily = "dev.sarto.pref.proseFontFamily"
        static let codeFontFamily = "dev.sarto.pref.codeFontFamily"
        static let terminalFontSize = "dev.sarto.pref.terminalFontSize"
        static let terminalFontFamily = "dev.sarto.pref.terminalFontFamily"
        static let hiddenHostIDs = "dev.sarto.pref.hiddenHostIDs"
        static let notifications = "dev.sarto.pref.notifications"
        static let relayOrigin = "dev.sarto.pref.relayOrigin"
        static let relayBearerToken = "dev.sarto.pref.relayBearerToken"
        static let uiTimestamps = "dev.sarto.pref.uiTimestamps"
        static let syncedHostIDs = "dev.sarto.pref.syncedHostIDs"
        static let threadWideWidth = "prism.threadWideWidth"
        static let rememberedModeByAgentModel = "dev.sarto.pref.rememberedModeByAgentModel"
        static let rememberedModeByAgent = "dev.sarto.pref.rememberedModeByAgent"
    }

    public var language: PrismLanguage = PrismLanguage.loadSaved() {
        didSet {
            language.save()
            markUiPrefMutated("language")
        }
    }
    public var darkPalette: PrismPalette = .obsidian {
        didSet {
            UserDefaults.standard.set(darkPalette.rawValue, forKey: PrefKey.darkPalette)
            markUiPrefMutated("darkPalette")
        }
    }
    public var lightPalette: PrismPalette = .crystal {
        didSet {
            UserDefaults.standard.set(lightPalette.rawValue, forKey: PrefKey.lightPalette)
            markUiPrefMutated("lightPalette")
        }
    }
    public var colorMode: PrismColorMode = .dark {
        didSet {
            UserDefaults.standard.set(colorMode.rawValue, forKey: PrefKey.colorMode)
            syncPaletteForColorMode()
            markUiPrefMutated("colorMode")
        }
    }
    public var palette: PrismPalette = .obsidian {
        didSet {
            UserDefaults.standard.set(palette.rawValue, forKey: PrefKey.palette)
            if palette.isDark {
                if darkPalette != palette { darkPalette = palette }
            } else {
                if lightPalette != palette { lightPalette = palette }
            }
            markUiPrefMutated("palette")
            if !isInitializingPrefs && !isBatchUpdatingPalette && palette != oldValue {
                onEffectivePaletteChanged?(palette)
            }
        }
    }
    public var accentMode: PrismAccentMode = .model {
        didSet {
            UserDefaults.standard.set(accentMode.rawValue, forKey: PrefKey.accentMode)
            markUiPrefMutated("accentMode")
        }
    }
    public var appIconStyle: PrismAppIconStyle = .defaultStyle {
        didSet {
            UserDefaults.standard.set(appIconStyle.rawValue, forKey: PrefKey.appIconStyle)
            markUiPrefMutated("appIconStyle")
        }
    }
    public var motionTier: PrismMotionTier = .ultra {
        didSet {
            UserDefaults.standard.set(motionTier.rawValue, forKey: PrefKey.motionTier)
            markUiPrefMutated("motionTier")
        }
    }
    public var effortLevel: ReasoningEffortLevel = .high
    public var effortSliderStyle: EffortSliderStyle = .starfield
    public var sendKeyMode: PrismSendKeyMode = .enter {
        didSet {
            UserDefaults.standard.set(sendKeyMode.rawValue, forKey: PrefKey.sendKeyMode)
            markUiPrefMutated("sendKeyMode")
        }
    }
    public var defaultAgentID: String? = nil {
        didSet {
            UserDefaults.standard.set(defaultAgentID, forKey: PrefKey.defaultAgentID)
            markUiPrefMutated("defaultAgentID")
        }
    }
    public var restoreLastSession: Bool = true {
        didSet {
            UserDefaults.standard.set(restoreLastSession, forKey: PrefKey.restoreLastSession)
            markUiPrefMutated("restoreLastSession")
        }
    }
    public var textSize: PrismTextSize = .standard {
        didSet {
            UserDefaults.standard.set(textSize.rawValue, forKey: PrefKey.textSize)
            markUiPrefMutated("textSize")
        }
    }
    public var uiFontFamily: String = "" {
        didSet {
            UserDefaults.standard.set(uiFontFamily, forKey: PrefKey.uiFontFamily)
            markUiPrefMutated("uiFontFamily")
        }
    }
    public var proseFontFamily: String = "" {
        didSet {
            UserDefaults.standard.set(proseFontFamily, forKey: PrefKey.proseFontFamily)
            markUiPrefMutated("proseFontFamily")
        }
    }
    public var codeFontFamily: String = "" {
        didSet {
            UserDefaults.standard.set(codeFontFamily, forKey: PrefKey.codeFontFamily)
            markUiPrefMutated("codeFontFamily")
        }
    }
    public var terminalFontSize: Int = 12 {
        didSet {
            UserDefaults.standard.set(terminalFontSize, forKey: PrefKey.terminalFontSize)
            markUiPrefMutated("terminalFontSize")
        }
    }
    public var terminalFontFamily: String = "" {
        didSet {
            UserDefaults.standard.set(terminalFontFamily, forKey: PrefKey.terminalFontFamily)
            markUiPrefMutated("terminalFontFamily")
        }
    }
    public var notificationPrefs: PrismNotificationPrefs = PrismNotificationPrefs() {
        didSet {
            if let data = try? JSONEncoder().encode(notificationPrefs) {
                UserDefaults.standard.set(data, forKey: PrefKey.notifications)
            }
            if notificationPrefs.inAppNoticeMode == .off {
                dismissFocusedAttentionNotice()
            }
            markUiPrefMutated("notifications")
        }
    }
    @ObservationIgnored private var isInitializingPrefs: Bool = true
    @ObservationIgnored private var isApplyingSyncedPrefs: Bool = false
    @ObservationIgnored private var isBatchUpdatingPalette: Bool = false
    @ObservationIgnored private var uiTimestamps: [String: Double] = [:]
    @ObservationIgnored private var lastExportedBrowserOrigins: [String: [String]] = [:]
    @ObservationIgnored private var syncedHostIDs: Set<String> = []
    @ObservationIgnored public var onLocalUiPrefsMutated: (() -> Void)? = nil
    @ObservationIgnored public var onEffectivePaletteChanged: ((PrismPalette) -> Void)? = nil
    @ObservationIgnored public var onApplySyncedIslandPrefs: (([String: SartoSyncedUiPrefEntry], inout [String: Double]) -> Void)? = nil
    @ObservationIgnored private var systemAppearanceIsDark: Bool = true
    public struct PendingTerminalCommand: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let command: String
        public let run: Bool
    }

    public var pendingTerminalCommand: PendingTerminalCommand? = nil

    public func requestTerminalCommand(_ command: String, run: Bool = true) {
        pendingTerminalCommand = PendingTerminalCommand(command: command, run: run)
    }

    public var showStudioHome: Bool = true
    public var selectedAgentID: String = "antigravity" {
        didSet {
            // Only Claude Code supports remote model hosts; switching to another agent clears it.
            if selectedAgentID != "claude-code", selectedModelHostID != nil {
                selectedModelHostID = nil
            }
        }
    }

    // Optical feedback pulses & strictly real measured telemetry (nil until observed)
    public var liftoffToken: Int = 0
    public var isStartSurging: Bool = false
    public var currentTPS: Double? = nil
    public var currentTPSIsApprox: Bool = false
    public var currentTTFTMs: Int? = nil
    public var currentCacheHit: Double? = nil
    public var currentSessionCacheHit: Double? = nil
    public var currentCacheMode: PrismCacheTelemetryMode = .session
    public var currentTurnContextDelta: Double? = nil

    // The published `current*` properties mirror this; observing the tracker itself would notify on every batch.
    @ObservationIgnored private var telemetryTracker = LiveSessionTelemetryTracker()

    // MARK: - Connection, Relay & Identity
    public var connectionMode: ConnectionMode = .disconnected
    public var connectionError: String?
    public var statusMessage: String?
    public var isConnecting = false

    public var relayOrigin: String = "" {
        didSet { UserDefaults.standard.set(relayOrigin, forKey: PrefKey.relayOrigin) }
    }
    public var relayBearerToken: String = "" {
        didSet {
            guard !isRestoringRelayToken, relayBearerToken != oldValue else { return }
            relayTokenEditedSinceLaunch = true
            RelayTokenVault.store(relayBearerToken, legacyDefaultsKey: PrefKey.relayBearerToken)
        }
    }
    @ObservationIgnored private var isRestoringRelayToken = false
    @ObservationIgnored private var relayTokenEditedSinceLaunch = false
    @ObservationIgnored private var relayTokenLoadTask: Task<Void, Never>? = nil
    public var relayStatus: RelayProbeStatus = .idle
    public private(set) var relayLatencyMs: Int? = nil
    public private(set) var relayLatencyFailed: Bool = false
    @ObservationIgnored private var relayLatencyTask: Task<Void, Never>? = nil
    public var remoteHosts: [RelayListedHost] = []
    public var pairedHosts: [PairedHostRecord] = []
    public var cloudAccountStatus: CloudAccountStatusInfo = CloudAccountStatusInfo()
    public var sartoSyncStatus: SartoSyncStatusInfo = SartoSyncStatusInfo()
    /// Direct Sarto Cloud sign-in state for clients without a local daemon (iOS).
    public var directCloudProfile: CloudAccountProfile? = nil
    public var pendingDeviceAuth: CloudDeviceAuthStart? = nil
    public var isSigningInDirectCloud: Bool = false
    public var pendingDiscoveryHost: RelayListedHost? = nil
    public var pendingDiscoveryCode: String? = nil
    @ObservationIgnored private let cloudAccountClient = CloudAccountClient()
    @ObservationIgnored private let cloudAccountStore = CloudAccountSessionStore()
    @ObservationIgnored private var directCloudSession: CloudAccountSessionRecord? = nil
    @ObservationIgnored private var directCloudPollTask: Task<Void, Never>? = nil
    @ObservationIgnored private var discoveryConfirmationContinuation: CheckedContinuation<Bool, Never>? = nil
    public var includeRemoteDaemonUsage: Bool = true
    @ObservationIgnored public var relayTokenProvider: (() async -> String?)? = nil
    /// Set on macOS: other hosts go through the local daemon, and `pairedHosts` follows its list.
    /// Unset on iOS, which connects to them with its own client.
    @ObservationIgnored public var daemonOtherHosts: DaemonOtherHosts? = nil {
        didSet { if daemonOtherHosts != nil { applyOtherHosts(otherHosts) } }
    }
    /// The daemon's other hosts as it last reported them, while `daemonOtherHosts` is set.
    public private(set) var otherHosts: [OtherHostStatus] = []
    /// Identifier of the computer currently in the foreground (`"local"` or `OtherHostStatus.id`).
    public static let localHostID = "local"
    public var activeHostID: String = SartoState.localHostID
    public var localHostDisplayName: String = SartoState.resolveLocalHostDisplayName()
    /// Remote host IDs hidden from the sidebar unified tree, search, and running rail.
    /// The local Mac (`Self.localHostID`) can never be hidden.
    public var hiddenHostIDs: Set<String> = [] {
        didSet {
            let cleaned = hiddenHostIDs.subtracting([Self.localHostID])
            UserDefaults.standard.set(Array(cleaned).sorted(), forKey: PrefKey.hiddenHostIDs)
        }
    }
    /// Observable snapshots of background hosts in the multi-host pool (local when viewing remote,
    /// and all connected/known remote hosts when viewing local or another remote host).
    /// Reading it follows every host; `cachedHostSnapshot(_:)` follows one.
    public var backgroundHostSnapshots: [String: UnifiedHostSnapshot] = [:] {
        didSet { syncHostSnapshotCells() }
    }
    /// Each background host's snapshot in a cell of its own, kept equal to `backgroundHostSnapshots`.
    @ObservationIgnored var hostSnapshotCells: [String: HostSnapshotCell] = [:]
    public var backgroundReplicaRevision: Int = 0
    /// Bumped when a foreground replica changes in a way the Dynamic Island and the running rail
    /// show (a tool request, the plan, the session's own fields), and never by streamed text, so
    /// they follow `replicas` without redrawing for every token.
    public var islandReplicaRevision: Int = 0
    @ObservationIgnored var dirtyBackgroundSnapshotHostIDs: Set<String> = []
    @ObservationIgnored var backgroundSnapshotFlushTask: Task<Void, Never>? = nil
    public var remoteHostErrors: [String: String] = [:]
    /// Online same-account hosts probed for remote Claude Code availability.
    public var remoteClaudeHosts: [RemoteClaudeHostInfo] = []
    public var isLoadingRemoteClaudeHosts: Bool = false
    /// Active remote Claude Code runs currently hosted by this computer.
    public var remoteClaudeActiveRuns: [RemoteClaudeActiveRun] = []
    /// When non-nil on the local new-session stage, runs Claude Code on that remote host.
    public var selectedModelHostID: String? = nil
    @ObservationIgnored private var remoteClaudeHostsRefresh: UInt = 0
    @ObservationIgnored private var lastOnlineOtherHostIDs: Set<String> = []
    /// Live app version & updater states reported by connected hosts, keyed by host ID.
    public var remoteAppUpdateStatusByHost: [String: AppUpdateStatusInfo] = [:]
    @ObservationIgnored public var onHostAppUpdateCommand: ((String) -> Void)? = nil
    @ObservationIgnored public var onLocalDaemonAttached: (() -> Void)? = nil
    @ObservationIgnored var hostPool: [String: HostPoolSlot] = [:]
    /// Where `sessions` stands in the host in front's index, for reading only its changes again.
    @ObservationIgnored var sessionsCursor: SessionsCursorInfo? = nil
    @ObservationIgnored var openingRemoteHostTasks: [String: Task<HostPoolSlot?, Never>] = [:]
    @ObservationIgnored var hostSwitchGeneration: UInt64 = 0

    // MARK: - Live Sessions, Threads, Agents, Usage, Projects & Workbench
    public var sessions: [SessionSummary] = []
    public var replicas: [String: ThreadReplica] = [:]
    public var agents: [AgentStatusInfo] = []
    public var projects: [ProjectInfo] = []
    public var noProjectInfo: NoProjectInfo = NoProjectInfo()
    public var studioUsageStats: StudioUsageStats = StudioUsageStats()
    public var selectedSessionID: String?
    public let workspace = WorkspaceController()
    public let browser = PrismBrowserController()
    public let devices = PrismDeviceController()
    /// Install requests and what stops each agent; see SartoState+AgentAvailability.swift.
    let agentAvailabilityModel = AgentAvailabilityModel()
    public var activePreviewTarget: PreviewTargetMode = .web
    /// Incremented whenever an agent navigates/opens a browser page or mobile simulator on the active session so the UI reveals the unified Preview pane.
    public var browserAutoOpenRequestToken: Int = 0
    public var browserAutoOpenSessionID: String? = nil
    @ObservationIgnored var outputsCache: [String: (fetchedAt: Double, info: SessionOutputsInfo)] = [:]

    // MARK: - Composer Draft Text, Attachments, Queue, Agent Switch & Blob Cache
    public enum WorktreeLocationMode: String, Sendable, Equatable {
        case local
        case worktree
    }

    public struct WorktreeDraftChoice: Sendable, Equatable {
        public var mode: WorktreeLocationMode
        public var baseBranch: String?
        public var customBranch: String
        public var branchTemplate: String

        public init(
            mode: WorktreeLocationMode = .local,
            baseBranch: String? = nil,
            customBranch: String = "",
            branchTemplate: String = "sarto/{slug}"
        ) {
            self.mode = mode
            self.baseBranch = baseBranch
            self.customBranch = customBranch
            self.branchTemplate = branchTemplate
        }
    }

    public struct PendingAgentSwitch: Sendable, Equatable {
        public var agentId: String
        public var summarize: Bool
        public var values: [String: JSONValue]

        public init(agentId: String, summarize: Bool = false, values: [String: JSONValue] = [:]) {
            self.agentId = agentId
            self.summarize = summarize
            self.values = values
        }
    }

    public var agentOptionsById: [String: AgentOptionsInfo] = [:]
    public var newSessionProjectPath: String? = nil
    public var newSessionIsScratch: Bool = false
    public var newSessionParentID: String? = nil
    public var worktreeChoiceByProject: [String: WorktreeDraftChoice] = [:]
    public var newSessionOptionPicks: [String: [String: JSONValue]] = [:]
    /// Last-used permission mode keyed by `"\(agentId)|\(modelId)"` (persisted in UserDefaults).
    private var rememberedModeByAgentModel: [String: String] = [:]
    /// Fallback last-used permission mode keyed by `agentId` (persisted in UserDefaults).
    private var rememberedModeByAgent: [String: String] = [:]
    public var preparedSession: SessionSummary? = nil
    public var isPreparingSession: Bool = false
    public var preparedSessionError: String? = nil
    public var gitStatusByProject: [String: GitStatusInfo] = [:]
    public var gitBranchesByProject: [String: BranchListInfo] = [:]
    public var isLoadingBranches: Bool = false
    public var dismissedCacheNoticeBySession: [String: Double] = [:]

    public var draftTextByScope: [String: String] = [:]
    public var draftAttachmentsByScope: [String: [DraftAttachmentItem]] = [:]
    public var draftCommentsByScope: [String: [DraftReplyComment]] = [:]
    public var draftSessionReferencesByScope: [String: [DraftSessionReference]] = [:]
    public var attachmentBannerError: String? = nil
    @ObservationIgnored private let draftStore = ComposerDraftStore()
    @ObservationIgnored private var sessionPreviewCache: [String: (fetchedAt: TimeInterval, preview: ComposerSessionPreview)] = [:]
    private static let maxSessionPreviewCacheEntries = 64
    @ObservationIgnored private var knownFilePathsCache: (generation: UInt64, revision: UInt64, set: Set<String>)? = nil
    @ObservationIgnored private var waitingCardCache: (
        sessionId: String,
        seq: Int,
        count: Int,
        hasWaiting: Bool,
        awaitsQuestion: Bool,
        endedOnRejection: Bool
    )? = nil
    public var showArchivedSessions: Bool = false
    public var isLoadingOlderPage: Bool = false
    public var outlineBySession: [String: [OutlineEntryInfo]] = [:]
    public var pendingSwitchBySession: [String: PendingAgentSwitch] = [:]
    /// Sessions with an edit from a message or a Put back on its way to the host.
    public var rewindBusySessionIDs: Set<String> = []

    // MARK: - Context Breakdown, Global Search, Import CLI & Live Host Sync Revisions
    public var contextBreakdownBySession: [String: ContextBreakdownInfo] = [:]
    public var contextEstimatesBySession: [String: ContextEstimatesInfo] = [:]
    public var isLoadingContextBreakdown: Bool = false
    public var memoryChangeRevision: UInt64 = 0
    public var marketKeysChangeRevision: UInt64 = 0
    public var marketConnectionsByServer: [String: MarketConnectionInfo] = [:]
    public var marketConnectionError: String? = nil
    public var showGlobalSearchSheet: Bool = false
    public var showImportSessionsSheet: Bool = false
    @ObservationIgnored public var onHostOpenSettings: ((_ section: String, _ item: String?, _ row: String) -> Void)? = nil

    @ObservationIgnored var preparedTargetKey: String? = nil
    @ObservationIgnored private var preparedDiscardTask: Task<Void, Never>? = nil
    @ObservationIgnored private var discardedPreparedIDs: Set<String> = []
    @ObservationIgnored var earlyAttachedSessionIDs: Set<String> = []

    public var activeOutline: [OutlineEntryInfo] {
        guard !showStudioHome, let sid = selectedSessionSummary?.id else { return [] }
        return outlineBySession[sid] ?? []
    }
    public var showSessionBoard: Bool = false

    public var pendingSwitchAgentID: String? {
        get {
            guard !showStudioHome, let sid = selectedSessionSummary?.id else { return nil }
            return pendingSwitchBySession[sid]?.agentId
        }
        set {
            guard let sid = selectedSessionSummary?.id else { return }
            if let next = newValue {
                let existing = pendingSwitchBySession[sid]
                let values = existing?.agentId == next ? (existing?.values ?? [:]) : defaultOptionValues(for: next, projectPath: selectedSessionSummary?.projectPath, includeStartMode: false)
                pendingSwitchBySession[sid] = PendingAgentSwitch(
                    agentId: next,
                    summarize: existing?.summarize ?? false,
                    values: values
                )
            } else {
                pendingSwitchBySession.removeValue(forKey: sid)
            }
        }
    }

    public var pendingSwitchSummarize: Bool {
        get {
            guard !showStudioHome, let sid = selectedSessionSummary?.id else { return false }
            return pendingSwitchBySession[sid]?.summarize ?? false
        }
        set {
            guard let sid = selectedSessionSummary?.id, var cur = pendingSwitchBySession[sid] else { return }
            cur.summarize = newValue
            pendingSwitchBySession[sid] = cur
        }
    }

    public var pendingSwitchValues: [String: JSONValue] {
        guard !showStudioHome, let sid = selectedSessionSummary?.id else { return [:] }
        return pendingSwitchBySession[sid]?.values ?? [:]
    }
    private static let maxBlobCacheEntries = 64
    private static let maxBlobCacheBytes = 32 * 1024 * 1024

    private static let maxKeptWatchedSessions = 6
    private static let maxCachedReplicas = 16

    /// Live system load snapshots keyed by host ID (local or remote), populated while watched.
    public var hostLoadsByHostID: [String: HostLoad] = [:]
    /// Lightweight in-app toast shown while the window is focused when a background session needs attention.
    public var focusedAttentionNotice: FocusedAttentionNotice? = nil

    @ObservationIgnored private var hostLoadWatcherCount: Int = 0
    @ObservationIgnored private var hostLoadLeaseTask: Task<Void, Never>? = nil
    @ObservationIgnored private var focusedAttentionDismissTask: Task<Void, Never>? = nil
    @ObservationIgnored private var focusedAttentionSessionIDs: Set<String> = []
    @ObservationIgnored private var focusedAttentionIsHovered: Bool = false
    private static let focusedAttentionAutoDismissSeconds: Double = 3.0
    @ObservationIgnored internal var isForegroundWindowVisible: Bool = true
    @ObservationIgnored internal var lastReportedShownSession: (hostId: String, sessionObjectId: ObjectIdentifier, ids: [String])? = nil

    @ObservationIgnored private var sessionBlobCache: [String: Data] = [:]
    @ObservationIgnored private var sessionBlobOrder: [String] = []
    @ObservationIgnored private var sessionBlobTotalBytes: Int = 0
    struct SnapshotRetryState {
        var consecutiveFailures: Int = 0
        var nextAllowedAt: Date = .distantPast
    }

    @ObservationIgnored var inFlightSnapshotSessionIDs: Set<String> = []
    @ObservationIgnored var snapshotRetryBySession: [String: SnapshotRetryState] = [:]
    @ObservationIgnored var inFlightEntryHydrations: Set<String> = []
    @ObservationIgnored var activeOpenTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var prefetchTask: Task<Void, Never>? = nil
    @ObservationIgnored private var selectionGeneration: UInt64 = 0
    /// Recently viewed sessions kept actively `watched` (MRU last),
    /// so switching back between active sessions is 0-RTT instant with zero blank frames.
    @ObservationIgnored var watchedSessionOrder: [String] = []
    @ObservationIgnored var replicaAccessOrder: [String] = []
    @ObservationIgnored var isManualDisconnect: Bool = false
    @ObservationIgnored var reconnectTask: Task<Void, Never>? = nil
    @ObservationIgnored private var lastConnectedHost: PairedHostRecord? = nil
    /// The daemon's host in front, by its id, for reconnecting to it.
    @ObservationIgnored var lastOtherHostID: String? = nil
    /// The daemon lost its session with the host in front and is trying again.
    @ObservationIgnored var hostLinkDropped = false
    /// Bumped by every connect so a slower, older connect never installs itself over a newer one.
    @ObservationIgnored var connectionGeneration: UInt64 = 0
    /// The mode of the last connection that went live, to tell a reconnect from a switch of host.
    @ObservationIgnored var lastAttachedMode: ConnectionMode? = nil
    /// Set when the relay refused this device or token, which retrying cannot fix.
    @ObservationIgnored private var lastConnectRefusedByRelay = false
    @ObservationIgnored public var onReconnectLocalDaemon: (() async throws -> (agent: SartoHostSession, terminal: SartoTerminalSession?))? = nil

    @ObservationIgnored var toolVersionBySession: [String: Int] = [:]
    @ObservationIgnored private var cachedToolSubagentsKey: String = ""
    @ObservationIgnored private var cachedToolSubagents: [SessionSummary] = []
    @ObservationIgnored private var cachedToolTasksKey: String = ""
    @ObservationIgnored private var cachedToolTasks: [BackgroundTaskInfo] = []

    private let identityStore = DeviceIdentityStore(appGroupIdentifier: DeviceIdentityStore.defaultAppGroupIdentifier)
    private let localKeyPair: NoiseKeyPair
    private let relayClient = SartoRelayClient()
    var hostSession: SartoHostSession?
    var terminalSession: SartoTerminalSession?
    var eventLoopTask: Task<Void, Never>?

    public static var defaultWorkspacePath: String {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.path
        #else
        NSHomeDirectory()
        #endif
    }

    /// Resolves `out/daemon/main.cjs` via `SARTO_DAEMON_BUNDLE`, `Bundle.main.resourceURL`, or a walk-up dev fallback.
    public static func resolveDaemonBundlePath() -> String? {
        let fm = FileManager.default
        if let envOverride = ProcessInfo.processInfo.environment["SARTO_DAEMON_BUNDLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envOverride.isEmpty,
           fm.fileExists(atPath: envOverride) {
            return envOverride
        }

        if let resourceURL = Bundle.main.resourceURL {
            for rel in ["runtime/daemon/main.cjs", "daemon/main.cjs", "out/daemon/main.cjs"] {
                let candidate = resourceURL.appendingPathComponent(rel).path
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }

        var roots = [
            URL(fileURLWithPath: fm.currentDirectoryPath),
            Bundle.main.bundleURL.deletingLastPathComponent(),
        ]
        #if DEBUG
        // The checkout this build came from; a release binary must neither carry the builder's
        // source path nor look there.
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent())
        #endif
        for start in roots {
            var dir = start.standardizedFileURL
            for _ in 0..<8 {
                let candidate = dir.appendingPathComponent("out/daemon/main.cjs").path
                if fm.fileExists(atPath: candidate) {
                    return candidate
                }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }

    public init() {
        let loaded = identityStore.loadOrCreateIdentity()
        self.localKeyPair = loaded.keyPair
        self.pairedHosts = loaded.hosts

        let ud = UserDefaults.standard
        if let savedHidden = ud.stringArray(forKey: PrefKey.hiddenHostIDs) {
            self.hiddenHostIDs = Set(savedHidden).subtracting([Self.localHostID])
        }
        if let savedModes = ud.dictionary(forKey: PrefKey.rememberedModeByAgentModel) as? [String: String] {
            self.rememberedModeByAgentModel = savedModes
        }
        if let savedAgentModes = ud.dictionary(forKey: PrefKey.rememberedModeByAgent) as? [String: String] {
            self.rememberedModeByAgent = savedAgentModes
        }
        if let raw = ud.string(forKey: PrefKey.darkPalette), let p = PrismPalette(rawValue: raw), p.isDark {
            self.darkPalette = p
        }
        if let raw = ud.string(forKey: PrefKey.lightPalette), let p = PrismPalette(rawValue: raw), !p.isDark {
            self.lightPalette = p
        }
        if let raw = ud.string(forKey: PrefKey.palette), let p = PrismPalette(rawValue: raw) {
            self.palette = p
        }
        if let raw = ud.string(forKey: PrefKey.colorMode), let m = PrismColorMode(rawValue: raw) {
            self.colorMode = m
        } else {
            self.colorMode = self.palette.isDark ? .dark : .light
        }
        if let raw = ud.string(forKey: PrefKey.accentMode), let a = PrismAccentMode(rawValue: raw) {
            self.accentMode = a
        }
        if let raw = ud.string(forKey: PrefKey.appIconStyle),
           let icon = PrismAppIconStyle.fromPersistedRawValue(raw) {
            self.appIconStyle = icon
        }
        if let raw = ud.string(forKey: PrefKey.motionTier), let t = PrismMotionTier(rawValue: raw) {
            self.motionTier = t
        }
        if let raw = ud.string(forKey: PrefKey.sendKeyMode), let s = PrismSendKeyMode(rawValue: raw) {
            self.sendKeyMode = s
        }
        self.defaultAgentID = ud.string(forKey: PrefKey.defaultAgentID)
        if ud.object(forKey: PrefKey.restoreLastSession) != nil {
            self.restoreLastSession = ud.bool(forKey: PrefKey.restoreLastSession)
        }
        if let raw = ud.string(forKey: PrefKey.textSize), let ts = PrismTextSize(rawValue: raw) {
            self.textSize = ts
        }
        self.uiFontFamily = ud.string(forKey: PrefKey.uiFontFamily) ?? ""
        self.proseFontFamily = ud.string(forKey: PrefKey.proseFontFamily) ?? ""
        self.codeFontFamily = ud.string(forKey: PrefKey.codeFontFamily) ?? ""
        let savedTermSize = ud.integer(forKey: PrefKey.terminalFontSize)
        if [11, 12, 13, 14, 15, 16].contains(savedTermSize) {
            self.terminalFontSize = savedTermSize
        }
        self.terminalFontFamily = ud.string(forKey: PrefKey.terminalFontFamily) ?? ""
        if let data = ud.data(forKey: PrefKey.notifications),
           let decoded = try? JSONDecoder().decode(PrismNotificationPrefs.self, from: data) {
            self.notificationPrefs = decoded
        }
        if let savedRelay = ud.string(forKey: PrefKey.relayOrigin) {
            self.relayOrigin = savedRelay
        }
        let legacyTokenKey = PrefKey.relayBearerToken
        self.relayTokenLoadTask = Task { @MainActor [weak self] in
            let loaded = await RelayTokenVault.loadMigratingLegacy(legacyDefaultsKey: legacyTokenKey)
            guard let self, !self.relayTokenEditedSinceLaunch, let loaded, loaded != self.relayBearerToken else { return }
            self.isRestoringRelayToken = true
            self.relayBearerToken = loaded
            self.isRestoringRelayToken = false
        }
        if let tsData = ud.data(forKey: PrefKey.uiTimestamps),
           let decodedTs = try? JSONDecoder().decode([String: Double].self, from: tsData) {
            self.uiTimestamps = decodedTs
        } else {
            let hadPriorInstall = ud.object(forKey: PrefKey.palette) != nil
                || ud.object(forKey: PrefKey.colorMode) != nil
                || ud.object(forKey: "dev.sarto.usage-island.settings") != nil
            if hadPriorInstall {
                let seedKeys = [
                    "language", "darkPalette", "lightPalette", "colorMode", "palette",
                    "accentMode", "motionTier", "sendKeyMode", "defaultAgentID",
                    "restoreLastSession", "textSize", "threadWideWidth",
                    "uiFontFamily", "proseFontFamily", "codeFontFamily", "terminalFontSize",
                    "terminalFontFamily", "notifications", "subtleReminders", "islandMotion",
                    "runningRailEnabled", "browserAllowedOrigins",
                    "statusText", "providerOrder", "providerHidden",
                    "usageScope", "lowAlert", "lowThreshold", "usagePrivacy",
                ]
                var seeded: [String: Double] = [:]
                for k in seedKeys { seeded[k] = 1_000 }
                self.uiTimestamps = seeded
                if let encoded = try? JSONEncoder().encode(seeded) {
                    ud.set(encoded, forKey: PrefKey.uiTimestamps)
                }
            }
        }
        self.syncedHostIDs = Set(ud.stringArray(forKey: PrefKey.syncedHostIDs) ?? [])
        self.lastExportedBrowserOrigins = browser.exportedProjectAllowedOrigins()
        self.isInitializingPrefs = false
        restorePersistedDrafts()

        workspace.attach(host: nil, terminal: nil, projectPath: "")
        // A push or branch switch from the Git pane keeps the tray's branch chip current.
        workspace.onGitStatusLoaded = { [weak self] status in
            guard let self, self.gitStatusByProject[status.projectPath] != nil,
                  self.gitStatusByProject[status.projectPath] != status
            else { return }
            self.gitStatusByProject[status.projectPath] = status
        }
        wireBrowserCallbacks()
    }

    private func wireBrowserCallbacks() {
        browser.onWaitingChanged = { [weak self] callId, waiting in
            guard let session = self?.hostSession else { return }
            Task { try? await session.browserWaiting(callId: callId, waiting: waiting) }
        }
        browser.onOriginRequested = { [weak self] sessionId, requestId, origin in
            guard let session = self?.hostSession else { return }
            Task { try? await session.browserOrigin(sessionId: sessionId, requestId: requestId, origin: origin) }
        }
        browser.onOriginSettled = { [weak self] requestId, decision in
            guard let session = self?.hostSession else { return }
            Task { try? await session.browserOriginSettled(requestId: requestId, decision: decision) }
        }
        browser.onHandedBack = { [weak self] sessionId, durationMs in
            guard let session = self?.hostSession else { return }
            Task { try? await session.browserHandedBack(sessionId: sessionId, durationMs: durationMs) }
        }
        browser.onAgentOpenedBrowser = { [weak self] sessionId in
            guard let self else { return }
            self.activePreviewTarget = .web
            self.browserAutoOpenSessionID = sessionId
            self.browserAutoOpenRequestToken &+= 1
        }
        browser.onProjectAllowedOriginsChanged = { [weak self] in
            self?.handleLocalBrowserAllowedOriginsChanged()
        }
        devices.onAgentOpenedDevice = { [weak self] sessionId, platform, _ in
            guard let self else { return }
            self.activePreviewTarget = (platform == .ios) ? .ios : .android
            self.browserAutoOpenSessionID = sessionId
            self.browserAutoOpenRequestToken &+= 1
        }
    }

    public var activeHostSession: SartoHostSession? { hostSession }

    public var hasRunningTurns: Bool {
        sessions.contains { $0.archivedAt == nil && ($0.status == .running || $0.status == .starting || $0.status == .awaitingPermission) }
    }

    /// Whether a terminal on the connected host runs a command, which restarting the daemon would end.
    public func hasBusyTerminals() async -> Bool {
        guard let terminalSession, let terminals = try? await terminalSession.listTerminals() else { return false }
        return terminals.contains { $0.busy }
    }

    public func applySystemAppearance(isDark: Bool) {
        systemAppearanceIsDark = isDark
        if colorMode == .system {
            syncPaletteForColorMode()
        }
    }

    public func selectPaletteDirectly(_ next: PrismPalette) {
        palette = next
        if colorMode != .system {
            colorMode = next.isDark ? .dark : .light
        }
    }

    private func syncPaletteForColorMode() {
        let prevApplying = isApplyingSyncedPrefs
        if colorMode == .system {
            isApplyingSyncedPrefs = true
        }
        defer { isApplyingSyncedPrefs = prevApplying }

        switch colorMode {
        case .system:
            let target = systemAppearanceIsDark ? darkPalette : lightPalette
            if palette != target { palette = target }
        case .dark:
            if !palette.isDark { palette = darkPalette }
        case .light:
            if palette.isDark { palette = lightPalette }
        }
    }

    public func removePairedHost(id: String) {
        pairedHosts.removeAll { $0.id == id }
        if let daemon = daemonOtherHosts {
            Task { [weak self] in
                do {
                    try await daemon.remove(id)
                } catch {
                    self?.reportConnectionError(error)
                }
            }
            return
        }
        identityStore.save(keyPair: localKeyPair, hosts: pairedHosts)
    }

    /// The daemon's other hosts: `pairedHosts` lists them, and the host in front keeps its name.
    public func applyOtherHosts(_ hosts: [OtherHostStatus]) {
        // The daemon sends the whole list on every link change, and each write redraws whatever
        // reads the hosts, so only a change is written. The pool is reconciled even so: that
        // retries opening an online host whose last open failed.
        if otherHosts != hosts { otherHosts = hosts }
        guard daemonOtherHosts != nil else { return }
        let nextPaired = hosts.map { host in
            let key = Data(base64Encoded: host.publicKey).map(BaseEncoding.base64URLEncode) ?? host.publicKey
            return PairedHostRecord(
                id: host.id,
                name: host.name,
                platform: host.platform,
                hostPublicKey: key,
                relayID: host.relay?.id,
                relayURLs: host.relay?.urls ?? [],
                lastConnectedAt: host.lastOnlineAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
        }
        if pairedHosts != nextPaired { pairedHosts = nextPaired }
        if case .remoteHost(let name, let viaRelay) = connectionMode,
           let id = lastOtherHostID,
           let host = hosts.first(where: { $0.id == id }),
           host.connection.isOnline,
           host.name != name || host.connection.viaRelay != viaRelay {
            let next = ConnectionMode.remoteHost(name: host.name, viaRelay: host.connection.viaRelay)
            connectionMode = next
            lastAttachedMode = next
        }
        reconcileRemoteHostPool(with: hosts)
        let onlineIDs = Set(hosts.filter(\.connection.isOnline).map(\.id))
        if onlineIDs != lastOnlineOtherHostIDs {
            lastOnlineOtherHostIDs = onlineIDs
            Task { [weak self] in
                await self?.refreshRemoteClaudeHosts()
            }
        }
    }

    // MARK: - Own-Account Remote Claude Code

    public static let remoteClaudePrefix = "remote-claude::"

    public static func remoteClaudeSelectionID(for hostId: String) -> String {
        "\(remoteClaudePrefix)\(hostId)"
    }

    public static func remoteClaudeHostID(from selectionID: String) -> String? {
        guard selectionID.hasPrefix(remoteClaudePrefix) else { return nil }
        let id = String(selectionID.dropFirst(remoteClaudePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Selected remote Claude Code host on the local new-session stage, if any.
    public var selectedRemoteClaudeHost: RemoteClaudeHostInfo? {
        guard !isViewingRemoteHost,
              selectedAgentID == "claude-code",
              let hostId = selectedModelHostID
        else { return nil }
        return remoteClaudeHosts.first(where: { $0.hostId == hostId })
    }

    /// Effective selection ID for RunSetupPanelView (synthetic `remote-claude::<hostId>` when remote).
    public var selectedRunSetupAgentID: String {
        if !isViewingRemoteHost,
           selectedAgentID == "claude-code",
           let hostId = selectedModelHostID {
            return Self.remoteClaudeSelectionID(for: hostId)
        }
        return selectedAgentID
    }

    /// Active model host reference for the new-session stage or the currently viewed local session.
    public var activeModelHostRef: ModelHostRef? {
        guard !isViewingRemoteHost else { return nil }
        if showStudioHome {
            guard selectedAgentID == "claude-code", let hostId = selectedModelHostID else { return nil }
            if let host = selectedRemoteClaudeHost {
                return ModelHostRef(hostId: host.hostId, hostName: host.hostName)
            }
            let name = otherHosts.first(where: { $0.id == hostId })?.name ?? hostId
            return ModelHostRef(hostId: hostId, hostName: name)
        }
        let sessionAgentID = activeReplica?.session.agentId ?? selectedSessionSummary?.agentId
        guard sessionAgentID == "claude-code" else { return nil }
        if let replica = activeReplica {
            return replica.session.modelHost
        }
        return selectedSessionSummary?.modelHost
    }

    public func isModelHostOffline(_ ref: ModelHostRef) -> Bool {
        guard !isViewingRemoteHost else { return false }
        guard let host = otherHosts.first(where: { $0.id == ref.hostId }) else { return true }
        return !host.connection.isOnline
    }

    private var localHostSessionForRemoteClaude: SartoHostSession? {
        if activeHostID == Self.localHostID {
            return hostSession
        }
        return hostPool[Self.localHostID]?.agent
    }

    public func refreshRemoteClaudeHosts() async {
        // Only the latest refresh applies its answer, so a slower earlier one never wins.
        remoteClaudeHostsRefresh &+= 1
        let refresh = remoteClaudeHostsRefresh
        guard let session = localHostSessionForRemoteClaude else {
            applyRemoteClaudeHosts([])
            return
        }
        guard !otherHosts.filter(\.connection.isOnline).isEmpty else {
            applyRemoteClaudeHosts([])
            return
        }
        isLoadingRemoteClaudeHosts = true
        defer { if refresh == remoteClaudeHostsRefresh { isLoadingRemoteClaudeHosts = false } }
        guard let list = try? await session.remoteClaudeHosts(), refresh == remoteClaudeHostsRefresh else {
            return
        }
        applyRemoteClaudeHosts(list)
    }

    /// The hosts that offer Claude Code now; New session no longer picks one that went.
    private func applyRemoteClaudeHosts(_ list: [RemoteClaudeHostInfo]) {
        if list != remoteClaudeHosts { remoteClaudeHosts = list }
        if let hostId = selectedModelHostID,
           !list.contains(where: { $0.hostId == hostId && $0.status.enabled }) {
            if showStudioHome {
                setNewSessionRemoteClaudeHost(nil)
            } else {
                selectedModelHostID = nil
            }
        }
    }

    public func refreshRemoteClaudeActiveRuns() async {
        guard let session = localHostSessionForRemoteClaude else { return }
        if let list = try? await session.remoteClaudeActive(), list != remoteClaudeActiveRuns {
            remoteClaudeActiveRuns = list
        }
    }

    @discardableResult
    public func disconnectAllRemoteClaudeRuns() async throws -> Int {
        guard let session = localHostSessionForRemoteClaude else { return 0 }
        let res = try await session.remoteClaudeDisconnectAll()
        remoteClaudeActiveRuns = []
        return res.closed
    }

    public func setNewSessionRemoteClaudeHost(_ hostId: String?) {
        if hostId != nil {
            selectedAgentID = "claude-code"
        }
        selectedModelHostID = hostId
        syncEffortFromActiveConfig()
        Task { [weak self] in
            await self?.prepareNewSessionIfNeeded()
        }
    }

    /// Resolves effective ConfigOptions for a remote Claude Code host, merging its advertised
    /// models with local permission-mode / effort choices and any prepared session config.
    public func remoteClaudeConfigOptions(
        for host: RemoteClaudeHostInfo,
        overrides: [String: JSONValue],
        preparedOverride: [ConfigOption]? = nil
    ) -> [ConfigOption] {
        if let preparedOverride, !preparedOverride.isEmpty {
            return configOptions(
                forAgent: "claude-code",
                overrides: overrides,
                includeStartMode: true,
                preparedOverride: preparedOverride
            )
        }
        var combined: [ConfigOption] = host.status.models
        let existingIds = Set(combined.map(\.id))
        let localClaude = agentOptionsById["claude-code"]?.config ?? []
        for opt in localClaude where !existingIds.contains(opt.id) {
            combined.append(opt)
        }
        if !combined.contains(where: { $0.category == "mode" && $0.type == "select" }) {
            let fallbackModes = ConfigOption(
                id: "mode",
                name: l10n.tr("remoteClaude.mode.title"),
                description: nil,
                category: "mode",
                type: "select",
                value: .string("default"),
                choices: [
                    ConfigChoice(value: "default", name: l10n.tr("remoteClaude.mode.default"), description: nil),
                    ConfigChoice(value: "acceptEdits", name: l10n.tr("remoteClaude.mode.acceptEdits"), description: nil),
                    ConfigChoice(value: "plan", name: l10n.tr("remoteClaude.mode.plan"), description: nil),
                    ConfigChoice(value: "bypassPermissions", name: l10n.tr("remoteClaude.mode.bypassPermissions"), description: nil),
                ]
            )
            combined.append(fallbackModes)
        }
        // As for a local agent: the pick, else the mode remembered for the model, else the start
        // mode and remembered values New session would use.
        let defaults = defaultOptionValues(
            for: "claude-code",
            projectPath: effectiveNewSessionProjectPath,
            includeStartMode: true
        )
        let modelOpt = combined.first(where: { $0.category == "model" && $0.type == "select" })
        let resolvedModel: String? = modelOpt.flatMap { opt in
            [overrides[opt.id], defaults[opt.id]]
                .compactMap { $0 }
                .first(where: { Self.isValidConfigValue($0, for: opt) })?
                .stringValue ?? opt.value.stringValue
        }
        return combined.map { opt in
            let effectiveVal: JSONValue
            if let pick = overrides[opt.id], Self.isValidConfigValue(pick, for: opt) {
                effectiveVal = pick
            } else if opt.category == "mode" && opt.type == "select",
                      let savedMode = rememberedMode(forAgent: "claude-code", model: resolvedModel),
                      Self.isValidConfigValue(.string(savedMode), for: opt) {
                effectiveVal = .string(savedMode)
            } else if let defVal = defaults[opt.id], Self.isValidConfigValue(defVal, for: opt) {
                effectiveVal = defVal
            } else {
                effectiveVal = opt.value
            }
            return ConfigOption(
                id: opt.id,
                name: opt.name,
                description: opt.description,
                category: opt.category,
                type: opt.type,
                value: effectiveVal,
                choices: opt.choices,
                idleOnly: opt.idleOnly,
                defaultValue: opt.defaultValue,
                indicator: opt.indicator
            )
        }
    }

    public func refreshAgentsFromHost() async {
        guard let hostSession else { return }
        if let list = try? await hostSession.listAgents() {
            self.agents = list
        }
        if let opts = try? await hostSession.listAgentOptions() {
            var map: [String: AgentOptionsInfo] = [:]
            for item in opts { map[item.agentId] = item }
            self.agentOptionsById = map
        }
    }

    public func clearAllHostSessions() async throws {
        guard let hostSession else { return }
        try await hostSession.removeAllSessions()
        self.sessions = []
        self.sessionsCursor = nil
        self.replicas.removeAll()
        self.outlineBySession.removeAll()
        self.selectedSessionID = nil
        self.showStudioHome = true
    }

    public var tokens: PrismTokens {
        PrismTokens.resolved(palette: palette, accent: accentMode)
    }

    public var l10n: PrismL10n {
        PrismL10n(language: language)
    }

    public var devicePublicKeyBase64URL: String {
        BaseEncoding.base64URLEncode(localKeyPair.publicKeyData)
    }

    public var archivedSessionsCount: Int {
        sessions.filter { $0.archivedAt != nil }.count
    }

    public var prioritizedSessions: [SessionSummary] {
        let filtered = sessions.filter { showArchivedSessions ? true : ($0.archivedAt == nil) }
        return filtered.sorted(by: sessionPrecedes)
    }

    private func sessionPrecedes(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        let lPinned = lhs.pinnedAt != nil
        let rPinned = rhs.pinnedAt != nil
        if lPinned != rPinned { return lPinned }
        if lPinned && rPinned, let lp = lhs.pinnedAt, let rp = rhs.pinnedAt, lp != rp {
            return lp > rp
        }
        let lRank = priorityRank(lhs)
        let rRank = priorityRank(rhs)
        if lRank != rRank { return lRank < rRank }
        return lhs.updatedAt > rhs.updatedAt
    }

    public var selectedSessionSummary: SessionSummary? {
        if let id = selectedSessionID,
           let found = sessions.first(where: { $0.id == id }) {
            return found
        }
        // The first of `prioritizedSessions`, found in one pass instead of a full sort, as the
        // island asks for it several times a sync.
        return sessions
            .lazy
            .filter { self.showArchivedSessions ? true : ($0.archivedAt == nil) }
            .min(by: sessionPrecedes)
    }

    public func sessionSummary(for id: String) -> SessionSummary? {
        sessions.first(where: { $0.id == id })
    }

    public var parentSessionSummary: SessionSummary? {
        guard let parentId = activeReplica?.session.parentId ?? selectedSessionSummary?.parentId else {
            return nil
        }
        return sessionSummary(for: parentId)
    }

    public var activeReplica: ThreadReplica? {
        guard let id = selectedSessionSummary?.id else { return nil }
        return replicas[id]
    }

    public var activeQueue: [QueuedPrompt] {
        activeReplica?.session.queue ?? []
    }

    public var activeQueuePaused: Bool {
        activeReplica?.session.queuePaused ?? false
    }

    public var activeSlashCommands: [SlashCommand] {
        if showStudioHome {
            if let prepared = preparedSession, prepared.agentId == selectedAgentID {
                return (prepared.prepared?.commands ?? []).filter { $0.name != "btw" }
            }
            return []
        }
        return (activeReplica?.session.commands ?? []).filter { $0.name != "btw" }
    }

    public var activeStartNotices: [StartNoticeInfo] {
        guard showStudioHome,
              let prepared = preparedSession,
              prepared.agentId == selectedAgentID
        else { return [] }
        return (prepared.prepared?.notices ?? []).filter { notice in
            !(notice.type == "boolean" && notice.actual == nil && notice.wanted.boolValue == false)
        }
    }

    public var resolvedNewSessionParent: SessionSummary? {
        guard let pid = newSessionParentID else { return nil }
        return sessionSummary(for: pid)
    }

    public var effectiveNewSessionProjectPath: String? {
        if let parent = resolvedNewSessionParent {
            return parent.scratch == true ? nil : parent.projectPath
        }
        if newSessionIsScratch { return nil }
        if let chosen = newSessionProjectPath, !chosen.isEmpty {
            return chosen
        }
        return projects.first(where: { !$0.isMissing })?.path ?? projects.first?.path
    }

    public var effectiveNewSessionIsScratch: Bool {
        if let parent = resolvedNewSessionParent {
            return parent.scratch == true
        }
        return newSessionIsScratch
    }

    public var recentPickupSessions: [SessionSummary] {
        sessions
            .filter { $0.archivedAt == nil && ($0.origin == nil || $0.origin == "user") }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(6)
            .map { $0 }
    }

    public var recallableUserMessages: [String] {
        recallableUserMessagesWithIDs.map(\.text)
    }

    public var recallableUserMessagesWithIDs: [(id: String, text: String)] {
        guard !showStudioHome, let replica = activeReplica else { return [] }
        var result: [(id: String, text: String)] = []
        for entry in replica.entries {
            if case .user(let id, let text, _, _, let approval, _) = entry,
               !approval {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append((id: id, text: text))
                }
            }
        }
        return result
    }

    public var activeSessionUsedFiles: [String] {
        guard !showStudioHome,
              let replica = activeReplica,
              let projectPath = activeTrayProjectPath,
              !workspace.filePaths.isEmpty
        else { return [] }
        let known: Set<String>
        if let cached = knownFilePathsCache,
           cached.generation == workspace.projectGeneration,
           cached.revision == workspace.fileTreeRevision {
            known = cached.set
        } else {
            let built = Set(workspace.filePaths)
            knownFilePathsCache = (workspace.projectGeneration, workspace.fileTreeRevision, built)
            known = built
        }
        return ComposerPathMatcher.usedFiles(
            from: replica.entries,
            projectPath: projectPath,
            known: known
        )
    }

    private func activeWaitingCardFlags() -> (hasWaiting: Bool, awaitsQuestion: Bool, endedOnRejection: Bool) {
        guard !showStudioHome,
              let sessionId = selectedSessionID,
              let replica = activeReplica
        else { return (false, false, false) }
        if let cached = waitingCardCache,
           cached.sessionId == sessionId,
           cached.seq == replica.seq,
           cached.count == replica.entries.count {
            return (cached.hasWaiting, cached.awaitsQuestion, cached.endedOnRejection)
        }
        let entries = replica.entries
        let flags = (
            hasWaiting: ComposerWaitingCard.hasWaitingCard(in: entries),
            awaitsQuestion: ComposerWaitingCard.awaitsQuestionAnswer(in: entries),
            endedOnRejection: ComposerWaitingCard.endedOnRejection(in: entries)
        )
        waitingCardCache = (sessionId, replica.seq, entries.count, flags.hasWaiting, flags.awaitsQuestion, flags.endedOnRejection)
        return flags
    }

    public var activeHasWaitingCard: Bool {
        activeWaitingCardFlags().hasWaiting
    }

    public var activeAwaitsQuestionAnswer: Bool {
        activeWaitingCardFlags().awaitsQuestion
    }

    public var activeEndedOnRejection: Bool {
        activeWaitingCardFlags().endedOnRejection
    }

    /// Executes the keyboard action (`Enter`, `Cmd+Enter`, or `Esc`) on the first waiting card in the active session.
    @discardableResult
    public func answerFirstWaitingCard(key: ComposerCardKey) -> Bool {
        guard !showStudioHome,
              let sessionId = selectedSessionSummary?.id,
              let entries = activeReplica?.entries,
              let action = ComposerWaitingCard.action(for: key, in: entries)
        else { return false }

        Task { [weak self] in
            guard let self else { return }
            switch action {
            case .respondPermission(let requestId, let optionId):
                await self.respondPermission(sessionId: sessionId, requestId: requestId, optionId: optionId)
            case .answerMemory(let entryId, let decision):
                await self.answerMemory(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerSettingsChange(let entryId, let decision):
                await self.answerSettingsChange(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerBrowserOrigin(let entryId, let decision):
                await self.answerBrowserOrigin(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerControlAsk(let entryId, let outcome):
                await self.answerControlAsk(sessionId: sessionId, entryId: entryId, outcome: outcome)
            case .answerDeviceAccess(let entryId, let decision):
                await self.answerDeviceAccess(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerSurfaceAccess(let entryId, let decision):
                await self.answerSurfaceAccess(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerComputerApp(let entryId, let decision):
                await self.answerComputerApp(sessionId: sessionId, entryId: entryId, decision: decision)
            case .declineComputerSetup(let entryId):
                await self.declineComputerSetup(sessionId: sessionId, entryId: entryId)
            case .answerProjectMcp(let entryId, let decision):
                await self.answerProjectMcp(sessionId: sessionId, entryId: entryId, decision: decision)
            case .answerProjectHooks(let entryId, let decision):
                await self.answerProjectHooks(sessionId: sessionId, entryId: entryId, decision: decision)
            }
        }
        return true
    }

    public var activeHeldOutside: Bool {
        !showStudioHome && (activeReplica?.session.heldOutside == true)
    }

    public var activePromptCache: PromptCacheInfo? {
        guard !showStudioHome else { return nil }
        return activeReplica?.session.usage?.cache ?? selectedSessionSummary?.cache
    }

    /// Returns context token count to warn about when prompt cache has expired and context >= 20k tokens.
    public func expiredCacheNoticeTokens(draftNonEmpty: Bool, nowMs: Double = Date().timeIntervalSince1970 * 1000.0) -> Double? {
        guard !showStudioHome,
              draftNonEmpty,
              !isTurnBusy,
              pendingSwitchAgentID == nil,
              let sid = selectedSessionSummary?.id,
              let cache = activePromptCache,
              let expiresAt = cache.expiresAt,
              nowMs >= expiresAt
        else { return nil }
        let used = activeContextUsed
        guard used >= 20_000 else { return nil }
        if dismissedCacheNoticeBySession[sid] == cache.lastRequestAt {
            return nil
        }
        return used
    }

    public func dismissActiveCacheNotice() {
        guard let sid = selectedSessionSummary?.id,
              let lastReq = activePromptCache?.lastRequestAt
        else { return }
        dismissedCacheNoticeBySession[sid] = lastReq
    }

    public func warmCacheChangeNote(nowMs: Double = Date().timeIntervalSince1970 * 1000.0) -> String? {
        guard !showStudioHome,
              !isTurnBusy,
              let agentId = activeReplica?.session.agentId ?? selectedSessionSummary?.agentId,
              agentId.contains("claude"),
              let cache = activePromptCache,
              let expiresAt = cache.expiresAt,
              nowMs < expiresAt,
              activeContextUsed >= 10_000
        else { return nil }
        return l10n.tr("composer.cacheWarmChangeNote", PrismTelemetryFormat.compactTokens(activeContextUsed))
    }

    public var activeTrayProjectPath: String? {
        if showStudioHome {
            return effectiveNewSessionProjectPath
        }
        guard let summary = selectedSessionSummary else { return nil }
        return summary.scratch == true ? nil : summary.projectPath
    }

    public var activeTrayGitStatus: GitStatusInfo? {
        guard let path = activeTrayProjectPath else { return nil }
        if let cached = gitStatusByProject[path] {
            return cached
        }
        if workspace.activeProjectPath == path {
            return workspace.gitStatus
        }
        return nil
    }

    public var activeTrayBranchName: String? {
        if let status = activeTrayGitStatus, status.repo != nil {
            if let b = status.head.branch, !b.isEmpty { return b }
            if let oid = status.head.oid, !oid.isEmpty { return String(oid.prefix(7)) }
        }
        if !showStudioHome {
            return selectedSessionSummary?.worktree?.branch ?? selectedSessionSummary?.branch
        }
        return nil
    }

    public func worktreeDraft(for projectPath: String) -> WorktreeDraftChoice {
        worktreeChoiceByProject[projectPath] ?? WorktreeDraftChoice()
    }

    public func updateWorktreeDraft(for projectPath: String, _ mutate: (inout WorktreeDraftChoice) -> Void) {
        var draft = worktreeChoiceByProject[projectPath] ?? WorktreeDraftChoice()
        mutate(&draft)
        worktreeChoiceByProject[projectPath] = draft
    }

    public static func isValidGitBranchName(_ raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        if name.hasPrefix("-") || name.hasPrefix(".") || name.hasPrefix("/") { return false }
        if name.hasSuffix("/") || name.hasSuffix(".") || name.hasSuffix(".lock") { return false }
        if name.contains("..") || name.contains("//") || name.contains("@{") || name == "@" { return false }
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\]\t\n\r")
        if name.rangeOfCharacter(from: forbidden) != nil { return false }
        for seg in name.split(separator: "/") {
            if seg.hasPrefix(".") || seg.hasSuffix(".lock") { return false }
        }
        return true
    }

    public func capabilities(for agentId: String) -> AgentCapabilitiesInfo? {
        agents.first(where: { $0.id == agentId })?.capabilities
    }

    public var activeAgentCapabilities: AgentCapabilitiesInfo? {
        guard let agentId = activeReplica?.session.agentId ?? selectedSessionSummary?.agentId else {
            return nil
        }
        return capabilities(for: agentId)
    }

    public var canForkActiveSession: Bool {
        guard !showStudioHome,
              let summary = selectedSessionSummary,
              summary.origin != "subagent",
              let caps = activeAgentCapabilities,
              caps.forkSession
        else { return false }
        let st = activeReplica?.session.status ?? summary.status
        return st != .starting && st != .failed && st != .authRequired
    }

    public var canForkActiveAtMessage: Bool {
        canForkActiveSession && (activeAgentCapabilities?.forkAtMessage == true)
    }

    public var isViewingSubagent: Bool {
        !showStudioHome && (activeReplica?.session.origin ?? selectedSessionSummary?.origin) == "subagent"
    }

    public var activeSubagents: [SessionSummary] {
        guard !showStudioHome, let sid = selectedSessionSummary?.id else { return [] }
        let native = sessions
            .filter { $0.parentId == sid && $0.origin == "subagent" }
            .sorted { lhs, rhs in
                let lw = lhs.permissionCount > 0 || lhs.attention == "permission" || lhs.status == .awaitingPermission
                let rw = rhs.permissionCount > 0 || rhs.attention == "permission" || rhs.status == .awaitingPermission
                if lw != rw { return lw }
                return lhs.createdAt < rhs.createdAt
            }
        if !native.isEmpty {
            return native
        }
        guard let replica = activeReplica else { return [] }
        let ver = toolVersionBySession[replica.session.id] ?? 0
        let key = "\(replica.session.id)|\(ver)|\(replica.session.status.rawValue)"
        if key == cachedToolSubagentsKey {
            return cachedToolSubagents
        }
        let derived = Self.deriveToolSubagents(from: replica)
        cachedToolSubagentsKey = key
        cachedToolSubagents = derived
        return derived
    }

    public var activeBackgroundTasks: [BackgroundTaskInfo] {
        guard !showStudioHome, let replica = activeReplica else { return [] }
        if !replica.session.background.isEmpty {
            return replica.session.background
        }
        let ver = toolVersionBySession[replica.session.id] ?? 0
        let key = "\(replica.session.id)|\(ver)|\(replica.session.status.rawValue)"
        if key == cachedToolTasksKey {
            return cachedToolTasks
        }
        let derived = Self.deriveToolTasks(from: replica)
        cachedToolTasksKey = key
        cachedToolTasks = derived
        return derived
    }

    private static func deriveToolSubagents(from replica: ThreadReplica) -> [SessionSummary] {
        let baseTime = replica.session.turnStartedAt ?? replica.session.updatedAt
        var found: [SessionSummary] = []

        for entry in replica.entries.suffix(120) {
            guard case .tool(let data) = entry else { continue }
            let lowerTitle = data.title.lowercased()
            let parsed = parseJSONObject(data.rawInput)
            let isSubagentTool = lowerTitle.contains("invoke_subagent")
                || lowerTitle.contains("spawn_agent")
                || (parsed?["Role"] != nil && parsed?["TypeName"] != nil)
                || parsed?["subagent_type"] != nil
            guard isSubagentTool else { continue }

            let role = (parsed?["Role"] as? String)
                ?? (parsed?["role"] as? String)
                ?? (parsed?["description"] as? String)
                ?? data.title
            let typeName = (parsed?["TypeName"] as? String)
                ?? (parsed?["subagent_type"] as? String)
                ?? "subagent"
            let prompt = (parsed?["Prompt"] as? String)
                ?? (parsed?["prompt"] as? String)
                ?? data.description

            let status: SessionStatus
            switch data.status {
            case "in_progress", "pending":
                status = .running
            case "failed":
                status = .failed
            default:
                status = .ready
            }

            found.append(SessionSummary(
                id: "tool:\(data.id)",
                agentId: typeName,
                projectPath: replica.session.projectPath,
                title: role,
                description: prompt,
                status: status,
                permissionCount: data.permission != nil ? 1 : 0,
                createdAt: baseTime,
                updatedAt: replica.session.updatedAt,
                parentId: replica.session.id,
                origin: "subagent-tool"
            ))
        }

        return Array(found.suffix(6).reversed())
    }

    private static func deriveToolTasks(from replica: ThreadReplica) -> [BackgroundTaskInfo] {
        let baseTime = replica.session.turnStartedAt ?? replica.session.updatedAt
        var live: [BackgroundTaskInfo] = []

        for entry in replica.entries.suffix(80) {
            guard case .tool(let data) = entry else { continue }
            let lowerTitle = data.title.lowercased()
            let isWorkflow = lowerTitle.contains("run_workflow")
            let isMonitor = lowerTitle.contains("schedule")
            let isExecute = data.toolKind == "execute"
            guard isExecute || isWorkflow || isMonitor else { continue }

            let isLive = data.status == "in_progress" || data.status == "pending"
            guard isLive else { continue }
            let outputText = extractToolText(from: data)
            let parsedInput = parseJSONObject(data.rawInput)
            let waitMs = (parsedInput?["WaitMsBeforeAsync"] as? Int)
                ?? (parsedInput?["WaitMsBeforeAsync"] as? Double).flatMap(Int.wholePart(of:))
            let isExplicitBackground = (parsedInput?["run_in_background"] as? Bool == true)
                || (parsedInput?["IsDaemon"] as? Bool == true)
                || (parsedInput?["isDaemon"] as? Bool == true)
                || (waitMs != nil && waitMs! <= 1000)
                || outputText.localizedCaseInsensitiveContains("running as a background task")
                || outputText.localizedCaseInsensitiveContains("Task logs are available")
                || outputText.localizedCaseInsensitiveContains("background task with task id")
            guard isWorkflow || isMonitor || isExplicitBackground else { continue }

            let kind = isWorkflow ? "workflow" : (isMonitor ? "monitor" : "shell")
            let cleanTitle: String = {
                if let desc = data.description?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                    return desc
                }
                let firstLine = data.title.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? data.title
                let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.count > 64 ? String(trimmed.prefix(63)) + "…" : trimmed
            }()

            let task = BackgroundTaskInfo(
                id: "tool:\(data.id)",
                kind: kind,
                title: cleanTitle,
                command: data.rawInput ?? data.title,
                status: "running",
                startedAt: baseTime,
                endedAt: nil,
                summary: outputText.split(separator: "\n").last.map(String.init)
            )
            live.append(task)
        }

        return live
    }

    private static func isMobileDeviceToolTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower.contains("device_open")
            || lower.contains("device_tap")
            || lower.contains("device_screenshot")
            || lower.contains("device_launch_app")
            || lower.contains("device_install_app")
            || lower.contains("device_snapshot")
    }

    private static func parseJSONObject(_ raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.first == "{",
              let data = raw.data(using: .utf8)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func extractToolText(from data: ToolEntryData) -> String {
        var chunks: [String] = []
        for item in data.content {
            switch item {
            case .markdown(let md) where !md.isEmpty:
                chunks.append(md)
            case .diff(let path, _, _):
                chunks.append("diff: \(path)")
            case .digest(let of, let path, let lines, _, _, _):
                chunks.append("\(of)\(path.map { ": \($0)" } ?? "")\(lines.map { " (\($0) lines)" } ?? "")")
            default:
                break
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var activeBoardWaitingCount: Int {
        activeSubagents.filter {
            $0.permissionCount > 0 || $0.attention == "permission" || $0.status == .awaitingPermission
        }.count
    }

    public var activeBoardRunningCount: Int {
        let runningAgents = activeSubagents.filter {
            let waiting = $0.permissionCount > 0 || $0.attention == "permission" || $0.status == .awaitingPermission
            return !waiting && ($0.status == .running || $0.status == .starting)
        }.count
        let runningTasks = activeBackgroundTasks.filter { $0.status == "running" }.count
        return runningAgents + runningTasks
    }

    public var isTurnBusy: Bool {
        guard !showStudioHome, let status = activeReplica?.session.status ?? selectedSessionSummary?.status else {
            return false
        }
        return status == .running || status == .starting || status == .awaitingPermission
    }

    public var activeDraftText: String {
        get { draftTextByScope[activeAttachmentScope] ?? "" }
        set {
            let scope = activeAttachmentScope
            draftTextByScope[scope] = newValue
            persistDraft(scope: scope)
        }
    }

    public var activeDraftComments: [DraftReplyComment] {
        guard !showStudioHome else { return [] }
        return draftCommentsByScope[activeAttachmentScope] ?? []
    }

    public func addReplyComment(entryId: String? = nil, passage: String, comment: String) {
        guard !showStudioHome else { return }
        let trimmedPassage = passage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassage.isEmpty else { return }
        let scope = activeAttachmentScope
        let item = DraftReplyComment(
            entryId: entryId,
            passage: trimmedPassage,
            comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var list = draftCommentsByScope[scope] ?? []
        list.append(item)
        draftCommentsByScope[scope] = list
        persistDraft(scope: scope)
    }

    public func editReplyComment(id: String, comment: String) {
        let scope = activeAttachmentScope
        guard var list = draftCommentsByScope[scope],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        list[idx].comment = trimmed
        draftCommentsByScope[scope] = list
        persistDraft(scope: scope)
    }

    public func removeReplyComment(id: String) {
        let scope = activeAttachmentScope
        guard var list = draftCommentsByScope[scope] else { return }
        list.removeAll { $0.id == id }
        draftCommentsByScope[scope] = list
        persistDraft(scope: scope)
    }

    public func clearReplyComments() {
        let scope = activeAttachmentScope
        draftCommentsByScope[scope] = []
        persistDraft(scope: scope)
    }

    public var activeDraftSessionReferences: [DraftSessionReference] {
        draftSessionReferencesByScope[activeAttachmentScope] ?? []
    }

    public func addDraftSessionReference(_ reference: DraftSessionReference) {
        let scope = activeAttachmentScope
        var list = draftSessionReferencesByScope[scope] ?? []
        if let idx = list.firstIndex(where: { $0.id == reference.id }) {
            list[idx] = reference
        } else {
            list.append(reference)
        }
        draftSessionReferencesByScope[scope] = list
        persistDraft(scope: scope)
    }

    public func removeDraftSessionReferences(sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        let scope = activeAttachmentScope
        guard var list = draftSessionReferencesByScope[scope] else { return }
        let drop = Set(sessionIDs)
        list.removeAll { drop.contains($0.id) }
        draftSessionReferencesByScope[scope] = list
        persistDraft(scope: scope)
    }

    /// Other unarchived top-level / user sessions belonging to the exact same project as the current draft.
    public func sameProjectReferenceableSessions(isNewSessionStage: Bool) -> [ComposerSessionCandidate] {
        let projectPath: String?
        let excludedID: String?
        if isNewSessionStage {
            projectPath = effectiveNewSessionIsScratch ? nil : effectiveNewSessionProjectPath
            excludedID = nil
        } else {
            guard let current = selectedSessionSummary, current.scratch != true else { return [] }
            projectPath = current.projectPath
            excludedID = current.id
        }
        guard let projectPath, !projectPath.isEmpty else { return [] }

        return sessions.compactMap { s -> ComposerSessionCandidate? in
            guard s.archivedAt == nil,
                  s.scratch != true,
                  s.prepared == nil,
                  s.origin != "subagent",
                  s.projectPath == projectPath,
                  s.id != excludedID
            else { return nil }
            let rawTitle = (s.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = rawTitle.isEmpty ? l10n.tr("session.untitled") : rawTitle
            return ComposerSessionCandidate(
                id: s.id,
                title: displayTitle,
                agentId: s.agentId,
                agentName: agentDisplayName(for: s.agentId),
                projectPath: s.projectPath,
                branch: s.branch ?? s.worktree?.branch,
                status: s.status,
                updatedAt: s.updatedAt
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Referenced session IDs that are currently archived or deleted (for subtle warning styling on inline chips).
    public func missingReferencedSessionIDs(for references: [DraftSessionReference]) -> Set<String> {
        guard !references.isEmpty else { return [] }
        let activeUnarchived = Set(sessions.filter { $0.archivedAt == nil }.map(\.id))
        return Set(references.map(\.id).filter { !activeUnarchived.contains($0) })
    }

    /// Read-only fetch of a referenced session's entries without waking or starting its agent.
    public func fetchSessionEntriesForReference(sessionId: String) async -> [ThreadEntry] {
        if let hostSession,
           let snapshot = try? await hostSession.sessionSnapshot(sessionId: sessionId, from: 0) {
            return snapshot.entries
        }
        if let replica = replicas[sessionId] {
            return replica.entries
        }
        return []
    }

    /// Cached lightweight preview for 350ms hover over an inline session reference chip.
    public func fetchSessionPreview(sessionId: String) async -> ComposerSessionPreview {
        let now = Date().timeIntervalSince1970
        if let cached = sessionPreviewCache[sessionId], (now - cached.fetchedAt) < 12.0 {
            return cached.preview
        }
        let entries = await fetchSessionEntriesForReference(sessionId: sessionId)
        let preview = ComposerSessionContextFormatter.preview(from: entries)
        sessionPreviewCache[sessionId] = (now, preview)
        if sessionPreviewCache.count > Self.maxSessionPreviewCacheEntries {
            sessionPreviewCache = sessionPreviewCache.filter { (now - $0.value.fetchedAt) < 12.0 }
            if sessionPreviewCache.count > Self.maxSessionPreviewCacheEntries {
                let overflow = sessionPreviewCache.count - Self.maxSessionPreviewCacheEntries
                let oldest = sessionPreviewCache
                    .sorted { $0.value.fetchedAt < $1.value.fetchedAt }
                    .prefix(overflow)
                for (key, _) in oldest {
                    sessionPreviewCache.removeValue(forKey: key)
                }
            }
        }
        return preview
    }

    public func flushDraftsNow() {
        draftStore.flushNow()
    }

    private func restorePersistedDrafts() {
        for (scope, saved) in draftStore.allDrafts() {
            if !saved.text.isEmpty {
                draftTextByScope[scope] = saved.text
            }
            if !saved.attachments.isEmpty {
                draftAttachmentsByScope[scope] = saved.attachments.map { $0.toDraftItem() }
            }
            if !saved.comments.isEmpty {
                draftCommentsByScope[scope] = saved.comments
            }
            if !saved.sessionReferences.isEmpty {
                draftSessionReferencesByScope[scope] = saved.sessionReferences
            }
        }
    }

    private func persistDraft(scope: String) {
        let text = draftTextByScope[scope] ?? ""
        let savedAttachments: [PersistedDraftAttachment] = (draftAttachmentsByScope[scope] ?? []).compactMap { item in
            guard let att = item.readyAttachment, !item.goneOnHost else { return nil }
            return PersistedDraftAttachment(
                attachment: att,
                pixelWidth: item.pixelWidth,
                pixelHeight: item.pixelHeight,
                projectRelativePath: item.projectRelativePath
            )
        }
        let comments = draftCommentsByScope[scope] ?? []
        let sessionRefs = (draftSessionReferencesByScope[scope] ?? []).filter { text.contains($0.token) }
        draftStore.update(
            scope: scope,
            draft: PersistedComposerDraft(
                text: text,
                attachments: savedAttachments,
                comments: comments,
                sessionReferences: sessionRefs
            )
        )
    }

    private func verifyRestoredDraftAttachments(host: SartoHostSession) async {
        var ids: [String] = []
        for items in draftAttachmentsByScope.values {
            for item in items {
                if let id = item.readyAttachment?.id {
                    ids.append(id)
                }
            }
        }
        guard !ids.isEmpty else { return }
        guard let heldList = try? await host.heldAttachments(ids: ids) else { return }
        let held = Set(heldList)
        let asked = Set(ids)
        for scope in Array(draftAttachmentsByScope.keys) {
            guard var items = draftAttachmentsByScope[scope] else { continue }
            var changed = false
            for idx in items.indices {
                guard let id = items[idx].readyAttachment?.id,
                      asked.contains(id),
                      !held.contains(id)
                else { continue }
                items[idx].status = .failed(l10n.tr("composer.attachments.unavailableLong"))
                items[idx].goneOnHost = true
                changed = true
            }
            if changed {
                draftAttachmentsByScope[scope] = items
                persistDraft(scope: scope)
            }
        }
    }

    public var composerDraft: String {
        get { activeDraftText }
        set { activeDraftText = newValue }
    }

    public var activeContextUsed: Double {
        activeReplica?.session.usage?.used ?? 0
    }

    public var activeContextTotal: Double {
        activeReplica?.session.usage?.size ?? 0
    }

    public var activeContextFill: Double {
        activeReplica?.session.usage?.fillRatio ?? 0
    }

    public var activeIsStreaming: Bool {
        guard let status = activeReplica?.session.status ?? selectedSessionSummary?.status else {
            return false
        }
        return status == .running
    }

    public var activeAuraState: PrismAuraState {
        if isStartSurging { return .start }
        guard !showStudioHome, let summary = selectedSessionSummary else { return .idle }
        if activeIsStreaming { return .running }
        if summary.status == .awaitingPermission || summary.permissionCount > 0 { return .waiting }
        if summary.status == .failed { return .error }
        if summary.status == .ready { return .completed }
        return .idle
    }

    // MARK: - Live Session, Pending Switch & New Session Config (Model, Mode, Effort, Booleans)

    public static func isFullAccessMode(_ value: String?) -> Bool {
        guard let lower = value?.lowercased() else { return false }
        return lower == "bypasspermissions"
            || lower == "full-access"
            || lower == "danger-full-access"
            || lower == "yolo"
            || lower == "never"
            || lower == "full"
    }

    public static func modeLookKind(for value: String?) -> PrismModeLook {
        if isFullAccessMode(value) { return .full }
        switch value?.lowercased() {
        case "workspace-write", "acceptedits", "accept-edits": return .edits
        case "plan": return .plan
        case "auto", "agent": return .auto
        default: return .asks
        }
    }

    private func rememberedMode(forAgent agentId: String, model: String?) -> String? {
        if let model, !model.isEmpty,
           let perModel = rememberedModeByAgentModel["\(agentId)|\(model)"],
           !perModel.isEmpty {
            return perModel
        }
        if let perAgent = rememberedModeByAgent[agentId], !perAgent.isEmpty {
            return perAgent
        }
        return nil
    }

    private func recordRememberedMode(_ modeValue: String, forAgent agentId: String, model: String?) {
        guard !agentId.isEmpty, !modeValue.isEmpty else { return }
        let ud = UserDefaults.standard
        if rememberedModeByAgent[agentId] != modeValue {
            rememberedModeByAgent[agentId] = modeValue
            ud.set(rememberedModeByAgent, forKey: PrefKey.rememberedModeByAgent)
        }
        if let model, !model.isEmpty {
            let key = "\(agentId)|\(model)"
            if rememberedModeByAgentModel[key] != modeValue {
                rememberedModeByAgentModel[key] = modeValue
                ud.set(rememberedModeByAgentModel, forKey: PrefKey.rememberedModeByAgentModel)
            }
        }
    }

    public func defaultOptionValues(
        for agentId: String,
        projectPath: String?,
        includeStartMode: Bool
    ) -> [String: JSONValue] {
        guard let entry = agentOptionsById[agentId] else { return [:] }
        var out: [String: JSONValue] = [:]
        for opt in entry.config {
            out[opt.id] = opt.value
        }
        if let remembered = entry.remembered {
            for (k, v) in remembered {
                out[k] = v
            }
        }
        if includeStartMode,
           let startMode = entry.startMode,
           let modeOpt = entry.config.first(where: { $0.category == "mode" && $0.type == "select" }),
           modeOpt.choices?.contains(where: { $0.value == startMode }) == true {
            out[modeOpt.id] = .string(startMode)
        }
        // Prefer the user's last-used permission mode for this channel & model over agent startMode.
        if let modeOpt = entry.config.first(where: { $0.category == "mode" && $0.type == "select" }) {
            let modelOpt = entry.config.first(where: { $0.category == "model" && $0.type == "select" })
            let modelVal = modelOpt.flatMap { out[$0.id]?.stringValue ?? $0.value.stringValue }
            if let savedMode = rememberedMode(forAgent: agentId, model: modelVal),
               Self.isValidConfigValue(.string(savedMode), for: modeOpt) {
                out[modeOpt.id] = .string(savedMode)
            }
        }
        return out
    }

    /// Resolves effective ConfigOptions for any agent given cached `agents.options` and user overrides.
    public func configOptions(
        forAgent agentId: String,
        overrides: [String: JSONValue],
        includeStartMode: Bool,
        preparedOverride: [ConfigOption]? = nil
    ) -> [ConfigOption] {
        let baseConfig: [ConfigOption]
        if let preparedOverride, !preparedOverride.isEmpty {
            baseConfig = preparedOverride
        } else if let entry = agentOptionsById[agentId] {
            baseConfig = entry.config
        } else {
            return []
        }

        let entry = agentOptionsById[agentId]
        let defaults = defaultOptionValues(for: agentId, projectPath: effectiveNewSessionProjectPath, includeStartMode: includeStartMode)

        // Resolve current model first so model-specific thought_level choices from `entry.levels`
        // and per-(agent, model) remembered permission modes apply.
        let modelOpt = baseConfig.first(where: { $0.category == "model" && $0.type == "select" })
        let resolvedModelVal: String? = {
            guard let modelOpt else { return nil }
            if let pick = overrides[modelOpt.id]?.stringValue { return pick }
            if preparedOverride != nil { return modelOpt.value.stringValue }
            return defaults[modelOpt.id]?.stringValue ?? modelOpt.value.stringValue
        }()

        return baseConfig.map { opt in
            var working = opt
            if opt.category == "thought_level",
               let mVal = resolvedModelVal,
               let modelSpecific = entry?.levels?[mVal] {
                working = modelSpecific
            }
            let effectiveVal: JSONValue
            if let pick = overrides[working.id], Self.isValidConfigValue(pick, for: working) {
                effectiveVal = pick
            } else if working.category == "mode" && working.type == "select",
                      let savedMode = rememberedMode(forAgent: agentId, model: resolvedModelVal),
                      Self.isValidConfigValue(.string(savedMode), for: working) {
                effectiveVal = .string(savedMode)
            } else if preparedOverride != nil {
                effectiveVal = working.value
            } else if let defVal = defaults[working.id], Self.isValidConfigValue(defVal, for: working) {
                effectiveVal = defVal
            } else {
                effectiveVal = working.value
            }
            return ConfigOption(
                id: working.id,
                name: working.name,
                description: working.description,
                category: working.category,
                type: working.type,
                value: effectiveVal,
                choices: working.choices,
                idleOnly: working.idleOnly,
                defaultValue: working.defaultValue,
                indicator: working.indicator
            )
        }
    }

    private static func isValidConfigValue(_ value: JSONValue, for option: ConfigOption) -> Bool {
        if option.type == "boolean" {
            if case .bool = value { return true }
            return value.stringValue == "default"
        }
        guard let str = value.stringValue else { return false }
        guard let choices = option.choices, !choices.isEmpty else { return true }
        return choices.contains(where: { $0.value == str })
    }

    /// Effective config options for the currently active composer (New Session, Pending Agent Switch, or Live Session).
    public var activeConfigOptions: [ConfigOption] {
        if showStudioHome {
            if let remoteHost = selectedRemoteClaudeHost {
                let prepCfg = (preparedSession?.agentId == "claude-code" && preparedSession?.modelHost?.hostId == remoteHost.hostId)
                    ? preparedSession?.prepared?.config
                    : nil
                return remoteClaudeConfigOptions(
                    for: remoteHost,
                    overrides: newSessionOptionPicks["claude-code"] ?? [:],
                    preparedOverride: prepCfg
                )
            }
            let prepCfg = (preparedSession?.agentId == selectedAgentID && preparedSession?.modelHost == nil)
                ? preparedSession?.prepared?.config
                : nil
            return configOptions(
                forAgent: selectedAgentID,
                overrides: newSessionOptionPicks[selectedAgentID] ?? [:],
                includeStartMode: true,
                preparedOverride: prepCfg
            )
        }
        if let sid = selectedSessionSummary?.id, let pending = pendingSwitchBySession[sid] {
            return configOptions(
                forAgent: pending.agentId,
                overrides: pending.values,
                includeStartMode: false
            )
        }
        return activeReplica?.session.config ?? []
    }

    public var activeConfigAgentID: String {
        if showStudioHome { return selectedAgentID }
        if let pendingId = pendingSwitchAgentID { return pendingId }
        return activeReplica?.session.agentId ?? selectedSessionSummary?.agentId ?? selectedAgentID
    }

    public var activeModelConfigOption: ConfigOption? {
        activeConfigOptions.first(where: { $0.category == "model" && $0.type == "select" })
    }

    public var activeThoughtConfigOption: ConfigOption? {
        activeConfigOptions.first(where: { $0.category == "thought_level" && $0.type == "select" })
    }

    public var activeModeConfigOption: ConfigOption? {
        activeConfigOptions.first(where: { $0.category == "mode" && $0.type == "select" })
    }

    public var activeBooleanConfigOptions: [ConfigOption] {
        activeConfigOptions.filter { $0.type == "boolean" }
    }

    public var activeOtherSelectConfigOptions: [ConfigOption] {
        activeConfigOptions.filter {
            $0.type == "select" && $0.category != "model" && $0.category != "mode" && $0.category != "thought_level"
        }
    }

    public var activeAllowsAutoEffort: Bool {
        guard let thoughtOpt = activeThoughtConfigOption else { return true }
        return thoughtOpt.choices?.contains(where: { $0.value.lowercased() == "auto" }) ?? false
    }

    public var activeModeChoices: [PrismModeOption] {
        guard let modeOpt = activeModeConfigOption, let choices = modeOpt.choices else { return [] }
        return choices.map {
            PrismModeOption(
                id: $0.value,
                name: $0.name,
                description: $0.description ?? "",
                look: Self.modeLookKind(for: $0.value)
            )
        }
    }

    public var activeModeValue: String? {
        activeModeConfigOption?.value.stringValue
    }

    public var activeModeLook: PrismModeLook {
        Self.modeLookKind(for: activeModeValue)
    }

    public var activeModeDisplayName: String? {
        guard let opt = activeModeConfigOption, let val = opt.value.stringValue else { return nil }
        return opt.choices?.first(where: { $0.value == val })?.name ?? val
    }

    /// Pending mode switch (e.g. agy waiting for turn/background to finish before switching to Full access).
    public var activePendingModeSwitch: (option: ConfigOption, pending: PendingConfig, targetName: String)? {
        guard !showStudioHome,
              let opt = activeModeConfigOption,
              let pending = opt.pending
        else { return nil }
        let targetName = opt.choices?.first(where: { $0.value == pending.value })?.name ?? pending.value
        return (opt, pending, targetName)
    }

    public func cancelPendingModeSwitch() async {
        guard let opt = activeModeConfigOption,
              let currentVal = opt.value.stringValue
        else { return }
        await applyModeChoice(currentVal)
    }

    /// Ephemeral next-message suggestion for the active ready session when the composer is empty.
    public var activeSessionSuggestion: String? {
        guard !showStudioHome,
              let replica = activeReplica,
              replica.session.status == .ready,
              let raw = replica.session.suggestion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    /// Whether editing from a sent message on the active session also reverts modified files (e.g. OpenCode).
    public var canRewindActiveFiles: Bool {
        guard let sid = selectedSessionSummary?.agentId else { return false }
        return agents.first(where: { $0.id == sid })?.capabilities?.rewindFiles == true
    }

    public var activeModelSelectionID: String {
        if let opt = activeModelConfigOption, let val = opt.value.stringValue {
            return opt.choices?.first(where: { $0.value == val })?.shownAs ?? val
        }
        return activeConfigAgentID
    }

    public func resolveEffort(for config: [ConfigOption]) -> PrismEffortResolved? {
        guard let thoughtOpt = config.first(where: { $0.category == "thought_level" && $0.type == "select" }),
              let rawChoices = thoughtOpt.choices,
              !rawChoices.isEmpty
        else { return nil }
        let modelVal = config.first(where: { $0.category == "model" && $0.type == "select" })?.value.stringValue
        return PrismEffortLevelResolver.resolve(
            optionId: thoughtOpt.id,
            optionName: thoughtOpt.name,
            choices: rawChoices.map {
                PrismEffortLevelResolver.RawChoice(value: $0.value, name: $0.name, description: $0.description)
            },
            currentValue: thoughtOpt.value.stringValue,
            modelValue: modelVal
        )
    }

    public var activeEffortResolved: PrismEffortResolved? {
        resolveEffort(for: activeConfigOptions)
    }

    public var activeEffortDisplayLabel: String? {
        activeEffortResolved?.selectedOption?.label
    }

    public var activeEffortTier: PrismEffortTier {
        activeEffortResolved?.selectedOption?.tier ?? .normal
    }

    public var activeThoughtDisplayName: String? {
        activeEffortDisplayLabel
    }

    public var pendingSwitchSummaryText: String? {
        guard pendingSwitchAgentID != nil else { return nil }
        var parts: [String] = []
        if let m = activeModelConfigOption, let v = m.value.stringValue {
            let shown = m.choices?.first(where: { $0.value == v })?.shownAs ?? v
            let name = m.choices?.first(where: { $0.value == shown })?.name ?? v
            parts.append(name)
        }
        if let mode = activeModeDisplayName {
            parts.append(mode)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True for cooperative Swift Task cancellation or URLSession cancellation, which are normal
    /// lifecycle events (host switch, view disappear, superseded request) and must never surface
    /// as red error banners in the composer or host list.
    public static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlErr = error as? URLError, urlErr.code == .cancelled { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    internal func reportConnectionError(_ error: Error) {
        guard !Self.isCancellationError(error), !Task.isCancelled else { return }
        connectionError = error.localizedDescription
    }

    public var activeSessionError: String? {
        if let attachErr = attachmentBannerError, !attachErr.isEmpty {
            return attachErr
        }
        if !showStudioHome, let err = activeReplica?.session.error {
            if let detail = err.detail, !detail.isEmpty {
                return "\(err.message) (\(detail))"
            }
            return err.message
        }
        return connectionError
    }

    // MARK: - Draft Attachment State & Operations

    public var activeAttachmentScope: String {
        if showStudioHome || selectedSessionSummary == nil {
            return "__studio__"
        }
        return selectedSessionSummary?.id ?? "__studio__"
    }

    public var activeDraftAttachments: [DraftAttachmentItem] {
        draftAttachmentsByScope[activeAttachmentScope] ?? []
    }

    public var hasUploadingAttachments: Bool {
        activeDraftAttachments.contains(where: \.isPreparing)
    }

    public var hasFailedAttachments: Bool {
        activeDraftAttachments.contains { $0.failureMessage != nil }
    }

    public var hasReadyAttachments: Bool {
        activeDraftAttachments.contains { $0.readyAttachment != nil }
    }

    public func canSendDraft(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || hasReadyAttachments || !activeDraftComments.isEmpty else { return false }
        guard !hasUploadingAttachments && !hasFailedAttachments else { return false }
        let combined = ComposerComments.commentsMessage(comments: activeDraftComments, text: trimmed)
        let textBytes = combined.utf8.count
        let attachBytes = activeDraftAttachments.reduce(0) { $0 + $1.estimatedPromptBytes }
        return textBytes + attachBytes <= AttachmentLimits.maxPromptBytes
    }

    /// Explains why a non-empty draft cannot be sent right now, and whether waiting for uploading
    /// attachments alone is what holds it back (so Enter can arm an auto-send).
    public func sendBlockingReason(text: String, isNewSessionStage: Bool) -> (reason: String, waitingForUpload: Bool)? {
        if !isNewSessionStage && activeReplica?.session.status == .starting {
            let agentName = agentDisplayName(for: selectedSessionSummary?.agentId ?? selectedAgentID)
            return (l10n.tr("composer.blocked.waitForStart", agentName), false)
        }
        if !isNewSessionStage && activeHeldOutside {
            return (l10n.tr("composer.heldOutside"), false)
        }
        if hasFailedAttachments {
            return (l10n.tr("composer.attachmentsRemoveFailed"), false)
        }
        if hasUploadingAttachments {
            return (l10n.tr("composer.attachmentsUploading"), true)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = ComposerComments.commentsMessage(comments: activeDraftComments, text: trimmed)
        let attachBytes = activeDraftAttachments.reduce(0) { $0 + $1.estimatedPromptBytes }
        if combined.utf8.count + attachBytes > AttachmentLimits.maxPromptBytes {
            return (l10n.tr("composer.attachmentsPromptTooLarge"), false)
        }
        return nil
    }

    public struct PendingFileAttachmentJob: Sendable {
        public let scope: String
        public let itemID: UUID
        public let url: URL
    }

    /// Registers preparing placeholders for up to `maxAttachments` files on `@MainActor` so callers
    /// (such as iOS `.fileImporter`) can acquire security-scoped access synchronously before detaching.
    public func registerPendingFileAttachments(urls: [URL]) -> [PendingFileAttachmentJob] {
        guard !urls.isEmpty else { return [] }
        let scope = activeAttachmentScope
        attachmentBannerError = nil

        let current = draftAttachmentsByScope[scope] ?? []
        let room = max(0, AttachmentLimits.maxAttachments - current.count)
        guard room > 0 else {
            attachmentBannerError = l10n.tr("composer.attachmentsLimitReached", AttachmentLimits.maxAttachments)
            return []
        }

        let taken = Array(urls.prefix(room))
        if urls.count > room {
            attachmentBannerError = l10n.tr("composer.attachmentsLimitReached", AttachmentLimits.maxAttachments)
        }

        var nextItems = current
        var jobs: [PendingFileAttachmentJob] = []
        for url in taken {
            let id = UUID()
            let isImg = AttachmentPreparer.looksLikeImage(url: url)
            let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
            let placeholder = DraftAttachmentItem(
                id: id,
                name: name,
                kind: isImg ? .image : .file,
                mimeType: isImg ? "image/png" : "application/octet-stream",
                size: 0,
                status: .preparing
            )
            nextItems.append(placeholder)
            jobs.append(PendingFileAttachmentJob(scope: scope, itemID: id, url: url))
        }
        draftAttachmentsByScope[scope] = nextItems
        return jobs
    }

    public func completePreparedAttachment(
        scope: String,
        itemID: UUID,
        result: Result<PreparedAttachmentPayload, Error>
    ) async {
        switch result {
        case .success(let prepared):
            await uploadPreparedAttachment(scope: scope, itemID: itemID, prepared: prepared)
        case .failure(let prepErr as AttachmentPrepareError):
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.localizedPrepareError(prepErr))
            }
        case .failure(let error):
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    public func attachFiles(urls: [URL]) {
        let jobs = registerPendingFileAttachments(urls: urls)
        for job in jobs {
            let url = job.url
            let scope = job.scope
            let itemID = job.itemID
            let accessed = url.startAccessingSecurityScopedResource()
            Task.detached(priority: .userInitiated) { [weak self] in
                let result: Result<PreparedAttachmentPayload, Error>
                do {
                    defer {
                        if accessed {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let prepared = try AttachmentPreparer.prepareFile(url: url, manageSecurityScope: false)
                    result = .success(prepared)
                } catch {
                    result = .failure(error)
                }
                await self?.completePreparedAttachment(scope: scope, itemID: itemID, result: result)
            }
        }
    }

    public func attachImageData(_ data: Data, suggestedName: String? = nil) {
        guard !data.isEmpty else { return }
        let scope = activeAttachmentScope
        attachmentBannerError = nil

        let current = draftAttachmentsByScope[scope] ?? []
        guard current.count < AttachmentLimits.maxAttachments else {
            attachmentBannerError = l10n.tr("composer.attachmentsLimitReached", AttachmentLimits.maxAttachments)
            return
        }

        let imageIndex = current.filter { $0.kind == .image }.count + 1
        let name = suggestedName ?? "image-\(imageIndex).png"
        let id = UUID()
        let placeholder = DraftAttachmentItem(
            id: id,
            name: name,
            kind: .image,
            mimeType: "image/png",
            size: data.count,
            status: .preparing
        )
        draftAttachmentsByScope[scope] = current + [placeholder]

        Task { [weak self] in
            await self?.prepareAndUploadImageData(scope: scope, itemID: id, data: data, name: name)
        }
    }

    public func removeDraftAttachment(id: UUID) {
        let scope = activeAttachmentScope
        guard var list = draftAttachmentsByScope[scope],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        let removed = list.remove(at: idx)
        draftAttachmentsByScope[scope] = list
        persistDraft(scope: scope)

        if !list.contains(where: { $0.failureMessage != nil }) {
            attachmentBannerError = nil
        }

        if !removed.goneOnHost, let uploaded = removed.readyAttachment, let host = hostSession {
            Task { try? await host.removeAttachment(id: uploaded.id) }
        }
    }

    public func attachPastedText(_ text: String) {
        guard !text.isEmpty else { return }
        let scope = activeAttachmentScope
        attachmentBannerError = nil

        let current = draftAttachmentsByScope[scope] ?? []
        guard current.count < AttachmentLimits.maxAttachments else {
            attachmentBannerError = l10n.tr("composer.attachmentsLimitReached", AttachmentLimits.maxAttachments)
            return
        }

        let number = current.filter { $0.kind == .text }.count + 1
        let name = l10n.tr("composer.attachments.pastedTextName", number)
        let bytes = Data(text.utf8)
        let thumb = ComposerAttachmentRules.textThumb(text)
        let id = UUID()
        let placeholder = DraftAttachmentItem(
            id: id,
            name: name,
            kind: .text,
            mimeType: "text/plain",
            size: bytes.count,
            status: .preparing,
            thumbDataURL: thumb,
            pastedTextBody: text
        )
        draftAttachmentsByScope[scope] = current + [placeholder]

        Task { [weak self] in
            await self?.uploadPastedTextAttachment(scope: scope, itemID: id, name: name, bytes: bytes, thumb: thumb)
        }
    }

    private func uploadPastedTextAttachment(
        scope: String,
        itemID: UUID,
        name: String,
        bytes: Data,
        thumb: String
    ) async {
        guard let hostSession else {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.l10n.tr("error.daemonNotConnected"))
            }
            return
        }
        do {
            let uploaded = try await hostSession.addAttachment(
                bytes: bytes,
                mimeType: "text/plain",
                name: name,
                thumb: thumb
            )
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else {
                try? await hostSession.removeAttachment(id: uploaded.id)
                return
            }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .ready(uploaded)
                if let sz = uploaded.size { item.size = sz }
            }
        } catch {
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else { return }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    public func readDraftAttachmentText(_ item: DraftAttachmentItem) async -> String? {
        if let local = item.pastedTextBody {
            return local
        }
        guard let id = item.readyAttachment?.id, let hostSession else { return nil }
        guard let data = try? await hostSession.readAttachment(id: id) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func readProjectFileText(projectPath: String, relativePath: String) async -> String? {
        guard !projectPath.isEmpty, !relativePath.isEmpty, let hostSession else { return nil }
        guard let content = try? await hostSession.filesRead(
            projectPath: projectPath,
            path: relativePath,
            asText: true
        ) else { return nil }
        if case .text(_, _, let text, _, _) = content {
            return text
        }
        return nil
    }

    @discardableResult
    public func attachProjectFile(relativePath: String, isFolder: Bool = false) -> UUID? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let scope = activeAttachmentScope
        attachmentBannerError = nil

        let current = draftAttachmentsByScope[scope] ?? []
        if let existing = current.first(where: { $0.projectRelativePath == trimmed }) {
            return existing.id
        }
        guard current.count < AttachmentLimits.maxAttachments else {
            attachmentBannerError = l10n.tr("composer.attachmentsLimitReached", AttachmentLimits.maxAttachments)
            return nil
        }

        let id = UUID()
        let name = (trimmed as NSString).lastPathComponent
        let isImg = !isFolder && AttachmentPreparer.looksLikeImage(url: URL(fileURLWithPath: trimmed))
        let placeholder = DraftAttachmentItem(
            id: id,
            name: name.isEmpty ? trimmed : name,
            kind: isFolder ? .folder : (isImg ? .image : .file),
            mimeType: isFolder ? "inode/directory" : (isImg ? "image/png" : "text/plain"),
            size: 0,
            status: .preparing,
            projectRelativePath: trimmed
        )
        draftAttachmentsByScope[scope] = current + [placeholder]

        let projectPath = activeTrayProjectPath ?? workspace.activeProjectPath
        guard !projectPath.isEmpty else { return id }
        Task { [weak self] in
            await self?.uploadProjectFileAttachment(scope: scope, itemID: id, projectPath: projectPath, relativePath: trimmed)
        }
        return id
    }

    private func uploadProjectFileAttachment(
        scope: String,
        itemID: UUID,
        projectPath: String,
        relativePath: String
    ) async {
        guard let hostSession else {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.l10n.tr("error.daemonNotConnected"))
            }
            return
        }
        do {
            let uploaded = try await hostSession.addProjectAttachment(projectPath: projectPath, path: relativePath)
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else {
                try? await hostSession.removeAttachment(id: uploaded.id)
                return
            }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.name = uploaded.name
                switch uploaded.type {
                case "image": item.kind = .image
                case "folder": item.kind = .folder
                case "text": item.kind = .text
                default: item.kind = .file
                }
                item.mimeType = uploaded.mimeType ?? item.mimeType
                item.size = uploaded.size ?? 0
                item.thumbDataURL = uploaded.thumb
                item.thumbnailData = PrismImageDecoder.decodeDataURL(uploaded.thumb)
                item.status = .ready(uploaded)
            }
        } catch {
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else { return }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    private func prepareAndUploadFile(scope: String, itemID: UUID, url: URL) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AttachmentPreparer.prepareFile(url: url)
            }.value
            await uploadPreparedAttachment(scope: scope, itemID: itemID, prepared: prepared)
        } catch let prepErr as AttachmentPrepareError {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.localizedPrepareError(prepErr))
            }
        } catch {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    private func prepareAndUploadImageData(scope: String, itemID: UUID, data: Data, name: String) async {
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try AttachmentPreparer.prepareImage(data: data, name: name)
            }.value
            await uploadPreparedAttachment(scope: scope, itemID: itemID, prepared: prepared)
        } catch let prepErr as AttachmentPrepareError {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.localizedPrepareError(prepErr))
            }
        } catch {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    private func uploadPreparedAttachment(
        scope: String,
        itemID: UUID,
        prepared: PreparedAttachmentPayload
    ) async {
        guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else { return }

        updateDraftAttachment(scope: scope, itemID: itemID) { item in
            item.name = prepared.name
            item.kind = prepared.kind
            item.mimeType = prepared.mimeType
            item.size = prepared.bytes.count
            item.thumbnailData = prepared.thumbnailData
            item.thumbDataURL = prepared.thumbDataURL
            item.pixelWidth = prepared.pixelWidth
            item.pixelHeight = prepared.pixelHeight
            if prepared.kind == .image {
                item.previewImageData = prepared.bytes
            }
        }

        guard let hostSession else {
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(self.l10n.tr("error.daemonNotConnected"))
            }
            return
        }

        do {
            let uploaded = try await hostSession.addAttachment(
                bytes: prepared.bytes,
                mimeType: prepared.mimeType,
                name: prepared.name,
                thumb: prepared.thumbDataURL
            )
            // User removed the tile while upload was in flight: clean up host record immediately.
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else {
                try? await hostSession.removeAttachment(id: uploaded.id)
                return
            }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .ready(uploaded)
                if let sz = uploaded.size { item.size = sz }
            }
        } catch {
            guard isDraftAttachmentStillHeld(scope: scope, itemID: itemID) else { return }
            updateDraftAttachment(scope: scope, itemID: itemID) { item in
                item.status = .failed(error.localizedDescription)
            }
        }
    }

    private func isDraftAttachmentStillHeld(scope: String, itemID: UUID) -> Bool {
        draftAttachmentsByScope[scope]?.contains(where: { $0.id == itemID }) ?? false
    }

    private func updateDraftAttachment(
        scope: String,
        itemID: UUID,
        mutate: (inout DraftAttachmentItem) -> Void
    ) {
        guard var list = draftAttachmentsByScope[scope],
              let idx = list.firstIndex(where: { $0.id == itemID })
        else { return }
        mutate(&list[idx])
        draftAttachmentsByScope[scope] = list
        persistDraft(scope: scope)
    }

    private func localizedPrepareError(_ err: AttachmentPrepareError) -> String {
        switch err {
        case .tooLarge: return l10n.tr("composer.attachmentsTooLarge")
        case .unreadable, .empty, .directoryNotSupported: return l10n.tr("composer.attachmentsUnreadable")
        }
    }

    public func loadSessionBlob(sessionId: String, hash: String) async -> Data? {
        let key = "\(sessionId):\(hash)"
        if let cached = sessionBlobCache[key] {
            if let idx = sessionBlobOrder.firstIndex(of: key) {
                sessionBlobOrder.remove(at: idx)
            }
            sessionBlobOrder.append(key)
            return cached
        }
        guard let hostSession else { return nil }
        guard let blob = try? await hostSession.readSessionBlob(sessionId: sessionId, hash: hash) else {
            return nil
        }
        insertCachedSessionBlob(key: key, data: blob.data)
        return blob.data
    }

    /// Fetches the full payload of a digested tool entry via `sessions.entry` and updates the cached replica in place.
    public func hydrateToolEntry(sessionId: String, entryId: String) async {
        let key = "\(sessionId)::\(entryId)"
        guard !inFlightEntryHydrations.contains(key) else { return }
        guard let targetSession = hostSession else { return }
        if case .tool(let existing)? = replicas[sessionId]?.byId[entryId], !existing.hasDigestedContent {
            return
        }
        inFlightEntryHydrations.insert(key)
        defer { inFlightEntryHydrations.remove(key) }

        guard let fullEntry = try? await targetSession.sessionEntry(sessionId: sessionId, entryId: entryId) else {
            return
        }
        guard self.hostSession === targetSession else { return }
        _ = mutateReplica(sessionId) { replica in
            replica.replaceHydratedEntry(fullEntry)
        }
    }

    private func insertCachedSessionBlob(key: String, data: Data) {
        guard data.count <= Self.maxBlobCacheBytes else { return }
        if let existing = sessionBlobCache.removeValue(forKey: key) {
            sessionBlobTotalBytes -= existing.count
            sessionBlobOrder.removeAll { $0 == key }
        }
        while !sessionBlobOrder.isEmpty
            && (sessionBlobOrder.count >= Self.maxBlobCacheEntries
                || sessionBlobTotalBytes + data.count > Self.maxBlobCacheBytes) {
            let oldestKey = sessionBlobOrder.removeFirst()
            if let evicted = sessionBlobCache.removeValue(forKey: oldestKey) {
                sessionBlobTotalBytes -= evicted.count
            }
        }
        sessionBlobCache[key] = data
        sessionBlobOrder.append(key)
        sessionBlobTotalBytes += data.count
    }

    private func evictSessionBlobs(forSessionId sessionId: String) {
        let prefix = "\(sessionId):"
        let keysToRemove = sessionBlobOrder.filter { $0.hasPrefix(prefix) }
        guard !keysToRemove.isEmpty else { return }
        sessionBlobOrder.removeAll { $0.hasPrefix(prefix) }
        for key in keysToRemove {
            if let removed = sessionBlobCache.removeValue(forKey: key) {
                sessionBlobTotalBytes = max(0, sessionBlobTotalBytes - removed.count)
            }
        }
    }

    /// Ordered, registered non-disabled agents detected by Sarto daemon.
    public var selectableAgents: [AgentStatusInfo] {
        let priority: [String: Int] = [
            "antigravity": 0,
            "claude-code": 1,
            "codex": 2,
            "pi": 3,
            "opencode": 4,
            "cursor": 5,
            "gemini": 6,
            "cline": 7,
        ]
        let nonDisabled = agents.filter { ($0.disabled ?? false) == false && ($0.hidden ?? false) == false }
        let registered = nonDisabled.filter { agent in
            if let reg = agent.registered { return reg }
            return agent.state != "not-installed"
        }
        let base = registered.isEmpty ? nonDisabled : registered
        return base.sorted { lhs, rhs in
            let lReady = lhs.state != "not-installed"
            let rReady = rhs.state != "not-installed"
            if lReady != rReady { return lReady }
            let lPrio = priority[lhs.id] ?? 100
            let rPrio = priority[rhs.id] ?? 100
            if lPrio != rPrio { return lPrio < rPrio }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public var activeModelDisplayName: String {
        if let opt = activeModelConfigOption, let val = opt.value.stringValue {
            let resolvedVal = opt.choices?.first(where: { $0.value == val })?.shownAs ?? val
            if let choice = opt.choices?.first(where: { $0.value == resolvedVal }) {
                return choice.name
            }
            return val
        }
        let targetID = activeConfigAgentID
        if let known = agents.first(where: { $0.id == targetID }) {
            return targetID == "antigravity" ? "Antigravity" : known.name
        }
        switch targetID {
        case "antigravity": return "Antigravity"
        case "claude-code": return "Claude Code"
        case "codex": return "Codex CLI"
        case "opencode": return "OpenCode"
        case "pi": return "Pi RPC"
        default: return targetID
        }
    }

    public var activeAccountBadge: String? {
        for agent in selectableAgents {
            if let label = agent.account?.label, !label.isEmpty {
                return label
            }
        }
        return nil
    }

    public func agentDisplayName(for agentId: String) -> String {
        if let known = agents.first(where: { $0.id == agentId }) {
            return agentId == "antigravity" ? "Antigravity" : known.name
        }
        switch agentId {
        case "antigravity": return "Antigravity"
        case "claude-code": return "Claude Code"
        case "codex": return "Codex CLI"
        case "opencode": return "OpenCode"
        case "pi": return "Pi RPC"
        default: return agentId
        }
    }

    public func refreshActiveContextBreakdown() async {
        guard !showStudioHome,
              let sid = selectedSessionSummary?.id,
              let hostSession
        else { return }
        isLoadingContextBreakdown = true
        defer { isLoadingContextBreakdown = false }
        async let breakdownTask = hostSession.sessionContext(sessionId: sid)
        async let estimatesTask = hostSession.sessionContextEstimates(sessionId: sid)
        if let breakdown = try? await breakdownTask {
            contextBreakdownBySession[sid] = breakdown
        }
        if let estimates = try? await estimatesTask {
            contextEstimatesBySession[sid] = estimates
        }
    }

    /// Real per-session token breakdown: prefers Sarto's detailed `sessions.context` categories
    /// (System, Tools, MCP, Memory, Messages, Buffer) and falls back to `session.usage.tokens`.
    public var activeContextStrata: [ContextStratum] {
        if !showStudioHome,
           let sid = selectedSessionSummary?.id,
           let breakdown = contextBreakdownBySession[sid],
           !breakdown.categories.isEmpty {
            let visible = breakdown.categories.filter { cat in
                let lower = cat.name.lowercased()
                return cat.tokens > 0 && !lower.contains("free space") && !lower.contains("剩余")
            }
            if !visible.isEmpty {
                let denom = max(1, breakdown.size > 0 ? breakdown.size : visible.reduce(0) { $0 + $1.tokens })
                let palette: [Color] = [
                    Color(hex: 0x1B49B2),
                    Color(hex: 0x3186FF),
                    Color(hex: 0x8B5CF6),
                    Color(hex: 0x06B6D4),
                    Color(hex: 0x5CC6FC),
                    Color(hex: 0xF59E0B),
                ]
                return visible.enumerated().map { idx, cat in
                    ContextStratum(
                        id: idx,
                        title: cat.name,
                        tokens: cat.tokens,
                        ratio: max(0, min(1, cat.share ?? (cat.tokens / denom))),
                        color: palette[idx % palette.count]
                    )
                }
            }
        }
        guard let tok = activeReplica?.session.usage?.tokens else { return [] }
        let input = max(0, tok.input)
        let cacheRead = max(0, tok.cacheRead ?? 0)
        let outputAndThought = max(0, tok.output + (tok.thought ?? 0))
        let total = max(1, input + cacheRead + outputAndThought)
        return [
            ContextStratum(id: 0, title: l10n.tr("popover.strata.input"), tokens: input, ratio: input / total, color: Color(hex: 0x1B49B2)),
            ContextStratum(id: 1, title: l10n.tr("popover.strata.cacheRead"), tokens: cacheRead, ratio: cacheRead / total, color: Color(hex: 0x3186FF)),
            ContextStratum(id: 2, title: l10n.tr("popover.strata.output"), tokens: outputAndThought, ratio: outputAndThought / total, color: Color(hex: 0x5CC6FC)),
        ]
    }

    /// Detailed collapsible context lists from `sessions.context` (`lists`: MCP tools, Skills,
    /// Memory files, System files) enriched with `sessions.contextEstimates` when lists are absent.
    public var activeContextDetailLists: [ContextDetailList] {
        guard !showStudioHome, let sid = selectedSessionSummary?.id else { return [] }
        var out: [ContextDetailList] = []
        if let breakdown = contextBreakdownBySession[sid] {
            for list in breakdown.lists where !list.items.isEmpty {
                out.append(ContextDetailList(
                    name: list.name,
                    items: list.items.map { item in
                        ContextDetailItem(
                            name: item.name,
                            detail: item.detail,
                            tokensText: item.tokens
                        )
                    }
                ))
            }
        }
        if let est = contextEstimatesBySession[sid] {
            let existingNames = Set(out.map { $0.name.lowercased() })
            if let servers = est.mcpServers, !servers.isEmpty,
               !existingNames.contains(where: { $0.contains("mcp") }) {
                out.append(ContextDetailList(
                    id: "est:mcp",
                    name: l10n.tr("popover.contextMcpEstimates"),
                    items: servers.map { s in
                        ContextDetailItem(
                            name: s.name,
                            detail: nil,
                            tokensText: s.tokens.map { PrismTelemetryFormat.compactTokens($0) } ?? ""
                        )
                    }
                ))
            }
            if let skills = est.skills, !skills.isEmpty,
               !existingNames.contains(where: { $0.contains("skill") }) {
                out.append(ContextDetailList(
                    id: "est:skills",
                    name: l10n.tr("popover.contextSkillEstimates"),
                    items: skills.map { s in
                        ContextDetailItem(
                            name: s.name,
                            detail: nil,
                            tokensText: s.tokens.map { PrismTelemetryFormat.compactTokens($0) } ?? ""
                        )
                    }
                ))
            }
        }
        return out
    }

    /// Real vendor subscription quota windows from `agents.list` / `agents.refreshLimits`.
    public var studioQuotaPools: [StudioQuotaPool] {
        var pools: [(priority: Int, pool: StudioQuotaPool)] = []
        let nowMs = Date().timeIntervalSince1970 * 1000.0

        for agent in selectableAgents {
            guard let limits = agent.limits, !limits.isEmpty else { continue }
            let brand = brandKey(for: agent.id)
            for lim in limits {
                let used = lim.usedPercent ?? 0
                let rem = max(0, min(100, 100 - used))
                let isFiveHour = lim.window.hasPrefix("five_hour")
                let cleanName = lim.label
                    .replacingOccurrences(of: "5-hour · ", with: "5h · ")
                    .replacingOccurrences(of: "Weekly · ", with: "7d · ")
                let resetStr = formatResetCountdown(resetsAtMs: lim.resetsAt, nowMs: nowMs, fallback: isFiveHour ? "5h" : "7d")
                pools.append((
                    priority: isFiveHour ? 0 : 1,
                    pool: StudioQuotaPool(
                        id: "\(agent.id)-\(lim.window)",
                        name: cleanName,
                        brand: brand,
                        remainingPercent: rem,
                        resetLabel: resetStr
                    )
                ))
            }
        }

        return pools
            .sorted { $0.priority < $1.priority }
            .prefix(4)
            .map(\.pool)
    }

    private func formatResetCountdown(resetsAtMs: Double?, nowMs: Double, fallback: String) -> String {
        guard let resetsAtMs, resetsAtMs > nowMs else { return fallback }
        let sec = Int((resetsAtMs - nowMs) / 1000.0)
        if sec < 60 { return "<1m" }
        let mins = sec / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        let remMins = mins % 60
        if hours < 24 { return remMins > 0 ? "\(hours)h \(remMins)m" : "\(hours)h" }
        let days = hours / 24
        let remHours = hours % 24
        return remHours > 0 ? "\(days)d \(remHours)h" : "\(days)d"
    }

    private func brandKey(for agentId: String) -> String {
        if agentId.contains("antigravity") || agentId.contains("gemini") { return "antigravity" }
        if agentId.contains("claude") { return "claude" }
        if agentId.contains("codex") { return "codex" }
        return "opencode"
    }

    private func priorityRank(_ s: SessionSummary) -> Int {
        if s.status == .awaitingPermission || s.permissionCount > 0 { return 0 }
        if s.status == .failed || s.status == .authRequired { return 1 }
        if s.status == .running || s.status == .starting { return 2 }
        return 3
    }

    // MARK: - Attaching Live Sarto Host Sessions

    /// Loads the host's index and makes `session` the live connection. Returns false (and closes
    /// `session` and `terminal`) when loading fails or a newer connect superseded this one.
    @discardableResult
    public func attachLiveSession(
        _ session: SartoHostSession,
        terminal: SartoTerminalSession? = nil,
        mode: ConnectionMode
    ) async -> Bool {
        await attachLiveSession(session, terminal: terminal, mode: mode, cancelsReconnect: true)
    }

    internal func attachLiveSession(
        _ session: SartoHostSession,
        terminal: SartoTerminalSession?,
        mode: ConnectionMode,
        cancelsReconnect: Bool
    ) async -> Bool {
        // The reconnect loop calls in here itself; cancelling it would cancel this very load.
        if cancelsReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let targetHostID: String = {
            if case .localDaemon = mode { return Self.localHostID }
            if daemonOtherHosts != nil, let otherID = lastOtherHostID { return otherID }
            return Self.localHostID
        }()
        let isReattach = Self.isSameHost(lastAttachedMode, mode)
        let previousSelectedID = selectedSessionID
        let previousShowStudioHome = showStudioHome
        let previousAgentID = selectedAgentID

        if daemonOtherHosts != nil && targetHostID != activeHostID && hostSession != nil {
            // Preserve the outgoing host's persistent connection in the multi-host pool.
            saveActiveHostToPool()
            if let oldTarget = hostPool.removeValue(forKey: targetHostID) {
                oldTarget.eventTask?.cancel()
                await Self.close(oldTarget.agent, oldTarget.terminal)
            }
            prefetchTask?.cancel()
            prefetchTask = nil
            for (_, task) in activeOpenTasks { task.cancel() }
            activeOpenTasks.removeAll()
            hostSession = nil
            terminalSession = nil
            eventLoopTask = nil
        } else {
            hostPool.removeValue(forKey: targetHostID)?.eventTask?.cancel()
            await tearDownActiveConnection()
        }
        guard generation == connectionGeneration else {
            await Self.close(session, terminal)
            return false
        }
        isManualDisconnect = false
        connectionMode = .disconnected

        let loadedSessions: [SessionSummary]
        let loadedSessionsCursor: SessionsCursorInfo?
        let loadedAgents: [AgentStatusInfo]
        let loadedAgentOptions: [AgentOptionsInfo]?
        let loadedProjects: [ProjectInfo]
        let loadedNoProject: NoProjectInfo
        do {
            async let sessionsReq = Self.loadSessionIndex(session, current: [], cursor: nil)
            async let agentsReq = session.listAgents()
            async let agentOptionsReq = session.listAgentOptions()
            async let projectsReq = session.listProjects()
            async let noProjectReq = session.noProjectState()
            let index = try await sessionsReq
            loadedSessions = index.sessions
            loadedSessionsCursor = index.cursor
            loadedAgents = (try? await agentsReq) ?? []
            loadedAgentOptions = try? await agentOptionsReq
            loadedProjects = (try? await projectsReq) ?? []
            loadedNoProject = (try? await noProjectReq) ?? NoProjectInfo()
        } catch {
            await Self.close(session, terminal)
            guard generation == connectionGeneration else { return false }
            guard !Self.isCancellationError(error), !Task.isCancelled else { return false }
            connectionError = error.localizedDescription
            statusMessage = error.localizedDescription
            // A path from a remote host must not be read from this Mac's disk.
            let fallbackPath = workspace.isRemoteWorkspace && !mode.isRemote
                ? ""
                : workspace.activeProjectPath
            workspace.attach(host: nil, terminal: nil, projectPath: fallbackPath, hostId: targetHostID, isRemote: mode.isRemote)
            return false
        }
        guard generation == connectionGeneration else {
            await Self.close(session, terminal)
            return false
        }

        activeHostID = targetHostID
        backgroundHostSnapshots.removeValue(forKey: targetHostID)
        lastAttachedMode = mode
        hostSession = session
        terminalSession = terminal
        connectionMode = mode
        connectionError = nil
        statusMessage = nil

        if mode.isRemote {
            devices.attach(remoteHostSession: session)
        } else {
            // Local mode keeps `device-host` strictly lazy: never spawned or polled until
            // the user opens the iOS/Android tab or an agent invokes a `device_*` tool.
            devices.tearDown()
        }

        sessions = loadedSessions
        sessionsCursor = loadedSessionsCursor
        agents = loadedAgents
        if let loadedAgentOptions {
            var map: [String: AgentOptionsInfo] = [:]
            for item in loadedAgentOptions { map[item.agentId] = item }
            agentOptionsById = map
        }
        projects = loadedProjects
        noProjectInfo = loadedNoProject
        replicas.removeAll()
        watchedSessionOrder.removeAll()
        replicaAccessOrder.removeAll()
        inFlightSnapshotSessionIDs.removeAll()
        snapshotRetryBySession.removeAll()
        earlyAttachedSessionIDs.removeAll()
        outlineBySession.removeAll()
        gitStatusByProject.removeAll()
        gitBranchesByProject.removeAll()
        preparedSession = nil
        preparedTargetKey = nil
        isPreparingSession = false

        func isUsable(_ agent: AgentStatusInfo) -> Bool {
            agent.state != "not-installed" && (agent.disabled ?? false) == false
        }
        if isReattach, previousShowStudioHome,
           let kept = agents.first(where: { $0.id == previousAgentID && isUsable($0) }) {
            selectedAgentID = kept.id
        } else if let preferred = defaultAgentID,
                  let match = agents.first(where: { $0.id == preferred && isUsable($0) }) {
            selectedAgentID = match.id
        } else if let agy = agents.first(where: { $0.id == "antigravity" && isUsable($0) }) {
            selectedAgentID = agy.id
        } else if let top = selectableAgents.first(where: { $0.state != "not-installed" }) {
            selectedAgentID = top.id
        }
        if mode.isRemote || !isReattach || !previousShowStudioHome || selectedAgentID != "claude-code" {
            selectedModelHostID = nil
        }

        if newSessionProjectPath == nil {
            newSessionProjectPath = projects.first(where: { !$0.isMissing })?.path ?? projects.first?.path
        }

        // Reconnecting to the same host keeps what the user was looking at when it still exists there.
        let keptSession: SessionSummary? = isReattach && !previousShowStudioHome
            ? previousSelectedID.flatMap { id in sessions.first(where: { $0.id == id }) }
            : nil
        let keepsNewSessionStage = isReattach && previousShowStudioHome
        let initialSession: SessionSummary?
        if let keptSession {
            initialSession = keptSession
        } else if keepsNewSessionStage {
            initialSession = nil
        } else {
            let savedSessionID = UserDefaults.standard.string(forKey: PrefKey.lastSelectedSessionID)
            let restoredTarget = restoreLastSession
                ? savedSessionID.flatMap { id in prioritizedSessions.first(where: { $0.id == id }) }
                : nil
            initialSession = restoredTarget ?? (restoreLastSession ? prioritizedSessions.first : nil)
        }

        let initialPath = initialSession?.projectPath
            ?? (keepsNewSessionStage ? effectiveNewSessionProjectPath : nil)
            ?? projects.first?.path
            ?? ""
        workspace.attach(host: session, terminal: terminal, projectPath: initialPath, hostId: targetHostID, isRemote: mode.isRemote)

        // Register active host into the persistent multi-host pool and start consuming events before
        // the selection's round trips so none queue up behind them.
        let activeSlot = HostPoolSlot(
            hostId: targetHostID,
            isLocal: targetHostID == Self.localHostID,
            agent: session,
            terminal: terminal,
            mode: mode
        )
        activeSlot.sessions = loadedSessions
        activeSlot.projects = loadedProjects
        activeSlot.noProjectInfo = loadedNoProject
        activeSlot.agents = loadedAgents
        activeSlot.agentOptionsById = agentOptionsById
        activeSlot.isLoaded = true
        hostPool[targetHostID] = activeSlot
        startPooledEventLoop(for: targetHostID, session: session)

        if targetHostID == Self.localHostID {
            onLocalDaemonAttached?()
        }
        if daemonOtherHosts != nil && !otherHosts.isEmpty {
            reconcileRemoteHostPool(with: otherHosts)
        }

        if let target = initialSession {
            await selectSession(target.id)
        } else if keepsNewSessionStage {
            let parentId = newSessionParentID.flatMap { id in sessionSummary(for: id) != nil ? id : nil }
            openNewSession(
                projectPath: newSessionIsScratch ? nil : newSessionProjectPath,
                scratch: newSessionIsScratch,
                parentId: parentId
            )
        } else {
            openNewSession(projectPath: newSessionProjectPath, scratch: newSessionProjectPath == nil)
        }
        guard generation == connectionGeneration else { return true }

        // Fetch real 26-week usage history & real vendor quota pools asynchronously,
        // and gently warm the next top 3 recent sessions so first-time tab switches are instant.
        Task { [weak self] in
            await self?.refreshUsageSummary()
            await self?.refreshAgentLimits()
            await self?.verifyRestoredDraftAttachments(host: session)
        }
        scheduleRecentSessionPrefetch(excluding: initialSession?.id)
        return true
    }

    private static func isSameHost(_ previous: ConnectionMode?, _ next: ConnectionMode) -> Bool {
        switch (previous, next) {
        case (.localDaemon?, .localDaemon):
            return true
        case (.remoteHost(let previousName, _)?, .remoteHost(let nextName, _)):
            return previousName == nextName
        default:
            return false
        }
    }

    private static func close(_ session: SartoHostSession, _ terminal: SartoTerminalSession?) async {
        await session.close()
        if let terminal {
            await terminal.close()
        }
    }

    internal func scheduleRecentSessionPrefetch(excluding activeId: String?) {
        prefetchTask?.cancel()
        let candidates = prioritizedSessions
            .filter { $0.id != activeId && $0.archivedAt == nil && $0.origin != "subagent" }
            .prefix(3)
            .map(\.id)
        guard !candidates.isEmpty else { return }
        prefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            for sid in candidates {
                guard let self, !Task.isCancelled, let host = self.hostSession else { return }
                if self.replicas[sid] == nil {
                    self.touchWatchedPool(sid, host: host)
                    async let watchReq: Void = { _ = try? await host.watchSession(sessionId: sid) }()
                    async let snapReq: Void = self.reloadSnapshot(sessionId: sid)
                    _ = await (watchReq, snapReq)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    private func touchWatchedPool(_ sessionId: String, host: SartoHostSession) {
        watchedSessionOrder.removeAll { $0 == sessionId }
        watchedSessionOrder.append(sessionId)
        while watchedSessionOrder.count > Self.maxKeptWatchedSessions {
            let evicted = watchedSessionOrder.removeFirst()
            Task { try? await host.unwatchSession(sessionId: evicted) }
        }
    }

    /// Mutates a cached replica in place through the dictionary's modify accessor, so the thread's
    /// entry storage is never copied and Observation fires once per call.
    @discardableResult
    private func mutateReplica<R>(_ sessionId: String, _ body: (inout ThreadReplica) -> R) -> R? {
        guard replicas[sessionId] != nil else { return nil }
        return body(&replicas[sessionId]!)
    }

    private func touchReplicaCacheOrder(_ sessionId: String) {
        replicaAccessOrder.removeAll { $0 == sessionId }
        replicaAccessOrder.append(sessionId)
        while replicaAccessOrder.count > Self.maxCachedReplicas {
            let candidate = replicaAccessOrder.removeFirst()
            if candidate == selectedSessionID || watchedSessionOrder.contains(candidate) {
                replicaAccessOrder.append(candidate)
                break
            }
            replicas.removeValue(forKey: candidate)
            islandReplicaRevision &+= 1
        }
    }

    private func tearDownActiveConnection() async {
        eventLoopTask?.cancel()
        eventLoopTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        for (_, task) in activeOpenTasks { task.cancel() }
        activeOpenTasks.removeAll()
        watchedSessionOrder.removeAll()
        replicaAccessOrder.removeAll()
        inFlightSnapshotSessionIDs.removeAll()
        snapshotRetryBySession.removeAll()
        let oldHost = hostSession
        let oldTerm = terminalSession
        hostSession = nil
        terminalSession = nil
        devices.tearDown()
        if let oldHost {
            await oldHost.close()
        }
        if let oldTerm {
            await oldTerm.close()
        }
    }

    public func disconnectLive() async {
        isManualDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration &+= 1
        await tearDownActiveConnection()
        await tearDownAllHostPoolSlots()
        connectionMode = .disconnected
        statusMessage = nil
        sessions = []
        sessionsCursor = nil
        replicas = [:]
        agents = []
        studioUsageStats = StudioUsageStats()
        currentTPS = nil
        currentTTFTMs = nil
        currentCacheHit = nil
        workspace.attach(host: nil, terminal: nil, projectPath: "")
    }

    public func refreshUsageSummary() async {
        guard let hostSession else { return }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let dayMs: Double = 86_400_000.0
        let todayMs = todayStart.timeIntervalSince1970 * 1000.0
        var dayStarts: [Double] = []
        dayStarts.reserveCapacity(183)
        for i in stride(from: 181, through: 0, by: -1) {
            dayStarts.append(todayMs - Double(i) * dayMs)
        }
        dayStarts.append(todayMs + dayMs)

        let usageScopeParam = (sartoSyncStatus.isVaultReady && includeRemoteDaemonUsage) ? "all" : "computer"
        guard let summary = try? await hostSession.usageSummary(
            dayStarts: dayStarts,
            from: dayStarts.first ?? todayMs,
            to: dayStarts.last ?? (todayMs + dayMs),
            scope: usageScopeParam
        ) else { return }

        var daily = Array(repeating: 0.0, count: 182)
        var total26w = 0.0
        var total7d = 0.0
        var turns26w = 0
        var turns7d = 0
        var reqs26w = 0
        var sumInput = 0.0
        var sumCacheRead = 0.0

        for row in summary.days {
            let tok = row.totalTokens
            if row.day >= 0 && row.day < 182 {
                daily[row.day] += tok
            }
            total26w += tok
            turns26w += row.turns ?? 0
            reqs26w += row.requests ?? 0
            sumInput += row.input
            sumCacheRead += row.cacheRead ?? 0
            if row.day >= 175 {
                total7d += tok
                turns7d += row.turns ?? 0
            }
        }

        let cachePct: Double? = (sumCacheRead > 0 && (sumInput + sumCacheRead) > 0)
            ? (sumCacheRead / (sumInput + sumCacheRead)) * 100.0
            : nil

        studioUsageStats = StudioUsageStats(
            dailyTokens: daily,
            totalTokens26w: total26w,
            totalTokens7d: total7d,
            totalTurns26w: turns26w,
            totalTurns7d: turns7d,
            totalRequests26w: reqs26w,
            cacheHitPercent: cachePct
        )
    }

    public func refreshAgentLimits() async {
        guard let hostSession else { return }
        let targets = selectableAgents.filter { $0.state != "not-installed" }.prefix(3)
        for agent in targets {
            try? await hostSession.refreshAgentLimits(agentId: agent.id)
        }
        if let refreshed = try? await hostSession.listAgents() {
            self.agents = refreshed
        }
    }

    internal func handleUnexpectedDisconnect(from session: SartoHostSession) async {
        guard hostSession === session, !isManualDisconnect else { return }
        let lostMode = connectionMode
        let oldTerm = terminalSession
        hostSession = nil
        terminalSession = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        for (_, task) in activeOpenTasks { task.cancel() }
        activeOpenTasks.removeAll()
        watchedSessionOrder.removeAll()
        replicaAccessOrder.removeAll()
        inFlightSnapshotSessionIDs.removeAll()
        snapshotRetryBySession.removeAll()
        await session.close()
        if let oldTerm {
            await oldTerm.close()
        }
        connectionMode = .disconnected
        let offlineMsg = l10n.tr("studio.daemonOffline")
        statusMessage = offlineMsg
        connectionError = offlineMsg
        workspace.attach(host: nil, terminal: nil, projectPath: workspace.activeProjectPath, hostId: activeHostID, isRemote: lostMode.isRemote)

        scheduleBoundedReconnect(previousMode: lostMode)
    }

    private func scheduleBoundedReconnect(previousMode: ConnectionMode) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            let delays: [Double] = [1.0, 2.0, 4.0, 8.0, 16.0]
            for (attempt, delaySec) in delays.enumerated() {
                try? await Task.sleep(for: .milliseconds(Int(delaySec * 1000)))
                guard let self, !Task.isCancelled, !self.isManualDisconnect, !self.connectionMode.isLive else {
                    return
                }
                self.statusMessage = "Reconnecting (\(attempt + 1)/\(delays.count))..."
                switch previousMode {
                case .localDaemon(let socketPath):
                    let mode = ConnectionMode.localDaemon(socketPath: socketPath)
                    if let reconnector = self.onReconnectLocalDaemon {
                        if let hosts = try? await reconnector(),
                           await self.attachLiveSession(hosts.agent, terminal: hosts.terminal, mode: mode, cancelsReconnect: false) {
                            return
                        }
                    } else {
                        #if os(macOS)
                        let transport = try? await Task.detached(priority: .userInitiated) {
                            try UnixSocketPortTransport(socketPath: socketPath)
                        }.value
                        if let transport {
                            try? await transport.sendLocalBrowserConnect()
                            let resumed = SartoHostSession(transport: transport)
                            if await self.attachLiveSession(resumed, terminal: nil, mode: mode, cancelsReconnect: false) {
                                return
                            }
                        }
                        #endif
                    }

                case .remoteHost(let name, let viaRelay):
                    if self.daemonOtherHosts != nil {
                        guard let id = self.lastOtherHostID else { return }
                        if await self.connectOtherHost(id: id, name: name, viaRelay: viaRelay, cancelsReconnect: false) {
                            return
                        }
                        continue
                    }
                    guard let host = self.lastConnectedHost else { return }
                    if await self.connectPairedHost(host, cancelsReconnect: false) {
                        return
                    }
                    if self.lastConnectRefusedByRelay {
                        self.statusMessage = self.connectionError
                        return
                    }

                case .disconnected:
                    return
                }
            }
            guard let self, !Task.isCancelled, !self.connectionMode.isLive else { return }
            self.statusMessage = self.l10n.tr("studio.daemonOffline")
        }
    }

    /// Watches the sessions in view again and reads them anew, after the host dropped what it kept.
    private func resyncWatchedSessions() async {
        guard let host = hostSession else { return }
        let ids = watchedSessionOrder
        for sid in ids.reversed() {
            Task { @MainActor [weak self] in
                try? await host.watchSession(sessionId: sid)
                await self?.reloadSnapshot(sessionId: sid, force: true)
            }
        }
        if let id = selectedSessionID, !ids.contains(id) {
            await reloadSnapshot(sessionId: id, force: true)
        }
    }

    /// The daemon has a new session with the host in front: its index and the sessions in view are
    /// read again, since nothing of the old session carries over.
    private func reloadAfterHostLinkReopened() async {
        guard let host = hostSession else { return }
        if let index = try? await Self.loadSessionIndex(host, current: sessions, cursor: sessionsCursor),
           hostSession === host {
            sessions = index.sessions
            sessionsCursor = index.cursor
        }
        if let list = try? await host.listProjects(), hostSession === host {
            projects = list
        }
        await refreshAgentsFromHost()
        await resyncWatchedSessions()
        lastReportedShownSession = nil
        syncReportedShownSessions()
    }

    internal func handleHostEvent(_ event: HostEvent) async {
        switch event {
        case .sessionSummary(let summary):
            // Prepared sessions stay outside the sidebar index until adopted by `sessions.create`.
            if summary.prepared != nil {
                receivePreparedSummary(summary)
                return
            }
            if preparedSession?.id == summary.id {
                preparedSession = nil
                preparedTargetKey = nil
                isPreparingSession = false
            }
            if summary.status == .closed {
                earlyAttachedSessionIDs.remove(summary.id)
            }
            let previousSummary = sessions.first(where: { $0.id == summary.id })
            if let idx = sessions.firstIndex(where: { $0.id == summary.id }) {
                sessions[idx] = summary
            } else {
                sessions.insert(summary, at: 0)
            }
            maybeShowFocusedAttentionNotice(previous: previousSummary, next: summary, hostId: activeHostID)
            if let cached = replicas[summary.id]?.session {
                let unwatchedWaiting = !watchedSessionOrder.contains(summary.id)
                    && (summary.permissionCount > 0 || summary.status == .awaitingPermission)
                    && replicas[summary.id]?.pendingTools.isEmpty == true
                let nextTitle = summary.title ?? cached.title
                if cached.status != summary.status
                    || cached.turnStartedAt != summary.turnStartedAt
                    || cached.title != nextTitle {
                    mutateReplica(summary.id) { replica in
                        replica.session.status = summary.status
                        replica.session.turnStartedAt = summary.turnStartedAt
                        replica.session.title = nextTitle
                    }
                }
                if unwatchedWaiting {
                    // Refresh in background without deleting cached replica (deleting caused blank flash on switch).
                    Task { [weak self] in await self?.reloadSnapshot(sessionId: summary.id) }
                }
            }

        case .sessionPatches(let batch):
            guard let currentSeq = replicas[batch.sessionId]?.seq else { break }
            // Mirror ThreadReplica.apply's no-op cases up front so a replayed batch does not notify observers.
            if batch.seq <= currentSeq { break }
            let applied = (batch.from ?? batch.seq) <= currentSeq + 1
                && mutateReplica(batch.sessionId, { $0.apply(batch) }) == true
            if applied, let replica = replicas[batch.sessionId] {
                if Self.patchesTouchIsland(batch, in: replica) {
                    islandReplicaRevision &+= 1
                }
                if batch.patches.contains(where: { patch in
                    switch patch {
                    case .threadReset: return true
                    case .threadTruncate: return true
                    case .entryAdd(.tool): return true
                    case .entryUpdate(let id, _):
                        if case .tool? = replica.byId[id] { return true }
                        return false
                    default: return false
                    }
                }) {
                    toolVersionBySession[batch.sessionId, default: 0] &+= 1
                }
                // Lazily attach local device-host on the first agent `device_open` / `device_*` call
                // so mobile simulator streams auto-open even when device-host started dormant.
                if !devices.isConnected && devices.canConnectLocal {
                    for patch in batch.patches {
                        if case .entryAdd(.tool(let data)) = patch,
                           Self.isMobileDeviceToolTitle(data.title) {
                            let targetSessionId = batch.sessionId
                            let isOpenCall = data.title.localizedCaseInsensitiveContains("device_open")
                            let hintedPlatform: DevicePlatform? = {
                                guard let raw = data.rawInput else { return nil }
                                if raw.contains("ios") { return .ios }
                                if raw.contains("android") || raw.contains("avd:") { return .android }
                                return nil
                            }()
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                await self.devices.ensureConnectedAndRefresh()
                                if isOpenCall,
                                   let opened = self.devices.devices.first(where: { $0.sessionId == targetSessionId }) {
                                    self.devices.onAgentOpenedDevice?(targetSessionId, opened.platform, opened.id)
                                    await self.devices.startWatching(deviceId: opened.id, sessionId: targetSessionId)
                                } else if isOpenCall, let plat = hintedPlatform, targetSessionId == self.selectedSessionSummary?.id {
                                    self.activePreviewTarget = (plat == .ios) ? .ios : .android
                                    self.browserAutoOpenSessionID = targetSessionId
                                    self.browserAutoOpenRequestToken &+= 1
                                }
                            }
                            break
                        }
                    }
                }
                telemetryTracker.recordBatch(batch, replica: replica)
                if batch.sessionId == selectedSessionSummary?.id {
                    applyTelemetrySnapshot(telemetryTracker.snapshot(for: replica))
                    syncConfigFromReplica(replica)
                }
                if batch.patches.contains(where: {
                    if case .entryAdd(.turnEnd) = $0 { return true }
                    return false
                }) {
                    Task { [weak self] in await self?.refreshUsageSummary() }
                }
            } else if !applied {
                // Reload asynchronously with backoff so a failing snapshot never blocks the host
                // event loop or hammers the host on every incoming patch batch.
                let sid = batch.sessionId
                if activeOpenTasks[sid] == nil && canAutoReloadSnapshot(sessionId: sid) {
                    Task { @MainActor [weak self] in
                        await self?.reloadSnapshot(sessionId: sid, force: false)
                    }
                }
            }

        case .sessionRemoved(let sid):
            if discardedPreparedIDs.remove(sid) != nil {
                return
            }
            if preparedSession?.id == sid {
                preparedSession = nil
                preparedTargetKey = nil
                isPreparingSession = false
                if showStudioHome {
                    Task { [weak self] in await self?.prepareNewSessionIfNeeded() }
                }
                return
            }
            sessions.removeAll { $0.id == sid }
            replicas.removeValue(forKey: sid)
            watchedSessionOrder.removeAll { $0 == sid }
            replicaAccessOrder.removeAll { $0 == sid }
            activeOpenTasks.removeValue(forKey: sid)?.cancel()
            snapshotRetryBySession.removeValue(forKey: sid)
            earlyAttachedSessionIDs.remove(sid)
            browser.removeSession(sid)
            if selectedSessionID == sid {
                if showStudioHome {
                    selectedSessionID = nil
                } else if let next = prioritizedSessions.first {
                    // Go through selectSession so the new selection is watched and loaded.
                    let nextID = next.id
                    selectedSessionID = nextID
                    Task { [weak self] in await self?.selectSession(nextID) }
                } else {
                    selectedSessionID = nil
                    openStudioHome()
                }
            }

        case .agentStatus(let status):
            if let idx = agents.firstIndex(where: { $0.id == status.id }) {
                agents[idx] = status
            } else {
                agents.append(status)
            }

        case .agentOptions(let options):
            agentOptionsById[options.agentId] = options
            if showStudioHome && options.agentId == selectedAgentID {
                syncEffortFromActiveConfig()
            }

        case .agentSignInLink(_, let rawURL):
            if let url = URL(string: rawURL),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                #if os(macOS)
                NSWorkspace.shared.open(url)
                #elseif os(iOS)
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                #endif
            }

        case .projectsChanged(let nextProjects, let nextNoProject):
            projects = nextProjects
            if let nextNoProject {
                noProjectInfo = nextNoProject
            }

        case .filesChanged(let projectPath):
            workspace.handleFilesChanged(projectPath: projectPath)

        case .browserCall(let call):
            let activeHost = self.hostSession
            Task { @MainActor [weak self] in
                guard let self else { return }
                let answer = await self.browser.handleDeviceCall(call)
                try? await activeHost?.browserAnswer(callId: call.callId, answer: answer)
            }

        case .browserOriginDecided(let sessionId, let requestId, let decision):
            browser.handleOriginDecidedFromHost(sessionId: sessionId, requestId: requestId, decision: decision)

        case .browserTurnEnded(let sessionId):
            browser.handleTurnEnded(sessionId: sessionId)

        case .browserAskAnswered(let sessionId, let outcome):
            browser.handleAskAnsweredFromHost(sessionId: sessionId, outcome: outcome)

        case .settingsOpen(let section, let item, let row):
            onHostOpenSettings?(section, item, row)

        case .memoryChanged:
            memoryChangeRevision &+= 1

        case .marketKeysChanged:
            marketKeysChangeRevision &+= 1

        case .marketConnectionChanged(let serverId, let connection, _, let error):
            marketConnectionsByServer[serverId] = connection
            if let error, !error.isEmpty {
                marketConnectionError = error
            } else {
                marketConnectionError = nil
            }

        case .deviceEvent(let evt):
            devices.handleEvent(evt)

        case .resync:
            await resyncWatchedSessions()

        case .hostLinkClosed:
            hostLinkDropped = true
            if case .remoteHost(let name, _) = connectionMode {
                statusMessage = l10n.tr("hosts.linkReconnecting", name)
            }

        case .hostLinkOpen:
            // The first opening only says the session is there; one after a drop is a new session.
            guard hostLinkDropped else { break }
            hostLinkDropped = false
            statusMessage = nil
            await reloadAfterHostLinkReopened()

        case .otherHostsUpdated, .otherHostPairing:
            break

        case .syncUpdated(let status):
            applySyncedStatus(status)

        case .accountUpdated(let status):
            applyAccountStatus(status)

        case .syncUsageUpdated, .usageChanged:
            break

        case .appUpdateState(let status):
            remoteAppUpdateStatusByHost[activeHostID] = status

        case .appUpdateCommand(let action):
            if activeHostID == Self.localHostID {
                onHostAppUpdateCommand?(action)
            }

        case .hostLoad(let load):
            hostLoadsByHostID[activeHostID] = load

        case .gameStatus, .gameFrame:
            // The game comes from the daemon's control connection, never from a host port.
            break

        case .remoteClaudeActiveChanged(let active):
            if activeHostID == Self.localHostID {
                remoteClaudeActiveRuns = active
            }

        case .pairing, .unknown:
            break
        }
    }

    /// Whether a patch batch changes what the Dynamic Island and the running rail read from a
    /// replica: its tool requests, its plan and the session's own fields. Streamed text and tool
    /// output never do.
    static func patchesTouchIsland(_ batch: PatchBatch, in replica: ThreadReplica?) -> Bool {
        batch.patches.contains { patch in
            switch patch {
            case .entryAppendText, .unknown:
                return false
            case .entryAdd(let entry):
                switch entry {
                case .tool, .plan: return true
                default: return false
                }
            case .entryUpdate(let id, let changes):
                switch replica?.byId[id] {
                case .plan?: return true
                case .tool?: return changes["permission"] != nil || changes["status"] != nil
                default: return false
                }
            case .sessionUpdate(let changes):
                return changes["status"] != nil || changes["config"] != nil
                    || changes["title"] != nil || changes["turnStartedAt"] != nil
            case .threadReset, .threadTruncate:
                return true
            }
        }
    }

    // MARK: - New Session Stage, Prepared Sessions & Git Branches

    public func openStudioHome() {
        openNewSession(projectPath: effectiveNewSessionProjectPath, scratch: effectiveNewSessionIsScratch, parentId: nil)
    }

    public func openNewSession(
        projectPath: String? = nil,
        scratch: Bool? = nil,
        parentId: String? = nil,
        agentId: String? = nil
    ) {
        preparedDiscardTask?.cancel()
        preparedDiscardTask = nil
        showStudioHome = true
        workspace.activeSessionID = nil
        connectionError = nil
        newSessionParentID = parentId

        if let parentId, let parent = sessionSummary(for: parentId) {
            newSessionIsScratch = parent.scratch == true
            newSessionProjectPath = parent.scratch == true ? nil : parent.projectPath
            if let agentId {
                if let remoteHostId = Self.remoteClaudeHostID(from: agentId) {
                    selectedAgentID = "claude-code"
                    selectedModelHostID = isViewingRemoteHost ? nil : remoteHostId
                } else {
                    selectedAgentID = agentId
                    selectedModelHostID = nil
                }
            } else {
                selectedAgentID = parent.agentId
                selectedModelHostID = (!isViewingRemoteHost && parent.agentId == "claude-code")
                    ? parent.modelHost?.hostId
                    : nil
            }
        } else {
            if isViewingRemoteHost || selectedAgentID != "claude-code" {
                selectedModelHostID = nil
            }
            if let scratch {
                newSessionIsScratch = scratch
            }
            if let projectPath {
                newSessionProjectPath = projectPath
                if scratch == nil { newSessionIsScratch = false }
            } else if newSessionProjectPath == nil && !newSessionIsScratch {
                newSessionProjectPath = selectedSessionSummary.flatMap { $0.scratch == true ? nil : $0.projectPath }
                    ?? projects.first(where: { !$0.isMissing })?.path
                    ?? projects.first?.path
            }
            if let agentId {
                if let remoteHostId = Self.remoteClaudeHostID(from: agentId) {
                    selectedAgentID = "claude-code"
                    selectedModelHostID = isViewingRemoteHost ? nil : remoteHostId
                } else {
                    selectedAgentID = agentId
                    selectedModelHostID = nil
                }
            } else if selectedModelHostID == nil,
                      let preferred = defaultAgentID,
                      agents.contains(where: { $0.id == preferred && ($0.disabled ?? false) == false }) {
                selectedAgentID = preferred
            }
        }

        if let path = effectiveNewSessionProjectPath, !path.isEmpty {
            Task { [weak self] in
                await self?.workspace.setProjectPath(path)
                await self?.refreshGitMetadata(for: path)
            }
        } else {
            workspace.clearProjectPath()
        }
        syncReportedShownSessions()
        syncEffortFromActiveConfig()
        Task { [weak self] in
            if let self, !self.isViewingRemoteHost, !self.otherHosts.isEmpty {
                await self.refreshRemoteClaudeHosts()
            }
            await self?.prepareNewSessionIfNeeded()
        }
    }

    public func setNewSessionProject(path: String?, scratch: Bool) {
        newSessionParentID = nil
        newSessionIsScratch = scratch
        if !scratch {
            newSessionProjectPath = path
        }
        if let path, !path.isEmpty, !scratch {
            Task { [weak self] in
                await self?.workspace.setProjectPath(path)
                await self?.refreshGitMetadata(for: path)
            }
        } else {
            workspace.clearProjectPath()
        }
        Task { [weak self] in
            await self?.prepareNewSessionIfNeeded()
        }
    }

    public func setNewSessionAgent(_ agentId: String) {
        if let remoteHostId = Self.remoteClaudeHostID(from: agentId) {
            setNewSessionRemoteClaudeHost(isViewingRemoteHost ? nil : remoteHostId)
            return
        }
        selectedModelHostID = nil
        selectedAgentID = agentId
        syncEffortFromActiveConfig()
        Task { [weak self] in
            await self?.prepareNewSessionIfNeeded()
        }
    }

    private func currentPrepareKey() -> String {
        let modelHostKey = (!isViewingRemoteHost && selectedAgentID == "claude-code") ? (selectedModelHostID ?? "") : ""
        return "\(selectedAgentID)|\(modelHostKey)|\(effectiveNewSessionIsScratch ? "__scratch__" : (effectiveNewSessionProjectPath ?? "__none__"))|\(newSessionParentID ?? "")"
    }

    public func prepareNewSessionIfNeeded(replace: Bool = false) async {
        guard showStudioHome, let hostSession else { return }
        let targetModelHostId: String? = (!isViewingRemoteHost && selectedAgentID == "claude-code") ? selectedModelHostID : nil
        if let targetModelHostId {
            if let remote = remoteClaudeHosts.first(where: { $0.hostId == targetModelHostId }),
               !remote.status.isSelectable {
                return
            }
        } else {
            guard let agent = agents.first(where: { $0.id == selectedAgentID }),
                  agent.state == "ready" || agent.state == "available"
            else { return }
        }

        let targetProject: String? = effectiveNewSessionIsScratch ? nil : effectiveNewSessionProjectPath
        if !effectiveNewSessionIsScratch && targetProject == nil { return }

        let key = currentPrepareKey()
        if !replace, preparedTargetKey == key, (isPreparingSession || preparedSession != nil) {
            return
        }

        if let old = preparedSession, preparedTargetKey != key {
            discardPreparedSessionNow(old.id)
        }

        preparedTargetKey = key
        isPreparingSession = true
        preparedSessionError = nil

        let picks = effectiveStartOptionsForNewSession() ?? newSessionOptionPicks[selectedAgentID]
        do {
            let summary = try await hostSession.prepareSession(
                agentId: selectedAgentID,
                projectPath: targetProject,
                parentId: newSessionParentID,
                options: picks?.isEmpty == false ? picks : nil,
                replace: replace,
                modelHostId: targetModelHostId
            )
            guard preparedTargetKey == key else {
                discardPreparedSessionNow(summary.id)
                return
            }
            preparedSession = summary
            isPreparingSession = false
            if showStudioHome {
                if let desired = effectiveStartOptionsForNewSession() {
                    _ = await reconcilePreparedSessionOptions(summary, desired: desired)
                }
                syncEffortFromActiveConfig()
            } else {
                // The user left the new-session stage while this was preparing; selectSession found
                // nothing to discard then, so give the prepared session the same grace period now.
                schedulePreparedDiscard()
            }
        } catch {
            guard preparedTargetKey == key else { return }
            isPreparingSession = false
            preparedSessionError = error.localizedDescription
        }
    }

    /// Ensures a prepared session's live config matches the user's desired start options (model
    /// first, since thought_level choices depend on it). Returns false if any sync fails so the
    /// caller can safely fall back to creating a fresh session with `options`.
    @discardableResult
    private func reconcilePreparedSessionOptions(
        _ summary: SessionSummary,
        desired: [String: JSONValue]
    ) async -> Bool {
        guard let hostSession, !desired.isEmpty else { return true }
        let currentConfig = summary.prepared?.config ?? []
        let currentById = Dictionary(uniqueKeysWithValues: currentConfig.map { ($0.id, $0) })
        let fallbackById = Dictionary(
            uniqueKeysWithValues: (agentOptionsById[summary.agentId]?.config ?? []).map { ($0.id, $0) }
        )

        func sortRank(for optionId: String) -> Int {
            let cat = currentById[optionId]?.category ?? fallbackById[optionId]?.category ?? ""
            switch cat {
            case "model": return 0
            case "mode": return 1
            case "thought_level": return 2
            default: return 3
            }
        }

        let mismatches: [(id: String, value: JSONValue)] = desired
            .compactMap { (optId, wanted) -> (id: String, value: JSONValue)? in
                if let existing = currentById[optId], existing.value == wanted {
                    return nil
                }
                return (optId, wanted)
            }
            .sorted { lhs, rhs in
                let lr = sortRank(for: lhs.id)
                let rr = sortRank(for: rhs.id)
                return lr != rr ? lr < rr : lhs.id < rhs.id
            }

        guard !mismatches.isEmpty else { return true }
        for item in mismatches {
            do {
                try await hostSession.setConfigOption(
                    sessionId: summary.id,
                    optionId: item.id,
                    value: item.value
                )
            } catch {
                return false
            }
        }
        return true
    }

    private func receivePreparedSummary(_ summary: SessionSummary) {
        guard showStudioHome, summary.agentId == selectedAgentID else { return }
        if let held = preparedSession,
           held.id != summary.id,
           (summary.prepared?.openedAt ?? 0) < (held.prepared?.openedAt ?? 0) {
            return
        }
        preparedSession = summary
        if summary.status == .ready {
            isPreparingSession = false
        }
        syncEffortFromActiveConfig()
    }

    private func discardPreparedSessionNow(_ sessionId: String? = nil) {
        let targetId = sessionId ?? preparedSession?.id
        if sessionId == nil || sessionId == preparedSession?.id {
            preparedSession = nil
            preparedTargetKey = nil
            isPreparingSession = false
        }
        guard let targetId, let hostSession else { return }
        discardedPreparedIDs.insert(targetId)
        Task {
            try? await hostSession.discardPreparedSession(sessionId: targetId)
        }
    }

    private func schedulePreparedDiscard() {
        preparedDiscardTask?.cancel()
        guard preparedSession != nil else { return }
        preparedDiscardTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled, !self.showStudioHome else { return }
            self.discardPreparedSessionNow()
        }
    }

    public func refreshGitMetadata(for projectPath: String) async {
        guard let hostSession, !projectPath.isEmpty else { return }
        if let status = try? await hostSession.gitStatus(projectPath: projectPath) {
            gitStatusByProject[projectPath] = status
        }
        if let settings = try? await hostSession.projectWorktreeSettings(path: projectPath) {
            updateWorktreeDraft(for: projectPath) { draft in
                draft.branchTemplate = settings.branchTemplate
            }
        }
    }

    public func loadBranches(for projectPath: String) async {
        guard let hostSession, !projectPath.isEmpty else { return }
        isLoadingBranches = true
        defer { isLoadingBranches = false }
        if let list = try? await hostSession.gitBranches(projectPath: projectPath) {
            gitBranchesByProject[projectPath] = list
        }
    }

    public func switchGitBranch(projectPath: String, branch: String, create: Bool = false) async -> String? {
        guard let hostSession, !projectPath.isEmpty else { return l10n.tr("error.daemonNotConnected") }
        do {
            let result = try await hostSession.gitSwitchBranch(projectPath: projectPath, branch: branch, create: create)
            gitStatusByProject[projectPath] = result.status
            await loadBranches(for: projectPath)
            await workspace.refreshGit()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public func ensureAgentOptionsLoaded(for agentId: String) {
        guard Self.remoteClaudeHostID(from: agentId) == nil,
              agentOptionsById[agentId] == nil,
              let hostSession,
              let agent = agents.first(where: { $0.id == agentId }),
              agent.state == "ready" || agent.state == "available" || agent.state == "running"
        else { return }
        let path = effectiveNewSessionIsScratch ? nil : (activeTrayProjectPath ?? projects.first?.path)
        Task {
            try? await hostSession.readAgentOptions(agentId: agentId, projectPath: path)
        }
    }

    // MARK: - Model pins (agents.pinModel)

    /// Whether the model menu may pin the agent's models: the host refuses a pin for an agent whose
    /// models it has not seen.
    public func canPinModels(forAgent agentId: String) -> Bool {
        hostSession != nil && agentOptionsById[agentId] != nil
    }

    /// Pins `model` to the top of the agent's model menu, or unpins it. The menu changes at once and
    /// goes back when the host refuses; the host's `agent.options` event then carries the list it
    /// keeps. Returns what to tell the user when the pin did not take, else nil.
    public func setModelPinned(_ model: String, pinned: Bool, forAgent agentId: String) async -> String? {
        guard let hostSession else { return l10n.tr("error.daemonNotConnected") }
        guard let before = agentOptionsById[agentId] else { return nil }
        let next: [String]?
        do throws(ModelPinRefusal) {
            next = try before.pinnedModels(setting: model, pinned: pinned)
        } catch {
            switch error {
            case .full(let limit): return l10n.tr("composer.pinsFull", limit)
            }
        }
        guard next != before.pinned else { return nil }
        let optimistic = before.replacingPinned(next)
        agentOptionsById[agentId] = optimistic
        do {
            try await hostSession.pinModel(agentId: agentId, model: model, pinned: pinned)
            return nil
        } catch {
            // Undo only while no newer list came from the host, then take the list the host keeps,
            // which also settles pins changed meanwhile.
            if let current = agentOptionsById[agentId], current.pinned == optimistic.pinned {
                agentOptionsById[agentId] = current.replacingPinned(before.pinned)
            }
            if let listed = try? await hostSession.listAgentOptions(),
               let kept = listed.first(where: { $0.agentId == agentId }) {
                agentOptionsById[agentId] = kept
            }
            return error.localizedDescription
        }
    }

    /// Replaces an agent's favorite/pinned models in order (at most `ModelMenuLimits.maxPinnedModels`)
    /// using `agents.setPinnedModels`, updating optimistically and rolling back if the host refuses.
    @discardableResult
    public func setPinnedModels(agentId: String, models: [String]) async -> String? {
        guard let hostSession else { return l10n.tr("error.daemonNotConnected") }
        guard let before = agentOptionsById[agentId] else { return nil }
        var seen = Set<String>()
        let unique = models.filter { !$0.isEmpty && seen.insert($0).inserted }
        if unique.count > ModelMenuLimits.maxPinnedModels {
            return l10n.tr("composer.pinsFull", ModelMenuLimits.maxPinnedModels)
        }
        let next: [String]? = unique.isEmpty ? nil : unique
        guard next != before.pinned else { return nil }
        let optimistic = before.replacingPinned(next)
        agentOptionsById[agentId] = optimistic
        do {
            try await hostSession.setPinnedModels(agentId: agentId, models: unique)
            return nil
        } catch {
            if let current = agentOptionsById[agentId], current.pinned == optimistic.pinned {
                agentOptionsById[agentId] = current.replacingPinned(before.pinned)
            }
            if let listed = try? await hostSession.listAgentOptions(),
               let kept = listed.first(where: { $0.agentId == agentId }) {
                agentOptionsById[agentId] = kept
            }
            return error.localizedDescription
        }
    }

    /// Opens a session HTML file through the host's loopback `files.preview` server inside the
    /// side panel browser pane.
    public func previewHTMLFileInBrowser(relativePath: String) async {
        guard !isViewingRemoteHost, let sid = selectedSessionSummary?.id else { return }
        do {
            let urlString = try await workspace.previewHTMLFile(sessionId: sid, relativePath: relativePath)
            _ = browser.openUserTab(sessionId: sid, urlString: urlString)
            activePreviewTarget = .web
            browserAutoOpenSessionID = sid
            browserAutoOpenRequestToken &+= 1
        } catch {
            reportConnectionError(error)
        }
    }

    /// Appends a quoted file passage into the active composer draft.
    public func appendQuotedFilePassage(_ quote: String) {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let current = activeDraftText
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            activeDraftText = trimmed + "\n"
        } else {
            let sep = current.hasSuffix("\n\n") ? "" : (current.hasSuffix("\n") ? "\n" : "\n\n")
            activeDraftText = current + sep + trimmed + "\n"
        }
    }

    public func refreshActiveModels() async {
        guard let hostSession else { return }
        if showStudioHome {
            if !isViewingRemoteHost && !otherHosts.isEmpty {
                await refreshRemoteClaudeHosts()
            }
            let nowMs = Date().timeIntervalSince1970 * 1000.0
            let openedAt = preparedSession?.prepared?.openedAt ?? 0
            if preparedSession == nil || (nowMs - openedAt) > 5 * 60 * 1000 {
                await prepareNewSessionIfNeeded(replace: true)
            }
            if selectedModelHostID == nil || selectedAgentID != "claude-code" {
                try? await hostSession.refreshAgentLimits(agentId: selectedAgentID)
            }
            if let refreshed = try? await hostSession.listAgents(), refreshed != agents {
                agents = refreshed
            }
            return
        }
        guard let sid = selectedSessionSummary?.id else { return }
        let targetAgent = activeConfigAgentID
        if pendingSwitchAgentID == nil {
            try? await hostSession.refreshSessionModels(sessionId: sid)
        } else {
            ensureAgentOptionsLoaded(for: targetAgent)
        }
        if pendingSwitchAgentID != nil || activeModelHostRef == nil {
            try? await hostSession.refreshAgentLimits(agentId: targetAgent)
        }
        if let refreshed = try? await hostSession.listAgents(), refreshed != agents {
            agents = refreshed
        }
    }

    public func attachActiveSessionEarlyIfNeeded() {
        guard !showStudioHome,
              let sid = selectedSessionSummary?.id,
              let hostSession,
              !earlyAttachedSessionIDs.contains(sid)
        else { return }
        let status = activeReplica?.session.status ?? selectedSessionSummary?.status
        guard status == .closed else { return }
        earlyAttachedSessionIDs.insert(sid)
        Task {
            try? await hostSession.attachSessionEarly(sessionId: sid)
        }
    }

    public func checkRunningWorkBeforeSwitch() async -> [RunningWorkInfo] {
        guard !showStudioHome,
              let sid = selectedSessionSummary?.id,
              let hostSession
        else { return [] }
        guard let items = try? await hostSession.runningWork(sessionIds: [sid]) else { return [] }
        return items.filter { item in
            item.turn
                || item.waiting > 0
                || (item.subagents ?? 0) > 0
                || (item.commands ?? 0) > 0
                || (item.monitors ?? 0) > 0
                || (item.tasks ?? 0) > 0
        }
    }

    public func selectSession(
        _ id: String,
        onHost hostId: String? = nil
    ) async {
        let resolvedHostID = hostId
            ?? (sessions.contains(where: { $0.id == id }) ? activeHostID : hostID(owningSession: id))
        if let resolvedHostID, resolvedHostID != activeHostID {
            _ = await switchActiveHost(to: resolvedHostID, selectingSession: id)
            return
        }
        selectionGeneration &+= 1
        let gen = selectionGeneration
        selectedSessionID = id
        workspace.activeSessionID = id
        UserDefaults.standard.set(id, forKey: PrefKey.lastSelectedSessionID)
        showStudioHome = false
        isLoadingOlderPage = false
        if connectionMode.isLive {
            connectionError = nil
        }
        schedulePreparedDiscard()
        if let existing = replicas[id] {
            applyTelemetrySnapshot(telemetryTracker.snapshot(for: existing))
        } else {
            applyTelemetrySnapshot(LiveTelemetrySnapshot())
        }

        if let s = sessionSummary(for: id) {
            selectedAgentID = s.agentId
            selectedModelHostID = nil
            if !s.projectPath.isEmpty {
                let projectPath = s.worktree?.path ?? s.projectPath
                Task { [weak self] in
                    await self?.workspace.setProjectPath(projectPath)
                    if s.scratch != true {
                        await self?.refreshGitMetadata(for: s.projectPath)
                    }
                }
            } else {
                workspace.clearProjectPath()
            }
        }
        guard let hostSession else { return }

        let wasAlreadyWatched = watchedSessionOrder.contains(id)
        let hasCachedReplica = replicas[id] != nil
        touchWatchedPool(id, host: hostSession)
        if hasCachedReplica {
            touchReplicaCacheOrder(id)
        }

        if wasAlreadyWatched && hasCachedReplica {
            // Live-watched replica is already up-to-date in memory: 0-RTT instant switch!
            syncReportedShownSessions()
            if let existing = replicas[id] {
                syncConfigFromReplica(existing)
            }
            if outlineBySession[id] == nil {
                Task { [weak self] in await self?.refreshOutline(sessionId: id) }
            }
            return
        }

        // Cold or previously evicted session: dispatch watch + show + open concurrently
        // (UnixSocketPort preserves send order so the host watches before snapshotting).
        let shouldReportShown = isForegroundWindowVisible
        if shouldReportShown {
            clearReportedShownSessionsIfDifferentHost(from: activeHostID, session: hostSession)
            lastReportedShownSession = (
                hostId: activeHostID,
                sessionObjectId: ObjectIdentifier(hostSession),
                ids: [id]
            )
        } else {
            syncReportedShownSessions()
        }
        async let watchCall: Void = { _ = try? await hostSession.watchSession(sessionId: id) }()
        async let showCall: Void = {
            guard shouldReportShown else { return }
            _ = try? await hostSession.showSessions([id])
        }()
        async let openCall: Void = reloadSnapshot(sessionId: id, force: true)
        _ = await (watchCall, showCall, openCall)
        guard selectionGeneration == gen else { return }
    }

    public func loadOlderPage(from: Int? = nil) async {
        guard !isLoadingOlderPage,
              let sessionId = selectedSessionSummary?.id,
              let hostSession,
              let before = replicas[sessionId]?.older,
              before > 0
        else { return }

        isLoadingOlderPage = true
        defer { isLoadingOlderPage = false }

        do {
            let page = try await hostSession.loadSessionPage(sessionId: sessionId, before: before, from: from)
            // Re-fetch live replica after await so streaming patches applied in-flight are never overwritten!
            guard replicas[sessionId]?.older == before else { return }
            mutateReplica(sessionId) { $0.prependOlderPage(page) }
        } catch {
            reportConnectionError(error)
        }
    }

    /// Loads older history pages back through `pos`,
    /// so clicking any earlier turn in the left timeline rail can jump straight into unloaded history.
    public func loadThrough(pos: Int) async -> Bool {
        guard let sessionId = selectedSessionSummary?.id else { return false }
        while let replica = replicas[sessionId], let before = replica.older, before > pos {
            if isLoadingOlderPage {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            await loadOlderPage(from: pos)
            if replicas[sessionId]?.older == before {
                return false
            }
        }
        return true
    }

    public func refreshOutline(sessionId: String) async {
        guard let hostSession else { return }
        if let remote = try? await hostSession.sessionOutline(sessionId: sessionId), !remote.isEmpty {
            outlineBySession[sessionId] = remote
        }
    }

    /// Loads a session snapshot into `replicas[sessionId]` without switching the main window's selection.
    /// Deduplicates concurrent requests and no-ops when a replica is already cached.
    public func fetchSessionSnapshotIfNeeded(_ sessionId: String) async {
        guard replicas[sessionId] == nil else { return }
        guard !inFlightSnapshotSessionIDs.contains(sessionId) else { return }
        inFlightSnapshotSessionIDs.insert(sessionId)
        defer { inFlightSnapshotSessionIDs.remove(sessionId) }
        await reloadSnapshot(sessionId: sessionId)
    }

    internal func canAutoReloadSnapshot(sessionId: String, now: Date = Date()) -> Bool {
        guard let retry = snapshotRetryBySession[sessionId] else { return true }
        return now >= retry.nextAllowedAt
    }

    internal func recordSnapshotFailure(sessionId: String, now: Date = Date()) {
        var state = snapshotRetryBySession[sessionId] ?? SnapshotRetryState()
        state.consecutiveFailures += 1
        let delaySeconds = min(30.0, pow(2.0, Double(min(state.consecutiveFailures, 5))))
        state.nextAllowedAt = now.addingTimeInterval(delaySeconds)
        snapshotRetryBySession[sessionId] = state
    }

    internal func clearSnapshotFailure(sessionId: String) {
        snapshotRetryBySession.removeValue(forKey: sessionId)
    }

    private func reloadSnapshot(sessionId: String, force: Bool = false) async {
        guard let hostSession else { return }
        if force {
            clearSnapshotFailure(sessionId: sessionId)
        } else if !canAutoReloadSnapshot(sessionId: sessionId) {
            return
        }
        let targetSession = hostSession
        if let existingTask = activeOpenTasks[sessionId] {
            await existingTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await targetSession.openSession(sessionId: sessionId)
                guard !Task.isCancelled, self.hostSession === targetSession else { return }
                self.clearSnapshotFailure(sessionId: sessionId)
                let incoming = ThreadReplica(snapshot: snapshot)
                if let current = self.replicas[sessionId] {
                    // Never downgrade a replica that already received newer live patches in-flight,
                    // and skip redundant writes when the snapshot matches the cached replica identically.
                    if current.seq > incoming.seq {
                        return
                    }
                    if current.seq == incoming.seq
                        && current.order.count == incoming.order.count
                        && current.session.status == incoming.session.status
                        && current.older == incoming.older {
                        if sessionId == self.selectedSessionSummary?.id {
                            self.connectionError = nil
                            if self.outlineBySession[sessionId] == nil {
                                Task { [weak self] in await self?.refreshOutline(sessionId: sessionId) }
                            }
                        }
                        return
                    }
                }
                self.toolVersionBySession[sessionId, default: 0] &+= 1
                self.replicas[sessionId] = incoming
                self.islandReplicaRevision &+= 1
                self.touchReplicaCacheOrder(sessionId)
                self.telemetryTracker.syncSnapshot(replica: incoming)
                if sessionId == self.selectedSessionSummary?.id {
                    self.connectionError = nil
                    self.syncConfigFromReplica(incoming)
                    self.applyTelemetrySnapshot(self.telemetryTracker.snapshot(for: incoming))
                    Task { [weak self] in
                        await self?.refreshOutline(sessionId: sessionId)
                    }
                }
            } catch {
                guard self.hostSession === targetSession else { return }
                self.recordSnapshotFailure(sessionId: sessionId)
                self.reportConnectionError(error)
            }
        }
        activeOpenTasks[sessionId] = task
        await task.value
        if activeOpenTasks[sessionId] == task {
            activeOpenTasks.removeValue(forKey: sessionId)
        }
    }

    private func syncConfigFromReplica(_ replica: ThreadReplica) {
        syncEffortFromConfig(replica.session.config)
    }

    public func syncEffortFromActiveConfig() {
        syncEffortFromConfig(activeConfigOptions)
    }

    private func syncEffortFromConfig(_ config: [ConfigOption]) {
        if let thoughtOpt = config.first(where: { $0.category == "thought_level" }),
           let val = thoughtOpt.value.stringValue?.lowercased() {
            let next: ReasoningEffortLevel?
            switch val {
            case "auto": next = .auto
            case "low", "minimal": next = .low
            case "medium", "med": next = .medium
            case "high": next = .high
            case "extra", "max", "xhigh": next = .extra
            default: next = nil
            }
            // Observation notifies on every assignment, and this runs for every patch batch.
            if let next, next != effortLevel {
                effortLevel = next
            }
        }
    }

    private func applyTelemetrySnapshot(_ snap: LiveTelemetrySnapshot) {
        if currentTPS != snap.tps { currentTPS = snap.tps }
        if currentTPSIsApprox != snap.tpsIsApprox { currentTPSIsApprox = snap.tpsIsApprox }
        if currentTTFTMs != snap.ttftMs { currentTTFTMs = snap.ttftMs }
        if currentCacheHit != snap.primaryCacheHitPercent { currentCacheHit = snap.primaryCacheHitPercent }
        if currentSessionCacheHit != snap.sessionCacheHitPercent { currentSessionCacheHit = snap.sessionCacheHitPercent }
        if currentTurnContextDelta != snap.turnContextDelta { currentTurnContextDelta = snap.turnContextDelta }
        let nextMode: PrismCacheTelemetryMode = switch snap.cacheSource {
        case .liveRequest: .liveRequest
        case .lastTurn: .lastTurn
        case .pendingTurn: .pendingTurn
        case .session, .unavailable: .session
        }
        if currentCacheMode != nextMode { currentCacheMode = nextMode }
    }

    public func triggerStartOptics(sessionId: String? = nil) {
        liftoffToken += 1
        isStartSurging = true
        if let sid = sessionId ?? selectedSessionSummary?.id {
            let replica = replicas[sid]
            telemetryTracker.recordPromptSent(
                sessionId: sid,
                baselineTokens: replica?.session.usage?.tokens,
                baselineUsed: replica?.session.usage?.used
            )
            if let replica {
                applyTelemetrySnapshot(telemetryTracker.snapshot(for: replica))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1150))
            isStartSurging = false
        }
    }

    /// Returns the created session, or nil when the host refused it (the reason is in `connectionError`).
    @discardableResult
    public func createSession(
        agentId: String,
        projectPath: String?,
        prompt: String? = nil,
        parentId: String? = nil,
        allowNoProject: Bool = false,
        options: [String: JSONValue]? = nil,
        preparedId: String? = nil,
        worktree: WorktreeCreateRequest? = nil,
        modelHostId: String? = nil
    ) async -> SessionSummary? {
        let trimmed = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let content: [UserContent]? = trimmed.isEmpty ? nil : [.text(trimmed)]
        return await createSession(
            agentId: agentId,
            projectPath: projectPath,
            promptContent: content,
            parentId: parentId,
            allowNoProject: allowNoProject,
            options: options,
            preparedId: preparedId,
            worktree: worktree,
            modelHostId: modelHostId
        )
    }

    /// Returns the created session, or nil when the host refused it (the reason is in `connectionError`).
    @discardableResult
    public func createSession(
        agentId: String,
        projectPath: String?,
        promptContent: [UserContent]?,
        parentId: String? = nil,
        allowNoProject: Bool = false,
        options: [String: JSONValue]? = nil,
        preparedId: String? = nil,
        worktree: WorktreeCreateRequest? = nil,
        modelHostId: String? = nil
    ) async -> SessionSummary? {
        let resolvedProject: String? = allowNoProject
            ? projectPath
            : (projectPath ?? projects.first?.path)
        triggerStartOptics()
        connectionError = nil

        guard let hostSession else {
            connectionError = l10n.tr("error.daemonNotConnected")
            return nil
        }

        do {
            let created = try await hostSession.createSession(
                agentId: agentId,
                projectPath: resolvedProject,
                promptContent: promptContent,
                parentId: parentId,
                options: options,
                preparedId: preparedId,
                worktree: worktree,
                modelHostId: modelHostId
            )
            if preparedSession?.id == preparedId || preparedSession?.id == created.id {
                preparedSession = nil
                preparedTargetKey = nil
                isPreparingSession = false
            }
            newSessionParentID = nil
            if let idx = sessions.firstIndex(where: { $0.id == created.id }) {
                sessions[idx] = created
            } else {
                sessions.insert(created, at: 0)
            }
            // Keep New Session stage visible until `selectSession(created.id)` switches `selectedSessionID`
            // and flips `showStudioHome = false`, preventing any flash of an older unrelated session.
            await selectSession(created.id)
            return created
        } catch {
            reportConnectionError(error)
            return nil
        }
    }

    /// Public URL of Sarto's security and privacy architecture documentation.
    public var privacyPolicyURL: URL? {
        let isZh = l10n.language.resolvedLocale.identifier.lowercased().hasPrefix("zh")
        let file = isZh ? "SECURITY.zh-CN.md" : "SECURITY.md"
        return URL(string: "https://github.com/Rladmsrl/Sarto/blob/main/\(file)")
    }

    private func effectiveStartOptionsForNewSession() -> [String: JSONValue]? {
        let opts = activeConfigOptions
        guard !opts.isEmpty else {
            let raw = newSessionOptionPicks[selectedAgentID]
            return raw?.isEmpty == false ? raw : nil
        }
        var result: [String: JSONValue] = [:]
        for opt in opts {
            if opt.type == "boolean" {
                if let b = opt.value.boolValue {
                    result[opt.id] = .bool(b)
                }
            } else if let s = opt.value.stringValue {
                result[opt.id] = .string(s)
            }
        }
        return result.isEmpty ? nil : result
    }

    public func sendPrompt(_ text: String? = nil, steer: Bool = false) async {
        let scope = activeAttachmentScope
        let rawText = text ?? (draftTextByScope[scope] ?? "")
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachmentsByScope[scope] ?? []
        let comments = showStudioHome ? [] : (draftCommentsByScope[scope] ?? [])
        let sessionRefs = (draftSessionReferencesByScope[scope] ?? []).filter { rawText.contains($0.token) }

        if attachments.contains(where: { $0.failureMessage != nil }) {
            attachmentBannerError = l10n.tr("composer.attachmentsRemoveFailed")
            return
        }
        if attachments.contains(where: \.isPreparing) {
            attachmentBannerError = l10n.tr("composer.attachmentsUploading")
            return
        }

        let readyAttachments = attachments.compactMap(\.readyAttachment)
        let baseText = ComposerComments.commentsMessage(comments: comments, text: trimmed)
        guard !baseText.isEmpty || !readyAttachments.isEmpty else { return }

        // Verify live hostSession and target session preconditions BEFORE clearing composer draft/attachments!
        guard let hostSession else {
            connectionError = l10n.tr("error.daemonNotConnected")
            return
        }

        // Pull referenced sessions' read-only snapshots concurrently and assemble structured context blocks.
        var finalText = baseText
        if !sessionRefs.isEmpty {
            let maxPerSession = max(4_000, ComposerSessionContextFormatter.defaultMaxChars / max(1, min(sessionRefs.count, 3)))
            var formattedBlocks: [String] = []
            for ref in sessionRefs {
                let entries = await fetchSessionEntriesForReference(sessionId: ref.id)
                formattedBlocks.append(
                    ComposerSessionContextFormatter.formatContextBlock(
                        reference: ref,
                        entries: entries,
                        maxChars: maxPerSession
                    )
                )
            }
            finalText = ComposerSessionContextFormatter.composePromptWithSessionContexts(
                text: baseText,
                contexts: formattedBlocks
            )
        }

        let totalBytes = finalText.utf8.count + attachments.reduce(0) { $0 + $1.estimatedPromptBytes }
        if totalBytes > AttachmentLimits.maxPromptBytes {
            attachmentBannerError = l10n.tr("composer.attachmentsPromptTooLarge")
            return
        }

        var content: [UserContent] = []
        if !finalText.isEmpty {
            content.append(.text(finalText))
        }
        for info in readyAttachments {
            content.append(.ref(.attachment(info)))
        }

        if showStudioHome || selectedSessionSummary == nil {
            let isScratch = effectiveNewSessionIsScratch
            let targetProject = effectiveNewSessionProjectPath
            let parentId = newSessionParentID

            var worktreeReq: WorktreeCreateRequest? = nil
            if !isScratch, parentId == nil, let projectPath = targetProject {
                let wtDraft = worktreeDraft(for: projectPath)
                if wtDraft.mode == .worktree {
                    let custom = wtDraft.customBranch.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !custom.isEmpty && !Self.isValidGitBranchName(custom) {
                        connectionError = l10n.tr("worktree.branchInvalid")
                        return
                    }
                    let base = wtDraft.baseBranch
                        ?? gitStatusByProject[projectPath]?.head.branch
                        ?? gitStatusByProject[projectPath]?.defaultBranch
                        ?? gitStatusByProject[projectPath]?.head.oid
                    if let base, !base.isEmpty {
                        worktreeReq = WorktreeCreateRequest(base: base, branch: custom.isEmpty ? nil : custom)
                    }
                }
            }

            let startOptions = effectiveStartOptionsForNewSession()
            let targetModelHostId: String? = (!isViewingRemoteHost && selectedAgentID == "claude-code") ? selectedModelHostID : nil
            var preparedId: String? = (worktreeReq == nil && preparedSession?.agentId == selectedAgentID && preparedSession?.modelHost?.hostId == targetModelHostId)
                ? preparedSession?.id
                : nil
            if let prep = preparedSession, prep.id == preparedId, let startOptions {
                // Daemon's `adopt(preparedId)` ignores `options` and uses the prepared session's
                // current config as-is, so reconcile any option picked while preparing first.
                let synced = await reconcilePreparedSessionOptions(prep, desired: startOptions)
                if !synced {
                    preparedId = nil
                }
            }

            attachmentBannerError = nil
            draftTextByScope[scope] = ""
            draftAttachmentsByScope[scope] = []
            draftCommentsByScope[scope] = []
            draftSessionReferencesByScope[scope] = []
            persistDraft(scope: scope)
            let created = await createSession(
                agentId: selectedAgentID,
                projectPath: isScratch ? nil : targetProject,
                promptContent: content,
                parentId: parentId,
                allowNoProject: isScratch,
                options: startOptions,
                preparedId: preparedId,
                worktree: worktreeReq,
                modelHostId: targetModelHostId
            )
            // Decide from the result: other requests (a snapshot load, say) also set connectionError,
            // and restoring the draft after a successful create would send the prompt twice.
            if created == nil {
                showStudioHome = true
                restoreFailedDraft(
                    scope: scope,
                    rawText: rawText,
                    trimmed: trimmed,
                    attachments: attachments,
                    comments: comments,
                    sessionReferences: sessionRefs
                )
            }
            return
        }

        guard let sessionId = selectedSessionSummary?.id else { return }

        // Check mid-session agent switch precondition BEFORE clearing draft.
        if pendingSwitchBySession[sessionId] != nil && isTurnBusy {
            connectionError = l10n.tr("composer.switchBusyHint")
            return
        }

        attachmentBannerError = nil
        connectionError = nil
        draftTextByScope[scope] = ""
        draftAttachmentsByScope[scope] = []
        draftCommentsByScope[scope] = []
        draftSessionReferencesByScope[scope] = []
        persistDraft(scope: scope)

        // Mid-session Agent Switch (Takeover): when user picked another agent in this session,
        // automatically hand over & take effect on the very first message sent, carrying configured options.
        if let pending = pendingSwitchBySession[sessionId] {
            pendingSwitchBySession.removeValue(forKey: sessionId)
            triggerStartOptics(sessionId: sessionId)
            do {
                try await hostSession.switchAgent(
                    sessionId: sessionId,
                    agentId: pending.agentId,
                    content: content,
                    options: pending.values.isEmpty ? nil : pending.values,
                    summarize: pending.summarize
                )
            } catch {
                reportConnectionError(error)
                pendingSwitchBySession[sessionId] = pending
                restoreFailedDraft(
                    scope: scope,
                    rawText: rawText,
                    trimmed: trimmed,
                    attachments: attachments,
                    comments: comments,
                    sessionReferences: sessionRefs
                )
            }
            return
        }

        // Always route composer sends through `sessions.queue`,
        // which atomically sends immediately when idle or queues behind an active turn without race errors.
        let wasBusy = isTurnBusy
        if !wasBusy {
            triggerStartOptics(sessionId: sessionId)
        }
        do {
            let queuedID = try await hostSession.queuePrompt(sessionId: sessionId, content: content)
            if let queuedID {
                if steer && wasBusy {
                    if activeAgentCapabilities?.steering == true {
                        try await hostSession.steerPrompt(sessionId: sessionId, itemId: queuedID)
                    } else {
                        try await hostSession.sendQueuedNow(sessionId: sessionId, itemId: queuedID)
                    }
                } else {
                    appendOptimisticQueueItem(sessionId: sessionId, id: queuedID, content: content)
                }
            }
        } catch {
            reportConnectionError(error)
            restoreFailedDraft(
                scope: scope,
                rawText: rawText,
                trimmed: trimmed,
                attachments: attachments,
                comments: comments,
                sessionReferences: sessionRefs
            )
        }
    }

    private func restoreFailedDraft(
        scope: String,
        rawText: String,
        trimmed: String,
        attachments: [DraftAttachmentItem],
        comments: [DraftReplyComment] = [],
        sessionReferences: [DraftSessionReference] = []
    ) {
        if !trimmed.isEmpty {
            let existing = draftTextByScope[scope] ?? ""
            draftTextByScope[scope] = existing.isEmpty ? rawText : "\(rawText)\n\(existing)"
        }
        if !attachments.isEmpty {
            let existingAtt = draftAttachmentsByScope[scope] ?? []
            let existingIDs = Set(existingAtt.compactMap { $0.readyAttachment?.id })
            let restored = attachments.filter { item in
                guard let id = item.readyAttachment?.id else { return true }
                return !existingIDs.contains(id)
            }
            draftAttachmentsByScope[scope] = Array((restored + existingAtt).prefix(AttachmentLimits.maxAttachments))
        }
        if !comments.isEmpty {
            let existingComments = draftCommentsByScope[scope] ?? []
            let existingIDs = Set(existingComments.map(\.id))
            let restored = comments.filter { !existingIDs.contains($0.id) }
            draftCommentsByScope[scope] = restored + existingComments
        }
        if !sessionReferences.isEmpty {
            let existingRefs = draftSessionReferencesByScope[scope] ?? []
            let existingIDs = Set(existingRefs.map(\.id))
            let restored = sessionReferences.filter { !existingIDs.contains($0.id) }
            draftSessionReferencesByScope[scope] = restored + existingRefs
        }
        persistDraft(scope: scope)
    }

    /// Sends a pure-text prompt to the active session without touching or attaching any composer draft files/images.
    /// Used by interactive ACP text-fallback question cards (e.g. `agy acp` `ask_question`, which rejects images).
    public func sendTextOnlyPrompt(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let sessionId = selectedSessionSummary?.id,
              let hostSession
        else { return }

        connectionError = nil
        let content: [UserContent] = [.text(trimmed)]
        let wasBusy = isTurnBusy
        if !wasBusy {
            triggerStartOptics(sessionId: sessionId)
        }
        do {
            let queuedID = try await hostSession.queuePrompt(sessionId: sessionId, content: content)
            if let queuedID {
                appendOptimisticQueueItem(sessionId: sessionId, id: queuedID, content: content)
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func cancelActiveTurn() async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        try? await hostSession.cancelTurn(sessionId: sessionId)
    }

    // MARK: - Queue, Steering, Retry, Session Management, Fork, Find, Outline & Takeover

    public func unqueueItem(_ item: QueuedPrompt, editInComposer: Bool) async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        do {
            try await hostSession.unqueuePrompt(sessionId: sessionId, itemId: item.id)
            if editInComposer && item.isUserEditable {
                let scope = activeAttachmentScope
                let body = item.textBody.trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    let current = (draftTextByScope[scope] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    draftTextByScope[scope] = current.isEmpty ? body : "\(body)\n\(current)"
                }

                // Restore queued attachments alongside text so user can edit and re-send without re-picking files.
                var restoredAttachments: [DraftAttachmentItem] = []
                for part in item.content {
                    guard case .ref(let ref) = part else { continue }
                    if case .attachment(let att) = ref {
                        let kind: DraftAttachmentItem.Kind = {
                            switch att.type {
                            case "image": return .image
                            case "folder": return .folder
                            case "text": return .text
                            default: return .file
                            }
                        }()
                        let thumbData = PrismImageDecoder.decodeDataURL(att.thumb)
                        let cachedBlob = att.blob.flatMap { sessionBlobCache["\(sessionId):\($0)"] }
                        restoredAttachments.append(DraftAttachmentItem(
                            name: att.name,
                            kind: kind,
                            mimeType: att.mimeType ?? (kind == .image ? "image/png" : "application/octet-stream"),
                            size: att.size ?? 0,
                            status: .ready(att),
                            thumbnailData: thumbData ?? cachedBlob,
                            thumbDataURL: att.thumb,
                            previewImageData: cachedBlob ?? thumbData
                        ))
                    }
                }
                if !restoredAttachments.isEmpty {
                    let existing = draftAttachmentsByScope[scope] ?? []
                    let existingIDs = Set(existing.compactMap { $0.readyAttachment?.id })
                    let deduped = restoredAttachments.filter { item in
                        guard let id = item.readyAttachment?.id else { return true }
                        return !existingIDs.contains(id)
                    }
                    draftAttachmentsByScope[scope] = Array((deduped + existing).prefix(AttachmentLimits.maxAttachments))
                }
                persistDraft(scope: scope)
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func sendQueuedNow(itemId: String) async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        do {
            try await hostSession.sendQueuedNow(sessionId: sessionId, itemId: itemId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func steerQueued(itemId: String) async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        do {
            try await hostSession.steerPrompt(sessionId: sessionId, itemId: itemId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func resumeQueue() async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        do {
            try await hostSession.resumeQueue(sessionId: sessionId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func retryActiveTurn() async {
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        connectionError = nil
        triggerStartOptics(sessionId: sessionId)
        do {
            try await hostSession.retryTurn(sessionId: sessionId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func renameSession(id: String, title: String?, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (cleaned?.isEmpty == false) ? cleaned : nil
        do {
            try await host.renameSession(sessionId: id, title: normalized)
        } catch {
            reportConnectionError(error)
        }
    }

    public func pinSession(id: String, pinned: Bool, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        do {
            try await host.pinSession(sessionId: id, pinned: pinned)
        } catch {
            reportConnectionError(error)
        }
    }

    public func markSessionUnread(id: String, unread: Bool, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        do {
            try await host.markSessionUnread(sessionId: id, unread: unread)
        } catch {
            reportConnectionError(error)
        }
    }

    public func cancelTurn(sessionId: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        do {
            try await host.cancelTurn(sessionId: sessionId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func retryTurn(sessionId: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        do {
            try await host.retryTurn(sessionId: sessionId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func addProject(path: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            let added = try await host.addProject(path: path)
            if isBackground, let hid = hostId, let slot = hostPool[hid] {
                if !slot.projects.contains(where: { $0.path == added.path }) {
                    slot.projects.insert(added, at: 0)
                    publishBackgroundSnapshot(for: hid)
                }
            } else if !projects.contains(where: { $0.path == added.path }) {
                projects.insert(added, at: 0)
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func removeProject(path: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            try await host.removeProject(path: path)
            if isBackground, let hid = hostId, let slot = hostPool[hid] {
                slot.projects.removeAll { $0.path == path }
                slot.sessions.removeAll { $0.projectPath == path && $0.scratch != true }
                publishBackgroundSnapshot(for: hid)
            } else {
                projects.removeAll { $0.path == path }
                sessions.removeAll { $0.projectPath == path && $0.scratch != true }
                if let sid = selectedSessionID, !sessions.contains(where: { $0.id == sid }) {
                    if let next = prioritizedSessions.first {
                        await selectSession(next.id)
                    } else {
                        selectedSessionID = nil
                        showStudioHome = true
                    }
                }
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func pinProject(path: String?, pinned: Bool, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            try await host.pinProject(path: path, pinned: pinned)
            let updatedProjects = try? await host.listProjects()
            if isBackground, let hid = hostId, let slot = hostPool[hid] {
                if let updatedProjects { slot.projects = updatedProjects }
                if path == nil {
                    slot.noProjectInfo = NoProjectInfo(pinnedAt: pinned ? Date().timeIntervalSince1970 * 1000.0 : nil)
                }
                publishBackgroundSnapshot(for: hid)
            } else {
                if let updatedProjects { projects = updatedProjects }
                if path == nil {
                    noProjectInfo = NoProjectInfo(pinnedAt: pinned ? Date().timeIntervalSince1970 * 1000.0 : nil)
                }
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func moveProject(path: String, before: String?, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            try await host.moveProject(path: path, before: before)
            if let refreshed = try? await host.listProjects() {
                if isBackground, let hid = hostId, let slot = hostPool[hid] {
                    slot.projects = refreshed
                    publishBackgroundSnapshot(for: hid)
                } else {
                    projects = refreshed
                }
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func fetchSessionOutputs(sessionId: String) async -> SessionOutputsInfo? {
        let now = Date().timeIntervalSince1970
        if let cached = outputsCache[sessionId], (now - cached.fetchedAt) < 12.0 {
            return cached.info
        }
        guard let hostSession else { return nil }
        if let info = try? await hostSession.sessionOutputs(sessionId: sessionId) {
            outputsCache[sessionId] = (now, info)
            return info
        }
        return nil
    }

    public func archiveSession(id: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            try await host.archiveSession(sessionId: id)
            if !isBackground && selectedSessionID == id && !showArchivedSessions {
                if let next = prioritizedSessions.first(where: { $0.id != id }) {
                    await selectSession(next.id)
                } else {
                    showStudioHome = true
                }
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func unarchiveSession(id: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        do {
            try await host.unarchiveSession(sessionId: id)
        } catch {
            reportConnectionError(error)
        }
    }

    public func deleteSession(id: String, onHost hostId: String? = nil) async {
        guard let host = resolveHostSession(for: hostId) else { return }
        let isBackground = hostId != nil && hostId != activeHostID
        do {
            try await host.deleteSession(sessionId: id)
            if isBackground, let hid = hostId, let slot = hostPool[hid] {
                slot.sessions.removeAll { $0.id == id }
                slot.replicas.removeValue(forKey: id)
                slot.outlineBySession.removeValue(forKey: id)
                publishBackgroundSnapshot(for: hid)
            } else {
                sessions.removeAll { $0.id == id }
                replicas.removeValue(forKey: id)
                draftTextByScope.removeValue(forKey: id)
                draftAttachmentsByScope.removeValue(forKey: id)
                draftCommentsByScope.removeValue(forKey: id)
                draftSessionReferencesByScope.removeValue(forKey: id)
                draftStore.remove(scope: id)
                pendingSwitchBySession.removeValue(forKey: id)
                outlineBySession.removeValue(forKey: id)
                evictSessionBlobs(forSessionId: id)
                if selectedSessionID == id {
                    if let next = prioritizedSessions.first {
                        await selectSession(next.id)
                    } else {
                        selectedSessionID = nil
                        showStudioHome = true
                    }
                }
            }
        } catch {
            reportConnectionError(error)
        }
    }

    public func forkActiveSession(entryId: String? = nil) async {
        guard let sessionId = selectedSessionSummary?.id else { return }
        await forkSession(id: sessionId, entryId: entryId)
    }

    public func forkSession(id sessionId: String, entryId: String? = nil, onHost hostId: String? = nil) async {
        if let hostId, hostId != activeHostID {
            let switched = await switchActiveHost(to: hostId, selectingSession: sessionId)
            guard switched else { return }
        }
        guard let hostSession else { return }
        connectionError = nil
        let resolvedEntry = (entryId == "__latest__") ? nil : entryId
        do {
            let forked = try await hostSession.forkSession(sessionId: sessionId, entryId: resolvedEntry)
            if let idx = sessions.firstIndex(where: { $0.id == forked.id }) {
                sessions[idx] = forked
            } else {
                sessions.insert(forked, at: 0)
            }
            await selectSession(forked.id)
        } catch {
            reportConnectionError(error)
        }
    }

    public func stopBackgroundTask(taskId: String) async {
        if taskId.hasPrefix("tool:") {
            await cancelActiveTurn()
            return
        }
        if let task = activeBackgroundTasks.first(where: { $0.id == taskId }), !task.supportsStop {
            return
        }
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return }
        do {
            try await hostSession.stopBackgroundTask(sessionId: sessionId, taskId: taskId)
        } catch {
            reportConnectionError(error)
        }
    }

    public func readBackgroundTaskOutput(taskId: String) async -> BackgroundTaskOutput? {
        let task = activeBackgroundTasks.first(where: { $0.id == taskId })
        let localEntryId: String? = taskId.hasPrefix("tool:")
            ? String(taskId.dropFirst(5))
            : task?.entryId
        if let entryId = localEntryId {
            if case .tool(let data)? = activeReplica?.byId[entryId] {
                let text = Self.extractToolText(from: data)
                if !text.isEmpty {
                    let limit = 8192
                    let truncated = text.utf8.count > limit
                    let slice = truncated ? String(text.suffix(limit)) : text
                    return BackgroundTaskOutput(output: slice, truncated: truncated)
                }
                if let raw = data.rawInput, !raw.isEmpty {
                    return BackgroundTaskOutput(output: raw, truncated: false)
                }
            }
            if let summary = task?.summary, !summary.isEmpty {
                return BackgroundTaskOutput(output: summary, truncated: false)
            }
            return BackgroundTaskOutput(output: "", truncated: false)
        }
        if task?.canReadOutput == false {
            return BackgroundTaskOutput(output: task?.summary ?? "", truncated: false)
        }
        guard let sessionId = selectedSessionSummary?.id, let hostSession else { return nil }
        return try? await hostSession.readBackgroundTaskOutput(sessionId: sessionId, taskId: taskId)
    }

    public func findInActiveSession(query: String) async -> [SessionFindMatchInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let sessionId = selectedSessionSummary?.id else { return [] }

        if trimmed.count >= 2, let hostSession,
           let result = try? await hostSession.findInSession(sessionId: sessionId, query: trimmed),
           !result.matches.isEmpty {
            return result.matches
        }

        // Local instant fallback across loaded entries (also handles 1-char or unindexed queries).
        guard let replica = replicas[sessionId] else { return [] }
        let terms = trimmed.lowercased().split(separator: " ").map(String.init)
        var found: [SessionFindMatchInfo] = []
        for (idx, entry) in replica.entries.enumerated() {
            switch entry {
            case .user(let id, let text, _, _, let approval, _):
                guard !approval else { continue }
                let lower = text.lowercased()
                if terms.allSatisfy({ lower.contains($0) }) {
                    found.append(SessionFindMatchInfo(pos: idx, entryId: id, role: "user"))
                }
            case .agent(let id, let md, _, _, _):
                let lower = md.lowercased()
                if terms.allSatisfy({ lower.contains($0) }) {
                    found.append(SessionFindMatchInfo(pos: idx, entryId: id, role: "agent"))
                }
            default:
                continue
            }
        }
        return found
    }

    public func fetchActiveOutline() async -> [OutlineEntryInfo] {
        guard let sessionId = selectedSessionSummary?.id else { return [] }
        if let hostSession,
           let remote = try? await hostSession.sessionOutline(sessionId: sessionId),
           !remote.isEmpty {
            return remote
        }
        guard let replica = replicas[sessionId] else { return [] }
        var local: [OutlineEntryInfo] = []
        for (idx, entry) in replica.entries.enumerated() {
            if case .user(let id, let text, _, _, let approval, _) = entry, !approval {
                let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
                let clean = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    local.append(OutlineEntryInfo(pos: idx, entryId: id, text: clean, title: nil))
                }
            }
        }
        return local
    }

    public func prepareAgentSwitch(to agentId: String, initialValues: [String: JSONValue]? = nil) {
        guard let sid = selectedSessionSummary?.id else { return }
        let currentAgent = activeReplica?.session.agentId ?? selectedSessionSummary?.agentId
        if agentId == currentAgent && activeModelHostRef == nil {
            pendingSwitchBySession.removeValue(forKey: sid)
            syncEffortFromActiveConfig()
            return
        }
        ensureAgentOptionsLoaded(for: agentId)
        let existing = pendingSwitchBySession[sid]
        var values = initialValues ?? (existing?.agentId == agentId ? existing?.values : nil)
            ?? defaultOptionValues(for: agentId, projectPath: selectedSessionSummary?.projectPath, includeStartMode: false)
        if let initialValues {
            for (k, v) in initialValues { values[k] = v }
        }
        pendingSwitchBySession[sid] = PendingAgentSwitch(
            agentId: agentId,
            summarize: existing?.summarize ?? false,
            values: values
        )
        syncEffortFromActiveConfig()
    }

    public func cancelAgentSwitch() {
        guard let sid = selectedSessionSummary?.id else { return }
        pendingSwitchBySession.removeValue(forKey: sid)
        syncEffortFromActiveConfig()
    }

    /// Why an answer to a permission request did not reach its host.
    public enum PermissionAnswerFailure: Error, Equatable {
        /// No connection to the host that asked.
        case hostUnavailable
        /// The host refused or the call failed, with its message.
        case failed(String)
    }

    /// Sends the answer to the host that asked; returns why it failed, or nil once it is sent.
    @discardableResult
    public func respondPermission(
        sessionId: String,
        requestId: String,
        optionId: String?,
        note: String? = nil,
        answers: [QuestionAnswer]? = nil,
        values: [String: JSONValue]? = nil,
        onHost hostId: String? = nil
    ) async -> PermissionAnswerFailure? {
        let resolvedHost = hostId ?? hostID(owningSession: sessionId)
        guard let host = resolveHostSession(for: resolvedHost) else { return .hostUnavailable }
        let isBackground = resolvedHost != nil && resolvedHost != activeHostID
        do {
            try await host.respondPermission(
                sessionId: sessionId,
                requestId: requestId,
                optionId: optionId,
                note: note,
                answers: answers,
                values: values
            )
            if isBackground, let hid = resolvedHost, let slot = hostPool[hid] {
                if !slot.watchedSessionOrder.contains(sessionId) {
                    slot.replicas.removeValue(forKey: sessionId)
                    backgroundReplicaRevision &+= 1
                    await fetchSessionSnapshotIfNeeded(sessionId, onHost: hid)
                }
            } else if !watchedSessionOrder.contains(sessionId) {
                await reloadSnapshot(sessionId: sessionId)
            }
            return nil
        } catch {
            reportConnectionError(error)
            if Self.isCancellationError(error) { return .failed("") }
            return .failed(error.localizedDescription)
        }
    }

    public func answerMemory(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerMemory(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func undoMemory(sessionId: String, entryId: String) async {
        guard let hostSession else { return }
        do { try await hostSession.undoMemory(sessionId: sessionId, entryId: entryId) }
        catch { reportConnectionError(error) }
    }

    public func answerSettingsChange(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerSettingsChange(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func undoSettingsChange(sessionId: String, entryId: String) async {
        guard let hostSession else { return }
        do { try await hostSession.undoSettingsChange(sessionId: sessionId, entryId: entryId) }
        catch { reportConnectionError(error) }
    }

    public func answerBrowserOrigin(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerBrowserOrigin(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func answerControlAsk(sessionId: String, entryId: String, outcome: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerControlAsk(sessionId: sessionId, entryId: entryId, outcome: outcome) }
        catch { reportConnectionError(error) }
    }

    public func answerDeviceAccess(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerDeviceAccess(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func answerSurfaceAccess(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerSurfaceAccess(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func answerComputerApp(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerComputerApp(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func declineComputerSetup(sessionId: String, entryId: String) async {
        guard let hostSession else { return }
        do { try await hostSession.declineComputerSetup(sessionId: sessionId, entryId: entryId) }
        catch { reportConnectionError(error) }
    }

    public func answerProjectMcp(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerProjectMcp(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func answerProjectHooks(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerProjectHooks(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    public func answerProblemReport(
        sessionId: String,
        entryId: String,
        outcomeKind: String,
        reportId: String? = nil,
        onHost hostId: String? = nil
    ) async {
        guard let hostSession = resolveHostSession(for: hostId) else { return }
        do {
            try await hostSession.answerProblemReport(
                sessionId: sessionId,
                entryId: entryId,
                outcomeKind: outcomeKind,
                reportId: reportId
            )
        } catch {
            reportConnectionError(error)
        }
    }

    /// Resolves the agent/model priority for `agents.draftReport`:
    /// 1) The report's session or current active session's agent & model;
    /// 2) The new-session composer's last recorded agent & model as fallback.
    private func resolveProblemReportDraftTargets(
        sessionId: String?,
        agentId: String?
    ) -> (draftAgentId: String?, draftModel: String?, fallbackAgentId: String?, fallbackModel: String?) {
        func sessionModel(for sid: String) -> (agentId: String, model: String?)? {
            if let replica = replicas[sid] {
                let model = replica.session.config
                    .first(where: { $0.category == "model" && $0.type == "select" })?
                    .value.stringValue ?? sessionSummary(for: sid)?.model
                return (replica.session.agentId, model)
            }
            if let summary = sessionSummary(for: sid) {
                return (summary.agentId, summary.model)
            }
            return nil
        }

        // Priority 1: explicit report session, else currently open live session.
        var primaryAgent: String? = nil
        var primaryModel: String? = nil
        if let sid = sessionId, let info = sessionModel(for: sid) {
            primaryAgent = info.agentId
            primaryModel = info.model
        } else if !showStudioHome, let currentSid = selectedSessionSummary?.id, let info = sessionModel(for: currentSid) {
            primaryAgent = info.agentId
            primaryModel = info.model
        } else if let agentId, !agentId.isEmpty {
            primaryAgent = agentId
        }

        // Priority 2: new-session stage's last remembered agent & model.
        let newSessionAgent: String? = selectedAgentID.isEmpty ? nil : selectedAgentID
        let newSessionModel: String? = newSessionAgent.flatMap { aid in
            let prepCfg = (preparedSession?.agentId == aid) ? preparedSession?.prepared?.config : nil
            return configOptions(
                forAgent: aid,
                overrides: newSessionOptionPicks[aid] ?? [:],
                includeStartMode: true,
                preparedOverride: prepCfg
            )
            .first(where: { $0.category == "model" && $0.type == "select" })?
            .value.stringValue
        }

        if let primaryAgent {
            return (primaryAgent, primaryModel, newSessionAgent, newSessionModel)
        }
        return (newSessionAgent, newSessionModel, nil, nil)
    }

    public func draftProblemReport(
        origin: String?,
        sessionId: String?,
        agentId: String?,
        error: String?,
        onHost hostId: String
    ) async throws -> ReportDraftResultInfo {
        guard let hostSession = resolveHostSession(for: hostId) else {
            throw NSError(domain: "SartoState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected to host"])
        }
        let tag = language.resolvedLocale.identifier.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        let targets = resolveProblemReportDraftTargets(sessionId: sessionId, agentId: agentId)
        return try await hostSession.draftProblemReport(
            origin: origin,
            sessionId: sessionId,
            agentId: agentId,
            error: error,
            language: tag,
            draftAgentId: targets.draftAgentId,
            draftModel: targets.draftModel,
            fallbackAgentId: targets.fallbackAgentId,
            fallbackModel: targets.fallbackModel
        )
    }

    public func requestRemoteHostReport(
        description: String,
        rangeKind: String,
        extras: [String],
        sessionId: String? = nil,
        agentId: String? = nil,
        error: String? = nil,
        onHost hostId: String
    ) async throws -> DeviceReportInfo {
        guard let hostSession = resolveHostSession(for: hostId) else {
            throw NSError(domain: "SartoState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected to host"])
        }
        return try await hostSession.adminHostReport(
            description: description,
            rangeKind: rangeKind,
            extras: extras,
            sessionId: sessionId,
            agentId: agentId,
            error: error
        )
    }

    public func submitRemoteHostReport(ref: String, allowAnonymous: Bool = true, onHost hostId: String) async throws -> ReportSubmitResultInfo {
        guard let hostSession = resolveHostSession(for: hostId) else {
            throw NSError(domain: "SartoState", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected to host"])
        }
        return try await hostSession.adminHostSubmitReport(ref: ref, allowAnonymous: allowAnonymous)
    }

    public func answerMarketPublish(sessionId: String, entryId: String, decision: String) async {
        guard let hostSession else { return }
        do { try await hostSession.answerMarketPublish(sessionId: sessionId, entryId: entryId, decision: decision) }
        catch { reportConnectionError(error) }
    }

    /// Unified setter for any config option (model, mode, thought_level, boolean switch, or extra select)
    /// across New Session (with prepared session sync), Pending Agent Switch, and Live Session.
    public func setActiveConfigOption(optionId: String, value: JSONValue, forAgent targetAgentId: String? = nil) async {
        // 1. New Session stage
        if showStudioHome {
            let agentId = targetAgentId ?? selectedAgentID
            if agentId != selectedAgentID {
                selectedAgentID = agentId
            }
            let currentPool: [ConfigOption]
            if agentId == "claude-code", let remoteHost = selectedRemoteClaudeHost {
                currentPool = remoteClaudeConfigOptions(
                    for: remoteHost,
                    overrides: newSessionOptionPicks["claude-code"] ?? [:]
                )
            } else {
                currentPool = configOptions(
                    forAgent: agentId,
                    overrides: newSessionOptionPicks[agentId] ?? [:],
                    includeStartMode: true
                )
            }
            let changedOpt = currentPool.first(where: { $0.id == optionId })
            let modelOpt = currentPool.first(where: { $0.category == "model" && $0.type == "select" })
            let modeOpt = currentPool.first(where: { $0.category == "mode" && $0.type == "select" })

            var picks = newSessionOptionPicks[agentId] ?? [:]
            picks[optionId] = value

            var syncedModeOption: (id: String, value: JSONValue)? = nil
            if changedOpt?.category == "mode", let modeVal = value.stringValue {
                recordRememberedMode(modeVal, forAgent: agentId, model: modelOpt?.value.stringValue)
            } else if changedOpt?.category == "model", let newModel = value.stringValue, let modeOpt {
                // Switching models recalls that model's (or channel's) last-used permission mode.
                if let savedMode = rememberedMode(forAgent: agentId, model: newModel),
                   Self.isValidConfigValue(.string(savedMode), for: modeOpt) {
                    picks[modeOpt.id] = .string(savedMode)
                    syncedModeOption = (modeOpt.id, .string(savedMode))
                } else {
                    picks.removeValue(forKey: modeOpt.id)
                }
            }

            newSessionOptionPicks[agentId] = picks
            syncEffortFromActiveConfig()

            let targetModelHostId: String? = (!isViewingRemoteHost && agentId == "claude-code") ? selectedModelHostID : nil
            if let hostSession,
               let prep = preparedSession,
               prep.agentId == agentId,
               prep.modelHost?.hostId == targetModelHostId {
                try? await hostSession.setConfigOption(sessionId: prep.id, optionId: optionId, value: value)
                if let syncedModeOption {
                    try? await hostSession.setConfigOption(sessionId: prep.id, optionId: syncedModeOption.id, value: syncedModeOption.value)
                }
            } else {
                await prepareNewSessionIfNeeded()
            }
            return
        }

        // 2. Pending Agent Switch in active session
        if let sid = selectedSessionSummary?.id {
            let currentAgent = activeReplica?.session.agentId ?? selectedSessionSummary?.agentId
            if let targetAgentId, targetAgentId != currentAgent {
                var values = (pendingSwitchBySession[sid]?.agentId == targetAgentId)
                    ? (pendingSwitchBySession[sid]?.values ?? [:])
                    : defaultOptionValues(for: targetAgentId, projectPath: selectedSessionSummary?.projectPath, includeStartMode: false)
                let pool = configOptions(forAgent: targetAgentId, overrides: values, includeStartMode: false)
                let changedOpt = pool.first(where: { $0.id == optionId })
                let modelOpt = pool.first(where: { $0.category == "model" && $0.type == "select" })
                let modeOpt = pool.first(where: { $0.category == "mode" && $0.type == "select" })
                values[optionId] = value
                if changedOpt?.category == "mode", let modeVal = value.stringValue {
                    recordRememberedMode(modeVal, forAgent: targetAgentId, model: modelOpt?.value.stringValue)
                } else if changedOpt?.category == "model", let newModel = value.stringValue, let modeOpt {
                    if let savedMode = rememberedMode(forAgent: targetAgentId, model: newModel),
                       Self.isValidConfigValue(.string(savedMode), for: modeOpt) {
                        values[modeOpt.id] = .string(savedMode)
                    } else {
                        values.removeValue(forKey: modeOpt.id)
                    }
                }
                pendingSwitchBySession[sid] = PendingAgentSwitch(
                    agentId: targetAgentId,
                    summarize: pendingSwitchBySession[sid]?.summarize ?? false,
                    values: values
                )
                syncEffortFromActiveConfig()
                return
            }
            if var pending = pendingSwitchBySession[sid] {
                let pool = configOptions(forAgent: pending.agentId, overrides: pending.values, includeStartMode: false)
                let changedOpt = pool.first(where: { $0.id == optionId })
                let modelOpt = pool.first(where: { $0.category == "model" && $0.type == "select" })
                let modeOpt = pool.first(where: { $0.category == "mode" && $0.type == "select" })
                pending.values[optionId] = value
                if changedOpt?.category == "mode", let modeVal = value.stringValue {
                    recordRememberedMode(modeVal, forAgent: pending.agentId, model: modelOpt?.value.stringValue)
                } else if changedOpt?.category == "model", let newModel = value.stringValue, let modeOpt {
                    if let savedMode = rememberedMode(forAgent: pending.agentId, model: newModel),
                       Self.isValidConfigValue(.string(savedMode), for: modeOpt) {
                        pending.values[modeOpt.id] = .string(savedMode)
                    } else {
                        pending.values.removeValue(forKey: modeOpt.id)
                    }
                }
                pendingSwitchBySession[sid] = pending
                syncEffortFromActiveConfig()
                return
            }
        }

        // 3. Normal live session: optimistic update + send RPC; live watched stream delivers
        // authoritative `session.update { config }` patches without a jarring full-snapshot reload.
        guard let hostSession, let replica = activeReplica else { return }
        if let changedOpt = replica.session.config.first(where: { $0.id == optionId }),
           changedOpt.category == "mode",
           let modeVal = value.stringValue {
            let modelVal = replica.session.config.first(where: { $0.category == "model" && $0.type == "select" })?.value.stringValue
            recordRememberedMode(modeVal, forAgent: replica.session.agentId, model: modelVal)
        }
        applyOptimisticConfigValue(sessionId: replica.session.id, optionId: optionId, value: value)
        syncEffortFromActiveConfig()
        do {
            try await hostSession.setConfigOption(
                sessionId: replica.session.id,
                optionId: optionId,
                value: value
            )
        } catch {
            reportConnectionError(error)
            await reloadSnapshot(sessionId: replica.session.id)
        }
    }

    public func selectEffortValue(_ value: String, forAgent targetAgentId: String? = nil) async {
        let configPool: [ConfigOption]
        if let targetAgentId, targetAgentId != activeConfigAgentID {
            let overrides: [String: JSONValue] = showStudioHome
                ? (newSessionOptionPicks[targetAgentId] ?? [:])
                : (pendingSwitchBySession[selectedSessionSummary?.id ?? ""]?.agentId == targetAgentId ? (pendingSwitchBySession[selectedSessionSummary?.id ?? ""]?.values ?? [:]) : [:])
            configPool = configOptions(forAgent: targetAgentId, overrides: overrides, includeStartMode: showStudioHome)
        } else {
            configPool = activeConfigOptions
        }
        guard let thoughtOpt = configPool.first(where: { $0.category == "thought_level" && $0.type == "select" }) else {
            return
        }
        await setActiveConfigOption(optionId: thoughtOpt.id, value: .string(value), forAgent: targetAgentId)
    }

    public func selectModelOrAgent(_ id: String) async {
        if let opt = activeModelConfigOption,
           opt.choices?.contains(where: { $0.value == id }) == true {
            await setActiveConfigOption(optionId: opt.id, value: .string(id))
            return
        }
        if showStudioHome {
            setNewSessionAgent(id)
        } else {
            selectedAgentID = id
        }
    }

    public func applyModeChoice(_ value: String) async {
        guard let modeOpt = activeModeConfigOption else { return }
        await setActiveConfigOption(optionId: modeOpt.id, value: .string(value))
    }

    @discardableResult
    public func cyclePermissionMode() -> Bool {
        guard let modeOpt = activeModeConfigOption,
              let choices = modeOpt.choices,
              choices.count > 1
        else { return false }
        let current = modeOpt.value.stringValue
        // Cycle past Full Access unless already on it.
        let pool = choices.filter { !Self.isFullAccessMode($0.value) || $0.value == current }
        guard !pool.isEmpty else { return false }
        let idx = pool.firstIndex(where: { $0.value == current }) ?? -1
        let next = pool[(idx + 1) % pool.count].value
        guard next != current else { return false }
        Task { await applyModeChoice(next) }
        return true
    }

    @discardableResult
    public func cycleThoughtLevel() -> Bool {
        guard let resolved = activeEffortResolved,
              resolved.levels.count > 1
        else { return false }
        let idx = resolved.levels.firstIndex(where: { $0.id == resolved.selectedID }) ?? -1
        let next = resolved.levels[(idx + 1) % resolved.levels.count].id
        guard next != resolved.selectedID else { return false }
        Task { await setActiveConfigOption(optionId: resolved.optionId, value: .string(next)) }
        return true
    }

    public func toggleBooleanOption(_ optionId: String, on: Bool, forAgent targetAgentId: String? = nil) async {
        await setActiveConfigOption(optionId: optionId, value: .bool(on), forAgent: targetAgentId)
    }

    public func applyEffortLevel(_ level: ReasoningEffortLevel, forAgent targetAgentId: String? = nil) async {
        effortLevel = level
        let configPool: [ConfigOption]
        if let targetAgentId, targetAgentId != activeConfigAgentID {
            let overrides: [String: JSONValue] = showStudioHome
                ? (newSessionOptionPicks[targetAgentId] ?? [:])
                : (pendingSwitchBySession[selectedSessionSummary?.id ?? ""]?.agentId == targetAgentId ? (pendingSwitchBySession[selectedSessionSummary?.id ?? ""]?.values ?? [:]) : [:])
            configPool = configOptions(forAgent: targetAgentId, overrides: overrides, includeStartMode: showStudioHome)
        } else {
            configPool = activeConfigOptions
        }
        guard let thoughtOpt = configPool.first(where: { $0.category == "thought_level" && $0.type == "select" }) else {
            return
        }
        let targetValue = level.label.lowercased()
        let matched = thoughtOpt.choices?.first(where: { $0.value.lowercased() == targetValue })?.value
            ?? thoughtOpt.choices?.first(where: {
                $0.value.lowercased().contains(targetValue) || $0.name.lowercased().contains(targetValue)
            })?.value
            ?? targetValue
        await setActiveConfigOption(optionId: thoughtOpt.id, value: .string(matched), forAgent: targetAgentId)
    }

    private func appendOptimisticQueueItem(sessionId: String, id queuedID: String, content: [UserContent]) {
        guard let queue = replicas[sessionId]?.session.queue,
              !queue.contains(where: { $0.id == queuedID })
        else { return }
        mutateReplica(sessionId) { replica in
            replica.session.queue.append(
                QueuedPrompt(id: queuedID, content: content, at: Date().timeIntervalSince1970 * 1000.0)
            )
        }
    }

    private func applyOptimisticConfigValue(sessionId: String, optionId: String, value: JSONValue) {
        guard let config = replicas[sessionId]?.session.config else { return }
        let updated = config.map { opt in
            guard opt.id == optionId else { return opt }
            return ConfigOption(
                id: opt.id,
                name: opt.name,
                description: opt.description,
                category: opt.category,
                type: opt.type,
                value: value,
                choices: opt.choices,
                idleOnly: opt.idleOnly,
                defaultValue: opt.defaultValue,
                indicator: opt.indicator
            )
        }
        mutateReplica(sessionId) { $0.session.config = updated }
    }

    // MARK: - Pairing (Noise_IKpsk1) & Remote Relay Connections

    private func resolveRelayBearerToken() async -> String {
        if sartoSyncStatus.mode == "account" || cloudAccountStatus.account.isSignedIn {
            if let fresh = await relayTokenProvider?() {
                let trimmed = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        await relayTokenLoadTask?.value
        return relayBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func probeRelay() async {
        let trimmedOrigin = relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOrigin.isEmpty else {
            relayStatus = .failed("Please enter your self-hosted server URL first")
            return
        }
        relayStatus = .checking
        do {
            let result = try await relayClient.measureRelayLatency(origin: trimmedOrigin)
            relayStatus = .online(regionCount: result.info.regions.count, features: result.info.features)
            relayLatencyMs = result.latencyMs
            relayLatencyFailed = false
            let trimmedToken = await resolveRelayBearerToken()
            if !trimmedToken.isEmpty {
                remoteHosts = try await relayClient.listHosts(origin: trimmedOrigin, bearerToken: trimmedToken)
            }
        } catch {
            relayStatus = .failed(error.localizedDescription)
            relayLatencyMs = nil
            relayLatencyFailed = true
        }
    }

    private func resolvedRelayLatencyOrigin() -> String {
        let accountOrigin = cloudAccountStatus.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !accountOrigin.isEmpty { return accountOrigin }
        let configuredOrigin = relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredOrigin.isEmpty { return configuredOrigin }
        return SartoSyncStatusInfo.defaultCloudURL
    }

    public func refreshRelayLatency() async {
        let origin = resolvedRelayLatencyOrigin()
        guard !origin.isEmpty else { return }
        do {
            let result = try await relayClient.measureRelayLatency(origin: origin)
            guard !Task.isCancelled, cloudAccountStatus.account.isSignedIn else { return }
            if relayLatencyMs != result.latencyMs {
                relayLatencyMs = result.latencyMs
            }
            if relayLatencyFailed {
                relayLatencyFailed = false
            }
            let nextStatus: RelayProbeStatus = .online(
                regionCount: result.info.regions.count,
                features: result.info.features
            )
            if relayStatus != nextStatus {
                relayStatus = nextStatus
            }
        } catch {
            guard !Task.isCancelled, cloudAccountStatus.account.isSignedIn else { return }
            if relayLatencyMs != nil {
                relayLatencyMs = nil
            }
            if !relayLatencyFailed {
                relayLatencyFailed = true
            }
        }
    }

    public func startRelayLatencyMonitoring() {
        relayLatencyTask?.cancel()
        relayLatencyTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshRelayLatency()
            if !Task.isCancelled, self.cloudAccountStatus.account.isSignedIn, self.relayLatencyFailed {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.cloudAccountStatus.account.isSignedIn else { return }
                await self.refreshRelayLatency()
            }
            while !Task.isCancelled, self.cloudAccountStatus.account.isSignedIn {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, self.cloudAccountStatus.account.isSignedIn else { return }
                await self.refreshRelayLatency()
            }
        }
    }

    public func stopRelayLatencyMonitoring() {
        relayLatencyTask?.cancel()
        relayLatencyTask = nil
        if relayLatencyMs != nil { relayLatencyMs = nil }
        if relayLatencyFailed { relayLatencyFailed = false }
    }

    // MARK: - Direct Cloud Account Sign-In & Auto-Discovery (iOS)

    /// Restores a previously signed-in direct cloud account (iOS), refreshes its relay token,
    /// and automatically discovers online computers belonging to the same account.
    public func restoreDirectCloudAccount() async {
        guard daemonOtherHosts == nil else { return }
        guard let stored = cloudAccountStore.load() else { return }
        directCloudSession = stored
        directCloudProfile = stored.profile
        relayOrigin = stored.origin
        await refreshAccountComputers()
    }

    /// Starts Sarto Cloud OAuth 2.0 Device Flow sign-in for mobile clients without QR codes.
    public func startDirectCloudSignIn(
        deviceName: String,
        os: String,
        arch: String = "arm64",
        version: String? = nil
    ) async {
        guard daemonOtherHosts == nil else { return }
        directCloudPollTask?.cancel()
        connectionError = nil
        isSigningInDirectCloud = true
        let origin = relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SartoSyncStatusInfo.defaultCloudURL
            : relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        relayOrigin = origin

        do {
            let auth = try await cloudAccountClient.startDeviceSignIn(
                origin: origin,
                deviceName: deviceName,
                os: os,
                arch: arch,
                version: version
            )
            pendingDeviceAuth = auth
            directCloudPollTask = Task { @MainActor [weak self] in
                await self?.pollDirectCloudDeviceAuth(origin: origin, auth: auth)
            }
        } catch {
            isSigningInDirectCloud = false
            pendingDeviceAuth = nil
            connectionError = error.localizedDescription
        }
    }

    public func cancelDirectCloudSignIn() {
        directCloudPollTask?.cancel()
        directCloudPollTask = nil
        pendingDeviceAuth = nil
        isSigningInDirectCloud = false
    }

    private func pollDirectCloudDeviceAuth(origin: String, auth: CloudDeviceAuthStart) async {
        var waitSeconds = max(2, auth.interval)
        let deadline = Date().addingTimeInterval(TimeInterval(max(60, auth.expiresIn)))
        defer {
            isSigningInDirectCloud = false
            pendingDeviceAuth = nil
        }

        while !Task.isCancelled && Date() < deadline {
            try? await Task.sleep(for: .seconds(waitSeconds))
            guard !Task.isCancelled else { return }
            do {
                let tokens = try await cloudAccountClient.pollDeviceToken(origin: origin, deviceCode: auth.deviceCode)
                let profile = try await cloudAccountClient.fetchMe(origin: origin, accessToken: tokens.accessToken)
                let record = CloudAccountSessionRecord(origin: origin, tokens: tokens, profile: profile)
                try? cloudAccountStore.save(record)
                directCloudSession = record
                directCloudProfile = profile
                connectionError = nil
                await refreshAccountComputers()
                return
            } catch let err as CloudAccountClientError {
                switch err {
                case .authorizationPending:
                    continue
                case .slowDown(let next):
                    waitSeconds = max(waitSeconds + 2, next ?? (waitSeconds + 2))
                    continue
                default:
                    connectionError = err.localizedDescription
                    return
                }
            } catch {
                connectionError = error.localizedDescription
                return
            }
        }
        if !Task.isCancelled {
            connectionError = CloudAccountClientError.expiredToken.localizedDescription
        }
    }

    public func signOutDirectCloud() async {
        cancelDirectCloudSignIn()
        if let current = directCloudSession {
            try? await cloudAccountClient.revoke(origin: current.origin, refreshToken: current.tokens.refreshToken)
        }
        cloudAccountStore.clear()
        directCloudSession = nil
        directCloudProfile = nil
        relayBearerToken = ""
        remoteHosts = []
        await disconnectLive()
    }

    /// Ensures a fresh Sarto Cloud access + relay token and loads all online computers under the account.
    @discardableResult
    public func refreshAccountComputers() async -> Bool {
        guard daemonOtherHosts == nil else { return false }
        guard var current = directCloudSession ?? cloudAccountStore.load() else { return false }
        do {
            if current.tokens.isExpiredOrNearExpiry {
                let osVer = ProcessInfo.processInfo.operatingSystemVersion
                #if os(macOS)
                let osLabel = "macOS \(osVer.majorVersion).\(osVer.minorVersion)"
                let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
                #else
                let osLabel = "iOS \(osVer.majorVersion).\(osVer.minorVersion)"
                let deviceName = ProcessInfo.processInfo.hostName
                #endif
                let appVersion = (Bundle.main.object(forInfoDictionaryKey: "SartoVersion") as? String)
                    .flatMap { $0.isEmpty ? nil : $0 }
                    ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                let info = CloudAccountClient.encodeClientInfo(
                    deviceName: deviceName,
                    os: osLabel,
                    version: appVersion
                )
                let refreshed = try await cloudAccountClient.refreshTokens(
                    origin: current.origin,
                    refreshToken: current.tokens.refreshToken,
                    clientInfo: info
                )
                current.tokens = refreshed
                try? cloudAccountStore.save(current)
            }
            let relayTok = try await cloudAccountClient.fetchRelayToken(
                origin: current.origin,
                accessToken: current.tokens.accessToken
            )
            directCloudSession = current
            directCloudProfile = current.profile
            relayOrigin = current.origin
            relayBearerToken = relayTok.token

            let listed = try await relayClient.listHosts(origin: current.origin, bearerToken: relayTok.token)
            remoteHosts = listed
            relayStatus = .online(regionCount: 1, features: ["hosts", "relay-tokens", "sarto-sync"])
            connectionError = nil
            return true
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Connects an authenticated mobile device to one of its account's online computers over the relay.
    /// Uses 0-click Noise_IK when already trusted, falling back to same-account 6-digit verification on first connect.
    public func connectToAccountHost(_ host: RelayListedHost, deviceName: String) async {
        guard let hostKey = host.hostPublicKeyData else {
            connectionError = "Invalid host key returned by relay"
            return
        }
        guard await refreshAccountComputers() else { return }
        let token = relayBearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !origin.isEmpty else {
            connectionError = "Sign in to your Sarto account first"
            return
        }

        isConnecting = true
        connectionError = nil
        defer {
            isConnecting = false
            pendingDiscoveryHost = nil
            pendingDiscoveryCode = nil
        }

        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "SartoVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.2.0"
        #if os(macOS)
        let clientInfo = HelloClientInfo(kind: "desktop", version: appVersion, platform: "darwin")
        let modelName = "Mac"
        let helloFeatures = ["image-refs", "browser", "tool-digests"]
        #else
        let clientInfo = HelloClientInfo(kind: "ios", version: appVersion, platform: "ios")
        let modelName = "iPhone"
        let helloFeatures = ["image-refs", "tool-digests"]
        #endif

        do {
            // Fast path: already trusted device connects immediately with Noise_IK.
            let (task, channel) = try await relayClient.connectViaRelay(
                origin: origin,
                hostID: host.id,
                relayToken: token,
                localStaticKey: localKeyPair,
                hostStaticPublicKey: hostKey,
                psk: nil
            )
            let transport = try await EncryptedChannelTransport(
                task: task,
                channel: channel,
                hello: HelloMessage(client: clientInfo, features: helloFeatures),
                welcomeTimeout: EncryptedChannelTransport.knownHostWelcomeTimeout
            )
            await finishAccountHostAttach(host: host, hostKey: hostKey, origin: origin, transport: transport)
            return
        } catch let rpcErr as PortRPCError where rpcErr.message == "unknown_device" || rpcErr.message == "removed" {
            // First connect from this signed-in device: run same-account discovery handshake.
        } catch {
            connectionError = error.localizedDescription
            return
        }

        do {
            let (task, channel) = try await relayClient.connectViaRelay(
                origin: origin,
                hostID: host.id,
                relayToken: token,
                localStaticKey: localKeyPair,
                hostStaticPublicKey: hostKey,
                psk: nil,
                prologue: DiscoveryPairProtocol.prologue
            )
            let hello = HelloMessage(
                client: clientInfo,
                device: HelloDeviceInfo(name: deviceName, model: modelName),
                features: helloFeatures
            )
            let transport = try await EncryptedChannelTransport(
                task: task,
                channel: channel,
                hello: hello,
                welcomeTimeout: nil,
                confirmDiscoveryCode: { [weak self] code in
                    await self?.awaitDiscoveryConfirmation(host: host, code: code) ?? false
                }
            )
            await finishAccountHostAttach(host: host, hostKey: hostKey, origin: origin, transport: transport)
        } catch {
            reportConnectionError(error)
        }
    }

    private func finishAccountHostAttach(
        host: RelayListedHost,
        hostKey: Data,
        origin: String,
        transport: EncryptedChannelTransport
    ) async {
        let welcome = transport.welcome
        let record = PairedHostRecord(
            id: host.id,
            name: welcome.host.name,
            platform: welcome.host.platform,
            hostPublicKey: BaseEncoding.base64URLEncode(hostKey),
            addresses: welcome.addresses,
            relayID: host.id,
            relayURLs: [origin],
            lastConnectedAt: Date()
        )
        upsertPairedHost(record)
        lastConnectedHost = record
        let session = SartoHostSession(transport: transport)
        if await attachLiveSession(session, mode: .remoteHost(name: record.name, viaRelay: true)) {
            Task { [weak self] in
                await self?.syncRemoteHostSigningKey(session: session, hostKey: hostKey)
            }
        }
    }

    private func awaitDiscoveryConfirmation(host: RelayListedHost, code: String) async -> Bool {
        pendingDiscoveryHost = host
        pendingDiscoveryCode = code
        return await withCheckedContinuation { continuation in
            discoveryConfirmationContinuation?.resume(returning: false)
            discoveryConfirmationContinuation = continuation
        }
    }

    public func answerDiscoveryConfirmation(matched: Bool) {
        let cont = discoveryConfirmationContinuation
        discoveryConfirmationContinuation = nil
        if !matched {
            pendingDiscoveryHost = nil
            pendingDiscoveryCode = nil
        }
        cont?.resume(returning: matched)
    }

    /// Returns true once the host is the live connection.
    @discardableResult
    public func connectPairedHost(_ host: PairedHostRecord) async -> Bool {
        await connectPairedHost(host, cancelsReconnect: true)
    }

    private func connectPairedHost(_ host: PairedHostRecord, cancelsReconnect: Bool) async -> Bool {
        if daemonOtherHosts != nil {
            return await switchActiveHost(to: host.id, cancelsReconnect: cancelsReconnect)
        }
        if cancelsReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        lastConnectRefusedByRelay = false
        guard let hostKey = host.hostPublicKeyData else {
            connectionError = "Stored host key is invalid"
            return false
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            let (task, channel, viaRelay) = try await dialHost(
                hostPublicKey: hostKey,
                addresses: host.addresses,
                relayID: host.relayID,
                relayURLs: host.relayURLs,
                psk: nil,
                hostName: host.name
            )
            #if os(macOS)
            let clientInfo = HelloClientInfo(kind: "desktop", version: "0.1.0", platform: "darwin")
            let helloFeatures = ["image-refs", "browser", "tool-digests"]
            #else
            let clientInfo = HelloClientInfo(kind: "ios", version: "0.1.0", platform: "ios")
            let helloFeatures = ["image-refs", "tool-digests"]
            #endif
            let transport = try await EncryptedChannelTransport(
                task: task,
                channel: channel,
                hello: HelloMessage(client: clientInfo, features: helloFeatures),
                welcomeTimeout: EncryptedChannelTransport.knownHostWelcomeTimeout
            )
            lastConnectedHost = host
            let session = SartoHostSession(transport: transport)
            let attached = await attachLiveSession(
                session,
                terminal: nil,
                mode: .remoteHost(name: host.name, viaRelay: viaRelay),
                cancelsReconnect: cancelsReconnect
            )
            if attached {
                Task { [weak self] in
                    await self?.syncRemoteHostSigningKey(session: session, hostKey: hostKey)
                }
            }
            return attached
        } catch {
            if let refusal = (error as? RelayClientError)?.relayRefusal,
               refusal == .forbidden || refusal == .unauthorized {
                lastConnectRefusedByRelay = true
            }
            connectionError = error.localizedDescription
            return false
        }
    }

    /// Makes the daemon's host `id` the live connection, through the hosts socket; true once it is.
    private func connectOtherHost(id: String, name: String, viaRelay: Bool, cancelsReconnect: Bool) async -> Bool {
        guard let daemon = daemonOtherHosts else { return false }
        if cancelsReconnect {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            let opened = try await daemon.open(id)
            lastOtherHostID = id
            hostLinkDropped = false
            return await attachLiveSession(
                opened.agent,
                terminal: opened.terminal,
                mode: .remoteHost(name: name, viaRelay: viaRelay),
                cancelsReconnect: cancelsReconnect
            )
        } catch {
            connectionError = error.localizedDescription
            return false
        }
    }

    private func dialHost(
        hostPublicKey: Data,
        addresses: [DirectAddress],
        relayID: String?,
        relayURLs: [String],
        psk: Data?,
        hostName: String?
    ) async throws -> (URLSessionWebSocketTask, SartoChannel, Bool) {
        for addr in addresses {
            let formattedHost = addr.host.contains(":") ? "[\(addr.host)]" : addr.host
            if let url = URL(string: "ws://\(formattedHost):\(addr.port)/channel") {
                if let (task, channel) = try? await relayClient.connectDirect(
                    channelURL: url,
                    localStaticKey: localKeyPair,
                    hostStaticPublicKey: hostPublicKey,
                    psk: psk
                ) {
                    return (task, channel, false)
                }
            }
        }

        let token = await resolveRelayBearerToken()
        guard let relayID, !token.isEmpty else {
            throw PortRPCError(
                code: "host_offline",
                message: "No Sarto Cloud / Server relay token or host relay ID is configured"
            )
        }
        let trimmedOrigin = relayOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        // The token goes only to the configured relay and the hosts under it, whatever a pairing
        // link or a stored host names; any other relay is skipped, never asked.
        var origins: [String] = []
        for origin in relayURLs + [trimmedOrigin] where !origin.isEmpty && !origins.contains(origin) {
            if origin == trimmedOrigin || RelayProtocol.isTrustedRelay(origin, main: trimmedOrigin) {
                origins.append(origin)
            }
        }
        guard !origins.isEmpty else {
            throw PortRPCError(
                code: "host_offline",
                message: "No Sarto Cloud / Server URL is configured"
            )
        }
        var lastErr: Error = RelayClientError.invalidURL
        var offlineRefusal: RelayClientError?
        for origin in origins {
            do {
                let (task, channel) = try await relayClient.connectViaRelay(
                    origin: origin,
                    hostID: relayID,
                    relayToken: token,
                    localStaticKey: localKeyPair,
                    hostStaticPublicKey: hostPublicKey,
                    psk: psk
                )
                return (task, channel, true)
            } catch let error as RelayClientError {
                switch error.relayRefusal {
                case .forbidden?, .unauthorized?:
                    // The device or token is refused for this host; every other relay answers the same.
                    throw error
                case .offline?:
                    // The host may be joined to another region, so keep trying the remaining relays.
                    offlineRefusal = error
                default:
                    lastErr = error
                }
            } catch {
                lastErr = error
            }
        }
        if let offlineRefusal {
            let reason = offlineRefusal.localizedDescription
            let message = hostName.map { l10n.tr("connection.hostOfflineNamed", $0, reason) }
                ?? l10n.tr("connection.hostOffline", reason)
            throw PortRPCError(code: "host_offline", message: message)
        }
        throw lastErr
    }

    private func upsertPairedHost(_ record: PairedHostRecord) {
        var merged = record
        if let idx = pairedHosts.firstIndex(where: { $0.id == record.id }) {
            if merged.hostEd25519PublicKey == nil {
                merged.hostEd25519PublicKey = pairedHosts[idx].hostEd25519PublicKey
            }
            pairedHosts[idx] = merged
        } else {
            pairedHosts.insert(merged, at: 0)
        }
        identityStore.save(keyPair: localKeyPair, hosts: pairedHosts)
    }

    /// Keeps the push signing key the connected host names, on the record paired with `hostKey`,
    /// the key its Noise handshake proved. An id the host claims selects nothing, or one host
    /// could replace the signing key of another.
    private func syncRemoteHostSigningKey(session: SartoHostSession, hostKey: Data) async {
        guard let res = try? await session.request("notifications.get"),
              let hostObj = res.objectValue?["host"]?.objectValue,
              let signingKey = hostObj["key"]?.stringValue,
              !signingKey.isEmpty
        else { return }

        var updated = false
        for idx in pairedHosts.indices where pairedHosts[idx].hostPublicKeyData == hostKey {
            if pairedHosts[idx].hostEd25519PublicKey != signingKey {
                pairedHosts[idx].hostEd25519PublicKey = signingKey
                updated = true
            }
        }
        if updated {
            identityStore.save(keyPair: localKeyPair, hosts: pairedHosts)
        }
    }

    // MARK: - Sarto E2EE Multi-Device Workspace Sync Hydration

    public func markUiPrefMutated(_ key: String, at timestampMs: Double? = nil) {
        guard !isInitializingPrefs && !isApplyingSyncedPrefs else { return }
        let stamp = timestampMs ?? (Date().timeIntervalSince1970 * 1000.0)
        uiTimestamps[key] = stamp
        saveUiTimestamps()
        onLocalUiPrefsMutated?()
    }

    public func markUiPrefsMutated(_ keys: [String], at timestampMs: Double? = nil) {
        guard !isInitializingPrefs && !isApplyingSyncedPrefs, !keys.isEmpty else { return }
        let stamp = timestampMs ?? (Date().timeIntervalSince1970 * 1000.0)
        for key in keys {
            uiTimestamps[key] = stamp
        }
        saveUiTimestamps()
        onLocalUiPrefsMutated?()
    }

    private static let browserOriginKeyPrefix = "browserAllowedOrigins:"

    private func handleLocalBrowserAllowedOriginsChanged() {
        let current = browser.exportedProjectAllowedOrigins()
        let allPaths = Set(lastExportedBrowserOrigins.keys).union(current.keys)
        var changedKeys: [String] = []
        for path in allPaths where lastExportedBrowserOrigins[path] != current[path] {
            changedKeys.append(Self.browserOriginKeyPrefix + path)
        }
        lastExportedBrowserOrigins = current
        if !changedKeys.isEmpty {
            markUiPrefsMutated(changedKeys)
        }
    }

    private func saveUiTimestamps() {
        if let data = try? JSONEncoder().encode(uiTimestamps) {
            UserDefaults.standard.set(data, forKey: PrefKey.uiTimestamps)
        }
    }

    private func saveSyncedHostIDs() {
        UserDefaults.standard.set(Array(syncedHostIDs).sorted(), forKey: PrefKey.syncedHostIDs)
    }

    public func localTrustedDeviceInput(deviceName: String) -> SartoTrustedDeviceInput {
        let pubData = localKeyPair.publicKeyData
        let digest = SHA256.hash(data: pubData)
        let idHex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        #if os(macOS)
        let kind = "desktop"
        let platform = "darwin"
        let model = "Mac"
        #else
        let kind = "ios"
        let platform = "ios"
        let model = "iPhone"
        #endif
        return SartoTrustedDeviceInput(
            id: idHex,
            publicKey: pubData.base64EncodedString(),
            name: deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? model : deviceName,
            kind: kind,
            platform: platform,
            model: model
        )
    }

    public func buildSyncedUiPrefsPayload(
        extraPrefs: [String: JSONValue] = [:]
    ) -> [String: SartoSyncedUiPrefEntry] {
        let notifObj: [String: JSONValue] = [
            "permissionNeeded": .bool(notificationPrefs.permissionNeeded),
            "turnEnded": .bool(notificationPrefs.turnEnded),
            "error": .bool(notificationPrefs.error),
            "soundEnabled": .bool(notificationPrefs.soundEnabled),
            "dockBadgeEnabled": .bool(notificationPrefs.dockBadgeEnabled),
            "inAppNoticeMode": .string(notificationPrefs.inAppNoticeMode.rawValue),
        ]
        let wideWidth = UserDefaults.standard.bool(forKey: PrefKey.threadWideWidth)
        let runningRail = UserDefaults.standard.object(forKey: "sarto.runningRail.enabled") as? Bool ?? true
        let exportedOrigins = browser.exportedProjectAllowedOrigins()
        var rawValues: [String: JSONValue] = [
            "language": .string(language.rawValue),
            "palette": .string(palette.rawValue),
            "darkPalette": .string(darkPalette.rawValue),
            "lightPalette": .string(lightPalette.rawValue),
            "colorMode": .string(colorMode.rawValue),
            "accentMode": .string(accentMode.rawValue),
            "appIconStyle": .string(appIconStyle.rawValue),
            "motionTier": .string(motionTier.rawValue),
            "sendKeyMode": .string(sendKeyMode.rawValue),
            "defaultAgentID": defaultAgentID.map(JSONValue.string) ?? .null,
            "restoreLastSession": .bool(restoreLastSession),
            "textSize": .string(textSize.rawValue),
            "threadWideWidth": .bool(wideWidth),
            "uiFontFamily": .string(uiFontFamily),
            "proseFontFamily": .string(proseFontFamily),
            "codeFontFamily": .string(codeFontFamily),
            "terminalFontSize": .number(Double(terminalFontSize)),
            "terminalFontFamily": .string(terminalFontFamily),
            "notifications": .object(notifObj),
            "runningRailEnabled": .bool(runningRail),
        ]
        // Emit per-project browser allowed-origin keys so Macs approving different projects merge cleanly.
        var originPaths = Set(exportedOrigins.keys)
        for key in uiTimestamps.keys where key.hasPrefix(Self.browserOriginKeyPrefix) {
            originPaths.insert(String(key.dropFirst(Self.browserOriginKeyPrefix.count)))
        }
        for proj in originPaths {
            let list = exportedOrigins[proj] ?? []
            rawValues[Self.browserOriginKeyPrefix + proj] = .array(list.map(JSONValue.string))
        }
        for (k, v) in extraPrefs {
            rawValues[k] = v
        }
        var out: [String: SartoSyncedUiPrefEntry] = [:]
        for (k, val) in rawValues {
            out[k] = SartoSyncedUiPrefEntry(value: val, updatedAt: uiTimestamps[k] ?? 0)
        }
        return out
    }

    public func applyAccountStatus(_ status: CloudAccountStatusInfo) {
        let wasSignedIn = cloudAccountStatus.account.isSignedIn
        let previousOrigin = cloudAccountStatus.origin
        cloudAccountStatus = status
        if status.account.isSignedIn,
           !status.origin.isEmpty,
           relayOrigin != status.origin {
            relayOrigin = status.origin
        }
        if status.account.isSignedIn {
            if !wasSignedIn || relayLatencyTask == nil || previousOrigin != status.origin {
                startRelayLatencyMonitoring()
            }
        } else if wasSignedIn || relayLatencyTask != nil || relayLatencyMs != nil || relayLatencyFailed {
            stopRelayLatencyMonitoring()
        }
        if status.account.isSignedIn != wasSignedIn && daemonOtherHosts != nil {
            reconcileRemoteHostPool(with: otherHosts)
        }
    }

    public func applySyncedStatus(_ status: SartoSyncStatusInfo) {
        let prevRevs = sartoSyncStatus.revisions
        sartoSyncStatus = status

        if status.mode != "off",
           !status.serverUrl.isEmpty,
           relayOrigin != status.serverUrl {
            relayOrigin = status.serverUrl
        }
        // In `account` mode relay tokens come on-demand from `account.relayToken`, never `sync.status`.
        if status.mode != "off",
           status.mode != "account",
           let rt = status.relayToken,
           !rt.isEmpty,
           relayBearerToken != rt {
            relayBearerToken = rt
        }

        // Hydrate UI preferences when remote timestamps beat local timestamps (or on fresh install `ts == 0`).
        if !status.uiPrefs.isEmpty {
            let prevEffectivePalette = palette
            isApplyingSyncedPrefs = true
            isBatchUpdatingPalette = true
            var tsChanged = false
            var adoptedThemePref = false

            func shouldAdopt(_ key: String, _ remote: SartoSyncedUiPrefEntry) -> Bool {
                let localTs = uiTimestamps[key] ?? 0
                return remote.updatedAt > localTs || (localTs == 0 && remote.updatedAt == 0)
            }

            func recordAdopted(_ key: String, _ remote: SartoSyncedUiPrefEntry) {
                if uiTimestamps[key] != remote.updatedAt {
                    uiTimestamps[key] = remote.updatedAt
                    tsChanged = true
                }
            }

            if let e = status.uiPrefs["language"], shouldAdopt("language", e),
               let s = e.value.stringValue, let lang = PrismLanguage(rawValue: s) {
                if language != lang { language = lang }
                recordAdopted("language", e)
            }
            if let e = status.uiPrefs["darkPalette"], shouldAdopt("darkPalette", e),
               let s = e.value.stringValue, let p = PrismPalette(rawValue: s), p.isDark {
                if darkPalette != p { darkPalette = p }
                adoptedThemePref = true
                recordAdopted("darkPalette", e)
            }
            if let e = status.uiPrefs["lightPalette"], shouldAdopt("lightPalette", e),
               let s = e.value.stringValue, let p = PrismPalette(rawValue: s), !p.isDark {
                if lightPalette != p { lightPalette = p }
                adoptedThemePref = true
                recordAdopted("lightPalette", e)
            }
            if let e = status.uiPrefs["palette"], shouldAdopt("palette", e),
               let s = e.value.stringValue, let p = PrismPalette(rawValue: s) {
                if palette != p { palette = p }
                adoptedThemePref = true
                recordAdopted("palette", e)
            }
            if let e = status.uiPrefs["colorMode"], shouldAdopt("colorMode", e),
               let s = e.value.stringValue, let m = PrismColorMode(rawValue: s) {
                if colorMode != m { colorMode = m }
                adoptedThemePref = true
                recordAdopted("colorMode", e)
            }
            if adoptedThemePref {
                syncPaletteForColorMode()
            }
            if let e = status.uiPrefs["accentMode"], shouldAdopt("accentMode", e),
               let s = e.value.stringValue, let a = PrismAccentMode(rawValue: s) {
                if accentMode != a { accentMode = a }
                recordAdopted("accentMode", e)
            }
            if let e = status.uiPrefs["appIconStyle"], shouldAdopt("appIconStyle", e),
               let s = e.value.stringValue, let icon = PrismAppIconStyle.fromPersistedRawValue(s) {
                if appIconStyle != icon { appIconStyle = icon }
                recordAdopted("appIconStyle", e)
            }
            if let e = status.uiPrefs["motionTier"], shouldAdopt("motionTier", e),
               let s = e.value.stringValue, let t = PrismMotionTier(rawValue: s) {
                if motionTier != t { motionTier = t }
                recordAdopted("motionTier", e)
            }
            if let e = status.uiPrefs["sendKeyMode"], shouldAdopt("sendKeyMode", e),
               let s = e.value.stringValue, let m = PrismSendKeyMode(rawValue: s) {
                if sendKeyMode != m { sendKeyMode = m }
                recordAdopted("sendKeyMode", e)
            }
            if let e = status.uiPrefs["defaultAgentID"], shouldAdopt("defaultAgentID", e) {
                let nextVal: String? = e.value == .null ? nil : e.value.stringValue
                if defaultAgentID != nextVal { defaultAgentID = nextVal }
                recordAdopted("defaultAgentID", e)
            }
            if let e = status.uiPrefs["restoreLastSession"], shouldAdopt("restoreLastSession", e),
               let b = e.value.boolValue {
                if restoreLastSession != b { restoreLastSession = b }
                recordAdopted("restoreLastSession", e)
            }
            if let e = status.uiPrefs["textSize"], shouldAdopt("textSize", e),
               let s = e.value.stringValue, let ts = PrismTextSize(rawValue: s) {
                if textSize != ts { textSize = ts }
                recordAdopted("textSize", e)
            }
            if let e = status.uiPrefs["threadWideWidth"], shouldAdopt("threadWideWidth", e),
               let b = e.value.boolValue {
                if UserDefaults.standard.bool(forKey: PrefKey.threadWideWidth) != b {
                    UserDefaults.standard.set(b, forKey: PrefKey.threadWideWidth)
                }
                recordAdopted("threadWideWidth", e)
            }
            if let e = status.uiPrefs["runningRailEnabled"], shouldAdopt("runningRailEnabled", e),
               let b = e.value.boolValue {
                let cur = UserDefaults.standard.object(forKey: "sarto.runningRail.enabled") as? Bool ?? true
                if cur != b {
                    UserDefaults.standard.set(b, forKey: "sarto.runningRail.enabled")
                }
                recordAdopted("runningRailEnabled", e)
            }
            // Per-project browser allowed origins (falls back to legacy whole-dict entry if absent).
            var originPatch: [String: [String]] = [:]
            var hasPerProjectOriginKeys = false
            for (key, e) in status.uiPrefs where key.hasPrefix(Self.browserOriginKeyPrefix) {
                hasPerProjectOriginKeys = true
                guard shouldAdopt(key, e), let arr = e.value.arrayValue else { continue }
                let proj = String(key.dropFirst(Self.browserOriginKeyPrefix.count))
                guard !proj.isEmpty else { continue }
                originPatch[proj] = arr.compactMap(\.stringValue)
                recordAdopted(key, e)
            }
            if !originPatch.isEmpty {
                browser.applySyncedProjectAllowedOriginsPatch(originPatch)
                lastExportedBrowserOrigins = browser.exportedProjectAllowedOrigins()
            } else if !hasPerProjectOriginKeys,
                      let e = status.uiPrefs["browserAllowedOrigins"],
                      shouldAdopt("browserAllowedOrigins", e),
                      let obj = e.value.objectValue {
                var parsed: [String: [String]] = [:]
                for (proj, val) in obj {
                    if let arr = val.arrayValue {
                        let origins = arr.compactMap(\.stringValue)
                        if !origins.isEmpty {
                            parsed[proj] = origins
                        }
                    }
                }
                browser.applySyncedProjectAllowedOriginsPatch(parsed)
                lastExportedBrowserOrigins = browser.exportedProjectAllowedOrigins()
                recordAdopted("browserAllowedOrigins", e)
            }
            if let e = status.uiPrefs["uiFontFamily"], shouldAdopt("uiFontFamily", e),
               let s = e.value.stringValue {
                if uiFontFamily != s { uiFontFamily = s }
                recordAdopted("uiFontFamily", e)
            }
            if let e = status.uiPrefs["proseFontFamily"], shouldAdopt("proseFontFamily", e),
               let s = e.value.stringValue {
                if proseFontFamily != s { proseFontFamily = s }
                recordAdopted("proseFontFamily", e)
            }
            if let e = status.uiPrefs["codeFontFamily"], shouldAdopt("codeFontFamily", e),
               let s = e.value.stringValue {
                if codeFontFamily != s { codeFontFamily = s }
                recordAdopted("codeFontFamily", e)
            }
            if let e = status.uiPrefs["terminalFontSize"], shouldAdopt("terminalFontSize", e),
               let d = e.value.doubleValue {
                if let sz = Int.wholePart(of: d), [11, 12, 13, 14, 15, 16].contains(sz), terminalFontSize != sz {
                    terminalFontSize = sz
                }
                recordAdopted("terminalFontSize", e)
            }
            if let e = status.uiPrefs["terminalFontFamily"], shouldAdopt("terminalFontFamily", e),
               let s = e.value.stringValue {
                if terminalFontFamily != s { terminalFontFamily = s }
                recordAdopted("terminalFontFamily", e)
            }
            if let e = status.uiPrefs["notifications"], shouldAdopt("notifications", e),
               let obj = e.value.objectValue {
                var next = notificationPrefs
                if let b = obj["permissionNeeded"]?.boolValue { next.permissionNeeded = b }
                if let b = obj["turnEnded"]?.boolValue { next.turnEnded = b }
                if let b = obj["error"]?.boolValue { next.error = b }
                if let b = obj["soundEnabled"]?.boolValue { next.soundEnabled = b }
                if let b = obj["dockBadgeEnabled"]?.boolValue { next.dockBadgeEnabled = b }
                if let raw = obj["inAppNoticeMode"]?.stringValue,
                   let mode = PrismInAppNoticeMode(rawValue: raw) {
                    next.inAppNoticeMode = mode
                }
                if notificationPrefs != next { notificationPrefs = next }
                recordAdopted("notifications", e)
            }

            let prevTsSnapshot = uiTimestamps
            onApplySyncedIslandPrefs?(status.uiPrefs, &uiTimestamps)
            if uiTimestamps != prevTsSnapshot {
                tsChanged = true
            }
            isApplyingSyncedPrefs = false
            isBatchUpdatingPalette = false
            if tsChanged {
                saveUiTimestamps()
            }
            if palette != prevEffectivePalette {
                onEffectivePaletteChanged?(palette)
            }
        }

        // Auto-trust Workspace Computers (excluding this local Mac's own daemon identity) and
        // prune previously cloud-synced hosts that were removed from the workspace.
        if daemonOtherHosts != nil {
            // The daemon keeps the account's hosts itself (src/remote-host/mesh-hosts.ts).
        } else if status.isVaultReady {
            var changedHosts = false
            var activeSyncedIDs = Set<String>()
            for host in status.trustedHosts {
                if let ownPub = status.hostPublicKey, !ownPub.isEmpty, host.publicKey == ownPub {
                    continue
                }
                if let ownRelay = status.relayId, !ownRelay.isEmpty, host.relayId == ownRelay {
                    continue
                }
                guard let pkData = Data(base64Encoded: host.publicKey), pkData.count == 32 else {
                    continue
                }
                let b64url = BaseEncoding.base64URLEncode(pkData)
                let recordID = host.relayId ?? host.id
                activeSyncedIDs.insert(recordID)
                let urls = [host.relayUrl, status.serverUrl]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var dedupURLs: [String] = []
                for u in urls where !dedupURLs.contains(u) { dedupURLs.append(u) }

                let record = PairedHostRecord(
                    id: recordID,
                    name: host.name,
                    platform: host.platform,
                    hostPublicKey: b64url,
                    addresses: [],
                    relayID: host.relayId,
                    relayURLs: dedupURLs
                )
                if let idx = pairedHosts.firstIndex(where: { $0.id == recordID || $0.hostPublicKey == b64url }) {
                    var merged = record
                    merged.lastConnectedAt = pairedHosts[idx].lastConnectedAt
                    merged.hostEd25519PublicKey = pairedHosts[idx].hostEd25519PublicKey
                    if pairedHosts[idx] != merged {
                        pairedHosts[idx] = merged
                        changedHosts = true
                    }
                } else {
                    pairedHosts.append(record)
                    changedHosts = true
                }
            }
            let staleSyncedIDs = syncedHostIDs.subtracting(activeSyncedIDs)
            if !staleSyncedIDs.isEmpty {
                let beforeCount = pairedHosts.count
                pairedHosts.removeAll { staleSyncedIDs.contains($0.id) }
                if pairedHosts.count != beforeCount {
                    changedHosts = true
                }
            }
            if syncedHostIDs != activeSyncedIDs {
                syncedHostIDs = activeSyncedIDs
                saveSyncedHostIDs()
            }
            if changedHosts {
                identityStore.save(keyPair: localKeyPair, hosts: pairedHosts)
            }
        } else if status.mode == "off", !syncedHostIDs.isEmpty {
            let beforeCount = pairedHosts.count
            pairedHosts.removeAll { syncedHostIDs.contains($0.id) }
            syncedHostIDs.removeAll()
            saveSyncedHostIDs()
            if pairedHosts.count != beforeCount {
                identityStore.save(keyPair: localKeyPair, hosts: pairedHosts)
            }
        }

        // Refresh agent list/options when host-config, mcp-servers, mcp-vault, skills, or memory revisions advance.
        if prevRevs != status.revisions, case .localDaemon = connectionMode {
            Task { [weak self] in
                await self?.refreshAgentsFromHost()
            }
        }
    }
}

// MARK: - Edit From a Sent Message (Rewind & Put Back)

extension SartoState {
    /// The edit the active session holds, whose turns Put back brings back.
    public var activeRewound: RewoundView? {
        guard !showStudioHome else { return nil }
        return activeReplica?.session.rewound
    }

    /// Whether the active session's messages can be edited from, as the host allows: not a subagent's or
    /// an archived session, an agent that can cut its conversation, and a session that has started.
    public var canEditActiveFromMessage: Bool {
        guard !showStudioHome,
              hostSession != nil,
              let summary = selectedSessionSummary,
              summary.origin != "subagent",
              summary.archivedAt == nil,
              activeAgentCapabilities?.rewind == true,
              let replica = activeReplica,
              replica.session.origin != "subagent",
              replica.session.noRewind != true,
              replica.session.status != .starting
        else { return false }
        return !rewindBusySessionIDs.contains(summary.id)
    }

    /// Edit from a message: the host sets the turns from it aside and gives the message back, which goes
    /// into the composer above what it held, after a blank line. What it held goes with the edit for Put back.
    /// Returns whether the message came back.
    @discardableResult
    public func editFromMessage(entryId: String) async -> Bool {
        guard let sessionId = selectedSessionSummary?.id,
              let hostSession,
              !rewindBusySessionIDs.contains(sessionId)
        else { return false }
        let heldText = draftTextByScope[sessionId] ?? ""
        let heldAttachments = (draftAttachmentsByScope[sessionId] ?? []).compactMap(\.readyAttachment)
        var draft: [UserContent] = []
        if !heldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft.append(.text(heldText))
        }
        draft += heldAttachments.map { .ref(.attachment($0)) }

        rewindBusySessionIDs.insert(sessionId)
        defer { rewindBusySessionIDs.remove(sessionId) }
        connectionError = nil
        do {
            let content = try await hostSession.rewindSession(sessionId: sessionId, entryId: entryId, draft: draft)
            // Read again: the composer may have changed while the host worked.
            let message = SessionRewind.promptText(content)
            let written = draftTextByScope[sessionId] ?? ""
            if !message.isEmpty {
                let keepsWritten = !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                draftTextByScope[sessionId] = keepsWritten ? "\(message)\n\n\(written)" : message
            }
            let existing = draftAttachmentsByScope[sessionId] ?? []
            let shown = Set(existing.compactMap { $0.readyAttachment?.id })
            let restored = rewindDraftItems(SessionRewind.attachments(content), sessionId: sessionId)
                .filter { item in item.readyAttachment.map { !shown.contains($0.id) } ?? true }
            if !restored.isEmpty {
                draftAttachmentsByScope[sessionId] = Array((restored + existing).prefix(AttachmentLimits.maxAttachments))
            }
            persistDraft(scope: sessionId)
            Task { [weak self] in await self?.refreshOutline(sessionId: sessionId) }
            return true
        } catch {
            connectionError = l10n.tr("thread.editFrom.failed", error.localizedDescription)
            return false
        }
    }

    /// Put back: the turns an edit set aside return, and the composer holds what it did before the edit.
    public func putBackRewound() async {
        guard let sessionId = selectedSessionSummary?.id,
              let hostSession,
              !rewindBusySessionIDs.contains(sessionId)
        else { return }
        rewindBusySessionIDs.insert(sessionId)
        defer { rewindBusySessionIDs.remove(sessionId) }
        connectionError = nil
        do {
            let draft = try await hostSession.putBackSession(sessionId: sessionId)
            draftTextByScope[sessionId] = SessionRewind.promptText(draft)
            // The composer's attachments become the draft's: the others go with their records, and one of
            // the draft the composer no longer shows comes back.
            let wanted = SessionRewind.attachments(draft)
            let wantedIDs = Set(wanted.map(\.id))
            let items = draftAttachmentsByScope[sessionId] ?? []
            let kept = items.filter { item in item.readyAttachment.map { wantedIDs.contains($0.id) } ?? false }
            for item in items where !kept.contains(item) {
                if let record = item.readyAttachment {
                    Task { try? await hostSession.removeAttachment(id: record.id) }
                }
            }
            let shown = Set(kept.compactMap { $0.readyAttachment?.id })
            let back = rewindDraftItems(wanted.filter { !shown.contains($0.id) }, sessionId: sessionId)
            draftAttachmentsByScope[sessionId] = Array((kept + back).prefix(AttachmentLimits.maxAttachments))
            persistDraft(scope: sessionId)
            if !(draftAttachmentsByScope[sessionId] ?? []).contains(where: { $0.failureMessage != nil }) {
                attachmentBannerError = nil
            }
            Task { [weak self] in await self?.refreshOutline(sessionId: sessionId) }
        } catch {
            connectionError = l10n.tr("composer.rewound.putBackFailed", error.localizedDescription)
        }
    }

    /// Composer tiles for attachment records the host already holds, as a queued prompt's edit makes them.
    private func rewindDraftItems(_ attachments: [AttachmentInfo], sessionId: String) -> [DraftAttachmentItem] {
        attachments.map { att in
            let kind: DraftAttachmentItem.Kind = switch att.type {
            case "image": .image
            case "folder": .folder
            case "text": .text
            default: .file
            }
            let thumbData = PrismImageDecoder.decodeDataURL(att.thumb)
            let cachedBlob = att.blob.flatMap { sessionBlobCache["\(sessionId):\($0)"] }
            return DraftAttachmentItem(
                name: att.name,
                kind: kind,
                mimeType: att.mimeType ?? (kind == .image ? "image/png" : "application/octet-stream"),
                size: att.size ?? 0,
                status: .ready(att),
                thumbnailData: thumbData ?? cachedBlob,
                thumbDataURL: att.thumb,
                previewImageData: cachedBlob ?? thumbData
            )
        }
    }

    // MARK: - Host System Load, Focused Attention Notices & Markdown Export

    /// Returns the latest system load sample for `hostId` (`nil` resolves to the local host).
    public func hostLoad(for hostId: String?) -> HostLoad? {
        hostLoadsByHostID[hostId ?? Self.localHostID]
    }

    public func beginWatchingHostLoads() {
        hostLoadWatcherCount += 1
        guard hostLoadWatcherCount == 1 else { return }
        startHostLoadLeaseLoop()
    }

    public func endWatchingHostLoads() {
        hostLoadWatcherCount = max(0, hostLoadWatcherCount - 1)
        guard hostLoadWatcherCount == 0 else { return }
        hostLoadLeaseTask?.cancel()
        hostLoadLeaseTask = nil
        let targets = connectedHostSessionsForLoad()
        Task { @MainActor in
            for (_, session) in targets {
                try? await session.unwatchHostLoad()
            }
        }
    }

    private func connectedHostSessionsForLoad() -> [(String, SartoHostSession)] {
        var result: [(String, SartoHostSession)] = []
        var seen = Set<String>()
        for (id, slot) in hostPool {
            result.append((id, slot.agent))
            seen.insert(id)
        }
        if let active = hostSession, !seen.contains(activeHostID) {
            result.append((activeHostID, active))
        }
        return result
    }

    private func startHostLoadLeaseLoop() {
        hostLoadLeaseTask?.cancel()
        hostLoadLeaseTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.hostLoadWatcherCount > 0 {
                let targets = self.connectedHostSessionsForLoad()
                await withTaskGroup(of: (String, HostLoad?).self) { group in
                    for (hostId, session) in targets {
                        group.addTask {
                            let sample = try? await session.watchHostLoad().load
                            return (hostId, sample)
                        }
                    }
                    for await (hostId, sample) in group {
                        if let sample {
                            self.hostLoadsByHostID[hostId] = sample
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(HostLoadConstants.renewSeconds))
            }
        }
    }

    public func dismissFocusedAttentionNotice() {
        focusedAttentionDismissTask?.cancel()
        focusedAttentionDismissTask = nil
        focusedAttentionIsHovered = false
        focusedAttentionSessionIDs.removeAll()
        focusedAttentionNotice = nil
    }

    public func setFocusedAttentionHovered(_ hovered: Bool) {
        guard focusedAttentionIsHovered != hovered else { return }
        focusedAttentionIsHovered = hovered
        if hovered {
            focusedAttentionDismissTask?.cancel()
            focusedAttentionDismissTask = nil
        } else if focusedAttentionNotice != nil {
            scheduleFocusedAttentionAutoDismiss()
        }
    }

    private func scheduleFocusedAttentionAutoDismiss() {
        focusedAttentionDismissTask?.cancel()
        let seconds = Self.focusedAttentionAutoDismissSeconds
        focusedAttentionDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.focusedAttentionIsHovered else { return }
            self.dismissFocusedAttentionNotice()
        }
    }

    public func openFocusedAttentionNotice() async {
        guard let notice = focusedAttentionNotice else { return }
        dismissFocusedAttentionNotice()
        if notice.hostId != activeHostID {
            let switched = await switchActiveHost(to: notice.hostId)
            guard switched else { return }
        }
        await selectSession(notice.sessionId)
    }

    /// Whether notifications, reminders, and the Dock icon badge on this Mac should include events
    /// from `hostId`: always true for this Mac itself, and true for a remote synced host while it
    /// is the workbench's active host (`activeHostID`).
    public func shouldNotifyForHost(_ hostId: String) -> Bool {
        hostId == Self.localHostID || hostId == activeHostID
    }

    /// Updates whether this app has a focused, visible main window and reconciles `sessions.show`
    /// so every host tracks `inFront` and `attention` accurately across synced devices.
    public func updateForegroundPresence(isInForeground: Bool) {
        if isForegroundWindowVisible != isInForeground {
            isForegroundWindowVisible = isInForeground
        }
        syncReportedShownSessions()
    }

    internal func clearReportedShownSessionsIfDifferentHost(
        from targetHostId: String,
        session targetSession: SartoHostSession?
    ) {
        guard let prev = lastReportedShownSession, !prev.ids.isEmpty else { return }
        let sameTarget = targetSession.map { ObjectIdentifier($0) == prev.sessionObjectId } ?? false
        guard prev.hostId != targetHostId || !sameTarget else { return }
        if let prevHost = resolveHostSession(for: prev.hostId),
           ObjectIdentifier(prevHost) == prev.sessionObjectId {
            Task { try? await prevHost.showSessions([]) }
        }
        lastReportedShownSession = nil
    }

    internal func syncReportedShownSessions() {
        let desiredHost = hostSession
        let desiredHostId = activeHostID
        let desiredIds: [String] = (isForegroundWindowVisible && !showStudioHome)
            ? (selectedSessionID.map { [$0] } ?? [])
            : []

        if let prev = lastReportedShownSession {
            let sameTarget = desiredHost.map { ObjectIdentifier($0) == prev.sessionObjectId } ?? false
            if prev.hostId == desiredHostId && sameTarget && prev.ids == desiredIds {
                return
            }
            if (prev.hostId != desiredHostId || !sameTarget),
               !prev.ids.isEmpty,
               let prevHost = resolveHostSession(for: prev.hostId),
               ObjectIdentifier(prevHost) == prev.sessionObjectId {
                Task { try? await prevHost.showSessions([]) }
            }
        }

        guard let desiredHost else {
            lastReportedShownSession = nil
            return
        }

        let desiredObjId = ObjectIdentifier(desiredHost)
        let previouslyEmpty = lastReportedShownSession == nil
            || lastReportedShownSession?.hostId != desiredHostId
            || lastReportedShownSession?.sessionObjectId != desiredObjId
            || (lastReportedShownSession?.ids.isEmpty ?? true)

        if desiredIds.isEmpty {
            lastReportedShownSession = nil
            if !previouslyEmpty {
                Task { try? await desiredHost.showSessions([]) }
            }
            return
        }

        lastReportedShownSession = (hostId: desiredHostId, sessionObjectId: desiredObjId, ids: desiredIds)
        Task { try? await desiredHost.showSessions(desiredIds) }
    }

    internal func maybeShowFocusedAttentionNotice(
        previous: SessionSummary?,
        next: SessionSummary,
        hostId: String
    ) {
        #if os(macOS)
        guard NSApp.isActive else { return }
        #endif
        let inAppMode = notificationPrefs.inAppNoticeMode
        guard inAppMode != .off else { return }
        guard shouldNotifyForHost(hostId) else { return }
        guard next.origin != "subagent", next.archivedAt == nil, next.prepared == nil else { return }
        let isCurrentlyViewed = hostId == activeHostID
            && !showStudioHome
            && selectedSessionSummary?.id == next.id
        guard !isCurrentlyViewed else { return }

        let kind: FocusedAttentionNotice.Kind?
        if let prev = previous {
            if prev.status == .running && next.status == .ready {
                kind = (next.attention == "unread" && inAppMode == .all && notificationPrefs.turnEnded) ? .turnEnded : nil
            } else if (next.status == .awaitingPermission && prev.status != .awaitingPermission)
                || next.permissionCount > prev.permissionCount {
                kind = notificationPrefs.permissionNeeded ? .permission : nil
            } else if next.status == .failed && prev.status != .failed {
                kind = notificationPrefs.error ? .error : nil
            } else {
                kind = nil
            }
        } else {
            kind = nil
        }

        guard let kind else { return }
        let key = "\(hostId)::\(next.id)"
        focusedAttentionSessionIDs.insert(key)
        let extra = max(0, focusedAttentionSessionIDs.count - 1)
        let title = (next.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? l10n.tr("sidebar.untitledSession")
        focusedAttentionNotice = FocusedAttentionNotice(
            hostId: hostId,
            sessionId: next.id,
            title: title,
            kind: kind,
            extraCount: extra
        )
        if !focusedAttentionIsHovered {
            scheduleFocusedAttentionAutoDismiss()
        }
    }

    #if os(macOS)
    /// Exports a session's thread as Markdown using a native save panel.
    public func exportSessionMarkdown(sessionId: String, onHost hostId: String? = nil) async {
        let targetHost = hostId ?? activeHostID
        do {
            guard let host = resolveHostSession(for: targetHost) else {
                throw URLError(.notConnectedToInternet)
            }
            let agentList = targetHost == activeHostID ? agents : hostPool[targetHost]?.agents ?? []
            let snapshot = try await host.openSession(sessionId: sessionId)
            var replica = ThreadReplica(snapshot: snapshot)
            while let before = replica.older {
                let page = try await host.loadSessionPage(sessionId: sessionId, before: before)
                guard page.older.map({ $0 < before }) ?? true else { throw URLError(.cannotParseResponse) }
                replica.prependOlderPage(page)
            }
            let agentName = agentList.first(where: { $0.id == replica.session.agentId })?.name ?? replica.session.agentId
            _ = try await SessionMarkdownExporter.saveWithPanel(replica: replica, agentName: agentName)
        } catch {
            statusMessage = String(format: l10n.tr("session.exportMarkdownFailed"), error.localizedDescription)
        }
    }
    #endif
}

/// Keeps the relay bearer token in the Keychain. UserDefaults holds it only while the Keychain refuses
/// writes (for example an unsigned development build), so a token is never lost.
private enum RelayTokenVault {
    private static let account = "relayBearerToken"
    private static let queue = DispatchQueue(label: "dev.sarto.relay-token", qos: .utility)

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "dev.sarto.mac"
    }

    static func store(_ token: String, legacyDefaultsKey: String) {
        queue.async {
            if write(token) {
                UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            } else {
                UserDefaults.standard.set(token, forKey: legacyDefaultsKey)
            }
        }
    }

    static func loadMigratingLegacy(legacyDefaultsKey: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                // A UserDefaults copy only survives a failed Keychain write, so it is newer than the Keychain copy.
                if let fallback = UserDefaults.standard.string(forKey: legacyDefaultsKey), !fallback.isEmpty {
                    if write(fallback) {
                        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
                    }
                    continuation.resume(returning: fallback)
                    return
                }
                continuation.resume(returning: read())
            }
        }
    }

    private static func baseQuery(service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(service: String = service) -> String? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ token: String) -> Bool {
        let query = baseQuery()
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
