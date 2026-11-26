import SwiftUI

public struct StudioQuotaPool: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let brand: String // "antigravity", "claude", "codex", "opencode"
    public let remainingPercent: Double
    public let resetLabel: String

    public init(id: String, name: String, brand: String, remainingPercent: Double, resetLabel: String) {
        self.id = id
        self.name = name
        self.brand = brand
        self.remainingPercent = remainingPercent
        self.resetLabel = resetLabel
    }
}

public struct StudioUsageStats: Sendable, Equatable {
    /// Daily token totals for the past 182 days (26 weeks), oldest first, index 181 = today.
    public let dailyTokens: [Double]
    public let totalTokens26w: Double
    public let totalTokens7d: Double
    public let totalTurns26w: Int
    public let totalTurns7d: Int
    public let totalRequests26w: Int
    public let cacheHitPercent: Double?

    public init(
        dailyTokens: [Double] = Array(repeating: 0, count: 182),
        totalTokens26w: Double = 0,
        totalTokens7d: Double = 0,
        totalTurns26w: Int = 0,
        totalTurns7d: Int = 0,
        totalRequests26w: Int = 0,
        cacheHitPercent: Double? = nil
    ) {
        self.dailyTokens = dailyTokens.count == 182
            ? dailyTokens
            : Array(repeating: 0, count: max(0, 182 - dailyTokens.count)) + Array(dailyTokens.suffix(182))
        self.totalTokens26w = totalTokens26w
        self.totalTokens7d = totalTokens7d
        self.totalTurns26w = totalTurns26w
        self.totalTurns7d = totalTurns7d
        self.totalRequests26w = totalRequests26w
        self.cacheHitPercent = cacheHitPercent
    }
}


/// One tool's daily usage, as the menu bar's usage store counts it (this Mac plus the synced
/// Macs when the menu bar's scope includes them).
public struct StudioUsageSource: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let color: Color
    /// Oldest first, today last; aligned across sources.
    public let dailyTokens: [Double]
    public let dailyCost: [Double]

    public init(id: String, name: String, color: Color, dailyTokens: [Double], dailyCost: [Double]) {
        self.id = id
        self.name = name
        self.color = color
        self.dailyTokens = dailyTokens
        self.dailyCost = dailyCost
    }

    public func tokens(lastDays days: Int) -> Double {
        dailyTokens.suffix(days).reduce(0, +)
    }

    public func cost(lastDays days: Int) -> Double {
        dailyCost.suffix(days).reduce(0, +)
    }
}

/// One live subscription quota window shown in the usage card's Quotas tab.
public struct StudioQuotaItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let color: Color
    /// Remaining percentage in `0...100`.
    public let remainingPercent: Double
    public let resetLabel: String
    public let isReset: Bool

    public init(
        id: String,
        name: String,
        color: Color,
        remainingPercent: Double,
        resetLabel: String,
        isReset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.remainingPercent = remainingPercent
        self.resetLabel = resetLabel
        self.isReset = isReset
    }
}

public struct StudioUsageData: Equatable {
    public static let ranges = [7, 30, 90]
    public static let heatmapDays = 182 // 26 weeks x 7 days

    public let sources: [StudioUsageSource]
    /// Range in days -> requests in it.
    public let requestsByRange: [Int: Int]
    /// Macs whose usage is counted; 1 while sync is off.
    public let deviceCount: Int
    /// False until the first read has finished.
    public let ready: Bool
    /// Optional 26-week (182-day) daily token history for the square heatmap, oldest first.
    public let heatmapDailyTokens: [Double]
    /// Live vendor subscription quota windows shown in the right-hand Quotas tab.
    public let quotas: [StudioQuotaItem]

    public init(
        sources: [StudioUsageSource] = [],
        requestsByRange: [Int: Int] = [:],
        deviceCount: Int = 1,
        ready: Bool = false,
        heatmapDailyTokens: [Double] = [],
        quotas: [StudioQuotaItem] = []
    ) {
        self.sources = sources
        self.requestsByRange = requestsByRange
        self.deviceCount = deviceCount
        self.ready = ready
        self.heatmapDailyTokens = heatmapDailyTokens
        self.quotas = quotas
    }

    public var dailyTokens: [Double] {
        let count = sources.map(\.dailyTokens.count).max() ?? 0
        var totals = Array(repeating: 0.0, count: count)
        for source in sources {
            let offset = count - source.dailyTokens.count
            for (i, value) in source.dailyTokens.enumerated() { totals[offset + i] += value }
        }
        return totals
    }

    /// Always 182 days (26 weeks) so the heatmap renders as crisp 26x7 squares.
    public var heatmapSeries: [Double] {
        let raw = heatmapDailyTokens.isEmpty ? dailyTokens : heatmapDailyTokens
        if raw.count == Self.heatmapDays { return raw }
        if raw.count > Self.heatmapDays { return Array(raw.suffix(Self.heatmapDays)) }
        return Array(repeating: 0.0, count: Self.heatmapDays - raw.count) + raw
    }

    public func tokens(lastDays days: Int) -> Double {
        sources.reduce(0) { $0 + $1.tokens(lastDays: days) }
    }

    public func cost(lastDays days: Int) -> Double {
        sources.reduce(0) { $0 + $1.cost(lastDays: days) }
    }
}

/// Token activity heatmap: one column per week, one cell per day, today in the last cell.
/// Days outside `highlightLastDays` are dimmed; with no data every cell stays at level 0.
public struct TokenHeatmapMatrix: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let dailyTokens: [Double]
    public let weeklyActivity: [Double]?
    public let highlightLastDays: Int?
    public let cellHeight: CGFloat
    public let formatTokens: (Double) -> String

    @State private var hoveredCell: (col: Int, row: Int, daysAgo: Int, tokens: Double)?

    public init(
        dailyTokens: [Double],
        weeklyActivity: [Double]? = nil,
        highlightLastDays: Int? = nil,
        cellHeight: CGFloat = 12,
        formatTokens: @escaping (Double) -> String = { PrismTelemetryFormat.compactTokens($0) }
    ) {
        self.dailyTokens = dailyTokens
        self.weeklyActivity = weeklyActivity
        self.highlightLastDays = highlightLastDays
        self.cellHeight = cellHeight
        self.formatTokens = formatTokens
    }

    public static func level(forNormalized fraction: Double) -> Int {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        if fraction < 0.15 { return 1 }
        if fraction < 0.35 { return 2 }
        if fraction < 0.60 { return 3 }
        if fraction < 0.85 { return 4 }
        return 5
    }

    static func columnCount(for days: Int) -> Int {
        max(1, (days + 6) / 7)
    }

    /// Levels per week column; a partial first week is padded at its start.
    public static func computeLevels(
        dailyTokens: [Double],
        weeklyActivity: [Double]? = nil
    ) -> [[Int]] {
        let columns = columnCount(for: dailyTokens.count)
        let pad = columns * 7 - dailyTokens.count
        let maxDay = max(dailyTokens.max() ?? 0, 0)
        let normalizedTail: [Double]? = weeklyActivity.map { values in
            let suffix = Array(values.suffix(7))
            return Array(repeating: 0.0, count: max(0, 7 - suffix.count)) + suffix
        }

        var cols: [[Int]] = []
        cols.reserveCapacity(columns)
        for c in 0..<columns {
            var days: [Int] = []
            days.reserveCapacity(7)
            for r in 0..<7 {
                let idx = c * 7 + r - pad
                let rawVal = idx >= 0 && idx < dailyTokens.count ? dailyTokens[idx] : 0
                if rawVal > 0 && maxDay > 0 {
                    days.append(level(forNormalized: rawVal / maxDay))
                } else if c == columns - 1, let normalizedTail {
                    days.append(level(forNormalized: max(0.0, min(1.0, normalizedTail[r]))))
                } else {
                    days.append(0)
                }
            }
            cols.append(days)
        }
        return cols
    }

    public var body: some View {
        let levels = Self.computeLevels(dailyTokens: dailyTokens, weeklyActivity: weeklyActivity)
        let columns = levels.count
        let pad = columns * 7 - dailyTokens.count

        HStack(spacing: 3) {
            ForEach(0..<columns, id: \.self) { c in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { r in
                        let lvl = levels[c][r]
                        let idx = c * 7 + r - pad
                        let daysAgo = dailyTokens.count - 1 - idx
                        let inRange = idx >= 0 && (highlightLastDays.map { daysAgo < $0 } ?? true)
                        let isHot = hoveredCell?.col == c && hoveredCell?.row == r
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(tokens.heatColors[min(lvl, tokens.heatColors.count - 1)])
                            .overlay {
                                if lvl >= 3 {
                                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                        .strokeBorder(Color.white.opacity(tokens.palette.isDark ? 0.16 : 0.35), lineWidth: 0.5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .opacity(idx < 0 ? 0 : (inRange ? 1 : 0.26))
                            .scaleEffect(isHot ? 1.2 : 1.0)
                            .zIndex(isHot ? 5 : 0)
                            .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: isHot)
                            .animation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion), value: inRange)
                            .onHover { inside in
                                if inside, idx >= 0 {
                                    hoveredCell = (c, r, daysAgo, dailyTokens[idx])
                                } else if hoveredCell?.col == c && hoveredCell?.row == r {
                                    hoveredCell = nil
                                }
                            }
                    }
                }
            }
        }
        .onContinuousHover { phase in
            if case .ended = phase {
                hoveredCell = nil
            }
        }
        .overlay(alignment: .topTrailing) {
            if let cell = hoveredCell {
                HStack(spacing: 6) {
                    Text(cell.daysAgo == 0 ? l10n.tr("studio.today") : l10n.tr("studio.daysAgo", cell.daysAgo))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.foreground)
                    Text(cell.tokens <= 0 ? l10n.tr("studio.noRecords") : "\(formatTokens(cell.tokens)) tokens")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(tokens.prismCobalt)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .prismSurface(elevation: .popover, cornerRadius: tokens.rSM)
                .offset(y: -26)
                .allowsHitTesting(false)
            }
        }
    }
}

/// The new session stage's usage card: the same numbers as the menu bar's usage page, from the
/// same store, over 7, 30 or 90 days.
public struct StudioBentoChassisView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let usage: StudioUsageData
    public let isLiveConnection: Bool
    public let telemetrySummary: String
    public let primaryActionTitle: String
    public let formatTokens: (Double) -> String
    public let formatMoney: (Double) -> String
    public let onPrimaryAction: () -> Void

    private enum RightTab: String {
        case sources
        case quotas
    }

    @Binding private var rangeDays: Int
    @State private var rightTab: RightTab = .sources

    public init(
        usage: StudioUsageData,
        rangeDays: Binding<Int>,
        isLiveConnection: Bool,
        telemetrySummary: String,
        primaryActionTitle: String,
        formatTokens: @escaping (Double) -> String,
        formatMoney: @escaping (Double) -> String,
        onPrimaryAction: @escaping () -> Void
    ) {
        self.usage = usage
        self._rangeDays = rangeDays
        self.isLiveConnection = isLiveConnection
        self.telemetrySummary = telemetrySummary
        self.primaryActionTitle = primaryActionTitle
        self.formatTokens = formatTokens
        self.formatMoney = formatMoney
        self.onPrimaryAction = onPrimaryAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heatmapZone
                    Rectangle().fill(tokens.borderEtched).frame(height: 1)
                    heroScaleZone
                }
                .frame(maxWidth: .infinity)

                Rectangle().fill(tokens.borderEtched).frame(width: 1)

                rightZone
                    .frame(width: 272)
            }

            Rectangle().fill(tokens.borderEtched).frame(height: 1)

            HStack(spacing: 12) {
                Text(telemetrySummary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tokens.mutedForeground)
                    .lineLimit(1)

                Spacer()

                Button(action: onPrimaryAction) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(isLiveConnection ? tokens.success : tokens.prismCobalt)
                            .frame(width: 5, height: 5)
                        Text(primaryActionTitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(tokens.secondaryForeground)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(tokens.hoverWash))
                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(tokens.surface1.opacity(0.42))
        }
        .clipShape(RoundedRectangle(cornerRadius: tokens.rLG, style: .continuous))
        .prismSurface(elevation: .floating, cornerRadius: tokens.rLG)
        .prismInputRim(cornerRadius: tokens.rLG)
        .frame(maxWidth: 760)
    }

    // MARK: - 26-Week Square Heatmap (Concept A)

    private static let monthFormatCacheLock = NSLock()
    private nonisolated(unsafe) static var monthFormatters: [String: DateFormatter] = [:]

    private static func monthFormatter(for locale: Locale) -> DateFormatter {
        monthFormatCacheLock.lock()
        defer { monthFormatCacheLock.unlock() }
        if let existing = monthFormatters[locale.identifier] { return existing }
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.setLocalizedDateFormatFromTemplate("MMM")
        monthFormatters[locale.identifier] = fmt
        return fmt
    }

    private var monthAxisLabels: [String] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let fmt = Self.monthFormatter(for: l10n.language.resolvedLocale)
        let offsets = stride(from: 175, through: 0, by: -35)
        return offsets.compactMap { daysAgo in
            cal.date(byAdding: .day, value: -daysAgo, to: today).map { fmt.string(from: $0) }
        }
    }

    /// Weekday label for each row `0..<7` (today sits on row 6).
    private func weekdayLabel(forRow row: Int) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let isZh = l10n.language.resolvedLocale.identifier.lowercased().hasPrefix("zh")
        let zhNames = ["日", "一", "二", "三", "四", "五", "六"]
        let symbols = isZh ? zhNames : cal.veryShortWeekdaySymbols
        let daysAgo = 6 - row
        guard let date = cal.date(byAdding: .day, value: -daysAgo, to: today) else { return "" }
        let idx = cal.component(.weekday, from: date) - 1
        return symbols.indices.contains(idx) ? symbols[idx] : ""
    }

    private var heatmapZone: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(l10n.tr("studio.heatmapTitle"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tokens.secondaryForeground)
                    Text(l10n.tr("studio.heatmapSpan"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(tokens.placeholder)
                }

                Spacer()

                HStack(spacing: 2) {
                    ForEach(StudioUsageData.ranges, id: \.self) { days in
                        segButton(l10n.tr("studio.rangeDays", days), days: days)
                    }
                }
                .padding(2)
                .background(Capsule().fill(tokens.hoverWash))
                .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 0) {
                    ForEach(Array(monthAxisLabels.enumerated()), id: \.offset) { idx, label in
                        if idx > 0 { Spacer(minLength: 0) }
                        Text(label)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(tokens.placeholder)
                    }
                }
                .padding(.leading, 18)

                HStack(alignment: .center, spacing: 6) {
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(weekdayLabel(forRow: row))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(tokens.placeholder)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity((row == 1 || row == 3 || row == 5) ? 1 : 0)
                        }
                    }
                    .frame(width: 12)

                    TokenHeatmapMatrix(
                        dailyTokens: usage.heatmapSeries,
                        highlightLastDays: rangeDays,
                        formatTokens: formatTokens
                    )
                }
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(l10n.tr("studio.highlightRange", rangeDays))
                        .font(.system(size: 10))
                        .foregroundStyle(tokens.placeholder)
                    Spacer()
                    HStack(spacing: 3) {
                        Text(l10n.tr("studio.legendLess"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(tokens.placeholder)
                        ForEach(0..<tokens.heatColors.count, id: \.self) { idx in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(tokens.heatColors[idx])
                                .frame(width: 9, height: 9)
                        }
                        Text(l10n.tr("studio.legendMore"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(tokens.placeholder)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Ordered descending by token threshold so each rung starts at >= 1.0 of its reference scale
    /// and spans smoothly from 10K essays up to 100B+ national library archives.
    private static let volumeTiers: [(minTokens: Double, unitTokens: Double, key: String)] = [
        (100_000_000_000, 100_000_000_000, "studio.volume.nationalArchive"),
        (25_000_000_000, 25_000_000_000, "studio.volume.universityLibrary"),
        (6_000_000_000, 6_000_000_000, "studio.volume.wikipedia"),
        (350_000_000, 350_000_000, "studio.volume.linuxKernel"),
        (50_000_000, 50_000_000, "studio.volume.encyclopedias"),
        (2_000_000, 2_000_000, "studio.volume.bookshelves"),
        (100_000, 80_000, "studio.volume.books"),
        (10_000, 10_000, "studio.volume.essays"),
    ]

    private var heroScaleZone: some View {
        let activeTokens = usage.tokens(lastDays: rangeDays)
        let formattedTok = formatTokens(activeTokens)
        let headline: String
        if !usage.ready {
            headline = l10n.tr("studio.readingUsage")
        } else if activeTokens <= 0 {
            headline = l10n.tr("studio.noUsageInRange")
        } else if let tier = Self.volumeTiers.first(where: { activeTokens >= $0.minTokens }) {
            headline = l10n.tr(tier.key, activeTokens / tier.unitTokens)
        } else {
            headline = l10n.tr("studio.totalTokensHeadline", formattedTok)
        }

        let devices = usage.deviceCount > 1 ? l10n.tr("studio.deviceSuffix", usage.deviceCount) : ""
        let subtitle = activeTokens > 0
            ? l10n.tr(
                "studio.usageSubtitle",
                formattedTok,
                usage.requestsByRange[rangeDays] ?? 0,
                formatMoney(usage.cost(lastDays: rangeDays)),
                devices
            )
            : l10n.tr("studio.usageEmptyHint")

        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(headline)
                    .font(.system(size: 19.5, weight: .medium, design: .serif))
                    .foregroundStyle(tokens.foreground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.numericText())
                Text(l10n.tr("studio.rangeDaysLabel", rangeDays))
                    .font(.system(size: 11.5))
                    .foregroundStyle(tokens.mutedForeground)
            }
            Text(subtitle)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    // MARK: - Right Column: Sources / Quotas

    private var rightZone: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 12) {
                rightTabButton(.sources, title: l10n.tr("studio.sourcesTitle"))
                rightTabButton(.quotas, title: l10n.tr("studio.quotasTitle"))
                Spacer(minLength: 0)
            }

            if rightTab == .sources {
                sourcesList
            } else {
                quotasList
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func rightTabButton(_ tab: RightTab, title: String) -> some View {
        let active = rightTab == tab
        return Button {
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                rightTab = tab
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? tokens.secondaryForeground : tokens.placeholder)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sourcesList: some View {
        let rows = usage.sources.map { source in
            (source: source, tokens: source.tokens(lastDays: rangeDays), cost: source.cost(lastDays: rangeDays))
        }
        let total = rows.reduce(0) { $0 + $1.tokens }

        if !usage.ready || rows.isEmpty {
            Text(l10n.tr("studio.readingUsage"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 12) {
                ForEach(rows, id: \.source.id) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(row.source.color)
                                    .frame(width: 6, height: 6)
                                Text(row.source.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            HStack(spacing: 5) {
                                Text(formatTokens(row.tokens))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(tokens.placeholder)
                                    .lineLimit(1)
                                Text(formatMoney(row.cost))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(tokens.foreground)
                                    .lineLimit(1)
                            }
                        }

                        GeometryReader { geo in
                            let frac = total > 0 ? row.tokens / total : 0
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(tokens.hoverWash)
                                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.5))
                                if frac > 0 {
                                    Capsule()
                                        .fill(row.source.color)
                                        .overlay(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.28), Color.clear],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            .clipShape(Capsule())
                                        )
                                        .frame(width: max(5, geo.size.width * frac))
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var quotasList: some View {
        if usage.quotas.isEmpty {
            Text(usage.ready ? l10n.tr("studio.noQuotas") : l10n.tr("studio.readingUsage"))
                .font(.system(size: 11.5))
                .foregroundStyle(tokens.mutedForeground)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 11) {
                ForEach(usage.quotas) { quota in
                    let clamped = max(0, min(100, quota.remainingPercent))
                    let barColor: Color = {
                        if quota.isReset { return quota.color }
                        if clamped <= 10 { return tokens.danger }
                        if clamped <= 20 { return tokens.warning }
                        return quota.color
                    }()

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(barColor)
                                    .frame(width: 6, height: 6)
                                Text(quota.name)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(tokens.foreground)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            HStack(spacing: 5) {
                                Text(quota.isReset ? l10n.tr("studio.quotaReset") : "\(Int(clamped.rounded()))%")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(clamped <= 20 && !quota.isReset ? barColor : tokens.foreground)
                                    .lineLimit(1)
                                if !quota.resetLabel.isEmpty {
                                    Text(quota.resetLabel)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(tokens.placeholder)
                                        .lineLimit(1)
                                }
                            }
                        }

                        GeometryReader { geo in
                            let frac = quota.isReset ? 1.0 : (clamped / 100.0)
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(tokens.hoverWash)
                                    .overlay(Capsule().strokeBorder(tokens.borderEtched, lineWidth: 0.5))
                                if frac > 0 {
                                    Capsule()
                                        .fill(barColor)
                                        .overlay(
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.28), Color.clear],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            .clipShape(Capsule())
                                        )
                                        .frame(width: max(5, geo.size.width * frac))
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                }
            }
        }
    }

    private func segButton(_ title: String, days: Int) -> some View {
        let active = rangeDays == days
        return Button {
            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                rangeDays = days
            }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? tokens.foreground : tokens.mutedForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(active ? tokens.surface2 : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}
