import Foundation

/// Release channels the updater can follow.
public enum UpdateChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case beta
}

/// Build channel stamped into an app or daemon bundle (`SartoBuildChannel`).
public enum BuildChannel: String, CaseIterable, Codable, Sendable {
    case stable
    case beta
    case dev

    public static func configured(_ value: Any?) -> BuildChannel? {
        guard let text = value as? String else { return nil }
        return BuildChannel(rawValue: text.trimmingCharacters(in: .whitespaces))
    }
}

public enum SartoVersion {
    private struct Parsed {
        let core: [Int]
        let pre: [String]
    }

    private static func parse(_ version: String) -> Parsed? {
        var text = Substring(version)
        if text.hasPrefix("v") { text = text.dropFirst() }
        if let plus = text.firstIndex(of: "+") {
            let build = text[text.index(after: plus)...]
            guard !build.isEmpty, build.allSatisfy(isIdentifierCharacter) else { return nil }
            text = text[..<plus]
        }
        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let tail = text[text.index(after: dash)...]
            guard !tail.isEmpty, tail.allSatisfy(isIdentifierCharacter) else { return nil }
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var core: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy(\.isASCIIDigit), let value = Int(part)
            else { return nil }
            core.append(value)
        }
        return Parsed(core: core, pre: pre)
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "-")
    }

    private static func isCanonicalNumericIdentifier(_ part: String) -> Bool {
        guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit) else { return false }
        return part == "0" || !part.hasPrefix("0")
    }

    /// Whether `version` is a release version, X.Y.Z with nothing after it.
    public static func isRelease(_ version: String) -> Bool {
        guard let parsed = parse(version) else { return false }
        return parsed.pre.isEmpty && !version.hasPrefix("v") && !version.contains("+")
    }

    /// Whether `version` is a beta prerelease version, `X.Y.Z-beta.<number>`.
    public static func isBeta(_ version: String) -> Bool {
        guard !version.hasPrefix("v"), !version.contains("+"),
              let parsed = parse(version),
              parsed.pre.count == 2,
              parsed.pre[0] == "beta",
              isCanonicalNumericIdentifier(parsed.pre[1])
        else { return false }
        return true
    }

    /// Whether `version` is a local development version, `X.Y.Z-dev.<number>`.
    public static func isDev(_ version: String) -> Bool {
        guard !version.hasPrefix("v"), !version.contains("+"),
              let parsed = parse(version),
              parsed.pre.count == 2,
              parsed.pre[0] == "dev",
              isCanonicalNumericIdentifier(parsed.pre[1])
        else { return false }
        return true
    }

    /// Whether `version` is valid for an update `channel`.
    public static func isChannelVersion(_ version: String, channel: UpdateChannel) -> Bool {
        switch channel {
        case .stable:
            return isRelease(version)
        case .beta:
            return isRelease(version) || isBeta(version)
        }
    }

    /// Whether `build` is a monotonic numeric build identifier (1 to 18 ASCII digits, no leading zero).
    public static func isValidBuildNumber(_ build: String) -> Bool {
        guard (1...18).contains(build.count), let first = build.first, first != "0" else { return false }
        return build.allSatisfy(\.isASCIIDigit)
    }

    /// Whether `tag` is a safe release folder / tag name with no path traversal.
    public static func isValidTag(_ tag: String) -> Bool {
        guard (1...128).contains(tag.count),
              !tag.contains(".."),
              let first = tag.first,
              first.isASCII && (first.isLetter || first.isNumber)
        else { return false }
        return tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// The full semantic version from an app bundle's Info.plist (`SartoVersion` if present,
    /// falling back to `CFBundleShortVersionString`).
    public static func bundleVersion(info: [String: Any]) -> String {
        if let full = (info["SartoVersion"] as? String)?.trimmingCharacters(in: .whitespaces), !full.isEmpty {
            return full
        }
        if let short = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces), !short.isEmpty {
            return short
        }
        return "0.0.0"
    }

    /// The build channel stamped into an app bundle, or inferred from its version when absent.
    public static func buildChannel(version: String, configured: Any?) -> BuildChannel {
        if let explicit = BuildChannel.configured(configured) { return explicit }
        if isBeta(version) { return .beta }
        if isDev(version) { return .dev }
        if isRelease(version) { return .stable }
        return .dev
    }

    /// Semver precedence: negative when `a` is older than `b`; nil when either is not a version.
    public static func compare(_ a: String, _ b: String) -> Int? {
        guard let left = parse(a), let right = parse(b) else { return nil }
        for i in 0..<3 where left.core[i] != right.core[i] {
            return left.core[i] - right.core[i]
        }
        if left.pre.isEmpty || right.pre.isEmpty { return right.pre.count - left.pre.count }
        for i in 0..<max(left.pre.count, right.pre.count) {
            guard i < left.pre.count else { return -1 }
            guard i < right.pre.count else { return 1 }
            let x = left.pre[i]
            let y = right.pre[i]
            let xNumeric = x.allSatisfy(\.isASCIIDigit)
            let yNumeric = y.allSatisfy(\.isASCIIDigit)
            if xNumeric && yNumeric {
                let nx = x.drop(while: { $0 == "0" })
                let ny = y.drop(while: { $0 == "0" })
                if nx.count != ny.count { return nx.count < ny.count ? -1 : 1 }
                if nx != ny { return nx < ny ? -1 : 1 }
            } else if xNumeric != yNumeric {
                // SemVer 2.0.0 section 11.4.3: numeric identifiers always have lower precedence.
                return xNumeric ? -1 : 1
            } else if x != y {
                return x < y ? -1 : 1
            }
        }
        return 0
    }

    public static func isNewer(_ a: String, than b: String) -> Bool {
        (compare(a, b) ?? 0) > 0
    }

    /// The version this launch updated from, when the last run was an older version.
    public static func updatedFrom(lastRunVersion: String?, current: String) -> String? {
        guard let lastRunVersion, let order = compare(lastRunVersion, current), order < 0 else { return nil }
        return lastRunVersion
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
