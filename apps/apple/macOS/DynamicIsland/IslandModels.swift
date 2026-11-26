import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - Placement & Geometry

/// Where the island sits and how large it may grow on the active screen.
struct IslandGeometry: Equatable, Sendable {
    /// Hardware notch width, or 0 on a non-notch external monitor.
    var notchWidth: CGFloat = 0
    /// Top band height: hardware notch height, or menu bar height on non-notch screens.
    var notchHeight: CGFloat = 32
    var hasNotch: Bool = false
    var maxHeight: CGFloat = 600
}

enum IslandMode: Equatable, Sendable {
    case hidden
    case collapsed
    case grown
    case open
}

/// What opened the island, deciding what closes it.
enum IslandOpener: Equatable, Sendable {
    case hover
    case click
    case request
}

/// Visual rim accent reflecting live agent activity (Obsidian Prism optical language).
enum IslandAuraState: Equatable, Sendable {
    case calm
    case running
    case waiting
    case failed
    case done
}

/// Top-bar tab inside the expanded island when no permission approval is blocking.
enum IslandExpandedTab: String, CaseIterable, Equatable, Sendable {
    case sessions
    case usage
}

// MARK: - Projected Domain Models (clean pluggable boundary for future island integrations)

struct IslandAgentIdentity: Equatable, Sendable {
    let id: String
    let name: String
    let harness: String
    let color: String?
}

struct IslandPlanStep: Equatable, Identifiable, Sendable {
    let index: Int
    let content: String
    /// "pending" | "in_progress" | "completed"
    let status: String

    var id: String { "\(index)-\(content)" }
}

struct IslandPlanSnapshot: Equatable, Sendable {
    let done: Int
    let total: Int
    let current: String?
    var items: [IslandPlanStep] = []
}

/// One usage window of an agent's plan, by what is left of it.
struct IslandQuotaWindow: Equatable, Identifiable, Sendable {
    var id: String { label }
    let label: String
    /// Share left, 0...1.
    let remaining: Double
    /// Epoch milliseconds.
    let resetsAt: Double?
}

/// How the running rail and collapsed island animate, from full particles down to still frames.
/// Set from Settings -> Dynamic Island -> Animation, and capped by the app's motion tier.
enum IslandMotionStyle: String, Codable, CaseIterable, Sendable {
    /// Particles and shockwaves at the frame rate the energy policy allows.
    case lively
    /// Quieter animation at half the rate.
    case calm
    /// Static frames only.
    case still

    /// Reads a stored or synced value; `arcade`, the tier the removed Agent RPG used, is `lively`.
    init?(storedValue: String) {
        if storedValue == "arcade" {
            self = .lively
        } else {
            self.init(rawValue: storedValue)
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let style = IslandMotionStyle(storedValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown motion style \(raw)")
            )
        }
        self = style
    }

    var framesPerSecond: Double {
        switch self {
        case .lively: return 60
        case .calm: return 30
        case .still: return 0
        }
    }

    /// The style the app's motion tier and Reduce Motion leave: `off` stills it, `subtle` calms it.
    func capped(by tier: PrismMotionTier, reduceMotion: Bool) -> IslandMotionStyle {
        if reduceMotion || tier == .off { return .still }
        if tier == .subtle, self == .lively { return .calm }
        return self
    }
}

struct IslandLimitSnapshot: Equatable, Sendable {
    let label: String
    let resetsAt: Double?
}

struct IslandCacheWindow: Equatable, Sendable {
    let expiresAt: Double
    let endingMs: Double
    let estimate: Bool
}

struct IslandRowItem: Equatable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let sessionId: String
    let title: String
    let project: String
    let agent: IslandAgentIdentity
    let model: String?
    let group: String // "needs_you" | "running" | "finished" | "idle"
    let status: String // "waiting" | "running" | "starting" | "sign_in" | "failed" | "limited" | "unread" | "idle"
    let since: Double?
    let line: String
    let toolSince: Double?
    let toolKind: String?
    let turnStartedAt: Double?
    let plan: IslandPlanSnapshot?
    let limit: IslandLimitSnapshot?
    let phase: String?
    let cache: IslandCacheWindow?
    let isSubagent: Bool
    var hostId: String? = nil
    var hostName: String? = nil
    /// The turn has ended, but commands or sub-agents it started still run in the background.
    var background: Bool = false
}

struct IslandRequestOption: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    /// "deny" | "allow_once" | "allow_always" | "recommended" | "normal"
    let style: String
    let questionIndex: Int?
    let choiceIndex: Int?
}

struct IslandPendingRequest: Equatable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let sessionId: String
    let requestId: String
    let rowKey: String
    /// "permission" | "question" | "plan" | "sarto"
    let kind: String
    let title: String
    let lines: [String]
    let code: Bool
    let options: [IslandRequestOption]
    /// When the island first saw the request (epoch milliseconds); requests are shown oldest first.
    var askedAt: Double?
    let isDemo: Bool
    var hostId: String? = nil
    var hostName: String? = nil
}

struct IslandNoticeMeter: Equatable, Sendable {
    let percent: Double
    let reached: Bool
    let text: String
}

struct IslandNoticeItem: Equatable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let kind: String
    let marks: [IslandAgentIdentity]
    let title: String
    let detail: String?
    let meter: IslandNoticeMeter?
    let trailing: String?
}

struct IslandSummaryCounts: Equatable, Sendable {
    let running: Int
    let waiting: Int
    let failed: Int
    let today: Int
}

struct IslandLiveTelemetry: Equatable, Sendable {
    let sessionId: String?
    let tps: Double?
    let tpsIsApprox: Bool
    let cacheHitPercent: Double?
    let contextFillRatio: Double
    let contextUsed: Double
    let contextTotal: Double
    let isStreaming: Bool
}

struct IslandPopItem: Equatable, Identifiable, Sendable {
    let id: Int
    let rowKey: String?
    let kind: String // "permission" | "error" | "limit-near" | "limit-reached" | "turn-ended" | "info"
    let title: String
    let body: String
    let agent: IslandAgentIdentity?
    let percent: Double?
}

/// The one compact fact shown beside the status signal when collapsed.
enum IslandCollapsedFact: Equatable, Sendable {
    case cache(String, ending: Bool)
    /// Approvals waiting on the user.
    case pending(Int)
    /// A used-up window, counting down to its reset (epoch milliseconds).
    case resumeAt(Double)
    case failed
    /// Finished sessions the user has not looked at.
    case done(Int)
    /// Sessions running, and when the longest turn started (epoch milliseconds).
    case running(count: Int, since: Double?)

    /// Shown alone in the right wing, as a pill, without the status signal beside it.
    var isPill: Bool {
        switch self {
        case .pending, .resumeAt, .failed, .done, .running: return true
        case .cache: return false
        }
    }
}

struct IslandCollapsedState: Equatable, Sendable {
    let agents: [IslandAgentIdentity]
    let signal: IslandSignal?
    let fact: IslandCollapsedFact?
    let title: String?
}

/// One display in the island's context menu, with whether the island shows on it.
struct IslandDisplayMenuItem: Identifiable, Equatable, Sendable {
    let display: DisplayInfo
    let isActive: Bool
    var id: UInt32 { display.id }
}

struct IslandAnswerNote: Equatable, Sendable {
    let text: String
    let ok: Bool
}

/// Complete immutable snapshot produced by any data provider (Sarto daemon or future merged island sources).
struct IslandViewSnapshot: Equatable, Sendable {
    let rows: [IslandRowItem]
    let requests: [IslandPendingRequest]
    let notices: [IslandNoticeItem]
    let summary: IslandSummaryCounts
    let telemetry: IslandLiveTelemetry?
    /// Each agent's plan windows from the host, by agent id.
    var quotas: [String: [IslandQuotaWindow]] = [:]
}

/// Action callbacks emitted by the island UI back to the host app.
@MainActor
protocol IslandActionSink: AnyObject {
    func islandOpenApp(sessionId: String?)
    func islandStartNewSession()
    func islandAnswerRequest(_ request: IslandPendingRequest, option: IslandRequestOption) async -> IslandAnswerNote
    func islandExpandedDidAppear()
    func islandOpenMenuBarPanel(page: MenuBarPage)
    func islandOpenSettings(section: PrismSettingsSection?)
    func islandToggleDisplay(_ display: DisplayInfo)
    func islandUseAutomaticDisplays()
    func islandRequestHide()
    func islandTriggerDemoPop()
    func islandTriggerDemoApproval()
}

// MARK: - Theme & Metrics

/// Static names for the island's colors, forwarded from `PrismIslandTokens.standard` for code with
/// no tokens at hand. The chassis, the accent and the spectrum change with the palette, so views
/// with the island model read those from `model.prismTokens.island` instead.
enum IslandTheme {
    private static let tokens = PrismIslandTokens.standard

    static let surface = tokens.surface
    static let card = tokens.card
    static let focusCard = tokens.focusCard
    static let line = tokens.line
    static let track = tokens.track
    static let cardHover = tokens.cardHover
    static let rowHover = tokens.rowHover
    static let button = tokens.button
    static let buttonHover = tokens.buttonHover
    static let primaryButton = tokens.primaryButton
    static let text = tokens.text
    static let quote = tokens.quote
    static let secondary = tokens.secondary
    static let tertiary = tokens.tertiary

    static let prismCobalt = tokens.cobalt
    static let prismIris = tokens.iris
    static let prismCoral = tokens.coral
    static let prismAmber = tokens.amber

    static let attentionDot = tokens.warning
    static let attention = tokens.attention
    static let danger = tokens.danger
    static let success = tokens.success
    static let warning = tokens.warning
    static let usageRed = tokens.danger
    static let usageGreen = tokens.success
    static let unread = tokens.unread
    static let running = tokens.running
    static let planDone = tokens.planDone
}

enum IslandMetrics {
    static let shoulder: CGFloat = 7
    static let collapsedRadius: CGFloat = 13
    /// Unified collapsed width on displays without a hardware notch.
    static let collapsedWidth: CGFloat = 336
    /// Unified wing width on each side of a physical hardware notch while collapsed.
    static let collapsedNotchWing: CGFloat = 112
    static let grownWidth: CGFloat = 388
    static let grownBody: CGFloat = 46
    static let grownRadius: CGFloat = 20
    static let openWidth: CGFloat = 468
    static let openWings: CGFloat = 264
    static let openRadius: CGFloat = 26
    static let wingMark: CGFloat = 18
    static let markOverlap: CGFloat = 5
    static let maxHeightShare: CGFloat = 0.7
    static let margin: CGFloat = 28
    static let bandHeight: CGFloat = 32
    static let listRows = 6
    static let twoLineRows = 4
    /// Center spacer width on screens without a physical notch (such as external 4K monitors).
    static let plainMiddle: CGFloat = 192
}

/// The strike lane the window's running rail shows for each session.
enum IslandLaneMetrics {
    /// Widest the centred title band gets, leaving the two marks and some runway clear.
    static let titleWidth: CGFloat = 300
}

enum IslandFonts {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
