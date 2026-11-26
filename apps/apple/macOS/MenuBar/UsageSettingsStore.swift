import AppKit
import Combine
import MenuBarKit
import PrismDesign
import ServiceManagement
import SwiftUI

/// A display the Dynamic Island is switched on for. Keeping `name` lets the selection survive display ID changes.
struct DisplayChoice: Codable, Equatable, Hashable, Sendable {
    var id: UInt32
    var name: String
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
    /// While sessions run, one animated row per session under the notch. Off by default: the
    /// window's running sessions rail shows them, and the island keeps to its notch-high bar.
    var islandSessionStack = false
    var islandMaxRows = 5
    var islandShowQuota = true
    var islandMotion: IslandMotionStyle = .arcade

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
        islandSessionStack = (try? c.decode(Bool.self, forKey: .islandSessionStack)) ?? d.islandSessionStack
        islandMaxRows = (try? c.decode(Int.self, forKey: .islandMaxRows))
            .flatMap { IslandStackOptions.rowChoices.contains($0) ? $0 : nil } ?? d.islandMaxRows
        islandShowQuota = (try? c.decode(Bool.self, forKey: .islandShowQuota)) ?? d.islandShowQuota
        islandMotion = (try? c.decode(IslandMotionStyle.self, forKey: .islandMotion)) ?? d.islandMotion
    }
}

@MainActor
final class UsageSettingsStore: ObservableObject {
    private static let key = "dev.sarto.usage-island.settings"
    private static let arcadeDefaultAdoptedKey = "dev.sarto.usage-island.arcadeDefaultAdopted.v1"

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
    @Published var shakeIsland = 0
    @Published var shakeMenubar = 0
    @Published var shakeSource: String?
    var onLocalMutation: ((UsageIslandSettings) -> Void)?
    private var isApplyingSyncedSettings = false

    init() {
        var loaded: UsageIslandSettings
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(UsageIslandSettings.self, from: data)
        {
            loaded = decoded
        } else {
            loaded = UsageIslandSettings()
        }
        if !UserDefaults.standard.bool(forKey: Self.arcadeDefaultAdoptedKey) {
            UserDefaults.standard.set(true, forKey: Self.arcadeDefaultAdoptedKey)
            if loaded.islandMotion == .lively {
                loaded.islandMotion = .arcade
            }
        }
        settings = loaded
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
        let showing = Displays.screens(for: settings.islandDisplays).map { screen in
            DisplayChoice(id: Displays.id(of: screen), name: screen.localizedName)
        }
        let connected = Set(NSScreen.screens.map(Displays.id(of:)))
        let away = settings.islandDisplays.filter { choice in
            !connected.contains(choice.id) && !showing.contains { $0.name == choice.name }
        }
        if showing.contains(where: { $0.id == display.id }) {
            guard showing.count > 1 else {
                setIslandEnabled(false)
                return
            }
            settings.islandDisplays = showing.filter { $0.id != display.id } + away
        } else {
            settings.islandDisplays = showing + [DisplayChoice(id: display.id, name: display.name)] + away
            if !settings.islandEnabled { settings.islandEnabled = true }
        }
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
            if all.filter({ !settings.hidden.contains($0.id) }).count <= 1 {
                shakeSource = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.shakeSource = nil
                }
                return
            }
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

    static func screens(for choices: [DisplayChoice]) -> [NSScreen] {
        var picked: [NSScreen] = []
        for choice in choices {
            let match = screen(id: choice.id) ?? NSScreen.screens.first { $0.localizedName == choice.name }
            if let match, !picked.contains(match) { picked.append(match) }
        }
        return picked.isEmpty ? (preferredScreen().map { [$0] } ?? []) : picked
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
