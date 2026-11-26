import SwiftUI

public enum PrismCacheTelemetryMode: String, Sendable, Equatable {
    case liveRequest
    case lastTurn
    case session
    case pendingTurn
}

public struct ContextStratum: Identifiable, Sendable {
    public let id: Int
    public let title: String
    public let tokens: Double
    public let ratio: Double
    public let color: Color

    public init(id: Int, title: String, tokens: Double, ratio: Double, color: Color) {
        self.id = id
        self.title = title
        self.tokens = tokens
        self.ratio = ratio
        self.color = color
    }
}

public struct ContextDetailItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let detail: String?
    public let tokensText: String

    public init(id: String? = nil, name: String, detail: String? = nil, tokensText: String) {
        self.id = id ?? "\(name)::\(detail ?? "")::\(tokensText)"
        self.name = name
        self.detail = detail
        self.tokensText = tokensText
    }
}

public struct ContextDetailList: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let items: [ContextDetailItem]

    public init(id: String? = nil, name: String, items: [ContextDetailItem]) {
        self.id = id ?? name
        self.name = name
        self.items = items
    }
}

/// The composer footer's live telemetry: output speed, prompt cache and context fill. Each is a
/// chip that opens its own popover, and only measured values show.
public struct MiniTelemetryStripView<SpeedPopover: View, CachePopover: View, ContextPopover: View>: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let tps: Double?
    public let cacheHitPercent: Double?
    public let cacheMode: PrismCacheTelemetryMode
    public let totalTokens: Double
    public let contextFill: Double
    @Binding public var speedExpanded: Bool
    @Binding public var cacheExpanded: Bool
    @Binding public var contextExpanded: Bool
    private let speedPopover: () -> SpeedPopover
    private let cachePopover: () -> CachePopover
    private let contextPopover: () -> ContextPopover

    @State private var hovered: Chip?

    private enum Chip { case speed, cache, context }

    public init(
        tps: Double? = nil,
        cacheHitPercent: Double? = nil,
        cacheMode: PrismCacheTelemetryMode = .session,
        totalTokens: Double = 0,
        contextFill: Double,
        speedExpanded: Binding<Bool>,
        cacheExpanded: Binding<Bool>,
        contextExpanded: Binding<Bool>,
        @ViewBuilder speedPopover: @escaping () -> SpeedPopover,
        @ViewBuilder cachePopover: @escaping () -> CachePopover,
        @ViewBuilder contextPopover: @escaping () -> ContextPopover
    ) {
        self.tps = tps
        self.cacheHitPercent = cacheHitPercent
        self.cacheMode = cacheMode
        self.totalTokens = totalTokens
        self.contextFill = contextFill
        self._speedExpanded = speedExpanded
        self._cacheExpanded = cacheExpanded
        self._contextExpanded = contextExpanded
        self.speedPopover = speedPopover
        self.cachePopover = cachePopover
        self.contextPopover = contextPopover
    }

    public var body: some View {
        let warn = contextFill >= 0.80
        HStack(spacing: 1) {
            if let tps, tps > 0 {
                chip(.speed, isOpen: $speedExpanded) {
                    HStack(spacing: 3) {
                        Text(String(format: "%.1f", tps))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(chipForeground(.speed, isOpen: speedExpanded))
                        Text("tok/s")
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.68))
                    }
                }
                .popover(isPresented: $speedExpanded, arrowEdge: .bottom, content: speedPopover)

                separatorDot
            }

            if let cacheHitPercent {
                chip(.cache, isOpen: $cacheExpanded) {
                    HStack(spacing: 3) {
                        if cacheMode == .liveRequest {
                            Circle()
                                .fill(tokens.success)
                                .frame(width: 4.5, height: 4.5)
                        }
                        Text(l10n.tr("popover.cacheLabel"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground.opacity(0.68))
                        Text(String(format: "%.0f%%", cacheHitPercent))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(chipForeground(.cache, isOpen: cacheExpanded))
                    }
                }
                .popover(isPresented: $cacheExpanded, arrowEdge: .bottom, content: cachePopover)

                separatorDot
            }

            chip(.context, isOpen: $contextExpanded) {
                HStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .stroke(tokens.borderStrong.opacity(0.6), lineWidth: 1.75)
                        Circle()
                            .trim(from: 0, to: max(contextFill > 0 ? 0.04 : 0.0, min(1.0, contextFill)))
                            .stroke(
                                warn ? tokens.warning : tokens.primary,
                                style: StrokeStyle(lineWidth: 1.75, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 15, height: 15)

                    Text(totalTokens > 0 ? "\(Int(round(contextFill * 100)))%" : "—")
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(warn ? tokens.warning : chipForeground(.context, isOpen: contextExpanded))
                }
            }
            .popover(isPresented: $contextExpanded, arrowEdge: .bottom, content: contextPopover)
        }
    }

    private func chipForeground(_ chip: Chip, isOpen: Bool) -> Color {
        isOpen || hovered == chip ? tokens.foreground : tokens.secondaryForeground
    }

    private func chip<Label: View>(
        _ chip: Chip,
        isOpen: Binding<Bool>,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let active = isOpen.wrappedValue || hovered == chip
        return Button {
            isOpen.wrappedValue.toggle()
        } label: {
            label()
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? tokens.hoverWash : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovered = inside ? chip : (hovered == chip ? nil : hovered)
        }
    }

    private var separatorDot: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(tokens.mutedForeground.opacity(0.35))
    }
}

public enum PrismTelemetryFormat {
    public static func compactTokens(_ count: Double) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", count / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.1fk", count / 1_000.0)
        }
        return "\(Int(count))"
    }

    public static func duration(ms: Double) -> String {
        if ms < 1_000 { return "\(Int(ms.rounded())) ms" }
        if ms < 60_000 { return String(format: "%.1f s", ms / 1_000.0) }
        let secs = Int((ms / 1_000.0).rounded())
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }
}

/// The popovers' shared frame: a header with a title, a caption and one large figure, then rows.
private struct TelemetryPopoverChrome<Content: View>: View {
    @Environment(\.prismTokens) private var tokens

    let title: String
    let caption: String?
    let figure: String
    let unit: String?
    let figureColor: Color?
    let useSystemPopoverChrome: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        let body = VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2.5) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    if let caption {
                        Text(caption)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(figure)
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(figureColor ?? tokens.prismCobalt)
                    if let unit {
                        Text(unit)
                            .font(.system(size: 10.5))
                            .foregroundStyle(tokens.mutedForeground)
                    }
                }
            }
            content()
        }
        .padding(14)
        .frame(width: 280)
        .background(useSystemPopoverChrome ? tokens.surface1 : Color.clear)

        if useSystemPopoverChrome {
            body
        } else {
            body.prismSurface(elevation: .popover, cornerRadius: tokens.rLG)
        }
    }
}

private struct TelemetryValueRow: View {
    @Environment(\.prismTokens) private var tokens
    let label: String
    let value: String
    var swatch: Color? = nil

    var body: some View {
        HStack(spacing: 7) {
            if let swatch {
                Circle().fill(swatch).frame(width: 6, height: 6)
            }
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.secondaryForeground)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }
}

private struct TelemetryDivider: View {
    @Environment(\.prismTokens) private var tokens
    var body: some View {
        Rectangle().fill(tokens.borderEtched).frame(height: 1)
    }
}

/// Output speed: the live rate, its recent trend, time to first token and the turn's and
/// session's averages.
public struct OutputSpeedPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let rate: Double?
    public let isApprox: Bool
    public let isStreaming: Bool
    public let recentRates: [Double]
    public let firstTokenMs: Double?
    public let lastTokens: Double?
    public let lastMs: Double?
    public let turnRate: Double?
    public let turnRequests: Int?
    public let sessionRate: Double?
    public let sessionRequests: Int?
    public let useSystemPopoverChrome: Bool

    public init(
        rate: Double?,
        isApprox: Bool = false,
        isStreaming: Bool = false,
        recentRates: [Double] = [],
        firstTokenMs: Double? = nil,
        lastTokens: Double? = nil,
        lastMs: Double? = nil,
        turnRate: Double? = nil,
        turnRequests: Int? = nil,
        sessionRate: Double? = nil,
        sessionRequests: Int? = nil,
        useSystemPopoverChrome: Bool = false
    ) {
        self.rate = rate
        self.isApprox = isApprox
        self.isStreaming = isStreaming
        self.recentRates = recentRates
        self.firstTokenMs = firstTokenMs
        self.lastTokens = lastTokens
        self.lastMs = lastMs
        self.turnRate = turnRate
        self.turnRequests = turnRequests
        self.sessionRate = sessionRate
        self.sessionRequests = sessionRequests
        self.useSystemPopoverChrome = useSystemPopoverChrome
    }

    public var body: some View {
        TelemetryPopoverChrome(
            title: l10n.tr("popover.speed.title"),
            caption: l10n.tr(isStreaming ? "popover.speed.live" : "popover.speed.lastRequest"),
            figure: rate.map { (isApprox ? "≈" : "") + String(format: "%.1f", $0) } ?? "—",
            unit: "tok/s",
            figureColor: nil,
            useSystemPopoverChrome: useSystemPopoverChrome
        ) {
            if recentRates.count >= 2 {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n.tr("popover.speed.recent"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.placeholder)
                    sparkline
                }
            }

            let rows = valueRows
            if rows.isEmpty {
                Text(l10n.tr("popover.speed.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
            } else {
                TelemetryDivider()
                VStack(spacing: 1) {
                    ForEach(rows, id: \.0) { row in
                        TelemetryValueRow(label: row.0, value: row.1)
                    }
                }
            }
        }
    }

    /// The recent readings as a smooth curve over a vertical axis from zero to a rounded peak.
    private var sparkline: some View {
        let rates = Array(recentRates.suffix(24))
        let top = Self.axisTop(rates.max() ?? 0)
        let plot: CGFloat = 52
        let label: CGFloat = 10
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .trailing, spacing: 0) {
                axisLabel(top).frame(height: label)
                Spacer(minLength: 0)
                axisLabel(top / 2).frame(height: label)
                Spacer(minLength: 0)
                axisLabel(0).frame(height: label)
            }
            .frame(height: plot + label)

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    gridLine
                    Spacer(minLength: 0)
                    gridLine
                    Spacer(minLength: 0)
                    Rectangle().fill(tokens.borderStrong).frame(height: 1)
                }
                SpeedCurveShape(values: rates, top: top, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [tokens.prismCobalt.opacity(0.26), tokens.prismCobalt.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                SpeedCurveShape(values: rates, top: top, closed: false)
                    .stroke(tokens.prismCobalt, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                GeometryReader { geo in
                    if let last = rates.last {
                        let point = SpeedCurveShape.point(
                            index: rates.count - 1,
                            count: rates.count,
                            value: last,
                            top: top,
                            in: geo.size
                        )
                        Circle()
                            .fill(tokens.prismCobalt.opacity(0.22))
                            .frame(width: 10, height: 10)
                            .overlay(Circle().fill(tokens.prismCobalt).frame(width: 5, height: 5))
                            .position(point)
                    }
                }
            }
            .frame(height: plot)
            .padding(.vertical, label / 2)
            .overlay(alignment: .leading) {
                Rectangle().fill(tokens.borderStrong).frame(width: 1).padding(.vertical, label / 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var gridLine: some View {
        Rectangle().fill(tokens.borderEtched).frame(height: 1)
    }

    private func axisLabel(_ value: Double) -> some View {
        Text(value >= 10 || value == 0 ? String(format: "%.0f", value) : String(format: "%.1f", value))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(tokens.placeholder)
            .monospacedDigit()
    }

    /// The axis top: the peak rounded up to a round step of its power of ten, close enough that
    /// the curve fills most of the plot.
    static func axisTop(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(peak)))
        let step = peak / magnitude
        let nice = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].first { step <= $0 } ?? 10
        return nice * magnitude
    }

    private var valueRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let firstTokenMs {
            rows.append((l10n.tr("popover.speed.ttft"), PrismTelemetryFormat.duration(ms: firstTokenMs)))
        }
        if let lastTokens, let lastMs, lastMs > 0 {
            rows.append((
                l10n.tr("popover.speed.lastOutput"),
                l10n.tr(
                    "popover.speed.tokensIn",
                    PrismTelemetryFormat.compactTokens(lastTokens),
                    PrismTelemetryFormat.duration(ms: lastMs)
                )
            ))
        }
        if let turnRate, turnRate > 0 {
            rows.append((l10n.tr("popover.speed.turnAvg"), rateText(turnRate, requests: turnRequests)))
        }
        if let sessionRate, sessionRate > 0 {
            rows.append((l10n.tr("popover.speed.sessionAvg"), rateText(sessionRate, requests: sessionRequests)))
        }
        return rows
    }

    private func rateText(_ rate: Double, requests: Int?) -> String {
        let value = String(format: "%.1f tok/s", rate)
        guard let requests, requests > 0 else { return value }
        return l10n.tr("popover.speed.withRequests", value, "\(requests)")
    }
}

/// Prompt cache: the hit rate, what the latest request's input was made of, the session's totals
/// and how long the cache stays warm.
public struct PromptCachePopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    public let hitPercent: Double?
    public let mode: PrismCacheTelemetryMode
    public let sessionHitPercent: Double?
    public let requestCacheRead: Double?
    public let requestCacheWrite: Double?
    public let requestUncached: Double?
    public let sessionCacheRead: Double?
    public let sessionCacheWrite: Double?
    public let expiresAtMs: Double?
    public let lastRequestAtMs: Double?
    public let isTurnActive: Bool
    public let useSystemPopoverChrome: Bool

    public init(
        hitPercent: Double?,
        mode: PrismCacheTelemetryMode,
        sessionHitPercent: Double? = nil,
        requestCacheRead: Double? = nil,
        requestCacheWrite: Double? = nil,
        requestUncached: Double? = nil,
        sessionCacheRead: Double? = nil,
        sessionCacheWrite: Double? = nil,
        expiresAtMs: Double? = nil,
        lastRequestAtMs: Double? = nil,
        isTurnActive: Bool = false,
        useSystemPopoverChrome: Bool = false
    ) {
        self.hitPercent = hitPercent
        self.mode = mode
        self.sessionHitPercent = sessionHitPercent
        self.requestCacheRead = requestCacheRead
        self.requestCacheWrite = requestCacheWrite
        self.requestUncached = requestUncached
        self.sessionCacheRead = sessionCacheRead
        self.sessionCacheWrite = sessionCacheWrite
        self.expiresAtMs = expiresAtMs
        self.lastRequestAtMs = lastRequestAtMs
        self.isTurnActive = isTurnActive
        self.useSystemPopoverChrome = useSystemPopoverChrome
    }

    public var body: some View {
        TelemetryPopoverChrome(
            title: l10n.tr("popover.cache.title"),
            caption: modeCaption,
            figure: hitPercent.map { String(format: "%.0f%%", $0) } ?? "—",
            unit: nil,
            figureColor: tokens.success,
            useSystemPopoverChrome: useSystemPopoverChrome
        ) {
            let parts = requestParts
            if !parts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.tr("popover.cache.requestInput"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(tokens.placeholder)
                    compositionBar(parts)
                    VStack(spacing: 1) {
                        ForEach(parts, id: \.label) { part in
                            TelemetryValueRow(
                                label: part.label,
                                value: PrismTelemetryFormat.compactTokens(part.tokens),
                                swatch: part.color
                            )
                        }
                    }
                }
            }

            let rows = sessionRows
            if !rows.isEmpty || expiresAtMs != nil || lastRequestAtMs != nil || isTurnActive {
                TelemetryDivider()
                VStack(spacing: 1) {
                    ForEach(rows, id: \.0) { row in
                        TelemetryValueRow(label: row.0, value: row.1)
                    }
                    expiryRow
                }
            } else if parts.isEmpty {
                Text(l10n.tr("popover.cache.empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
            }
        }
    }

    private var modeCaption: String {
        switch mode {
        case .liveRequest: return l10n.tr("popover.cache.mode.liveRequest")
        case .lastTurn: return l10n.tr("popover.cache.mode.lastTurn")
        case .pendingTurn: return l10n.tr("popover.cache.mode.pendingTurn")
        case .session: return l10n.tr("popover.cache.mode.session")
        }
    }

    private struct Part {
        let label: String
        let tokens: Double
        let color: Color
    }

    private var requestParts: [Part] {
        var parts: [Part] = []
        if let requestCacheRead, requestCacheRead > 0 {
            parts.append(Part(label: l10n.tr("popover.cache.read"), tokens: requestCacheRead, color: tokens.success))
        }
        if let requestCacheWrite, requestCacheWrite > 0 {
            parts.append(Part(label: l10n.tr("popover.cache.write"), tokens: requestCacheWrite, color: tokens.prismCobalt))
        }
        if let requestUncached, requestUncached > 0 {
            parts.append(Part(label: l10n.tr("popover.cache.uncached"), tokens: requestUncached, color: tokens.borderStrong))
        }
        return parts
    }

    private func compositionBar(_ parts: [Part]) -> some View {
        let total = parts.reduce(0) { $0 + $1.tokens }
        return GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(parts, id: \.label) { part in
                    Capsule()
                        .fill(part.color)
                        .frame(width: max(3, (g.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(part.tokens / total)))
                }
            }
        }
        .frame(height: 5)
    }

    private var sessionRows: [(String, String)] {
        var rows: [(String, String)] = []
        // The header already shows the session's rate when that is all there is.
        if mode != .session, let sessionHitPercent {
            rows.append((l10n.tr("popover.cache.sessionHit"), String(format: "%.1f%%", sessionHitPercent)))
        }
        if let sessionCacheRead, sessionCacheRead > 0 {
            rows.append((l10n.tr("popover.cache.sessionRead"), PrismTelemetryFormat.compactTokens(sessionCacheRead)))
        }
        if let sessionCacheWrite, sessionCacheWrite > 0 {
            rows.append((l10n.tr("popover.cache.sessionWrite"), PrismTelemetryFormat.compactTokens(sessionCacheWrite)))
        }
        return rows
    }

    @ViewBuilder
    private var expiryRow: some View {
        if isTurnActive {
            TelemetryValueRow(label: l10n.tr("popover.cache.expiry"), value: l10n.tr("popover.cache.renewing"))
        } else if let expiresAtMs {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = expiresAtMs - context.date.timeIntervalSince1970 * 1000.0
                TelemetryValueRow(
                    label: l10n.tr("popover.cache.expiry"),
                    value: remaining > 0
                        ? l10n.tr("popover.cache.remaining", PrismTelemetryFormat.duration(ms: remaining))
                        : l10n.tr("popover.cache.expired")
                )
            }
        } else if let lastRequestAtMs {
            TimelineView(.periodic(from: .now, by: 10)) { context in
                let elapsedMs = max(0, context.date.timeIntervalSince1970 * 1000.0 - lastRequestAtMs)
                TelemetryValueRow(
                    label: l10n.tr("popover.cache.lastRequest"),
                    value: elapsedMs < 60_000
                        ? l10n.tr("popover.cache.justNow")
                        : l10n.tr("popover.cache.ago", PrismTelemetryFormat.duration(ms: elapsedMs))
                )
            }
        }
    }
}

/// Context window: the model, how full the window is, what fills it and this turn's growth.
public struct ContextTelemetryPopoverView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let modelName: String
    public let usedTokens: Double
    public let totalTokens: Double
    public let turnContextDelta: Double?
    public let strata: [ContextStratum]
    public let detailLists: [ContextDetailList]
    public let isLoadingDetails: Bool
    public let useSystemPopoverChrome: Bool

    @State private var hoveredStratumID: Int? = nil
    @State private var expandedListID: String? = nil

    public init(
        modelName: String,
        usedTokens: Double,
        totalTokens: Double,
        turnContextDelta: Double? = nil,
        strata: [ContextStratum] = [],
        detailLists: [ContextDetailList] = [],
        isLoadingDetails: Bool = false,
        useSystemPopoverChrome: Bool = false
    ) {
        self.modelName = modelName
        self.usedTokens = usedTokens
        self.totalTokens = totalTokens
        self.turnContextDelta = turnContextDelta
        self.strata = strata
        self.detailLists = detailLists
        self.isLoadingDetails = isLoadingDetails
        self.useSystemPopoverChrome = useSystemPopoverChrome
    }

    private var fillRatio: Double {
        guard totalTokens > 0 else { return 0 }
        return max(0.0, min(1.0, usedTokens / totalTokens))
    }

    public var body: some View {
        let warn = fillRatio > 0.82
        let content = VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2.5) {
                        HStack(spacing: 6) {
                            Circle().fill(tokens.success).frame(width: 6, height: 6)
                            Text(modelName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(tokens.foreground)
                                .lineLimit(1)
                            if isLoadingDetails {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.65)
                            }
                        }
                        Text(totalTokens > 0
                            ? l10n.tr("popover.contextHint", PrismTelemetryFormat.compactTokens(usedTokens), PrismTelemetryFormat.compactTokens(totalTokens))
                            : l10n.tr("popover.contextEmptyHint"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(tokens.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(totalTokens > 0 ? "\(Int(round(fillRatio * 100)))%" : "—")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(warn ? tokens.warning : tokens.prismCobalt)
                }

                if totalTokens > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tokens.hoverWash)
                            Capsule()
                                .fill(warn ? tokens.warning : tokens.prismCobalt)
                                .frame(width: g.size.width * CGFloat(max(fillRatio > 0 ? 0.02 : 0.0, fillRatio)))
                        }
                    }
                    .frame(height: 4)
                }

                if let turnContextDelta, turnContextDelta > 0 {
                    Text(l10n.tr("popover.context.turnDelta", PrismTelemetryFormat.compactTokens(turnContextDelta)))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }

            if !strata.isEmpty {
                VStack(spacing: 3) {
                    ForEach(strata) { item in
                        strataRow(item)
                    }
                }
            } else {
                Text(l10n.tr("popover.noStrataHint"))
                    .font(.system(size: 11))
                    .foregroundStyle(tokens.placeholder)
                    .padding(.vertical, 4)
            }

            if !detailLists.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detailLists) { list in
                        detailListRow(list)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 312)
        .background(useSystemPopoverChrome ? tokens.surface1 : Color.clear)

        if useSystemPopoverChrome {
            content
        } else {
            content.prismSurface(elevation: .popover, cornerRadius: tokens.rLG)
        }
    }

    private func strataRow(_ item: ContextStratum) -> some View {
        let active = hoveredStratumID == item.id
        return HStack(spacing: 7) {
            Circle().fill(item.color).frame(width: 6, height: 6)
            Text(item.title)
                .font(.system(size: 11.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? tokens.foreground : tokens.secondaryForeground)
            Spacer()
            Text(PrismTelemetryFormat.compactTokens(item.tokens))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(active ? tokens.prismCobalt : tokens.mutedForeground)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                .fill(active ? tokens.hoverWash : Color.clear)
        )
        .onHover { inside in
            hoveredStratumID = inside ? item.id : (hoveredStratumID == item.id ? nil : hoveredStratumID)
        }
    }

    private func detailListRow(_ list: ContextDetailList) -> some View {
        let isExpanded = expandedListID == list.id
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(PrismSpringSpec.default.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    expandedListID = isExpanded ? nil : list.id
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tokens.mutedForeground)
                        .frame(width: 10)
                    Text(list.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(list.items.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.mutedForeground)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(tokens.surface2))
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(isExpanded ? tokens.hoverWash : tokens.surface2.opacity(0.45))
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(list.items) { entry in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.name)
                                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(tokens.foreground)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let detail = entry.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(tokens.mutedForeground)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                Spacer(minLength: 4)
                                if !entry.tokensText.isEmpty {
                                    Text(entry.tokensText)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(tokens.mutedForeground)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                        }
                    }
                }
                .frame(maxHeight: 136)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: tokens.rXS, style: .continuous)
                        .fill(tokens.surface2.opacity(0.55))
                )
            }
        }
    }
}


/// A Catmull-Rom curve through evenly spaced readings, its control points kept inside the plot so
/// the curve never dips below zero or above the axis top. Closed, it runs down to the baseline.
struct SpeedCurveShape: Shape {
    let values: [Double]
    let top: Double
    let closed: Bool

    static func point(index: Int, count: Int, value: Double, top: Double, in size: CGSize) -> CGPoint {
        let x = count > 1 ? size.width * CGFloat(index) / CGFloat(count - 1) : size.width / 2
        let share = top > 0 ? min(1, max(0, value / top)) : 0
        return CGPoint(x: x, y: size.height * (1 - CGFloat(share)))
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        let points = values.indices.map {
            Self.point(index: $0, count: values.count, value: values[$0], top: top, in: rect.size)
        }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: min(rect.height, max(0, p.y)))
        }
        path.move(to: points[0])
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            let c1 = clamp(CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6))
            let c2 = clamp(CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.height))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.height))
            path.closeSubpath()
        }
        return path
    }
}
