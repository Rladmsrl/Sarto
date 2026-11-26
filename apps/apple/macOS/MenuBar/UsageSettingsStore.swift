import AppKit
import Combine
import MenuBarKit
import PrismDesign
import ServiceManagement
import SwiftUI

/// A display the Dynamic Island is switched on for. `uuid` is the display's own identity, which
/// survives display ID changes and tells two monitors of the same model apart; choices saved
/// before it existed fall back to `id`, then `name`.
struct DisplayChoice: Codable, Equatable, Hashable, Sendable {
    var id: UInt32
    var name: String
    var uuid: String? = nil
}

enum StatusTextMode: String, Codable, CaseIterable, Sendable {
    case icon, lowest, today

    func label(_ l10n: PrismL10n) -> String {
        switch self {
        case .icon: return l10n.tr("settings.menubar.textMode.icon")
        case .lowest: return l10n.tr("settings.menubar.textMode.lowest")
        case .today: return l10n.tr("settings.menubar.textMode.today")
        }
    }
}

enum UsageScope: String, Codable, CaseIterable, Sendable {
    case allMacs, thisMac

    func label(_ l10n: PrismL10n) -> String {
        switch self {
        case .allMacs: return l10n.tr("settings.usage.scope.allMacs")
        case .thisMac: return l10n.tr("settings.usage.scope.thisMac")
        }
    }
}

struct UsageIslandSettings: Codable, Equatable, Sendable {
    var islandEnabled = true
    /// Empty means automatic: notched display if present, else main display. Multi-selection shows one island per display.
    var islandDisplays: [DisplayChoice] = []
    /// Subtle reminders: low-quota alerts update compact badge without auto-expanding the island.
    var subtleReminders = false
    var menubarEnabled = true
    var statusText: StatusTextMode = .today
    var order: [String] = []
    var hidden: [String] = []
    var usageScope: UsageScope = .allMacs
    var lowAlert = true
    var lowThreshold = 30
    var privacy = false
    var islandMotion: IslandMotionStyle = .lively

    static let lowThresholds = [10, 20, 30, 50]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UsageIslandSettings()
        islandEnabled = (try? c.decode(Bool.self, forKey: .islandEnabled)) ?? d.islandEnabled
        islandDisplays = (try? c.decode([DisplayChoice].self, forKey: .islandDisplays)) ?? d.islandDisplays
        subtleReminders = (try? c.decode(Bool.self, forKey: .subtleReminders)) ?? d.subtleReminders
        menubarEnabled = (try? c.decode(Bool.self, forKey: .menubarEnabled)) ?? d.menubarEnabled
        statusText = (try? c.decode(StatusTextMode.self, forKey: .statusText)) ?? d.statusText
        order = (try? c.decode([String].self, forKey: .order)) ?? d.order
        hidden = (try? c.decode([String].self, forKey: .hidden)) ?? d.hidden
        usageScope = (try? c.decode(UsageScope.self, forKey: .usageScope)) ?? d.usageScope
        lowAlert = (try? c.decode(Bool.self, forKey: .lowAlert)) ?? d.lowAlert
        lowThreshold = (try? c.decode(Int.self, forKey: .lowThreshold)).flatMap { Self.lowThresholds.contains($0) ? $0 : nil } ?? d.lowThreshold
        privacy = (try? c.decode(Bool.self, forKey: .privacy)) ?? d.privacy
        islandMotion = (try? c.decode(IslandMotionStyle.self, forKey: .islandMotion)) ?? d.islandMotion
    }
}

/// How a plan window running low is told: a pop that opens the island, only the low-quota
/// marks on the island and the menu bar item, or not at all. Stored as `lowAlert` and
/// `subtleReminders`, which other Macs sync.
enum LowQuotaAlertMode: String, CaseIterable, Identifiable, Sendable {
    case pop
    case badge
    case off

    var id: String { rawValue }
}

extension UsageIslandSettings {
    var lowQuotaAlert: LowQuotaAlertMode {
        get { !lowAlert ? .off : (subtleReminders ? .badge : .pop) }
        set {
            lowAlert = newValue != .off
            subtleReminders = newValue == .badge
        }
    }
}

@MainActor
final class UsageSettingsStore: ObservableObject {
    private static let key = "dev.sarto.usage-island.settings"

    @Published var settings: UsageIslandSettings {
        didSet {
            if settings != oldValue {
                save()
                if !isApplyingSyncedSettings {
                    onLocalMutation?(settings)
                }
            }
        }
    }
    var onLocalMutation: ((UsageIslandSettings) -> Void)?
    private var isApplyingSyncedSettings = false

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(UsageIslandSettings.self, from: data)
        {
            settings = decoded
        } else {
            settings = UsageIslandSettings()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func applySynced(_ next: UsageIslandSettings) {
        guard settings != next else { return }
        isApplyingSyncedSettings = true
        defer { isApplyingSyncedSettings = false }
        settings = next
    }

    func setIslandEnabled(_ on: Bool) {
        settings.islandEnabled = on
    }

    func setMenubarEnabled(_ on: Bool) {
        settings.menubarEnabled = on
    }

    func toggleIslandDisplay(_ display: DisplayInfo) {
        let showing = Displays.screens(for: settings.islandDisplays).map(Displays.choice(for:))
        let away = Displays.awayChoices(settings.islandDisplays)
        if showing.contains(where: { $0.id == display.id }) {
            // The last display stays: hiding the island is the island switch's job alone.
            guard showing.count > 1 else { return }
            settings.islandDisplays = showing.filter { $0.id != display.id } + away
        } else {
            let added = DisplayChoice(id: display.id, name: display.name, uuid: Displays.uuid(of: display.id))
            settings.islandDisplays = showing + [added] + away
            if !settings.islandEnabled { settings.islandEnabled = true }
        }
    }

    /// Back to choosing the display automatically (the main display, or the one with the notch).
    func useAutomaticIslandDisplays() {
        settings.islandDisplays = []
    }

    func ordered(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        let rank = Dictionary(uniqueKeysWithValues: settings.order.enumerated().map { ($1, $0) })
        return providers.enumerated().sorted { a, b in
            (rank[a.element.id] ?? 1000 + a.offset) < (rank[b.element.id] ?? 1000 + b.offset)
        }.map(\.element)
    }

    func visible(_ providers: [ProviderUsage]) -> [ProviderUsage] {
        ordered(providers).filter { !settings.hidden.contains($0.id) }
    }

    @discardableResult
    func setVisible(_ id: String, _ on: Bool, all: [ProviderUsage]) -> Bool {
        let hidden = settings.hidden.contains(id)
        if on == !hidden { return false }
        toggleHidden(id, all: all)
        return settings.hidden.contains(id) != hidden
    }

    func toggleHidden(_ id: String, all: [ProviderUsage]) {
        if settings.hidden.contains(id) {
            settings.hidden.removeAll { $0 == id }
        } else {
            // The last visible source stays; its switch is disabled in Settings.
            if all.filter({ !settings.hidden.contains($0.id) }).count <= 1 { return }
            settings.hidden.append(id)
        }
    }

    func move(_ id: String, into target: String, all: [ProviderUsage]) {
        var order = ordered(all).map(\.id)
        guard let from = order.firstIndex(of: id), let to = order.firstIndex(of: target), from != to else { return }
        order.remove(at: from)
        order.insert(id, at: to)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { settings.order = order }
    }

    func moveBy(_ id: String, offset: Int, all: [ProviderUsage]) {
        var order = ordered(all).map(\.id)
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard to >= 0, to < order.count else { return }
        order.swapAt(from, to)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { settings.order = order }
    }
}

// MARK: - Launch at Login (SMAppService)

@MainActor
final class PrismLaunchAtLogin: ObservableObject {
    enum State: Equatable {
        case unavailable
        case off
        case on
        case requiresApproval
    }

    @Published private(set) var state: State = .off
    @Published private(set) var error: String?

    init() { refresh() }

    var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        guard available else { state = .unavailable; return }
        switch SMAppService.mainApp.status {
        case .enabled: state = .on
        case .requiresApproval: state = .requiresApproval
        default: state = .off
        }
    }

    func set(_ on: Bool) {
        guard available else { return }
        error = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let l10n = PrismL10n(language: PrismLanguage.loadSaved())
            self.error = l10n.tr(on ? "settings.general.launchAtLogin.enableFailed" : "settings.general.launchAtLogin.disableFailed")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Multi-Monitor Display Discovery

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
    let resolution: String
    let primary: Bool
    let builtIn: Bool
    let frame: CGRect
}

@MainActor
enum Displays {
    static func id(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func all() -> [DisplayInfo] {
        let l10n = PrismL10n(language: PrismLanguage.loadSaved())
        return NSScreen.screens.enumerated().map { index, screen in
            let sid = id(of: screen)
            let pixels = CGSize(width: CGFloat(CGDisplayPixelsWide(sid)), height: CGFloat(CGDisplayPixelsHigh(sid)))
            let name = screen.localizedName.isEmpty ? l10n.tr("display.fallbackName", index + 1) : screen.localizedName
            return DisplayInfo(
                id: sid,
                name: name,
                resolution: "\(Int(pixels.width))×\(Int(pixels.height))",
                primary: index == 0,
                builtIn: CGDisplayIsBuiltin(sid) != 0,
                frame: screen.frame
            )
        }
    }

    static func screen(id: UInt32) -> NSScreen? {
        NSScreen.screens.first { self.id(of: $0) == id }
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first {
            $0.safeAreaInsets.top > 0
                || $0.auxiliaryTopLeftArea != nil
                || HardwareNotchCache.hasNotch(id(of: $0))
        }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// Each choice takes its own display: by `uuid`, or for a choice saved without one by `id`,
    /// then by `name`. Exact matches go first, so a choice found only by name never takes a
    /// display another choice names exactly, and two monitors of one model stay two.
    static func screens(for choices: [DisplayChoice]) -> [NSScreen] {
        let connected = NSScreen.screens
        var picked = [NSScreen?](repeating: nil, count: choices.count)
        var taken = Set<UInt32>()
        for (index, choice) in choices.enumerated() {
            let free = connected.filter { screen in
                let sid = id(of: screen)
                guard !taken.contains(sid) else { return false }
                if let uuid = choice.uuid { return self.uuid(of: sid) == uuid }
                return sid == choice.id
            }
            // Monitors whose EDID carries no serial can share a UUID; the saved ID tells them apart.
            if let match = free.first(where: { id(of: $0) == choice.id }) ?? free.first {
                picked[index] = match
                taken.insert(id(of: match))
            }
        }
        for (index, choice) in choices.enumerated() where picked[index] == nil && choice.uuid == nil {
            if let match = connected.first(where: { $0.localizedName == choice.name && !taken.contains(id(of: $0)) }) {
                picked[index] = match
                taken.insert(id(of: match))
            }
        }
        let screens = picked.compactMap { $0 }
        return screens.isEmpty ? (preferredScreen().map { [$0] } ?? []) : screens
    }

    /// Chosen displays that no connected display answers to, kept so the island returns to them.
    static func awayChoices(_ choices: [DisplayChoice]) -> [DisplayChoice] {
        let connected = NSScreen.screens
        return choices.filter { choice in
            !connected.contains { screen in
                let sid = id(of: screen)
                if let uuid = choice.uuid { return uuid == self.uuid(of: sid) }
                return sid == choice.id || screen.localizedName == choice.name
            }
        }
    }

    static func choice(for screen: NSScreen) -> DisplayChoice {
        let sid = id(of: screen)
        return DisplayChoice(id: sid, name: screen.localizedName, uuid: uuid(of: sid))
    }

    private static var uuidCache: (displays: Set<UInt32>, uuids: [UInt32: String]) = ([], [:])

    /// ColorSync's UUID for the display, cached while the same displays stay connected, since
    /// relocating the island resolves the choices on every Space change.
    static func uuid(of displayID: UInt32) -> String? {
        let connected = Set(NSScreen.screens.map(id(of:)))
        if uuidCache.displays != connected { uuidCache = (connected, [:]) }
        if let cached = uuidCache.uuids[displayID] { return cached }
        guard connected.contains(displayID),
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
              let text = CFUUIDCreateString(nil, uuid) as String?
        else { return nil }
        uuidCache.uuids[displayID] = text
        return text
    }
}

// MARK: - Sarto 4-Palette <-> MenuBarKit Bridge

extension PrismPalette {
    var menuBarStyle: MenuBarThemeStyle {
        switch self {
        case .obsidian: return .obsidian
        case .warm: return .warm
        case .crystal: return .crystal
        case .alabaster: return .alabaster
        }
    }

    func resolvedAccentHex(accent: PrismAccentMode) -> UInt32 {
        PrismTokens.resolvedPrimaryHex(palette: self, accent: accent)
    }
}
