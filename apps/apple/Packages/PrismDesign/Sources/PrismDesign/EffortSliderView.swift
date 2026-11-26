import MetalKit
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Multi-level reasoning effort tiers matching Obsidian Prism's Effort Slider + Auto Orchestrator.
public enum ReasoningEffortLevel: Int, CaseIterable, Identifiable, Codable, Sendable {
    case auto = -1
    case low = 0
    case medium = 1
    case high = 2
    case extra = 3

    public var id: Int { rawValue }

    public static let manualLevels: [ReasoningEffortLevel] = [.low, .medium, .high, .extra]

    public var label: String {
        switch self {
        case .auto: return "Auto"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .extra: return "Extra"
        }
    }

    public func localizedTitle(_ l10n: PrismL10n) -> String {
        switch self {
        case .auto: return l10n.tr("effort.auto")
        case .low: return l10n.tr("effort.low")
        case .medium: return l10n.tr("effort.medium")
        case .high: return l10n.tr("effort.high")
        case .extra: return l10n.tr("effort.extra")
        }
    }

    public var localizedLabel: String {
        localizedTitle(PrismL10n(language: PrismLanguage.loadSaved()))
    }

    public var energy: Double {
        switch self {
        case .auto: return 1.0
        case .low: return 0.05
        case .medium: return 0.45
        case .high: return 0.82
        case .extra: return 1.0
        }
    }

    public var progress: Double {
        switch self {
        case .auto: return 1.0
        case .low: return 0.0
        case .medium: return 1.0 / 3.0
        case .high: return 2.0 / 3.0
        case .extra: return 1.0
        }
    }

    public static func fromManualProgress(_ pct: Double) -> ReasoningEffortLevel {
        let clamped = max(0.0, min(1.0, pct.isFinite ? pct : 0.0))
        let idx = Int(round(clamped * 3.0))
        return ReasoningEffortLevel(rawValue: max(0, min(3, idx))) ?? .high
    }
}

public typealias EffortLevel = ReasoningEffortLevel

public enum EffortSliderStyle: String, CaseIterable, Sendable {
    case starfield
    case cutCrystal
}

/// Drives smooth ~0.5s `crystalWake` decay (`1.0 -> 0.0`) inside the Metal `draw(in:)` tick
/// without mutating SwiftUI `@State` per frame, pausing `MTKView` once settled at `0`.
@MainActor
final class EffortCrystalWakeState {
    static let decayDuration: Float = 0.50

    var crystalWake: Float = 0
    var wakeSweep: Float = 0
    var isInteracting: Bool = false
    weak var attachedView: MTKView?

    func trigger(motionActive: Bool) {
        guard motionActive else {
            crystalWake = 0
            wakeSweep = 0
            return
        }
        crystalWake = 1.0
        wakeSweep = 0.0
        resumeViewIfVisible()
    }

    func setInteracting(_ active: Bool, motionActive: Bool) {
        isInteracting = active
        if active && motionActive {
            crystalWake = max(crystalWake, 0.55)
            resumeViewIfVisible()
        }
    }

    func step(dt: Double) -> Bool {
        if crystalWake > 0, dt.isFinite, dt > 0 {
            let delta = Float(dt) / Self.decayDuration
            crystalWake = max(0, crystalWake - delta)
            wakeSweep = (1.0 - crystalWake) * 1.15
        }
        return !isInteracting && crystalWake <= 0.001
    }

    private func resumeViewIfVisible() {
        guard let view = attachedView else { return }
        #if os(macOS)
        guard let win = view.window, win.isVisible, win.occlusionState.contains(.visible) else { return }
        #elseif os(iOS)
        guard view.window != nil, UIApplication.shared.applicationState != .background else { return }
        #endif
        let conditions = PrismEnergyMonitor.shared.conditions
        let maxFPS = PrismEnergyPolicy.framesPerSecond(
            for: .interactive,
            surface: .widget,
            displayMaxFPS: 120,
            conditions: conditions
        )
        guard maxFPS > 0 else {
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.setNeedsDisplay(view.bounds)
            return
        }
        view.preferredFramesPerSecond = maxFPS
        view.enableSetNeedsDisplay = false
        view.isPaused = false
    }
}

/// Obsidian Prism Optical Reasoning Effort Slider.
/// Powered by GPU Metal `pk_cut_crystal_frag` and `pk_starfield_track_frag` with a clean SwiftUI capsule fallback.
public struct EffortSliderView: View {
    /// Horizontal track inset matching the 28pt capsule cap radius (`14pt` on each end).
    public static let trackHorizontalInset: CGFloat = 14

    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismL10n) private var l10n
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding public var level: ReasoningEffortLevel
    public var style: EffortSliderStyle
    public var showHeader: Bool
    public var allowsAuto: Bool

    @State private var dragProgress: Double?
    /// Detent shown while dragging; `level` is written once, when the drag ends.
    @State private var dragLevel: ReasoningEffortLevel?
    @State private var dragAxis: DragAxis?
    @State private var pointerPos: CGPoint = CGPoint(x: -9999, y: -9999)
    @State private var proximity: Double = 0
    @State private var isHovering = false
    @State private var wakeSettled = false
    @State private var wakeState = EffortCrystalWakeState()

    public init(
        level: Binding<ReasoningEffortLevel>,
        style: EffortSliderStyle = .starfield,
        showHeader: Bool = true,
        allowsAuto: Bool = true
    ) {
        self._level = level
        self.style = style
        self.showHeader = showHeader
        self.allowsAuto = allowsAuto
    }

    public static func normalizedProgress(
        for locationX: CGFloat,
        width: CGFloat,
        pad: CGFloat = trackHorizontalInset
    ) -> Double {
        let usableWidth = max(1, width - pad * 2)
        let raw = Double((locationX - pad) / usableWidth)
        guard raw.isFinite else { return 0 }
        return max(0.0, min(1.0, raw))
    }

    private enum DragAxis {
        case horizontal
        case vertical
    }

    /// Movement before the track claims a drag, so taps reach the tap gesture and a vertical swipe can scroll.
    private static let dragActivationDistance: CGFloat = 4

    private var displayLevel: ReasoningEffortLevel {
        dragLevel ?? level
    }

    private var activeManualProgress: Double {
        dragProgress ?? displayLevel.progress
    }

    public var body: some View {
        let metalAvailable = PrismMetalEngine.shared.isReady
        let useMetal = metalAvailable && motionTier != .off
        let motionActive = useMetal && !reduceMotion
        let shouldAnimate = motionActive && (!wakeSettled || isHovering || dragProgress != nil)
        let shown = displayLevel

        VStack(alignment: .leading, spacing: 8) {
            if showHeader {
                HStack(spacing: 8) {
                    Text(l10n.tr("effort.title"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(tokens.secondaryForeground)

                    Spacer()

                    if allowsAuto {
                        Button {
                            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                level = (level == .auto) ? .high : .auto
                            }
                            triggerWake(motionActive: motionActive)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: shown == .auto ? "sparkles" : "slider.horizontal.3")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(shown == .auto ? l10n.tr("effort.autoOrchestrator") : shown.localizedTitle(l10n))
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(badgeForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(badgeBackground))
                            .overlay(Capsule().strokeBorder(badgeBorder, lineWidth: 0.75))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(level == .auto ? .isSelected : [])
                    } else {
                        Text(shown.localizedTitle(l10n))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(badgeForeground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(badgeBackground))
                            .overlay(Capsule().strokeBorder(badgeBorder, lineWidth: 0.75))
                    }
                }
            }

            GeometryReader { geo in
                let w = max(geo.size.width, 60)
                let h: CGFloat = 28
                let pad = Self.trackHorizontalInset
                let usableWidth = max(1, w - pad * 2)
                let shaderFillFraction = Double(pad + usableWidth * activeManualProgress) / Double(w)

                ZStack(alignment: .leading) {
                    if !useMetal {
                        swiftUIFallbackTrack(width: w, height: h)
                        if shown != .auto {
                            detentDots(width: w, height: h)
                            orbThumb(width: w, height: h, crystalStyle: style == .cutCrystal)
                        }
                    } else if shown == .auto {
                        PrismMetalView(
                            kind: .cutCrystal,
                            uniforms: PrismUniforms(
                                size: CGSize(width: w, height: h),
                                isDark: tokens.palette.isDark,
                                pointer: pointerPos,
                                pointerAlpha: Float(proximity),
                                accent: tokens.shaderAccentCode,
                                params: SIMD4(
                                    motionActive ? 0.0 : 1.0,
                                    1.0,
                                    wakeState.wakeSweep,
                                    wakeState.crystalWake
                                )
                            ),
                            isAnimating: shouldAnimate,
                            preferredFPS: 0,
                            onDrawTick: { dt, coord, view in
                                tickCrystalWake(dt: dt, coord: coord, view: view)
                            }
                        )
                    } else if style == .cutCrystal {
                        let modeVal = Float((motionActive ? 2.0 : 4.0) + shaderFillFraction)
                        PrismMetalView(
                            kind: .cutCrystal,
                            uniforms: PrismUniforms(
                                size: CGSize(width: w, height: h),
                                isDark: tokens.palette.isDark,
                                pointer: pointerPos,
                                pointerAlpha: Float(proximity),
                                accent: tokens.shaderAccentCode,
                                params: SIMD4(
                                    modeVal,
                                    1.0,
                                    wakeState.wakeSweep,
                                    wakeState.crystalWake
                                )
                            ),
                            isAnimating: shouldAnimate,
                            preferredFPS: 0,
                            onDrawTick: { dt, coord, view in
                                tickCrystalWake(dt: dt, coord: coord, view: view)
                            }
                        )
                        detentDots(width: w, height: h)
                        orbThumb(width: w, height: h, crystalStyle: true)
                    } else {
                        let filledEdge = max(Double(pad) / Double(w), shaderFillFraction)
                        PrismMetalView(
                            kind: .starfieldTrack,
                            uniforms: PrismUniforms(
                                size: CGSize(width: w, height: h),
                                isDark: tokens.palette.isDark,
                                accent: tokens.shaderAccentCode,
                                params: SIMD4(Float(filledEdge), Float(shown.energy), wakeState.crystalWake, 0)
                            ),
                            isAnimating: shouldAnimate,
                            preferredFPS: 0,
                            onDrawTick: { dt, coord, view in
                                wakeState.attachedView = view
                                let settled = wakeState.step(dt: dt)
                                coord.uniforms.params.z = wakeState.crystalWake
                                if settled && !wakeSettled {
                                    view.enableSetNeedsDisplay = true
                                    view.isPaused = true
                                    Task { @MainActor in
                                        wakeSettled = true
                                    }
                                }
                            }
                        )
                        detentDots(width: w, height: h)
                        orbThumb(width: w, height: h, crystalStyle: false)
                    }
                }
                .frame(width: w, height: h)
                .shadow(
                    color: shown == .extra || shown == .high
                        ? tokens.prismIris.opacity(tokens.palette.isDark ? 0.34 : 0.18)
                        : Color.clear,
                    radius: shown == .extra ? 12 : 6,
                    y: 2
                )
                .contentShape(Capsule())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        pointerPos = loc
                        if !isHovering {
                            isHovering = true
                            proximity = 1.0
                            wakeState.setInteracting(true, motionActive: motionActive)
                            triggerWake(motionActive: motionActive)
                        }
                    case .ended:
                        isHovering = false
                        proximity = 0.0
                        pointerPos = CGPoint(x: -9999, y: -9999)
                        wakeState.setInteracting(dragProgress != nil, motionActive: motionActive)
                    }
                }
                .gesture(
                    trackDragGesture(width: w, pad: pad, motionActive: motionActive)
                        .exclusively(before: trackTapGesture(width: w, pad: pad, motionActive: motionActive))
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(l10n.tr("effort.title"))
                .accessibilityValue(level == .auto ? l10n.tr("effort.autoOrchestrator") : level.localizedTitle(l10n))
                .accessibilityAdjustableAction { direction in
                    adjustForAccessibility(direction, motionActive: motionActive)
                }
            }
            .frame(height: 28)

            HStack(spacing: 0) {
                ForEach(ReasoningEffortLevel.manualLevels) { tier in
                    let isSelected = displayLevel == tier
                    Button {
                        if level != tier {
                            withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                                level = tier
                            }
                        }
                        triggerWake(motionActive: motionActive)
                    } label: {
                        Text(tier.localizedTitle(l10n))
                            .font(.system(size: 10, weight: isSelected ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(isSelected ? tierTextColor(tier) : tokens.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: labelAlignment(tier))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .onChange(of: style) { _, _ in
            triggerWake(motionActive: motionActive)
        }
        .onAppear {
            triggerWake(motionActive: motionActive)
        }
    }

    private func trackDragGesture(width w: CGFloat, pad: CGFloat, motionActive: Bool) -> some Gesture {
        DragGesture(minimumDistance: Self.dragActivationDistance)
            .onChanged { value in
                if dragAxis == nil {
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    dragAxis = dx >= dy ? .horizontal : .vertical
                }
                guard dragAxis == .horizontal else { return }
                pointerPos = value.location
                proximity = 1.0
                wakeState.setInteracting(true, motionActive: motionActive)
                let pct = Self.normalizedProgress(for: value.location.x, width: w, pad: pad)
                let current = displayLevel
                if current == .auto {
                    if abs(value.translation.width) > 6 {
                        dragProgress = pct
                        dragLevel = ReasoningEffortLevel.fromManualProgress(pct)
                        triggerWake(motionActive: motionActive)
                    }
                    return
                }
                dragProgress = pct
                let next = detentTarget(current: current, pointerPct: pct)
                if next != current {
                    dragLevel = next
                    triggerWake(motionActive: motionActive)
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                guard axis == .horizontal else { return }
                wakeState.setInteracting(isHovering, motionActive: motionActive)
                if dragLevel == nil && level == .auto {
                    dragProgress = nil
                    triggerWake(motionActive: motionActive)
                    return
                }
                let pct = Self.normalizedProgress(for: value.location.x, width: w, pad: pad)
                let next = ReasoningEffortLevel.fromManualProgress(pct)
                withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                    if next != level {
                        level = next
                    }
                    dragLevel = nil
                    dragProgress = nil
                }
                triggerWake(motionActive: motionActive)
            }
    }

    private func trackTapGesture(width w: CGFloat, pad: CGFloat, motionActive: Bool) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard level != .auto else {
                    triggerWake(motionActive: motionActive)
                    return
                }
                let pct = Self.normalizedProgress(for: value.location.x, width: w, pad: pad)
                let next = ReasoningEffortLevel.fromManualProgress(pct)
                if next != level {
                    withAnimation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion)) {
                        level = next
                    }
                }
                triggerWake(motionActive: motionActive)
            }
    }

    private func adjustForAccessibility(_ direction: AccessibilityAdjustmentDirection, motionActive: Bool) {
        let next: ReasoningEffortLevel
        switch direction {
        case .increment:
            next = level == .auto ? .high : ReasoningEffortLevel(rawValue: min(3, level.rawValue + 1)) ?? level
        case .decrement:
            next = level == .auto ? .high : ReasoningEffortLevel(rawValue: max(0, level.rawValue - 1)) ?? level
        @unknown default:
            return
        }
        guard next != level else { return }
        level = next
        triggerWake(motionActive: motionActive)
    }

    private func tickCrystalWake(dt: Double, coord: PrismMetalCoordinator, view: MTKView) {
        wakeState.attachedView = view
        let settled = wakeState.step(dt: dt)
        coord.uniforms.params.z = wakeState.wakeSweep
        coord.uniforms.params.w = wakeState.crystalWake
        coord.uniforms.pointerAccent.z = max(Float(proximity), wakeState.crystalWake * 0.65)
        if settled && !wakeSettled {
            view.enableSetNeedsDisplay = true
            view.isPaused = true
            Task { @MainActor in
                wakeSettled = true
            }
        }
    }

    private func swiftUIFallbackTrack(width: CGFloat, height: CGFloat) -> some View {
        let pad = Self.trackHorizontalInset
        let usableWidth = max(1, width - pad * 2)
        let fillWidth: CGFloat = displayLevel == .auto
            ? width
            : min(width, max(height, pad + usableWidth * activeManualProgress + pad))

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(tokens.surface2)
                .overlay(Capsule().strokeBorder(tokens.border, lineWidth: 1))

            Capsule()
                .fill(
                    LinearGradient(
                        colors: displayLevel == .auto
                            ? [tokens.prismCobalt.opacity(0.32), tokens.prismIris.opacity(0.28)]
                            : [tokens.prismCobalt.opacity(0.75), tokens.prismIris.opacity(0.82)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: fillWidth, height: height)

            if displayLevel == .auto {
                HStack {
                    Spacer()
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tokens.secondaryForeground.opacity(0.72))
                        .padding(.trailing, 11)
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private func detentDots(width: CGFloat, height: CGFloat) -> some View {
        let pad = Self.trackHorizontalInset
        let usableWidth = max(1, width - pad * 2)
        return ZStack {
            ForEach(0..<4, id: \.self) { idx in
                let p = Double(idx) / 3.0
                let reached = p <= activeManualProgress + 0.02
                Circle()
                    .fill(reached ? Color.white.opacity(0.88) : tokens.mutedForeground.opacity(0.38))
                    .frame(width: 4, height: 4)
                    .position(x: pad + usableWidth * p, y: height * 0.5)
            }
        }
        .allowsHitTesting(false)
    }

    private func orbThumb(width: CGFloat, height: CGFloat, crystalStyle: Bool) -> some View {
        let knobSize: CGFloat = 24
        let pad = Self.trackHorizontalInset
        let usableWidth = max(1, width - pad * 2)
        let x = pad + usableWidth * activeManualProgress

        return Circle()
            .fill(
                RadialGradient(
                    colors: crystalStyle
                        ? [Color.white, Color(hex: 0xDCE6F5), Color(hex: 0x9BB0CE)]
                        : [Color.white, Color(hex: 0xF3F0FF), Color(hex: 0xD8CEF8)],
                    center: UnitPoint(x: 0.36, y: 0.32),
                    startRadius: 1,
                    endRadius: knobSize * 0.65
                )
            )
            .frame(width: knobSize, height: knobSize)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
            .shadow(
                color: (displayLevel == .extra || displayLevel == .high)
                    ? tokens.prismIris.opacity(0.62)
                    : Color.black.opacity(0.38),
                radius: dragProgress != nil ? 9 : 6,
                y: 1.5
            )
            .scaleEffect(dragProgress != nil ? 1.07 : 1.0)
            .position(x: x, y: height * 0.5)
            .allowsHitTesting(false)
    }

    private func detentTarget(current: ReasoningEffortLevel, pointerPct: Double) -> ReasoningEffortLevel {
        let curIdx = max(0, min(3, current.rawValue))
        let step = 1.0 / 3.0
        let forward = 1.0 / 3.0
        var idx = curIdx
        let center = Double(idx) * step
        if pointerPct >= center {
            while idx < 3 && pointerPct >= (Double(idx) + forward) * step - 1e-6 { idx += 1 }
        } else {
            while idx > 0 && pointerPct <= (Double(idx) - forward) * step + 1e-6 { idx -= 1 }
        }
        return ReasoningEffortLevel(rawValue: idx) ?? current
    }

    private func triggerWake(motionActive: Bool) {
        guard motionActive else {
            wakeState.trigger(motionActive: false)
            wakeSettled = true
            return
        }
        wakeSettled = false
        wakeState.trigger(motionActive: true)
    }

    private func labelAlignment(_ tier: ReasoningEffortLevel) -> Alignment {
        switch tier {
        case .low: return .leading
        case .extra: return .trailing
        default: return .center
        }
    }

    private func tierTextColor(_ tier: ReasoningEffortLevel) -> Color {
        switch tier {
        case .auto, .low: return tokens.prismCobalt
        case .medium, .high: return tokens.prismIris
        case .extra: return Color(hex: 0xB392FF)
        }
    }

    private var badgeForeground: Color {
        switch displayLevel {
        case .auto: return tokens.palette.isDark ? Color(hex: 0xC4D2EC) : Color(hex: 0x365284)
        case .extra, .high: return tokens.palette.isDark ? Color(hex: 0xB392FF) : Color(hex: 0x6D28D9)
        default: return tokens.primary
        }
    }

    private var badgeBackground: Color {
        switch displayLevel {
        case .auto: return tokens.prismCobalt.opacity(0.14)
        case .extra, .high: return tokens.prismIris.opacity(0.16)
        default: return tokens.primarySoft
        }
    }

    private var badgeBorder: Color {
        switch displayLevel {
        case .auto: return tokens.prismCobalt.opacity(0.32)
        case .extra, .high: return tokens.prismIris.opacity(0.36)
        default: return tokens.primaryBorder
        }
    }
}
