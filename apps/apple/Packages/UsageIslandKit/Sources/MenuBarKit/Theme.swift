// Portions of this file are adapted from Cindy (https://github.com/makecindy/cindy),
// Copyright 2026 XD Inc., licensed under the Apache License 2.0 (LICENSES/Apache-2.0.txt).
// Modified for Sarto.

import AppKit
import CoreText
import SwiftUI

// Colors, motion curves and number formatting adapted from Cindy's menu bar panel
// (apps/desktop/native/menubar/macos-menubar-helper.swift) and unified with Sarto's
// 4 optical palettes (Obsidian Dark, Warm Charcoal, Daylight Crystal, Warm Alabaster).

public enum MenuBarThemeStyle: String, CaseIterable, Equatable, Sendable {
  case obsidian
  case warm
  case crystal
  case alabaster

  public var isDark: Bool {
    switch self {
    case .obsidian, .warm: return true
    case .crystal, .alabaster: return false
    }
  }

  public var appearanceName: NSAppearance.Name {
    isDark ? .darkAqua : .aqua
  }

  public var colorScheme: ColorScheme {
    isDark ? .dark : .light
  }
}

public enum Palette {
  /// Synchronized by `MenuBarPanelState` whenever Sarto's active palette or accent changes.
  public nonisolated(unsafe) static var currentStyle: MenuBarThemeStyle = .obsidian
  public nonisolated(unsafe) static var currentAccentHex: UInt32 = 0x5B89D6

  static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: alpha
    )
  }

  public static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    })
  }

  /// A solid color that differs between Light and Dark.
  public static func dynamicHex(_ light: UInt32, _ dark: UInt32) -> Color {
    dynamic(hex(light), hex(dark))
  }

  public static func solid(_ value: UInt32) -> Color { Color(nsColor: hex(value)) }

  private static func neutral(_ lightAlpha: CGFloat, _ darkAlpha: CGFloat) -> Color {
    switch currentStyle {
    case .obsidian:
      return Color(nsColor: hex(0xF2F2F5, darkAlpha))
    case .warm:
      return Color(nsColor: hex(0xF2EFE9, darkAlpha))
    case .crystal:
      return Color(nsColor: hex(0x0F172A, lightAlpha))
    case .alabaster:
      return Color(nsColor: hex(0x181715, lightAlpha))
    }
  }

  /// Titles and values.
  public static var ink: Color { neutral(0.92, 0.94) }
  public static var ink2: Color { neutral(0.62, 0.64) }
  /// Times, units and captions.
  public static var ink3: Color { neutral(0.45, 0.44) }
  /// Outlines and tube borders.
  public static var ink4: Color { neutral(0.14, 0.14) }
  /// Faint fills: hover, ring tracks.
  public static var ink5: Color { neutral(0.055, 0.055) }
  public static var line: Color { neutral(0.085, 0.08) }

  public static var tile: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0xF2F2F5, 0.048))
    case .warm: return Color(nsColor: hex(0xF2EFE9, 0.05))
    case .crystal: return Color(nsColor: hex(0xFFFFFF, 0.56))
    case .alabaster: return Color(nsColor: hex(0xFFFFFF, 0.52))
    }
  }

  public static var edge: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0xFFFFFF, 0.115))
    case .warm: return Color(nsColor: hex(0xF5F0E6, 0.105))
    case .crystal: return Color(nsColor: hex(0xFFFFFF, 0.88))
    case .alabaster: return Color(nsColor: hex(0xFFFFFF, 0.84))
    }
  }

  /// Solid fill for the primary pill.
  public static var cta: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0xF2F2F5))
    case .warm: return Color(nsColor: hex(0xF2EFE9))
    case .crystal: return Color(nsColor: hex(0x0F172A))
    case .alabaster: return Color(nsColor: hex(0x181715))
    }
  }

  /// The liquid: ink at partial opacity so the glass well shows through.
  public static var liquid: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0x88B2FA, 0.72))
    case .warm: return Color(nsColor: hex(0xF2EFE9, 0.72))
    case .crystal: return Color(nsColor: hex(0x2563EB, 0.50))
    case .alabaster: return Color(nsColor: hex(0x3C3934, 0.48))
    }
  }

  public static var fill: Color { neutral(0.44, 0.80) }

  /// Text on an `ink` pill.
  public static var onInk: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0x0E0E11))
    case .warm: return Color(nsColor: hex(0x141413))
    case .crystal, .alabaster: return Color(nsColor: hex(0xFFFFFF))
    }
  }

  /// Translucent backdrop tint & optical Prism corner glows over the system popover material.
  public static var panelTint: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0x0E0E11, 0.68))
    case .warm: return Color(nsColor: hex(0x161514, 0.64))
    case .crystal: return Color(nsColor: hex(0xF4F7FB, 0.62))
    case .alabaster: return Color(nsColor: hex(0xF6F4EE, 0.58))
    }
  }

  public static var panelGlow: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0x4C8DF6, 0.14))
    case .warm: return Color(nsColor: hex(0xD97757, 0.13))
    case .crystal: return Color(nsColor: hex(0x2563EB, 0.085))
    case .alabaster: return Color(nsColor: hex(0xC96442, 0.09))
    }
  }

  public static var panelGlow2: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0x9B72CB, 0.10))
    case .warm: return Color(nsColor: hex(0xFFF4E4, 0.045))
    case .crystal: return Color(nsColor: hex(0x7C3AED, 0.055))
    case .alabaster: return Color(nsColor: hex(0xFFFFFF, 0.55))
    }
  }

  /// Glass well behind the liquid.
  public static var wellTop: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0xFFFFFF, 0.075))
    case .warm: return Color(nsColor: hex(0xF2EFE9, 0.07))
    case .crystal: return Color(nsColor: hex(0xFFFFFF, 0.78))
    case .alabaster: return Color(nsColor: hex(0xFFFFFF, 0.72))
    }
  }

  public static var wellBottom: Color {
    switch currentStyle {
    case .obsidian: return Color(nsColor: hex(0xFFFFFF, 0.025))
    case .warm: return Color(nsColor: hex(0xF2EFE9, 0.025))
    case .crystal: return Color(nsColor: hex(0xEAF1FB, 0.56))
    case .alabaster: return Color(nsColor: hex(0xFFFFFF, 0.50))
    }
  }

  public static var wellShade: Color {
    currentStyle.isDark ? Color(nsColor: hex(0x000000, 0.50)) : Color(nsColor: hex(0x000000, 0.08))
  }

  /// Prism accent mark inside the primary CTA pill.
  public static var brand: Color { Color(nsColor: hex(currentAccentHex)) }
  /// 30% or less left.
  public static let warn = Color(nsColor: hex(0xF3A115))
  /// 10% or less left.
  public static let error = Color(nsColor: hex(0xEF4444))
  public static var focus: Color { Color(nsColor: hex(currentAccentHex)) }

  /// "warn" / "error" to their state color; anything else has none.
  public static func level(_ level: String) -> Color? {
    switch level {
    case "warn": return warn
    case "error": return error
    default: return nil
    }
  }
}

/// The open/fill curve shared by tubes, rings, page slides and the panel size.
public enum Motion {
  public static let fill = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
  /// Tube liquid rises slower than the rings, like a liquid settling.
  public static let liquid = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)
  public static let page = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)
  public static let quick = Animation.easeOut(duration: 0.2)
}

/// Barlow Condensed for numbers (OFL, bundled). Falls back to a smaller system font.
public enum NumFont {
  private static let faces = ["BarlowCondensed-Light", "BarlowCondensed-Medium", "BarlowCondensed-SemiBold"]
  public private(set) static var available = false

  public static func register() {
    for face in faces {
      guard let url = Bundle.module.url(forResource: face, withExtension: "ttf", subdirectory: "Fonts") else { continue }
      CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    available = faces.allSatisfy { NSFont(name: $0, size: 12) != nil }
  }

  public static func font(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    guard available else { return .system(size: (size * 0.8).rounded(), weight: weight) }
    let face: String
    switch weight {
    case .ultraLight, .thin, .light: face = faces[0]
    case .regular, .medium: face = faces[1]
    default: face = faces[2]
    }
    return .custom(face, fixedSize: size)
  }

  /// A pure number takes the number font; anything mixed with words (or CJK) stays in the
  /// system font, since a condensed face next to Chinese reads uneven.
  public static func adaptive(_ string: String, size: CGFloat, weight: Font.Weight = .semibold, textSize: CGFloat, textWeight: Font.Weight = .medium) -> Text {
    if isPureNumber(string) { return Text(string).font(font(size, weight)) }
    return Text(string).font(.system(size: textSize, weight: textWeight)).monospacedDigit()
  }

  public static func isPureNumber(_ string: String) -> Bool {
    var previousDigit = false
    var digits = 0
    for character in string {
      let isDigit = character.isNumber && character.isASCII
      let allowed = isDigit || "$¥€.,:%+-−".contains(character) || (previousDigit && "kKMB".contains(character))
      if !allowed { return false }
      if isDigit { digits += 1 }
      previousDigit = isDigit
    }
    return digits > 0
  }
}

public enum Fmt {
  @MainActor public static var symbol = "$"

  private static let lock = NSLock()
  private static let groupedFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    f.maximumFractionDigits = 0
    return f
  }()
  private nonisolated(unsafe) static var monthDayFormatters: [String: DateFormatter] = [:]
  private nonisolated(unsafe) static var weekdayFormatters: [String: DateFormatter] = [:]

  @MainActor public static func money(_ value: Double) -> String {
    if value >= 10_000 { return symbol + String(format: "%.1fk", value / 1000) }
    if value >= 100 { return symbol + grouped(value.rounded()) }
    return symbol + String(format: "%.2f", value)
  }

  public static func tokens(_ value: Double) -> String {
    let millions = value / 1_000_000
    if millions >= 1000 { return String(format: "%.1fB", millions / 1000) }
    if millions >= 10 { return "\(Int(millions.rounded()))M" }
    if millions >= 1 { return String(format: "%.1fM", millions) }
    if value >= 1000 { return "\(Int((value / 1000).rounded()))K" }
    return "\(Int(max(0, value).rounded()))"
  }

  public static func grouped(_ value: Double) -> String {
    lock.lock()
    defer { lock.unlock() }
    return groupedFormatter.string(from: NSNumber(value: value)) ?? String(Int(value))
  }

  public static func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return "\(total / 60):" + String(format: "%02d", total % 60)
  }

  public static func monthDay(_ date: Date, locale: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    let formatter: DateFormatter
    if let cached = monthDayFormatters[locale] {
      formatter = cached
    } else {
      let created = DateFormatter()
      created.locale = Locale(identifier: locale)
      created.setLocalizedDateFormatFromTemplate("MMMd")
      monthDayFormatters[locale] = created
      formatter = created
    }
    return formatter.string(from: date)
  }

  public static func weekday(_ date: Date, locale: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    let formatter: DateFormatter
    if let cached = weekdayFormatters[locale] {
      formatter = cached
    } else {
      let created = DateFormatter()
      created.locale = Locale(identifier: locale)
      created.setLocalizedDateFormatFromTemplate("EEE")
      weekdayFormatters[locale] = created
      formatter = created
    }
    return formatter.string(from: date)
  }
}
