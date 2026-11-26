import QuartzCore
import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Execution phase for the 3x3 animated turn dots.
public enum PrismTurnPhase: String, Sendable, Equatable {
    case thinking
    case execute
    case read
    case search
    case fetch
    case edit
    case writing
    case compacting
    case working
    case waiting
}

/// Sarto's signature 3x3 9-dot phase indicator.
/// Core Animation keyframes sampled from `dotOpacity` run in the render server and follow the
/// media clock, so streaming re-renders neither cost a SwiftUI frame nor reset the phase.
public struct PrismTurnDotsView: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let phase: PrismTurnPhase
    public let size: CGFloat
    public let tint: Color?

    public init(phase: PrismTurnPhase, size: CGFloat = 12, tint: Color? = nil) {
        self.phase = phase
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        let color = tint ?? (phase == .waiting ? tokens.warning : tokens.primary)
        let animate = !(reduceMotion || motionTier == .off)

        Group {
            if phase == .waiting {
                // Steady attention dot with soft halo.
                ZStack {
                    Circle()
                        .fill(color.opacity(0.22))
                        .frame(width: size, height: size)
                    Circle()
                        .fill(color)
                        .frame(width: size * 0.56, height: size * 0.56)
                }
            } else {
                PrismDotLayerView(content: .turn(phase), color: color, animate: animate)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Seconds per loop of each phase's pattern, as in turn-dot-patterns.ts.
    public nonisolated static func period(for phase: PrismTurnPhase) -> Double {
        switch phase {
        case .thinking: return 2.0
        case .execute, .working: return 0.96
        case .read: return 1.5
        case .search: return 1.6
        case .edit: return 1.4
        case .fetch, .compacting: return 1.2
        case .writing: return 1.8
        case .waiting: return 1.0
        }
    }

    // MARK: - Exact Port of `src/renderer/src/features/session/turn-dot-patterns.ts`

    private nonisolated static let ringOrder: [Int] = [0, 1, 2, 7, -1, 3, 6, 5, 4]
    private nonisolated static let twinkleOffsets: [Double] = [0, 0.53, 0.21, 0.78, 0.37, 0.91, 0.12, 0.66, 0.45]

    public nonisolated static func dotOpacity(phase: PrismTurnPhase, x: Int, y: Int, time: Double) -> Double {
        let idx = y * 3 + x
        let fx = Double(x)
        let fy = Double(y)

        switch phase {
        case .thinking:
            let offset = (1.0 - twinkleOffsets[idx]).truncatingRemainder(dividingBy: 1.0)
            return evalTwinkle(unitPhase(time: time, period: 2.0, offset: offset))

        case .execute, .working:
            let place = ringOrder[idx]
            if place < 0 { return 0.22 }
            return evalTrail(unitPhase(time: time, period: 0.96, offset: Double(place) / 8.0))

        case .read:
            let offset = (fy * 1.2 + fx * 0.3) / 3.6
            return evalTrail(unitPhase(time: time, period: 1.5, offset: offset))

        case .search:
            if x == 1 {
                return evalSweepMid(unitPhase(time: time, period: 1.6, offset: 0.0))
            }
            return evalSweepEdge(unitPhase(time: time, period: 1.6, offset: fx / 4.0))

        case .edit:
            let offset = ((x + y) % 2 != 0) ? 0.5 : 0.0
            return evalSwap(unitPhase(time: time, period: 1.4, offset: offset))

        case .fetch:
            let dist = hypot(fx - 1.0, fy - 1.0)
            return evalTrail(unitPhase(time: time, period: 1.2, offset: dist / 2.6))

        case .compacting:
            let dist = hypot(fx - 1.0, fy - 1.0)
            return evalTrail(unitPhase(time: time, period: 1.2, offset: (Double(2.0).squareRoot() - dist) / 2.6))

        case .writing:
            return evalFill(unitPhase(time: time, period: 1.8, offset: Double(idx) * 0.05))

        case .waiting:
            return 1.0
        }
    }

    private nonisolated static func unitPhase(time: Double, period: Double, offset: Double) -> Double {
        // Matches negative CSS animation-delay `(at - 1) * period`: shifts phase forward by `1 - offset`.
        let raw = (time / period) + (1.0 - offset)
        return raw - floor(raw)
    }

    private nonisolated static func evalTrail(_ u: Double) -> Double {
        if u <= 0.4 {
            return 1.0 - (u / 0.4) * 0.78
        }
        return 0.22
    }

    private nonisolated static func evalTwinkle(_ u: Double) -> Double {
        if u <= 0.15 {
            let t = smoothstep(u / 0.15)
            return 0.22 + 0.78 * t
        }
        if u <= 0.30 {
            let t = smoothstep((u - 0.15) / 0.15)
            return 1.0 - 0.78 * t
        }
        return 0.22
    }

    private nonisolated static func evalSwap(_ u: Double) -> Double {
        let wave = 0.5 - 0.5 * cos(u * 2.0 * .pi)
        return 0.22 + 0.78 * wave
    }

    private nonisolated static func evalSweepEdge(_ u: Double) -> Double {
        if u < 0.125 { return lerp(1.0, 0.74, u / 0.125) }
        if u < 0.25 { return lerp(0.74, 0.22, (u - 0.125) / 0.125) }
        if u <= 0.75 { return 0.22 }
        if u < 0.875 { return lerp(0.22, 0.74, (u - 0.75) / 0.125) }
        return lerp(0.74, 1.0, (u - 0.875) / 0.125)
    }

    private nonisolated static func evalSweepMid(_ u: Double) -> Double {
        let local = (u * 2.0) - floor(u * 2.0)
        if local < 0.25 { return lerp(0.22, 0.36, local / 0.25) }
        if local < 0.50 { return lerp(0.36, 1.0, (local - 0.25) / 0.25) }
        if local < 0.75 { return lerp(1.0, 0.36, (local - 0.50) / 0.25) }
        return lerp(0.36, 0.22, (local - 0.75) / 0.25)
    }

    private nonisolated static func evalFill(_ u: Double) -> Double {
        if u <= 0.55 { return 1.0 }
        if u <= 0.62 { return lerp(1.0, 0.22, (u - 0.55) / 0.07) }
        return 0.22
    }

    private nonisolated static func smoothstep(_ t: Double) -> Double {
        let c = max(0.0, min(1.0, t))
        return c * c * (3.0 - 2.0 * c)
    }

    private nonisolated static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * max(0.0, min(1.0, t))
    }
}

/// Calm single breathing dot for an active step inside an expanded tool run.
/// Fits the exact 14x14pt icon slot so completing a step never causes horizontal shift.
public struct PrismStepPulseDot: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let size: CGFloat

    public init(size: CGFloat = 14) {
        self.size = size
    }

    public var body: some View {
        PrismDotLayerView(content: .pulse, color: tokens.primary, animate: !(reduceMotion || motionTier == .off))
            .frame(width: size, height: size)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    nonisolated static let period = 2.0 * Double.pi / 3.6

    /// Breathing level 0...1 at `time`; 0.65 is the resting level shown without motion.
    nonisolated static func pulse(time: Double) -> Double {
        0.5 + 0.5 * sin(time * 3.6)
    }
}

// MARK: - Core Animation Dot Layers

enum PrismDotLayerContent: Equatable {
    case turn(PrismTurnPhase)
    case pulse
}

/// Lays out and animates the dots of `PrismTurnDotsView` and `PrismStepPulseDot` as plain layers.
@MainActor
final class PrismDotLayerRenderer {
    private static let samplesPerLoop = 48
    private static let animationKey = "pk.dot.opacity"

    let root = CALayer()
    private var dots: [CALayer] = []
    private var content: PrismDotLayerContent?
    private var animate = false
    private var color: CGColor?
    private var laidOutSize: CGSize = .zero

    func configure(content: PrismDotLayerContent, color: CGColor, animate: Bool, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let contentChanged = self.content != content
        if contentChanged {
            dots.forEach { $0.removeFromSuperlayer() }
            let count = content == .pulse ? 2 : 9
            dots = (0..<count).map { _ in CALayer() }
            dots.forEach(root.addSublayer)
            self.content = content
            laidOutSize = .zero
            self.color = nil
        }
        if self.color != color {
            self.color = color
            for dot in dots { dot.backgroundColor = color }
        }
        if size != laidOutSize, size.width > 0, size.height > 0 {
            laidOutSize = size
            layout(content: content, size: size)
        }
        if contentChanged || self.animate != animate || (animate && dots.first?.animation(forKey: Self.animationKey) == nil) {
            self.animate = animate
            applyOpacity(content: content, animate: animate)
        }
    }

    private func layout(content: PrismDotLayerContent, size: CGSize) {
        root.frame = CGRect(origin: .zero, size: size)
        switch content {
        case .turn:
            let side = min(size.width, size.height)
            let scale = side / 12.0
            let radius = 1.35 * scale
            let originX = (size.width - side) / 2
            let originY = (size.height - side) / 2
            for (index, dot) in dots.enumerated() {
                let cx = originX + (2.0 + CGFloat(index % 3) * 4.0) * scale
                let cy = originY + (2.0 + CGFloat(index / 3) * 4.0) * scale
                dot.frame = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
                dot.cornerRadius = radius
            }
        case .pulse:
            for (dot, diameter) in zip(dots, [11.0, 5.5] as [CGFloat]) {
                dot.frame = CGRect(
                    x: (size.width - diameter) / 2,
                    y: (size.height - diameter) / 2,
                    width: diameter,
                    height: diameter
                )
                dot.cornerRadius = diameter / 2
            }
        }
    }

    private func applyOpacity(content: PrismDotLayerContent, animate: Bool) {
        let period: Double
        let opacityAt: (Int, Double) -> Double
        switch content {
        case .turn(let phase):
            period = PrismTurnDotsView.period(for: phase)
            opacityAt = { index, time in
                PrismTurnDotsView.dotOpacity(phase: phase, x: index % 3, y: index / 3, time: time)
            }
        case .pulse:
            period = PrismStepPulseDot.period
            opacityAt = { index, time in
                let pulse = animate ? PrismStepPulseDot.pulse(time: time) : 0.65
                return index == 0 ? 0.14 + 0.16 * pulse : 0.75 + 0.25 * pulse
            }
        }

        // Every dot starts at the media clock's position in its loop, so all indicators on screen
        // breathe in step however late each one was added.
        let clockOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
        let keyTimes = (0...Self.samplesPerLoop).map { NSNumber(value: Double($0) / Double(Self.samplesPerLoop)) }
        for (index, dot) in dots.enumerated() {
            dot.removeAnimation(forKey: Self.animationKey)
            guard animate else {
                dot.opacity = Float(opacityAt(index, 0))
                continue
            }
            let values = keyTimes.map { opacityAt(index, $0.doubleValue * period) }
            dot.opacity = Float(values[0])
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = values
            animation.keyTimes = keyTimes
            animation.calculationMode = .linear
            animation.duration = period
            animation.repeatCount = .infinity
            animation.timeOffset = clockOffset
            animation.isRemovedOnCompletion = false
            dot.add(animation, forKey: Self.animationKey)
        }
    }
}

#if os(macOS)
struct PrismDotLayerView: NSViewRepresentable {
    let content: PrismDotLayerContent
    let color: Color
    let animate: Bool

    func makeNSView(context: Context) -> PrismDotLayerNSView {
        PrismDotLayerNSView()
    }

    func updateNSView(_ nsView: PrismDotLayerNSView, context: Context) {
        nsView.update(content: content, color: color.resolve(in: context.environment).cgColor, animate: animate)
    }
}

@MainActor
final class PrismDotLayerNSView: NSView {
    private let renderer = PrismDotLayerRenderer()
    private var pending: (content: PrismDotLayerContent, color: CGColor, animate: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(renderer.root)
    }

    required init?(coder: NSCoder) { nil }

    // Top-left origin, so row 0 of the 3x3 pattern is the top row as in the web renderer.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        apply()
    }

    override func layout() {
        super.layout()
        apply()
    }

    func update(content: PrismDotLayerContent, color: CGColor, animate: Bool) {
        pending = (content, color, animate)
        apply()
    }

    private func apply() {
        guard let pending else { return }
        renderer.configure(content: pending.content, color: pending.color, animate: pending.animate, size: bounds.size)
    }
}
#elseif os(iOS)
struct PrismDotLayerView: UIViewRepresentable {
    let content: PrismDotLayerContent
    let color: Color
    let animate: Bool

    func makeUIView(context: Context) -> PrismDotLayerUIView {
        PrismDotLayerUIView()
    }

    func updateUIView(_ uiView: PrismDotLayerUIView, context: Context) {
        uiView.update(content: content, color: color.resolve(in: context.environment).cgColor, animate: animate)
    }
}

@MainActor
final class PrismDotLayerUIView: UIView {
    private let renderer = PrismDotLayerRenderer()
    private var pending: (content: PrismDotLayerContent, color: CGColor, animate: Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(renderer.root)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        apply()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }

    func update(content: PrismDotLayerContent, color: CGColor, animate: Bool) {
        pending = (content, color, animate)
        apply()
    }

    private func apply() {
        guard let pending else { return }
        renderer.configure(content: pending.content, color: pending.color, animate: pending.animate, size: bounds.size)
    }
}
#endif
