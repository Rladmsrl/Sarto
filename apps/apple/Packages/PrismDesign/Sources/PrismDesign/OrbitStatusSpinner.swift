import SwiftUI
#if os(macOS)
import AppKit
import QuartzCore
#elseif os(iOS)
import QuartzCore
import UIKit
#endif

/// Animated rainbow breathing left edge bar for running sessions in the sidebar.
/// Driven purely by CoreAnimation `CABasicAnimation(keyPath: "opacity")` with 0% main-thread SwiftUI churn.
public struct PrismRunningRowBar: View {
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        let animate = !reduceMotion && motionTier != .off
        CoreAnimationRainbowBarView(animate: animate)
            .frame(width: 2.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Exact Obsidian Prism 30pt Alabaster Ceramic Send Button & Google 4-Color Orbital Stop Button
/// (v2-components.css lines 2854-2995).
public struct PrismSendStopButton: View {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public let isRunning: Bool
    public let canSend: Bool
    public let onSend: () -> Void
    public let onStop: () -> Void

    @State private var isHovered = false

    public init(
        isRunning: Bool,
        canSend: Bool,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isRunning = isRunning
        self.canSend = canSend
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        let animate = !reduceMotion && motionTier != .off && isRunning
        Button {
            if isRunning {
                onStop()
            } else if canSend {
                onSend()
            }
        } label: {
            ZStack {
                if isRunning {
                    // 4-Color Conic-Gradient Orbital Stop Button (pure CoreAnimation GPU rotation)
                    CoreAnimationConicOrbView(
                        size: 30,
                        lineWidth: 0,
                        filled: true,
                        animate: animate
                    )
                    .frame(width: 30, height: 30)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: 0x1C1E28), Color(hex: 0x101117)],
                                center: .top,
                                startRadius: 1,
                                endRadius: 20
                            )
                        )
                        .frame(width: 26, height: 26)
                    RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                        .fill(Color(hex: 0xF4F5F8))
                        .frame(width: 8.5, height: 8.5)
                        .shadow(color: Color.white.opacity(0.35), radius: 4)
                        .scaleEffect(isHovered ? 1.08 : 1.0)
                } else {
                    // Alabaster Ceramic High-Contrast Send Button
                    let enabled = canSend
                    let bg: Color = {
                        if !enabled {
                            return tokens.palette.isDark
                                ? Color.white.opacity(0.07)
                                : Color(hex: 0x0F172A).opacity(0.06)
                        }
                        return tokens.palette.isDark ? Color(hex: 0xF2F3F7) : Color(hex: 0x14151B)
                    }()
                    let fg: Color = {
                        if !enabled {
                            return tokens.palette.isDark
                                ? Color(hex: 0xF2F3F7).opacity(0.28)
                                : Color(hex: 0x0F172A).opacity(0.28)
                        }
                        return tokens.palette.isDark ? Color(hex: 0x0E0F14) : Color(hex: 0xF8F9FC)
                    }()

                    Circle()
                        .fill(bg)
                        .overlay(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(enabled ? (tokens.palette.isDark ? 0.65 : 0.16) : 0), Color.clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                        )
                        .frame(width: 30, height: 30)
                        .shadow(
                            color: enabled ? Color.black.opacity(tokens.palette.isDark ? 0.42 : 0.22) : .clear,
                            radius: 6,
                            y: 2
                        )

                    Image(systemName: "arrow.up")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(fg)
                }
            }
            .shadow(color: isRunning ? Color(hex: 0x4285F4).opacity(0.42) : .clear, radius: 10)
            .offset(y: isHovered && (canSend || isRunning) ? -1 : 0)
            .animation(PrismSpringSpec.micro.animation(tier: motionTier, reduceMotion: reduceMotion), value: isHovered)
            .animation(PrismSpringSpec.snappy.animation(tier: motionTier, reduceMotion: reduceMotion), value: isRunning)
        }
        .buttonStyle(.plain)
        .disabled(!isRunning && !canSend)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Zero-CPU CoreAnimation GPU Layer Backing

private enum OrbitPaletteColors {
    static let conicCGColors: [CGColor] = [
        CGColor(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0, alpha: 1.0),
        CGColor(red: 0x9B / 255.0, green: 0x72 / 255.0, blue: 0xCB / 255.0, alpha: 1.0),
        CGColor(red: 0xEA / 255.0, green: 0x43 / 255.0, blue: 0x35 / 255.0, alpha: 1.0),
        CGColor(red: 0xFB / 255.0, green: 0xBC / 255.0, blue: 0x04 / 255.0, alpha: 1.0),
        CGColor(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0, alpha: 1.0),
        CGColor(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0, alpha: 1.0),
    ]
    static let conicLocations: [NSNumber] = [0.00, 0.26, 0.51, 0.76, 0.90, 1.00]

    static let barCGColors: [CGColor] = [
        CGColor(red: 0x42 / 255.0, green: 0x85 / 255.0, blue: 0xF4 / 255.0, alpha: 1.0),
        CGColor(red: 0x9B / 255.0, green: 0x72 / 255.0, blue: 0xCB / 255.0, alpha: 1.0),
        CGColor(red: 0xEA / 255.0, green: 0x43 / 255.0, blue: 0x35 / 255.0, alpha: 1.0),
        CGColor(red: 0xFB / 255.0, green: 0xBC / 255.0, blue: 0x04 / 255.0, alpha: 1.0),
    ]
}

#if os(macOS)
private struct CoreAnimationConicOrbView: NSViewRepresentable {
    let size: CGFloat
    let lineWidth: CGFloat
    let filled: Bool
    let animate: Bool

    func makeNSView(context: Context) -> ConicOrbNSView {
        let view = ConicOrbNSView()
        view.configure(size: size, lineWidth: lineWidth, filled: filled, animate: animate)
        return view
    }

    func updateNSView(_ nsView: ConicOrbNSView, context: Context) {
        nsView.configure(size: size, lineWidth: lineWidth, filled: filled, animate: animate)
    }
}

@MainActor
private final class ConicOrbNSView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let ringMaskLayer = CAShapeLayer()
    private var currentSize: CGFloat = 0
    private var currentLineWidth: CGFloat = 2.0
    private var currentFilled: Bool = false
    private var isAnimating: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        gradientLayer.type = .conic
        gradientLayer.colors = OrbitPaletteColors.conicCGColors
        gradientLayer.locations = OrbitPaletteColors.conicLocations
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradientLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        ringMaskLayer.fillColor = nil
        ringMaskLayer.strokeColor = CGColor(gray: 1.0, alpha: 1.0)
        layer?.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updateGeometry()
    }

    func configure(size: CGFloat, lineWidth: CGFloat, filled: Bool, animate: Bool) {
        let geometryChanged = (currentSize != size || currentLineWidth != lineWidth || currentFilled != filled)
        currentSize = size
        currentLineWidth = lineWidth
        currentFilled = filled
        if geometryChanged {
            updateGeometry()
        }
        setAnimating(animate)
    }

    private func updateGeometry() {
        let side = max(1, min(bounds.width > 0 ? bounds.width : currentSize, bounds.height > 0 ? bounds.height : currentSize))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradientLayer.position = CGPoint(x: bounds.midX > 0 ? bounds.midX : side * 0.5, y: bounds.midY > 0 ? bounds.midY : side * 0.5)
        if currentFilled {
            gradientLayer.mask = nil
            gradientLayer.cornerRadius = side * 0.5
        } else {
            gradientLayer.cornerRadius = 0
            let inset = currentLineWidth * 0.5
            ringMaskLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
            ringMaskLayer.lineWidth = currentLineWidth
            ringMaskLayer.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: max(1, side - currentLineWidth), height: max(1, side - currentLineWidth)), transform: nil)
            gradientLayer.mask = ringMaskLayer
        }
        CATransaction.commit()
    }

    private func setAnimating(_ active: Bool) {
        if active {
            if !isAnimating || gradientLayer.animation(forKey: "pk.orbit") == nil {
                let anim = CABasicAnimation(keyPath: "transform.rotation.z")
                anim.fromValue = 0.0
                anim.toValue = -Double.pi * 2.0
                anim.duration = 1.9
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                gradientLayer.add(anim, forKey: "pk.orbit")
            }
            isAnimating = true
        } else if isAnimating {
            gradientLayer.removeAnimation(forKey: "pk.orbit")
            isAnimating = false
        }
    }
}

private struct CoreAnimationRainbowBarView: NSViewRepresentable {
    let animate: Bool

    func makeNSView(context: Context) -> RainbowBarNSView {
        let view = RainbowBarNSView()
        view.setAnimating(animate)
        return view
    }

    func updateNSView(_ nsView: RainbowBarNSView, context: Context) {
        nsView.setAnimating(animate)
    }
}

@MainActor
private final class RainbowBarNSView: NSView {
    private let barLayer = CAGradientLayer()
    private var isAnimating: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        barLayer.colors = OrbitPaletteColors.barCGColors
        barLayer.startPoint = CGPoint(x: 0.5, y: 1.0)
        barLayer.endPoint = CGPoint(x: 0.5, y: 0.0)
        barLayer.cornerRadius = 1.25
        barLayer.opacity = 0.85
        layer?.addSublayer(barLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = bounds
        CATransaction.commit()
    }

    func setAnimating(_ active: Bool) {
        if active {
            if !isAnimating || barLayer.animation(forKey: "pk.pulse") == nil {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 0.45
                anim.toValue = 1.0
                anim.duration = 1.4
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.isRemovedOnCompletion = false
                barLayer.add(anim, forKey: "pk.pulse")
            }
            isAnimating = true
        } else if isAnimating {
            barLayer.removeAnimation(forKey: "pk.pulse")
            barLayer.opacity = 0.85
            isAnimating = false
        }
    }
}

#elseif os(iOS)
private struct CoreAnimationConicOrbView: UIViewRepresentable {
    let size: CGFloat
    let lineWidth: CGFloat
    let filled: Bool
    let animate: Bool

    func makeUIView(context: Context) -> ConicOrbUIView {
        let view = ConicOrbUIView()
        view.configure(size: size, lineWidth: lineWidth, filled: filled, animate: animate)
        return view
    }

    func updateUIView(_ uiView: ConicOrbUIView, context: Context) {
        uiView.configure(size: size, lineWidth: lineWidth, filled: filled, animate: animate)
    }
}

@MainActor
private final class ConicOrbUIView: UIView {
    private let gradientLayer = CAGradientLayer()
    private let ringMaskLayer = CAShapeLayer()
    private var currentSize: CGFloat = 0
    private var currentLineWidth: CGFloat = 2.0
    private var currentFilled: Bool = false
    private var isAnimating: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gradientLayer.type = .conic
        gradientLayer.colors = OrbitPaletteColors.conicCGColors
        gradientLayer.locations = OrbitPaletteColors.conicLocations
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        gradientLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)

        ringMaskLayer.fillColor = nil
        ringMaskLayer.strokeColor = UIColor.white.cgColor
        layer.addSublayer(gradientLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
    }

    func configure(size: CGFloat, lineWidth: CGFloat, filled: Bool, animate: Bool) {
        let geometryChanged = (currentSize != size || currentLineWidth != lineWidth || currentFilled != filled)
        currentSize = size
        currentLineWidth = lineWidth
        currentFilled = filled
        if geometryChanged {
            updateGeometry()
        }
        setAnimating(animate)
    }

    private func updateGeometry() {
        let side = max(1, min(bounds.width > 0 ? bounds.width : currentSize, bounds.height > 0 ? bounds.height : currentSize))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradientLayer.position = CGPoint(x: bounds.midX > 0 ? bounds.midX : side * 0.5, y: bounds.midY > 0 ? bounds.midY : side * 0.5)
        if currentFilled {
            gradientLayer.mask = nil
            gradientLayer.cornerRadius = side * 0.5
        } else {
            gradientLayer.cornerRadius = 0
            let inset = currentLineWidth * 0.5
            ringMaskLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
            ringMaskLayer.lineWidth = currentLineWidth
            ringMaskLayer.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: max(1, side - currentLineWidth), height: max(1, side - currentLineWidth)), transform: nil)
            gradientLayer.mask = ringMaskLayer
        }
        CATransaction.commit()
    }

    private func setAnimating(_ active: Bool) {
        if active {
            if !isAnimating || gradientLayer.animation(forKey: "pk.orbit") == nil {
                let anim = CABasicAnimation(keyPath: "transform.rotation.z")
                anim.fromValue = 0.0
                anim.toValue = Double.pi * 2.0
                anim.duration = 1.9
                anim.repeatCount = .infinity
                anim.isRemovedOnCompletion = false
                gradientLayer.add(anim, forKey: "pk.orbit")
            }
            isAnimating = true
        } else if isAnimating {
            gradientLayer.removeAnimation(forKey: "pk.orbit")
            isAnimating = false
        }
    }
}

private struct CoreAnimationRainbowBarView: UIViewRepresentable {
    let animate: Bool

    func makeUIView(context: Context) -> RainbowBarUIView {
        let view = RainbowBarUIView()
        view.setAnimating(animate)
        return view
    }

    func updateUIView(_ uiView: RainbowBarUIView, context: Context) {
        uiView.setAnimating(animate)
    }
}

@MainActor
private final class RainbowBarUIView: UIView {
    private let barLayer = CAGradientLayer()
    private var isAnimating: Bool = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        barLayer.colors = OrbitPaletteColors.barCGColors
        barLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        barLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        barLayer.cornerRadius = 1.25
        barLayer.opacity = 0.85
        layer.addSublayer(barLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barLayer.frame = bounds
        CATransaction.commit()
    }

    func setAnimating(_ active: Bool) {
        if active {
            if !isAnimating || barLayer.animation(forKey: "pk.pulse") == nil {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 0.45
                anim.toValue = 1.0
                anim.duration = 1.4
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.isRemovedOnCompletion = false
                barLayer.add(anim, forKey: "pk.pulse")
            }
            isAnimating = true
        } else if isAnimating {
            barLayer.removeAnimation(forKey: "pk.pulse")
            barLayer.opacity = 0.85
            isAnimating = false
        }
    }
}
#endif
