// Portions of this file are adapted from Obsidian Prism (https://github.com/RMvdesi/obsidian-prism),
// Copyright (C) 2026 RMvdesi, licensed under the GNU GPL version 3 only (LICENSES/GPL-3.0.txt).
// Modified for Sarto.

import SwiftUI

public enum PrismElevation: Sendable {
    case flat
    case raised
    case floating
    case popover
}

/// Semantic aura states matching Obsidian Prism (conv-aura.js).
public enum PrismAuraState: Sendable, Equatable {
    case idle
    case start
    case running
    case waiting
    case error
    case completed
}

private struct PrismSurfaceModifier: ViewModifier {
    @Environment(\.prismTokens) private var tokens
    let elevation: PrismElevation
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? tokens.rMD
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        content
            .background(
                ZStack {
                    shape.fill(fillColor)
                    // 12-degree directional optical sheen from top-left (zero live backdrop-blur stall)
                    shape.fill(
                        LinearGradient(
                            colors: [
                                tokens.palette.isDark
                                    ? Color.white.opacity(elevation == .flat ? 0.025 : 0.055)
                                    : Color.white.opacity(0.92),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .center
                        )
                    )
                }
            )
            .overlay(
                shape.strokeBorder(elevation == .flat ? tokens.borderEtched : tokens.border, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                shape
                    .stroke(tokens.specular, lineWidth: 1)
                    .mask(
                        VStack(spacing: 0) {
                            Rectangle().frame(height: 1.5)
                            Spacer(minLength: 0)
                        }
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: shadowColorPrimary,
                radius: primaryShadowRadius,
                x: 0,
                y: primaryShadowY
            )
    }

    private var fillColor: Color {
        switch elevation {
        case .flat: return tokens.surface1
        case .raised: return tokens.glassBackground
        case .floating: return tokens.composerBackground
        case .popover: return tokens.popoverBackground
        }
    }

    private var primaryShadowRadius: CGFloat {
        switch elevation {
        case .flat: return 0
        case .raised: return 10
        case .floating: return 18
        case .popover: return 22
        }
    }

    private var primaryShadowY: CGFloat {
        switch elevation {
        case .flat: return 0
        case .raised: return 4
        case .floating: return 10
        case .popover: return 12
        }
    }

    private var shadowColorPrimary: Color {
        if elevation == .flat { return .clear }
        return tokens.palette.isDark
            ? Color.black.opacity(elevation == .popover ? 0.68 : (elevation == .floating ? 0.56 : 0.38))
            : Color(hex: 0x1E3A8A).opacity(elevation == .popover ? 0.14 : (elevation == .floating ? 0.11 : 0.07))
    }
}

private struct PrismAuraModifier: ViewModifier {
    @Environment(\.prismTokens) private var tokens
    let state: PrismAuraState
    let cornerRadius: CGFloat?

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? tokens.rMD
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let auraColor: Color? = {
            switch state {
            case .idle, .start, .running: return nil
            case .waiting: return tokens.warning
            case .error: return tokens.danger
            case .completed: return tokens.success
            }
        }()

        content
            .overlay {
                if let auraColor {
                    shape
                        .strokeBorder(auraColor.opacity(tokens.palette.isDark ? 0.56 : 0.46), lineWidth: 1.2)
                        .shadow(color: auraColor.opacity(tokens.palette.isDark ? 0.34 : 0.18), radius: 10)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Persistently mounted pointer-tracking 220pt rainbow prism specular rim (Input-Only Prism Constitution).
/// Tracks mouse coordinates directly inside the Metal coordinator at native 60/120/144Hz with ZERO SwiftUI
/// re-renders and ZERO CAMetalLayer teardown/recreation hitch on hover!
private struct PrismInputRimModifier: ViewModifier {
    @Environment(\.prismTokens) private var tokens
    @Environment(\.prismMotionTier) private var motionTier
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let cornerRadius: CGFloat
    let isFocused: Bool
    let isStreaming: Bool

    func body(content: Content) -> some View {
        let motionActive = !reduceMotion && motionTier != .off
        let baseAlpha: Float = isStreaming ? 0.80 : (isFocused ? 0.62 : 0.0)
        // Only run a continuous display-link sweep while actively streaming;
        // pointer hover drives vsync-coalesced on-demand redraws at native refresh rate (0% idle CPU).
        let animateRim = motionActive && isStreaming

        content
            .overlay {
                if PrismMetalEngine.shared.isReady {
                    PrismMetalView(
                        kind: .prismRim,
                        uniforms: PrismUniforms(
                            isDark: tokens.palette.isDark,
                            pointerAlpha: baseAlpha,
                            accent: tokens.shaderAccentCode,
                            params: SIMD4(Float(cornerRadius), 0, 0, 0)
                        ),
                        isAnimating: animateRim,
                        preferredFPS: 60,
                        tracksWindowPointer: motionActive,
                        activity: animateRim ? .streaming : .interactive
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else if baseAlpha > 0 {
                    // Static rim when the Metal pipeline is unavailable.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AngularGradient(
                                colors: [tokens.prismCobalt, tokens.prismIris, tokens.prismCobalt],
                                center: .center
                            ),
                            lineWidth: 1.2
                        )
                        .opacity(Double(baseAlpha))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

public extension View {
    func prismSurface(
        elevation: PrismElevation = .raised,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(PrismSurfaceModifier(elevation: elevation, cornerRadius: cornerRadius))
    }

    func prismSemanticAura(
        _ state: PrismAuraState,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(PrismAuraModifier(state: state, cornerRadius: cornerRadius))
    }

    func prismInputRim(
        cornerRadius: CGFloat = 10,
        isFocused: Bool = false,
        isStreaming: Bool = false
    ) -> some View {
        modifier(PrismInputRimModifier(cornerRadius: cornerRadius, isFocused: isFocused, isStreaming: isStreaming))
    }
}
