import Foundation
import PrismDesign

/// Localized copy for the macOS Dynamic Island, read through `PrismL10n` from PrismDesign's
/// `Localizable.strings` under the `island.` prefix. Values name their placeholders as
/// `{{name}}`, and counted copy has `_one` and `_other` variants.
struct IslandStrings: Sendable, Equatable {
    let l10n: PrismL10n

    init(language: PrismLanguage) {
        // Pins `.system` to the language it resolves to, so copy in the same language compares equal.
        l10n = PrismL10n(language: PrismLanguage(rawValue: language.resolvedLprojCode) ?? .en)
    }

    var isChinese: Bool {
        l10n.language == .zhHans
    }

    var localeIdentifier: String {
        isChinese ? "zh-CN" : "en"
    }

    func text(_ key: String, _ values: [String: String] = [:]) -> String {
        Self.fill(l10n.lookup("island.\(key)") ?? key, values)
    }

    func counted(_ key: String, _ count: Int) -> String {
        let values = ["count": "\(count)"]
        // Chinese has no singular, so it always reads the `_other` variant.
        if !isChinese && count == 1, let one = l10n.lookup("island.\(key)_one") {
            return Self.fill(one, values)
        }
        if let other = l10n.lookup("island.\(key)_other") {
            return Self.fill(other, values)
        }
        return text(key, values)
    }

    private static func fill(_ template: String, _ values: [String: String]) -> String {
        var resolved = template
        for (name, value) in values {
            resolved = resolved.replacingOccurrences(of: "{{\(name)}}", with: value)
        }
        return resolved
    }
}
