import Foundation
import SwiftUI

/// Supported interface languages with instant runtime switching (no app restart required).
/// Adding a new locale only requires adding a `<code >.lproj/Localizable.strings` catalog
/// and a case here.
public enum PrismLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public static let storageKey = "sarto.language"
    public static let legacyStorageKey = "prism.language"

    public static func loadSaved(defaults: UserDefaults = .standard) -> PrismLanguage {
        let candidate = defaults.string(forKey: storageKey) ?? defaults.string(forKey: legacyStorageKey)
        if let raw = candidate {
            if let parsed = PrismLanguage(rawValue: raw) {
                return parsed
            }
            let lower = raw.lowercased()
            if lower.hasPrefix("zh") {
                return .zhHans
            }
            if lower.hasPrefix("en") {
                return .en
            }
        }
        return .system
    }

    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    /// Resolves `.system` against the OS preferred language list to a concrete `.lproj` code.
    public var resolvedLprojCode: String {
        switch self {
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferred.hasPrefix("zh") {
                return "zh-Hans"
            }
            return "en"
        }
    }

    public var resolvedLocale: Locale {
        Locale(identifier: resolvedLprojCode)
    }

    public func pickerLabel(l10n: PrismL10n) -> String {
        switch self {
        case .system: return l10n.tr("language.system")
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }
}

private final class BundleBox: @unchecked Sendable {
    let bundle: Bundle
    init(_ bundle: Bundle) { self.bundle = bundle }
}

/// Runtime-switchable, Bundle-backed localization resolver injected via `@Environment(\.prismL10n)`.
public struct PrismL10n: Sendable, Equatable {
    public let language: PrismLanguage
    public let resolvedCode: String

    private static func resolveLprojURL(for code: String) -> URL? {
        for candidate in [code, code.lowercased()] {
            if let url = Bundle.module.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: "\(candidate).lproj"
            ) {
                return url.deletingLastPathComponent()
            }
            if let path = Bundle.module.path(forResource: candidate, ofType: "lproj") {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static let cachedBundles: [String: BundleBox] = {
        var map: [String: BundleBox] = [:]
        for code in ["en", "zh-Hans"] {
            if let dir = resolveLprojURL(for: code),
               let sub = Bundle(url: dir) {
                map[code] = BundleBox(sub)
            }
        }
        return map
    }()

    private static let cachedTables: [String: [String: String]] = {
        var map: [String: [String: String]] = [:]
        for code in ["en", "zh-Hans"] {
            if let table = rawStringsTable(lproj: code) {
                map[code] = table
            }
        }
        return map
    }()

    public init(language: PrismLanguage = .system) {
        self.language = language
        self.resolvedCode = language.resolvedLprojCode
    }

    private var bundle: Bundle {
        if let cached = Self.cachedBundles[resolvedCode]?.bundle {
            return cached
        }
        if let dir = Self.resolveLprojURL(for: resolvedCode),
           let sub = Bundle(url: dir) {
            return sub
        }
        if let en = Self.cachedBundles["en"]?.bundle {
            return en
        }
        return Bundle.module
    }

    /// Looks up a localized string for `key` from the resolved `.lproj/Localizable.strings` table.
    public func tr(_ key: String) -> String {
        lookup(key) ?? key
    }

    /// The localized string for `key`, falling back to English; nil when no table has the key.
    public func lookup(_ key: String) -> String? {
        if let hit = Self.cachedTables[resolvedCode]?[key] {
            return hit
        }
        let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
        if value != key {
            return value
        }
        if resolvedCode != "en" {
            if let enHit = Self.cachedTables["en"]?[key] {
                return enHit
            }
            if let enBundle = Self.cachedBundles["en"]?.bundle {
                let enValue = enBundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if enValue != key {
                    return enValue
                }
            }
        }
        return nil
    }

    /// Formats a localized string using printf-style placeholders (`%@`, `%d`, `%.1f`).
    public func tr(_ key: String, _ args: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, locale: language.resolvedLocale, arguments: args)
    }

    /// Reads the raw key-value dictionary for a concrete `.lproj` code (used by completeness tests).
    public static func rawStringsTable(lproj code: String) -> [String: String]? {
        for candidate in [code, code.lowercased()] {
            if let url = Bundle.module.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: "\(candidate).lproj"
            ),
               let dict = NSDictionary(contentsOf: url) as? [String: String] {
                return dict
            }
        }
        return nil
    }
}

private struct PrismL10nKey: EnvironmentKey {
    static let defaultValue: PrismL10n = PrismL10n(language: .system)
}

public extension EnvironmentValues {
    var prismL10n: PrismL10n {
        get { self[PrismL10nKey.self] }
        set { self[PrismL10nKey.self] = newValue }
    }
}
