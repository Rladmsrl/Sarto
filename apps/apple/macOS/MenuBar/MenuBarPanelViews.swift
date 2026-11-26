// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import Charts
import SartoProtocol
import MenuBarKit
import PrismDesign
import SwiftUI

// MARK: - Menu Bar Status Item Helpers

@MainActor
func prismFormattedMoney(_ value: Double, privacy: Bool) -> String {
    privacy ? "\(Fmt.symbol)••••" : Fmt.money(value)
}

@MainActor
func prismStatusTitle(store: PrismUsageStore, settings: UsageIslandSettings) -> String {
    switch settings.statusText {
    case .icon:
        return ""
    case .today:
        return prismFormattedMoney(store.todaySpend, privacy: settings.privacy)
    case .lowest:
        return store.lowestRemaining.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
    }
}

@MainActor private var cachedStatusMarkImage: NSImage?
@MainActor private var cachedBadgedStatusMarkImage: NSImage?

/// The Sarto mark as the menu bar's template image, drawn from the same geometry as the app icon.
/// `badged` puts an up arrow in a circle beside it while an update waits in Settings.
@MainActor
func prismStatusMarkImage(badged: Bool = false) -> NSImage? {
    if badged, let cachedBadgedStatusMarkImage { return cachedBadgedStatusMarkImage }
    if !badged, let cachedStatusMarkImage { return cachedStatusMarkImage }
    let mark: CGFloat = 18
    let arrow = badged
        ? NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        : nil
    let gap: CGFloat = 3
    let canvas = NSSize(width: mark + (arrow.map { gap + $0.size.width } ?? 0), height: 18)
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width * scale),
        pixelsHigh: Int(canvas.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = canvas

    NSGraphicsContext.saveGraphicsState()
    if let nsCtx = NSGraphicsContext(bitmapImageRep: rep) {
        NSGraphicsContext.current = nsCtx
        let ctx = nsCtx.cgContext
        ctx.saveGState()
        // The geometry is laid out top-down like SwiftUI; the bitmap context grows upward.
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        let side: CGFloat = 15.5
        let box = CGRect(x: (mark - side) / 2, y: (canvas.height - side) / 2, width: side, height: side)
        ctx.addPath(SartoMarkGeometry.path(in: box, detail: .small, part: .tiles).cgPath)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.fillPath()
        ctx.addPath(SartoMarkGeometry.path(in: box, detail: .small, part: .solid).cgPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        if let arrow {
            let size = arrow.size
            arrow.draw(in: NSRect(
                x: mark + gap,
                y: (canvas.height - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: canvas)
    image.addRepresentation(rep)
    image.isTemplate = true
    image.accessibilityDescription = SartoBrand.name
    if badged {
        cachedBadgedStatusMarkImage = image
    } else {
        cachedStatusMarkImage = image
    }
    return image
}

// MARK: - Router & Actions

enum MenuBarPage: Equatable {
    case main
    case detail(String)
    case usage
}

@MainActor
final class MenuBarPanelRouter: ObservableObject {
    @Published var page: MenuBarPage = .main
    @Published var usageRange = 30

    func go(_ next: MenuBarPage) {
        withAnimation(Motion.page) { page = next }
    }
}

@MainActor
struct MenuBarPanelActions {
    let openMainWindow: (String?) -> Void
    let openSettings: (PrismSettingsSection?) -> Void
    let toggleIsland: () -> Void
    let setPinned: (Bool) -> Void
    let previewPop: () -> Void
    let previewApproval: () -> Void
    let refresh: () -> Void
    let close: () -> Void
    let quit: () -> Void
    /// The version of an update downloaded and waiting for a restart, if any.
    let updateReadyVersion: () -> String?
    /// Opens Settings at the update, where it installs.
    let openUpdates: () -> Void
}

// MARK: - Panel Root (4 Pages Unified with Sarto 4-Palette Theme)

struct MenuBarPanelRootView: View {
    @Bindable var appState: SartoState
    var islandModel: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var launch: PrismLaunchAtLogin
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    let actions: MenuBarPanelActions

    var body: some View {
        let width = panel.width
        ZStack(alignment: .topTrailing) {
            if router.page == .main {
                MenuBarMainPage(
                    appState: appState,
                    islandModel: islandModel,
                    store: usageStore,
                    settingsStore: settingsStore,
                    router: router,
                    panel: panel,
                    actions: actions
                )
                .frame(width: width)
                .transition(.asymmetric(
                    insertion: .offset(x: -width * 0.3).combined(with: .opacity),
                    removal: .offset(x: -width * 0.3).combined(with: .opacity)
                ))
            }
            if case .detail(let id) = router.page, let provider = usageStore.provider(id) {
                MenuBarDetailPage(
                    store: usageStore,
                    settingsStore: settingsStore,
                    provider: provider,
                    router: router,
                    panel: panel,
                    actions: actions,
                    l10n: appState.l10n
                )
                .frame(width: width)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if router.page == .usage {
                MenuBarUsagePage(
                    store: usageStore,
                    settingsStore: settingsStore,
                    router: router,
                    panel: panel
                )
                .frame(width: width)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .focusEffectDisabled()
        .environment(\.locale, appState.language.resolvedLocale)
        .environment(\.prismL10n, appState.l10n)
    }
}

// MARK: - 1. Main Page (Liquid Tubes + Model Ranking + 30d Card)

private struct MenuBarMainPage: View {
    @Bindable var appState: SartoState
    var islandModel: PrismIslandModel
    @ObservedObject var store: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    let actions: MenuBarPanelActions

    private static let tubesPerRow = 5

    private var hasUrgentSession: Bool {
        appState.sessions.contains {
            $0.archivedAt == nil && ($0.status == .awaitingPermission || $0.permissionCount > 0 || $0.status == .running || $0.status == .starting)
        }
    }

    var body: some View {
        PanelPage(onNaturalHeight: { panel.contentHeight = $0 }) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    SartoEmblem(size: 14, active: hasUrgentSession)
                    Text(SartoBrand.name)
                        .font(.system(size: 13, weight: .bold))
                    Circle()
                        .fill(appState.connectionMode.isLive ? Color.green : Palette.ink3.opacity(0.45))
                        .frame(width: 6, height: 6)
                        .help(appState.l10n.tr(appState.connectionMode.isLive ? "menuBar.daemonRunning" : "menuBar.daemonDisconnected"))
                }
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(updatedText(now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.ink3)
                        .lineLimit(1)
                        .padding(.leading, 8)
                }
                Spacer(minLength: 0)
                SpinningIconButton(systemName: "arrow.clockwise", label: appState.l10n.tr("menuBar.refresh"), spinToken: store.refreshToken) {
                    actions.refresh()
                }
            }
            .padding(EdgeInsets(top: 14, leading: 18, bottom: 4, trailing: 12))
        } content: {
            content
        } footer: {
            VStack(spacing: 8) {
                if let version = actions.updateReadyVersion() {
                    InkPillButton(
                        title: appState.l10n.tr("menuBar.update.ready", version),
                        fullWidth: true
                    ) {
                        actions.openUpdates()
                    }
                }
                HStack(spacing: 6) {
                    InkPillButton(
                        title: appState.l10n.tr("menuBar.openMainWindow"),
                        brandMark: true,
                        replayToken: panel.fillToken
                    ) {
                        actions.openMainWindow(nil)
                    }
                    Button {
                        actions.toggleIsland()
                    } label: {
                        Text(islandButtonTitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Palette.ink2)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Capsule().fill(Palette.tile))
                            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 0.5))
                    }
                    .buttonStyle(PressScaleStyle())
                    Spacer(minLength: 0)
                    IconButton(systemName: "gearshape", label: appState.l10n.tr("menuBar.settings"), help: appState.l10n.tr("menuBar.settingsHelp")) { actions.openSettings(.islandAndMenuBar) }
                    IconButton(systemName: "power", label: appState.l10n.tr("menuBar.quit"), help: appState.l10n.tr("menuBar.quitHelp")) { actions.quit() }
                }
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 10))
        }
    }

    private var islandButtonTitle: String {
        guard settingsStore.settings.islandEnabled else {
            return appState.l10n.tr("menuBar.island.show")
        }
        return appState.l10n.tr(islandModel.mode == .open ? "menuBar.island.collapse" : "menuBar.island.expand")
    }

    private func updatedText(now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(store.updatedAt))
        if seconds < 60 { return appState.l10n.tr("menuBar.updatedJustNow") }
        return appState.l10n.tr("menuBar.updatedMinutesAgo", Int(seconds / 60))
    }

    private var content: some View {
        let visible = settingsStore.visible(store.providers)
        // One tube per account: another account a Mac uses stands beside the tool's own. Only the
        // tools installed, used within 30 days and measured have one.
        let measured = visible.filter(\.eligible).flatMap { [$0] + $0.otherAccounts }.filter { $0.remaining != nil }
        let rows = stride(from: 0, to: measured.count, by: Self.tubesPerRow).map {
            Array(measured[$0..<min($0 + Self.tubesPerRow, measured.count)])
        }
        let privacy = settingsStore.settings.privacy

        return VStack(alignment: .leading, spacing: 0) {
            Headline(
                primary: !store.ready
                    ? appState.l10n.tr(store.connection == .offline ? "usage.daemonOffline" : "usage.loading")
                    : appState.l10n.tr("menuBar.todaySpent", prismFormattedMoney(store.todaySpend, privacy: privacy)),
                secondary: headlineSecondary,
                alert: store.lowestWindow.map { !settingsStore.settings.hidden.contains($0.provider.id) } ?? false,
                short: panel.short
            )
            .padding(EdgeInsets(top: panel.short ? 6 : 10, leading: 20, bottom: 0, trailing: 20))

            VStack(spacing: panel.short ? 8 : 12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { index, provider in
                            MenuBarProviderCell(
                                provider: provider,
                                index: rowIndex * Self.tubesPerRow + index,
                                fillToken: panel.fillToken,
                                privacy: privacy,
                                tubeHeight: panel.short ? 82 : 104
                            ) {
                                router.go(.detail(provider.id))
                            }
                        }
                        // A short last row keeps the tubes as wide as the full rows'.
                        if rows.count > 1 {
                            ForEach(0..<(Self.tubesPerRow - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, panel.short ? 10 : 14)
            .padding(.bottom, 4)

            MenuBarModelOverview(store: store, visibleIds: Set(visible.map(\.id)), privacy: privacy, router: router, panel: panel)
                .padding(.top, panel.short ? 12 : 16)

            MenuBarMonthCard(store: store, privacy: privacy, router: router, panel: panel)
                .padding(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
        }
        .frame(width: panel.width, alignment: .leading)
    }

    private var headlineSecondary: String {
        if !store.ready {
            return appState.l10n.tr(store.connection == .offline ? "usage.daemonOfflineHint" : "usage.loadingHint")
        }
        if store.connection == .offline { return appState.l10n.tr("usage.daemonOfflineStale") }
        if let low = store.lowestWindow, !settingsStore.settings.hidden.contains(low.provider.id) {
            let left = Int((low.remaining * 100).rounded())
            return low.provider.kind == .balance
                ? appState.l10n.tr("menuBar.lowBalance", low.provider.name, left)
                : appState.l10n.tr("menuBar.lowWindow", low.provider.name, low.label, left)
        }
        return appState.l10n.tr("menuBar.tokensRequests", Fmt.tokens(store.todayTokens), store.todayRequests)
    }
}

private struct MenuBarProviderCell: View {
    let provider: ProviderUsage
    let index: Int
    let fillToken: Int
    let privacy: Bool
    var tubeHeight: CGFloat
    let action: () -> Void
    @Environment(\.prismL10n) private var l10n
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    CountUpText(
                        text: "\(Int(((provider.remaining ?? 0) * 100).rounded()))",
                        font: NumFont.font(18),
                        replayToken: fillToken,
                        delay: Double(index) * 0.06
                    )
                    .lineLimit(1)
                    Text("%").font(NumFont.font(11)).foregroundStyle(Palette.ink3)
                }
                .monospacedDigit()
                .frame(height: 22, alignment: .bottom)

                TubeView(
                    fill: provider.remaining,
                    level: provider.level,
                    active: false,
                    hovered: hovering,
                    index: index,
                    fillToken: fillToken,
                    height: tubeHeight
                )

                VStack(spacing: 4) {
                    SVGMark(svg: provider.logo, size: 12)
                    Text(provider.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(1)
                }

                NumFont.adaptive(when, size: 12, weight: .medium, textSize: 10)
                    .foregroundStyle(Palette.level(provider.level) ?? Palette.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(height: 15)
                    .padding(.top, -4)
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .offset(y: hovering ? -3 : 0)
        }
        .buttonStyle(CellPressStyle())
        .onHover { value in
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.25)) { hovering = value }
        }
    }

    private var when: String {
        switch provider.kind {
        case .quota: return provider.windowReset ? l10n.tr("menuBar.reset") : UsageCountdown.shortCountdown(to: provider.resetsAt, l10n: l10n)
        case .balance: return prismFormattedMoney(provider.balance ?? 0, privacy: privacy)
        case .payg: return "—"
        }
    }
}

// MARK: - Model Overview & 30-Day Card

private struct MenuBarModelOverview: View {
    @ObservedObject var store: PrismUsageStore
    let visibleIds: Set<String>
    let privacy: Bool
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    @Environment(\.prismL10n) private var l10n

    var body: some View {
        let sorted = store.models.filter { visibleIds.contains($0.providerId) }.sorted { $0.money > $1.money }
        let total = max(0.0001, sorted.reduce(0) { $0 + $1.money })
        let limit = panel.short ? 2 : 3
        let rest = sorted.dropFirst(limit)
        VStack(alignment: .leading, spacing: 8) {
            Caption(title: l10n.tr("menuBar.todayModels"), detail: l10n.tr("menuBar.modelCount", sorted.count)) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Fmt.tokens(store.todayTokens)) tokens · ")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.ink3)
                        .monospacedDigit()
                    CountUpText(text: prismFormattedMoney(total, privacy: privacy), font: NumFont.font(19), replayToken: panel.fillToken)
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 20)

            VStack(spacing: 0) {
                ForEach(sorted.prefix(limit)) { model in
                    MenuBarModelRow(
                        model: model,
                        provider: store.provider(model.providerId),
                        share: model.money / total,
                        privacy: privacy,
                        fillToken: panel.fillToken
                    ) {
                        router.go(.usage)
                    }
                }
                if !rest.isEmpty {
                    MoreRow(label: l10n.tr("menuBar.otherModels", rest.count), value: prismFormattedMoney(rest.reduce(0) { $0 + $1.money }, privacy: privacy)) {
                        router.go(.usage)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct MenuBarModelRow: View {
    let model: ModelUsage
    let provider: ProviderUsage?
    let share: Double
    let privacy: Bool
    let fillToken: Int
    let action: () -> Void
    @Environment(\.prismL10n) private var l10n
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                PulsingIcon(running: false) {
                    SVGMark(svg: provider?.logo ?? "", size: 13)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(model.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .tracking(-0.1)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CountUpText(text: model.moneyText(privacy: privacy), font: NumFont.font(14), replayToken: fillToken, delay: 0.12)
                            .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(l10n.tr("menuBar.modelRowDetail", provider?.name ?? "", Fmt.tokens(model.tokens), model.requests))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.ink3)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Int((share * 100).rounded()))%")
                            .font(NumFont.font(11, .medium))
                            .foregroundStyle(Palette.ink3)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
            }
            .padding(EdgeInsets(top: 6, leading: 10, bottom: 8, trailing: 10))
            .background(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    let width = geometry.size.width - 48 - 10
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.ink5)
                        ShareFill(running: false).frame(width: max(4, width * share))
                    }
                    .frame(width: max(0, width), height: 2)
                    .offset(x: 48, y: geometry.size.height - 5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .circular).fill(hovering ? Palette.ink5 : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .circular))
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(.easeOut(duration: 0.15)) { hovering = value } }
    }
}

private struct MenuBarMonthCard: View {
    @ObservedObject var store: PrismUsageStore
    let privacy: Bool
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    @Environment(\.prismL10n) private var l10n
    @State private var hovering = false

    var body: some View {
        let last = Array(store.includedHistory.suffix(30))
        let total = last.reduce(0) { $0 + $1.money.reduce(0, +) }
        Button { router.go(.usage) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(l10n.tr("menuBar.last30Days")).font(.system(size: 10.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                    CountUpText(text: prismFormattedMoney(total, privacy: privacy), font: NumFont.font(22), replayToken: panel.fillToken, delay: 0.2)
                        .lineLimit(1)
                }
                .fixedSize()
                MenuBarUsageChart(days: last, providers: store.providers, compact: true, selection: .constant(nil))
                    .frame(height: 28)
                HStack(spacing: 4) {
                    Text(l10n.tr("menuBar.expand")).lineLimit(1)
                    Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .semibold))
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Palette.ink2)
                .fixedSize()
            }
            .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
            .background(RoundedRectangle(cornerRadius: 14, style: .circular).fill(Palette.tile))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .circular))
            .offset(y: hovering ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { value in withAnimation(Motion.quick) { hovering = value } }
    }
}

private struct MenuBarUsagePoint: Identifiable {
    let id: String
    let date: Date
    let series: String
    let value: Double
}

private struct MenuBarUsageChart: View {
    let days: [DayUsage]
    let providers: [ProviderUsage]
    let compact: Bool
    @Binding var selection: Int?

    var body: some View {
        let order = Array(providers.indices)
        let points = order.flatMap { p in
            days.enumerated().map { i, day in
                MenuBarUsagePoint(id: "\(p)-\(i)", date: day.date, series: providers[p].id, value: day.money[p])
            }
        }
        let totals = days.map { $0.money.reduce(0, +) }
        let maxTotal = max(totals.max() ?? 0, 0.0001) * 1.08
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Day", point.date), y: .value("Value", point.value), stacking: .standard)
                    .foregroundStyle(by: .value("Provider", point.series))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                LineMark(x: .value("Day", day.date), y: .value("Total", totals[i]), series: .value("Series", "total"))
                    .foregroundStyle(Palette.ink.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: compact ? 1 : 1.2))
                    .interpolationMethod(.monotone)
            }
            if let selection, selection < days.count {
                RuleMark(x: .value("Day", days[selection].date))
                    .foregroundStyle(Palette.ink3)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Day", days[selection].date), y: .value("Total", totals[selection]))
                    .symbol {
                        Circle().fill(Palette.ink).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: providers.map(\.id),
            range: providers.map { LinearGradient(colors: [$0.color.opacity(0.95), $0.color.opacity(0.55)], startPoint: .top, endPoint: .bottom) }
        )
        .chartLegend(.hidden)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...maxTotal)
        .chartPlotStyle { plot in plot.clipped(antialiased: true) }
        .chartOverlay { proxy in
            if !compact {
                GeometryReader { geometry in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = location.x - geometry[plotFrame].origin.x
                                guard let date: Date = proxy.value(atX: x) else { return }
                                let idx = days.indices.min { abs(days[$0].date.timeIntervalSince(date)) < abs(days[$1].date.timeIntervalSince(date)) } ?? 0
                                if selection != idx { selection = idx }
                            case .ended:
                                selection = nil
                            }
                        }
                }
            }
        }
        .accessibilityHidden(compact)
    }
}

// MARK: - 2. Detail Page (Segmented Rings + Hover Window Tiles + Fact Cards)

/// Removes the account a detail page shows from the usage views. The first click only arms it,
/// for a few seconds, so a stray click removes nothing.
private struct ForgetAccountButton: View {
    let l10n: PrismL10n
    let forget: () async throws -> Void
    @State private var confirming = false
    @State private var working = false
    @State private var failed = false
    @State private var hovering = false
    @State private var disarm: Task<Void, Never>?

    var body: some View {
        Button {
            if confirming { run() } else { arm() }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(confirming || failed ? Palette.error : (hovering ? Palette.ink2 : Palette.ink3))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(working)
        .help(l10n.tr("usage.forgetAccount.hint"))
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: confirming)
        .animation(Motion.quick, value: hovering)
        .onDisappear { disarm?.cancel() }
    }

    private var title: String {
        if failed { return l10n.tr("usage.forgetAccount.failed") }
        return l10n.tr(confirming ? "usage.forgetAccount.confirm" : "usage.forgetAccount")
    }

    private func arm() {
        failed = false
        confirming = true
        disarm?.cancel()
        disarm = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            confirming = false
        }
    }

    private func run() {
        disarm?.cancel()
        working = true
        Task { @MainActor in
            do {
                try await forget()
            } catch {
                failed = true
            }
            working = false
            confirming = false
        }
    }
}

private struct MenuBarDetailPage: View {
    @ObservedObject var store: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    let provider: ProviderUsage
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    let actions: MenuBarPanelActions
    let l10n: PrismL10n
    @State private var hoveredSegment: Int?

    private struct WindowSegment {
        let label: String
        let remaining: Double
        let color: Color
        let alertColor: Color?
        let resetsAt: Date?
        let reset: Bool
    }

    var body: some View {
        PanelPage(onNaturalHeight: { panel.contentHeight = $0 }) {
            HStack(spacing: 6) {
                IconButton(systemName: "chevron.left", label: l10n.tr("menuBar.back")) { router.go(.main) }
                SVGMark(svg: provider.logo, size: 13)
                Text(provider.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(provider.plan).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.ink3).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 14))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                let ring: CGFloat = panel.short ? 160 : 184
                ZStack {
                    RingsView(rings: rings, fillToken: panel.fillToken, size: ring, highlighted: hoveredSegment)
                    VStack(spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            CountUpText(
                                text: bigValue.0,
                                font: NumFont.font((bigValue.1 == nil ? 48 : 66) * ring / 184, .medium),
                                replayToken: panel.fillToken
                            )
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            if let unit = bigValue.1 {
                                Text(unit).font(NumFont.font(24 * ring / 184, .medium)).foregroundStyle(Palette.ink3)
                            }
                        }
                        .monospacedDigit()
                        .foregroundStyle(bigValueColor)
                        Text(bigCaption).font(.system(size: 11)).foregroundStyle(Palette.ink3).lineLimit(1)
                    }
                    .frame(maxWidth: ring - 44)
                    .animation(Motion.quick, value: hoveredSegment)
                }
                .frame(maxWidth: .infinity)

                if !segments.isEmpty {
                    windowTiles.padding(.top, 12)
                }

                (Text(say.0) + Text(say.1).foregroundColor(Palette.ink3))
                    .font(.system(size: 15.5, weight: .semibold))
                    .tracking(-0.3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 14, leading: 20, bottom: 0, trailing: 20))

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    if LiveUsageSources.loggedIds.contains(provider.id) {
                        FactCard(
                            label: l10n.tr("menuBar.detail.todaySpend"),
                            value: provider.spendText(privacy: settingsStore.settings.privacy),
                            sub: l10n.tr(provider.unpricedTokens > 0 && provider.todaySpend >= 0.005 ? "menuBar.detail.partlyUnpriced" : (provider.todaySpend >= 0.005 ? "menuBar.detail.apiPriced" : "menuBar.detail.unpriced"))
                        )
                        FactCard(label: l10n.tr("menuBar.detail.todayTokens"), value: Fmt.tokens(provider.todayTokens), sub: l10n.tr("menuBar.detail.calls", provider.requests))
                        FactCard(label: l10n.tr("menuBar.detail.topModel"), value: topModel, sub: l10n.tr("menuBar.today"))
                    }
                    if provider.kind == .quota {
                        FactCard(label: l10n.tr("menuBar.detail.quotaUpdated"), value: UsageAgo.text(provider.quotaObservedAt, l10n: l10n), sub: quotaSource)
                        if let amount = provider.allWindows.first(where: { $0.kind != .scoped })?.amount {
                            FactCard(
                                label: l10n.tr("menuBar.detail.usedThisPeriod"),
                                value: amountText(amount.used, unit: amount.unit),
                                sub: l10n.tr("menuBar.detail.ofTotal", amountText(amount.total, unit: amount.unit))
                            )
                        }
                    } else {
                        FactCard(label: l10n.tr("menuBar.detail.lastActivity"), value: UsageAgo.text(provider.lastActivity, l10n: l10n), sub: l10n.tr("menuBar.detail.localLogs"))
                    }
                }
                .padding(14)
            }
            .frame(width: panel.width, alignment: .leading)
        } footer: {
            VStack(spacing: 4) {
                if let folder = LiveUsageSources.folder(for: provider.id) {
                    InkPillButton(title: l10n.tr("menuBar.detail.showInFinder"), height: 32, fullWidth: true) {
                        NSWorkspace.shared.open(folder)
                        actions.close()
                    }
                }
                if let account = provider.quotaAccount {
                    ForgetAccountButton(l10n: l10n) {
                        try await store.forgetAccount(account)
                        router.go(.main)
                    }
                    .id(account.account)
                }
            }
            .padding(EdgeInsets(top: 0, leading: 14, bottom: provider.quotaAccount == nil ? 14 : 8, trailing: 14))
        }
        .onChange(of: provider.id) { _, _ in hoveredSegment = nil }
    }

    private func amountText(_ value: Double, unit: String) -> String {
        if unit == "USD" { return prismFormattedMoney(value, privacy: settingsStore.settings.privacy) }
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return "\(number) \(unit)"
    }

    private var segments: [WindowSegment] {
        guard provider.kind == .quota else { return [] }
        let palette = Self.segmentPalette(for: provider.id, fallback: provider.color)
        if !provider.allWindows.isEmpty {
            return provider.allWindows.enumerated().map { index, w in
                let alert = w.reset ? nil : levelColor(w.remaining)
                return WindowSegment(
                    label: w.label,
                    remaining: w.remaining,
                    color: alert ?? palette[index % palette.count],
                    alertColor: alert,
                    resetsAt: w.resetsAt,
                    reset: w.reset
                )
            }
        }
        var list: [WindowSegment] = []
        if let rem = provider.remaining {
            let alert = provider.windowReset ? nil : levelColor(rem)
            list.append(WindowSegment(label: provider.windowLabel, remaining: rem, color: alert ?? palette[0], alertColor: alert, resetsAt: provider.resetsAt, reset: provider.windowReset))
        }
        if let weekly = provider.weeklyRemaining {
            let alert = levelColor(weekly)
            list.append(WindowSegment(label: provider.weeklyLabel, remaining: weekly, color: alert ?? palette[1], alertColor: alert, resetsAt: nil, reset: false))
        }
        return list
    }

    private var focusedSegment: WindowSegment? {
        if let index = hoveredSegment, segments.indices.contains(index) { return segments[index] }
        let active = segments.filter { !$0.reset }
        return active.min { $0.remaining < $1.remaining } ?? segments.first
    }

    private var rings: [Ring] {
        switch provider.kind {
        case .quota: return segments.map { Ring(fraction: $0.remaining, color: $0.color) }
        case .balance: return [Ring(fraction: provider.remaining ?? 0, color: Palette.level(provider.level) ?? provider.color)]
        case .payg: return [Ring(fraction: 0, color: Palette.fill)]
        }
    }

    private var bigValue: (String, String?) {
        switch provider.kind {
        case .quota:
            if let seg = focusedSegment {
                return seg.reset ? (l10n.tr("menuBar.reset"), nil) : ("\(Int((seg.remaining * 100).rounded()))", "%")
            }
            return ("\(Int(((provider.remaining ?? 0) * 100).rounded()))", "%")
        case .balance: return (prismFormattedMoney(provider.balance ?? 0, privacy: settingsStore.settings.privacy), nil)
        case .payg: return (Fmt.tokens(provider.todayTokens), nil)
        }
    }

    private var bigValueColor: Color {
        if provider.kind == .quota { return focusedSegment?.alertColor ?? Palette.ink }
        return Palette.level(provider.level) ?? Palette.ink
    }

    private func levelColor(_ remaining: Double) -> Color? {
        remaining <= 0.1 ? Palette.error : (remaining <= store.lowThreshold ? Palette.warn : nil)
    }

    private var bigCaption: String {
        switch provider.kind {
        case .quota:
            if let seg = focusedSegment {
                if let index = hoveredSegment, segments.indices.contains(index), let resets = seg.resetsAt, !seg.reset {
                    return l10n.tr("menuBar.detail.resetsIn", seg.label, UsageCountdown.shortCountdown(to: resets, l10n: l10n))
                }
                return seg.reset ? seg.label : l10n.tr("menuBar.detail.left", seg.label)
            }
            return l10n.tr("menuBar.detail.left", provider.windowLabel)
        case .balance: return l10n.tr("menuBar.detail.apiBalance")
        case .payg: return l10n.tr("menuBar.detail.todayTokens")
        }
    }

    @ViewBuilder
    private var windowTiles: some View {
        if segments.count == 1, let seg = segments.first {
            if seg.reset || seg.resetsAt != nil {
                let text = seg.reset
                    ? l10n.tr("menuBar.detail.pastReset", seg.label)
                    : l10n.tr("menuBar.detail.resetsIn", seg.label, UsageCountdown.countdown(to: seg.resetsAt, l10n: l10n))
                HStack(spacing: 6) {
                    Circle().fill(seg.color).frame(width: 6, height: 6)
                    Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2).lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .circular).fill(Palette.tile))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .circular).strokeBorder(Palette.line, lineWidth: 0.5))
                .frame(maxWidth: .infinity)
            }
        } else if segments.count == 3 {
            HStack(spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    segmentTile(seg, index: index, stacked: true)
                }
            }
            .padding(.horizontal, 14)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    segmentTile(seg, index: index, stacked: false)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private func segmentTile(_ seg: WindowSegment, index: Int, stacked: Bool) -> some View {
        let hovered = hoveredSegment == index
        let pctText = seg.reset ? l10n.tr("menuBar.reset") : "\(Int((seg.remaining * 100).rounded()))%"
        let border: Color = hovered ? seg.color.opacity(0.65) : (seg.alertColor?.opacity(0.45) ?? Palette.line)
        return HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .circular)
                .fill(seg.color)
                .frame(width: 3, height: stacked ? 28 : 16)
            if stacked {
                VStack(alignment: .leading, spacing: 1) {
                    Text(seg.label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.82)
                    NumFont.adaptive(pctText, size: 18, weight: .semibold, textSize: 12, textWeight: .semibold)
                        .foregroundStyle(seg.alertColor ?? Palette.ink).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(seg.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink2).lineLimit(1).minimumScaleFactor(0.82).frame(maxWidth: .infinity, alignment: .leading)
                NumFont.adaptive(pctText, size: 17, weight: .semibold, textSize: 11.5, textWeight: .semibold)
                    .foregroundStyle(seg.alertColor ?? Palette.ink).lineLimit(1).fixedSize()
            }
        }
        .padding(EdgeInsets(top: stacked ? 7 : 8, leading: 8, bottom: stacked ? 7 : 8, trailing: 10))
        .background(RoundedRectangle(cornerRadius: 10, style: .circular).fill(hovered ? Palette.edge : Palette.tile))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .circular).strokeBorder(border, lineWidth: hovered || seg.alertColor != nil ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .circular))
        .onHover { isOver in
            withAnimation(Motion.quick) {
                if isOver { hoveredSegment = index } else if hoveredSegment == index { hoveredSegment = nil }
            }
        }
    }

    private static func segmentPalette(for providerId: String, fallback: Color) -> [Color] {
        switch providerId {
        case "claude":
            return [Palette.dynamicHex(0xD97757, 0xE5896B), Palette.dynamicHex(0x2E9B78, 0x48B894), Palette.dynamicHex(0x6D6AE8, 0x8B88FF), Palette.dynamicHex(0x0EA5B7, 0x2CC4D6)]
        case "antigravity":
            return [Palette.dynamicHex(0x2F7BF5, 0x5B9BFF), Palette.dynamicHex(0x7C5CFA, 0x9B80FF), Palette.dynamicHex(0x14A39A, 0x2EC4BA), Palette.dynamicHex(0xD97757, 0xE5896B)]
        case "codex":
            return [Palette.dynamicHex(0x5F82F5, 0x7A9DFF), Palette.dynamicHex(0x1CA48C, 0x38C4AA), Palette.dynamicHex(0x8063F5, 0x9E85FF), Palette.dynamicHex(0xD97757, 0xE5896B)]
        default:
            return [fallback, Palette.dynamicHex(0x1CA48C, 0x38C4AA), Palette.dynamicHex(0x7C5CFA, 0x9B80FF), Palette.dynamicHex(0xD97757, 0xE5896B)]
        }
    }

    private var say: (String, String) {
        switch provider.kind {
        case .quota:
            let low = store.lowestWindow.flatMap { $0.provider.id == provider.id ? $0 : nil }
            if provider.windowReset {
                let first = low.map { l10n.tr("menuBar.say.lowLeft", $0.label, Int(($0.remaining * 100).rounded())) }
                    ?? l10n.tr("menuBar.say.pastReset", provider.windowLabel)
                return (first, l10n.tr("menuBar.say.waitRefresh", provider.name))
            }
            let first = low.map { l10n.tr("menuBar.say.lowLeft", $0.label, Int(($0.remaining * 100).rounded())) }
                ?? l10n.tr("menuBar.say.plenty")
            return (first, provider.resetsAt.map {
                l10n.tr("menuBar.say.resetsIn", provider.windowLabel, UsageCountdown.countdown(to: $0, l10n: l10n))
            } ?? "")
        default:
            return (l10n.tr("menuBar.say.noLocalQuota", provider.name), l10n.tr("menuBar.say.fromLocalLogs"))
        }
    }

    private var quotaSource: String {
        if let device = provider.quotaDevice { return l10n.tr("menuBar.source.device", device) }
        switch provider.id {
        case "claude": return l10n.tr("menuBar.source.claude")
        case "codex": return l10n.tr("menuBar.source.codex")
        case "antigravity": return l10n.tr("menuBar.source.antigravity")
        default: return l10n.tr("menuBar.source.account", provider.name)
        }
    }

    private var topModel: String {
        store.models.filter { $0.providerId == provider.id }.max { ($0.money, $0.tokens) < ($1.money, $1.tokens) }?.name ?? "—"
    }
}

// MARK: - 3. Usage History Page (7 / 30 / 90 Days Stacked Chart)

private struct MenuBarUsagePage: View {
    @ObservedObject var store: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    @ObservedObject var router: MenuBarPanelRouter
    @ObservedObject var panel: MenuBarPanelState
    @Environment(\.prismL10n) private var l10n
    @State private var selection: Int?

    var body: some View {
        let days = Array(store.includedHistory.suffix(router.usageRange))
        let byProvider = store.providers.indices.map { p in days.reduce(0) { $0 + $1.money[p] } }
        let total = byProvider.reduce(0, +)
        let privacy = settingsStore.settings.privacy
        PanelPage(onNaturalHeight: { panel.contentHeight = $0 }) {
            HStack(spacing: 4) {
                IconButton(systemName: "chevron.left", label: l10n.tr("menuBar.back")) { router.go(.main) }
                Text(l10n.tr("menuBar.usage.title")).font(.system(size: 13, weight: .bold)).lineLimit(1)
                Spacer(minLength: 8)
                Picker("", selection: $router.usageRange) {
                    Text(l10n.tr("menuBar.usage.daysOption", 7)).tag(7)
                    Text(l10n.tr("menuBar.usage.daysOption", 30)).tag(30)
                    Text(l10n.tr("menuBar.usage.daysOption", 90)).tag(90)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 8, trailing: 14))
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                summary(days: days, total: total, privacy: privacy).padding(.horizontal, 18)
                MenuBarUsageChart(days: days, providers: store.providers, compact: false, selection: $selection)
                    .frame(height: panel.short ? 84 : 100)
                    .padding(EdgeInsets(top: 12, leading: 18, bottom: 0, trailing: 18))
                HStack {
                    if let first = days.first { Text(Fmt.monthDay(first.date, locale: l10n.resolvedCode)) }
                    Spacer(minLength: 0)
                    Text(l10n.tr("menuBar.today"))
                }
                .font(.system(size: 10))
                .foregroundStyle(Palette.ink3)
                .padding(EdgeInsets(top: 4, leading: 18, bottom: 0, trailing: 18))

                providerSplit(byProvider: byProvider, total: total, privacy: privacy)
                    .padding(EdgeInsets(top: 14, leading: 18, bottom: 0, trailing: 18))

                Text(l10n.tr("menuBar.usage.modelRanking", router.usageRange))
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(EdgeInsets(top: 16, leading: 18, bottom: 4, trailing: 18))

                VStack(spacing: 0) {
                    ForEach(store.rankedModels(days: router.usageRange).prefix(8)) { model in
                        HStack(spacing: 8) {
                            Circle().fill(store.provider(model.providerId)?.color ?? Palette.ink3).frame(width: 6, height: 6)
                            Text(model.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(Fmt.tokens(model.tokens))").foregroundStyle(Palette.ink3)
                            Text(model.moneyText(privacy: privacy)).fontWeight(.semibold).frame(minWidth: 52, alignment: .trailing)
                        }
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                    }
                }
                .padding(.horizontal, 10)

                Text(pricingNote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.ink3)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(EdgeInsets(top: 12, leading: 18, bottom: 16, trailing: 18))
            }
            .frame(width: panel.width, alignment: .leading)
        } footer: {
            EmptyView()
        }
        .onChange(of: router.usageRange) { _, _ in selection = nil }
    }

    private var pricingNote: String {
        var lines = [l10n.tr("menuBar.usage.pricingNote")]
        let separator = l10n.tr("common.listSeparator")
        let shown = Set(store.rankedModels(days: 90).map(\.name))
        let family = store.familyPriced.filter { shown.contains($0.0) }
        let unpriced = store.unpricedModels.filter { shown.contains($0) }
        if !family.isEmpty {
            let items = family.map { l10n.tr("menuBar.usage.familyItem", $0.0, $0.1) }.joined(separator: separator)
            lines.append(l10n.tr("menuBar.usage.familyPriced", items))
        }
        if !unpriced.isEmpty {
            lines.append(l10n.tr("menuBar.usage.unpricedList", unpriced.joined(separator: separator)))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func summary(days: [DayUsage], total: Double, privacy: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let selection, selection < days.count {
                let day = days[selection]
                bigNumber(prismFormattedMoney(day.money.reduce(0, +), privacy: privacy))
                caption(Fmt.monthDay(day.date, locale: l10n.resolvedCode) + " " + Fmt.weekday(day.date, locale: l10n.resolvedCode))
                caption(store.providers.indices.filter { day.money[$0] > 0.01 }
                    .sorted { day.money[$0] > day.money[$1] }
                    .prefix(3)
                    .map { "\(store.providers[$0].name) \(prismFormattedMoney(day.money[$0], privacy: privacy))" }
                    .joined(separator: " · "))
            } else {
                bigNumber(prismFormattedMoney(total, privacy: privacy))
                caption(l10n.tr("menuBar.usage.rangeCaption", router.usageRange))
                let tokens = days.reduce(0) { $0 + $1.tokens.reduce(0, +) }
                caption(l10n.tr("menuBar.usage.dailyAverage", prismFormattedMoney(total / Double(max(1, days.count)), privacy: privacy), Fmt.tokens(tokens)))
            }
        }
    }

    private func bigNumber(_ text: String) -> some View {
        Text(text)
            .font(NumFont.font(34))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(Motion.quick, value: text)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.ink3).monospacedDigit().lineLimit(1)
    }

    private func providerSplit(byProvider: [Double], total: Double, privacy: Bool) -> some View {
        let order = store.providers.indices.filter { !store.excluded.contains(store.providers[$0].id) }
            .sorted { byProvider[$0] > byProvider[$1] }
        return VStack(alignment: .leading, spacing: 8) {
            SegmentBar(values: order.map { (store.providers[$0].color, byProvider[$0]) }).frame(height: 4)
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                    GridItem(.flexible(), alignment: .leading),
                ],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(order, id: \.self) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Circle().fill(store.providers[p].color).frame(width: 6, height: 6)
                            Text(store.providers[p].name).lineLimit(1)
                            Text("\(Int((byProvider[p] / max(total, 0.0001) * 100).rounded()))%").foregroundStyle(Palette.ink3)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.ink2)
                        Text(prismFormattedMoney(byProvider[p], privacy: privacy)).font(NumFont.font(16)).padding(.leading, 11)
                    }
                    .monospacedDigit()
                }
            }
        }
    }
}
