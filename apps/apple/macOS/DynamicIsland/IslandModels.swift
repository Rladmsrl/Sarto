import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - Placement & Geometry

/// Which display hosts the Dynamic Island on multi-monitor setups (such as dual 4K monitors).
enum IslandScreenPreference: String, CaseIterable, Identifiable, Sendable {
    case followActive
    case followPointer
    case primaryOrNotch

    var id: String { rawValue }

    private static let defaultsKey = "dev.sarto.island.screenPreference"

    static func loadSaved() -> IslandScreenPreference {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let parsed = IslandScreenPreference(rawValue: raw)
        else { return .followActive }
        return parsed
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }

    func localizedTitle(_ strings: IslandStrings) -> String {
        switch self {
        case .followActive: return strings.text("screen.active")
        case .followPointer: return strings.text("screen.pointer")
        case .primaryOrNotch: return strings.text("screen.primary")
        }
    }
}

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

/// How the running rail and collapsed island animate; 3 degradation levels from full idle RPG down
/// to static frames. Set from Settings -> Animation.
enum IslandMotionStyle: String, Codable, CaseIterable, Sendable {
    /// 60 fps full idle RPG game (XP, leveling, weapons, cosmetics, auto skills, damage numbers).
    case arcade
    /// 60 fps pure animation with particles and shockwaves, without idle RPG overlays.
    case lively
    /// 30 fps quieter animation.
    case calm
    /// Static frames only.
    case still

    var framesPerSecond: Double {
        switch self {
        case .arcade, .lively: return 60
        case .calm: return 30
        case .still: return 0
        }
    }

    /// True only at the highest tier where the running rail enables the full idle RPG game.
    var enablesIdleGame: Bool {
        self == .arcade
    }
}

struct IslandStackOptions: Equatable, Sendable {
    /// One row per running session under the notch while any session runs; off by default, as
    /// the window's running panel shows them.
    var enabled = false
    /// Rows shown before the rest fold into one line.
    var maxRows = 5
    var showQuota = true
    var motion: IslandMotionStyle = .arcade

    static let rowChoices = [3, 5, 8]
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
    let askedAt: Double?
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
    case count(Int)
    case cache(String, ending: Bool)
    case plan(done: Int, total: Int)
    case speed(String)
    case word(String)
    /// Approvals waiting on the user.
    case pending(Int)
    /// A used-up window, counting down to its reset (epoch milliseconds).
    case resumeAt(Double)
    case failed
    /// Finished sessions the user has not looked at.
    case done(Int)
    /// Sessions running, and how long the longest turn has run.
    case running(count: Int, elapsed: String)
    /// Idle: the scarcest plan window, its agent and when it resets.
    case quota(IslandQuotaWindow, agent: IslandAgentIdentity, reset: String?)

    /// Shown alone in the right wing, as a pill, without the status signal beside it.
    var isPill: Bool {
        switch self {
        case .pending, .resumeAt, .failed, .done, .running, .quota: return true
        default: return false
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
    func islandRequestHide()
    func islandTriggerDemoPop()
    func islandTriggerDemoApproval()
}

// MARK: - Theme & Metrics (Black Hardware Surface + Subtle Obsidian Prism Accents)

enum IslandTheme {
    static let surface = Color(hex: 0x050507)
    static let card = Color(hex: 0x16161B)
    static let focusCard = Color(hex: 0x111116)
    static let line = Color.white.opacity(0.085)
    static let track = Color(hex: 0x26262E)
    static let cardHover = Color(hex: 0x22222A)
    static let rowHover = Color(hex: 0x14141A)
    static let button = Color(hex: 0x26262E)
    static let buttonHover = Color(hex: 0x31313B)
    static let primaryButton = Color(hex: 0xF5F5F7)
    static let text = Color(hex: 0xF2F2F7)
    static let quote = Color(hex: 0xC7C7CC)
    static let secondary = Color(hex: 0x8E8E98)
    static let tertiary = Color(hex: 0x6A6A74)

    // Obsidian Prism optical spectral palette
    static let prismCobalt = Color(hex: 0x4C8DF6)
    static let prismIris = Color(hex: 0x9B72CB)
    static let prismCoral = Color(hex: 0xD96570)
    static let prismAmber = Color(hex: 0xF2B84B)

    // Semantic signals matching Prism
    static let attentionDot = Color(hex: 0xF2B84B)
    static let attention = Color(hex: 0xF4BE5B)
    static let danger = Color(hex: 0xE5534B)
    static let success = Color(hex: 0x50A37B)
    static let warning = Color(hex: 0xF2B84B)
    static let usageRed = Color(hex: 0xE5534B)
    static let usageGreen = Color(hex: 0x50A37B)
    static let unread = Color(hex: 0x4C8DF6)
    static let running = Color(hex: 0x6BA4FF)
    static let planDone = Color(hex: 0x50A37B)

    static let turnDotsNSColor = NSColor(srgbRed: 0.42, green: 0.64, blue: 0.99, alpha: 1.0)
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

/// Fixed row heights of the running session stack; `PrismIslandModel.stackBodyHeight` adds them up.
enum IslandStackMetrics {
    static let width: CGFloat = 420
    static let radius: CGFloat = 20
    static let topPadding: CGFloat = 4
    static let bottomPadding: CGFloat = 10
    static let groupHeader: CGFloat = 24
    static let row: CGFloat = 30
    static let foldRow: CGFloat = 24
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
