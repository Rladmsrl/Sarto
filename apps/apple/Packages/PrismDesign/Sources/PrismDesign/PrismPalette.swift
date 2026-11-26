// Portions of this file are adapted from Obsidian Prism (https://github.com/RMvdesi/obsidian-prism),
// Copyright (C) 2026 RMvdesi, licensed under the GNU GPL version 3 only (LICENSES/GPL-3.0.txt).
// Modified for Sarto.

import SwiftUI

/// The four flagship optical palettes adapted from Obsidian Prism (v2-tokens.css).
public enum PrismPalette: String, CaseIterable, Identifiable, Codable, Sendable {
    case obsidian
    case warm
    case crystal
    case alabaster

    public var id: String { rawValue }

    public var isDark: Bool {
        switch self {
        case .obsidian, .warm: return true
        case .crystal, .alabaster: return false
        }
    }

    public var displayName: String {
        switch self {
        case .obsidian: return "Obsidian Dark"
        case .warm: return "Warm Charcoal"
        case .crystal: return "Daylight Crystal"
        case .alabaster: return "Warm Alabaster"
        }
    }

    public func localizedName(_ l10n: PrismL10n) -> String {
        l10n.tr("palette.\(rawValue).name")
    }

    public func localizedName(language: PrismLanguage?) -> String {
        localizedName(PrismL10n(language: language ?? PrismLanguage.loadSaved()))
    }

    public func localizedSubtitle(_ l10n: PrismL10n) -> String {
        l10n.tr("palette.\(rawValue).subtitle")
    }

    public func localizedSubtitle(language: PrismLanguage?) -> String {
        localizedSubtitle(PrismL10n(language: language ?? PrismLanguage.loadSaved()))
    }

    public var localizedName: String {
        localizedName(language: nil)
    }

    public var subtitle: String {
        localizedSubtitle(language: nil)
    }

    public var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    /// Exact opaque stage background RGB matching `PrismTokens.resolved(palette:).background`
    /// so the full-stage Metal backdrop can render with `isOpaque = true` (zero WindowServer alpha blend).
    public var backgroundRGB: SIMD3<Float> {
        switch self {
        case .obsidian: return SIMD3(14.0 / 255.0, 14.0 / 255.0, 17.0 / 255.0)
        case .warm: return SIMD3(20.0 / 255.0, 20.0 / 255.0, 19.0 / 255.0)
        case .crystal: return SIMD3(244.0 / 255.0, 247.0 / 255.0, 251.0 / 255.0)
        case .alabaster: return SIMD3(246.0 / 255.0, 244.0 / 255.0, 238.0 / 255.0)
        }
    }

    public var defaultPrimaryHex: UInt32 {
        switch self {
        case .obsidian: return 0x5B89D6
        case .warm: return 0xD97757
        case .crystal: return 0x2563EB
        case .alabaster: return 0xC96442
        }
    }

    public var defaultPrimaryColor: Color {
        Color(hex: defaultPrimaryHex)
    }
}

public enum PrismAccentMode: RawRepresentable, Identifiable, Hashable, Codable, Sendable {
    case model
    case cobalt
    case iris
    case amber
    case mono
    case custom(UInt32)

    public static let presetCases: [PrismAccentMode] = [.model, .cobalt, .iris, .amber, .mono]

    public var id: String { rawValue }

    public var rawValue: String {
        switch self {
        case .model: return "model"
        case .cobalt: return "cobalt"
        case .iris: return "iris"
        case .amber: return "amber"
        case .mono: return "mono"
        case .custom(let hex): return String(format: "#%06X", hex & 0xFFFFFF)
        }
    }

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "model": self = .model
        case "cobalt": self = .cobalt
        case "iris": self = .iris
        case "amber": self = .amber
        case "mono": self = .mono
        default:
            let hexStr: String
            if trimmed.lowercased().hasPrefix("custom:#") {
                hexStr = String(trimmed.dropFirst(8))
            } else if trimmed.hasPrefix("#") {
                hexStr = String(trimmed.dropFirst(1))
            } else {
                return nil
            }
            guard hexStr.count == 6, let value = UInt32(hexStr, radix: 16) else {
                return nil
            }
            self = .custom(value & 0xFFFFFF)
        }
    }

    public var customHex: UInt32? {
        if case .custom(let hex) = self { return hex & 0xFFFFFF }
        return nil
    }

    public func localizedName(_ l10n: PrismL10n) -> String {
        switch self {
        case .custom(let hex):
            return String(format: "#%06X", hex & 0xFFFFFF)
        default:
            return l10n.tr("accent.\(rawValue)")
        }
    }

    public func localizedName(language: PrismLanguage?) -> String {
        localizedName(PrismL10n(language: language ?? PrismLanguage.loadSaved()))
    }

    public var localizedName: String {
        localizedName(language: nil)
    }

    public var swatchColor: Color {
        switch self {
        case .model: return Color(hex: 0x4C8DF6)
        case .cobalt: return Color(hex: 0x3186FF)
        case .iris: return Color(hex: 0x9B72CB)
        case .amber: return Color(hex: 0xF2B84B)
        case .mono: return Color(hex: 0x94A3B8)
        case .custom(let hex): return Color(hex: hex)
        }
    }
}

/// Curated accent swatch shown in Settings alongside the Follow Theme option and custom color wheel.
public struct PrismAccentSwatch: Identifiable, Hashable, Sendable {
    public let id: String
    public let mode: PrismAccentMode
    public let hex: UInt32
    public let labelKey: String

    public init(id: String, mode: PrismAccentMode, hex: UInt32, labelKey: String) {
        self.id = id
        self.mode = mode
        self.hex = hex
        self.labelKey = labelKey
    }

    public var color: Color { Color(hex: hex) }

    public static let curated: [PrismAccentSwatch] = [
        PrismAccentSwatch(id: "cobalt", mode: .cobalt, hex: 0x3B82F6, labelKey: "accent.cobalt"),
        PrismAccentSwatch(id: "emerald", mode: .custom(0x2E9E72), hex: 0x2E9E72, labelKey: "accent.emerald"),
        PrismAccentSwatch(id: "amber", mode: .amber, hex: 0xE5A435, labelKey: "accent.amber"),
        PrismAccentSwatch(id: "iris", mode: .iris, hex: 0x8E63D2, labelKey: "accent.iris"),
        PrismAccentSwatch(id: "mono", mode: .mono, hex: 0x8E99AA, labelKey: "accent.mono"),
    ]
}

/// Syntax colors for highlighted code on `codeBackground`.
public struct PrismCodeSyntaxColors: Sendable {
    public let plain: Color
    public let keyword: Color
    public let type: Color
    public let string: Color
    public let number: Color
    public let comment: Color
    public let attribute: Color
    public let property: Color
    public let added: Color
    public let removed: Color

    static let dark = PrismCodeSyntaxColors(
        plain: Color(hex: 0xE6E9F2),
        keyword: Color(hex: 0xC792EA),
        type: Color(hex: 0x82AAFF),
        string: Color(hex: 0xA5D6A7),
        number: Color(hex: 0xF78C6C),
        comment: Color(hex: 0x6B7489),
        attribute: Color(hex: 0xFFCB6B),
        property: Color(hex: 0x89DDFF),
        added: Color(hex: 0x4ADE80),
        removed: Color(hex: 0xF87171)
    )

    static let light = PrismCodeSyntaxColors(
        plain: Color(hex: 0x1E2430),
        keyword: Color(hex: 0x7C3AED),
        type: Color(hex: 0x1D4ED8),
        string: Color(hex: 0x15803D),
        number: Color(hex: 0xC2410C),
        comment: Color(hex: 0x6B7280),
        attribute: Color(hex: 0xB45309),
        property: Color(hex: 0x0369A1),
        added: Color(hex: 0x15803D),
        removed: Color(hex: 0xDC2626)
    )
}

/// Resolved optical design tokens for a palette + accent combination.
public struct PrismTokens: Sendable {
    public let palette: PrismPalette
    public let accentMode: PrismAccentMode
    public let radiusBase: CGFloat

    // Surfaces
    public let background: Color
    public let sidebar: Color
    public let surface1: Color
    public let surface2: Color
    public let surface3: Color
    public let glassBackground: Color
    public let composerBackground: Color
    public let popoverBackground: Color
    public let codeBackground: Color
    public let codeHeaderBackground: Color
    public let userBubbleBackground: Color

    // Inverse button: a near-white capsule on dark palettes and a near-black one on light palettes
    public let inverseFill: Color
    public let inverseInk: Color

    // Code syntax highlighting
    public let codeSyntax: PrismCodeSyntaxColors

    // Typography inks
    public let foreground: Color
    public let secondaryForeground: Color
    public let mutedForeground: Color
    public let placeholder: Color

    // Accents & semantics
    public let primary: Color
    public let primarySoft: Color
    public let primaryBorder: Color
    public let success: Color
    public let successSoft: Color
    public let warning: Color
    public let warningSoft: Color
    public let danger: Color
    public let dangerSoft: Color

    // Optical edges & specular highlights
    public let border: Color
    public let borderEtched: Color
    public let borderStrong: Color
    public let specular: Color
    public let hoverWash: Color
    public let activeWash: Color

    // 4-stop optical prism spectrum
    public let prismCobalt: Color
    public let prismIris: Color
    public let prismCoral: Color
    public let prismAmber: Color

    // Model pool colors
    public let poolClaude: Color
    public let poolPro: Color
    public let poolFlash: Color

    // 6-level heatmap crystal ramp (0..5)
    public let heatColors: [Color]

    // Concentric micro-bevel radii (R_outer = R_inner + d)
    public var rMicro: CGFloat { 2 }
    public var rXS: CGFloat { max(2, radiusBase - 2) }
    public var rSM: CGFloat { radiusBase }
    public var rMD: CGFloat { radiusBase + 2 }
    public var rLG: CGFloat { radiusBase + 4 }

    /// High-contrast foreground ink over `primary` fills across all palettes and accent modes.
    public var onPrimary: Color {
        switch accentMode {
        case .custom(let hex):
            let r = Double((hex >> 16) & 0xFF) / 255.0
            let g = Double((hex >> 8) & 0xFF) / 255.0
            let b = Double(hex & 0xFF) / 255.0
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            return luma > 0.62 ? Color(hex: 0x0E0E11) : Color.white
        case .mono, .amber:
            return palette.isDark ? Color(hex: 0x0E0E11) : Color.white
        case .model, .cobalt, .iris:
            return Color.white
        }
    }

    /// Numeric spectrum code expected by Metal shaders:
    /// `0..5` for presets (0:default 1:warm 2:cobalt 3:iris 4:amber 5:mono),
    /// or `-(hex + 1)` for a custom 24-bit sRGB color (exact in IEEE 754 float32).
    public var shaderAccentCode: Float {
        switch accentMode {
        case .model:
            return (palette == .warm || palette == .alabaster) ? 1.0 : 0.0
        case .cobalt: return 2.0
        case .iris: return 3.0
        case .amber: return 4.0
        case .mono: return 5.0
        case .custom(let hex):
            return -Float((hex & 0xFFFFFF) + 1)
        }
    }

    public static func resolvedPrimaryHex(
        palette: PrismPalette = .obsidian,
        accent: PrismAccentMode = .model
    ) -> UInt32 {
        switch accent {
        case .model: return palette.defaultPrimaryHex
        case .cobalt: return palette.isDark ? 0x5B89D6 : 0x2563EB
        case .iris: return palette.isDark ? 0x9B72CB : 0x7C3AED
        case .amber: return palette.isDark ? 0xF2B84B : 0xD97706
        case .mono: return palette.isDark ? 0xD4D4DC : 0x27272A
        case .custom(let hex): return hex & 0xFFFFFF
        }
    }

    public static func resolved(
        palette: PrismPalette = .obsidian,
        accent: PrismAccentMode = .model,
        radiusBase: CGFloat = 6
    ) -> PrismTokens {
        let resolvedPrimary = Color(hex: resolvedPrimaryHex(palette: palette, accent: accent))

        switch palette {
        case .obsidian:
            return PrismTokens(
                palette: palette,
                accentMode: accent,
                radiusBase: radiusBase,
                background: Color(hex: 0x0E0E11),
                sidebar: Color(hex: 0x09090B),
                surface1: Color(hex: 0x151519),
                surface2: Color(hex: 0x1C1C21),
                surface3: Color(hex: 0x24242B),
                glassBackground: Color(hex: 0x151519, alpha: 0.78),
                composerBackground: Color(hex: 0x151519, alpha: 0.84),
                popoverBackground: Color(hex: 0x141418, alpha: 0.94),
                codeBackground: Color(hex: 0x09090B),
                codeHeaderBackground: Color(hex: 0x111115),
                userBubbleBackground: Color.white.opacity(0.055),
                inverseFill: Color(hex: 0xF2F3F7),
                inverseInk: Color(hex: 0x0E0F14),
                codeSyntax: .dark,
                foreground: Color(hex: 0xF2F2F5),
                secondaryForeground: Color(hex: 0xBDBDC8),
                mutedForeground: Color(hex: 0x8F8F9C),
                placeholder: Color(hex: 0x62626F),
                primary: resolvedPrimary,
                primarySoft: resolvedPrimary.opacity(0.14),
                primaryBorder: resolvedPrimary.opacity(0.38),
                success: Color(hex: 0x50A37B),
                successSoft: Color(hex: 0x50A37B).opacity(0.14),
                warning: Color(hex: 0xF2B84B),
                warningSoft: Color(hex: 0xF2B84B).opacity(0.15),
                danger: Color(hex: 0xE5534B),
                dangerSoft: Color(hex: 0xE5534B).opacity(0.15),
                border: Color.white.opacity(0.115),
                borderEtched: Color.white.opacity(0.072),
                borderStrong: Color.white.opacity(0.20),
                specular: Color.white.opacity(0.095),
                hoverWash: Color.white.opacity(0.055),
                activeWash: Color.white.opacity(0.105),
                prismCobalt: Color(hex: 0x4C8DF6),
                prismIris: Color(hex: 0x9B72CB),
                prismCoral: Color(hex: 0xD96570),
                prismAmber: Color(hex: 0xF2B84B),
                poolClaude: Color(hex: 0x5B89D6),
                poolPro: Color(hex: 0x846DC9),
                poolFlash: Color(hex: 0x629EBD),
                heatColors: [
                    Color.white.opacity(0.045),
                    Color(hex: 0x1E3A5F),
                    Color(hex: 0x2B579A),
                    Color(hex: 0x4378CF),
                    Color(hex: 0x6C7EE1),
                    Color(hex: 0x9B72CB),
                ]
            )

        case .warm:
            return PrismTokens(
                palette: palette,
                accentMode: accent,
                radiusBase: radiusBase,
                background: Color(hex: 0x141413),
                sidebar: Color(hex: 0x10100F),
                surface1: Color(hex: 0x1B1A18),
                surface2: Color(hex: 0x22201D),
                surface3: Color(hex: 0x2A2824),
                glassBackground: Color(hex: 0x1B1A18, alpha: 0.80),
                composerBackground: Color(hex: 0x1B1A18, alpha: 0.86),
                popoverBackground: Color(hex: 0x191816, alpha: 0.94),
                codeBackground: Color(hex: 0x0F0F0E),
                codeHeaderBackground: Color(hex: 0x161513),
                userBubbleBackground: Color(hex: 0xF5F0E6).opacity(0.055),
                inverseFill: Color(hex: 0xF2F3F7),
                inverseInk: Color(hex: 0x0E0F14),
                codeSyntax: .dark,
                foreground: Color(hex: 0xF2EFE9),
                secondaryForeground: Color(hex: 0xCEC8BC),
                mutedForeground: Color(hex: 0xA39E93),
                placeholder: Color(hex: 0x6E6A61),
                primary: resolvedPrimary,
                primarySoft: resolvedPrimary.opacity(0.14),
                primaryBorder: resolvedPrimary.opacity(0.36),
                success: Color(hex: 0x5FA882),
                successSoft: Color(hex: 0x5FA882).opacity(0.14),
                warning: Color(hex: 0xD9A05B),
                warningSoft: Color(hex: 0xD9A05B).opacity(0.15),
                danger: Color(hex: 0xE27872),
                dangerSoft: Color(hex: 0xE27872).opacity(0.14),
                border: Color(hex: 0xF5F0E6).opacity(0.115),
                borderEtched: Color(hex: 0xF5F0E6).opacity(0.072),
                borderStrong: Color(hex: 0xF5F0E6).opacity(0.20),
                specular: Color(hex: 0xFFFAF2).opacity(0.095),
                hoverWash: Color(hex: 0xF5F0E6).opacity(0.05),
                activeWash: Color(hex: 0xF5F0E6).opacity(0.085),
                prismCobalt: Color(hex: 0x4C8DF6),
                prismIris: Color(hex: 0x9B72CB),
                prismCoral: Color(hex: 0xD97757),
                prismAmber: Color(hex: 0xF2B84B),
                poolClaude: Color(hex: 0xD97757),
                poolPro: Color(hex: 0xC28A52),
                poolFlash: Color(hex: 0x5FA882),
                heatColors: [
                    Color(hex: 0xF5F0E6).opacity(0.045),
                    Color(hex: 0x4A2B1D),
                    Color(hex: 0x7A422B),
                    Color(hex: 0xB55D3E),
                    Color(hex: 0xD97757),
                    Color(hex: 0xF2B84B),
                ]
            )

        case .crystal:
            return PrismTokens(
                palette: palette,
                accentMode: accent,
                radiusBase: radiusBase,
                background: Color(hex: 0xF4F7FB),
                sidebar: Color(hex: 0xE8EEF6),
                surface1: Color(hex: 0xFFFFFF),
                surface2: Color(hex: 0xEDF2F9),
                surface3: Color(hex: 0xE1E9F4),
                glassBackground: Color(hex: 0xFFFFFF, alpha: 0.78),
                composerBackground: Color(hex: 0xFFFFFF, alpha: 0.88),
                popoverBackground: Color(hex: 0xFFFFFF, alpha: 0.94),
                codeBackground: Color(hex: 0xEDF2F9),
                codeHeaderBackground: Color(hex: 0xE4ECF6),
                userBubbleBackground: Color(hex: 0xEAF1FB),
                inverseFill: Color(hex: 0x14151B),
                inverseInk: Color(hex: 0xF8F9FC),
                codeSyntax: .light,
                foreground: Color(hex: 0x0F172A),
                secondaryForeground: Color(hex: 0x334155),
                mutedForeground: Color(hex: 0x5B6B82),
                placeholder: Color(hex: 0x8392A7),
                primary: resolvedPrimary,
                primarySoft: resolvedPrimary.opacity(0.11),
                primaryBorder: resolvedPrimary.opacity(0.36),
                success: Color(hex: 0x168055),
                successSoft: Color(hex: 0x168055).opacity(0.11),
                warning: Color(hex: 0xD97706),
                warningSoft: Color(hex: 0xD97706).opacity(0.13),
                danger: Color(hex: 0xDC2626),
                dangerSoft: Color(hex: 0xDC2626).opacity(0.11),
                border: Color(hex: 0x0F172A).opacity(0.115),
                borderEtched: Color(hex: 0x0F172A).opacity(0.08),
                borderStrong: Color(hex: 0x0F172A).opacity(0.17),
                specular: Color.white.opacity(0.96),
                hoverWash: Color(hex: 0x0F172A).opacity(0.05),
                activeWash: Color(hex: 0x2563EB).opacity(0.085),
                prismCobalt: Color(hex: 0x2563EB),
                prismIris: Color(hex: 0x7C3AED),
                prismCoral: Color(hex: 0xEA4335),
                prismAmber: Color(hex: 0xD97706),
                poolClaude: Color(hex: 0x2563EB),
                poolPro: Color(hex: 0x7C3AED),
                poolFlash: Color(hex: 0x0284C7),
                heatColors: [
                    Color(hex: 0x0F172A).opacity(0.055),
                    Color(hex: 0xCBDDF8),
                    Color(hex: 0x93BCFA),
                    Color(hex: 0x5893F5),
                    Color(hex: 0x366CE8),
                    Color(hex: 0x6D48E5),
                ]
            )

        case .alabaster:
            return PrismTokens(
                palette: palette,
                accentMode: accent,
                radiusBase: radiusBase,
                background: Color(hex: 0xF6F4EE),
                sidebar: Color(hex: 0xEBE6DC),
                surface1: Color(hex: 0xFFFFFF),
                surface2: Color(hex: 0xF1EEE5),
                surface3: Color(hex: 0xE5E0D3),
                glassBackground: Color(hex: 0xFFFFFF, alpha: 0.80),
                composerBackground: Color(hex: 0xFFFFFF, alpha: 0.88),
                popoverBackground: Color(hex: 0xFFFDF8, alpha: 0.94),
                codeBackground: Color(hex: 0xEFEAE0),
                codeHeaderBackground: Color(hex: 0xE7E1D5),
                userBubbleBackground: Color(hex: 0xEFECE2),
                inverseFill: Color(hex: 0x14151B),
                inverseInk: Color(hex: 0xF8F9FC),
                codeSyntax: .light,
                foreground: Color(hex: 0x181715),
                secondaryForeground: Color(hex: 0x3C3934),
                mutedForeground: Color(hex: 0x625D54),
                placeholder: Color(hex: 0x8F897D),
                primary: resolvedPrimary,
                primarySoft: resolvedPrimary.opacity(0.11),
                primaryBorder: resolvedPrimary.opacity(0.36),
                success: Color(hex: 0x2C7A56),
                successSoft: Color(hex: 0x2C7A56).opacity(0.11),
                warning: Color(hex: 0xB46D1E),
                warningSoft: Color(hex: 0xB46D1E).opacity(0.12),
                danger: Color(hex: 0xC44E47),
                dangerSoft: Color(hex: 0xC44E47).opacity(0.11),
                border: Color(hex: 0x2A2014).opacity(0.12),
                borderEtched: Color(hex: 0x2A2014).opacity(0.085),
                borderStrong: Color(hex: 0x2A2014).opacity(0.18),
                specular: Color.white.opacity(0.96),
                hoverWash: Color(hex: 0x2A2014).opacity(0.045),
                activeWash: Color(hex: 0x2A2014).opacity(0.08),
                prismCobalt: Color(hex: 0x2563EB),
                prismIris: Color(hex: 0x7C3AED),
                prismCoral: Color(hex: 0xC96442),
                prismAmber: Color(hex: 0xB46D1E),
                poolClaude: Color(hex: 0xC96442),
                poolPro: Color(hex: 0xB07428),
                poolFlash: Color(hex: 0x2C7A56),
                heatColors: [
                    Color(hex: 0x2A2014).opacity(0.055),
                    Color(hex: 0xF2D5C4),
                    Color(hex: 0xE7AD91),
                    Color(hex: 0xD98260),
                    Color(hex: 0xC96442),
                    Color(hex: 0xA8472A),
                ]
            )
        }
    }
}

public enum PrismAppIconStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case obsidian
    case warm
    case crystal
    case alabaster

    /// The default Sarto icon matching the Obsidian Dark optical palette.
    public static let defaultStyle: PrismAppIconStyle = .obsidian

    public var id: String { rawValue }

    /// Resolves current or legacy persisted raw values so saved preferences migrate cleanly.
    public static func fromPersistedRawValue(_ raw: String) -> PrismAppIconStyle? {
        if let direct = PrismAppIconStyle(rawValue: raw) {
            return direct
        }
        switch raw {
        case "abyssal", "prism":
            return .obsidian
        case "cobalt":
            return .crystal
        default:
            return nil
        }
    }

    /// Asset catalog imageset name bundled in SartoMac.
    public var assetName: String {
        "AppIconVariant_\(rawValue)"
    }

    public func localizedName(_ l10n: PrismL10n) -> String {
        l10n.tr("settings.appearance.appIcon.\(rawValue)")
    }
}

public enum PrismColorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case system
    case dark
    case light

    public var id: String { rawValue }
}

public enum PrismSendKeyMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case enter
    case commandEnter = "mod-enter"

    public var id: String { rawValue }
}

public enum PrismTextSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case small
    case standard = "default"
    case large

    public var id: String { rawValue }

    /// Delta in points applied to prose & code text inside the session thread.
    public var pointDelta: CGFloat {
        switch self {
        case .small: return -1.0
        case .standard: return 0.0
        case .large: return 1.5
        }
    }
}

public enum PrismInAppNoticeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case importantOnly
    case all
    case off

    public var id: String { rawValue }
}

public struct PrismNotificationPrefs: Codable, Equatable, Sendable {
    public var permissionNeeded: Bool
    public var turnEnded: Bool
    public var error: Bool
    public var soundEnabled: Bool
    public var dockBadgeEnabled: Bool
    public var inAppNoticeMode: PrismInAppNoticeMode

    public init(
        permissionNeeded: Bool = true,
        turnEnded: Bool = true,
        error: Bool = true,
        soundEnabled: Bool = true,
        dockBadgeEnabled: Bool = true,
        inAppNoticeMode: PrismInAppNoticeMode = .importantOnly
    ) {
        self.permissionNeeded = permissionNeeded
        self.turnEnded = turnEnded
        self.error = error
        self.soundEnabled = soundEnabled
        self.dockBadgeEnabled = dockBadgeEnabled
        self.inAppNoticeMode = inAppNoticeMode
    }

    private enum CodingKeys: String, CodingKey {
        case permissionNeeded
        case turnEnded
        case error
        case soundEnabled
        case dockBadgeEnabled
        case inAppNoticeMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.permissionNeeded = try container.decodeIfPresent(Bool.self, forKey: .permissionNeeded) ?? true
        self.turnEnded = try container.decodeIfPresent(Bool.self, forKey: .turnEnded) ?? true
        self.error = try container.decodeIfPresent(Bool.self, forKey: .error) ?? true
        self.soundEnabled = try container.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        self.dockBadgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .dockBadgeEnabled) ?? true
        self.inAppNoticeMode = try container.decodeIfPresent(PrismInAppNoticeMode.self, forKey: .inAppNoticeMode) ?? .importantOnly
    }
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

public struct PrismTypographyPrefs: Equatable, Sendable {
    public var textSizeDelta: CGFloat
    public var proseFontFamily: String
    public var codeFontFamily: String
    public var terminalFontSize: Int
    public var terminalFontFamily: String

    public init(
        textSizeDelta: CGFloat = 0,
        proseFontFamily: String = "",
        codeFontFamily: String = "",
        terminalFontSize: Int = 12,
        terminalFontFamily: String = ""
    ) {
        self.textSizeDelta = textSizeDelta
        self.proseFontFamily = proseFontFamily
        self.codeFontFamily = codeFontFamily
        self.terminalFontSize = terminalFontSize
        self.terminalFontFamily = terminalFontFamily
    }

    public func proseFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let resolved = max(9, size + textSizeDelta)
        if !proseFontFamily.isEmpty {
            return .custom(proseFontFamily, size: resolved).weight(weight)
        }
        return .system(size: resolved, weight: weight)
    }

    public func codeFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let resolved = max(9, size + textSizeDelta)
        if !codeFontFamily.isEmpty {
            return .custom(codeFontFamily, size: resolved).weight(weight)
        }
        return .system(size: resolved, weight: weight, design: .monospaced)
    }

    public func terminalFont(weight: Font.Weight = .regular) -> Font {
        let resolved = CGFloat(terminalFontSize)
        if !terminalFontFamily.isEmpty {
            return .custom(terminalFontFamily, size: resolved).weight(weight)
        }
        return .system(size: resolved, weight: weight, design: .monospaced)
    }
}

private struct PrismTokensKey: EnvironmentKey {
    static let defaultValue: PrismTokens = .resolved(palette: .obsidian)
}

private struct PrismTypographyKey: EnvironmentKey {
    static let defaultValue: PrismTypographyPrefs = PrismTypographyPrefs()
}

public extension EnvironmentValues {
    var prismTokens: PrismTokens {
        get { self[PrismTokensKey.self] }
        set { self[PrismTokensKey.self] = newValue }
    }

    var prismTypography: PrismTypographyPrefs {
        get { self[PrismTypographyKey.self] }
        set { self[PrismTypographyKey.self] = newValue }
    }
}
