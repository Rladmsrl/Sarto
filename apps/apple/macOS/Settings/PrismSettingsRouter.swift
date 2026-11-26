import AppKit
import Foundation
import SartoProtocol
import Observation
import PrismDesign
import SwiftUI

// MARK: - Settings Sections & Groups

enum PrismSettingsGroup: String, CaseIterable, Identifiable {
    case appAndExperience
    case hostAndAgents
    case networkAndSystem

    var id: String { rawValue }

    func title(_ l10n: PrismL10n) -> String {
        switch self {
        case .appAndExperience: return l10n.tr("settings.group.app")
        case .hostAndAgents: return l10n.tr("settings.group.host")
        case .networkAndSystem: return l10n.tr("settings.group.network")
        }
    }

    var sections: [PrismSettingsSection] {
        switch self {
        case .appAndExperience:
            return [.general, .appearance, .islandAndMenuBar, .usageAndSync, .notifications]
        case .hostAndAgents:
            return [.agents, .extensions, .memory, .archived, .gitAndTerminal]
        case .networkAndSystem:
            return [.remoteAndCloud, .advancedAndAbout]
        }
    }
}

enum PrismSettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general
    case appearance
    case islandAndMenuBar
    case usageAndSync
    case notifications
    case agents
    case extensions
    case memory
    case archived
    case gitAndTerminal
    case remoteAndCloud
    case advancedAndAbout

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general: return "gearshape.fill"
        case .appearance: return "paintbrush.fill"
        case .islandAndMenuBar: return "menubar.dock.rectangle"
        case .usageAndSync: return "chart.bar.xaxis"
        case .notifications: return "bell.badge.fill"
        case .agents: return "cpu.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .memory: return "brain.head.profile"
        case .archived: return "archivebox.fill"
        case .gitAndTerminal: return "terminal.fill"
        case .remoteAndCloud: return "network"
        case .advancedAndAbout: return "slider.horizontal.3"
        }
    }

    func badgeColor(tokens: PrismTokens) -> Color {
        switch self {
        case .general: return tokens.prismCobalt
        case .appearance: return tokens.prismIris
        case .islandAndMenuBar: return tokens.prismAmber
        case .usageAndSync: return tokens.success
        case .notifications: return tokens.prismCoral
        case .agents: return tokens.prismCobalt
        case .extensions: return tokens.prismIris
        case .memory: return tokens.prismIris
        case .archived: return tokens.secondaryForeground
        case .gitAndTerminal: return tokens.success
        case .remoteAndCloud: return tokens.prismCobalt
        case .advancedAndAbout: return tokens.secondaryForeground
        }
    }

    func title(_ l10n: PrismL10n) -> String {
        l10n.tr("settings.nav.\(rawValue)")
    }

    func subtitle(_ l10n: PrismL10n) -> String {
        l10n.tr("settings.nav.\(rawValue).sub")
    }
}

// MARK: - Searchable Catalog Entry

struct PrismSettingsSearchItem: Identifiable, Hashable {
    let id: String
    let section: PrismSettingsSection
    let rowID: String
    let titleKey: String
    let subtitleKey: String?
    let keywords: String

    func matches(query: String, l10n: PrismL10n) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        let haystack = [
            section.title(l10n),
            l10n.tr(titleKey),
            subtitleKey.map { l10n.tr($0) } ?? "",
            keywords,
        ]
        .joined(separator: " ")
        .lowercased()
        return needle.split(whereSeparator: \.isWhitespace).allSatisfy { token in
            haystack.contains(token)
        }
    }
}

enum PrismSettingsSearchCatalog {
    static let all: [PrismSettingsSearchItem] = [
        // General
        .init(id: "gen.lang", section: .general, rowID: "general.language", titleKey: "settings.general.language", subtitleKey: "settings.general.languageSub", keywords: "language locale english chinese 语言 中文 英文"),
        .init(id: "gen.send", section: .general, rowID: "general.sendKey", titleKey: "settings.general.sendKey", subtitleKey: "settings.general.sendKeySub", keywords: "enter command return submit composer 发送 快捷键 回车"),
        .init(id: "gen.agent", section: .general, rowID: "general.defaultAgent", titleKey: "settings.general.defaultAgent", subtitleKey: "settings.general.defaultAgentSub", keywords: "default agent claude codex antigravity 默认 代理"),
        .init(id: "gen.restore", section: .general, rowID: "general.restore", titleKey: "settings.general.restore", subtitleKey: "settings.general.restoreSub", keywords: "restore session startup launch 恢复 上次 会话 启动"),
        .init(id: "gen.quit", section: .general, rowID: "general.confirmQuit", titleKey: "settings.general.confirmQuit", subtitleKey: "settings.general.confirmQuitSub", keywords: "quit exit running confirm 退出 确认"),
        .init(id: "gen.login", section: .general, rowID: "general.launchAtLogin", titleKey: "settings.general.launchAtLogin", subtitleKey: "settings.general.launchAtLoginSub", keywords: "login startup boot macos 开机 自动 启动 登录项"),
        .init(id: "gen.titles", section: .general, rowID: "general.sessionTitles", titleKey: "settings.general.sessionTitles", subtitleKey: "settings.general.sessionTitlesSub", keywords: "auto title naming light model 自动 标题 命名 轻模型"),

        // Appearance
        .init(id: "app.mode", section: .appearance, rowID: "appearance.colorMode", titleKey: "settings.appearance.colorMode", subtitleKey: "settings.appearance.colorModeSub", keywords: "theme dark light system mode 外观 主题 深色 浅色 跟随系统"),
        .init(id: "app.palette", section: .appearance, rowID: "appearance.palette", titleKey: "settings.palettes", subtitleKey: nil, keywords: "obsidian warm crystal alabaster palette 调色板 配色"),
        .init(id: "app.accent", section: .appearance, rowID: "appearance.accent", titleKey: "settings.accents", subtitleKey: nil, keywords: "accent color cobalt iris amber mono 强调色 点缀色"),
        .init(id: "app.icon", section: .appearance, rowID: "appearance.appIcon", titleKey: "settings.appearance.appIconTitle", subtitleKey: "settings.appearance.appIconSub", keywords: "app icon dock obsidian warm crystal alabaster 图标 应用图标 程序坞 深空黑曜 暖炭玄岩 白昼冷晶 暖白画册 钴蓝 赤陶"),
        .init(id: "app.motion", section: .appearance, rowID: "appearance.motion", titleKey: "settings.motionTier", subtitleKey: nil, keywords: "motion animation reduce 120hz 动效 动画 减弱"),
        .init(id: "app.textsize", section: .appearance, rowID: "appearance.textSize", titleKey: "settings.appearance.textSize", subtitleKey: "settings.appearance.textSizeSub", keywords: "font size text scale small large 字号 字体 大小"),
        .init(id: "app.fonts", section: .appearance, rowID: "appearance.fonts", titleKey: "settings.appearance.fonts", subtitleKey: "settings.appearance.fontsSub", keywords: "font family ui prose code monospace 字体 代码"),
        .init(id: "app.width", section: .appearance, rowID: "appearance.readingWidth", titleKey: "settings.appearance.readingWidth", subtitleKey: "settings.appearance.readingWidthSub", keywords: "reading width compact wide column 阅读 宽度 宽屏"),

        // Island & Menu Bar
        .init(id: "isl.show", section: .islandAndMenuBar, rowID: "island.enabled", titleKey: "settings.island.show", subtitleKey: "settings.island.showSub", keywords: "dynamic island notch 灵动岛 刘海"),
        .init(id: "isl.displays", section: .islandAndMenuBar, rowID: "island.displays", titleKey: "settings.island.displays", subtitleKey: "settings.island.displaysSub", keywords: "monitor display screen map 显示器 多屏 位置"),
        .init(id: "isl.subtle", section: .islandAndMenuBar, rowID: "island.subtle", titleKey: "settings.island.subtle", subtitleKey: "settings.island.subtleSub", keywords: "subtle reminder expand 轻提醒 自动展开"),
        .init(id: "isl.preview", section: .islandAndMenuBar, rowID: "island.preview", titleKey: "settings.island.previewTitle", subtitleKey: "settings.island.previewSub", keywords: "preview test pop approval 预览 测试 弹窗 审批"),
        .init(id: "isl.rail", section: .islandAndMenuBar, rowID: "island.rail", titleKey: "settings.island.rail", subtitleKey: "settings.island.railSub", keywords: "running rail panel sidebar 右侧 运行中 面板"),
        .init(id: "isl.stack", section: .islandAndMenuBar, rowID: "island.stack", titleKey: "settings.island.stack", subtitleKey: "settings.island.stackSub", keywords: "session stack rows running 展开 会话 列表"),
        .init(id: "isl.maxrows", section: .islandAndMenuBar, rowID: "island.maxRows", titleKey: "settings.island.maxRows", subtitleKey: "settings.island.maxRowsSub", keywords: "max rows fold count 最多 行数 折叠"),
        .init(id: "isl.quota", section: .islandAndMenuBar, rowID: "island.quota", titleKey: "settings.island.quota", subtitleKey: "settings.island.quotaSub", keywords: "quota remaining group stack 显示 额度 分组"),
        .init(id: "isl.motion", section: .islandAndMenuBar, rowID: "island.motion", titleKey: "settings.island.motion", subtitleKey: "settings.island.motionSub", keywords: "animation arcade lively calm still rpg game 动画 小游戏 灵动 柔和 静止"),
        .init(id: "isl.menubar", section: .islandAndMenuBar, rowID: "menubar.enabled", titleKey: "settings.menubar.show", subtitleKey: "settings.menubar.showSub", keywords: "menu bar status icon vial 菜单栏 状态栏 图标 文字"),

        // Usage & Sync
        .init(id: "use.sources", section: .usageAndSync, rowID: "usage.sources", titleKey: "settings.usage.sources", subtitleKey: "settings.usage.sourcesSub", keywords: "provider usage quota source order claude codex antigravity 数据来源 额度 排序"),
        .init(id: "use.alerts", section: .usageAndSync, rowID: "usage.lowAlert", titleKey: "settings.usage.lowAlert", subtitleKey: "settings.usage.lowAlertSub", keywords: "low alert threshold quota privacy money 额度 预警 阈值 隐藏金额 隐私"),
        .init(id: "use.sync", section: .usageAndSync, rowID: "usage.sync", titleKey: "settings.usage.sync", subtitleKey: "settings.usage.syncSub", keywords: "sarto cloud usage quota sync multi mac encrypted 多设备 多机 同步 用量 额度 加密"),
        .init(id: "use.hostlogs", section: .usageAndSync, rowID: "usage.fromComputer", titleKey: "settings.usage.fromComputer", subtitleKey: "settings.usage.fromComputerSub", keywords: "host local logs usage summary 读取 本地 日志"),

        // Notifications
        .init(id: "not.perm", section: .notifications, rowID: "notifications.permission", titleKey: "settings.notifications.permission", subtitleKey: "settings.notifications.permissionSub", keywords: "notification permission approval alert 通知 权限 审批"),
        .init(id: "not.turn", section: .notifications, rowID: "notifications.turnEnded", titleKey: "settings.notifications.turnEnded", subtitleKey: "settings.notifications.turnEndedSub", keywords: "turn complete finish done 回合 结束 完成"),
        .init(id: "not.inapp", section: .notifications, rowID: "notifications.inAppPill", titleKey: "settings.notifications.inAppPill", subtitleKey: "settings.notifications.inAppPillSub", keywords: "in-app toast pill banner popup notice focused 应用内 浮窗 胶囊 弹窗 提醒"),
        .init(id: "not.sound", section: .notifications, rowID: "notifications.sound", titleKey: "settings.notifications.sound", subtitleKey: "settings.notifications.soundSub", keywords: "sound badge dock audio 提示音 徽标"),

        // Agents & Harnesses
        .init(id: "agt.env", section: .agents, rowID: "agents.environment", titleKey: "settings.agents.environment", subtitleKey: "settings.agents.environmentSub", keywords: "node npm shell path environment check updates 环境 检测 更新"),
        .init(id: "agt.list", section: .agents, rowID: "agents.list", titleKey: "settings.agents.list", subtitleKey: "settings.agents.listSub", keywords: "claude codex opencode cline antigravity api key login logout binary auto compact prompt cache 登录 密钥 二进制 自动压缩"),
        .init(id: "agt.idle", section: .agents, rowID: "agents.idleRelease", titleKey: "settings.agents.idleRelease", subtitleKey: "settings.agents.idleReleaseSub", keywords: "idle release memory process timeout 空闲 释放 回收 内存"),

        // MCP & Agent Plugins
        .init(id: "ext.builtin", section: .extensions, rowID: "extensions.builtinMcp", titleKey: "settings.ext.builtinMcp", subtitleKey: "settings.ext.builtinMcpSub", keywords: "sarto mcp server builtin tools bridge 内置 桥接 工具"),
        .init(id: "ext.mcp", section: .extensions, rowID: "extensions.mcpServers", titleKey: "settings.ext.mcpServers", subtitleKey: "settings.ext.mcpServersSub", keywords: "mcp oauth proxy http sse stdio server token api key 扩展 代理 授权 密钥"),
        .init(id: "ext.catalog", section: .extensions, rowID: "extensions.mcpCatalog", titleKey: "settings.ext.mcpCatalog", subtitleKey: "settings.ext.mcpCatalogSub", keywords: "mcp registry catalog search install github linear notion figma 目录 商店 搜索 安装"),
        .init(id: "ext.plugins", section: .extensions, rowID: "extensions.plugins", titleKey: "settings.ext.plugins", subtitleKey: "settings.ext.pluginsSub", keywords: "plugin claude code codex marketplace install uninstall 插件 市场"),

        // Memory
        .init(id: "mem.enable", section: .memory, rowID: "memory.enabled", titleKey: "settings.memory.enabled", subtitleKey: "settings.memory.enabledSub", keywords: "memory global project remember import 记忆 全局 项目 导入"),
        .init(id: "mem.entries", section: .memory, rowID: "memory.entries", titleKey: "settings.memory.entries", subtitleKey: "settings.memory.entriesSub", keywords: "memory list edit add delete 记忆 列表 编辑 新增 删除"),

        // Archived
        .init(id: "arc.list", section: .archived, rowID: "archived.sessions", titleKey: "settings.archived.title", subtitleKey: "settings.archived.sub", keywords: "archived restore unarchive delete session 归档 会话 恢复 删除"),

        // Git & Terminal
        .init(id: "git.fetch", section: .gitAndTerminal, rowID: "git.fetch", titleKey: "settings.git.fetch", subtitleKey: "settings.git.fetchSub", keywords: "git background fetch remote 拉取 后台"),
        .init(id: "git.wt", section: .gitAndTerminal, rowID: "git.worktreeRoot", titleKey: "settings.git.worktreeRoot", subtitleKey: "settings.git.worktreeRootSub", keywords: "worktree branch root setup copy 分支 工作树 根目录"),
        .init(id: "trm.shell", section: .gitAndTerminal, rowID: "terminal.shell", titleKey: "settings.terminal.shell", subtitleKey: "settings.terminal.shellSub", keywords: "terminal shell zsh bash font size 终端 字体 字号"),

        // Cloud Sync & Multi-Device
        .init(id: "rem.cloud", section: .remoteAndCloud, rowID: "remote.sync", titleKey: "settings.remote.cloudCardTitle", subtitleKey: "settings.remote.cloudCardSub", keywords: "sarto cloud official account sync e2ee 官方云 账号 同步 多设备 无缝"),
        .init(id: "rem.devices", section: .remoteAndCloud, rowID: "remote.devices", titleKey: "settings.myDevices.title", subtitleKey: "settings.myDevices.sub", keywords: "my devices computers mac iphone ipad mobile host mesh version upgrade update sidebar remove 我的设备 电脑 手机 版本 升级 更新 侧边栏 移除 互联"),
        .init(id: "rem.daemon", section: .remoteAndCloud, rowID: "remote.daemon", titleKey: "settings.localDaemon", subtitleKey: "settings.daemon.subtitle", keywords: "daemon background service restart local socket 守护进程 后台服务 重启 本地"),
        .init(id: "rem.term", section: .remoteAndCloud, rowID: "remote.terminal", titleKey: "settings.remote.terminal", subtitleKey: "settings.remote.terminalSub", keywords: "remote terminal allow access 远程 终端 权限"),
        .init(id: "rem.claude", section: .remoteAndCloud, rowID: "remote.claude", titleKey: "settings.remote.claudeTitle", subtitleKey: "settings.remote.claudeSub", keywords: "remote claude model host share borrow concurrent idle 远程 模型 借用 并发 空闲"),
        .init(id: "rem.privacy", section: .remoteAndCloud, rowID: "remote.privacy", titleKey: "settings.privacy.policyTitle", subtitleKey: "settings.privacy.policySub", keywords: "privacy security e2ee encryption keychain provenance verify 隐私 安全 加密 密钥链 溯源 声明"),

        // Advanced & About
        .init(id: "adv.updates", section: .advancedAndAbout, rowID: "advanced.updates", titleKey: "settings.updates.title", subtitleKey: "settings.updates.automaticSub", keywords: "update upgrade version download restart install beta channel 更新 升级 版本 下载 重启 安装 测试 通道"),
        .init(id: "adv.proxy", section: .advancedAndAbout, rowID: "advanced.proxy", titleKey: "settings.advanced.proxy", subtitleKey: "settings.advanced.proxySub", keywords: "http https socks proxy no_proxy network 代理 网络"),
        .init(id: "adv.diag", section: .advancedAndAbout, rowID: "advanced.diagnostics", titleKey: "settings.advanced.diagnostics", subtitleKey: "settings.advanced.diagnosticsSub", keywords: "verbose logs diagnostic report data folder 日志 诊断 目录"),
        .init(id: "adv.about", section: .advancedAndAbout, rowID: "advanced.about", titleKey: "settings.advanced.about", subtitleKey: "settings.advanced.aboutSub", keywords: "about version daemon health pid uptime 关于 版本 状态"),
    ]
}

// MARK: - Settings Navigation Router

@MainActor
@Observable
final class PrismSettingsRouter {
    var selectedSection: PrismSettingsSection = .general
    var searchQuery: String = ""
    var highlightedRowID: String? = nil
    var openWindowAction: (() -> Void)? = nil
    /// A notice from outside the Settings window, shown by it once it is open.
    var pendingNotice: String? = nil

    @ObservationIgnored private var flashTask: Task<Void, Never>?

    func open(section: PrismSettingsSection? = nil, rowID: String? = nil) {
        if let section {
            selectedSection = section
        }
        searchQuery = ""
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
        }
        openWindowAction?()
        for win in NSApp.windows where win.identifier?.rawValue.contains("prism-settings") == true {
            if win.isMiniaturized { win.deminiaturize(nil) }
            win.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let rowID {
            triggerHighlight(rowID: rowID)
        }
    }

    func jumpTo(section: PrismSettingsSection, rowID: String) {
        searchQuery = ""
        selectedSection = section
        triggerHighlight(rowID: rowID)
    }

    /// Maps an agent-triggered Sarto `settings.open` event (`section`, `item`, `row`) to the
    /// native Sarto Settings section and row identifier, then opens & highlights it.
    func openFromHost(section: String, item: String?, row: String) {
        let normalizedSection = section.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRow = row.trimmingCharacters(in: .whitespacesAndNewlines)

        let targetSection: PrismSettingsSection = {
            if normalizedRow.hasPrefix("mcp.") || normalizedRow.hasPrefix("marketplace.") {
                return .extensions
            }
            switch normalizedSection {
            case "general": return .general
            case "appearance": return .appearance
            case "island", "menubar": return .islandAndMenuBar
            case "usage": return .usageAndSync
            case "notifications": return .notifications
            case "agents", "harnesses": return .agents
            case "marketplace", "mcp", "plugins", "extensions": return .extensions
            case "memory": return .memory
            case "archived": return .archived
            case "git", "terminal": return .gitAndTerminal
            case "remote", "hosts", "account", "sharing", "privacy": return .remoteAndCloud
            case "advanced", "about", "browser", "devices", "computer-use": return .advancedAndAbout
            default: return .general
            }
        }()

        let mappedRowID: String? = {
            let r = normalizedRow.lowercased()
            if r.isEmpty { return nil }
            switch r {
            case "general.language": return "general.language"
            case "general.send-key", "general.sendkey": return "general.sendKey"
            case "general.default-agent", "general.defaultagent": return "general.defaultAgent"
            case "general.restore", "general.restore-session": return "general.restore"
            case "general.confirm-quit", "general.confirmquit": return "general.confirmQuit"
            case "general.launch-at-login", "general.launchatlogin": return "general.launchAtLogin"
            case "general.session-titles", "general.sessiontitles": return "general.sessionTitles"
            case "appearance.color-mode", "appearance.colormode", "appearance.theme": return "appearance.colorMode"
            case "appearance.app-icon", "appearance.appicon", "appearance.icon": return "appearance.appIcon"
            case "appearance.text-size", "appearance.textsize", "appearance.zoom": return "appearance.textSize"
            case "appearance.fonts", "appearance.font-ui", "appearance.font-prose", "appearance.font-code": return "appearance.fonts"
            case "appearance.reading-width", "appearance.readingwidth": return "appearance.readingWidth"
            case "agents.idle-release", "agents.idlerelease": return "agents.idleRelease"
            case "memory.enabled": return "memory.enabled"
            case "git.background-fetch", "git.fetch": return "git.fetch"
            case "git.worktree-root", "git.worktreeroot": return "git.worktreeRoot"
            case "terminal.shell", "terminal.shell-path", "terminal.font-size": return "terminal.shell"
            case "remote.direct", "remote.direct-port": return "remote.direct"
            case "remote.terminal": return "remote.terminal"
            case "remote.privacy", "privacy": return "remote.privacy"
            case "advanced.proxy", "proxy.mode", "proxy.url": return "advanced.proxy"
            case "advanced.verbose", "advanced.diagnostics": return "advanced.diagnostics"
            case "about", "advanced.about": return "advanced.about"
            default:
                if r.hasPrefix("mcp.sarto") { return "extensions.builtinMcp" }
                if r.hasPrefix("marketplace.mcp") || r.hasPrefix("mcp.") { return "extensions.mcpServers" }
                if r.hasPrefix("marketplace.plugin") || r.hasPrefix("plugins.") { return "extensions.plugins" }
                if r.hasPrefix("agents.") || r.hasPrefix("harnesses.") || item != nil && targetSection == .agents {
                    return "agents.list"
                }
                if r.hasPrefix("memory.") { return "memory.entries" }
                if r.hasPrefix("notifications.") { return "notifications.permission" }
                if r.hasPrefix("usage.") { return "usage.fromComputer" }
                return normalizedRow
            }
        }()

        open(section: targetSection, rowID: mappedRowID)
    }

    private func triggerHighlight(rowID: String) {
        flashTask?.cancel()
        highlightedRowID = rowID
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            if self?.highlightedRowID == rowID {
                self?.highlightedRowID = nil
            }
        }
    }
}

// MARK: - Live Settings Async View Model (Daemon Control + Agent Host)

enum MemoryScopeSelection: Equatable, Hashable {
    case global
    case project(path: String, name: String)

    var layer: String {
        switch self {
        case .global: return "global"
        case .project: return "project"
        }
    }

    var projectPath: String? {
        switch self {
        case .global: return nil
        case .project(let path, _): return path
        }
    }
}

@MainActor
@Observable
final class PrismSettingsStore {
    var daemonStatus: DaemonStatusInfo? = nil
    var hostSettings: HostSettingsSnapshot = HostSettingsSnapshot()
    /// This computer's own host settings, whichever host the window shows: hosting Claude Code for
    /// other computers is this computer's, as the runs listed beside it are.
    var localHostSettings: HostSettingsSnapshot = HostSettingsSnapshot()
    var hostSettingsLiveRPC: Bool = true
    var pairedDevices: [PairedDeviceSummary] = []
    var remoteTerminalAllowed: Bool = false

    var environmentInfo: EnvironmentStatusInfo? = nil
    var lightAgents: [LightAgentInfo] = []
    var claudeSettingsByAgent: [String: ClaudeSettingsInfo] = [:]
    var autoCompactByAgent: [String: AutoCompactSettingsInfo] = [:]
    var busyAgentIDs: Set<String> = []

    var memoryOverview: MemoryOverviewInfo? = nil
    var selectedMemoryScope: MemoryScopeSelection = .global
    var hasSelectedInitialMemoryScope: Bool = false
    var memoryEntries: [MemoryEntryInfo] = []
    var isLoadingMemory: Bool = false

    // MARK: - P1 MCP Hub, OAuth Proxy & Agent Plugins State
    var mcpStatus: McpStatusInfo? = nil
    var marketCatalog: MarketCatalogInfo? = nil
    var marketSearch: MarketSearchInfo? = nil
    var marketKeyState: [String: [String]] = [:]
    var marketConnections: [String: MarketConnectionInfo] = [:]
    var marketPlugins: MarketPluginsInfo? = nil
    var pluginDetailsByKey: [String: PluginDetailsInfo] = [:]
    var activeOAuthServerID: String? = nil
    var activeOAuthStart: ConnectStartInfo? = nil
    var isLoadingExtensions: Bool = false
    var isSearchingCatalog: Bool = false
    var busyExtensionIDs: Set<String> = []

    var worktreeSettingsByProject: [String: ProjectWorktreeSettingsInfo] = [:]
    var isRefreshing: Bool = false
    var bannerError: String? = nil
    var bannerNotice: String? = nil
    var bannerID: UUID = UUID()

    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var bannerIsHovered: Bool = false
    private static let noticeAutoDismissSeconds: Double = 3.0

    func showNotice(_ text: String) {
        bannerError = nil
        bannerNotice = text
        bannerID = UUID()
        if !bannerIsHovered {
            scheduleNoticeAutoDismiss(for: text)
        }
    }

    func showError(_ text: String) {
        noticeTask?.cancel()
        noticeTask = nil
        bannerNotice = nil
        bannerError = text
        bannerID = UUID()
    }

    func setBannerHovered(_ hovered: Bool) {
        guard bannerIsHovered != hovered else { return }
        bannerIsHovered = hovered
        if hovered {
            noticeTask?.cancel()
            noticeTask = nil
        } else if let text = bannerNotice {
            scheduleNoticeAutoDismiss(for: text)
        }
    }

    func clearBanners() {
        noticeTask?.cancel()
        noticeTask = nil
        bannerIsHovered = false
        bannerError = nil
        bannerNotice = nil
    }

    private func scheduleNoticeAutoDismiss(for text: String) {
        noticeTask?.cancel()
        let seconds = Self.noticeAutoDismissSeconds
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.bannerIsHovered else { return }
            if self.bannerNotice == text {
                self.bannerNotice = nil
            }
        }
    }

    // MARK: - Section Loaders

    func loadHostSettings(state: SartoState, daemon: LocalDaemonManager) async {
        if state.connectionMode.isRemote, let host = state.activeHostSession {
            do {
                hostSettings = try await host.adminSettingsGet()
                hostSettingsLiveRPC = true
            } catch {
                // Remote host may forbid admin settings if paired as non-owner.
            }
            if let fetched = try? await daemon.fetchHostSettings() {
                localHostSettings = fetched.snapshot
            }
            return
        }
        do {
            let (snap, live) = try await daemon.fetchHostSettings()
            hostSettings = snap
            localHostSettings = snap
            hostSettingsLiveRPC = live
        } catch {
            // Keep defaults quietly when daemon is stopped.
        }
    }

    func loadDaemonAndRemote(state: SartoState, daemon: LocalDaemonManager) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await loadHostSettings(state: state, daemon: daemon)
        if let st = try? await daemon.fetchStatus() {
            daemonStatus = st
        }
        if let accSt = try? await daemon.fetchAccountStatus() {
            state.applyAccountStatus(accSt)
            if accSt.account.isSignedIn {
                _ = try? await daemon.listAccountDevices()
            }
        }
        if let syncSt = try? await daemon.fetchSyncStatus() {
            state.applySyncedStatus(syncSt)
        }
        if let devs = try? await daemon.listPairedDevices() {
            pairedDevices = devs
        }
        if let term = try? await daemon.fetchRemoteTerminalAllowed() {
            remoteTerminalAllowed = term
        }
    }

    /// Lightweight local-socket poll while Settings is visible so paired device presence and counts stay live.
    func refreshLiveDevicePresence(daemon: LocalDaemonManager) async {
        if let st = try? await daemon.fetchStatus() {
            daemonStatus = st
        }
        if let devs = try? await daemon.listPairedDevices() {
            pairedDevices = devs
        }
    }

    func loadAgentsSection(state: SartoState, daemon: LocalDaemonManager) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await loadHostSettings(state: state, daemon: daemon)
        await state.refreshAgentsFromHost()
        guard let host = state.activeHostSession else { return }
        if let env = try? await host.agentEnvironment() {
            environmentInfo = env
        }
        if let lights = try? await host.listLightAgents() {
            lightAgents = lights
        }
    }

    func loadAgentDetails(agent: AgentStatusInfo, state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        if agent.harnessId == "claude-code" || agent.id.hasPrefix("claude") {
            if let cs = try? await host.agentClaudeSettings(agentId: agent.id) {
                claudeSettingsByAgent[agent.id] = cs
            }
        }
        if let ac = try? await host.agentAutoCompact(agentId: agent.id) {
            autoCompactByAgent[agent.id] = ac
        }
        if AgentAvailability.isInstalled(agent),
           agent.disabled != true,
           agent.state != "not-installed",
           (agent.signIn != "signed-in" || agent.account == nil) {
            try? await host.refreshAgentAccount(agentId: agent.id, force: false)
            await state.refreshAgentsFromHost()
        }
    }

    func loadMemorySection(state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        isLoadingMemory = true
        defer { isLoadingMemory = false }
        do {
            let overview = try await host.memoryOverview()
            memoryOverview = overview
            if !hasSelectedInitialMemoryScope {
                hasSelectedInitialMemoryScope = true
                if overview.global.isEmpty {
                    let activePath = state.selectedSessionSummary?.projectPath
                    let preferred = activePath.flatMap { path in
                        overview.projects.first(where: { $0.project == path && $0.count > 0 })
                    } ?? overview.projects.first(where: { $0.count > 0 })
                    if let preferred {
                        selectedMemoryScope = .project(path: preferred.project, name: preferred.name)
                    }
                }
            }
            await loadMemoryEntries(scope: selectedMemoryScope, state: state)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func loadMemoryEntries(scope: MemoryScopeSelection, state: SartoState) async {
        hasSelectedInitialMemoryScope = true
        selectedMemoryScope = scope
        guard let host = state.activeHostSession else { return }
        do {
            memoryEntries = try await host.memoryList(layer: scope.layer, project: scope.projectPath)
        } catch {
            if case .global = scope, let g = memoryOverview?.global {
                memoryEntries = g
            } else {
                memoryEntries = []
                showError(error.localizedDescription)
            }
        }
    }

    func loadProjectWorktreeSettings(projectPath: String, state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        if let wt = try? await host.projectWorktreeSettings(path: projectPath) {
            worktreeSettingsByProject[projectPath] = wt
        }
    }

    // MARK: - Extensions Center (MCP Hub + OAuth Proxy + Agent Plugins)

    func loadExtensionsSection(
        state: SartoState,
        daemon: LocalDaemonManager,
        refresh: Bool = false
    ) async {
        isLoadingExtensions = true
        defer { isLoadingExtensions = false }

        await loadHostSettings(state: state, daemon: daemon)
        guard let host = state.activeHostSession else { return }

        async let statusTask = try? host.mcpStatus()
        async let keysTask = try? host.marketKeys()
        async let connectionsTask = try? host.marketConnections()
        async let catalogTask = try? host.marketCatalog(refresh: refresh, cached: !refresh)
        async let pluginsTask = try? host.marketPlugins(refresh: refresh, cached: !refresh)

        if let st = await statusTask {
            mcpStatus = st
        }
        if let ks = await keysTask {
            marketKeyState = ks
        }
        if let conns = await connectionsTask {
            marketConnections = conns
        }
        if let cat = await catalogTask {
            marketCatalog = cat
        }
        if let plugs = await pluginsTask {
            marketPlugins = plugs
        }

        // Background-refresh stale cached catalog/plugins without blocking initial paint.
        if !refresh {
            if marketCatalog?.stale == true || (marketCatalog?.sections.isEmpty ?? true) {
                Task { [weak self] in
                    guard let self, let liveHost = state.activeHostSession else { return }
                    if let fresh = try? await liveHost.marketCatalog(refresh: false, cached: false) {
                        self.marketCatalog = fresh
                    }
                }
            }
            if marketPlugins?.stale == true || (marketPlugins?.catalog.isEmpty ?? true) {
                Task { [weak self] in
                    guard let self, let liveHost = state.activeHostSession else { return }
                    if let fresh = try? await liveHost.marketPlugins(refresh: false, cached: false) {
                        self.marketPlugins = fresh
                    }
                }
            }
        }
    }

    func refreshMarketKeys(state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        if let ks = try? await host.marketKeys() {
            marketKeyState = ks
        }
    }

    func refreshMarketConnections(state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        if let conns = try? await host.marketConnections() {
            marketConnections = conns
        }
    }

    func retryBuiltinMcp(state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        busyExtensionIDs.insert("builtin:sarto")
        defer { busyExtensionIDs.remove("builtin:sarto") }
        do {
            mcpStatus = try await host.mcpRetry()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setMcpSartoOff(
        _ offAgentIds: [String],
        state: SartoState,
        daemon: LocalDaemonManager
    ) async {
        let unique = Array(Set(offAgentIds)).sorted()
        hostSettings.mcpSartoOff = unique
        await patchHostSettings(
            [
                "mcp": .object([
                    "sarto": .object([
                        "off": .array(unique.map(JSONValue.string)),
                    ]),
                ]),
            ],
            state: state,
            daemon: daemon
        )
    }

    func saveMcpServers(
        _ servers: [MarketServerInfo],
        state: SartoState,
        daemon: LocalDaemonManager,
        notice: String? = nil
    ) async {
        hostSettings.marketplaceMcp = servers
        await patchHostSettings(
            [
                "marketplace": .object([
                    "mcp": .array(servers.map { $0.toJSONValue() }),
                ]),
            ],
            state: state,
            daemon: daemon,
            notice: notice
        )
    }

    func saveMcpKeys(
        serverId: String,
        values: [String: String?],
        state: SartoState,
        daemon: LocalDaemonManager,
        notice: String? = nil
    ) async {
        busyExtensionIDs.insert("keys:\(serverId)")
        defer { busyExtensionIDs.remove("keys:\(serverId)") }
        do {
            let updated: [String: [String]]
            if state.connectionMode.isRemote, let host = state.activeHostSession {
                updated = try await host.adminMarketplaceSetKeys(serverId: serverId, values: values)
            } else {
                updated = try await daemon.setMarketplaceKeys(serverId: serverId, values: values)
            }
            marketKeyState = updated
            if let notice { showNotice(notice) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func searchMcpCatalog(query: String, state: SartoState) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            marketSearch = nil
            return
        }
        guard let host = state.activeHostSession else { return }
        isSearchingCatalog = true
        defer { isSearchingCatalog = false }
        do {
            marketSearch = try await host.marketSearch(query: trimmed)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func connectMcpOAuth(serverId: String, state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        busyExtensionIDs.insert("oauth:\(serverId)")
        defer { busyExtensionIDs.remove("oauth:\(serverId)") }
        do {
            let start = try await host.marketConnect(serverId: serverId)
            switch start.kind {
            case "browser":
                activeOAuthServerID = serverId
                activeOAuthStart = start
                if let urlStr = start.url, let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            case "device":
                activeOAuthServerID = serverId
                activeOAuthStart = start
                if let uri = start.verificationUri, let url = URL(string: uri) {
                    NSWorkspace.shared.open(url)
                }
            default:
                activeOAuthServerID = nil
                activeOAuthStart = nil
                await refreshMarketConnections(state: state)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func cancelMcpOAuth(state: SartoState) async {
        guard let loginId = activeOAuthStart?.loginId, !loginId.isEmpty else {
            activeOAuthServerID = nil
            activeOAuthStart = nil
            return
        }
        activeOAuthServerID = nil
        activeOAuthStart = nil
        if let host = state.activeHostSession {
            try? await host.marketCancelConnect(loginId: loginId)
        }
    }

    func disconnectMcpOAuth(serverId: String, state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        busyExtensionIDs.insert("oauth:\(serverId)")
        defer { busyExtensionIDs.remove("oauth:\(serverId)") }
        do {
            try await host.marketDisconnect(serverId: serverId)
            marketConnections[serverId] = MarketConnectionInfo(state: "disconnected")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func loadPluginDetails(agentId: String, pluginId: String, state: SartoState) async {
        guard let host = state.activeHostSession else { return }
        let key = "\(agentId)::\(pluginId)"
        do {
            let details = try await host.marketPluginDetails(agentId: agentId, pluginId: pluginId)
            pluginDetailsByKey[key] = details
        } catch {
            showError(error.localizedDescription)
        }
    }

    func installPlugin(
        agentId: String,
        pluginId: String,
        scope: String = "user",
        projectPath: String? = nil,
        state: SartoState,
        notice: String? = nil
    ) async {
        guard let host = state.activeHostSession else { return }
        let busyKey = "plugin:\(agentId)::\(pluginId)"
        busyExtensionIDs.insert(busyKey)
        defer { busyExtensionIDs.remove(busyKey) }
        do {
            _ = try await host.marketInstallPlugin(
                agentId: agentId,
                pluginId: pluginId,
                scope: scope,
                projectPath: projectPath
            )
            marketPlugins = try await host.marketPlugins(refresh: true, cached: false)
            if let notice { showNotice(notice) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func uninstallPlugin(
        agentId: String,
        pluginId: String,
        scope: String = "user",
        projectPath: String? = nil,
        state: SartoState,
        notice: String? = nil
    ) async {
        guard let host = state.activeHostSession else { return }
        let busyKey = "plugin:\(agentId)::\(pluginId)"
        busyExtensionIDs.insert(busyKey)
        defer { busyExtensionIDs.remove(busyKey) }
        do {
            try await host.marketUninstallPlugin(
                agentId: agentId,
                pluginId: pluginId,
                scope: scope,
                projectPath: projectPath
            )
            marketPlugins = try await host.marketPlugins(refresh: true, cached: false)
            if let notice { showNotice(notice) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func setPluginEnabled(
        agentId: String,
        pluginId: String,
        enabled: Bool,
        scope: String = "user",
        projectPath: String? = nil,
        state: SartoState
    ) async {
        guard let host = state.activeHostSession else { return }
        let busyKey = "plugin:\(agentId)::\(pluginId)"
        busyExtensionIDs.insert(busyKey)
        defer { busyExtensionIDs.remove(busyKey) }
        do {
            try await host.marketSetPluginEnabled(
                agentId: agentId,
                pluginId: pluginId,
                enabled: enabled,
                scope: scope,
                projectPath: projectPath
            )
            marketPlugins = try await host.marketPlugins(refresh: false, cached: false)
        } catch {
            showError(error.localizedDescription)
        }
    }

    func addPluginMarketplace(
        agentId: String,
        source: String,
        state: SartoState,
        notice: String? = nil
    ) async {
        guard let host = state.activeHostSession else { return }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busyExtensionIDs.insert("mp:add")
        defer { busyExtensionIDs.remove("mp:add") }
        do {
            _ = try await host.marketAddMarketplace(agentId: agentId, source: trimmed)
            marketPlugins = try await host.marketPlugins(refresh: true, cached: false)
            if let notice { showNotice(notice) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removePluginMarketplace(
        agentId: String,
        name: String,
        state: SartoState,
        notice: String? = nil
    ) async {
        guard let host = state.activeHostSession else { return }
        let busyKey = "mp:\(agentId)::\(name)"
        busyExtensionIDs.insert(busyKey)
        defer { busyExtensionIDs.remove(busyKey) }
        do {
            try await host.marketRemoveMarketplace(agentId: agentId, name: name)
            marketPlugins = try await host.marketPlugins(refresh: true, cached: false)
            if let notice { showNotice(notice) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Host Settings Mutations (Unified Remote HostAdmin + Local Daemon Control)

    func patchHostSettings(
        _ patch: [String: JSONValue],
        state: SartoState,
        daemon: LocalDaemonManager,
        notice: String? = nil
    ) async {
        let previous = hostSettings
        do {
            let updated: HostSettingsSnapshot
            if state.connectionMode.isRemote, let host = state.activeHostSession {
                updated = try await host.adminSettingsUpdate(patch)
            } else {
                updated = try await daemon.updateHostSettings(patch)
            }
            var merged = updated
            if merged.verboseUntil == nil {
                merged.verboseUntil = previous.verboseUntil
            }
            hostSettings = merged
            hostSettingsLiveRPC = true
            if let notice { showNotice(notice) }
        } catch {
            hostSettings = previous
            showError(error.localizedDescription)
        }
    }

    /// Changes `remote.claude` on this computer through its own daemon, whichever host the window
    /// shows; a device may not change it on another computer. The settings go back to `previous`,
    /// as they were before the change was shown, if the daemon refuses it.
    func patchLocalRemoteClaude(
        _ fields: [String: JSONValue],
        previous: HostSettingsSnapshot,
        state: SartoState,
        daemon: LocalDaemonManager
    ) async {
        do {
            let updated = try await daemon.updateHostSettings(["remote": .object(["claude": .object(fields)])])
            localHostSettings = updated
            if !state.connectionMode.isRemote {
                var merged = updated
                if merged.verboseUntil == nil {
                    merged.verboseUntil = hostSettings.verboseUntil
                }
                hostSettings = merged
                hostSettingsLiveRPC = true
            }
        } catch {
            localHostSettings = previous
            showError(error.localizedDescription)
        }
    }

    func setAgentBinary(
        harnessId: String,
        path: String,
        state: SartoState,
        daemon: LocalDaemonManager
    ) async throws {
        let previousVerbose = hostSettings.verboseUntil
        var updated: HostSettingsSnapshot
        if state.connectionMode.isRemote, let host = state.activeHostSession {
            updated = try await host.adminSetAgentBinary(harnessId: harnessId, path: path)
        } else {
            updated = try await daemon.setHostAgentBinary(harnessId: harnessId, path: path)
        }
        if updated.verboseUntil == nil {
            updated.verboseUntil = previousVerbose
        }
        hostSettings = updated
    }

    func setShellPath(
        _ path: String,
        state: SartoState,
        daemon: LocalDaemonManager
    ) async throws {
        let previousVerbose = hostSettings.verboseUntil
        var updated: HostSettingsSnapshot
        if state.connectionMode.isRemote, let host = state.activeHostSession {
            updated = try await host.adminSetShellPath(path)
        } else {
            updated = try await daemon.setHostShellPath(path)
        }
        if updated.verboseUntil == nil {
            updated.verboseUntil = previousVerbose
        }
        hostSettings = updated
    }
}
