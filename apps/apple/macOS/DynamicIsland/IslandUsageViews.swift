import MenuBarKit
import PrismDesign
import SwiftUI
import UsageCore

// MARK: - Active Provider & Model-to-Window Resolution (from llm-usage-island)

struct IslandCompactWindowMeter {
    let tag: String
    let fullLabel: String
    let remaining: Double
    let color: Color
    let resetsAt: Date?
    let reset: Bool
    let forecast: WindowForecast?
}

struct IslandCompactFocus {
    let provider: ProviderUsage
    let identity: String
    let brandColor: Color
    let isLocalActive: Bool
    let source: UsageFocusPick.Source
    let meters: [IslandCompactWindowMeter]

    var lowestRemaining: Double? {
        let active = meters.filter { !$0.reset }
        return active.map(\.remaining).min() ?? meters.first?.remaining
    }

    var bottleneck: IslandCompactWindowMeter? {
        let exhausting = meters.compactMap { m -> (IslandCompactWindowMeter, TimeInterval)? in
            if case .exhausts(let secs)? = m.forecast?.status { return (m, secs) }
            return nil
        }
        if let soonest = exhausting.min(by: { $0.1 < $1.1 }) { return soonest.0 }
        let active = meters.filter { !$0.reset }
        return active.min { $0.remaining < $1.remaining } ?? meters.first
    }
}

enum IslandUsageFocusResolver {
    @MainActor
    static func resolve(
        store: PrismUsageStore,
        settingsStore: UsageSettingsStore,
        appFocus: AppUsageFocusContext? = nil,
        providerId: String? = nil,
        strings: IslandStrings,
        now: Date = Date()
    ) -> IslandCompactFocus? {
        let allVisible = settingsStore.visible(store.providers).filter(\.eligible)
        guard !allVisible.isEmpty else { return nil }

        let infos = allVisible.map(providerInfo(from:))
        guard let pick = UsageFocusPicker.pick(
            visibleProviders: infos,
            appContext: appFocus,
            pinnedProviderId: providerId,
            now: now
        ),
            let chosen = allVisible.first(where: { $0.id == pick.providerId })
        else {
            return nil
        }

        let hints = resolvedHints(pick.modelHints, provider: chosen, store: store)
        return buildFocus(
            provider: chosen,
            modelHints: hints,
            lowThreshold: store.lowThreshold,
            isLocalActive: pick.isLocalActive,
            source: pick.source,
            strings: strings
        )
    }

    @MainActor
    static func resolve(
        provider: ProviderUsage,
        store: PrismUsageStore,
        appFocus: AppUsageFocusContext? = nil,
        isLocalActive: Bool,
        strings: IslandStrings,
        now: Date = Date()
    ) -> IslandCompactFocus {
        let pickedHints = UsageFocusPicker.modelHints(
            for: providerInfo(from: provider),
            appContext: appFocus,
            now: now
        )
        let hints = resolvedHints(pickedHints, provider: provider, store: store)
        return buildFocus(
            provider: provider,
            modelHints: hints,
            lowThreshold: store.lowThreshold,
            isLocalActive: isLocalActive,
            source: isLocalActive ? .localFile : .fallback,
            strings: strings
        )
    }

    private static func providerInfo(from provider: ProviderUsage) -> UsageFocusProviderInfo {
        UsageFocusProviderInfo(
            id: provider.id,
            hasQuota: provider.kind == .quota,
            localLastActivity: provider.localLastActivity,
            lastActivity: provider.lastActivity,
            localLastModel: provider.localLastModel,
            lastModel: provider.lastModel
        )
    }

    @MainActor
    private static func resolvedHints(
        _ primary: [String],
        provider: ProviderUsage,
        store: PrismUsageStore
    ) -> [String] {
        let cleaned = primary.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !cleaned.isEmpty { return cleaned }
        if let top = store.models
            .filter({ $0.providerId == provider.id })
            .max(by: { ($0.money, $0.tokens) < ($1.money, $1.tokens) })?.name,
            !top.isEmpty
        {
            return [top]
        }
        return []
    }

    static func buildFocus(
        provider: ProviderUsage,
        model: String,
        lowThreshold: Double,
        isLocalActive: Bool = true,
        source: UsageFocusPick.Source = .localFile,
        strings: IslandStrings
    ) -> IslandCompactFocus {
        buildFocus(
            provider: provider,
            modelHints: model.isEmpty ? [] : [model],
            lowThreshold: lowThreshold,
            isLocalActive: isLocalActive,
            source: source,
            strings: strings
        )
    }

    static func buildFocus(
        provider: ProviderUsage,
        modelHints: [String],
        lowThreshold: Double,
        isLocalActive: Bool = true,
        source: UsageFocusPick.Source = .localFile,
        strings: IslandStrings
    ) -> IslandCompactFocus {
        let hints = modelHints.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        func alertColor(_ rem: Double, reset: Bool) -> Color? {
            guard !reset else { return nil }
            if rem <= 0.10 { return IslandTheme.danger }
            if rem <= lowThreshold { return IslandTheme.warning }
            return nil
        }
        func makeMeter(tag: String, label: String? = nil, window: QuotaWindow, color: Color) -> IslandCompactWindowMeter {
            IslandCompactWindowMeter(
                tag: tag,
                fullLabel: label ?? window.label,
                remaining: window.remaining,
                color: alertColor(window.remaining, reset: window.reset) ?? color,
                resetsAt: window.resetsAt,
                reset: window.reset,
                forecast: window.forecast
            )
        }

        let windows = provider.allWindows
        if windows.isEmpty {
            var meters: [IslandCompactWindowMeter] = []
            if let rem = provider.remaining {
                let c = alertColor(rem, reset: provider.windowReset) ?? darkBrandColor(provider.id, fallback: provider.color)
                meters.append(IslandCompactWindowMeter(
                    tag: provider.weeklyRemaining == nil ? "7d" : "5h",
                    fullLabel: provider.windowLabel,
                    remaining: rem,
                    color: c,
                    resetsAt: provider.resetsAt,
                    reset: provider.windowReset,
                    forecast: nil
                ))
            }
            if let weekly = provider.weeklyRemaining {
                let c = alertColor(weekly, reset: false) ?? secondaryDarkColor(provider.id)
                let wLabel = provider.weeklyLabel.isEmpty ? strings.text("usage.window.thisWeek") : provider.weeklyLabel
                meters.append(IslandCompactWindowMeter(
                    tag: "7d",
                    fullLabel: wLabel,
                    remaining: weekly,
                    color: c,
                    resetsAt: nil,
                    reset: false,
                    forecast: nil
                ))
            }
            return IslandCompactFocus(
                provider: provider,
                identity: shortProviderName(provider),
                brandColor: darkBrandColor(provider.id, fallback: provider.color),
                isLocalActive: isLocalActive,
                source: source,
                meters: meters
            )
        }

        let session = windows.first { $0.kind == .session }
        let weekly = windows.first { $0.kind == .weekly }
        let scoped = windows.filter { $0.kind == .scoped }

        switch provider.id {
        case "claude":
            if let matched = scoped.first(where: { win in
                hints.contains { UsageModelScope.claudeModel($0, matches: win.scope ?? "") }
            }) {
                let scopeName = matched.scope ?? matched.label
                var meters: [IslandCompactWindowMeter] = []
                if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: Color(hex: 0xE5896B))) }
                meters.append(makeMeter(tag: strings.text("usage.tag.week"), label: strings.text("usage.window.scopedWeek", ["scope": scopeName]), window: matched, color: Color(hex: 0x8B88FF)))
                return IslandCompactFocus(
                    provider: provider,
                    identity: scopeName,
                    brandColor: Color(hex: 0xE5896B),
                    isLocalActive: isLocalActive,
                    source: source,
                    meters: meters
                )
            }
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: Color(hex: 0xE5896B))) }
            if let weekly { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.thisWeek"), window: weekly, color: Color(hex: 0x48B894))) }
            return IslandCompactFocus(
                provider: provider,
                identity: "Claude",
                brandColor: Color(hex: 0xE5896B),
                isLocalActive: isLocalActive,
                source: source,
                meters: meters
            )

        case "antigravity":
            let isThirdParty = hints.contains { UsageModelScope.isAntigravityThirdParty($0) }
            let isArgon = hints.contains { $0.lowercased().contains("argon") }
            // Besides Gemini's own allowance, agy names a shared Claude/GPT group and an Argon one.
            let argonPool = scoped.filter { ($0.scope ?? $0.label).lowercased().contains("argon") }
            if isThirdParty {
                let pool = scoped.filter { !argonPool.contains($0) }
                let w5 = pool.first { $0.isFiveHour }
                let w7 = pool.first { !$0.isFiveHour }
                var meters: [IslandCompactWindowMeter] = []
                if let w5 { meters.append(makeMeter(tag: "5h", label: "C/G 5h", window: w5, color: Color(hex: 0x2EC4BA))) }
                if let w7 { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.groupWeek", ["group": "C/G"]), window: w7, color: Color(hex: 0xE5896B))) }
                if !meters.isEmpty {
                    return IslandCompactFocus(
                        provider: provider,
                        identity: "C/G",
                        brandColor: Color(hex: 0x2EC4BA),
                        isLocalActive: isLocalActive,
                        source: source,
                        meters: meters
                    )
                }
            } else if isArgon {
                let pool = argonPool
                if !pool.isEmpty {
                    let meters = pool.prefix(2).enumerated().map { idx, w in
                        makeMeter(
                            tag: w.isFiveHour ? "5h" : "7d",
                            label: w.isFiveHour ? "Argon 5h" : strings.text("usage.window.groupWeek", ["group": "Argon"]),
                            window: w,
                            color: idx == 0 ? Color(hex: 0x5B9BFF) : Color(hex: 0x9B80FF)
                        )
                    }
                    return IslandCompactFocus(
                        provider: provider,
                        identity: "Argon",
                        brandColor: Color(hex: 0x5B9BFF),
                        isLocalActive: isLocalActive,
                        source: source,
                        meters: meters
                    )
                }
            }
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: Color(hex: 0x5B9BFF))) }
            if let weekly { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.thisWeek"), window: weekly, color: Color(hex: 0x9B80FF))) }
            return IslandCompactFocus(
                provider: provider,
                identity: "Gemini",
                brandColor: Color(hex: 0x5B9BFF),
                isLocalActive: isLocalActive,
                source: source,
                meters: meters
            )

        default:
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: Color(hex: 0x7A9DFF))) }
            if let weekly {
                let c = session == nil ? Color(hex: 0x7A9DFF) : Color(hex: 0x38C4AA)
                meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.thisWeek"), window: weekly, color: c))
            }
            if meters.isEmpty, let first = windows.first {
                meters.append(makeMeter(tag: "7d", window: first, color: darkBrandColor(provider.id, fallback: provider.color)))
            }
            return IslandCompactFocus(
                provider: provider,
                identity: shortProviderName(provider),
                brandColor: darkBrandColor(provider.id, fallback: provider.color),
                isLocalActive: isLocalActive,
                source: source,
                meters: meters
            )
        }
    }

    private static func shortProviderName(_ provider: ProviderUsage) -> String {
        switch provider.id {
        case "claude": return "Claude"
        case "antigravity": return "Gemini"
        default: return provider.name
        }
    }

    private static func darkBrandColor(_ id: String, fallback: Color) -> Color {
        switch id {
        case "claude": return Color(hex: 0xE5896B)
        case "antigravity": return Color(hex: 0x5B9BFF)
        case "codex": return Color(hex: 0x7A9DFF)
        default: return fallback
        }
    }

    private static func secondaryDarkColor(_ id: String) -> Color {
        switch id {
        case "claude": return Color(hex: 0x48B894)
        case "antigravity": return Color(hex: 0x9B80FF)
        default: return Color(hex: 0x38C4AA)
        }
    }
}

// MARK: - Compact Usage Strip (Shown when Sessions are Calm/Idle)

struct IslandCompactUsageStrip: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var geometry: IslandGeometry? = nil
    var screenID: UInt32? = nil

    private var l10n: PrismL10n { PrismL10n(language: model.strings.isChinese ? .zhHans : .en) }

    var body: some View {
        let g = geometry ?? model.geometry
        let focus = usageStore.ready
            ? IslandUsageFocusResolver.resolve(
                store: usageStore,
                settingsStore: settingsStore,
                appFocus: model.appUsageFocus,
                strings: model.strings
            )
            : nil

        Group {
            if g.hasNotch {
                let wing = model.collapsedWingWidth(for: g)
                HStack(spacing: 0) {
                    leadingIdentity(focus: focus, hasNotch: true)
                        .padding(.leading, 12)
                        .padding(.trailing, 4)
                        .frame(width: wing, alignment: .leading)

                    Color.clear
                        .frame(width: g.notchWidth)

                    trailingMeters(focus: focus, hasNotch: true)
                        .padding(.leading, 4)
                        .padding(.trailing, 12)
                        .frame(width: wing, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    leadingIdentity(focus: focus, hasNotch: false)
                        .fixedSize()
                        .padding(.leading, 13)

                    Spacer(minLength: 10)

                    trailingMeters(focus: focus, hasNotch: false)
                        .fixedSize()
                        .padding(.trailing, 13)
                }
            }
        }
        .frame(height: g.notchHeight)
        .contentShape(Rectangle())
        .onTapGesture { model.expand(by: .click, onScreen: screenID) }
    }

    @ViewBuilder
    private func leadingIdentity(focus: IslandCompactFocus?, hasNotch: Bool) -> some View {
        let size: CGFloat = hasNotch ? 10.5 : 11.5
        if !usageStore.ready {
            HStack(spacing: 6) {
                SartoEmblem(size: 15, active: false)
                Text(usageStore.connection == .offline ? l10n.tr("usage.daemonOfflineShort") : model.strings.text("usage.loadingShort"))
                    .font(IslandFonts.ui(size, .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        } else if let focus {
            HStack(spacing: 6) {
                SVGMark(svg: focus.provider.logo, size: hasNotch ? 11 : 12, color: focus.brandColor)
                Text(focus.identity)
                    .font(IslandFonts.ui(size, .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 6) {
                SartoEmblem(size: 15, active: false)
                Text(SartoBrand.name)
                    .font(IslandFonts.ui(size, .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
        }
    }

    @ViewBuilder
    private func trailingMeters(focus: IslandCompactFocus?, hasNotch: Bool) -> some View {
        if !usageStore.ready {
            EmptyView()
        } else if let focus, !focus.meters.isEmpty {
            if hasNotch {
                notchMeters(focus)
            } else {
                wideMeters(focus)
            }
        } else {
            Text(Fmt.tokens(usageStore.todayTokens))
                .font(IslandFonts.mono(10.5, .semibold))
                .foregroundStyle(Color.white.opacity(0.82))
        }
    }

    @ViewBuilder
    private func notchMeters(_ focus: IslandCompactFocus) -> some View {
        let meters = Array(focus.meters.prefix(2))
        let lowest = focus.lowestRemaining
        let allReset = meters.allSatisfy(\.reset)
        let valText = allReset ? model.strings.text("usage.resetTag") : "\(Int(((lowest ?? 0) * 100).rounded()))%"
        HStack(spacing: 6) {
            VStack(spacing: 3) {
                ForEach(Array(meters.enumerated()), id: \.offset) { _, m in
                    IslandMicroBar(fraction: m.reset ? 0 : m.remaining, color: m.color, height: meters.count == 1 ? 3.8 : 3.2)
                        .frame(width: 34)
                }
            }
            Text(valText)
                .font(IslandFonts.mono(10.5, .semibold))
                .foregroundStyle(percentColor(lowest, reset: allReset))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func wideMeters(_ focus: IslandCompactFocus) -> some View {
        let meters = Array(focus.meters.prefix(2))
        HStack(spacing: 9) {
            ForEach(Array(meters.enumerated()), id: \.offset) { _, m in
                HStack(spacing: 4) {
                    Text(m.tag)
                        .font(IslandFonts.ui(9.5, .medium))
                        .foregroundStyle(Color.white.opacity(0.46))
                    IslandMicroBar(fraction: m.reset ? 0 : m.remaining, color: m.color, height: meters.count == 1 ? 4.0 : 3.5)
                        .frame(width: meters.count == 1 ? 56 : 32)
                    Text(m.reset ? model.strings.text("usage.resetTag") : "\(Int((m.remaining * 100).rounded()))%")
                        .font(IslandFonts.mono(10.5, .semibold))
                        .foregroundStyle(percentColor(m.remaining, reset: m.reset))
                        .lineLimit(1)
                }
            }
        }
    }

    private func percentColor(_ remaining: Double?, reset: Bool) -> Color {
        guard !reset, let rem = remaining else { return Color.white.opacity(0.55) }
        if rem <= 0.10 { return IslandTheme.danger }
        if rem <= usageStore.lowThreshold { return IslandTheme.warning }
        return Color.white.opacity(0.92)
    }
}

struct IslandMicroBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 3.5

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                if clamped > 0.005 {
                    Capsule()
                        .fill(color)
                        .frame(width: max(height, geo.size.width * clamped))
                        .animation(Motion.fill, value: clamped)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Expanded Usage Tab (24h Bars + Active Forecast Card + Clickable Peer Rows)

struct IslandExpandedUsageTab: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    @State private var pinnedProviderId: String?

    var body: some View {
        let visible = settingsStore.visible(usageStore.providers).filter(\.eligible)
        let activeFocus = IslandUsageFocusResolver.resolve(
            store: usageStore,
            settingsStore: settingsStore,
            appFocus: model.appUsageFocus,
            providerId: pinnedProviderId,
            strings: model.strings
        )
        let peers = visible.filter { $0.id != activeFocus?.provider.id }

        VStack(alignment: .leading, spacing: 6) {
            summaryCard

            if let focus = activeFocus {
                IslandActiveForecastCard(
                    focus: focus,
                    lowThreshold: usageStore.lowThreshold,
                    isAutoActive: pinnedProviderId == nil,
                    strings: model.strings
                ) {
                    model.openMenuBarPanel(page: .detail(focus.provider.id))
                }
            }

            ForEach(peers) { provider in
                let peerFocus = IslandUsageFocusResolver.resolve(
                    provider: provider,
                    store: usageStore,
                    appFocus: model.appUsageFocus,
                    isLocalActive: false,
                    strings: model.strings
                )
                IslandPeerForecastRow(
                    focus: peerFocus,
                    lowThreshold: usageStore.lowThreshold,
                    strings: model.strings
                ) {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        pinnedProviderId = provider.id
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear { usageStore.setShown(true) }
        .onDisappear {
            pinnedProviderId = nil
            usageStore.setShown(false)
        }
    }

    /// Today's tokens and requests, or why there are none yet.
    private var summaryDetail: String {
        let l10n = PrismL10n(language: model.strings.isChinese ? .zhHans : .en)
        if !usageStore.ready {
            return usageStore.connection == .offline ? l10n.tr("usage.daemonOffline") : l10n.tr("usage.loading")
        }
        let today = model.strings.text(
            "usage.todayRequests",
            ["tokens": Fmt.tokens(usageStore.todayTokens), "count": "\(usageStore.todayRequests)"]
        )
        return usageStore.connection == .offline ? l10n.tr("usage.daemonOfflineStale") : today
    }

    private var summaryCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.strings.text("usage.todayTitle"))
                    .font(IslandFonts.mono(10, .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
                Text(settingsStore.settings.privacy ? "\(Fmt.symbol)••••" : Fmt.money(usageStore.todaySpend))
                    .font(NumFont.font(28))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.95))
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.25), value: usageStore.todaySpend)
                Text(summaryDetail)
                    .font(IslandFonts.ui(10.5))
                    .foregroundStyle(Color.white.opacity(0.50))
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            IslandHourlyBars(values: usageStore.hourly, highlight: model.prismTokens.primary)
                .frame(width: 146, height: 38)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.75)
                )
        )
    }
}

private struct IslandHourlyBars: View {
    let values: [Double]
    let highlight: Color

    var body: some View {
        let maxValue = max(values.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let last = index == values.count - 1
                Capsule()
                    .fill(last ? highlight : Color.white.opacity(0.28))
                    .frame(height: max(2, CGFloat(value / maxValue) * 38))
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.3), value: values.last ?? 0)
    }
}

private enum IslandForecastFmt {
    static let green = Color(hex: 0x34D399)

    static func duration(_ seconds: TimeInterval, strings: IslandStrings) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        if mins >= 1440 {
            let days = mins / 1440
            let hrs = (mins % 1440) / 60
            return hrs > 0
                ? strings.text("usage.durDaysHours", ["d": "\(days)", "h": "\(hrs)"])
                : strings.text("usage.durDays", ["d": "\(days)"])
        }
        if mins >= 60 {
            let hrs = mins / 60
            let rem = mins % 60
            return rem > 0 ? "\(hrs)h \(rem)m" : "\(hrs)h"
        }
        return strings.text("usage.durMins", ["m": "\(mins)"])
    }

    static func quotaSummary(_ meter: IslandCompactWindowMeter?, lowThreshold: Double, strings: IslandStrings) -> (text: String, color: Color, urgent: Bool) {
        guard let meter else { return (strings.text("usage.collecting"), Color.white.opacity(0.45), false) }
        guard let forecast = meter.forecast else {
            if meter.reset { return (strings.text("usage.resetPending"), Color.white.opacity(0.55), false) }
            if meter.remaining <= 0.10 { return (strings.text("usage.lowCritical"), IslandTheme.danger, true) }
            if meter.remaining <= lowThreshold { return (strings.text("usage.lowWarn"), IslandTheme.warning, true) }
            return (strings.text("usage.collecting"), Color.white.opacity(0.45), false)
        }
        switch forecast.status {
        case .exhausts(let seconds):
            let critical = seconds < 2 * 3600 || meter.remaining <= 0.10
            let text = seconds < 60
                ? strings.text("usage.almostEmpty")
                : strings.text("usage.exhaustsIn", ["time": duration(seconds, strings: strings)])
            return (text, critical ? IslandTheme.danger : IslandTheme.warning, true)
        case .survives(let remAtReset):
            let pct = Int((remAtReset * 100).rounded())
            if meter.remaining <= 0.10 {
                return (strings.text("usage.criticalRemain", ["pct": "\(pct)"]), IslandTheme.danger, true)
            }
            return (strings.text("usage.survivesRemain", ["pct": "\(pct)"]), green, false)
        case .steady:
            return (strings.text("usage.survives"), green, false)
        case .reset:
            return (strings.text("usage.resetPending"), Color.white.opacity(0.55), false)
        case .insufficient:
            return (strings.text("usage.collecting"), Color.white.opacity(0.45), false)
        }
    }

    static func shortPeerQuota(_ meter: IslandCompactWindowMeter?, lowThreshold: Double, strings: IslandStrings) -> (text: String, color: Color, urgent: Bool) {
        guard let meter else { return (strings.text("usage.noQuota"), Color.white.opacity(0.42), false) }
        let label = (meter.tag == strings.text("usage.tag.week") || meter.fullLabel.hasPrefix("C/G") || meter.fullLabel.hasPrefix("Argon")) ? meter.fullLabel : meter.tag
        if meter.reset { return (strings.text("usage.peerReset", ["label": label]), Color.white.opacity(0.55), false) }
        let pct = "\(Int((meter.remaining * 100).rounded()))%"
        let prefix = "\(label) \(pct)"
        if let forecast = meter.forecast {
            switch forecast.status {
            case .exhausts(let seconds):
                let critical = seconds < 2 * 3600 || meter.remaining <= 0.10
                let text = seconds < 60
                    ? strings.text("usage.peerAlmostEmpty", ["prefix": prefix])
                    : strings.text("usage.peerExhausts", ["prefix": prefix, "time": duration(seconds, strings: strings)])
                return (text, critical ? IslandTheme.danger : IslandTheme.warning, true)
            case .survives, .steady:
                let urgent = meter.remaining <= lowThreshold
                let c: Color = meter.remaining <= 0.10 ? IslandTheme.danger : (urgent ? IslandTheme.warning : Color.white.opacity(0.65))
                return (strings.text("usage.peerSurvives", ["prefix": prefix]), c, urgent)
            case .reset:
                return (strings.text("usage.peerReset", ["label": label]), Color.white.opacity(0.55), false)
            case .insufficient:
                break
            }
        }
        let urgent = meter.remaining <= lowThreshold
        let c: Color = meter.remaining <= 0.10 ? IslandTheme.danger : (urgent ? IslandTheme.warning : Color.white.opacity(0.65))
        return (prefix, c, urgent)
    }

    static func remainingTokens(_ meter: IslandCompactWindowMeter?, strings: IslandStrings) -> (text: String, muted: Bool) {
        guard let est = meter?.forecast?.estimatedRemainingTokens else {
            return (strings.text("usage.collecting"), true)
        }
        return ("≈\(Fmt.tokens(est)) tokens", false)
    }
}

private struct IslandActiveForecastCard: View {
    let focus: IslandCompactFocus
    let lowThreshold: Double
    let isAutoActive: Bool
    let strings: IslandStrings
    let openDetail: () -> Void
    @State private var hoveringHeader = false

    var body: some View {
        let bottleneck = focus.bottleneck
        let qSummary = IslandForecastFmt.quotaSummary(bottleneck, lowThreshold: lowThreshold, strings: strings)
        let tokEst = IslandForecastFmt.remainingTokens(bottleneck, strings: strings)
        let borderColor: Color = qSummary.urgent ? qSummary.color.opacity(0.38) : focus.brandColor.opacity(0.30)
        let badgeLabel: String = {
            if isAutoActive && (focus.source == .appWorkbench || focus.source == .appSession) {
                return "● \(strings.text("usage.badgeCurrent")) · \(focus.identity)"
            }
            if focus.isLocalActive {
                return "● \(strings.text("usage.badgeLocal")) · \(focus.identity)"
            }
            return isAutoActive ? "● \(strings.text("usage.badgeActive")) · \(focus.identity)" : focus.identity
        }()

        VStack(alignment: .leading, spacing: 9) {
            Button(action: openDetail) {
                HStack(spacing: 6) {
                    SVGMark(svg: focus.provider.logo, size: 12, color: focus.brandColor)
                    Text(focus.provider.name)
                        .font(IslandFonts.ui(12.5, .semibold))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)
                    Text(badgeLabel)
                        .font(IslandFonts.ui(9.5, .semibold))
                        .foregroundStyle(focus.brandColor)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(focus.brandColor.opacity(0.20)))
                    Spacer(minLength: 6)
                    Text(strings.text("usage.todayTokens", ["tokens": Fmt.tokens(focus.provider.todayTokens)]))
                        .font(IslandFonts.mono(10.5, .medium))
                        .foregroundStyle(Color.white.opacity(hoveringHeader ? 0.88 : 0.55))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(hoveringHeader ? 0.72 : 0.28))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringHeader = $0 }

            if !focus.meters.isEmpty {
                HStack(spacing: 12) {
                    ForEach(Array(focus.meters.prefix(2).enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(m.fullLabel)
                                    .font(IslandFonts.ui(10, .medium))
                                    .foregroundStyle(Color.white.opacity(0.58))
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if let resetsAt = m.resetsAt, !m.reset {
                                    Text(UsageCountdown.shortCountdown(to: resetsAt, l10n: PrismL10n(language: strings.isChinese ? .zhHans : .en)))
                                        .font(IslandFonts.ui(9))
                                        .foregroundStyle(Color.white.opacity(0.32))
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                Text(m.reset ? strings.text("usage.resetTag") : "\(Int((m.remaining * 100).rounded()))%")
                                    .font(IslandFonts.mono(11, .semibold))
                                    .foregroundStyle(m.reset ? Color.white.opacity(0.5) : (m.remaining <= 0.10 ? IslandTheme.danger : (m.remaining <= lowThreshold ? IslandTheme.warning : Color.white.opacity(0.92))))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            IslandMicroBar(fraction: m.reset ? 0 : m.remaining, color: m.color, height: 3.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text(focus.provider.note ?? strings.text("usage.noQuotaFallback"))
                    .font(IslandFonts.ui(10.5))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.text("usage.forecastTitle"))
                        .font(IslandFonts.ui(9, .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text(qSummary.text)
                        .font(IslandFonts.mono(11, .semibold))
                        .foregroundStyle(qSummary.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(qSummary.urgent ? qSummary.color.opacity(0.12) : Color.white.opacity(0.045))
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.text("usage.estRemainingTitle"))
                        .font(IslandFonts.ui(9, .medium))
                        .foregroundStyle(Color.white.opacity(0.42))
                    Text(tokEst.text)
                        .font(IslandFonts.mono(11, .semibold))
                        .foregroundStyle(tokEst.muted ? Color.white.opacity(0.45) : Color.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.045))
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(borderColor, lineWidth: 0.9))
        )
    }
}

private struct IslandPeerForecastRow: View {
    let focus: IslandCompactFocus
    let lowThreshold: Double
    let strings: IslandStrings
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        let summary = IslandForecastFmt.shortPeerQuota(focus.bottleneck, lowThreshold: lowThreshold, strings: strings)
        let strokeColor: Color = summary.urgent ? summary.color.opacity(0.32) : (hovered ? Color.white.opacity(0.12) : .clear)
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SVGMark(svg: focus.provider.logo, size: 11, color: focus.brandColor)
                Text(focus.provider.name)
                    .font(IslandFonts.ui(11.5, .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                Text("\(Fmt.tokens(focus.provider.todayTokens)) tok")
                    .font(IslandFonts.mono(10))
                    .foregroundStyle(Color.white.opacity(0.40))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(summary.text)
                    .font(IslandFonts.mono(10.5, .medium))
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(hovered ? 0.075 : 0.035))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(strokeColor, lineWidth: 0.9))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}
