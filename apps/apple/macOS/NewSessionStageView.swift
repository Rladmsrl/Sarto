import SartoProtocol
import MenuBarKit
import PrismDesign
import SwiftUI

/// Full-stage New Session start screen for macOS.
/// - Personalized time-aware greeting + live Daemon status pill
/// - Optional Sub-session parent indicator bar
/// - Focal centered dual-layer Composer + New Session Tray (passed in from `MacWorkbenchView` for unified focus/popovers)
/// - Start notices from `sessions.prepare`
/// - Lower usage card (the menu bar's usage numbers).
struct NewSessionStageView<ComposerContent: View>: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.openURL) private var openURL

    @Bindable var state: SartoState
    let island: PrismDynamicIslandCoordinator
    let greeting: String
    let relayShortLabel: String
    let agentDisplayName: (String) -> String
    let onManageConnection: () -> Void
    var onOpenAgentSettings: () -> Void = {}
    @ViewBuilder let composer: () -> ComposerContent

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 28)

                VStack(alignment: .leading, spacing: 14) {
                    // 1. Greeting, Sarto ADE Slogan & Daemon Status Row
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(greeting)
                                .font(.system(size: 27, weight: .regular, design: .serif))
                                .tracking(-0.4)
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                SartoSpectrumEmblem(size: 14)
                                Text(l10n.tr("brand.slogan"))
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)

                        if state.hasMultipleHosts {
                            targetHostPickerPill
                        } else {
                            Button(action: onManageConnection) {
                                HStack(spacing: 7) {
                                    HStack(spacing: 3) {
                                        Circle().fill(Color(hex: 0x4C8DF6)).frame(width: 4, height: 4)
                                        Circle().fill(Color(hex: 0xEA5A60)).frame(width: 4, height: 4)
                                        Circle().fill(Color(hex: 0xF2B84B)).frame(width: 4, height: 4)
                                        Circle().fill(Color(hex: 0x38B27B)).frame(width: 4, height: 4)
                                    }
                                    Text(state.connectionMode.isLive ? l10n.tr("studio.daemonLive") : l10n.tr("studio.daemonOffline"))
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(state.connectionMode.isLive ? tokens.foreground : tokens.mutedForeground)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 25)
                                .background(Capsule().fill(tokens.surface1.opacity(0.75)))
                                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 2. Optional Sub-Session Parent Strip
                    if let parent = state.resolvedNewSessionParent {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tokens.prismCobalt)
                            Text(l10n.tr("newSession.subSessionOf", parent.title ?? l10n.tr("sidebar.untitledSession")))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                state.openNewSession(projectPath: state.effectiveNewSessionProjectPath, scratch: state.effectiveNewSessionIsScratch, parentId: nil)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(tokens.mutedForeground)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(tokens.hoverWash))
                            }
                            .buttonStyle(.plain)
                            .help(l10n.tr("newSession.clearSubSession"))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).fill(tokens.primarySoft.opacity(0.65)))
                        .overlay(RoundedRectangle(cornerRadius: tokens.rSM, style: .continuous).strokeBorder(tokens.primaryBorder, lineWidth: 1))
                    }

                    // 3. Focal Hero Composer + Tray
                    composer()

                    // 4. Prepared Start Notices (if agent adjusted an option)
                    if !state.activeStartNotices.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.activeStartNotices) { notice in
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(tokens.warning)
                                    Text("\(l10n.tr("newSession.startNoticeTitle", agentDisplayName(state.selectedAgentID))): \(notice.option)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(tokens.secondaryForeground)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }

                    // 4b. While no agent can start: why, and the one button for its cause.
                    if state.connectionMode.isLive, let stopped = state.noAgentCanStart {
                        noAgentLine(stopped)
                    }

                    // 5. Lower Deck: Usage Overview
                    StudioUsageCard(
                        store: island.usageStore,
                        settingsStore: island.settingsStore,
                        historicalDailyTokens: state.studioUsageStats.dailyTokens,
                        fallbackQuotaPools: state.studioQuotaPools,
                        isLiveConnection: state.connectionMode.isLive,
                        telemetrySummary: l10n.tr(
                            "studio.telemetrySummary",
                            state.connectionMode.badgeLabel,
                            state.sessions.count,
                            state.selectableAgents.count,
                            relayShortLabel
                        ),
                        primaryActionTitle: state.connectionMode.isLive
                            ? l10n.tr("studio.manageConnection")
                            : l10n.tr("studio.connectLocalDaemon"),
                        onPrimaryAction: onManageConnection
                    )
                    .padding(.top, 6)
                    .onAppear { island.setUsageViewerVisible(true) }
                    .onDisappear { island.setUsageViewerVisible(false) }
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 28)
                .padding(.bottom, 32)

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    private var targetHostPickerPill: some View {
        let active = state.activeHostSnapshot
        let isRemote = !active.isLocal
        let dotColor: Color = active.isOnline
            ? (active.isLocal ? tokens.success : tokens.prismCobalt)
            : (active.isConnecting ? tokens.warning : tokens.placeholder)

        return Menu {
            ForEach(state.unifiedHosts) { host in
                let routeText: String = {
                    if host.isLocal { return l10n.tr("sidebar.host.thisMac") }
                    if host.isOnline { return host.viaRelay ? l10n.tr("sidebar.host.relay") : l10n.tr("sidebar.host.direct") }
                    if host.isConnecting { return l10n.tr("sidebar.host.connecting") }
                    return l10n.tr("sidebar.host.offline")
                }()
                Button {
                    guard host.id != state.activeHostID else { return }
                    Task {
                        await state.openNewSession(onHost: host.id, projectPath: nil, scratch: nil, parentId: nil)
                    }
                } label: {
                    if host.id == state.activeHostID {
                        Label("\(host.name) · \(routeText)", systemImage: "checkmark")
                    } else {
                        Label("\(host.name) · \(routeText)", systemImage: host.deviceSymbolName)
                    }
                }
                .disabled(!host.isOnline && !host.isLocal)
            }
            Divider()
            Button(action: onManageConnection) {
                Label(l10n.tr("sidebar.host.manageDevices"), systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5.5, height: 5.5)
                Image(systemName: active.deviceSymbolName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isRemote ? tokens.primary : tokens.mutedForeground)
                Text(active.name)
                    .font(.system(size: 11, weight: isRemote ? .semibold : .medium))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(tokens.placeholder)
            }
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(Capsule().fill(isRemote ? tokens.primarySoft : tokens.surface1.opacity(0.75)))
            .overlay(Capsule().strokeBorder(isRemote ? tokens.primaryBorder : tokens.borderEtched, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.tr("topbar.hostPopoverTitle"))
    }

    /// Why no agent can start, as its harness's state says it, and the button for the cause: a
    /// tool's guide, the install sheet for one harness, the update of one program, or Settings.
    private func noAgentLine(_ stopped: NoAgentReason) -> some View {
        let text: String
        if let reason = stopped.reason {
            let list = ListFormatter()
            list.locale = l10n.language.resolvedLocale
            let agents = list.string(from: stopped.agents) ?? stopped.agents.joined(separator: ", ")
            text = l10n.tr("agents.noAgentBecause", agents, AgentAvailability.reasonLabel(reason, l10n: l10n))
        } else {
            text = l10n.tr("agents.noAgent")
        }
        // One harness gets its own fix; several, their settings.
        let state = self.state
        let openURL = self.openURL
        let harness = stopped.harnesses.count == 1 ? stopped.harnesses.first : nil
        let updateCommand = harness.flatMap { id in state.agents.first { $0.id == id }?.cli?.update?.command }
        let action: (title: String, run: () -> Void)
        switch stopped.reason {
        case .needsNode?, .needsNpm?, .needsUv?:
            let tool: AgentProblemFix
            switch stopped.reason {
            case .needsNpm?: tool = .npm
            case .needsUv?: tool = .uv
            default: tool = .node
            }
            action = (AgentFixAction.openGuide(tool).title(l10n), {
                if let url = tool.guideURL { openURL(url) }
            })
        case .notInstalled? where harness != nil:
            action = (AgentFixAction.install.title(l10n), {
                if let harness { state.requestAgentInstall(harness, from: .workbench) }
            })
        case .tooOld? where updateCommand != nil:
            action = (l10n.tr("agents.problem.fix.update"), {
                if let harness, let updateCommand {
                    state.requestAgentUpdate(harness, command: updateCommand, from: .workbench)
                }
            })
        case nil:
            action = (l10n.tr("agents.setUpAgents"), onOpenAgentSettings)
        default:
            action = (AgentFixAction.openSettings.title(l10n), onOpenAgentSettings)
        }
        let color: Color = switch stopped.reason {
        case nil: tokens.secondaryForeground
        case .tooOld?: tokens.warning
        default: tokens.danger
        }
        return HStack(spacing: 8) {
            Image(systemName: stopped.reason == nil ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(color)
                .lineLimit(2)
                .help(text)
            Spacer(minLength: 8)
            Button(action: action.run) {
                Text(action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(tokens.surface1.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(tokens.borderStrong, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
    }
}

/// The usage card on the new session stage, fed by the menu bar's usage store so both show the
/// same numbers: the same sources, hidden providers, sync scope and privacy.
private struct StudioUsageCard: View {
    @ObservedObject var store: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    let historicalDailyTokens: [Double]
    let fallbackQuotaPools: [StudioQuotaPool]
    let isLiveConnection: Bool
    let telemetrySummary: String
    let primaryActionTitle: String
    let onPrimaryAction: () -> Void

    @Environment(\.prismL10n) private var l10n
    @State private var rangeDays = 30

    var body: some View {
        let privacy = settingsStore.settings.privacy
        StudioBentoChassisView(
            usage: usageData,
            rangeDays: $rangeDays,
            isLiveConnection: isLiveConnection,
            telemetrySummary: telemetrySummary,
            primaryActionTitle: primaryActionTitle,
            formatTokens: { Fmt.tokens($0) },
            formatMoney: { prismFormattedMoney($0, privacy: privacy) },
            onPrimaryAction: onPrimaryAction
        )
    }

    private var usageData: StudioUsageData {
        let history = store.includedHistory
        let includedIndices = store.providers.indices.filter { !store.excluded.contains(store.providers[$0].id) }
        let sources = includedIndices.map { p in
            let provider = store.providers[p]
            return StudioUsageSource(
                id: provider.id,
                name: provider.name,
                color: provider.color,
                dailyTokens: history.map { p < $0.tokens.count ? $0.tokens[p] : 0 },
                dailyCost: history.map { p < $0.money.count ? $0.money[p] : 0 }
            )
        }
        var requests: [Int: Int] = [:]
        for days in StudioUsageData.ranges {
            requests[days] = store.rankedModels(days: days).reduce(0) { $0 + $1.requests }
        }
        let remote = store.devices.count > 1 && settingsStore.settings.usageScope == .allMacs
        return StudioUsageData(
            sources: sources,
            requestsByRange: requests,
            deviceCount: remote ? max(1, store.devices.count) : 1,
            ready: store.ready,
            heatmapDailyTokens: mergedHeatmapSeries(sources: sources),
            quotas: resolvedQuotas(includedIndices: includedIndices)
        )
    }

    /// 182-day (26-week) daily token series: earlier weeks from `studioUsageStats`, recent 90 days
    /// overlaid from `PrismUsageStore` so numbers match the menu bar's filters and sync scope.
    private func mergedHeatmapSeries(sources: [StudioUsageSource]) -> [Double] {
        let totalDays = StudioUsageData.heatmapDays
        var merged = Array(repeating: 0.0, count: totalDays)
        let histTail = Array(historicalDailyTokens.suffix(totalDays))
        let histOffset = totalDays - histTail.count
        for (i, v) in histTail.enumerated() {
            merged[histOffset + i] = max(0, v)
        }
        let recentCount = sources.map(\.dailyTokens.count).max() ?? 0
        if recentCount > 0 {
            let take = min(totalDays, recentCount)
            let start = totalDays - take
            for dayOffset in 0..<take {
                var sum = 0.0
                for source in sources {
                    let srcIdx = source.dailyTokens.count - take + dayOffset
                    if srcIdx >= 0 && srcIdx < source.dailyTokens.count {
                        sum += source.dailyTokens[srcIdx]
                    }
                }
                merged[start + dayOffset] = sum
            }
        }
        return merged
    }

    private func resolvedQuotas(includedIndices: [Int]) -> [StudioQuotaItem] {
        var ranked: [(priority: Int, item: StudioQuotaItem)] = []
        let now = Date()

        for p in includedIndices {
            let provider = store.providers[p]
            guard provider.kind == .quota, provider.eligible else { continue }
            if !provider.allWindows.isEmpty {
                for w in provider.allWindows.prefix(2) {
                    let cur = w.current(at: now)
                    let resetStr = cur.reset ? "" : UsageCountdown.shortCountdown(to: cur.resetsAt, now: now, l10n: l10n)
                    ranked.append((
                        priority: cur.isFiveHour ? 0 : 1,
                        item: StudioQuotaItem(
                            id: "\(provider.id)-\(cur.id)",
                            name: "\(provider.name) · \(cur.label)",
                            color: provider.color,
                            remainingPercent: cur.remaining * 100.0,
                            resetLabel: resetStr,
                            isReset: cur.reset
                        )
                    ))
                }
            } else if let rem = provider.remaining {
                let resetStr = provider.windowReset ? "" : UsageCountdown.shortCountdown(to: provider.resetsAt, now: now, l10n: l10n)
                ranked.append((
                    priority: 0,
                    item: StudioQuotaItem(
                        id: "\(provider.id)-primary",
                        name: "\(provider.name) · \(provider.windowLabel)",
                        color: provider.color,
                        remainingPercent: rem * 100.0,
                        resetLabel: resetStr,
                        isReset: provider.windowReset
                    )
                ))
            }
        }

        if !ranked.isEmpty {
            return ranked.sorted { $0.priority < $1.priority }.prefix(4).map(\.item)
        }

        return fallbackQuotaPools.prefix(4).map { pool in
            let color: Color = {
                switch pool.brand {
                case "claude": return Color(hex: 0xD97757)
                case "codex": return Color(hex: 0x7A9DFF)
                case "antigravity": return Color(hex: 0x2F7BF5)
                default: return Color(hex: 0x5B89D6)
                }
            }()
            return StudioQuotaItem(
                id: pool.id,
                name: pool.name,
                color: color,
                remainingPercent: pool.remainingPercent,
                resetLabel: pool.resetLabel
            )
        }
    }
}
