// Portions of this file are adapted from Obsidian Prism (https://github.com/RMvdesi/obsidian-prism),
// Copyright (C) 2026 RMvdesi, licensed under the GNU GPL version 3 only (LICENSES/GPL-3.0.txt).
// Modified for Sarto.

import SwiftUI

/// Motion intensity tiers matching Obsidian Prism's motion-engine.js.
public enum PrismMotionTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case subtle
    case standard
    case ultra

    public var id: String { rawValue }
}

/// Exact 2nd-order damped spring parameters from Obsidian Prism (motion-engine.js).
public struct PrismSpringSpec: Sendable, Equatable {
    public let stiffness: Double
    public let damping: Double
    public let mass: Double

    public init(stiffness: Double, damping: Double, mass: Double) {
        self.stiffness = stiffness
        self.damping = damping
        self.mass = mass
    }

    public static let snappy = PrismSpringSpec(stiffness: 420, damping: 30, mass: 0.9)
    public static let bouncy = PrismSpringSpec(stiffness: 380, damping: 20, mass: 1.0)
    public static let `default` = PrismSpringSpec(stiffness: 380, damping: 26, mass: 1.0)
    public static let gentle = PrismSpringSpec(stiffness: 260, damping: 26, mass: 1.05)
    public static let micro = PrismSpringSpec(stiffness: 440, damping: 24, mass: 0.85)
    public static let indicator = PrismSpringSpec(stiffness: 430, damping: 32, mass: 0.9)

    // The Dynamic Island's chassis. The lively ones overshoot slightly as the island grows (a
    // damping ratio of 0.86, 0.92 settling back); the calm ones are critically damped.
    public static let islandOpenLively = PrismSpringSpec(stiffness: 341.5, damping: 31.8, mass: 1.0)
    public static let islandOpenCalm = PrismSpringSpec(stiffness: 341.5, damping: 37.0, mass: 1.0)
    public static let islandGrowLively = PrismSpringSpec(stiffness: 246.7, damping: 27.0, mass: 1.0)
    public static let islandGrowCalm = PrismSpringSpec(stiffness: 246.7, damping: 31.4, mass: 1.0)
    public static let islandSettleLively = PrismSpringSpec(stiffness: 385.5, damping: 36.1, mass: 1.0)
    public static let islandSettleCalm = PrismSpringSpec(stiffness: 385.5, damping: 39.3, mass: 1.0)

    /// Returns a SwiftUI Animation respecting the active motion tier and reduce-motion setting.
    public func animation(tier: PrismMotionTier, reduceMotion: Bool = false) -> Animation? {
        let effective: PrismMotionTier = reduceMotion ? .off : tier
        switch effective {
        case .off:
            return nil
        case .subtle:
            return .easeOut(duration: 0.12)
        case .standard, .ultra:
            return .interpolatingSpring(mass: mass, stiffness: stiffness, damping: damping)
        }
    }
}

private struct PrismMotionTierKey: EnvironmentKey {
    static let defaultValue: PrismMotionTier = .ultra
}

public extension EnvironmentValues {
    var prismMotionTier: PrismMotionTier {
        get { self[PrismMotionTierKey.self] }
        set { self[PrismMotionTierKey.self] = newValue }
    }
}
