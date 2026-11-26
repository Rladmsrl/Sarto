import Foundation

/// One file of a release, as the update file names it.
public struct UpdateAsset: Codable, Equatable, Sendable {
    public let name: String
    public let size: Int64
    /// The SHA-512 of the file's bytes.
    public let sha512: Data
    /// For a delta, the version it builds this release from (`UpdateDelta`).
    public let from: String?

    public init(name: String, size: Int64, sha512: Data, from: String? = nil) {
        self.name = name
        self.size = size
        self.sha512 = sha512
        self.from = from
    }
}

/// `latest-mac.json` (stable) or `beta-mac.json` (beta), which the release key signs: the latest
/// version on that channel, its files, highlights and decoupled daemon metadata.
public struct UpdateFile: Equatable, Sendable {
    public static let name = "latest-mac.json"
    public static let betaName = "beta-mac.json"

    public static func name(for channel: UpdateChannel) -> String {
        switch channel {
        case .stable: return name
        case .beta: return betaName
        }
    }

    public let version: String
    public let channel: UpdateChannel
    public let build: String?
    public let daemonVersion: String?
    public let daemonBuild: String?
    /// Release folder / tag name under `download/<tag>/`; nil defaults to `v<version>`.
    public let tag: String?
    public let releaseDate: String?
    public let minimumSystemVersion: String?
    public let files: [UpdateAsset]
    /// The release's highlights by language (`en`, `zh-Hans`).
    public let notes: [String: [String]]
    /// The fingerprint of the daemon runtime the app bundles (`RuntimeFingerprint`), which tells
    /// whether installing it restarts the daemon; nil for a release that names none.
    public let runtime: String?

    public var releaseTag: String { tag ?? "v\(version)" }

    public init(
        version: String,
        channel: UpdateChannel = .stable,
        build: String? = nil,
        daemonVersion: String? = nil,
        daemonBuild: String? = nil,
        tag: String? = nil,
        releaseDate: String? = nil,
        minimumSystemVersion: String? = nil,
        files: [UpdateAsset],
        notes: [String: [String]] = [:],
        runtime: String? = nil
    ) {
        self.version = version
        self.channel = channel
        self.build = build
        self.daemonVersion = daemonVersion
        self.daemonBuild = daemonBuild
        self.tag = tag
        self.releaseDate = releaseDate
        self.minimumSystemVersion = minimumSystemVersion
        self.files = files
        self.notes = notes
        self.runtime = runtime
    }

    /// The app's zip for `arch`, which Install mode downloads.
    public func archive(arch: String) -> UpdateAsset? {
        files.first { $0.from == nil && $0.name.hasSuffix("-\(arch).zip") }
    }

    /// The delta for `arch` that builds this release from version `from`, if the release has one.
    public func delta(from: String, arch: String) -> UpdateAsset? {
        files.first { $0.from == from && $0.name.hasSuffix("-\(arch).delta") }
    }

    /// The disk image for `arch`, which Link mode opens.
    public func diskImage(arch: String) -> UpdateAsset? {
        files.first { $0.from == nil && $0.name.hasSuffix("-\(arch).dmg") }
    }

    /// Whether a Mac on `system` (major, minor, patch) can run this release.
    public func supports(system: OperatingSystemVersion) -> Bool {
        guard let minimum = minimumSystemVersion else { return true }
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let wanted = [system.majorVersion, system.minorVersion, system.patchVersion]
        for i in 0..<max(3, parts.count) {
            let have = i < wanted.count ? wanted[i] : 0
            let need = i < parts.count ? parts[i] : 0
            if have != need { return have > need }
        }
        return true
    }

    static let maxLength = 64 * 1024
    static let maxFiles = 16
    static let maxNotes = 5
    static let maxNote = 200
    static let languages: Set<String> = ["en", "zh-Hans"]

    static func isFileName(_ name: String) -> Bool {
        guard (1...128).contains(name.count), let first = name.first, first.isASCII, first.isLetter || first.isNumber
        else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// The update file's JSON, when it keeps every rule for `channel`; the signature is checked apart.
    public static func parse(_ data: Data, channel: UpdateChannel = .stable) -> Result<UpdateFile, UpdateFileError> {
        guard data.count <= maxLength else { return .failure(.invalid("it is too long")) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalid("it is not a JSON object"))
        }
        guard let version = object["version"] as? String, SartoVersion.isChannelVersion(version, channel: channel) else {
            return .failure(.invalid(channel == .stable ? "its version is not X.Y.Z" : "its version is not a valid beta or release version"))
        }
        var declaredChannel: UpdateChannel = channel
        if let value = object["channel"], !(value is NSNull) {
            guard let text = value as? String, let parsed = UpdateChannel(rawValue: text) else {
                return .failure(.invalid("its channel is not stable or beta"))
            }
            if channel == .stable && parsed != .stable {
                return .failure(.invalid("a stable update file cannot declare channel \(parsed.rawValue)"))
            }
            declaredChannel = parsed
        }
        var build: String?
        if let value = object["build"], !(value is NSNull) {
            guard let text = value as? String, SartoVersion.isValidBuildNumber(text) else {
                return .failure(.invalid("its build is not a valid build number"))
            }
            build = text
        }
        var daemonVersion: String?
        if let value = object["daemonVersion"], !(value is NSNull) {
            guard let text = value as? String, SartoVersion.isChannelVersion(text, channel: channel) else {
                return .failure(.invalid("its daemonVersion is not valid for this channel"))
            }
            daemonVersion = text
        }
        var daemonBuild: String?
        if let value = object["daemonBuild"], !(value is NSNull) {
            guard let text = value as? String, SartoVersion.isValidBuildNumber(text) else {
                return .failure(.invalid("its daemonBuild is not a valid build number"))
            }
            daemonBuild = text
        }
        var tag: String?
        if let value = object["tag"], !(value is NSNull) {
            guard let text = value as? String, SartoVersion.isValidTag(text) else {
                return .failure(.invalid("its tag is not a valid release tag"))
            }
            tag = text
        }
        let releaseDate = object["releaseDate"] as? String
        var minimum: String?
        if let value = object["minimumSystemVersion"], !(value is NSNull) {
            guard let text = value as? String, text.count <= 16,
                  text.split(separator: ".", omittingEmptySubsequences: false)
                      .allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
            else { return .failure(.invalid("its minimum system version is not a version")) }
            minimum = text
        }
        guard let rawFiles = object["files"] as? [Any], (1...maxFiles).contains(rawFiles.count) else {
            return .failure(.invalid("it lists no files or more than \(maxFiles)"))
        }
        var files: [UpdateAsset] = []
        for raw in rawFiles {
            guard let file = raw as? [String: Any],
                  let name = file["name"] as? String, isFileName(name),
                  let size = UpdateSources.integer(file["size"]), size > 0, size <= 8 << 30,
                  let hash = file["sha512"] as? String,
                  let sha512 = Data(base64Encoded: hash), sha512.count == 64
            else { return .failure(.invalid("a file has no valid name, size or SHA-512")) }
            guard !files.contains(where: { $0.name == name }) else {
                return .failure(.invalid("it lists \(name) twice"))
            }
            var from: String?
            if let value = file["from"], !(value is NSNull) {
                guard let text = value as? String, SartoVersion.isChannelVersion(text, channel: channel) else {
                    return .failure(.invalid("the delta \(name) is not from a version"))
                }
                from = text
            }
            files.append(UpdateAsset(name: name, size: Int64(size), sha512: sha512, from: from))
        }
        var notes: [String: [String]] = [:]
        if let rawNotes = object["notes"], !(rawNotes is NSNull) {
            guard let byLanguage = rawNotes as? [String: Any] else {
                return .failure(.invalid("its notes are not by language"))
            }
            for (language, list) in byLanguage where languages.contains(language) {
                guard let items = list as? [Any], items.count <= maxNotes else {
                    return .failure(.invalid("its \(language) notes are not a short list"))
                }
                let lines = items.compactMap { $0 as? String }
                guard lines.count == items.count, lines.allSatisfy({ !$0.isEmpty && $0.count <= maxNote }) else {
                    return .failure(.invalid("its \(language) notes are not short lines"))
                }
                notes[language] = lines
            }
        }
        var runtime: String?
        if let value = object["runtime"], !(value is NSNull) {
            guard let text = value as? String, RuntimeFingerprint.isValid(text) else {
                return .failure(.invalid("its runtime is not a fingerprint"))
            }
            runtime = text
        }
        return .success(UpdateFile(
            version: version,
            channel: declaredChannel,
            build: build,
            daemonVersion: daemonVersion,
            daemonBuild: daemonBuild,
            tag: tag,
            releaseDate: releaseDate,
            minimumSystemVersion: minimum,
            files: files,
            notes: notes,
            runtime: runtime
        ))
    }

    /// The update file when `signatureFile` signs it under the release keys for `channel` and it
    /// keeps every rule.
    public static func verified(
        _ data: Data,
        signatureFile: Data,
        channel: UpdateChannel = .stable,
        keys: [String] = SartoUpdateKeys.release
    ) -> Result<UpdateFile, UpdateFileError> {
        let expectedName = name(for: channel)
        guard UpdateSignature.verifyUpdateFile(name: expectedName, file: data, signatureFile: signatureFile, keys: keys) else {
            return .failure(.unsigned)
        }
        return parse(data, channel: channel)
    }
}

public enum UpdateFileError: Error, Equatable, Sendable {
    case unsigned
    case invalid(String)

    public var reason: String {
        switch self {
        case .unsigned: return "its signature does not hold"
        case .invalid(let reason): return reason
        }
    }
}
