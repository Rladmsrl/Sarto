import PrismDesign
import SwiftUI

/// The window's right-hand rail of sessions at work: the running ones and those waiting on the
/// user, grouped by agent under what is left of its plan, each as the island's strike lane with
/// its step and time below. Collapsed, it narrows to the agents' marks with a status dot.
struct RunningSessionsRail: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var model: PrismIslandModel
    var gameStore: GameStore? = nil
    let collapsed: Bool
    let selectedSessionID: String?
    let onSelect: (String) -> Void
    let onToggleCollapsed: () -> Void

    static let expandedWidth: CGFloat = 300
    static let collapsedWidth: CGFloat = 46

    /// Sessions the rail lists: at work, waiting on the user, or with work still running in
    /// the background after their turn ended.
    static func rows(of model: PrismIslandModel) -> [IslandRowItem] {
        model.rows.filter { $0.background || ["running", "starting", "waiting", "sign_in"].contains($0.status) }
    }

    private var groups: [(agent: IslandAgentIdentity, rows: [IslandRowItem])] {
        var order: [String] = []
        var byAgent: [String: (IslandAgentIdentity, [IslandRowItem])] = [:]
        for row in Self.rows(of: model) {
            if byAgent[row.agent.id] == nil {
                order.append(row.agent.id)
                byAgent[row.agent.id] = (row.agent, [])
            }
            byAgent[row.agent.id]?.1.append(row)
        }
        return order.compactMap { byAgent[$0].map { (agent: $0.0, rows: $0.1) } }
    }

    var body: some View {
        Group {
            if collapsed {
                collapsedStrip
            } else {
                expandedRail
            }
        }
        .frame(width: collapsed ? Self.collapsedWidth : Self.expandedWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(tokens.surface1.opacity(0.55))
        .overlay(alignment: .leading) {
            Rectangle().fill(tokens.borderEtched).frame(width: 1)
        }
    }

    // MARK: Expanded

    private var expandedRail: some View {
        let count = Self.rows(of: model).count
        let unread = model.rows.filter { $0.status == "unread" }.count
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tokens.prismCobalt)
                    .frame(width: 6, height: 6)
                    .background(Circle().fill(tokens.prismCobalt.opacity(0.18)).frame(width: 14, height: 14))
                Text(l10n.tr("rail.title"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tokens.foreground)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tokens.prismCobalt)
                    .contentTransition(.numericText())
                Spacer(minLength: 4)
                RailIconButton(systemName: "sidebar.right", help: l10n.tr("rail.collapse"), action: onToggleCollapsed)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(tokens.borderEtched).frame(height: 1) }

            if let gameStore, gameStore.visible {
                RailGameStrip(store: gameStore, paused: model.suspended)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.agent.id) { group in
                        RailAgentGroup(
                            model: model,
                            agent: group.agent,
                            rows: group.rows,
                            selectedSessionID: selectedSessionID,
                            onSelect: onSelect
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .animation(.spring(response: 0.38, dampingFraction: 0.86), value: Self.rows(of: model).map(\.key))
            }
            .scrollIndicators(.never)

            HStack(spacing: 6) {
                if unread > 0 {
                    Text(l10n.tr("rail.unread", unread))
                        .foregroundStyle(tokens.foreground)
                }
                Spacer(minLength: 4)
                if model.summary.today > 0 {
                    Text(l10n.tr("rail.today", model.summary.today))
                        .foregroundStyle(tokens.mutedForeground)
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14)
            .frame(height: 38)
            .overlay(alignment: .top) { Rectangle().fill(tokens.borderEtched).frame(height: 1) }
        }
    }

    // MARK: Collapsed

    private var collapsedStrip: some View {
        VStack(spacing: 10) {
            RailIconButton(systemName: "sidebar.right", help: l10n.tr("rail.expand"), action: onToggleCollapsed)
                .padding(.top, 11)
            Rectangle().fill(tokens.borderEtched).frame(width: 22, height: 1)
            ForEach(Self.rows(of: model)) { row in
                Button { onSelect(row.sessionId) } label: {
                    IslandMarkView(agent: row.agent, size: 18)
                        .padding(5)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(row.sessionId == selectedSessionID ? tokens.hoverWash : Color.clear)
                        )
                        .overlay(alignment: .topTrailing) {
                            Circle()
                                .fill(isWaiting(row) ? tokens.warning : tokens.prismCobalt)
                                .frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(tokens.background, lineWidth: 1.5))
                        }
                }
                .buttonStyle(.plain)
                .help(model.title(of: row))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: Self.rows(of: model).map(\.key))
    }

    private func isWaiting(_ row: IslandRowItem) -> Bool {
        row.status == "waiting" || row.status == "sign_in"
    }
}

/// An agent's mark and name, what is left of its plan, then its sessions.
private struct RailAgentGroup: View {
    @Environment(\.prismTokens) private var tokens

    var model: PrismIslandModel
    let agent: IslandAgentIdentity
    let rows: [IslandRowItem]
    let selectedSessionID: String?
    let onSelect: (String) -> Void

    var body: some View {
        let windows = model.quotaWindows(for: agent)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                IslandMarkView(agent: agent, size: 14)
                Text(agent.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tokens.secondaryForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)

            if !windows.isEmpty {
                HStack(spacing: 14) {
                    ForEach(windows) { window in
                        RailQuotaMeter(window: window)
                    }
                }
                .padding(.leading, 25)
                .padding(.bottom, 2)
            }

            ForEach(rows) { row in
                RailSessionCard(
                    model: model,
                    row: row,
                    selected: row.sessionId == selectedSessionID,
                    onSelect: onSelect
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
}

private struct RailQuotaMeter: View {
    @Environment(\.prismTokens) private var tokens
    let window: IslandQuotaWindow

    var body: some View {
        let tint: Color = window.remaining <= 0.1 ? tokens.danger : (window.remaining <= 0.3 ? tokens.warning : tokens.prismCobalt)
        HStack(spacing: 5) {
            Text(window.label)
                .font(.system(size: 10.5))
                .foregroundStyle(tokens.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: 64, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            ZStack(alignment: .leading) {
                Capsule().fill(tokens.hoverWash)
                Capsule().fill(tint).frame(width: max(2, 34 * window.remaining))
            }
            .frame(width: 34, height: 4)
            .animation(.spring(response: 0.5, dampingFraction: 0.9), value: window.remaining)
            Text("\(Int((window.remaining * 100).rounded()))%")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(window.remaining <= 0.3 ? tint : tokens.foreground)
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// One session: when an incomplete plan exists, renders the dark Sarto + Agent co-op Todo battle
/// arena (firing pixel bursts at the active Todo and switching targets as each clears). Without a
/// plan, keeps the compact strike lane capsule with the live action and elapsed time below.
private struct RailSessionCard: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n

    var model: PrismIslandModel
    let row: IslandRowItem
    let selected: Bool
    let onSelect: (String) -> Void

    @State private var hovered = false

    private var waiting: Bool { row.status == "waiting" || row.status == "sign_in" }

    var body: some View {
        Group {
            if let plan = row.plan {
                RailTodoBattleCard(
                    model: model,
                    row: row,
                    plan: plan,
                    selected: selected,
                    waiting: waiting,
                    onSelect: { onSelect(row.sessionId) }
                )
            } else {
                compactStrikeCard
            }
        }
    }

    private var compactStrikeCard: some View {
        Button { onSelect(row.sessionId) } label: {
            VStack(alignment: .leading, spacing: 6) {
                IslandStrikeLane(model: model, row: row, paused: waiting || model.suspended, showsElapsed: false)
                    .frame(height: 30)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(IslandTheme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(waiting ? tokens.warning.opacity(0.8) : Color.clear, lineWidth: 1.2)
                    )
                    .environment(\.colorScheme, .dark)

                HStack(spacing: 7) {
                    if waiting {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(tokens.warning)
                    }
                    Text(row.line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(waiting ? tokens.warning : tokens.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let hostName = row.hostName, !hostName.isEmpty {
                        Text(hostName)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(tokens.prismCobalt)
                            .lineLimit(1)
                    }
                    RailElapsedLabel(
                        model: model,
                        sinceMs: row.turnStartedAt ?? row.since,
                        fontSize: 10.5,
                        color: tokens.mutedForeground,
                        paused: model.suspended
                    )
                }
                .padding(.horizontal, 4)
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(selected ? tokens.background : (hovered ? tokens.hoverWash : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? tokens.borderStrong : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(row.project.isEmpty ? model.title(of: row) : "\(model.title(of: row)) · \(row.project)")
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

// MARK: - Sarto + Agent Co-Op Todo Battle Card (Right Running Rail)

private struct RailTodoBattleCard: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var model: PrismIslandModel
    let row: IslandRowItem
    let plan: IslandPlanSnapshot
    let selected: Bool
    let waiting: Bool
    let onSelect: () -> Void

    @State private var hovered = false

    private static let rowHeight: CGFloat = 24
    private static let rowSpacing: CGFloat = 2
    private static let rowStride: CGFloat = 26
    private static let topInset: CGFloat = 6
    private static let bottomInset: CGFloat = 6

    private var visibleSteps: (steps: [IslandPlanStep], activeVisibleIndex: Int?) {
        if plan.items.isEmpty {
            let text = plan.current ?? l10n.tr("rail.step", min(plan.total, plan.done + 1), plan.total, "")
            let step = IslandPlanStep(index: plan.done, content: text, status: "in_progress")
            return ([step], 0)
        }

        let items = plan.items
        let activeIdx = items.firstIndex(where: { $0.status == "in_progress" })
            ?? items.firstIndex(where: { $0.status != "completed" })

        if selected {
            // Current session: always expand every Todo step without any row cap.
            return (items, activeIdx)
        }

        // Non-current sessions collapse to the single active Todo step plus progress.
        let focusIdx = activeIdx ?? (items.count - 1)
        let single = items[focusIdx]
        let localActive: Int? = single.status == "completed" ? nil : 0
        return ([single], localActive)
    }

    var body: some View {
        let visible = visibleSteps
        let steps = visible.steps
        let activeIdx = visible.activeVisibleIndex
        let arenaHeight = Self.topInset
            + CGFloat(steps.count) * Self.rowHeight
            + CGFloat(max(0, steps.count - 1)) * Self.rowSpacing
            + Self.bottomInset
        let title = model.title(of: row)
        let tps = model.telemetry?.sessionId == row.sessionId ? model.telemetry?.tps : nil
        let progress = plan.total > 0 ? min(1.0, max(0.0, CGFloat(plan.done) / CGFloat(plan.total))) : 0
        let progressColor: Color = waiting
            ? IslandTheme.warning
            : (plan.done >= plan.total && plan.total > 0 ? IslandTheme.success : IslandTheme.prismCobalt)

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Card header: title + project + done/total + elapsed
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(IslandTheme.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if let hostName = row.hostName, !hostName.isEmpty {
                        Text(hostName)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(IslandTheme.prismCobalt)
                            .lineLimit(1)
                    } else if !row.project.isEmpty {
                        Text(row.project)
                            .font(.system(size: 10.5))
                            .foregroundStyle(IslandTheme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 4)
                    Text("\(plan.done)/\(plan.total)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(plan.done > 0 ? IslandTheme.success : IslandTheme.prismCobalt)
                        .monospacedDigit()
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule().fill((plan.done > 0 ? IslandTheme.success : IslandTheme.prismCobalt).opacity(0.16))
                        )
                        .fixedSize()
                    RailElapsedLabel(
                        model: model,
                        sinceMs: row.turnStartedAt ?? row.since,
                        fontSize: 10,
                        color: IslandTheme.secondary,
                        paused: model.suspended
                    )
                }
                .padding(.horizontal, 10)
                .frame(height: 29)

                // Slim progress bar separating header and battle arena
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(IslandTheme.line)
                        if progress > 0 {
                            Rectangle()
                                .fill(progressColor)
                                .frame(width: max(3, geo.size.width * progress))
                        }
                    }
                }
                .frame(height: 2)
                .animation(.spring(response: 0.35, dampingFraction: 0.88), value: progress)

                // Battle arena: pixel Sarto + Agent duo on left, firing toward the active Todo node
                let motion = model.effectiveMotion
                ZStack(alignment: .topLeading) {
                    RailTodoBattleCanvas(
                        agent: row.agent,
                        steps: steps,
                        activeIndex: activeIdx,
                        doneCount: plan.done,
                        phase: row.phase,
                        status: row.status,
                        tps: tps,
                        waiting: waiting,
                        paused: model.suspended,
                        reduceMotion: reduceMotion || !model.animatesStrikes,
                        motion: motion
                    )
                    .frame(height: arenaHeight)

                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { idx, step in
                            let isActive = idx == activeIdx
                            let isDone = step.status == "completed"
                            HStack(spacing: 0) {
                                Text(step.content)
                                    .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                                    .foregroundStyle(
                                        isActive
                                            ? (waiting ? IslandTheme.warning : IslandTheme.text)
                                            : (isDone ? IslandTheme.tertiary : IslandTheme.quote.opacity(0.78))
                                    )
                                    .strikethrough(isDone, color: IslandTheme.tertiary.opacity(0.7))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, 93)
                            .padding(.trailing, 10)
                            .frame(height: Self.rowHeight, alignment: .center)
                            .background(alignment: .leading) {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill((waiting ? IslandTheme.warning : IslandTheme.prismCobalt).opacity(0.11))
                                        .padding(.leading, 70)
                                        .padding(.trailing, 6)
                                }
                            }
                            .help(step.content)
                        }
                    }
                    .padding(.top, Self.topInset)
                    .padding(.bottom, Self.bottomInset)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // Footer: always show waiting reason; show live step caption only on selected card
                if waiting {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(IslandTheme.warning)
                        Text(row.line)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(IslandTheme.warning)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 7)
                } else if selected && !row.line.isEmpty {
                    HStack(spacing: 6) {
                        Spacer(minLength: 4)
                        Text(row.line)
                            .font(.system(size: 10))
                            .foregroundStyle(IslandTheme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 1)
                    .padding(.bottom, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(IslandTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    waiting
                        ? IslandTheme.warning.opacity(0.82)
                        : (selected
                            ? IslandTheme.prismCobalt.opacity(0.75)
                            : (hovered ? Color.white.opacity(0.18) : IslandTheme.line)),
                    lineWidth: (selected || waiting) ? 1.25 : 0.9
                )
        )
        .shadow(color: .black.opacity(selected ? 0.24 : 0.12), radius: selected ? 8 : 4, y: 2)
        .environment(\.colorScheme, .dark)
        .onHover { hovered = $0 }
        .help(row.project.isEmpty ? title : "\(title) · \(row.project)")
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selected)
    }
}

// MARK: - Sarto + Agent Co-Op Pixel Battle Simulation & Canvas

private struct RailElapsedLabel: View {
    var model: PrismIslandModel
    let sinceMs: Double?
    let fontSize: CGFloat
    let color: Color
    let paused: Bool

    var body: some View {
        if sinceMs != nil {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let date = paused ? model.now : context.date
                if let elapsed = model.duration(since: sinceMs, at: date) {
                    Text(elapsed)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
        }
    }
}

private struct RailTodoBattleCanvas: View {
    @Environment(\.prismMotionTier) private var motionTier

    let agent: IslandAgentIdentity
    let steps: [IslandPlanStep]
    let activeIndex: Int?
    let doneCount: Int
    let phase: String?
    let status: String
    let tps: Double?
    let waiting: Bool
    let paused: Bool
    let reduceMotion: Bool
    let motion: IslandMotionStyle

    @State private var sim = RailTodoBattleSimulation()

    private static let rowHeight: CGFloat = 24
    private static let rowStride: CGFloat = 26
    private static let topInset: CGFloat = 6
    private static let bottomInset: CGFloat = 6
    private static let sartoX: CGFloat = 14
    private static let agentX: CGFloat = 35
    private static let targetX: CGFloat = 80
    private static let sartoSize: CGFloat = 13
    private static let agentSize: CGFloat = 15.5

    private var framesPerSecond: Double { motion.framesPerSecond }

    private var normalizedIntensity: Double {
        let base: Double = {
            if let tps, tps > 0 {
                return min(1.0, 0.36 + (tps / 80.0) * 0.64)
            }
            switch phase {
            case "think", "thinking": return 0.34
            case "read", "search", "fetch": return 0.56
            case "edit", "write", "writing": return 0.78
            default: return status == "starting" ? 0.30 : 0.58
            }
        }()
        return motion == .calm ? base * 0.68 : base
    }

    private func rowCenterY(_ index: Int) -> CGFloat {
        Self.topInset + CGFloat(index) * Self.rowStride + Self.rowHeight * 0.5
    }

    var body: some View {
        let agentSprite = IslandPixelSpriteCache.sprite(for: agent)
        let palette = agentSprite.palette.isEmpty ? [IslandTheme.prismCobalt, IslandTheme.prismIris] : agentSprite.palette
        let policyFPS = PrismEnergyPolicy.framesPerSecond(
            for: .streaming,
            surface: .widget,
            displayMaxFPS: 60,
            conditions: PrismEnergyMonitor.shared.conditions
        )
        let effectiveFPS = PrismEnergyPolicy.capped(policyFPS, requestedFPS: Int(framesPerSecond.rounded()))

        if reduceMotion || motionTier == .off || effectiveFPS <= 0 || paused || waiting {
            staticCanvas(agentSprite: agentSprite, palette: palette)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / Double(max(1, effectiveFPS)), paused: paused)) { timeline in
                Canvas(rendersAsynchronously: false) { context, size in
                    guard size.width > 90, size.height > 16 else { return }
                    let activeID = activeIndex.flatMap { steps.indices.contains($0) ? steps[$0].id : nil }
                    let targetY = rowCenterY(activeIndex ?? 0)
                    let rowYByID = Dictionary(
                        steps.enumerated().map { ($0.element.id, rowCenterY($0.offset)) },
                        uniquingKeysWith: { first, _ in first }
                    )

                    let completedIDs = Set(steps.filter { $0.status == "completed" }.map(\.id))
                    sim.step(
                        timestamp: timeline.date.timeIntervalSinceReferenceDate,
                        targetY: targetY,
                        stepCount: steps.count,
                        activeStepID: activeID,
                        doneCount: doneCount,
                        completedIDs: completedIDs,
                        rowYByID: rowYByID,
                        sartoX: Self.sartoX,
                        agentX: Self.agentX,
                        targetX: Self.targetX,
                        agentSprite: agentSprite,
                        phase: phase,
                        waiting: waiting,
                        intensity: normalizedIntensity,
                        calmMode: motion == .calm
                    )

                    drawBattle(
                        context: &context,
                        size: size,
                        agentSprite: agentSprite,
                        palette: palette
                    )
                }
            }
        }
    }

    private func staticCanvas(agentSprite: IslandPixelSprite, palette: [Color]) -> some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard size.width > 90, size.height > 16 else { return }
            let targetY = rowCenterY(activeIndex ?? 0)
            drawVerticalTrack(context: &context, size: size)
            drawSquadSprites(
                context: &context,
                agentSprite: agentSprite,
                squadY: targetY,
                sartoKick: 0,
                sartoCharge: 0.45,
                sartoFlash: 0,
                agentKick: 0,
                agentFlash: 0,
                hopY: 0,
                missing: [],
                palette: palette
            )
            if !waiting && activeIndex != nil {
                let brand = palette.first ?? IslandTheme.prismCobalt
                for i in 0..<3 {
                    let x = Self.agentX + 12 + CGFloat(i) * 9
                    let r = CGRect(x: x, y: targetY - 1, width: 2.2, height: 2.2)
                    context.fill(Path(r), with: .color((i == 0 ? IslandTheme.prismCobalt : brand).opacity(0.75)))
                }
            }
            if waiting {
                drawWaitingExclamation(context: &context, x: (Self.sartoX + Self.agentX) * 0.5, y: targetY - 11)
            }
            drawAllTargetNodes(context: &context, hitFlash: 0, hitRecoil: 0, charge: 0.35, clearFlashes: [:])
        }
    }

    private func drawBattle(
        context: inout GraphicsContext,
        size: CGSize,
        agentSprite: IslandPixelSprite,
        palette: [Color]
    ) {
        let cell: CGFloat = 2.0

        drawVerticalTrack(context: &context, size: size)

        // 1. Subtle runway speed lines (skipped in calm 30fps mode for a quieter feel)
        if !waiting && activeIndex != nil && motion != .calm {
            for line in sim.speedLines {
                let lx = (Self.agentX + 9) + line.x * (Self.targetX - Self.agentX - 16)
                let ly = snap(sim.squadY + line.yOffset, step: cell)
                if ly > 2 && ly < size.height - 2 {
                    let rect = CGRect(x: lx, y: ly, width: line.length, height: 1.0)
                    context.fill(Path(rect), with: .color(Color.white.opacity(line.alpha)))
                }
            }
        }

        // 2. Curved pixel shockwaves on a cleared Todo and the periodic crit
        for wave in sim.shockwaves {
            let p = CGFloat(wave.age / wave.duration)
            let fade = Double(1.0 - p) * 0.95
            let arcHalfH: CGFloat = 5.5 + p * 8.0
            let arcDepth: CGFloat = arcHalfH * 0.44
            let frontX = wave.originX + p * (Self.targetX - wave.originX + 4)

            var dy = -arcHalfH
            while dy <= arcHalfH {
                let u = dy / max(1, arcHalfH)
                let wx = snap(frontX - arcDepth * u * u, step: cell)
                let wy = snap(wave.y + dy, step: cell)
                if wx >= Self.agentX + 6 && wx <= Self.targetX + 4 && wy > 1 && wy < size.height - 2 {
                    let thickness = abs(u) < 0.55 ? 2 : 1
                    for layer in 0..<thickness {
                        let px = wx - CGFloat(layer) * cell
                        let col = layer == 0 ? wave.color : wave.accent
                        context.fill(
                            Path(CGRect(x: px, y: wy, width: 1.75, height: 1.75)),
                            with: .color(col.opacity(fade * (layer == 0 ? 1.0 : 0.65)))
                        )
                    }
                }
                dy += cell
            }
        }

        // 3. Sarto + Agent co-op sprites gliding together along the left track
        let breatheY: CGFloat = waiting ? 0 : CGFloat(sin(sim.elapsed * 5.2)) * 0.8
        let hopY: CGFloat = sim.celebrateHop > 0 ? -CGFloat(sin(sim.celebrateHop * .pi * 2)) * 3.8 : 0
        drawSquadSprites(
            context: &context,
            agentSprite: agentSprite,
            squadY: sim.squadY + breatheY,
            sartoKick: sim.sartoKick,
            sartoCharge: sim.sartoCharge,
            sartoFlash: sim.sartoFlash,
            agentKick: sim.agentKick,
            agentFlash: sim.agentFlash,
            hopY: hopY,
            missing: Set(sim.missingPixels.map(\.cellIndex)),
            palette: palette
        )

        // 4. Co-op buff link pulses, support lobs and agent strikes
        for shot in sim.shots {
            let speedMag = max(1, hypot(shot.vx, shot.vy))
            let ux = shot.vx / speedMag
            let uy = shot.vy / speedMag
            for seg in 0..<shot.tailLength {
                let sx = snap(shot.x - ux * CGFloat(seg) * cell, step: cell)
                let sy = snap(shot.y - uy * CGFloat(seg) * cell, step: cell)
                guard sx >= 6, sx <= Self.targetX + 2, sy > 1, sy < size.height - 2 else { continue }
                let a = max(0.2, 1.0 - Double(seg) / Double(shot.tailLength + 1) * 0.78)
                let side: CGFloat = shot.thick ? 2.1 : 1.7
                context.fill(Path(CGRect(x: sx, y: sy, width: side, height: side)), with: .color(shot.color.opacity(a)))
                if shot.thick && seg < 2 {
                    context.fill(
                        Path(CGRect(x: sx, y: sy + cell, width: side, height: side)),
                        with: .color(shot.color.opacity(a * 0.7))
                    )
                }
            }
        }

        // 5. Todo pixel target nodes along x = targetX (aligned to each 24pt Todo row)
        drawAllTargetNodes(
            context: &context,
            hitFlash: sim.targetHitFlash,
            hitRecoil: sim.targetHitRecoil,
            charge: sim.targetCharge,
            clearFlashes: sim.clearFlashes
        )

        // 6. Rebounding & celebration sparks (always bounded to the left of Todo text!)
        for spark in sim.sparks {
            let ratio = spark.age / spark.life
            let alpha = max(0, 1.0 - ratio * ratio)
            let px = snap(spark.x, step: cell)
            let py = snap(spark.y, step: cell)
            guard px > 2, px < Self.targetX + 8, py > 1, py < size.height - 2 else { continue }
            context.fill(
                Path(CGRect(x: px, y: py, width: spark.size, height: spark.size)),
                with: .color(spark.color.opacity(alpha))
            )
        }

        // 7. Waiting-for-user amber pixel "!" pip bobbing above the squad
        if waiting {
            let bob = CGFloat(sin(sim.elapsed * 4.5)) * 1.4
            drawWaitingExclamation(
                context: &context,
                x: (Self.sartoX + Self.agentX) * 0.5,
                y: max(6, sim.squadY - 12 + bob)
            )
        }
    }

    private func drawVerticalTrack(context: inout GraphicsContext, size: CGSize) {
        guard steps.count > 1 else { return }
        let trackX = (Self.sartoX + Self.agentX) * 0.5
        var y: CGFloat = Self.topInset + 4
        while y < size.height - Self.bottomInset - 4 {
            context.fill(
                Path(CGRect(x: trackX - 0.5, y: y, width: 1.2, height: 2.0)),
                with: .color(Color.white.opacity(0.08))
            )
            y += 5.0
        }
    }

    private func drawSquadSprites(
        context: inout GraphicsContext,
        agentSprite: IslandPixelSprite,
        squadY: CGFloat,
        sartoKick: Double,
        sartoCharge: Double,
        sartoFlash: Double,
        agentKick: Double,
        agentFlash: Double,
        hopY: CGFloat,
        missing: Set<Int>,
        palette: [Color]
    ) {
        // Back support: Sarto pixel icon (slightly raised & behind Agent like a squad spotter)
        let sartoSprite = IslandPixelSpriteCache.appSprite
        let sn = CGFloat(sartoSprite.gridSize)
        let sStep = Self.sartoSize / sn
        let sGap: CGFloat = sStep >= 1.2 ? 0.16 : 0.08
        let sRecoil = CGFloat(-1.4 * sartoKick)
        let sScaleX = CGFloat(1.0 - 0.10 * sartoKick)
        let sScaleY = CGFloat(1.0 + 0.10 * sartoKick)
        let chargedFrom = Double(sartoSprite.gridSize - 1) - max(0, min(1, sartoCharge)) * Double(sartoSprite.gridSize - 2)

        var sCtx = context
        sCtx.translateBy(x: Self.sartoX + sRecoil, y: squadY - 1.5 + hopY * 0.85)
        sCtx.scaleBy(x: sScaleX, y: sScaleY)
        let sOrigin = -Self.sartoSize * 0.5
        for cell in sartoSprite.cells {
            let rect = CGRect(
                x: sOrigin + CGFloat(cell.gx) * sStep,
                y: sOrigin + CGFloat(cell.gy) * sStep,
                width: max(0.85, sStep - sGap),
                height: max(0.85, sStep - sGap)
            )
            sCtx.fill(Path(rect), with: .color(cell.color))
            if Double(cell.gy) >= chargedFrom && cell.gy > 0 && cell.gy < sartoSprite.gridSize - 1 {
                let rowColor = palette[(sartoSprite.gridSize - 1 - cell.gy) % palette.count]
                sCtx.fill(Path(rect), with: .color(rowColor.opacity(cell.luminance > 0.4 ? 0.72 : 0.24)))
            }
            if sartoFlash > 0.04 {
                sCtx.fill(Path(rect), with: .color(Color.white.opacity(0.6 * sartoFlash)))
            }
        }

        // Front striker: Agent pixel sprite (recoils leftward on firing rightward!)
        let an = CGFloat(agentSprite.gridSize)
        let aStep = Self.agentSize / an
        let aGap: CGFloat = aStep >= 1.2 ? 0.16 : 0.08
        let aRecoil = CGFloat(-1.8 * agentKick)
        let aScaleX = CGFloat(1.0 - 0.11 * agentKick)
        let aScaleY = CGFloat(1.0 + 0.11 * agentKick)
        let agentCenter = CGPoint(x: Self.agentX + aRecoil, y: squadY + 0.8 + hopY)

        var aCtx = context
        aCtx.translateBy(x: agentCenter.x, y: agentCenter.y)
        aCtx.scaleBy(x: aScaleX, y: aScaleY)
        let aOrigin = -Self.agentSize * 0.5
        for (idx, cell) in agentSprite.cells.enumerated() {
            let alpha: Double = missing.contains(idx) ? 0.26 : 1.0
            let rect = CGRect(
                x: aOrigin + CGFloat(cell.gx) * aStep,
                y: aOrigin + CGFloat(cell.gy) * aStep,
                width: max(0.9, aStep - aGap),
                height: max(0.9, aStep - aGap)
            )
            aCtx.fill(Path(rect), with: .color(cell.color.opacity(alpha)))
            if agentFlash > 0.04 {
                aCtx.fill(Path(rect), with: .color(Color.white.opacity(0.58 * agentFlash)))
            }
        }
    }

    private func drawAllTargetNodes(
        context: inout GraphicsContext,
        hitFlash: Double,
        hitRecoil: Double,
        charge: Double,
        clearFlashes: [String: Double]
    ) {
        for (idx, step) in steps.enumerated() {
            let cy = rowCenterY(idx)
            let isActive = idx == activeIndex
            let isDone = step.status == "completed"
            let clearFlash = clearFlashes[step.id] ?? 0

            if isDone {
                let popScale: CGFloat = 1.0 + CGFloat(clearFlash) * 0.32
                var c = context
                c.translateBy(x: Self.targetX, y: cy)
                c.scaleBy(x: popScale, y: popScale)
                let bg = CGRect(x: -5, y: -5, width: 10, height: 10)
                c.fill(Path(ellipseIn: bg), with: .color(IslandTheme.success.opacity(0.20 + clearFlash * 0.35)))
                c.stroke(Path(ellipseIn: bg), with: .color(IslandTheme.success), lineWidth: 1.25)
                var check = Path()
                check.move(to: CGPoint(x: -2.4, y: 0.2))
                check.addLine(to: CGPoint(x: -0.6, y: 2.0))
                check.addLine(to: CGPoint(x: 2.7, y: -1.8))
                c.stroke(check, with: .color(clearFlash > 0.3 ? .white : IslandTheme.success), style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round))
            } else if isActive {
                let nudgeX = waiting ? 0 : CGFloat(hitRecoil) * 1.6
                let cx = Self.targetX + nudgeX
                let ringColor = waiting ? IslandTheme.warning : IslandTheme.prismCobalt
                let outer = CGRect(x: cx - 5.5, y: cy - 5.5, width: 11, height: 11)
                context.fill(Path(ellipseIn: outer), with: .color(ringColor.opacity(0.20 + hitFlash * 0.35)))
                context.stroke(Path(ellipseIn: outer), with: .color(ringColor), lineWidth: 1.4)

                if !waiting && charge > 0.04 {
                    var arc = Path()
                    arc.addArc(
                        center: CGPoint(x: cx, y: cy),
                        radius: 5.5,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(-90 + 360 * min(1, charge)),
                        clockwise: false
                    )
                    context.stroke(arc, with: .color(Color.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                }

                let coreSize: CGFloat = waiting ? 3.2 : (3.4 + CGFloat(hitFlash) * 1.2)
                let core = CGRect(x: cx - coreSize * 0.5, y: cy - coreSize * 0.5, width: coreSize, height: coreSize)
                context.fill(Path(ellipseIn: core), with: .color(hitFlash > 0.25 ? .white : ringColor))
            } else {
                let ring = CGRect(x: Self.targetX - 4.5, y: cy - 4.5, width: 9, height: 9)
                context.stroke(Path(ellipseIn: ring), with: .color(Color.white.opacity(0.24)), lineWidth: 1.2)
            }
        }
    }

    private func drawWaitingExclamation(context: inout GraphicsContext, x: CGFloat, y: CGFloat) {
        let amber = IslandTheme.warning
        // Crisp 2x6 pixel "!" bar + 2x2 dot
        context.fill(Path(CGRect(x: x - 1, y: y - 4, width: 2.2, height: 5.2)), with: .color(amber))
        context.fill(Path(CGRect(x: x - 1, y: y + 2.4, width: 2.2, height: 2.0)), with: .color(amber))
    }

    private func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }
}

/// Real-time Sarto + Agent co-op pixel combat physics against the active Todo step. The calm
/// style fires and sparks less; the still style and Reduce Motion draw the static frame instead.
@MainActor
private final class RailTodoBattleSimulation {
    enum ShotKind {
        case buff    // Sarto -> Agent support charge pulse
        case support // Sarto -> active Todo arcing shot
        case strike  // Agent -> active Todo direct projectile
    }

    struct Shot {
        var kind: ShotKind
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var gravity: CGFloat
        var targetX: CGFloat
        var targetY: CGFloat
        var color: Color
        var tailLength: Int
        var thick: Bool
    }

    struct Spark {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var gravity: CGFloat
        var age: Double
        var life: Double
        var color: Color
        var size: CGFloat
    }

    struct Shockwave {
        var originX: CGFloat
        var y: CGFloat
        var age: Double
        var duration: Double
        var color: Color
        var accent: Color
    }

    struct SpeedLine {
        var x: CGFloat
        var yOffset: CGFloat
        var length: CGFloat
        var speed: CGFloat
        var alpha: Double
    }

    struct MissingPixel {
        var cellIndex: Int
        var ttl: Double
    }

    private(set) var shots: [Shot] = []
    private(set) var sparks: [Spark] = []
    private(set) var shockwaves: [Shockwave] = []
    private(set) var speedLines: [SpeedLine] = []
    private(set) var missingPixels: [MissingPixel] = []
    private(set) var clearFlashes: [String: Double] = [:]

    private(set) var elapsed: Double = 0
    private(set) var squadY: CGFloat = 18
    private(set) var sartoKick: Double = 0
    private(set) var sartoCharge: Double = 0.25
    private(set) var sartoFlash: Double = 0
    private(set) var agentKick: Double = 0
    private(set) var agentFlash: Double = 0
    private(set) var targetHitFlash: Double = 0
    private(set) var targetHitRecoil: Double = 0
    private(set) var targetCharge: Double = 0
    private(set) var celebrateHop: Double = 0

    private var squadVy: CGFloat = 0
    private var hasInitializedY = false
    private var lastStepCount: Int = 0
    private var lastTimestamp: Double?
    private var lastActiveStepID: String?
    private var lastDoneCount: Int?
    private var lastCompletedIDs: Set<String> = []
    private var switchHoldTimer: Double = 0
    private var strikeCarry: Double = 0.7
    private var sartoCarry: Double = 0.4
    private var shotCounter: Int = 0
    private var sartoShotCounter: Int = 0
    private var rngState: UInt64 = 0x5A27_070D_0C0B

    private static let buffColors: [Color] = [
        Color(hex: 0x5AA2FF),
        Color(hex: 0x86C5FF),
        Color(hex: 0x9B72CB),
    ]

    init() {
        speedLines = (0..<4).map { _ in
            SpeedLine(
                x: nextCGFloat(0, 1),
                yOffset: nextCGFloat(-7, 7),
                length: nextCGFloat(5, 11),
                speed: nextCGFloat(0.9, 1.6),
                alpha: Double(nextCGFloat(0.05, 0.12))
            )
        }
    }

    private func nextUnit() -> Double {
        rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
        let shifted = (rngState >> 11) & 0x1FFFFF_FFFFFFFF
        return Double(shifted) / Double(0x200000_00000000)
    }

    private func nextCGFloat(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + (hi - lo) * CGFloat(nextUnit())
    }

    func step(
        timestamp: Double,
        targetY: CGFloat,
        stepCount: Int,
        activeStepID: String?,
        doneCount: Int,
        completedIDs: Set<String>,
        rowYByID: [String: CGFloat],
        sartoX: CGFloat,
        agentX: CGFloat,
        targetX: CGFloat,
        agentSprite: IslandPixelSprite,
        phase: String?,
        waiting: Bool,
        intensity: Double,
        calmMode: Bool
    ) {
        let dt: Double
        if let prev = lastTimestamp {
            let raw = timestamp - prev
            if raw <= 0 { return }
            dt = min(0.05, raw)
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp
        elapsed += dt

        if !hasInitializedY {
            squadY = targetY
            hasInitializedY = true
            lastStepCount = stepCount
            lastActiveStepID = activeStepID
            lastDoneCount = doneCount
            lastCompletedIDs = completedIDs
        }

        // Detect expand/collapse vs genuine Todo completion.
        let prevDone = lastDoneCount ?? doneCount
        let prevID = lastActiveStepID
        let newlyCompleted = completedIDs.subtracting(lastCompletedIDs)
        if stepCount != lastStepCount && doneCount <= prevDone {
            squadY = targetY
            squadVy = 0
            switchHoldTimer = 0
            shots.removeAll(keepingCapacity: true)
            shockwaves.removeAll(keepingCapacity: true)
        } else if doneCount > prevDone || !newlyCompleted.isEmpty {
            let burstID = (prevID.flatMap { newlyCompleted.contains($0) ? $0 : nil })
                ?? newlyCompleted.first
                ?? prevID
            let burstY = burstID.flatMap { rowYByID[$0] } ?? squadY
            triggerTodoClearedFinisher(
                clearedIDs: newlyCompleted.isEmpty ? (prevID.map { [$0] } ?? []) : newlyCompleted,
                agentX: agentX,
                targetX: targetX,
                y: burstY
            )
            switchHoldTimer = 0.20
            targetCharge = 0
        } else if activeStepID != prevID {
            targetCharge = 0
        }
        lastStepCount = stepCount
        lastDoneCount = doneCount
        lastActiveStepID = activeStepID
        lastCompletedIDs = completedIDs

        // Smoothly glide Sarto + Agent along the left track once finisher hold expires
        if switchHoldTimer > 0 {
            switchHoldTimer = max(0, switchHoldTimer - dt)
        } else {
            let dy = targetY - squadY
            let accel = dy * 210 - squadVy * 22
            squadVy += accel * CGFloat(dt)
            squadY += squadVy * CGFloat(dt)
            if abs(dy) < 0.35 && abs(squadVy) < 1.5 {
                squadY = targetY
                squadVy = 0
            } else if abs(squadVy) > 30 && sparks.count < 42 && nextUnit() < 0.35 {
                sparks.append(Spark(
                    x: (sartoX + agentX) * 0.5 + nextCGFloat(-6, 6),
                    y: squadY,
                    vx: nextCGFloat(-16, 16),
                    vy: -squadVy * 0.18,
                    gravity: 40,
                    age: 0,
                    life: 0.18,
                    color: IslandTheme.prismCobalt,
                    size: 1.6
                ))
            }
        }

        let alignedToTarget = abs(squadY - targetY) < 4.5
        let palette = agentSprite.palette.isEmpty ? [IslandTheme.prismCobalt, IslandTheme.prismIris] : agentSprite.palette

        // Spawn Co-Op shots while actively running, not waiting, and aligned
        if !waiting && activeStepID != nil && switchHoldTimer <= 0 && alignedToTarget {
            let isThinking = (phase == "think" || phase == "thinking")
            let isScanning = (phase == "read" || phase == "search" || phase == "fetch")
            var strikeRate: Double = isThinking
                ? (1.9 + 1.1 * intensity)
                : (isScanning ? (3.0 + 1.6 * intensity) : (3.4 + 2.8 * intensity))
            if calmMode {
                strikeRate *= 0.72
            }

            strikeCarry += strikeRate * dt
            var cap = 2
            while strikeCarry >= 1.0 && cap > 0 {
                strikeCarry -= 1.0
                cap -= 1
                fireAgentStrike(
                    agentX: agentX,
                    targetX: targetX,
                    targetY: targetY,
                    sprite: agentSprite,
                    palette: palette,
                    isThinking: isThinking,
                    isScanning: isScanning,
                    intensity: intensity
                )
            }

            // Sarto support rhythm
            let sartoRate = (1.1 + 1.0 * intensity) * (calmMode ? 0.75 : 1.0)
            sartoCarry += sartoRate * dt
            if sartoCarry >= 1.0 {
                sartoCarry -= 1.0
                fireSartoSupport(
                    sartoX: sartoX,
                    agentX: agentX,
                    targetX: targetX,
                    targetY: targetY,
                    intensity: intensity
                )
            }
        }

        // Advance all shots and resolve impacts
        var surviving: [Shot] = []
        surviving.reserveCapacity(shots.count + 4)
        for var shot in shots {
            shot.vy += shot.gravity * CGFloat(dt)
            shot.x += shot.vx * CGFloat(dt)
            shot.y += shot.vy * CGFloat(dt)

            if shot.x >= shot.targetX {
                switch shot.kind {
                case .buff:
                    agentFlash = max(agentFlash, 0.52)
                    sartoCharge = min(1.0, sartoCharge + 0.18)
                case .support, .strike:
                    handleTargetImpact(
                        hitX: shot.targetX,
                        hitY: shot.y,
                        color: shot.color,
                        agentX: agentX,
                        palette: palette,
                        isHeavy: shot.thick || shot.kind == .support,
                        calmMode: calmMode
                    )
                }
            } else if shot.x > 0 && shot.x < targetX + 18 && shot.y > -8 && shot.y < 600 {
                surviving.append(shot)
            }
        }
        shots = surviving

        // Advance sparks
        sparks = sparks.compactMap { sp in
            var s = sp
            s.age += dt
            guard s.age < s.life else { return nil }
            s.vy += s.gravity * CGFloat(dt)
            s.x += s.vx * CGFloat(dt)
            s.y += s.vy * CGFloat(dt)
            return s
        }

        // Advance shockwaves
        shockwaves = shockwaves.compactMap { w in
            var copy = w
            copy.age += dt
            return copy.age < copy.duration ? copy : nil
        }

        // Advance runway speed lines
        for i in speedLines.indices {
            speedLines[i].x += speedLines[i].speed * CGFloat(dt) * CGFloat(0.6 + 0.8 * intensity)
            if speedLines[i].x > 1.2 {
                speedLines[i].x = -0.2
                speedLines[i].yOffset = nextCGFloat(-7, 7)
            }
        }

        // Decay impulses and clear flashes
        missingPixels = missingPixels.compactMap { m in
            var copy = m
            copy.ttl -= dt
            return copy.ttl > 0 ? copy : nil
        }
        for key in Array(clearFlashes.keys) {
            let next = (clearFlashes[key] ?? 0) - 2.0 * dt
            if next <= 0 {
                clearFlashes.removeValue(forKey: key)
            } else {
                clearFlashes[key] = next
            }
        }
        sartoKick = max(0, sartoKick - 8.5 * dt)
        sartoFlash = max(0, sartoFlash - 6.5 * dt)
        agentKick = max(0, agentKick - 9.0 * dt)
        agentFlash = max(0, agentFlash - 7.0 * dt)
        targetHitFlash = max(0, targetHitFlash - 7.5 * dt)
        targetHitRecoil = max(0, targetHitRecoil - 11.0 * dt)
        celebrateHop = max(0, celebrateHop - 3.6 * dt)
    }

    private func fireAgentStrike(
        agentX: CGFloat,
        targetX: CGFloat,
        targetY: CGFloat,
        sprite: IslandPixelSprite,
        palette: [Color],
        isThinking: Bool,
        isScanning: Bool,
        intensity: Double
    ) {
        guard shots.count < 32 else { return }
        shotCounter &+= 1
        agentKick = 1.0

        let launchX = agentX + 7.5
        if !sprite.launchIndices.isEmpty, missingPixels.count < 6 {
            let pick = sprite.launchIndices[shotCounter % sprite.launchIndices.count]
            missingPixels.append(MissingPixel(cellIndex: pick, ttl: 0.13))
        }

        let baseColor: Color
        if isThinking {
            baseColor = shotCounter % 2 == 0 ? IslandTheme.prismIris : IslandTheme.prismCobalt
        } else if isScanning {
            baseColor = shotCounter % 2 == 0 ? Color(hex: 0x5CC8FF) : palette[shotCounter % palette.count]
        } else {
            baseColor = palette[shotCounter % palette.count]
        }

        let destX = targetX - 5.5
        let speed = CGFloat(isThinking ? 135 : (175 + 95 * intensity)) * nextCGFloat(0.92, 1.12)
        spawnLinearShot(fromX: launchX, fromY: squadY + nextCGFloat(-3.0, 3.0), destX: destX, destY: targetY + nextCGFloat(-2.2, 2.2), speed: speed, color: baseColor, tail: isThinking ? 2 : (intensity > 0.65 ? 4 : 3), thick: isThinking || (shotCounter % 6 == 0 && intensity > 0.55))
    }

    private func spawnLinearShot(
        fromX: CGFloat,
        fromY: CGFloat,
        destX: CGFloat,
        destY: CGFloat,
        speed: CGFloat,
        color: Color,
        tail: Int,
        thick: Bool
    ) {
        let dx = max(14, destX - fromX)
        let flight = dx / max(60, speed)
        let vy = (destY - fromY) / max(0.06, flight)
        shots.append(Shot(
            kind: .strike,
            x: fromX,
            y: fromY,
            vx: speed,
            vy: vy,
            gravity: 0,
            targetX: destX,
            targetY: destY,
            color: color,
            tailLength: tail,
            thick: thick
        ))
    }

    private func fireSartoSupport(
        sartoX: CGFloat,
        agentX: CGFloat,
        targetX: CGFloat,
        targetY: CGFloat,
        intensity: Double
    ) {
        guard shots.count < 32 else { return }
        sartoShotCounter &+= 1
        sartoKick = 0.85

        // Alternate between buffing the Agent and lobbing an arcing co-op bolt over the Agent
        if sartoShotCounter % 3 == 0 || sartoCharge >= 0.95 {
            let isOverdrive = sartoCharge >= 0.95
            if isOverdrive {
                sartoCharge = 0.12
                sartoFlash = 0.95
            }
            let launchX = sartoX + 6
            let launchY = squadY - 4.5
            let destX = targetX - 5.5
            let dx = max(24, destX - launchX)
            let speed = CGFloat(155 + 60 * intensity)
            let flight = dx / speed
            let gravity: CGFloat = 210
            let vy = ((targetY - launchY) - 0.5 * gravity * CGFloat(flight * flight)) / max(0.08, flight)
            let color = isOverdrive ? Color.white : Self.buffColors[sartoShotCounter % Self.buffColors.count]
            shots.append(Shot(
                kind: .support,
                x: launchX,
                y: launchY,
                vx: speed,
                vy: vy,
                gravity: gravity,
                targetX: destX,
                targetY: targetY,
                color: color,
                tailLength: isOverdrive ? 4 : 3,
                thick: isOverdrive
            ))
        } else {
            let launchX = sartoX + 6
            let launchY = squadY - 1.5
            let color = Self.buffColors[sartoShotCounter % Self.buffColors.count]
            shots.append(Shot(
                kind: .buff,
                x: launchX,
                y: launchY,
                vx: 110,
                vy: 12,
                gravity: 0,
                targetX: agentX - 6,
                targetY: squadY,
                color: color,
                tailLength: 2,
                thick: false
            ))
        }
    }

    private func handleTargetImpact(
        hitX: CGFloat,
        hitY: CGFloat,
        color: Color,
        agentX: CGFloat,
        palette: [Color],
        isHeavy: Bool,
        calmMode: Bool
    ) {
        targetHitFlash = max(targetHitFlash, isHeavy ? 1.0 : 0.72)
        targetHitRecoil = max(targetHitRecoil, isHeavy ? 1.0 : 0.65)
        targetCharge += isHeavy ? 0.16 : 0.085
        sartoCharge = min(1.0, sartoCharge + 0.05)

        let sparkCount = calmMode ? 1 : (isHeavy ? 3 : 2)
        for i in 0..<sparkCount where sparks.count < 48 {
            sparks.append(Spark(
                x: hitX - 1,
                y: hitY,
                vx: nextCGFloat(-78, -22),
                vy: nextCGFloat(-62, 58),
                gravity: 195,
                age: 0,
                life: Double(nextCGFloat(0.16, 0.30)),
                color: i == 0 ? .white : color,
                size: isHeavy ? 1.9 : 1.65
            ))
        }

        // Periodic crit shockwave keeps long single steps feeling lively
        if targetCharge >= 1.0 {
            targetCharge = 0
            let accent = palette[shotCounter % palette.count]
            shockwaves.append(Shockwave(
                originX: agentX + 7,
                y: hitY,
                age: 0,
                duration: 0.28,
                color: .white,
                accent: accent
            ))
        }
    }

    private func triggerTodoClearedFinisher(
        clearedIDs: Set<String>,
        agentX: CGFloat,
        targetX: CGFloat,
        y: CGFloat
    ) {
        sartoFlash = 1.0
        agentFlash = 1.0
        sartoKick = 1.0
        agentKick = 1.0
        celebrateHop = 1.0
        sartoCharge = 0.2

        for id in clearedIDs {
            clearFlashes[id] = 1.0
        }

        shockwaves.append(Shockwave(
            originX: agentX + 6,
            y: y,
            age: 0,
            duration: 0.34,
            color: IslandTheme.success,
            accent: .white
        ))

        let burstCount = 10
        let burstColors: [Color] = [IslandTheme.success, .white, IslandTheme.prismAmber, IslandTheme.prismCobalt]

        for i in 0..<burstCount where sparks.count < 56 {
            let angle = Double(i) / Double(burstCount) * .pi * 2.0 + nextUnit() * 0.35
            let spd = nextCGFloat(34, 92)
            // Bias slightly leftward so celebration sparks never cover Todo text
            let vx = min(18, CGFloat(cos(angle)) * spd - 22)
            let vy = CGFloat(sin(angle)) * spd - 14
            sparks.append(Spark(
                x: targetX - 1,
                y: y,
                vx: vx,
                vy: vy,
                gravity: 175,
                age: 0,
                life: Double(nextCGFloat(0.28, 0.56)),
                color: burstColors[i % burstColors.count],
                size: i % 3 == 0 ? 2.1 : 1.8
            ))
        }
    }
}

private struct RailIconButton: View {
    @Environment(\.prismTokens) private var tokens
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? tokens.foreground : tokens.mutedForeground)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? tokens.hoverWash : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}
