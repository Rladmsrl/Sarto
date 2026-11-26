import AppKit
import PrismDesign
import SartoProtocol
import SwiftUI

// MARK: - Continuous-Curvature Concave-Shoulder Island Silhouette
// Adapted from Code Island's NotchPanelShape (MIT, Copyright (c) 2026 wxtsky):
// https://github.com/wxtsky/CodeIsland

/// Flat along the top edge with continuous cubic-bezier concave shoulders meeting the notch or
/// top screen edge, and continuously rounded bottom corners.
struct IslandShape: Shape {
    var radius: CGFloat
    var shoulders: Bool = true
    var shoulderWidth: CGFloat = IslandMetrics.shoulder

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, shoulderWidth) }
        set {
            radius = newValue.first
            shoulderWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(radius, rect.height / 2, rect.width / 2))
        let s = shoulders ? max(0, min(shoulderWidth, rect.height * 0.45)) : 0
        let c: CGFloat = 0.5522847498
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + s, y: rect.minY))
        if s > 0 {
            p.addCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + s),
                control1: CGPoint(x: rect.maxX + s * (1 - c), y: rect.minY),
                control2: CGPoint(x: rect.maxX, y: rect.minY + s * (1 - c))
            )
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        if r > 0 {
            p.addCurve(
                to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                control1: CGPoint(x: rect.maxX, y: rect.maxY - r * (1 - c)),
                control2: CGPoint(x: rect.maxX - r * (1 - c), y: rect.maxY)
            )
        }
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        if r > 0 {
            p.addCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - r),
                control1: CGPoint(x: rect.minX + r * (1 - c), y: rect.maxY),
                control2: CGPoint(x: rect.minX, y: rect.maxY - r * (1 - c))
            )
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + s))
        if s > 0 {
            p.addCurve(
                to: CGPoint(x: rect.minX - s, y: rect.minY),
                control1: CGPoint(x: rect.minX, y: rect.minY + s * (1 - c)),
                control2: CGPoint(x: rect.minX - s * (1 - c), y: rect.minY)
            )
        }
        p.closeSubpath()
        return p
    }
}

private func islandSwapTransition(_ reduceMotion: Bool) -> AnyTransition {
    let removal = AnyTransition.opacity.animation(.easeOut(duration: 0.09))
    if reduceMotion {
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.15)),
            removal: removal
        )
    }
    return .asymmetric(
        insertion: .opacity
            .combined(with: .offset(y: 6))
            .animation(.easeOut(duration: 0.18).delay(0.08)),
        removal: removal
    )
}

// MARK: - Root Container

struct PrismIslandRootView: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var gameStore: GameStore
    let screenID: UInt32
    var geometryBox: ScreenGeometryBox

    private var chassisFill: Color {
        switch model.prismTokens.palette {
        case .warm, .alabaster: return Color(hex: 0x0C0B0A)
        case .obsidian, .crystal: return Color(hex: 0x050508)
        }
    }

    var body: some View {
        let g = geometryBox.geometry
        let mode = model.effectiveMode(for: screenID)
        let size = model.frameSize(for: g, mode: mode, screenID: screenID)
        let radius = model.radius(for: mode)
        let shoulder = model.shoulderWidth(for: mode)
        let aura = model.auraState

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Hardware-black obsidian chassis subtly tuned to active Prism palette warmth
                IslandShape(radius: radius, shoulders: true, shoulderWidth: shoulder)
                    .fill(chassisFill)
                    .shadow(
                        color: .black.opacity(mode == .open ? 0.44 : (mode == .grown ? 0.28 : 0.18)),
                        radius: mode == .open ? 22 : 10,
                        y: mode == .open ? 9 : 4
                    )

                // Restrained Prism optical rim synced to active 4-palette tokens (paused when locked/asleep)
                IslandOpticalRim(
                    radius: radius,
                    shoulderWidth: shoulder,
                    aura: aura,
                    tokens: model.prismTokens,
                    isOpen: mode == .open,
                    paused: model.suspended,
                    reduceMotion: model.reduceMotion
                )

                // Mode-switched content clipped cleanly to inner silhouette
                ZStack(alignment: .top) {
                    switch mode {
                    case .hidden:
                        Color.clear
                    case .collapsed:
                        if model.collapsedQuiet {
                            Color.clear
                        } else if model.isIdleForUsage {
                            IslandCompactUsageStrip(
                                model: model,
                                usageStore: usageStore,
                                settingsStore: settingsStore,
                                geometry: g,
                                screenID: screenID
                            )
                            .transition(islandSwapTransition(model.reduceMotion))
                        } else {
                            IslandCollapsedContent(model: model, geometry: g, screenID: screenID)
                                .transition(islandSwapTransition(model.reduceMotion))
                        }
                    case .grown:
                        IslandGrownContent(model: model, geometry: g, screenID: screenID)
                            .transition(islandSwapTransition(model.reduceMotion))
                    case .open:
                        IslandPanelContent(
                            model: model,
                            usageStore: usageStore,
                            settingsStore: settingsStore,
                            gameStore: gameStore,
                            geometry: g,
                            screenID: screenID
                        )
                        .transition(islandSwapTransition(model.reduceMotion))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(IslandShape(radius: radius, shoulders: false, shoulderWidth: 0))
            }
            .frame(width: size.width, height: size.height)
            .opacity(mode == .hidden || (mode == .collapsed && model.collapsedQuiet && !g.hasNotch) ? 0 : 1)
            .contextMenu {
                IslandContextMenuItems(model: model)
            }
            .animation(model.animation(to: .collapsed), value: model.isIdleForUsage)
            .animation(model.animation(to: .collapsed), value: model.collapsedQuiet)
            .animation(model.animation(to: .collapsed), value: model.isSessionStackActive ? model.stackBodyHeight : -1)
            .animation(model.animation(to: .open), value: model.panelHeight(for: screenID))
            .animation(model.animation(to: mode), value: mode)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Hidden measurement pass on the active target display only, so multi-monitor setups never
        // mount duplicate measurement trees or trigger usage fetches on casual edge sweeps.
        .overlay(alignment: .top) {
            if model.measuring && mode != .open && model.measuringScreenID == screenID {
                IslandPanelBody(
                    model: model,
                    usageStore: usageStore,
                    settingsStore: settingsStore,
                    gameStore: gameStore,
                    isMeasuring: true
                )
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .frame(width: model.openWidth(for: g))
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { model.setPanelHeight(proxy.size.height, for: screenID) }
                            .onChange(of: proxy.size.height) { _, h in model.setPanelHeight(h, for: screenID) }
                    }
                )
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The island's right-click menu in a view of its own, so the chassis's body passes never build
/// it; the display list comes prebuilt from the coordinator.
private struct IslandContextMenuItems: View {
    var model: PrismIslandModel

    var body: some View {
        Button(model.strings.text("openSarto")) {
            model.openRow(nil)
        }
        Button(model.strings.text("menu.openUsagePanel")) {
            model.openMenuBarPanel(page: .main)
        }
        Button(model.strings.text("newSession")) {
            model.newSession()
        }
        Divider()
        Menu(model.strings.text("menu.displays")) {
            ForEach(model.displayMenuItems) { item in
                Button {
                    model.toggleDisplay(item.display)
                } label: {
                    if item.isActive {
                        Label("\(item.display.name) (\(item.display.resolution))", systemImage: "checkmark")
                    } else {
                        Text("\(item.display.name) (\(item.display.resolution))")
                    }
                }
            }
        }
        Divider()
        Button(model.strings.text("menu.testPop")) {
            model.actionSink?.islandTriggerDemoPop()
        }
        Button(model.strings.text("menu.testApproval")) {
            model.actionSink?.islandTriggerDemoApproval()
        }
        Divider()
        Button(model.strings.text("menu.hideIsland")) {
            model.actionSink?.islandRequestHide()
        }
    }
}

// MARK: - 1. Collapsed Pill View

private struct IslandLeadMarks: View {
    let collapsed: IslandCollapsedState?
    let aura: IslandAuraState
    var size: CGFloat = IslandMetrics.wingMark

    var body: some View {
        if let agents = collapsed?.agents, agents.count == 1, let accent {
            // One agent with something to say: its mark carries the state, a ring for an
            // approval, a badge for a failure or finished work, dimmed while its plan is used up.
            IslandMarkView(agent: agents[0], size: size - 2)
                .opacity(collapsed?.signal == .limited ? 0.5 : 1)
                .padding(2)
                .overlay {
                    if accent.ring {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(accent.color, lineWidth: 1.5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let glyph = accent.badge {
                        Image(systemName: glyph)
                            .font(.system(size: 6.5, weight: .black))
                            .foregroundStyle(IslandTheme.surface)
                            .frame(width: 10, height: 10)
                            .background(Circle().fill(accent.color))
                            .offset(x: 3, y: 3)
                    }
                }
        } else if let agents = collapsed?.agents, !agents.isEmpty {
            IslandMarkStack(agents: agents, size: size)
                .opacity(collapsed?.signal == .limited ? 0.5 : 1)
        } else {
            SartoEmblem(size: size, active: aura != .calm).padding(2)
        }
    }

    private var accent: (color: Color, ring: Bool, badge: String?)? {
        switch collapsed?.signal {
        case .waiting?: return (IslandTheme.attention, true, nil)
        case .failed?: return (IslandTheme.danger, false, "exclamationmark")
        case .unread?: return (IslandTheme.success, false, "checkmark")
        case .limited?: return (IslandTheme.danger, false, nil)
        default: return nil
        }
    }
}

private struct IslandCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(IslandFonts.ui(11.5, .semibold))
            .monospacedDigit()
            .foregroundStyle(IslandTheme.quote)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(IslandTheme.button))
            .fixedSize()
    }
}

private struct IslandFactView: View {
    let fact: IslandCollapsedFact
    var strings = IslandStrings(language: .system)
    var animates = true
    var paused = false

    var body: some View {
        switch fact {
        case .pending(let count):
            IslandStatePill(tint: IslandTheme.attention) {
                Circle().fill(IslandTheme.attention).frame(width: 6, height: 6)
                Text(strings.text("fact.pending", ["count": "\(count)"]))
            }
        case .resumeAt(let resetsAt):
            IslandStatePill(tint: IslandTheme.danger) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(strings.text("fact.resume", ["time": Self.countdown(to: resetsAt, from: context.date)]))
                        .monospacedDigit()
                }
            }
        case .failed:
            IslandStatePill(tint: IslandTheme.danger) {
                Text(strings.text("fact.failed"))
            }
        case .done(let count):
            IslandStatePill(tint: IslandTheme.success) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("\(count)").monospacedDigit()
            }
        case .running(let count, let since):
            IslandStatePill(tint: IslandTheme.quote, fill: Color.white.opacity(0.08)) {
                Circle()
                    .fill(IslandTheme.running)
                    .frame(width: 6, height: 6)
                    .modifier(IslandBreathing(active: animates && !paused))
                if count > 1 {
                    Text("\(count) ·").monospacedDigit()
                }
                if let since {
                    IslandRunningElapsedLabel(sinceMs: since, strings: strings, paused: paused)
                }
            }
        case .quota(let window, let agent, let reset):
            HStack(spacing: 5) {
                IslandMarkView(agent: agent, size: 12)
                ClampedWidthLayout(maxWidth: 54) {
                    Text(window.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                ZStack(alignment: .leading) {
                    Capsule().fill(IslandTheme.track)
                    Capsule()
                        .fill(Self.quotaTint(window.remaining))
                        .frame(width: max(2, 24 * window.remaining))
                }
                .frame(width: 24, height: 4)
                Text("\(Int((window.remaining * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(window.remaining <= 0.3 ? Self.quotaTint(window.remaining) : IslandTheme.text)
                    .fixedSize()
                if let reset {
                    Text("· \(reset)")
                        .fixedSize()
                }
            }
            .font(IslandFonts.ui(11.5, .semibold))
            .foregroundStyle(IslandTheme.quote)
            .lineLimit(1)
        case .count(let count):
            IslandCountBadge(count: count)
        case .plan(let done, let total):
            HStack(spacing: 5) {
                IslandPlanRing(done: done, total: total, size: 13)
                Text("\(done)/\(total)")
            }
            .font(IslandFonts.ui(12.5, .semibold))
            .foregroundStyle(IslandTheme.text)
        case .cache(let text, let ending):
            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 10.5, weight: .medium))
                Text(text)
            }
            .font(IslandFonts.ui(11.5, .semibold))
            .foregroundStyle(ending ? IslandTheme.warning : IslandTheme.secondary)
        case .speed(let text):
            Text(text)
                .font(IslandFonts.mono(11, .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [IslandTheme.prismCobalt, IslandTheme.prismIris],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        case .word(let text):
            Text(text)
                .font(IslandFonts.ui(12.5, .semibold))
                .foregroundStyle(IslandTheme.text)
        }
    }

    static func quotaTint(_ remaining: Double) -> Color {
        remaining <= 0.1 ? IslandTheme.danger : (remaining <= 0.3 ? IslandTheme.warning : IslandTheme.prismCobalt)
    }

    /// "1:42:00" past an hour, "42:00" under it.
    static func countdown(to resetsAt: Double, from date: Date) -> String {
        let seconds = max(0, Int((resetsAt / 1000 - date.timeIntervalSince1970).rounded(.up)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A tinted capsule for the right wing's one fact.
private struct IslandStatePill<Content: View>: View {
    let tint: Color
    var fill: Color? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 5) { content() }
            .font(IslandFonts.ui(11.5, .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(fill ?? tint.opacity(0.16)))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Hugs its single child's ideal width while clamping it to `maxWidth` without expanding to fill.
private struct ClampedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let cap = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        let ideal = child.sizeThatFits(ProposedViewSize(width: cap, height: proposal.height))
        return CGSize(width: min(ideal.width, cap), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

private struct IslandCollapsedContent: View {
    var model: PrismIslandModel
    let geometry: IslandGeometry
    let screenID: UInt32

    var body: some View {
        let g = geometry
        let c = model.collapsed

        if model.isSessionStackActive {
            IslandSessionStack(model: model, geometry: g, screenID: screenID)
        } else {
            Group {
                if model.isRunningStrikeActive {
                    runningStrikeBar(geometry: g, collapsed: c)
                } else {
                    standardCollapsedBar(geometry: g, collapsed: c)
                }
            }
            .frame(height: g.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture { model.expand(by: .click, onScreen: screenID) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.islandAccessibilityLabel)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func runningStrikeBar(
        geometry g: IslandGeometry,
        collapsed c: IslandCollapsedState?
    ) -> some View {
        let wing = model.collapsedWingWidth(for: g)
        let paused = model.suspended || model.effectiveMode(for: screenID) != .collapsed

        return HStack(spacing: 0) {
            IslandPixelStrikeStage(
                agents: c?.agents ?? [],
                tps: model.telemetry?.tps,
                runningCount: max(1, model.snapshot.summary.running),
                notchGapWidth: g.hasNotch ? g.notchWidth : 0,
                leftWingWidth: wing,
                paused: paused,
                reduceMotion: !model.animatesStrikes,
                framesPerSecond: model.stackOptions.motion.framesPerSecond
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let fact = c?.fact {
                Group {
                    if g.hasNotch {
                        ClampedWidthLayout(maxWidth: max(44, wing - 44)) {
                            IslandFactView(fact: fact, strings: model.strings, animates: model.animatesStrikes, paused: paused)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    } else {
                        IslandFactView(fact: fact, strings: model.strings, animates: model.animatesStrikes, paused: paused)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .layoutPriority(1)
                .padding(.leading, 2)
                .padding(.trailing, 12)
            }
        }
    }

    @ViewBuilder
    private func standardCollapsedBar(
        geometry g: IslandGeometry,
        collapsed c: IslandCollapsedState?
    ) -> some View {
        if g.hasNotch {
            notchCollapsedBar(geometry: g, collapsed: c)
        } else {
            plainCollapsedBar(collapsed: c)
        }
    }

    private func notchCollapsedBar(
        geometry g: IslandGeometry,
        collapsed c: IslandCollapsedState?
    ) -> some View {
        let wing = model.collapsedWingWidth(for: g)
        return HStack(spacing: 0) {
            Group {
                if case .quota(let window, let agent, _) = c?.fact {
                    HStack(spacing: 5) {
                        IslandMarkView(agent: agent, size: 12)
                        Text(window.label)
                            .font(IslandFonts.ui(11, .semibold))
                            .foregroundStyle(IslandTheme.quote)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                } else {
                    IslandLeadMarks(collapsed: c, aura: model.auraState)
                        .fixedSize()
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .frame(width: wing, alignment: .leading)

            Color.clear
                .frame(width: g.notchWidth)

            Group {
                if case .quota(let window, _, _) = c?.fact {
                    HStack(spacing: 5) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(IslandTheme.track)
                            Capsule()
                                .fill(IslandFactView.quotaTint(window.remaining))
                                .frame(width: max(2, 28 * window.remaining))
                        }
                        .frame(width: 28, height: 4)
                        Text("\(Int((window.remaining * 100).rounded()))%")
                            .font(IslandFonts.ui(11.5, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(
                                window.remaining <= 0.3
                                    ? IslandFactView.quotaTint(window.remaining)
                                    : IslandTheme.text
                            )
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        if let signal = c?.signal, c?.fact?.isPill != true {
                            IslandSignalView(signal: signal, reduceMotion: model.reduceMotion, paused: model.suspended)
                        }
                        if let fact = c?.fact {
                            IslandFactView(fact: fact, strings: model.strings, animates: model.animatesStrikes, paused: model.suspended)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 12)
            .frame(width: wing, alignment: .trailing)
        }
    }

    private func plainCollapsedBar(collapsed c: IslandCollapsedState?) -> some View {
        HStack(spacing: 8) {
            IslandLeadMarks(collapsed: c, aura: model.auraState)
                .fixedSize()

            if let title = c?.title {
                Text(title)
                    .font(IslandFonts.ui(12.5, .medium))
                    .foregroundStyle(c?.signal == nil ? IslandTheme.secondary : IslandTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }

            if (c?.signal != nil && c?.fact?.isPill != true) || c?.fact != nil {
                HStack(spacing: 7) {
                    if let signal = c?.signal, c?.fact?.isPill != true {
                        IslandSignalView(signal: signal, reduceMotion: model.reduceMotion, paused: model.suspended)
                    }
                    if let fact = c?.fact {
                        IslandFactView(fact: fact, strings: model.strings, animates: model.animatesStrikes, paused: model.suspended)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .layoutPriority(1)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
    }
}

// MARK: - 2. Grown Notification Pop View

private struct IslandPillBadge: View {
    let text: String
    let color: Color
    var dot: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(IslandFonts.ui(11.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, dot ? 9 : 7)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.16)))
        .fixedSize()
    }
}

private struct IslandLimitPill: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 6) {
            IslandUsageRing(percent: percent)
            Text("\(Int(percent.rounded()))%").monospacedDigit()
        }
        .font(IslandFonts.ui(11.5, .semibold))
        .foregroundStyle(IslandTheme.usageRed)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(IslandTheme.usageRed.opacity(0.16)))
        .fixedSize()
    }
}

private struct IslandGrownContent: View {
    var model: PrismIslandModel
    let geometry: IslandGeometry
    let screenID: UInt32

    var body: some View {
        let g = geometry
        VStack(alignment: .leading, spacing: 0) {
            if let pop = model.pop {
                let row = model.row(for: pop.rowKey)
                let (label, color) = model.pillInfo(for: pop.kind)

                HStack(spacing: 0) {
                    Group {
                        if let row {
                            IslandMarkView(agent: row.agent, size: g.hasNotch ? 20 : 17)
                        } else if let agent = pop.agent {
                            IslandMarkView(agent: agent, size: g.hasNotch ? 20 : 17)
                        } else {
                            SartoEmblem(size: g.hasNotch ? 20 : 17, active: true)
                        }
                    }
                    .padding(.leading, 14)

                    Spacer(minLength: model.middleWidth(for: g))

                    HStack(spacing: 6) {
                        if model.queuedPops > 0 {
                            IslandPillBadge(text: "+\(model.queuedPops)", color: IslandTheme.secondary, dot: false)
                        }
                        if pop.kind == "limit-near", let pct = pop.percent {
                            IslandLimitPill(percent: pct)
                        } else {
                            IslandPillBadge(text: label, color: color)
                        }
                    }
                    .padding(.trailing, 10)
                }
                .frame(height: g.notchHeight)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        (Text(row.map { model.title(of: $0) } ?? pop.title)
                            .foregroundStyle(IslandTheme.text)
                         + Text(row.map { $0.project.isEmpty ? "" : " · \($0.project)" } ?? "")
                            .foregroundStyle(IslandTheme.secondary)
                            .fontWeight(.medium))
                            .font(IslandFonts.ui(13, .semibold))
                            .lineLimit(1)
                    }
                    Text(pop.body)
                        .font(IslandFonts.ui(12))
                        .foregroundStyle(IslandTheme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.tapPop(onScreen: screenID) }
    }
}

// MARK: - 3. Expanded Interactive Panel (Approval-First + Compact `Sessions | Usage` Tab Switcher)

private struct IslandPanelContent: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var gameStore: GameStore
    let geometry: IslandGeometry
    let screenID: UInt32

    var body: some View {
        let g = geometry
        let activeTab = model.effectiveExpandedTab
        let hasSessionActivity = model.snapshot.summary.running > 0
            || model.snapshot.summary.waiting > 0
            || model.snapshot.summary.failed > 0
            || model.collapsed?.signal == .unread
        let sessionDotColor: Color = model.snapshot.summary.waiting > 0
            ? IslandTheme.attention
            : (model.snapshot.summary.failed > 0 ? IslandTheme.danger : model.prismTokens.primary)

        VStack(spacing: 0) {
            // Top header band: Approval identity when asking, otherwise light `Sessions | Usage` tab switcher + quick actions
            HStack(spacing: 6) {
                if model.asking {
                    if model.note == nil, let req = model.requests.first {
                        if let row = model.row(for: req.rowKey) {
                            IslandMarkView(agent: row.agent, size: IslandMetrics.wingMark)
                        } else {
                            SartoEmblem(size: IslandMetrics.wingMark, active: true).padding(2)
                        }
                    } else {
                        IslandLeadMarks(collapsed: model.collapsed, aura: model.auraState)
                    }
                    if let signal = model.collapsed?.signal {
                        IslandSignalView(signal: signal, reduceMotion: model.reduceMotion, paused: model.suspended)
                    }
                } else {
                    HStack(spacing: 3) {
                        IslandHeaderTabPill(
                            title: model.strings.text("tab.sessions"),
                            active: activeTab == .sessions,
                            accent: model.prismTokens.primary,
                            dotColor: hasSessionActivity ? sessionDotColor : nil
                        ) {
                            withAnimation(model.animation(to: .open)) {
                                model.selectTab(.sessions)
                            }
                        }
                        IslandHeaderTabPill(
                            title: model.strings.text("tab.usage"),
                            active: activeTab == .usage,
                            accent: model.prismTokens.primary,
                            dotColor: model.hasLowUsageAlert ? IslandTheme.warning : nil
                        ) {
                            withAnimation(model.animation(to: .open)) {
                                model.selectTab(.usage)
                            }
                        }
                    }
                    .padding(2)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }

                Spacer(minLength: g.hasNotch ? g.notchWidth : 8)

                if model.asking {
                    Text(model.summaryText)
                        .font(IslandFonts.ui(11.5, .medium))
                        .foregroundStyle(IslandTheme.secondary)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        IslandHeaderIconButton(
                            systemName: "arrow.up.forward.app",
                            help: model.strings.text("openSarto")
                        ) {
                            model.openRow(nil)
                        }
                        IslandHeaderIconButton(
                            systemName: "chart.bar.xaxis",
                            help: model.strings.text("menu.openUsagePanel")
                        ) {
                            model.openMenuBarPanel(page: .main)
                        }
                        IslandHeaderIconButton(
                            systemName: "gearshape.fill",
                            help: model.strings.text("menu.usageSettings")
                        ) {
                            model.openSettings(section: .islandAndMenuBar)
                        }
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(height: g.notchHeight)

            // Subtle Prism spectral hairline under header when running
            if model.auraState == .running {
                LinearGradient(
                    colors: [
                        Color.clear,
                        model.prismTokens.primary.opacity(0.72),
                        model.prismTokens.prismIris.opacity(0.66),
                        model.prismTokens.prismCoral.opacity(0.45),
                        Color.clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 14)
            }

            ScrollView(.vertical) {
                IslandPanelBody(
                    model: model,
                    usageStore: usageStore,
                    settingsStore: settingsStore,
                    gameStore: gameStore
                )
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { model.setPanelHeight(proxy.size.height, for: screenID) }
                            .onChange(of: proxy.size.height) { _, h in model.setPanelHeight(h, for: screenID) }
                    }
                )
            }
            .scrollIndicators(.never)
            .frame(height: max(0, model.frameSize(for: g, mode: .open, screenID: screenID).height - g.notchHeight))
        }
    }
}

private struct IslandHeaderTabPill: View {
    let title: String
    let active: Bool
    let accent: Color
    let dotColor: Color?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 5, height: 5)
                }
                Text(title)
                    .font(IslandFonts.ui(11, active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.white : (hover ? Color.white.opacity(0.85) : IslandTheme.secondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background(
                Capsule()
                    .fill(active ? accent.opacity(0.24) : (hover ? Color.white.opacity(0.06) : Color.clear))
            )
            .overlay(
                Capsule()
                    .stroke(active ? accent.opacity(0.55) : Color.clear, lineWidth: 0.75)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IslandHeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(hover ? Color.white : IslandTheme.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover ? Color.white.opacity(0.12) : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

private struct IslandPanelBody: View {
    var model: PrismIslandModel
    @ObservedObject var usageStore: PrismUsageStore
    @ObservedObject var settingsStore: UsageSettingsStore
    var gameStore: GameStore
    var isMeasuring: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note = model.note {
                IslandNoteView(note: note).padding(.vertical, 4)
            } else if let request = model.requests.first {
                IslandRequestCard(model: model, request: request).padding(.vertical, 4)
            } else if model.effectiveExpandedTab == .usage {
                IslandExpandedUsageTab(
                    model: model,
                    usageStore: usageStore,
                    settingsStore: settingsStore,
                    isMeasuring: isMeasuring
                )
            } else {
                if gameStore.visible, let gState = gameStore.state {
                    IslandExpeditionRow(model: model, store: gameStore, state: gState)
                        .padding(.vertical, 4)
                }
                if model.rows.isEmpty {
                    IslandEmptyPanel(model: model)
                } else {
                    let oneLine = model.rows.count > IslandMetrics.twoLineRows
                    VStack(spacing: oneLine ? 1 : 2) {
                        ForEach(model.listRows) { row in
                            IslandSessionRow(model: model, row: row, oneLine: oneLine)
                        }
                    }
                    .padding(.top, 2)

                    let more = model.rows.count - model.listRows.count
                    if more > 0 {
                        IslandMoreRow(model: model, count: more)
                    }
                }

                if let tel = model.telemetry {
                    IslandTelemetryStrip(telemetry: tel, strings: model.strings)
                        .padding(.top, 6)
                }

                if !model.notices.isEmpty {
                    VStack(spacing: 1) {
                        ForEach(model.notices) { notice in
                            IslandNoticeRow(model: model, notice: notice)
                        }
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) { Rectangle().fill(IslandTheme.line).frame(height: 1) }
                    .padding(.top, 6)
                }

                IslandPanelFooter(model: model)
            }
        }
    }
}

// MARK: - Prism Telemetry Micro-Strip inside Expanded Panel

private struct IslandExpeditionRow: View {
    var model: PrismIslandModel
    var store: GameStore
    let state: GameStateInfo
    @State private var hover = false

    var body: some View {
        Button {
            model.collapse()
            store.openExpedition()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandTheme.prismIris)
                Text(state.version)
                    .font(IslandFonts.mono(10.5, .bold))
                    .foregroundStyle(IslandTheme.prismAmber)
                Text(state.bossReady ? "Boss" : "\(state.chapter)-\(state.stage) · \(state.kills)/\(state.killsNeeded)")
                    .font(IslandFonts.mono(10.5, .medium))
                    .foregroundStyle(IslandTheme.text)
                    .lineLimit(1)
                if state.pendingOffers > 0 {
                    Text("★")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(IslandTheme.prismAmber)
                }
                Spacer(minLength: 4)
                Text("⚡\(state.power)")
                    .font(IslandFonts.mono(10.5, .semibold))
                    .foregroundStyle(IslandTheme.secondary)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(IslandTheme.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hover ? IslandTheme.cardHover : IslandTheme.card)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IslandTelemetryStrip: View {
    let telemetry: IslandLiveTelemetry
    let strings: IslandStrings

    var body: some View {
        HStack(spacing: 10) {
            if let tps = telemetry.tps, tps > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(telemetry.isStreaming ? IslandTheme.prismCobalt : IslandTheme.tertiary)
                        .frame(width: 5, height: 5)
                    Text("\(String(format: "%.1f", tps)) tok/s")
                        .font(IslandFonts.mono(10.5, .semibold))
                        .foregroundStyle(telemetry.isStreaming ? IslandTheme.text : IslandTheme.secondary)
                }
            }

            if let cache = telemetry.cacheHitPercent {
                HStack(spacing: 4) {
                    Text(strings.text("telemetry.cache"))
                        .font(IslandFonts.ui(10.5, .medium))
                        .foregroundStyle(IslandTheme.tertiary)
                    Text("\(Int(round(cache)))%")
                        .font(IslandFonts.mono(10.5, .semibold))
                        .foregroundStyle(cache >= 70 ? IslandTheme.success : (cache >= 40 ? IslandTheme.warning : IslandTheme.secondary))
                }
            }

            Spacer(minLength: 6)

            if telemetry.contextTotal > 0 {
                let fill = max(0, min(1, telemetry.contextFillRatio))
                HStack(spacing: 6) {
                    Text("\(strings.text("telemetry.context")) \(Int(round(fill * 100)))%")
                        .font(IslandFonts.mono(10.5, .medium))
                        .foregroundStyle(IslandTheme.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(IslandTheme.track)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [IslandTheme.prismCobalt, IslandTheme.prismIris],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(3, geo.size.width * fill))
                        }
                    }
                    .frame(width: 48, height: 4)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(IslandTheme.focusCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IslandTheme.line, lineWidth: 0.75)
        )
    }
}

// MARK: - Session Rows, Notices & Footer

private struct IslandSessionRow: View {
    var model: PrismIslandModel
    let row: IslandRowItem
    let oneLine: Bool
    @State private var hover = false

    var body: some View {
        let status = model.status(of: row)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                IslandMarkView(agent: row.agent, size: 14)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.title(of: row))
                        .font(IslandFonts.ui(13, .medium))
                        .foregroundStyle(row.group == "idle" ? IslandTheme.quote : IslandTheme.text)
                        .layoutPriority(1)
                    if !row.project.isEmpty {
                        Text(row.project)
                            .font(IslandFonts.ui(12))
                            .foregroundStyle(IslandTheme.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 8)

                if oneLine { trailing(status) }
                indicator(status).frame(width: 16, height: 16)
            }

            if !oneLine {
                HStack(spacing: 8) {
                    detail(status)
                        .font(IslandFonts.ui(12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    trailing(status)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.leading, row.isSubagent ? 24 : 10)
        .padding(.trailing, 10)
        .padding(.top, oneLine ? 0 : 7)
        .padding(.bottom, oneLine ? 0 : 8)
        .frame(height: oneLine ? 32 : nil)
        .background(
            RoundedRectangle(cornerRadius: oneLine ? 8 : 9, style: .continuous)
                .fill(hover || model.selectedRowKey == row.key ? IslandTheme.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openRow(row.key) }
    }

    @ViewBuilder
    private func detail(_ status: String) -> some View {
        switch status {
        case "running", "starting":
            Text(row.line).foregroundStyle(IslandTheme.running)
        case "stuck":
            let mins = row.toolSince.map { max(1, Int(model.now.timeIntervalSince1970 - $0 / 1000) / 60) }
            let stuckText = mins.map {
                model.strings.text("row.stuck", ["time": model.strings.text("duration.minutes", ["m": "\($0)"])])
            }
            Text([stuckText, row.line].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(IslandTheme.warning)
        case "waiting", "sign_in":
            Text(row.line).foregroundStyle(IslandTheme.attention)
        case "unread":
            Text(row.line).foregroundStyle(IslandTheme.success)
        case "failed", "limited":
            Text(row.line).foregroundStyle(IslandTheme.danger)
        default:
            if let left = model.cacheLeft(row.cache) {
                Text(model.strings.text("cache.left", ["time": left.text]))
                    .foregroundStyle(left.ending ? IslandTheme.warning : IslandTheme.tertiary)
                    .monospacedDigit()
            } else {
                Text(row.line).foregroundStyle(IslandTheme.tertiary)
            }
        }
    }

    @ViewBuilder
    private func trailing(_ status: String) -> some View {
        switch status {
        case "running", "starting", "stuck":
            if let plan = row.plan {
                HStack(spacing: 5) {
                    IslandPlanRing(done: plan.done, total: plan.total, size: 12)
                    Text(model.strings.text("plan", ["done": "\(plan.done)", "total": "\(plan.total)"]))
                        .foregroundStyle(IslandTheme.tertiary)
                        .monospacedDigit()
                }
                .font(IslandFonts.ui(12))
                .fixedSize()
            } else if let time = model.duration(since: row.turnStartedAt ?? row.since) {
                IslandTimeText(text: time)
            }
        case "limited":
            if let resets = row.limit?.resetsAt {
                IslandTimeText(text: model.strings.text("resets", ["day": model.resetDay(resets)]))
            }
        case "sign_in":
            EmptyView()
        default:
            if let time = model.ago(since: row.since) {
                IslandTimeText(text: time)
            }
        }
    }

    @ViewBuilder
    private func indicator(_ status: String) -> some View {
        switch status {
        case "waiting", "sign_in":
            IslandWaitingDot(size: 8)
        case "failed", "limited", "stuck":
            IslandSignalView(
                signal: model.signal(of: row) ?? .failed,
                size: 14,
                reduceMotion: model.reduceMotion,
                paused: model.suspended
            )
        case "running", "starting":
            IslandTurnDots(
                pattern: status == "starting" ? .think : IslandTurnDots.Pattern(phase: row.phase),
                size: 12,
                reduceMotion: model.reduceMotion,
                paused: model.suspended
            )
        default:
            if let share = model.cacheEndingShare(row.cache) {
                IslandCacheRing(share: share)
            } else if status == "unread" {
                Circle().fill(IslandTheme.unread).frame(width: 6, height: 6)
            }
        }
    }
}

private struct IslandTimeText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(IslandFonts.ui(11.5))
            .foregroundStyle(IslandTheme.tertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}

private struct IslandMoreRow: View {
    var model: PrismIslandModel
    let count: Int
    @State private var hover = false

    var body: some View {
        HStack {
            Text(model.strings.text("moreSessions", ["count": "\(count)"]))
                .foregroundStyle(IslandTheme.secondary)
            Spacer(minLength: 8)
            Text(model.strings.text("viewInSarto") + " ↗")
                .foregroundStyle(IslandTheme.tertiary)
        }
        .font(IslandFonts.ui(12, .medium))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? IslandTheme.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openRow(nil) }
    }
}

private struct IslandNoticeRow: View {
    var model: PrismIslandModel
    let notice: IslandNoticeItem
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let first = notice.marks.first {
                IslandMarkView(agent: first, size: 14)
            } else {
                SartoEmblem(size: 14, active: false)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.title)
                    .font(IslandFonts.ui(12.5, .medium))
                    .foregroundStyle(IslandTheme.text)
                    .layoutPriority(1)
                if let detail = notice.detail {
                    Text(detail)
                        .font(IslandFonts.ui(11.5))
                        .foregroundStyle(IslandTheme.tertiary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 8)

            if let meter = notice.meter {
                HStack(spacing: 5) {
                    if meter.reached {
                        IslandLimitRing(size: 12)
                    } else {
                        IslandUsageRing(percent: meter.percent)
                    }
                    Text(meter.text).monospacedDigit()
                }
                .font(IslandFonts.ui(11.5, .medium))
                .foregroundStyle(IslandTheme.usageRed)
                .fixedSize()
            }

            if let trailing = notice.trailing {
                IslandTimeText(text: trailing)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? IslandTheme.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.openRow(nil) }
    }
}

private struct IslandEmptyPanel: View {
    var model: PrismIslandModel

    var body: some View {
        VStack(spacing: 6) {
            SartoEmblem(size: 28, active: false)
            Text(model.strings.text("empty.title"))
                .font(IslandFonts.ui(13, .semibold))
                .foregroundStyle(IslandTheme.text)
            Text(model.strings.text("empty.body"))
                .font(IslandFonts.ui(12))
                .foregroundStyle(IslandTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

private struct IslandPanelFooter: View {
    var model: PrismIslandModel

    var body: some View {
        HStack {
            IslandFooterButton(label: "+ " + model.strings.text("newSession")) {
                model.newSession()
            }
            Spacer()
            IslandFooterButton(label: model.strings.text("openSarto") + " ↗") {
                model.openRow(nil)
            }
        }
        .padding(.top, 6)
    }
}

private struct IslandFooterButton: View {
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(IslandFonts.ui(11.5, .medium))
                .foregroundStyle(hover ? IslandTheme.text : IslandTheme.secondary)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hover ? IslandTheme.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Inline Permission / Question / Plan Approval Card

private struct IslandNoteView: View {
    let note: IslandAnswerNote

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: note.ok ? "checkmark" : "exclamationmark.triangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(note.ok ? IslandTheme.success : IslandTheme.danger)
            Text(note.text)
                .font(IslandFonts.ui(12.5))
                .foregroundStyle(IslandTheme.quote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(IslandTheme.card))
    }
}

private struct IslandRequestCard: View {
    var model: PrismIslandModel
    let request: IslandPendingRequest

    var body: some View {
        let row = model.row(for: request.rowKey)
        let pending = model.pendingRequestKeys.contains(request.key)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.map { model.title(of: $0) } ?? model.strings.text("untitled"))
                        .font(IslandFonts.ui(13, .semibold))
                        .foregroundStyle(IslandTheme.text)
                    Text(subtitle(row))
                        .font(IslandFonts.ui(11.5))
                        .foregroundStyle(IslandTheme.secondary)
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if let time = model.duration(since: request.askedAt) {
                    Text(model.strings.text("waited", ["time": time]))
                        .font(IslandFonts.ui(11.5))
                        .foregroundStyle(IslandTheme.secondary)
                        .monospacedDigit()
                }
            }

            Text(request.title)
                .font(IslandFonts.ui(12.5, .semibold))
                .foregroundStyle(IslandTheme.attention)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .padding(.horizontal, 2)

            if !request.lines.isEmpty {
                if request.code {
                    Text(request.lines.joined(separator: "\n"))
                        .font(IslandFonts.mono(12))
                        .foregroundStyle(IslandTheme.text)
                        .lineLimit(3)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(IslandTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(IslandTheme.line, lineWidth: 0.75)
                        )
                } else {
                    Text(request.lines.joined(separator: "\n"))
                        .font(IslandFonts.ui(12.5))
                        .foregroundStyle(IslandTheme.text)
                        .lineLimit(4)
                        .padding(.horizontal, 2)
                }
            }

            if request.kind == "question" && !request.options.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(request.options.enumerated()), id: \.element.id) { index, option in
                        IslandOptionRow(
                            index: index,
                            option: option,
                            recommendedText: model.strings.text("recommended")
                        ) {
                            model.answer(request, option: option)
                        }
                    }
                }
                .padding(.top, 8)

                HStack {
                    cardFooter
                    Spacer(minLength: 0)
                }
                .padding(.top, 8)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        cardFooter
                        Spacer(minLength: 8)
                        cardButtons
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 8) { cardButtons }
                        HStack {
                            cardFooter
                            Spacer(minLength: 0)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        cardButtons
                        cardFooter
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(IslandTheme.card))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(IslandTheme.attention.opacity(0.22), lineWidth: 0.85)
        )
        .disabled(pending)
        .opacity(pending ? 0.6 : 1)
    }

    @ViewBuilder
    private var cardButtons: some View {
        if request.options.isEmpty {
            IslandActionButton(label: model.strings.text("answerInSarto") + " ↗", style: "open") {
                model.openRequest(request)
            }
        } else {
            ForEach(request.options) { option in
                IslandActionButton(label: option.label, style: option.style) {
                    model.answer(request, option: option)
                }
            }
        }
    }

    private func subtitle(_ row: IslandRowItem?) -> String {
        guard let row else { return request.isDemo ? "Sarto · Demo" : "" }
        return [row.project, row.agent.name].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var cardFooter: some View {
        let more = model.requests.count - 1
        HStack(spacing: 0) {
            if more > 0 {
                Text(model.strings.counted("moreWaiting", more) + " · ")
                    .foregroundStyle(IslandTheme.tertiary)
            }
            Button(model.strings.text("openInSarto")) {
                model.openRequest(request)
            }
            .buttonStyle(.plain)
            .foregroundStyle(IslandTheme.secondary)
        }
        .font(IslandFonts.ui(11.5))
        .lineLimit(1)
    }
}

private struct IslandOptionRow: View {
    let index: Int
    let option: IslandRequestOption
    let recommendedText: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .font(IslandFonts.mono(10.5, .semibold))
                    .foregroundStyle(IslandTheme.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(IslandTheme.card))
                Text(option.label)
                    .font(IslandFonts.ui(12.5, .medium))
                    .foregroundStyle(IslandTheme.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if option.style == "recommended" {
                    Text(recommendedText)
                        .font(IslandFonts.ui(11))
                        .foregroundStyle(IslandTheme.success)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hover ? IslandTheme.cardHover : IslandTheme.surface)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IslandActionButton: View {
    let label: String
    let style: String
    let action: () -> Void
    @State private var hover = false

    private var isPrimary: Bool {
        ["allow_once", "recommended", "open"].contains(style)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch style {
                case "deny":
                    IslandCrossShape()
                        .stroke(IslandTheme.danger, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(width: 9, height: 9)
                case "allow_once", "recommended":
                    IslandCheckShape()
                        .stroke(Color.black, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 9)
                case "allow_always":
                    IslandDoubleCheckShape()
                        .stroke(IslandTheme.usageGreen, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 15, height: 9)
                default:
                    EmptyView()
                }
                Text(label).lineLimit(1)
            }
            .font(IslandFonts.ui(12.5, .semibold))
            .foregroundStyle(isPrimary ? Color.black : IslandTheme.text)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        isPrimary
                            ? (hover ? Color.white : IslandTheme.primaryButton)
                            : (hover ? IslandTheme.buttonHover : IslandTheme.button)
                    )
            )
            .contentShape(Rectangle())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IslandCrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

private struct IslandCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

private struct IslandDoubleCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.24, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.66, y: rect.minY))
        p.move(to: CGPoint(x: rect.minX + w * 0.44, y: rect.maxY - rect.height * 0.15))
        p.addLine(to: CGPoint(x: rect.minX + w * 0.5, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - 4. Running Session Stack (one animated row per running session, grouped by agent)

/// While sessions run, the collapsed island drops below the notch into one row per session: the
/// app-to-agent strike animation, the title and how long the turn has run, then the session's
/// todos. Rows group by agent under a header with that agent's plan windows; past
/// `IslandStackOptions.maxRows` the rest fold into one line.
struct IslandSessionStack: View {
    var model: PrismIslandModel
    let geometry: IslandGeometry
    let screenID: UInt32

    var body: some View {
        let g = geometry
        let groups = model.stackGroups
        let hidden = model.stackHiddenCount
        let paused = model.suspended || model.effectiveMode(for: screenID) != .collapsed

        VStack(spacing: 0) {
            IslandStackBand(model: model, geometry: g)
                .contentShape(Rectangle())
                .onTapGesture { model.expand(by: .click, onScreen: screenID) }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    IslandStackGroupHeader(
                        agent: group.agent,
                        windows: model.stackQuota(for: group.agent),
                        animates: model.animatesStrikes
                    )
                    .transition(stackTransition)

                    ForEach(group.rows) { row in
                        IslandStackRow(model: model, row: row, paused: paused)
                            .transition(stackTransition)
                    }
                }

                if hidden > 0 {
                    IslandStackFoldRow(text: model.strings.text("stack.more", ["count": "\(hidden)"]))
                        .contentShape(Rectangle())
                        .onTapGesture { model.expand(by: .click, onScreen: screenID) }
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, IslandStackMetrics.topPadding)
            .padding(.bottom, IslandStackMetrics.bottomPadding)
            .animation(model.animation(to: .collapsed), value: model.stackBodyHeight)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.islandAccessibilityLabel)
    }

    private var stackTransition: AnyTransition {
        guard model.animatesStrikes else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: -8))
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
        )
    }
}

/// The notch-high top of the stack: the app's mark on the left wing, the running count and the
/// live speed on the right.
private struct IslandStackBand: View {
    var model: PrismIslandModel
    let geometry: IslandGeometry

    var body: some View {
        let count = model.stackRunningRows.count
        HStack(spacing: 0) {
            SartoEmblem(size: 16, active: true)
                .padding(.leading, 16)

            Spacer(minLength: 8)
            Color.clear.frame(width: geometry.hasNotch ? geometry.notchWidth : 0)
            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Circle()
                    .fill(IslandTheme.running)
                    .frame(width: 6, height: 6)
                    .modifier(IslandBreathing(active: model.animatesStrikes))
                Text(model.strings.text("summary.running", ["count": "\(count)"]))
                    .font(IslandFonts.ui(11.5, .semibold))
                    .foregroundStyle(IslandTheme.quote)
                    .contentTransition(.numericText())
                    .animation(model.animation(to: .collapsed), value: count)
                if let tps = model.telemetry?.tps, tps > 0 {
                    Text(String(format: "%.0f tok/s", tps))
                        .font(IslandFonts.mono(10.5, .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [IslandTheme.prismCobalt, IslandTheme.prismIris],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                }
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.trailing, 16)
        }
        .frame(height: geometry.notchHeight)
    }
}

/// An agent's mark and name, with what is left of its plan windows.
private struct IslandStackGroupHeader: View {
    let agent: IslandAgentIdentity
    let windows: [IslandQuotaWindow]
    let animates: Bool

    var body: some View {
        HStack(spacing: 6) {
            IslandMarkView(agent: agent, size: 13)
            Text(agent.name)
                .font(IslandFonts.ui(11, .semibold))
                .foregroundStyle(IslandTheme.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 10) {
                ForEach(windows) { window in
                    IslandQuotaMeter(window: window, animates: animates)
                }
            }
        }
        .frame(height: IslandStackMetrics.groupHeader)
    }
}

private struct IslandQuotaMeter: View {
    let window: IslandQuotaWindow
    let animates: Bool

    private var tint: Color {
        if window.remaining <= 0.1 { return IslandTheme.danger }
        if window.remaining <= 0.3 { return IslandTheme.warning }
        return IslandTheme.prismCobalt
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(window.label)
                .font(IslandFonts.ui(10, .medium))
                .foregroundStyle(IslandTheme.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 74, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(IslandTheme.track)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, 34 * window.remaining))
            }
            .frame(width: 34, height: 4)
            .animation(animates ? .spring(response: 0.5, dampingFraction: 0.9) : nil, value: window.remaining)
            Text("\(Int((window.remaining * 100).rounded()))%")
                .font(IslandFonts.mono(10, .semibold))
                .foregroundStyle(window.remaining <= 0.3 ? tint : IslandTheme.quote)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .fixedSize()
    }
}

/// The app-to-agent strike animation across the full width, with the session's title centred on
/// a band of the island's black the pixel streams fade into. The island's stack and the window's
/// running sessions rail both show a session this way.
struct IslandStrikeLane: View {
    var model: PrismIslandModel
    let row: IslandRowItem
    let paused: Bool
    var showsElapsed = true

    var body: some View {
        let tps = model.telemetry?.sessionId == row.sessionId ? model.telemetry?.tps : nil
        let title = model.title(of: row)

        ZStack {
            IslandPixelStrikeStage(
                agents: [row.agent],
                tps: tps,
                runningCount: 1,
                notchGapWidth: 0,
                leftWingWidth: 0,
                paused: paused,
                reduceMotion: !model.animatesStrikes,
                framesPerSecond: model.stackOptions.motion.framesPerSecond
            )

            HStack(spacing: 7) {
                Text(title)
                    .font(IslandFonts.ui(12.5, .medium))
                    .foregroundStyle(IslandTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                if showsElapsed, let since = row.turnStartedAt ?? row.since {
                    IslandTurnDurationLabel(sinceMs: since, strings: model.strings, paused: paused)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: IslandTheme.surface.opacity(0), location: 0),
                        .init(color: IslandTheme.surface.opacity(0.94), location: 0.22),
                        .init(color: IslandTheme.surface.opacity(0.94), location: 0.78),
                        .init(color: IslandTheme.surface.opacity(0), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(maxWidth: IslandStackMetrics.titleWidth)
            .animation(model.animatesStrikes ? .easeInOut(duration: 0.3) : nil, value: title)
        }
    }
}

/// One running session in one line: the strike animation runs the row's full width between the
/// app on the left and its agent on the right, and the title sits in the middle on a band of the
/// island's black that the pixel streams fade into.
private struct IslandStackRow: View {
    var model: PrismIslandModel
    let row: IslandRowItem
    let paused: Bool

    @State private var hovered = false

    var body: some View {
        let title = model.title(of: row)
        IslandStrikeLane(model: model, row: row, paused: paused)
        .frame(height: IslandStackMetrics.row)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovered ? IslandTheme.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { model.openRow(row.key) }
        .help(row.project.isEmpty ? title : "\(title) · \(row.project)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

private struct IslandStackFoldRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(IslandFonts.ui(11, .medium))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(IslandTheme.secondary)
        .padding(.leading, 4)
        .frame(height: IslandStackMetrics.foldRow)
    }
}

/// Self-contained leaf view that ticks collapsed running minutes without a global 1Hz model timer.
private struct IslandRunningElapsedLabel: View {
    let sinceMs: Double
    let strings: IslandStrings
    let paused: Bool

    var body: some View {
        if paused {
            Text(format(at: Date())).monospacedDigit()
        } else {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                Text(format(at: context.date)).monospacedDigit()
            }
        }
    }

    private func format(at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince1970 - sinceMs / 1000) / 60)
        if minutes < 60 { return strings.text("fact.minutes", ["m": "\(minutes)"]) }
        return strings.text("fact.hoursMinutes", ["h": "\(minutes / 60)", "m": "\(minutes % 60)"])
    }
}

/// Self-contained leaf view for `IslandStrikeLane` elapsed duration: 1s ticks under a minute,
/// then 15s ticks once it displays minutes, paused whenever the lane is suspended or hidden.
private struct IslandTurnDurationLabel: View {
    let sinceMs: Double
    let strings: IslandStrings
    let paused: Bool

    var body: some View {
        let underOneMinute = (Date().timeIntervalSince1970 - sinceMs / 1000) < 60
        if paused {
            label(at: Date())
        } else {
            TimelineView(.periodic(from: .now, by: underOneMinute ? 1 : 15)) { context in
                label(at: context.date)
            }
        }
    }

    private func label(at date: Date) -> some View {
        let seconds = max(0, Int(date.timeIntervalSince1970 - sinceMs / 1000))
        let text: String
        if seconds < 60 {
            text = strings.text("duration.seconds", ["s": "\(seconds)"])
        } else {
            let minutes = seconds / 60
            if minutes < 60 {
                text = strings.text("duration.minutes", ["m": "\(minutes)"])
            } else if minutes < 24 * 60 {
                text = strings.text("duration.hoursMinutes", ["h": "\(minutes / 60)", "m": "\(minutes % 60)"])
            } else {
                text = strings.text("duration.days", ["d": "\(minutes / (24 * 60))"])
            }
        }
        return Text(text)
            .font(IslandFonts.mono(10, .medium))
            .foregroundStyle(IslandTheme.secondary)
            .monospacedDigit()
            .fixedSize()
    }
}

/// A slow scale-and-fade breath for a live dot; still with reduce motion or the still style.
private struct IslandBreathing: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && phase ? 1.35 : 1)
            .opacity(active && phase ? 0.55 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = true }
            }
            .onChange(of: active) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = true }
                } else {
                    phase = false
                }
            }
    }
}
