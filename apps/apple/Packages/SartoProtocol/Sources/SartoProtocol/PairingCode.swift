import Foundation

public struct PairingRelay: Codable, Sendable, Equatable {
    public let id: String
    public let urls: [String]

    public init(id: String, urls: [String]) {
        self.id = id
        self.urls = urls
    }
}

/// Binary pairing payload matching src/shared/remote/pairing.ts (versions 1 and 2).
public struct PairingPayload: Sendable, Equatable {
    public let version: Int
    public let hostKey: Data
    public let secret: Data
    public let addresses: [DirectAddress]
    public let relay: PairingRelay?

    public init(
        version: Int = 2,
        hostKey: Data,
        secret: Data,
        addresses: [DirectAddress] = [],
        relay: PairingRelay? = nil
    ) {
        self.version = relay == nil ? 1 : version
        self.hostKey = hostKey
        self.secret = secret
        self.addresses = addresses
        self.relay = relay
    }
}

public enum PairingError: Error, Sendable, Equatable {
    case invalidKeyOrSecretLength
    case invalidRelayID
    case invalidRelayOrigin
    case invalidAddress
    case malformedPayload
}

public enum PairingCode {
    public static let directVersion = 1
    public static let relayVersion = 2
    public static let maxAddresses = 16
    public static let maxRelays = 4

    private static let keyBytes = 32
    private static let secretBytes = 32
    private static let headerBytes = 1 + keyBytes + secretBytes
    private static let relayIDBytes = 16

    public static func encode(_ payload: PairingPayload) throws -> String {
        guard payload.hostKey.count == keyBytes, payload.secret.count == secretBytes else {
            throw PairingError.invalidKeyOrSecretLength
        }

        var bytes = Data()
        let version = payload.relay == nil ? directVersion : relayVersion
        bytes.append(UInt8(version))
        bytes.append(payload.hostKey)
        bytes.append(payload.secret)

        if let relay = payload.relay {
            guard relay.id.count == 26,
                  let idBytes = BaseEncoding.base32Decode(relay.id),
                  idBytes.count == relayIDBytes
            else {
                throw PairingError.invalidRelayID
            }
            bytes.append(idBytes)
            let clippedURLs = Array(relay.urls.prefix(maxRelays))
            bytes.append(UInt8(clippedURLs.count))
            for url in clippedURLs {
                guard isCanonicalOrigin(url) else { throw PairingError.invalidRelayOrigin }
                let raw = Data(url.utf8)
                guard !raw.isEmpty, raw.count <= 255 else { throw PairingError.invalidRelayOrigin }
                bytes.append(UInt8(raw.count))
                bytes.append(raw)
            }
        }

        for addr in payload.addresses.prefix(maxAddresses) {
            let hostData = Data(addr.host.utf8)
            guard !hostData.isEmpty, hostData.count <= 253,
                  isValidHostChars(addr.host),
                  addr.port >= 1, addr.port <= 65535
            else {
                throw PairingError.invalidAddress
            }
            bytes.append(UInt8(hostData.count))
            bytes.append(hostData)
            bytes.append(UInt8((addr.port >> 8) & 0xff))
            bytes.append(UInt8(addr.port & 0xff))
        }

        return BaseEncoding.base64URLEncode(bytes)
    }

    public static func decode(_ code: String) -> PairingPayload? {
        guard let bytes = BaseEncoding.base64URLDecode(code), bytes.count >= headerBytes else {
            return nil
        }
        let version = Int(bytes[0])
        guard version == directVersion || version == relayVersion else { return nil }

        let hostKey = Data(bytes[1..<(1 + keyBytes)])
        let secret = Data(bytes[(1 + keyBytes)..<headerBytes])
        var offset = headerBytes
        var relay: PairingRelay?

        if version == relayVersion {
            guard offset + relayIDBytes + 1 <= bytes.count else { return nil }
            let id = BaseEncoding.base32Encode(Data(bytes[offset..<(offset + relayIDBytes)]))
            offset += relayIDBytes
            let count = Int(bytes[offset])
            offset += 1
            guard count <= maxRelays else { return nil }
            var urls: [String] = []
            for _ in 0..<count {
                guard offset < bytes.count else { return nil }
                let len = Int(bytes[offset])
                guard len > 0, offset + 1 + len <= bytes.count else { return nil }
                let slice = Data(bytes[(offset + 1)..<(offset + 1 + len)])
                offset += 1 + len
                guard let url = String(data: slice, encoding: .ascii), isCanonicalOrigin(url) else {
                    return nil
                }
                urls.append(url)
            }
            relay = PairingRelay(id: id, urls: urls)
        }

        var addresses: [DirectAddress] = []
        while offset < bytes.count {
            let len = Int(bytes[offset])
            guard len > 0, offset + 1 + len + 2 <= bytes.count else { return nil }
            let hostSlice = Data(bytes[(offset + 1)..<(offset + 1 + len)])
            offset += 1 + len
            let port = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
            offset += 2
            guard let host = String(data: hostSlice, encoding: .ascii),
                  isValidHostChars(host),
                  port >= 1, port <= 65535,
                  addresses.count < maxAddresses
            else {
                return nil
            }
            addresses.append(DirectAddress(host: host, port: port))
        }

        return PairingPayload(
            version: version,
            hostKey: hostKey,
            secret: secret,
            addresses: addresses,
            relay: relay
        )
    }

    private static func isValidHostChars(_ host: String) -> Bool {
        for scalar in host.unicodeScalars {
            let v = scalar.value
            let ok = (v >= 65 && v <= 90) || (v >= 97 && v <= 122) || (v >= 48 && v <= 57)
                || v == 46 || v == 58 || v == 95 || v == 45
            if !ok { return false }
        }
        return true
    }

    private static func isCanonicalOrigin(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil
        else {
            return false
        }
        // Foundation's URL.host strips brackets on IPv6 literals such as http://[::1]:8787.
        let lowerHost = host.lowercased()
        let formattedHost = (lowerHost.contains(":") && !lowerHost.hasPrefix("["))
            ? "[\(lowerHost)]"
            : lowerHost
        var expected = "\(scheme)://\(formattedHost)"
        if let port = url.port {
            let isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
            if !isDefault { expected += ":\(port)" }
        }
        return value == expected
    }
}
