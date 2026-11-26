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
    /// Quota alerts and brand marks look the same in every palette family.
    private static let island = PrismIslandTokens.standard

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
            return island.quotaAlert(remaining: rem, low: lowThreshold)
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
                if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: PrismProviderBrand.claude.dark)) }
                meters.append(makeMeter(tag: strings.text("usage.tag.week"), label: strings.text("usage.window.scopedWeek", ["scope": scopeName]), window: matched, color: PrismProviderBrand.claudeModelWeekly.dark))
                return IslandCompactFocus(
                    provider: provider,
                    identity: scopeName,
                    brandColor: PrismProviderBrand.claude.dark,
                    isLocalActive: isLocalActive,
                    source: source,
                    meters: meters
                )
            }
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: PrismProviderBrand.claude.dark)) }
            if let weekly { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.thisWeek"), window: weekly, color: PrismProviderBrand.claudeWeekly.dark)) }
            return IslandCompactFocus(
                provider: provider,
                identity: "Claude",
                brandColor: PrismProviderBrand.claude.dark,
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
                if let w5 { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.groupFiveHour", ["group": "C/G"]), window: w5, color: PrismProviderBrand.geminiPartnerPool.dark)) }
                if let w7 { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.groupWeek", ["group": "C/G"]), window: w7, color: PrismProviderBrand.claude.dark)) }
                if !meters.isEmpty {
                    return IslandCompactFocus(
                        provider: provider,
                        identity: "C/G",
                        brandColor: PrismProviderBrand.geminiPartnerPool.dark,
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
                            label: strings.text(w.isFiveHour ? "usage.window.groupFiveHour" : "usage.window.groupWeek", ["group": "Argon"]),
                            window: w,
                            color: idx == 0 ? PrismProviderBrand.gemini.dark : PrismProviderBrand.geminiWeekly.dark
                        )
                    }
                    return IslandCompactFocus(
                        provider: provider,
                        identity: "Argon",
                        brandColor: PrismProviderBrand.gemini.dark,
                        isLocalActive: isLocalActive,
                        source: source,
                        meters: meters
                    )
                }
            }
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: PrismProviderBrand.gemini.dark)) }
            if let weekly { meters.append(makeMeter(tag: "7d", label: strings.text("usage.window.thisWeek"), window: weekly, color: PrismProviderBrand.geminiWeekly.dark)) }
            return IslandCompactFocus(
                provider: provider,
                identity: "Gemini",
                brandColor: PrismProviderBrand.gemini.dark,
                isLocalActive: isLocalActive,
                source: source,
                meters: meters
            )

        default:
            var meters: [IslandCompactWindowMeter] = []
            if let session { meters.append(makeMeter(tag: "5h", label: strings.text("usage.window.fiveHour"), window: session, color: PrismProviderBrand.codex.dark)) }
            if let weekly {
                let c = session == nil ? PrismProviderBrand.codex.dark : PrismProviderBrand.weekly.dark
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
        PrismProviderBrand.primary(forProvider: id)?.dark ?? fallback
    }

    private static func secondaryDarkColor(_ id: String) -> Color {
        PrismProviderBrand.secondary(forProvider: id).dark
    }
}

extension PrismIslandTokens {
    /// The alert color of a quota with `remaining` left: danger at 10% or less, warning at `low`
    /// or less, none above.
    func quotaAlert(remaining: Double, low: Double) -> Color? {
        if remaining <= 0.10 { return danger }
        if remaining <= low { return warning }
        return nil
    }
}

// MARK: - Compact Usage Strip (Shown when Sessions are Calm/Idle)

struct IslandCompactUsageStrip: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var geometry: IslandGeometry? = nil
    var screenID: UInt32? = nil

    private var l10n: PrismL10n { model.strings.l10n }
    private var island: PrismIslandTokens { model.prismTokens.island }

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
                    .foregroundStyle(island.secondary)
            }
        } else if let focus {
            HStack(spacing: 6) {
                SVGMark(svg: focus.provider.logo, size: hasNotch ? 11 : 12, color: focus.brandColor)
                Text(focus.identity)
                    .font(IslandFonts.ui(size, .semibold))
                    .foregroundStyle(island.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            HStack(spacing: 6) {
                SartoEmblem(size: 15, active: false)
                Text(SartoBrand.name)
                    .font(IslandFonts.ui(size, .medium))
                    .foregroundStyle(island.quote)
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
                .foregroundStyle(island.quote)
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
                        .foregroundStyle(island.tertiary)
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
        guard !reset, let rem = remaining else { return island.secondary }
        return island.quotaAlert(remaining: rem, low: usageStore.lowThreshold) ?? island.text
    }
}

// MARK: - Meters

/// The island's one fill bar: a capsule track with a capsule fill from the leading edge, for
/// quotas, the context window and any other share of a whole. It fills the width it is given.
struct IslandMicroBar: View {
    let fraction: Double
    let fill: AnyShapeStyle
    var height: CGFloat
    /// The track; the translucent `meterTrack` when nil, which reads alike on the chassis and cards.
    var track: Color?
    var animates: Bool
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fraction: Double, color: Color, height: CGFloat = 3.5, track: Color? = nil, animates: Bool = true) {
        self.init(fraction: fraction, fill: color, height: height, track: track, animates: animates)
    }

    init<Fill: ShapeStyle>(fraction: Double, fill: Fill, height: CGFloat = 3.5, track: Color? = nil, animates: Bool = true) {
        self.fraction = fraction
        self.fill = AnyShapeStyle(fill)
        self.height = height
        self.track = track
        self.animates = animates
    }

    var body: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? tokens.island.meterTrack)
                if clamped > 0.005 {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, geo.size.width * clamped))
                        .animation(
                            animates ? PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion) : nil,
                            value: clamped
                        )
                }
            }
        }
        .frame(height: height)
    }
}

/// The island's one progress ring, drawn with MenuBarKit's `RingArc` inside its frame: an arc over
/// the island's track, or over a disc of its own color. Plan, cache, usage and limit rings are all
/// this view.
struct IslandMeterRing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 2.2
    var showsTrack = true
    /// A disc of `color` at this opacity under the ring, filling the frame.
    var discOpacity: Double? = nil
    /// Insets the ring, not the disc, from the frame.
    var inset: CGFloat = 0
    @Environment(\.prismTokens) private var tokens

    var body: some View {
        ZStack {
            if let discOpacity {
                Circle().fill(color.opacity(discOpacity))
            }
            ZStack {
                if showsTrack {
                    Circle().strokeBorder(tokens.island.track, lineWidth: lineWidth)
                }
                RingArc(progress: max(0, min(1, progress)), lineWidth: lineWidth)
                    .fill(color)
            }
            .padding(inset)
        }
    }
}

// MARK: - Expanded Usage Tab (24h Bars + Active Forecast Card + Clickable Peer Rows)

struct IslandExpandedUsageTab: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var isMeasuring: Bool = false
    @State private var pinnedProviderId: String?
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var island: PrismIslandTokens { model.prismTokens.island }
    private var reduceMotion: Bool { systemReduceMotion || model.reduceMotion }

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
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        pinnedProviderId = provider.id
                    }
                }
            }
        }
        .padding(.top, 2)
        .onAppear {
            guard !isMeasuring else { return }
            usageStore.setShown(true)
        }
        .onDisappear {
            pinnedProviderId = nil
            guard !isMeasuring else { return }
            usageStore.setShown(false)
        }
    }

    /// Today's tokens and requests, or why there are none yet.
    private var summaryDetail: String {
        let l10n = model.strings.l10n
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
                    .foregroundStyle(island.tertiary)
                Text(settingsStore.settings.privacy ? "\(Fmt.symbol)••••" : Fmt.money(usageStore.todaySpend))
                    .font(NumFont.font(28))
                    .monospacedDigit()
                    .foregroundStyle(island.text)
                    .contentTransition(.numericText())
                    .animation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion), value: usageStore.todaySpend)
                Text(summaryDetail)
                    .font(IslandFonts.ui(10.5))
                    .foregroundStyle(island.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            IslandHourlyBars(values: usageStore.hourly, highlight: island.accent)
                .frame(width: 146, height: 38)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(island.wash)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(island.line, lineWidth: 0.75)
                )
        )
    }
}

private struct IslandHourlyBars: View {
    let values: [Double]
    let highlight: Color
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let maxValue = max(values.max() ?? 0, 0.0001)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                let last = index == values.count - 1
                Capsule()
                    .fill(last ? highlight : tokens.island.meterIdle)
                    .frame(height: max(2, CGFloat(value / maxValue) * 38))
                    .frame(maxWidth: .infinity)
            }
        }
        .animation(PrismSpringSpec.gentle.animation(tier: motionTier, reduceMotion: reduceMotion), value: values.last ?? 0)
    }
}

private enum IslandForecastFmt {
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
            return rem > 0
                ? strings.text("duration.hoursMinutes", ["h": "\(hrs)", "m": "\(rem)"])
                : strings.text("duration.hours", ["h": "\(hrs)"])
        }
        return strings.text("usage.durMins", ["m": "\(mins)"])
    }

    static func quotaSummary(_ meter: IslandCompactWindowMeter?, lowThreshold: Double, strings: IslandStrings, island: PrismIslandTokens) -> (text: String, color: Color, urgent: Bool) {
        guard let meter else { return (strings.text("usage.collecting"), island.tertiary, false) }
        guard let forecast = meter.forecast else {
            if meter.reset { return (strings.text("usage.resetPending"), island.secondary, false) }
            if meter.remaining <= 0.10 { return (strings.text("usage.lowCritical"), island.danger, true) }
            if meter.remaining <= lowThreshold { return (strings.text("usage.lowWarn"), island.warning, true) }
            return (strings.text("usage.collecting"), island.tertiary, false)
        }
        switch forecast.status {
        case .exhausts(let seconds):
            let critical = seconds < 2 * 3600 || meter.remaining <= 0.10
            let text = seconds < 60
                ? strings.text("usage.almostEmpty")
                : strings.text("usage.exhaustsIn", ["time": duration(seconds, strings: strings)])
            return (text, critical ? island.danger : island.warning, true)
        case .survives(let remAtReset):
            let pct = Int((remAtReset * 100).rounded())
            if meter.remaining <= 0.10 {
                return (strings.text("usage.criticalRemain", ["pct": "\(pct)"]), island.danger, true)
            }
            return (strings.text("usage.survivesRemain", ["pct": "\(pct)"]), island.successText, false)
        case .steady:
            return (strings.text("usage.survives"), island.successText, false)
        case .reset:
            return (strings.text("usage.resetPending"), island.secondary, false)
        case .insufficient:
            return (strings.text("usage.collecting"), island.tertiary, false)
        }
    }

    static func shortPeerQuota(_ meter: IslandCompactWindowMeter?, lowThreshold: Double, strings: IslandStrings, island: PrismIslandTokens) -> (text: String, color: Color, urgent: Bool) {
        guard let meter else { return (strings.text("usage.noQuota"), island.tertiary, false) }
        let label = (meter.tag == strings.text("usage.tag.week") || meter.fullLabel.hasPrefix("C/G") || meter.fullLabel.hasPrefix("Argon")) ? meter.fullLabel : meter.tag
        if meter.reset { return (strings.text("usage.peerReset", ["label": label]), island.secondary, false) }
        let pct = "\(Int((meter.remaining * 100).rounded()))%"
        let prefix = "\(label) \(pct)"
        let color = island.quotaAlert(remaining: meter.remaining, low: lowThreshold) ?? island.quote
        if let forecast = meter.forecast {
            switch forecast.status {
            case .exhausts(let seconds):
                let critical = seconds < 2 * 3600 || meter.remaining <= 0.10
                let text = seconds < 60
                    ? strings.text("usage.peerAlmostEmpty", ["prefix": prefix])
                    : strings.text("usage.peerExhausts", ["prefix": prefix, "time": duration(seconds, strings: strings)])
                return (text, critical ? island.danger : island.warning, true)
            case .survives, .steady:
                return (strings.text("usage.peerSurvives", ["prefix": prefix]), color, meter.remaining <= lowThreshold)
            case .reset:
                return (strings.text("usage.peerReset", ["label": label]), island.secondary, false)
            case .insufficient:
                break
            }
        }
        return (prefix, color, meter.remaining <= lowThreshold)
    }

    static func remainingTokens(_ meter: IslandCompactWindowMeter?, strings: IslandStrings) -> (text: String, muted: Bool) {
        guard let est = meter?.forecast?.estimatedRemainingTokens else {
            return (strings.text("usage.collecting"), true)
        }
        return (strings.text("usage.estTokens", ["tokens": Fmt.tokens(est)]), false)
    }
}

private struct IslandActiveForecastCard: View {
    let focus: IslandCompactFocus
    let lowThreshold: Double
    let isAutoActive: Bool
    let strings: IslandStrings
    let openDetail: () -> Void
    @State private var hoveringHeader = false
    @Environment(\.prismTokens) private var tokens

    var body: some View {
        let island = tokens.island
        let bottleneck = focus.bottleneck
        let qSummary = IslandForecastFmt.quotaSummary(bottleneck, lowThreshold: lowThreshold, strings: strings, island: island)
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
                        .foregroundStyle(island.text)
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
                        .foregroundStyle(hoveringHeader ? island.text : island.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(hoveringHeader ? island.quote : island.faint)
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
                                    .foregroundStyle(island.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if let resetsAt = m.resetsAt, !m.reset {
                                    Text(UsageCountdown.shortCountdown(to: resetsAt, l10n: strings.l10n))
                                        .font(IslandFonts.ui(9))
                                        .foregroundStyle(island.tertiary)
                                        .monospacedDigit()
                                        .lineLimit(1)
                                }
                                Text(m.reset ? strings.text("usage.resetTag") : "\(Int((m.remaining * 100).rounded()))%")
                                    .font(IslandFonts.mono(11, .semibold))
                                    .foregroundStyle(m.reset ? island.secondary : (island.quotaAlert(remaining: m.remaining, low: lowThreshold) ?? island.text))
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
                    .foregroundStyle(island.tertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    // A tinted well lifts its background, so its caption takes the next ink up.
                    Text(strings.text("usage.forecastTitle"))
                        .font(IslandFonts.ui(9, .medium))
                        .foregroundStyle(qSummary.urgent ? island.secondary : island.tertiary)
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
                        .fill(qSummary.urgent ? qSummary.color.opacity(0.10) : island.wash)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.text("usage.estRemainingTitle"))
                        .font(IslandFonts.ui(9, .medium))
                        .foregroundStyle(island.tertiary)
                    Text(tokEst.text)
                        .font(IslandFonts.mono(11, .semibold))
                        .foregroundStyle(tokEst.muted ? island.tertiary : island.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(island.wash)
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(island.washRaised)
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
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let island = tokens.island
        let summary = IslandForecastFmt.shortPeerQuota(focus.bottleneck, lowThreshold: lowThreshold, strings: strings, island: island)
        let strokeColor: Color = summary.urgent ? summary.color.opacity(0.32) : (hovered ? island.lineStrong : .clear)
        Button(action: onSelect) {
            HStack(spacing: 8) {
                SVGMark(svg: focus.provider.logo, size: 11, color: focus.brandColor)
                Text(focus.provider.name)
                    .font(IslandFonts.ui(11.5, .semibold))
                    .foregroundStyle(island.text)
                    .lineLimit(1)
                Text(strings.text("usage.tokensShort", ["tokens": Fmt.tokens(focus.provider.todayTokens)]))
                    .font(IslandFonts.mono(10))
                    .foregroundStyle(island.tertiary)
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
                    .fill(hovered ? island.washHover : island.washQuiet)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(strokeColor, lineWidth: 0.9))
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: hovered)
    }
}
