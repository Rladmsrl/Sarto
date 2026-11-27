import AppKit
import SartoProtocol
import PrismDesign
import SwiftUI

// MARK: - P1 Extensions Center: MCP Hub, OAuth Proxy & Agent Plugins (Skills Hub intentionally omitted)

struct ExtensionsSettingsSectionView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case mcp
        case plugins

        var id: String { rawValue }
    }

    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    @Bindable var router: PrismSettingsRouter

    @State private var selectedTab: Tab = .mcp

    // MCP Hub UI State
    @State private var showBuiltinTools: Bool = false
    @State private var showBuiltinPlaces: Bool = false
    @State private var expandedServerID: String? = nil
    @State private var keyDraftsByServer: [String: [String: String]] = [:]
    @State private var catalogQuery: String = ""
    @State private var selectedCatalogSection: String = "all"
    @State private var showCustomServerSheet: Bool = false

    // Agent Plugins UI State
    @State private var pluginSearchQuery: String = ""
    @State private var selectedPluginAgentFilter: String = "all"
    @State private var expandedPluginDetailKey: String? = nil
    @State private var newMarketplaceAgentID: String = "claude-code"
    @State private var newMarketplaceSource: String = ""

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    private var visibleAgents: [AgentStatusInfo] {
        PrismSettingsStore.visibleAgents(from: state.agents)
    }

    private var pluginCapableAgents: [AgentStatusInfo] {
        visibleAgents.filter {
            $0.harnessId == "claude-code" || $0.harnessId == "codex" || $0.harnessId == "antigravity"
                || $0.id == "claude-code" || $0.id == "codex" || $0.id == "antigravity"
        }
    }

    private var marketplaceCapableAgents: [AgentStatusInfo] {
        pluginCapableAgents.filter { $0.harnessId != "antigravity" && $0.id != "antigravity" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !state.connectionMode.isLive {
                SettingsBannerView(text: l10n.tr("settings.hostOfflineBanner"), kind: .info)
            }

            // Segmented Tab Bar + Refresh
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    tabButton(.mcp, title: l10n.tr("settings.ext.tabMcp"), icon: "server.rack")
                    tabButton(.plugins, title: l10n.tr("settings.ext.tabPlugins"), icon: "puzzlepiece.extension")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface1))
                .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.borderEtched, lineWidth: 1))

                Spacer(minLength: 8)

                if store.isLoadingExtensions {
                    ProgressView()
                        .controlSize(.small)
                }

                SettingsPillButton(
                    l10n.tr("settings.ext.refresh"),
                    icon: "arrow.clockwise",
                    disabled: !state.connectionMode.isLive || store.isLoadingExtensions
                ) {
                    Task {
                        await store.loadExtensionsSection(state: state, daemon: daemon, refresh: true)
                    }
                }
            }

            switch selectedTab {
            case .mcp:
                mcpHubBody
            case .plugins:
                agentPluginsBody
            }
        }
        .sheet(isPresented: $showCustomServerSheet) {
            AddCustomMcpServerSheet(
                state: state,
                daemon: daemon,
                store: store,
                existingServers: store.hostSettings.marketplaceMcp
            )
            .environment(\.prismTokens, tokens)
            .environment(\.prismL10n, l10n)
            .preferredColorScheme(state.palette.colorScheme)
        }
        .onAppear {
            syncTabFromHighlight(router.highlightedRowID)
            if let firstMarketplaceAgent = marketplaceCapableAgents.first {
                newMarketplaceAgentID = firstMarketplaceAgent.id
            }
        }
        .onChange(of: router.highlightedRowID) { _, next in
            syncTabFromHighlight(next)
        }
    }

    private func syncTabFromHighlight(_ rowID: String?) {
        guard let rowID else { return }
        if rowID.hasPrefix("extensions.plugins") || rowID.hasPrefix("extensions.plugin") {
            selectedTab = .plugins
        } else if rowID.hasPrefix("extensions.") {
            selectedTab = .mcp
        }
    }

    private func tabButton(_ tab: Tab, title: String, icon: String) -> some View {
        let active = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
            }
            .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: max(4, tokens.rSM - 2), style: .continuous)
                    .fill(active ? tokens.activeWash : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab 1: MCP Hub & OAuth Proxy

    @ViewBuilder
    private var mcpHubBody: some View {
        if let oauthServerId = store.activeOAuthServerID,
           let oauthStart = store.activeOAuthStart {
            activeOAuthBanner(serverId: oauthServerId, start: oauthStart)
        }

        builtinSartoMcpSection
        installedMcpServersSection
        mcpCatalogSection
    }

    private func activeOAuthBanner(serverId: String, start: ConnectStartInfo) -> some View {
        let serverTitle = store.hostSettings.marketplaceMcp.first(where: { $0.id == serverId })?.title ?? serverId
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(l10n.tr("settings.ext.oauthInProgress", serverTitle))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer(minLength: 8)
                SettingsPillButton(l10n.tr("settings.ext.cancel"), destructive: true) {
                    Task { await store.cancelMcpOAuth(state: state) }
                }
            }

            if start.kind == "device", let code = start.userCode {
                HStack(spacing: 10) {
                    Text(l10n.tr("settings.ext.deviceCodePrompt"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                    Text(code)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tokens.surface2))
                    SettingsPillButton(l10n.tr("settings.ext.copyCode"), icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    if let uri = start.verificationUri, let url = URL(string: uri) {
                        SettingsPillButton(l10n.tr("settings.ext.openBrowser"), icon: "arrow.up.right.square", prominent: true) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else if let urlStr = start.url, let url = URL(string: urlStr) {
                HStack(spacing: 10) {
                    Text(l10n.tr("settings.ext.browserAuthPrompt"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                    Spacer(minLength: 6)
                    SettingsPillButton(l10n.tr("settings.ext.openBrowser"), icon: "arrow.up.right.square", prominent: true) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).fill(tokens.primarySoft))
        .overlay(RoundedRectangle(cornerRadius: tokens.rMD, style: .continuous).strokeBorder(tokens.prismCobalt.opacity(0.35), lineWidth: 1))
    }

    private var builtinSartoMcpSection: some View {
        let builtin = store.mcpStatus?.servers.first(where: { $0.name == "sarto" }) ?? store.mcpStatus?.servers.first
        let isRunning = builtin?.running ?? false
        let toolCount = builtin?.tools.count ?? 0
        let places = store.mcpStatus?.places ?? []

        return SettingsGroupSection(
            l10n.tr("settings.ext.builtinMcp"),
            trailingBadge: toolCount > 0 ? l10n.tr("settings.ext.toolCount", toolCount) : nil
        ) {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRowView(
                    id: "extensions.builtinMcp",
                    highlightedID: router.highlightedRowID,
                    title: builtin?.title ?? l10n.tr("settings.ext.builtinMcpTitle"),
                    subtitle: builtin?.error ?? l10n.tr("settings.ext.builtinMcpSub")
                ) {
                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(isRunning ? tokens.success : tokens.warning)
                                .frame(width: 7, height: 7)
                            Text(isRunning ? l10n.tr("settings.ext.running") : l10n.tr("settings.ext.stopped"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isRunning ? tokens.success : tokens.warning)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(isRunning ? tokens.successSoft : tokens.surface2))

                        SettingsPillButton(
                            l10n.tr("settings.ext.retry"),
                            icon: "arrow.triangle.2.circlepath",
                            disabled: !state.connectionMode.isLive || store.busyExtensionIDs.contains("builtin:sarto")
                        ) {
                            Task { await store.retryBuiltinMcp(state: state) }
                        }
                    }
                }

                if !visibleAgents.isEmpty {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n.tr("settings.ext.enabledForAgents"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.mutedForeground)
                        FlowChipsLayout(spacing: 6) {
                            ForEach(visibleAgents) { agent in
                                let enabled = !store.hostSettings.mcpSartoOff.contains(agent.id)
                                Button {
                                    var off = Set(store.hostSettings.mcpSartoOff)
                                    if enabled {
                                        off.insert(agent.id)
                                    } else {
                                        off.remove(agent.id)
                                    }
                                    Task {
                                        await store.setMcpSartoOff(Array(off), state: state, daemon: daemon)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 11))
                                            .foregroundStyle(enabled ? tokens.prismCobalt : tokens.mutedForeground)
                                        Text(agent.name)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(enabled ? tokens.foreground : tokens.mutedForeground)
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(enabled ? tokens.primarySoft : tokens.surface2)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(enabled ? tokens.prismCobalt.opacity(0.35) : tokens.borderEtched, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(!state.connectionMode.isLive)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }

                if let tools = builtin?.tools, !tools.isEmpty {
                    let grouped = Dictionary(grouping: tools, by: \.group)
                    let sortedGroups = grouped.keys.sorted()
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showBuiltinTools.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showBuiltinTools ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                Text(l10n.tr("settings.ext.exposedTools", tools.count))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.secondaryForeground)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        if showBuiltinTools {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(sortedGroups, id: \.self) { group in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(group.uppercased())
                                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(tokens.mutedForeground)
                                        FlowChipsLayout(spacing: 5) {
                                            ForEach(grouped[group] ?? []) { tool in
                                                HStack(spacing: 4) {
                                                    Text(tool.name)
                                                        .font(.system(size: 10.5, design: .monospaced))
                                                        .foregroundStyle(tokens.foreground)
                                                    if tool.asks {
                                                        Text(l10n.tr("settings.ext.toolAsks"))
                                                            .font(.system(size: 9, weight: .semibold))
                                                            .foregroundStyle(tokens.warning)
                                                    }
                                                }
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(RoundedRectangle(cornerRadius: 5).fill(tokens.surface2.opacity(0.8)))
                                                .help(tool.description)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                if !places.isEmpty {
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showBuiltinPlaces.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showBuiltinPlaces ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                Text(l10n.tr("settings.ext.agentConfigFiles", places.count))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.secondaryForeground)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)

                        if showBuiltinPlaces {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(places) { place in
                                    HStack(spacing: 8) {
                                        Text(state.agentDisplayName(for: place.agentId))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(tokens.foreground)
                                            .frame(width: 96, alignment: .leading)
                                        Text(place.path)
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 6)
                                        Button {
                                            let url = URL(fileURLWithPath: place.path)
                                            if FileManager.default.fileExists(atPath: place.path) {
                                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                            } else {
                                                NSWorkspace.shared.open(url.deletingLastPathComponent())
                                            }
                                        } label: {
                                            Image(systemName: "folder")
                                                .font(.system(size: 11))
                                                .foregroundStyle(tokens.secondaryForeground)
                                        }
                                        .buttonStyle(.plain)
                                        .help(l10n.tr("settings.advanced.openFolder"))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(tokens.surface2.opacity(0.6)))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var installedMcpServersSection: some View {
        let servers = store.hostSettings.marketplaceMcp
        return SettingsGroupSection(
            l10n.tr("settings.ext.mcpServers"),
            trailingBadge: "\(servers.count)"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(l10n.tr("settings.ext.mcpServersSub"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                    Spacer(minLength: 8)
                    SettingsPillButton(
                        l10n.tr("settings.ext.addCustom"),
                        icon: "plus",
                        prominent: true,
                        disabled: !state.connectionMode.isLive
                    ) {
                        showCustomServerSheet = true
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .id("extensions.mcpServers")

                if servers.isEmpty {
                    SettingsRowDivider()
                    Text(l10n.tr("settings.ext.mcpEmpty"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(14)
                } else {
                    ForEach(servers) { server in
                        SettingsRowDivider()
                        installedMcpServerRow(server)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func installedMcpServerRow(_ server: MarketServerInfo) -> some View {
        let isExpanded = expandedServerID == server.id
        let conn = store.marketConnections[server.id]
        let savedKeyNames = Set(store.marketKeyState[server.id] ?? [])
        let inputs = server.spec.inputs
        let missingRequired = inputs.filter { $0.required && !savedKeyNames.contains($0.name) }
        let oauthBusy = store.busyExtensionIDs.contains("oauth:\(server.id)")

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(server.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        Text(server.name)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.surface2))
                        Text(server.spec.type == "http" ? (server.spec.transport ?? "http").uppercased() : "STDIO")
                            .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                        if !missingRequired.isEmpty {
                            Text(l10n.tr("settings.ext.keysMissing", missingRequired.count))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(tokens.warning)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(tokens.surface2))
                        }
                    }
                    Text(server.spec.summaryText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                // OAuth Connect / Disconnect Control
                if server.spec.oauth != nil {
                    oauthActionView(server: server, conn: conn, busy: oauthBusy)
                }

                // Configure / Keys Toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedServerID = isExpanded ? nil : server.id
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "slider.horizontal.3")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(tokens.surface2))
                }
                .buttonStyle(.plain)
                .help(l10n.tr("settings.ext.configureServer"))

                Toggle(
                    "",
                    isOn: Binding<Bool>(
                        get: { server.on },
                        set: { next in
                            var updated = store.hostSettings.marketplaceMcp
                            if let idx = updated.firstIndex(where: { $0.id == server.id }) {
                                updated[idx].on = next
                                Task { await store.saveMcpServers(updated, state: state, daemon: daemon) }
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!state.connectionMode.isLive)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    // Agent Scope Selector
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(l10n.tr("settings.ext.agentScope"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tokens.secondaryForeground)
                            Spacer()
                            Toggle(
                                l10n.tr("settings.ext.allAgents"),
                                isOn: Binding<Bool>(
                                    get: { server.agentsAll },
                                    set: { all in
                                        var updated = store.hostSettings.marketplaceMcp
                                        if let idx = updated.firstIndex(where: { $0.id == server.id }) {
                                            updated[idx].agentsAll = all
                                            if !all && updated[idx].agentIds.isEmpty {
                                                updated[idx].agentIds = visibleAgents.map(\.id)
                                            }
                                            Task { await store.saveMcpServers(updated, state: state, daemon: daemon) }
                                        }
                                    }
                                )
                            )
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }

                        if !server.agentsAll {
                            FlowChipsLayout(spacing: 6) {
                                ForEach(visibleAgents) { agent in
                                    let selected = server.agentIds.contains(agent.id)
                                    Button {
                                        var updated = store.hostSettings.marketplaceMcp
                                        if let idx = updated.firstIndex(where: { $0.id == server.id }) {
                                            var ids = Set(updated[idx].agentIds)
                                            if selected { ids.remove(agent.id) } else { ids.insert(agent.id) }
                                            updated[idx].agentIds = Array(ids).sorted()
                                            Task { await store.saveMcpServers(updated, state: state, daemon: daemon) }
                                        }
                                    } label: {
                                        Text(agent.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(selected ? tokens.prismCobalt : tokens.mutedForeground)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3.5)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? tokens.primarySoft : tokens.surface2))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Secret / Env Inputs Editor
                    if !inputs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(l10n.tr("settings.ext.keysAndEnv"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tokens.secondaryForeground)

                            ForEach(inputs) { input in
                                let isSet = savedKeyNames.contains(input.name)
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 5) {
                                            Text(input.title ?? input.name)
                                                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                .foregroundStyle(tokens.foreground)
                                            if isSet {
                                                Text(l10n.tr("settings.ext.keySet"))
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                    .foregroundStyle(tokens.success)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(tokens.successSoft))
                                            } else if input.required {
                                                Text(l10n.tr("settings.ext.required"))
                                                    .font(.system(size: 9.5, weight: .semibold))
                                                    .foregroundStyle(tokens.warning)
                                            }
                                        }
                                        if let desc = input.description, !desc.isEmpty {
                                            Text(desc)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(tokens.mutedForeground)
                                                .lineLimit(2)
                                        }
                                    }
                                    .frame(width: 210, alignment: .leading)

                                    Group {
                                        if input.secret {
                                            SecureField(
                                                isSet ? l10n.tr("settings.ext.replaceSecretPlaceholder") : l10n.tr("settings.ext.enterValuePlaceholder"),
                                                text: keyDraftBinding(serverId: server.id, keyName: input.name)
                                            )
                                        } else {
                                            TextField(
                                                input.defaultValue ?? l10n.tr("settings.ext.enterValuePlaceholder"),
                                                text: keyDraftBinding(serverId: server.id, keyName: input.name)
                                            )
                                        }
                                    }
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))

                                    if isSet {
                                        SettingsPillButton(l10n.tr("settings.ext.clear"), destructive: true) {
                                            Task {
                                                await store.saveMcpKeys(
                                                    serverId: server.id,
                                                    values: [input.name: nil],
                                                    state: state,
                                                    daemon: daemon,
                                                    notice: l10n.tr("settings.ext.keysSaved")
                                                )
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Spacer()
                                SettingsPillButton(
                                    l10n.tr("settings.ext.saveKeys"),
                                    icon: "key.fill",
                                    prominent: true,
                                    disabled: (keyDraftsByServer[server.id] ?? [:]).values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                ) {
                                    let drafts = keyDraftsByServer[server.id] ?? [:]
                                    var patch: [String: String?] = [:]
                                    for (k, v) in drafts {
                                        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !trimmed.isEmpty { patch[k] = trimmed }
                                    }
                                    guard !patch.isEmpty else { return }
                                    Task {
                                        await store.saveMcpKeys(
                                            serverId: server.id,
                                            values: patch,
                                            state: state,
                                            daemon: daemon,
                                            notice: l10n.tr("settings.ext.keysSaved")
                                        )
                                        keyDraftsByServer[server.id] = [:]
                                    }
                                }
                            }
                        }
                    }

                    // Remove Server Footer
                    HStack {
                        Spacer()
                        SettingsPillButton(
                            l10n.tr("settings.ext.removeServer"),
                            icon: "trash",
                            destructive: true
                        ) {
                            let updated = store.hostSettings.marketplaceMcp.filter { $0.id != server.id }
                            expandedServerID = nil
                            Task {
                                await store.saveMcpServers(
                                    updated,
                                    state: state,
                                    daemon: daemon,
                                    notice: l10n.tr("settings.ext.serverRemoved", server.title)
                                )
                            }
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.surface2.opacity(0.45)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private func oauthActionView(server: MarketServerInfo, conn: MarketConnectionInfo?, busy: Bool) -> some View {
        switch conn?.state {
        case "connected":
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle().fill(tokens.success).frame(width: 6, height: 6)
                    Text(conn?.account ?? l10n.tr("settings.ext.connected"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.success)
                        .lineLimit(1)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(tokens.successSoft))

                SettingsPillButton(l10n.tr("settings.ext.disconnect"), disabled: busy) {
                    Task { await store.disconnectMcpOAuth(serverId: server.id, state: state) }
                }
            }
        case "needs-reconnect", "error":
            SettingsPillButton(l10n.tr("settings.ext.reconnect"), icon: "arrow.triangle.2.circlepath", prominent: true, disabled: busy) {
                Task { await store.connectMcpOAuth(serverId: server.id, state: state) }
            }
        default:
            SettingsPillButton(l10n.tr("settings.ext.connectOAuth"), icon: "person.badge.key", prominent: true, disabled: busy) {
                Task { await store.connectMcpOAuth(serverId: server.id, state: state) }
            }
        }
    }

    private func keyDraftBinding(serverId: String, keyName: String) -> Binding<String> {
        Binding<String>(
            get: { keyDraftsByServer[serverId]?[keyName] ?? "" },
            set: { next in
                var dict = keyDraftsByServer[serverId] ?? [:]
                dict[keyName] = next
                keyDraftsByServer[serverId] = dict
            }
        )
    }

    private var mcpCatalogSection: some View {
        let sections = store.marketCatalog?.sections ?? []
        let installedIDs = Set(store.hostSettings.marketplaceMcp.map(\.id))
        let trimmedQuery = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayedItems: [CatalogServerInfo] = {
            if !trimmedQuery.isEmpty, let search = store.marketSearch,
               search.query.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedQuery) == .orderedSame {
                return search.items
            }
            var seen: Set<String> = []
            let base: [CatalogServerInfo] = {
                if selectedCatalogSection == "all" || !trimmedQuery.isEmpty {
                    return sections.flatMap(\.items).filter { seen.insert($0.id).inserted }
                }
                return sections.first(where: { $0.id == selectedCatalogSection })?.items ?? []
            }()
            guard !trimmedQuery.isEmpty else { return base }
            let needle = trimmedQuery.lowercased()
            return base.filter { item in
                item.title.lowercased().contains(needle)
                    || item.id.lowercased().contains(needle)
                    || item.publisher.lowercased().contains(needle)
                    || item.description.lowercased().contains(needle)
            }
        }()

        return SettingsGroupSection(l10n.tr("settings.ext.mcpCatalog")) {
            VStack(alignment: .leading, spacing: 0) {
                // Search Bar
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11.5))
                            .foregroundStyle(tokens.mutedForeground)
                        TextField(l10n.tr("settings.ext.catalogSearchPlaceholder"), text: $catalogQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .onSubmit {
                                Task { await store.searchMcpCatalog(query: catalogQuery, state: state) }
                            }
                        if !catalogQuery.isEmpty {
                            Button {
                                catalogQuery = ""
                                store.marketSearch = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))

                    SettingsPillButton(
                        l10n.tr("settings.ext.search"),
                        prominent: true,
                        disabled: trimmedQuery.isEmpty || store.isSearchingCatalog || !state.connectionMode.isLive
                    ) {
                        Task { await store.searchMcpCatalog(query: catalogQuery, state: state) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .id("extensions.mcpCatalog")

                if trimmedQuery.isEmpty && !sections.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            catalogCategoryChip(id: "all", label: l10n.tr("settings.ext.categoryAll"))
                            ForEach(sections) { sec in
                                catalogCategoryChip(id: sec.id, label: sec.id.capitalized)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                    }
                }

                if let err = store.marketSearch?.error ?? store.marketCatalog?.error {
                    SettingsRowDivider()
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.warning)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }

                if store.isSearchingCatalog {
                    SettingsRowDivider()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.tr("settings.ext.searching"))
                            .font(.system(size: 12))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(14)
                } else if displayedItems.isEmpty {
                    SettingsRowDivider()
                    Text(l10n.tr("settings.ext.catalogEmpty"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(14)
                } else {
                    ForEach(displayedItems.prefix(40)) { item in
                        SettingsRowDivider()
                        catalogServerRow(item, isInstalled: installedIDs.contains(item.id))
                    }
                }
            }
        }
    }

    private func catalogCategoryChip(id: String, label: String) -> some View {
        let active = selectedCatalogSection == id
        return Button {
            selectedCatalogSection = id
        } label: {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? tokens.prismCobalt : tokens.secondaryForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? tokens.primarySoft : tokens.surface2))
        }
        .buttonStyle(.plain)
    }

    private func catalogServerRow(_ item: CatalogServerInfo, isInstalled: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    if item.official {
                        Text(l10n.tr("settings.ext.official"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tokens.primarySoft))
                    }
                    if !item.publisher.isEmpty {
                        Text(item.publisher)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    if item.spec.oauth != nil {
                        Text("OAuth")
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.prismIris)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tokens.surface2))
                    }
                }
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if isInstalled {
                Text(l10n.tr("settings.ext.installed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.success)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tokens.successSoft))
            } else {
                SettingsPillButton(
                    l10n.tr("settings.ext.install"),
                    icon: "plus",
                    disabled: !state.connectionMode.isLive
                ) {
                    let current = store.hostSettings.marketplaceMcp
                    let name = MarketServerInfo.suggestedName(from: item.id, existing: current)
                    let server = MarketServerInfo(
                        id: item.id,
                        name: name,
                        title: item.title,
                        source: "registry",
                        version: item.version.isEmpty ? nil : item.version,
                        spec: item.spec,
                        agentsAll: true,
                        agentIds: [],
                        on: true
                    )
                    var updated = current
                    updated.append(server)
                    if !item.spec.inputs.isEmpty {
                        expandedServerID = server.id
                    }
                    Task {
                        await store.saveMcpServers(
                            updated,
                            state: state,
                            daemon: daemon,
                            notice: l10n.tr("settings.ext.serverInstalled", item.title)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Tab 2: Agent Plugins (Claude Code & Codex)

    @ViewBuilder
    private var agentPluginsBody: some View {
        let pluginsData = store.marketPlugins
        let installedAll = pluginsData?.installed ?? []
        let installed = installedAll.filter { item in
            selectedPluginAgentFilter == "all" || item.agentId == selectedPluginAgentFilter
        }
        let installedKeys = Set(installedAll.map { "\($0.agentId)::\($0.pluginId)" })
        let agentByHarness: [String: AgentStatusInfo] = {
            var map: [String: AgentStatusInfo] = [:]
            for agent in pluginCapableAgents {
                if let harnessId = agent.harnessId, map[harnessId] == nil {
                    map[harnessId] = agent
                }
                if map[agent.id] == nil {
                    map[agent.id] = agent
                }
            }
            return map
        }()
        let catalog = filteredPluginCatalog(store.sortedPluginCatalog)
        let marketplaces = pluginsData?.marketplaces ?? []

        if let errors = pluginsData?.errors, !errors.isEmpty {
            ForEach(errors) { err in
                SettingsBannerView(text: "\(state.agentDisplayName(for: err.agentId)): \(err.message)", kind: .info)
            }
        }

        // Agent Filter Chips
        if pluginCapableAgents.count > 1 {
            HStack(spacing: 6) {
                pluginAgentChip(id: "all", label: l10n.tr("settings.ext.allPluginAgents"))
                ForEach(pluginCapableAgents) { agent in
                    pluginAgentChip(id: agent.id, label: agent.name)
                }
                Spacer(minLength: 0)
            }
        }

        // Installed Plugins
        SettingsGroupSection(
            l10n.tr("settings.ext.installedPlugins"),
            trailingBadge: "\(installed.count)"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if installed.isEmpty {
                    Text(l10n.tr("settings.ext.noInstalledPlugins"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(14)
                        .id("extensions.plugins")
                } else {
                    ForEach(Array(installed.enumerated()), id: \.element.id) { idx, plugin in
                        if idx > 0 { SettingsRowDivider() }
                        installedPluginRow(plugin)
                    }
                    .id("extensions.plugins")
                }
            }
        }

        // Plugin Catalog
        SettingsGroupSection(
            l10n.tr("settings.ext.pluginCatalog"),
            trailingBadge: "\(catalog.count)"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.mutedForeground)
                    TextField(l10n.tr("settings.ext.pluginSearchPlaceholder"), text: $pluginSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !pluginSearchQuery.isEmpty {
                        Button { pluginSearchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if catalog.isEmpty {
                    SettingsRowDivider()
                    Text(l10n.tr("settings.ext.pluginCatalogEmpty"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(14)
                } else {
                    ForEach(catalog.prefix(50)) { item in
                        SettingsRowDivider()
                        catalogPluginRow(item, installedKeys: installedKeys, agentByHarness: agentByHarness)
                    }
                    if catalog.count > 50 {
                        SettingsRowDivider()
                        Text(l10n.tr("settings.ext.pluginCatalogTruncated", 50, catalog.count))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
            }
        }

        // Plugin Marketplaces
        SettingsGroupSection(
            l10n.tr("settings.ext.pluginMarketplaces"),
            trailingBadge: "\(marketplaces.count)"
        ) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if !marketplaceCapableAgents.isEmpty {
                        Picker("", selection: $newMarketplaceAgentID) {
                            ForEach(marketplaceCapableAgents) { agent in
                                Text(agent.name).tag(agent.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    TextField(l10n.tr("settings.ext.marketplacePlaceholder"), text: $newMarketplaceSource)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    SettingsPillButton(
                        l10n.tr("settings.ext.add"),
                        icon: "plus",
                        prominent: true,
                        disabled: newMarketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !state.connectionMode.isLive
                            || store.busyExtensionIDs.contains("mp:add")
                    ) {
                        let source = newMarketplaceSource.trimmingCharacters(in: .whitespacesAndNewlines)
                        let agentId = newMarketplaceAgentID
                        Task {
                            await store.addPluginMarketplace(
                                agentId: agentId,
                                source: source,
                                state: state,
                                notice: l10n.tr("settings.ext.marketplaceAdded")
                            )
                            newMarketplaceSource = ""
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if marketplaces.isEmpty {
                    SettingsRowDivider()
                    Text(l10n.tr("settings.ext.noMarketplaces"))
                        .font(.system(size: 12))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(14)
                } else {
                    ForEach(marketplaces) { mp in
                        SettingsRowDivider()
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(mp.name)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(tokens.foreground)
                                    Text(state.agentDisplayName(for: mp.agentId))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Capsule().fill(tokens.surface2))
                                    if mp.official {
                                        Text(l10n.tr("settings.ext.official"))
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundStyle(tokens.prismCobalt)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(tokens.primarySoft))
                                    }
                                }
                                if !mp.source.isEmpty {
                                    Text(mp.source)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(tokens.mutedForeground)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 8)
                            if !mp.official {
                                SettingsPillButton(
                                    l10n.tr("settings.ext.remove"),
                                    destructive: true,
                                    disabled: store.busyExtensionIDs.contains("mp:\(mp.agentId)::\(mp.name)")
                                ) {
                                    Task {
                                        await store.removePluginMarketplace(
                                            agentId: mp.agentId,
                                            name: mp.name,
                                            state: state,
                                            notice: l10n.tr("settings.ext.marketplaceRemoved", mp.name)
                                        )
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func pluginAgentChip(id: String, label: String) -> some View {
        let active = selectedPluginAgentFilter == id
        return Button {
            selectedPluginAgentFilter = id
        } label: {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? tokens.prismCobalt : tokens.secondaryForeground)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? tokens.primarySoft : tokens.surface1))
                .overlay(Capsule().strokeBorder(active ? tokens.prismCobalt.opacity(0.35) : tokens.borderEtched, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func filteredPluginCatalog(_ sortedItems: [CatalogPluginInfo]) -> [CatalogPluginInfo] {
        let q = pluginSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let selectedHarness: String? = {
            guard selectedPluginAgentFilter != "all" else { return nil }
            return pluginCapableAgents.first(where: { $0.id == selectedPluginAgentFilter })?.harnessId
                ?? selectedPluginAgentFilter
        }()
        if selectedHarness == nil && q.isEmpty {
            return sortedItems
        }
        return sortedItems.filter { item in
            if let selectedHarness, item.harness != selectedHarness {
                return false
            }
            guard !q.isEmpty else { return true }
            return item.title.lowercased().contains(q)
                || item.name.lowercased().contains(q)
                || item.description.lowercased().contains(q)
                || item.marketplace.lowercased().contains(q)
        }
    }

    private func formatInstallCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000.0) }
        return "\(count)"
    }

    @ViewBuilder
    private func installedPluginRow(_ plugin: InstalledPluginInfo) -> some View {
        let detailKey = "\(plugin.agentId)::\(plugin.pluginId)"
        let busyKey = "plugin:\(plugin.agentId)::\(plugin.pluginId)"
        let busy = store.busyExtensionIDs.contains(busyKey)
        let isExpanded = expandedPluginDetailKey == detailKey
        let details = store.pluginDetailsByKey[detailKey]

        let displayName = plugin.harness == "antigravity" && plugin.pluginId.hasSuffix("@antigravity")
            ? String(plugin.pluginId.dropLast("@antigravity".count))
            : plugin.pluginId

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tokens.foreground)
                        Text(state.agentDisplayName(for: plugin.agentId))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.primarySoft))
                        Text(plugin.scope)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tokens.surface2))
                        if let ver = plugin.version, !ver.isEmpty {
                            Text("v\(ver)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                    if let proj = plugin.projectPath, !proj.isEmpty {
                        Text(proj)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                SettingsPillButton(l10n.tr("settings.ext.details"), icon: "info.circle") {
                    if isExpanded {
                        expandedPluginDetailKey = nil
                    } else {
                        expandedPluginDetailKey = detailKey
                        if details == nil {
                            Task { await store.loadPluginDetails(agentId: plugin.agentId, pluginId: plugin.pluginId, state: state) }
                        }
                    }
                }

                Toggle(
                    "",
                    isOn: Binding<Bool>(
                        get: { plugin.enabled },
                        set: { next in
                            Task {
                                await store.setPluginEnabled(
                                    agentId: plugin.agentId,
                                    pluginId: plugin.pluginId,
                                    enabled: next,
                                    scope: plugin.scope,
                                    projectPath: plugin.projectPath,
                                    state: state
                                )
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(busy || !state.connectionMode.isLive)

                SettingsPillButton(l10n.tr("settings.ext.uninstall"), destructive: true, disabled: busy || !state.connectionMode.isLive) {
                    Task {
                        await store.uninstallPlugin(
                            agentId: plugin.agentId,
                            pluginId: plugin.pluginId,
                            scope: plugin.scope,
                            projectPath: plugin.projectPath,
                            state: state,
                            notice: l10n.tr("settings.ext.pluginUninstalled", plugin.pluginId)
                        )
                    }
                }
            }

            if isExpanded {
                if let details {
                    VStack(alignment: .leading, spacing: 6) {
                        if let desc = details.description, !desc.isEmpty {
                            Text(desc)
                                .font(.system(size: 11.5))
                                .foregroundStyle(tokens.secondaryForeground)
                        }
                        pluginComponentSummary(l10n.tr("settings.ext.detailSkills"), items: details.skills)
                        pluginComponentSummary(l10n.tr("settings.ext.detailCommands"), items: details.commands)
                        pluginComponentSummary(l10n.tr("settings.ext.detailAgents"), items: details.agents)
                        pluginComponentSummary(l10n.tr("settings.ext.detailHooks"), items: details.hooks)
                        pluginComponentSummary(l10n.tr("settings.ext.detailMcp"), items: details.mcpServers)
                        if let tokensEst = details.alwaysOnTokens, tokensEst > 0 {
                            Text(l10n.tr("settings.ext.alwaysOnTokens", tokensEst))
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(tokens.mutedForeground)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: tokens.rSM).fill(tokens.surface2.opacity(0.5)))
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(l10n.tr("settings.ext.loadingDetails"))
                            .font(.system(size: 11))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func pluginComponentSummary(_ title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(title) (\(items.count))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                FlowChipsLayout(spacing: 4) {
                    ForEach(items, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.foreground)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(tokens.surface1))
                    }
                }
            }
        }
    }

    private func catalogPluginRow(
        _ item: CatalogPluginInfo,
        installedKeys: Set<String>,
        agentByHarness: [String: AgentStatusInfo]
    ) -> some View {
        let targetAgent = agentByHarness[item.harness]
        let targetAgentId = targetAgent?.id ?? item.harness
        let isInstalled = installedKeys.contains("\(targetAgentId)::\(item.id)")
        let busyKey = "plugin:\(targetAgentId)::\(item.id)"
        let busy = store.busyExtensionIDs.contains(busyKey)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    if item.official {
                        Text(l10n.tr("settings.ext.official"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(tokens.prismCobalt)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(tokens.primarySoft))
                    }
                    Text(state.agentDisplayName(for: targetAgentId))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tokens.surface2))
                    if !item.marketplace.isEmpty {
                        Text(item.marketplace)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                    if let installs = item.installs, installs > 0 {
                        HStack(spacing: 2.5) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 9))
                            Text(formatInstallCount(installs))
                                .font(.system(size: 9.5, design: .monospaced))
                        }
                        .foregroundStyle(tokens.mutedForeground)
                    }
                }
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            if isInstalled {
                Text(l10n.tr("settings.ext.installed"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.success)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tokens.successSoft))
            } else {
                SettingsPillButton(
                    l10n.tr("settings.ext.install"),
                    icon: "arrow.down.circle",
                    disabled: busy || !state.connectionMode.isLive || targetAgent == nil
                ) {
                    Task {
                        await store.installPlugin(
                            agentId: targetAgentId,
                            pluginId: item.id,
                            scope: "user",
                            projectPath: nil,
                            state: state,
                            notice: l10n.tr("settings.ext.pluginInstalled", item.title)
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Add Custom MCP Server Sheet

private struct AddCustomMcpServerSheet: View {
    enum Mode: String, CaseIterable {
        case http
        case stdio
    }

    @Bindable var state: SartoState
    @Bindable var daemon: LocalDaemonManager
    @Bindable var store: PrismSettingsStore
    let existingServers: [MarketServerInfo]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    @State private var mode: Mode = .http
    @State private var titleText: String = ""
    @State private var httpTransport: String = "streamable-http"
    @State private var urlText: String = ""
    @State private var detectedOAuth: McpOAuthInfo? = nil
    @State private var isDetectingOAuth: Bool = false
    @State private var oauthProbeStatus: String? = nil

    @State private var commandText: String = ""
    @State private var argsText: String = ""

    @State private var kvPairs: [(id: UUID, name: String, value: String, secret: Bool)] = []
    @State private var validationError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(l10n.tr("settings.ext.addCustomTitle"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $mode) {
                Text("HTTP / SSE").tag(Mode.http)
                Text(l10n.tr("settings.ext.mcpModeStdio")).tag(Mode.stdio)
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.tr("settings.ext.serverTitle"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                    TextField(l10n.tr("settings.ext.serverTitlePlaceholder"), text: $titleText)
                        .textFieldStyle(.roundedBorder)
                }

                if mode == .http {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("settings.ext.serverUrl"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(tokens.secondaryForeground)
                            TextField("https://example.com/mcp", text: $urlText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(l10n.tr("settings.ext.transport"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(tokens.secondaryForeground)
                            Picker("", selection: $httpTransport) {
                                Text("Streamable HTTP").tag("streamable-http")
                                Text("SSE").tag("sse")
                            }
                            .labelsHidden()
                            .frame(width: 145)
                        }
                    }

                    HStack(spacing: 8) {
                        SettingsPillButton(
                            l10n.tr("settings.ext.detectOAuth"),
                            icon: "person.badge.key",
                            disabled: urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDetectingOAuth
                        ) {
                            Task { await probeOAuth() }
                        }
                        if isDetectingOAuth {
                            ProgressView().controlSize(.mini)
                        } else if let status = oauthProbeStatus {
                            Text(status)
                                .font(.system(size: 11))
                                .foregroundStyle(detectedOAuth != nil ? tokens.success : tokens.mutedForeground)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.tr("settings.ext.command"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        TextField("npx", text: $commandText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.tr("settings.ext.args"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        TextField("-y @modelcontextprotocol/server-filesystem /path", text: $argsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                // Optional Headers / Env Pairs
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(mode == .http ? l10n.tr("settings.ext.headers") : l10n.tr("settings.ext.envVars"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                        Spacer()
                        Button {
                            kvPairs.append((id: UUID(), name: "", value: "", secret: true))
                        } label: {
                            Label(l10n.tr("settings.ext.addField"), systemImage: "plus")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(tokens.prismCobalt)
                    }

                    ForEach(Array(kvPairs.enumerated()), id: \.element.id) { idx, pair in
                        HStack(spacing: 6) {
                            TextField(mode == .http ? "Authorization" : "API_KEY", text: Binding(
                                get: { kvPairs[idx].name },
                                set: { kvPairs[idx].name = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 140)

                            Group {
                                if pair.secret {
                                    SecureField(l10n.tr("settings.ext.enterValuePlaceholder"), text: Binding(
                                        get: { kvPairs[idx].value },
                                        set: { kvPairs[idx].value = $0 }
                                    ))
                                } else {
                                    TextField(l10n.tr("settings.ext.enterValuePlaceholder"), text: Binding(
                                        get: { kvPairs[idx].value },
                                        set: { kvPairs[idx].value = $0 }
                                    ))
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))

                            Toggle(l10n.tr("settings.ext.secret"), isOn: Binding(
                                get: { kvPairs[idx].secret },
                                set: { kvPairs[idx].secret = $0 }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))

                            Button {
                                kvPairs.remove(at: idx)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(tokens.mutedForeground)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let err = validationError {
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.danger)
            }

            HStack {
                Spacer()
                SettingsPillButton(l10n.tr("settings.ext.cancel")) { dismiss() }
                SettingsPillButton(l10n.tr("settings.ext.saveServer"), icon: "checkmark", prominent: true) {
                    Task { await saveServer() }
                }
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(tokens.surface1)
    }

    private func probeOAuth() async {
        guard let host = state.activeHostSession else { return }
        isDetectingOAuth = true
        defer { isDetectingOAuth = false }
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let oauth = try await host.marketDetectSignIn(url: url)
            detectedOAuth = oauth
            oauthProbeStatus = oauth != nil
                ? l10n.tr("settings.ext.oauthDetected")
                : l10n.tr("settings.ext.oauthNotRequired")
        } catch {
            oauthProbeStatus = error.localizedDescription
        }
    }

    private func saveServer() async {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            validationError = l10n.tr("settings.ext.errMissingTitle")
            return
        }

        var specs: [McpValueSpec] = []
        var secretValuesToStore: [String: String?] = [:]
        for pair in kvPairs {
            let k = pair.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { continue }
            if pair.secret {
                specs.append(McpValueSpec(name: k, isInput: true, secret: true, required: true))
                let v = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { secretValuesToStore[k] = v }
            } else {
                specs.append(McpValueSpec(name: k, value: pair.value))
            }
        }

        let spec: McpSpecInfo
        if mode == .http {
            let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, URL(string: url) != nil else {
                validationError = l10n.tr("settings.ext.errInvalidUrl")
                return
            }
            spec = McpSpecInfo(
                type: "http",
                transport: httpTransport,
                url: url,
                headers: specs,
                oauth: detectedOAuth
            )
        } else {
            let cmd = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else {
                validationError = l10n.tr("settings.ext.errMissingCommand")
                return
            }
            let args = argsText.split(whereSeparator: \.isWhitespace).map(String.init)
            spec = McpSpecInfo(
                type: "stdio",
                command: cmd,
                args: args,
                env: specs
            )
        }

        let serverId = "manual:\(UUID().uuidString.lowercased())"
        let name = MarketServerInfo.suggestedName(from: title, existing: existingServers)
        let newServer = MarketServerInfo(
            id: serverId,
            name: name,
            title: title,
            source: "manual",
            version: nil,
            spec: spec,
            agentsAll: true,
            agentIds: [],
            on: true
        )
        var updated = existingServers
        updated.append(newServer)
        await store.saveMcpServers(
            updated,
            state: state,
            daemon: daemon,
            notice: l10n.tr("settings.ext.serverInstalled", title)
        )
        if !secretValuesToStore.isEmpty {
            await store.saveMcpKeys(serverId: serverId, values: secretValuesToStore, state: state, daemon: daemon)
        }
        dismiss()
    }
}

// MARK: - Lightweight Wrapping Flow Layout for Agent Chips

private struct FlowChipsLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }
    }
}
