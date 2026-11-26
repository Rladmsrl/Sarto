import Foundation

/// Sarto Host Channel Protocol v4 messages (src/shared/remote/protocol.ts).
public enum HostProtocolVersion {
    public static let min = 1
    public static let max = 4
}

public struct ProtocolRange: Codable, Sendable, Equatable {
    public let min: Int
    public let max: Int

    public init(min: Int = HostProtocolVersion.min, max: Int = HostProtocolVersion.max) {
        self.min = min
        self.max = max
    }
}

public struct HelloClientInfo: Codable, Sendable, Equatable {
    public let kind: String
    public let version: String
    public let platform: String

    public init(kind: String, version: String, platform: String) {
        self.kind = kind
        self.version = version
        self.platform = platform
    }
}

public struct HelloDeviceInfo: Codable, Sendable, Equatable {
    public let name: String
    public let model: String

    public init(name: String, model: String) {
        self.name = name
        self.model = model
    }
}

public struct ResumeRequest: Codable, Sendable, Equatable {
    public let token: String
    public let received: Int

    public init(token: String, received: Int) {
        self.token = token
        self.received = received
    }
}

public struct HelloMessage: Codable, Sendable, Equatable {
    public let type: String
    public let `protocol`: ProtocolRange
    public let client: HelloClientInfo
    public let device: HelloDeviceInfo?
    public let features: [String]?
    public let resume: ResumeRequest?

    public init(
        client: HelloClientInfo,
        device: HelloDeviceInfo? = nil,
        features: [String]? = ["image-refs"],
        resume: ResumeRequest? = nil
    ) {
        self.type = "hello"
        self.`protocol` = ProtocolRange()
        self.client = client
        self.device = device
        self.features = features
        self.resume = resume
    }
}

public struct DirectAddress: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    /// Mirrors `isDirectHost` and `isPort` in src/shared/remote/address.ts closely enough that
    /// a value the device later interpolates into `ws://host:port/channel` cannot carry a path.
    public var isDialable: Bool {
        guard (1...65535).contains(port), !host.isEmpty, host.utf8.count <= 253 else { return false }
        for byte in host.utf8 {
            let ok = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2E || byte == 0x3A || byte == 0x2D
            if !ok { return false }
        }
        return true
    }
}

/// Decodes one element of an array, keeping nil instead of failing the whole array.
private struct LossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

public struct WelcomeHostInfo: Codable, Sendable, Equatable {
    public let name: String
    public let platform: String
    public let version: String

    public init(name: String, platform: String, version: String) {
        self.name = name
        self.platform = platform
        self.version = version
    }
}

public struct WelcomeDeviceInfo: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct WelcomeMessage: Codable, Sendable, Equatable {
    /// MAX_WELCOME_ADDRESSES in src/shared/remote/protocol.ts.
    public static let maxAddresses = 64

    public let type: String
    public let `protocol`: Int
    public let host: WelcomeHostInfo
    public let features: [String]
    public let role: String
    public let device: WelcomeDeviceInfo
    public let terminal: Bool
    public let addresses: [DirectAddress]
    public let relay: JSONValue?
    public let resume: String?
    public let resumed: Bool?
    public let resumedRequest: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case `protocol` = "protocol"
        case host
        case features
        case role
        case device
        case terminal
        case addresses
        case relay
        case resume
        case resumed
    }

    public init(
        type: String = "welcome",
        protocol protocolVersion: Int = HostProtocolVersion.max,
        host: WelcomeHostInfo,
        features: [String] = [],
        role: String = "owner",
        device: WelcomeDeviceInfo,
        terminal: Bool = false,
        addresses: [DirectAddress] = [],
        relay: JSONValue? = nil,
        resume: String? = nil,
        resumed: Bool? = nil,
        resumedRequest: Int? = nil
    ) {
        self.type = type
        self.`protocol` = protocolVersion
        self.host = host
        self.features = features
        self.role = role
        self.device = device
        self.terminal = terminal
        self.addresses = addresses
        self.relay = relay
        self.resume = resume
        self.resumed = resumed ?? (resumedRequest != nil ? true : nil)
        self.resumedRequest = resumedRequest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(String.self, forKey: .type)
        self.`protocol` = try c.decode(Int.self, forKey: .`protocol`)
        self.host = try c.decode(WelcomeHostInfo.self, forKey: .host)
        // Like parseWelcome in src/shared/remote/protocol.ts, a bad element drops only itself.
        self.features = (try? c.decodeIfPresent([LossyElement<String>].self, forKey: .features))?
            .compactMap(\.value) ?? []
        self.role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? "owner"
        self.device = try c.decode(WelcomeDeviceInfo.self, forKey: .device)
        self.terminal = (try? c.decodeIfPresent(Bool.self, forKey: .terminal)) ?? false
        self.addresses = (try? c.decodeIfPresent([LossyElement<DirectAddress>].self, forKey: .addresses))?
            .prefix(Self.maxAddresses)
            .compactMap(\.value)
            .filter(\.isDialable) ?? []
        self.relay = try c.decodeIfPresent(JSONValue.self, forKey: .relay)
        self.resume = try? c.decodeIfPresent(String.self, forKey: .resume)

        if let boolVal = try? c.decodeIfPresent(Bool.self, forKey: .resumed) {
            self.resumed = boolVal
            self.resumedRequest = nil
        } else if let resumedVal = try? c.decodeIfPresent(JSONValue.self, forKey: .resumed),
                  let obj = resumedVal.objectValue {
            self.resumed = true
            self.resumedRequest = obj["request"]?.doubleValue.flatMap(Int.wholePart(of:))
        } else {
            self.resumed = nil
            self.resumedRequest = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(`protocol`, forKey: .`protocol`)
        try c.encode(host, forKey: .host)
        try c.encode(features, forKey: .features)
        try c.encode(role, forKey: .role)
        try c.encode(device, forKey: .device)
        try c.encode(terminal, forKey: .terminal)
        try c.encode(addresses, forKey: .addresses)
        try c.encodeIfPresent(relay, forKey: .relay)
        try c.encodeIfPresent(resume, forKey: .resume)
        if let req = resumedRequest {
            try c.encode(["request": req], forKey: .resumed)
        } else {
            try c.encodeIfPresent(resumed, forKey: .resumed)
        }
    }
}
