import CryptoKit
import Foundation

public enum RelayCloseCode: Int, Sendable, Codable {
    case tooBig = 1009
    case malformed = 4400
    case unauthorized = 4401
    case forbidden = 4403
    case offline = 4404
    case timeout = 4408
    case replaced = 4409
    case tooMany = 4429
}

public struct RelayRegion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let url: String
    public let pin: String?

    public init(id: String, url: String, pin: String? = nil) {
        self.id = id
        self.url = url
        self.pin = pin
    }
}

public struct RelayInfo: Codable, Sendable, Equatable {
    public let relay: String
    public let protocolVersion: Int
    public let regions: [RelayRegion]
    public let features: [String]

    enum CodingKeys: String, CodingKey {
        case relay
        case protocolVersion = "protocol"
        case regions
        case features
    }

    public init(
        relay: String,
        protocolVersion: Int = RelayProtocol.protocolVersion,
        regions: [RelayRegion] = [],
        features: [String] = []
    ) {
        self.relay = relay
        self.protocolVersion = protocolVersion
        self.regions = regions
        self.features = features
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.relay = try c.decode(String.self, forKey: .relay)
        self.protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        self.regions = try c.decodeIfPresent([RelayRegion].self, forKey: .regions) ?? []
        self.features = try c.decodeIfPresent([String].self, forKey: .features) ?? []
    }
}

public struct RelayListedHost: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let key: String
    public let name: String
    public let platform: String

    public init(id: String, key: String, name: String, platform: String) {
        self.id = id
        self.key = key
        self.name = name
        self.platform = platform
    }

    /// Decodes the host's 32-byte X25519 static public key from base64url or standard base64.
    public var hostPublicKeyData: Data? {
        if let b64url = BaseEncoding.base64URLDecode(key), b64url.count == 32 {
            return b64url
        }
        if let b64 = Data(base64Encoded: key), b64.count == 32 {
            return b64
        }
        return nil
    }
}

public struct DeviceConnectMessage: Codable, Sendable, Equatable {
    public let type: String
    public let token: String
    public let features: [String]?

    public init(token: String, features: [String]? = ["drain"]) {
        self.type = "connect"
        self.token = token
        self.features = features
    }
}

public enum RelayProtocol {
    public static let protocolVersion = 1
    public static let signInContext = "sarto-relay/1"
    public static let ping = "ping"
    public static let pong = "pong"
    public static let maxMessageBytes = 64 * 1024

    /// Computes a host's 26-character base32 relay ID from its 32-byte Ed25519 public key.
    public static func hostID(fromEd25519PublicKey publicKey: Data) throws -> String {
        guard publicKey.count == 32 else { throw NoiseError.invalidKeyLength }
        let digest = Data(SHA256.hash(data: publicKey))
        return BaseEncoding.base32Encode(digest.prefix(16))
    }

    /// Constructs the canonical sign-in challenge bytes matching src/shared/remote/relay.ts.
    public static func signInText(origin: String, hostID: String, nonce: String) -> Data {
        Data([signInContext, origin, hostID, nonce].joined(separator: "\n").utf8)
    }

    /// Signs a relay challenge using a 32-byte Ed25519 seed.
    public static func signChallenge(
        ed25519Seed: Data,
        origin: String,
        hostID: String,
        nonce: String
    ) throws -> (publicKey: Data, signature: Data) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519Seed)
        let message = signInText(origin: origin, hostID: hostID, nonce: nonce)
        let sig = try key.signature(for: message)
        return (key.publicKey.rawRepresentation, sig)
    }

    /// Verifies an Ed25519 signature over arbitrary bytes.
    public static func verifySignature(
        ed25519PublicKey: Data,
        signature: Data,
        over data: Data
    ) -> Bool {
        guard ed25519PublicKey.count == 32, signature.count == 64 else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: ed25519PublicKey) else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    public static func isValidHostID(_ hostID: String) -> Bool {
        hostID.count == 26 && hostID.utf8.allSatisfy { byte in
            (byte >= 97 && byte <= 122) || (byte >= 50 && byte <= 55)
        }
    }

    public static func connectSocketURL(origin: String, hostID: String) -> URL? {
        guard isValidHostID(hostID) else { return nil }
        let trimmed = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        let wsOrigin: String
        if trimmed.hasPrefix("https://") {
            wsOrigin = "wss://" + trimmed.dropFirst("https://".count)
        } else if trimmed.hasPrefix("http://") {
            wsOrigin = "ws://" + trimmed.dropFirst("http://".count)
        } else {
            return nil
        }
        return URL(string: "\(wsOrigin)/v1/hosts/\(hostID)/connect")
    }

    /// Whether a relay named by a pairing link, a stored host or a welcome is one the account's
    /// token may be sent to: the configured relay `main`, or a host under it, over the same scheme.
    /// Anything else could take the token, a sibling under the same parent domain included. The
    /// rule is `trustedRelay` in src/shared/remote/relay.ts; unlike it, an origin must be written
    /// as `scheme://host[:port]` and nothing more, so no URL parser can read it another way.
    public static func isTrustedRelay(_ origin: String, main: String) -> Bool {
        guard let relay = originParts(origin), let ours = originParts(main), relay.scheme == ours.scheme else {
            return false
        }
        if relay.host == ours.host { return relay.port == ours.port }
        // A main relay on a name of its own, as localhost or an address, vouches for no other.
        let isAddress = ours.host.hasPrefix("[") || ours.host.allSatisfy { $0.isNumber || $0 == "." }
        guard ours.host.contains("."), !isAddress else { return false }
        return relay.host.hasSuffix(".\(ours.host)")
    }

    /// The scheme, host and port of an http or https origin, in lowercase and with the scheme's
    /// port when it names none; nil for anything but `scheme://host[:port]` with an optional `/`.
    private static func originParts(_ origin: String) -> (scheme: String, host: String, port: Int)? {
        var text = Substring(origin.lowercased())
        if text.hasSuffix("/") { text = text.dropLast() }
        let scheme: String
        var port: Int
        if text.hasPrefix("https://") {
            (scheme, port) = ("https", 443)
        } else if text.hasPrefix("http://") {
            (scheme, port) = ("http", 80)
        } else {
            return nil
        }
        text = text.dropFirst(scheme.count + 3)

        func readPort(_ digits: Substring) -> Int? {
            guard (1...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits), (1...65535).contains(value)
            else { return nil }
            return value
        }

        if text.hasPrefix("[") {
            // An IPv6 address, which keeps its brackets.
            guard let close = text.firstIndex(of: "]") else { return nil }
            let address = text[text.index(after: text.startIndex)..<close]
            guard !address.isEmpty, address.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") }) else {
                return nil
            }
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let named = readPort(rest.dropFirst()) else { return nil }
                port = named
            }
            return (scheme, "[\(address)]", port)
        }

        var host = text
        if let colon = text.lastIndex(of: ":") {
            guard let named = readPort(text[text.index(after: colon)...]) else { return nil }
            port = named
            host = text[..<colon]
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }) else { return nil }
        return (scheme, String(host), port)
    }
}
