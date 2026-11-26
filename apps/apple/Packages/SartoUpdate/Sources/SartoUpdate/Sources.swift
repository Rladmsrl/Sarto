import Foundation

/// A base URL laid out as GitHub's releases: `latest/download/<file>`, `download/v<version>/<file>`.
public struct UpdateSource: Codable, Equatable, Sendable {
    public let id: String
    public let url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }

    public func latestFileURL(_ name: String) -> URL? {
        URL(string: "\(url)/latest/download/\(Self.escape(name))")
    }

    public func releaseFileURL(tag: String, name: String) -> URL? {
        URL(string: "\(url)/download/\(Self.escape(tag))/\(Self.escape(name))")
    }

    public func releaseFileURL(version: String, name: String) -> URL? {
        releaseFileURL(tag: "v\(version)", name: name)
    }

    private static func escape(_ part: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? part
    }
}

public struct SourceList: Equatable, Sendable {
    public let serial: Int
    /// In the order to try them, the official source last.
    public let sources: [UpdateSource]
    public let connectTimeoutSeconds: Int
    /// A download without progress for this long moves on to the next source.
    public let stallSeconds: Int

    public init(serial: Int, sources: [UpdateSource], connectTimeoutSeconds: Int, stallSeconds: Int) {
        self.serial = serial
        self.sources = sources
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.stallSeconds = stallSeconds
    }
}

/// The list as the official source signs it and the app keeps it.
public struct SignedSourceList: Codable, Equatable, Sendable {
    /// base64url of the list's JSON.
    public let payload: String
    /// base64url of the Ed25519 signature over the payload's bytes.
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

public enum SourceListResult: Equatable, Sendable {
    case ok(SourceList, SignedSourceList)
    case failed(String)
}

/// Automatic tries the signed list's sources in order; official only never leaves Sarto's own.
public enum SourceChoice: String, CaseIterable, Codable, Sendable {
    case auto
    case official
}

public enum UpdateSources {
    /// Sarto's release source, served by the official Sarto server.
    public static let official = UpdateSource(id: "sarto", url: "https://sarto.1o.ink/releases")
    /// Primary public release mirror on GitHub Releases, tried before falling back to `official`.
    public static let github = UpdateSource(id: "github", url: "https://github.com/Rladmsrl/Sarto/releases")
    public static var sourcesURL: URL { URL(string: "\(official.url)/sources.json")! }

    /// Default automatic order: try GitHub Releases first, then fall back to the official server.
    public static let builtIn = SourceList(
        serial: 0,
        sources: [github, official],
        connectTimeoutSeconds: 10,
        stallSeconds: 15
    )

    /// Used when the user explicitly selects the official Sarto server alone.
    public static let officialOnly = SourceList(
        serial: 0,
        sources: [official],
        connectTimeoutSeconds: 10,
        stallSeconds: 15
    )

    static let maxSources = 8
    static let maxListLength = 64 * 1024
    static let maxURLLength = 2048

    /// The sources in order with the official one moved, or added, to the end, so no list can
    /// drop it.
    public static func withOfficialLast(_ sources: [UpdateSource]) -> [UpdateSource] {
        sources.filter { !sameURL($0.url, official.url) } + [official]
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        guard let left = URLComponents(string: a), let right = URLComponents(string: b) else { return false }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && left.port == right.port
            && left.path == right.path
    }

    /// A source's URL when it is https without credentials, query or fragment, and reads as it
    /// parses: anything a parser would quietly change or drop makes the URL other than it reads.
    static func sourceURL(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= maxURLLength else { return nil }
        if value.hasSuffix("/") { return nil }
        let forbidden = CharacterSet.whitespacesAndNewlines
            .union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\\?#"))
        if value.unicodeScalars.contains(where: forbidden.contains) { return nil }
        guard let url = URLComponents(string: value),
              url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        return value
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
        return Int(double)
    }

    static func readList(_ document: Any) -> Result<SourceList, Failure> {
        guard let document = document as? [String: Any] else { return .failure(Failure("the list is not an object")) }
        guard let serial = integer(document["serial"]), serial >= 1 else {
            return .failure(Failure("its serial is not a positive integer"))
        }
        guard let sources = document["sources"] as? [Any], (1...maxSources).contains(sources.count) else {
            return .failure(Failure("it lists no sources or more than \(maxSources)"))
        }
        var read: [UpdateSource] = []
        for source in sources {
            guard let source = source as? [String: Any],
                  let id = source["id"] as? String,
                  (1...32).contains(id.count),
                  id.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") })
            else { return .failure(Failure("a source has no valid id")) }
            guard let url = sourceURL(source["url"]) else {
                return .failure(Failure("source \(id) has no https URL without a query, fragment or credentials"))
            }
            read.append(UpdateSource(id: id, url: url))
        }
        guard let connect = integer(document["connectTimeoutSeconds"]), (1...120).contains(connect),
              let stall = integer(document["stallSeconds"]), (1...120).contains(stall)
        else { return .failure(Failure("its timeouts are not whole seconds from 1 to 120")) }
        return .success(SourceList(
            serial: serial,
            sources: withOfficialLast(read),
            connectTimeoutSeconds: connect,
            stallSeconds: stall
        ))
    }

    /// The list in a signed envelope, when its signature holds under one of `keys`, its serial is
    /// not below `minSerial` and it keeps every rule.
    public static func verify(
        _ envelope: SignedSourceList,
        minSerial: Int,
        keys: [String] = SartoUpdateKeys.sources
    ) -> SourceListResult {
        guard envelope.payload.count <= maxListLength,
              let bytes = Base64URL.decode(envelope.payload),
              let signature = Base64URL.decode(envelope.signature)
        else { return .failed("it is not a signed list") }
        guard UpdateSignature.verify(message: bytes, signature: signature, keys: keys) else {
            return .failed("its signature does not hold")
        }
        guard let document = try? JSONSerialization.jsonObject(with: bytes) else {
            return .failed("its list is not JSON")
        }
        switch readList(document) {
        case .failure(let failure):
            return .failed(failure.reason)
        case .success(let list):
            guard list.serial >= minSerial else {
                return .failed("its serial \(list.serial) is older than \(minSerial)")
            }
            return .ok(list, envelope)
        }
    }

    /// The body of `sources.json`, checked as `verify` checks the envelope it holds.
    public static func parse(
        _ body: Data,
        minSerial: Int,
        keys: [String] = SartoUpdateKeys.sources
    ) -> SourceListResult {
        guard body.count <= maxListLength * 2 else { return .failed("it is too long") }
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let payload = object["payload"] as? String,
              let signature = object["signature"] as? String
        else { return .failed("it is not a signed list") }
        return verify(SignedSourceList(payload: payload, signature: signature), minSerial: minSerial, keys: keys)
    }

    struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }
}

/// The sources of one check, in order, from the one that answered it to the last.
public struct SourceRun: Equatable, Sendable {
    public let sources: [UpdateSource]
    public let stallSeconds: Int
    public let connectTimeoutSeconds: Int
    private let start: Int
    private var index: Int

    public init(list: SourceList, start: Int = 0) {
        precondition(!list.sources.isEmpty)
        self.sources = list.sources
        self.stallSeconds = list.stallSeconds
        self.connectTimeoutSeconds = list.connectTimeoutSeconds
        self.start = min(max(start, 0), list.sources.count - 1)
        self.index = self.start
    }

    public var current: UpdateSource { sources[index] }

    /// Moves on to the next source; nil when this was the last.
    public mutating func next() -> UpdateSource? {
        guard index + 1 < sources.count else { return nil }
        index += 1
        return current
    }

    /// The same sources from the one that answered the check, for another download.
    public func again() -> SourceRun {
        var run = self
        run.index = start
        return run
    }

    /// The same sources, from the one in use now.
    public func fromCurrent() -> SourceRun {
        SourceRun(list: SourceList(
            serial: 0,
            sources: sources,
            connectTimeoutSeconds: connectTimeoutSeconds,
            stallSeconds: stallSeconds
        ), start: index)
    }
}

/// What one check finds as it asks the sources of a `SourceRun` in turn for the signed update files
/// of `channel`. Beta takes each source's stable file too, since beta follows stable releases, but
/// only a source with a beta file answers for beta: GitHub serves no `beta-mac.json` at
/// `latest/download`, as a prerelease is never its latest release, so the next source is asked.
public struct UpdateSearch: Sendable {
    public struct Found: Sendable {
        public let file: UpdateFile
        /// The sources from the one that offered `file`, to download it from.
        public let run: SourceRun
    }

    public let channel: UpdateChannel
    /// The running version.
    public let current: String
    /// The newest file a source offered; the earlier source keeps a version two of them offer.
    public private(set) var found: Found?

    public init(channel: UpdateChannel, current: String) {
        self.channel = channel
        self.current = current
    }

    /// Takes what the source `run` is at offered: `own`, its verified file for `channel`, nil when
    /// it has none or it could not be read, and on beta `stable`, its verified stable file. True
    /// when the search ends here: the source answered for the channel with no version older than
    /// the running one. A source that lags behind sends the search on, and one up to date ends it,
    /// so a check does not ask every source each time.
    public mutating func take(own: UpdateFile?, stable: UpdateFile?, from run: SourceRun) -> Bool {
        let offered = [own, channel == .beta ? stable : nil].compactMap { $0 }
        for file in offered where found.map({ SartoVersion.isNewer(file.version, than: $0.file.version) }) ?? true {
            found = Found(file: file, run: run)
        }
        guard own != nil, let newest = offered.max(by: { SartoVersion.isNewer($1.version, than: $0.version) })
        else { return false }
        return !SartoVersion.isNewer(current, than: newest.version)
    }
}
