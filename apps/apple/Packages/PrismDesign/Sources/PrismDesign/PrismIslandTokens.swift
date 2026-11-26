import SwiftUI

/// The Dynamic Island's colors. The island is hardware black on the notch in every palette, so
/// this set is always dark: the chassis and its rim follow the palette's family (cool for Obsidian
/// and Crystal, warm for Warm and Alabaster), and the accent and spectrum are those of the dark
/// counterpart, so a light palette's mono or deep accent never sinks into the black.
///
/// Small text (below 14 pt) in `text`, `quote`, `secondary` and `tertiary` keeps at least 4.5:1 on
/// the chassis, `card`, `focusCard` and the island's washes.
public struct PrismIslandTokens: Sendable {
    // Hardware surfaces
    /// The chassis fill; also the color of cutouts and fades that must match it.
    public let surface: Color
    /// The chassis's etched rim, collapsed and open.
    public let rim: Color
    public let rimOpen: Color
    public let card: Color
    public let focusCard: Color
    public let cardHover: Color
    public let rowHover: Color
    public let line: Color
    /// Outlines that answer the pointer.
    public let lineStrong: Color
    /// Solid track of bars and rings drawn on the chassis.
    public let track: Color
    public let button: Color
    public let buttonHover: Color
    public let primaryButton: Color
    public let primaryButtonHover: Color
    public let onPrimaryButton: Color

    // Translucent layers of the island's ink, which read alike over the chassis and over cards
    /// Rows at rest.
    public let washQuiet: Color
    /// Inset wells and summary cards.
    public let wash: Color
    /// The raised card and the tab switcher's capsule.
    public let washRaised: Color
    /// Rows under the pointer.
    public let washHover: Color
    /// Track of the micro bars.
    public let meterTrack: Color
    /// The idle columns of a chart.
    public let meterIdle: Color

    // Inks
    public let text: Color
    public let quote: Color
    public let secondary: Color
    /// Captions, units and times.
    public let tertiary: Color
    /// Chevrons and other glyphs at rest (3:1 on cards); never text.
    public let faint: Color

    // Accent and the optical spectrum, all legible on black
    public let accent: Color
    public let cobalt: Color
    public let iris: Color
    public let coral: Color
    public let amber: Color

    // Semantics
    public let attention: Color
    public let warning: Color
    public let danger: Color
    public let success: Color
    /// Success as small text: brighter than `success`, which fills, dots and rings take.
    public let successText: Color
    public let unread: Color
    public let running: Color
    public let planDone: Color

    /// The island for Obsidian with the model accent, for code that has no palette at hand. Only
    /// the chassis, the rim, the accent and the spectrum differ between palettes.
    public static let standard = PrismIslandTokens.resolved(palette: .obsidian, accent: .model)

    public static func resolved(palette: PrismPalette, accent: PrismAccentMode) -> PrismIslandTokens {
        let family = palette.darkCounterpart
        let warm = family == .warm
        let surfaceHex: UInt32 = warm ? 0x0C0B0A : 0x050508
        let rimInk: Color = warm ? Color(hex: 0xF5F0E6) : .white
        let cardHex: UInt32 = 0x16161B
        let counterpart = PrismTokens.resolvedPrimaryHex(palette: family, accent: accent)

        return PrismIslandTokens(
            surface: Color(hex: surfaceHex),
            rim: rimInk.opacity(0.085),
            rimOpen: rimInk.opacity(0.14),
            card: Color(hex: cardHex),
            focusCard: Color(hex: 0x111116),
            cardHover: Color(hex: 0x22222A),
            rowHover: Color(hex: 0x14141A),
            line: Color.white.opacity(0.085),
            lineStrong: Color.white.opacity(0.12),
            track: Color(hex: 0x26262E),
            button: Color(hex: 0x26262E),
            buttonHover: Color(hex: 0x31313B),
            primaryButton: Color(hex: 0xF5F5F7),
            primaryButtonHover: .white,
            onPrimaryButton: .black,
            washQuiet: Color.white.opacity(0.035),
            wash: Color.white.opacity(0.045),
            washRaised: Color.white.opacity(0.06),
            washHover: Color.white.opacity(0.075),
            meterTrack: Color.white.opacity(0.14),
            meterIdle: Color.white.opacity(0.28),
            text: Color(hex: 0xF2F2F7),
            quote: Color(hex: 0xC7C7CC),
            secondary: Color(hex: 0x8E8E98),
            tertiary: Color(hex: 0x868690),
            faint: Color(hex: 0x6A6A74),
            // A custom accent keeps its hue but is lifted toward white until it holds 4.5:1 on a
            // card; every preset already does.
            accent: Color(hex: liftedHex(counterpart, toContrast: 4.5, on: cardHex)),
            cobalt: Color(hex: 0x4C8DF6),
            iris: Color(hex: 0x9B72CB),
            coral: Color(hex: warm ? 0xD97757 : 0xD96570),
            amber: Color(hex: 0xF2B84B),
            attention: Color(hex: 0xF4BE5B),
            warning: Color(hex: 0xF2B84B),
            danger: Color(hex: 0xEC635B),
            success: Color(hex: 0x50A37B),
            successText: Color(hex: 0x34D399),
            unread: Color(hex: 0x4C8DF6),
            running: Color(hex: 0x6BA4FF),
            planDone: Color(hex: 0x50A37B)
        )
    }

    /// WCAG 2 contrast ratio of two opaque sRGB colors.
    static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `hex` mixed toward white just enough to reach `minimum` contrast on `background`.
    static func liftedHex(_ hex: UInt32, toContrast minimum: Double, on background: UInt32) -> UInt32 {
        let hex = hex & 0xFFFFFF
        guard contrastRatio(hex, background) < minimum else { return hex }
        var low = 0.0
        var high = 1.0
        for _ in 0..<16 {
            let mid = (low + high) / 2
            if contrastRatio(mixedWithWhite(hex, mid), background) >= minimum {
                high = mid
            } else {
                low = mid
            }
        }
        return mixedWithWhite(hex, high)
    }

    private static func mixedWithWhite(_ hex: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let value = Double((hex >> shift) & 0xFF)
            return UInt32((value + (255 - value) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    private static func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
    }
}

/// Brand marks of the usage providers' quota windows, in one place: a shade for light palettes
/// and one for dark surfaces such as the island's black (where each holds at least 5:1 on a card).
public enum PrismProviderBrand: String, CaseIterable, Sendable {
    case claude
    case claudeWeekly
    /// Claude's per-model weekly window.
    case claudeModelWeekly
    case gemini
    case geminiWeekly
    /// Antigravity's shared Claude and GPT pool.
    case geminiPartnerPool
    case codex
    /// The weekly window of any other provider.
    case weekly

    public var lightHex: UInt32 {
        switch self {
        case .claude: return 0xD97757
        case .claudeWeekly: return 0x2E9B78
        case .claudeModelWeekly: return 0x6D6AE8
        case .gemini: return 0x2F7BF5
        case .geminiWeekly: return 0x7C5CFA
        case .geminiPartnerPool: return 0x14A39A
        case .codex: return 0x5F82F5
        case .weekly: return 0x1CA48C
        }
    }

    public var darkHex: UInt32 {
        switch self {
        case .claude: return 0xE5896B
        case .claudeWeekly: return 0x48B894
        case .claudeModelWeekly: return 0x8B88FF
        case .gemini: return 0x5B9BFF
        case .geminiWeekly: return 0x9B80FF
        case .geminiPartnerPool: return 0x2EC4BA
        case .codex: return 0x7A9DFF
        case .weekly: return 0x38C4AA
        }
    }

    public var light: Color { Color(hex: lightHex) }
    public var dark: Color { Color(hex: darkHex) }

    /// The mark of a usage provider's first window, by its id.
    public static func primary(forProvider id: String) -> PrismProviderBrand? {
        switch id {
        case "claude": return .claude
        case "antigravity": return .gemini
        case "codex": return .codex
        default: return nil
        }
    }

    /// The mark of a usage provider's second window, by its id.
    public static func secondary(forProvider id: String) -> PrismProviderBrand {
        switch id {
        case "claude": return .claudeWeekly
        case "antigravity": return .geminiWeekly
        default: return .weekly
        }
    }

    /// The stops of Antigravity's swoosh mark, bottom leading to top trailing.
    public static let antigravitySwoosh: [Color] = [
        Color(hex: 0x34A853),
        Color(hex: 0x4285F4),
        Color(hex: 0x9B72CB),
        Color(hex: 0xEA4335),
        Color(hex: 0xFBBC05),
    ]
}
