import Foundation

// MARK: - Device Host Protocol Models (src/shared/device-host.ts)

public enum DevicePlatform: String, Codable, Sendable, Equatable, CaseIterable {
    case ios
    case android
}

public enum DeviceKind: String, Codable, Sendable, Equatable {
    case simulator
    case emulator
    case physical
}

public enum DeviceState: String, Codable, Sendable, Equatable {
    case booted
    case booting
    case shutdown
    case connected
    case unavailable
}

public enum DeviceOrientation: String, Codable, Sendable, Equatable {
    case portrait
    case portraitUpsideDown = "portrait_upside_down"
    case landscapeLeft = "landscape_left"
    case landscapeRight = "landscape_right"

    public var isLandscape: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

public enum DeviceAppearance: String, Codable, Sendable, Equatable {
    case light
    case dark
}

public struct DeviceControlState: Codable, Sendable, Equatable {
    public let kind: String // "agent" | "you" | "asks" | "idle"
    public let acting: Bool?
    public let since: Double?

    public init(kind: String, acting: Bool? = nil, since: Double? = nil) {
        self.kind = kind
        self.acting = acting
        self.since = since
    }
}

public struct DeviceOperatorInfo: Codable, Sendable, Equatable {
    public let sessionId: String?
    public let agentName: String?
    public let user: Bool
    public let control: DeviceControlState?

    public init(
        sessionId: String? = nil,
        agentName: String? = nil,
        user: Bool = false,
        control: DeviceControlState? = nil
    ) {
        self.sessionId = sessionId
        self.agentName = agentName
        self.user = user
        self.control = control
    }

    enum CodingKeys: String, CodingKey {
        case sessionId
        case agentName
        case user
        case control
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.agentName = try c.decodeIfPresent(String.self, forKey: .agentName)
        self.user = try c.decodeIfPresent(Bool.self, forKey: .user) ?? false
        self.control = try c.decodeIfPresent(DeviceControlState.self, forKey: .control)
    }
}

public struct MobileDeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let platform: DevicePlatform
    public let kind: DeviceKind
    public let name: String
    public let osVersion: String?
    public let model: String?
    public let state: DeviceState
    public let connection: String?
    public let sessionId: String?
    public let `operator`: DeviceOperatorInfo?
    public let problems: [String]
    public let input: Bool
    public let bootedByHost: Bool

    public init(
        id: String,
        platform: DevicePlatform,
        kind: DeviceKind,
        name: String,
        osVersion: String? = nil,
        model: String? = nil,
        state: DeviceState = .shutdown,
        connection: String? = nil,
        sessionId: String? = nil,
        operator op: DeviceOperatorInfo? = nil,
        problems: [String] = [],
        input: Bool = false,
        bootedByHost: Bool = false
    ) {
        self.id = id
        self.platform = platform
        self.kind = kind
        self.name = name
        self.osVersion = osVersion
        self.model = model
        self.state = state
        self.connection = connection
        self.sessionId = sessionId
        self.`operator` = op
        self.problems = problems
        self.input = input
        self.bootedByHost = bootedByHost
    }

    enum CodingKeys: String, CodingKey {
        case id, platform, kind, name, osVersion, model, state, connection, sessionId
        case `operator` = "operator"
        case problems, input, bootedByHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.platform = try c.decode(DevicePlatform.self, forKey: .platform)
        self.kind = try c.decode(DeviceKind.self, forKey: .kind)
        self.name = try c.decode(String.self, forKey: .name)
        self.osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.state = try c.decodeIfPresent(DeviceState.self, forKey: .state) ?? .unavailable
        self.connection = try c.decodeIfPresent(String.self, forKey: .connection)
        self.sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        self.`operator` = try c.decodeIfPresent(DeviceOperatorInfo.self, forKey: .`operator`)
        self.problems = try c.decodeIfPresent([String].self, forKey: .problems) ?? []
        self.input = try c.decodeIfPresent(Bool.self, forKey: .input) ?? false
        self.bootedByHost = try c.decodeIfPresent(Bool.self, forKey: .bootedByHost) ?? false
    }
}

public struct DeviceEnvironmentInfo: Codable, Sendable, Equatable {
    public let platform: String
    public let ios: Bool
    public let iosStream: Bool
    public let android: Bool
    public let problems: [String]

    public init(
        platform: String = "darwin",
        ios: Bool = false,
        iosStream: Bool = false,
        android: Bool = false,
        problems: [String] = []
    ) {
        self.platform = platform
        self.ios = ios
        self.iosStream = iosStream
        self.android = android
        self.problems = problems
    }
}

public struct DeviceScreenInfo: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let orientation: DeviceOrientation
    public let codec: String

    public init(width: Int, height: Int, orientation: DeviceOrientation = .portrait, codec: String) {
        self.width = width
        self.height = height
        self.orientation = orientation
        self.codec = codec
    }
}

public struct DeviceActPoint: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct DeviceFrameRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct DeviceFrameHover: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
}

public struct DeviceFrameButtonInfo: Codable, Sendable, Equatable {
    public let name: String
    public let down: String? // base64 PNG
    public let hover: DeviceFrameHover
}

public struct DeviceFrameImageInfo: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let png: String // base64 PNG
    public let button: DeviceFrameButtonInfo?
}

public struct DeviceFrameBodyInfo: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let radius: Double
}

public struct DeviceFrameInfo: Codable, Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let screen: DeviceFrameRect
    public let radii: [Double]
    public let body: DeviceFrameBodyInfo?
    public let images: [DeviceFrameImageInfo]
}

public enum DeviceInputAction: Sendable, Equatable {
    case touch(phase: String, x: Double, y: Double, finger: Int? = nil)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case key(phase: String, code: String)
    case text(String)
    case button(String)
    case frameButton(name: String, phase: String)

    public func toJSONValue() -> JSONValue {
        switch self {
        case .touch(let phase, let x, let y, let finger):
            var obj: [String: JSONValue] = [
                "type": .string("touch"),
                "phase": .string(phase),
                "x": .number(x),
                "y": .number(y),
            ]
            if let finger { obj["finger"] = .number(Double(finger)) }
            return .object(obj)
        case .scroll(let x, let y, let dx, let dy):
            return .object([
                "type": .string("scroll"),
                "x": .number(x),
                "y": .number(y),
                "dx": .number(dx),
                "dy": .number(dy),
            ])
        case .key(let phase, let code):
            return .object([
                "type": .string("key"),
                "phase": .string(phase),
                "code": .string(code),
            ])
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text),
            ])
        case .button(let button):
            return .object([
                "type": .string("button"),
                "button": .string(button),
            ])
        case .frameButton(let name, let phase):
            return .object([
                "type": .string("frameButton"),
                "name": .string(name),
                "phase": .string(phase),
            ])
        }
    }
}

public enum DeviceEvent: Sendable, Equatable {
    case devicesChanged([MobileDeviceInfo])
    case deviceScreen(deviceId: String, screen: DeviceScreenInfo)
    /// `data` holds raw avcC/hvcC description bytes, JPEG seed bytes, or AVCC/HVCC access-unit bytes.
    case deviceFrame(deviceId: String, seq: Int, kind: String, data: Data)
    case deviceStream(deviceId: String, state: String, error: String?)
    case devicesRestarted
    case deviceOpened(deviceId: String, sessionId: String)
    case deviceAct(deviceId: String, at: DeviceActPoint?)
    case unknown(type: String)

    public static let knownEventTypes: Set<String> = [
        "devices.changed",
        "device.screen",
        "device.frame",
        "device.stream",
        "devices.restarted",
        "device.opened",
        "device.act",
    ]

    private struct TypeProbe: Decodable {
        struct Inner: Decodable { let type: String }
        let event: Inner
    }

    private struct TypedEnvelope<Payload: Decodable>: Decodable {
        let event: Payload
    }

    private struct ChangedPayload: Decodable { let devices: [MobileDeviceInfo] }
    private struct ScreenPayload: Decodable { let deviceId: String; let screen: DeviceScreenInfo }
    private struct FramePayload: Decodable {
        let deviceId: String
        let seq: Int
        let kind: String
        let data: String
    }
    private struct StreamPayload: Decodable {
        let deviceId: String
        let state: String
        let error: String?
    }
    private struct OpenedPayload: Decodable { let deviceId: String; let sessionId: String }
    private struct ActPayload: Decodable { let deviceId: String; let at: DeviceActPoint? }

    public static func decode(fromEnvelopeData data: Data) -> DeviceEvent? {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            return nil
        }
        let type = probe.event.type
        guard knownEventTypes.contains(type) else { return nil }
        switch type {
        case "devices.changed":
            if let env = try? decoder.decode(TypedEnvelope<ChangedPayload>.self, from: data) {
                return .devicesChanged(env.event.devices)
            }
        case "device.screen":
            if let env = try? decoder.decode(TypedEnvelope<ScreenPayload>.self, from: data) {
                return .deviceScreen(deviceId: env.event.deviceId, screen: env.event.screen)
            }
        case "device.frame":
            if let env = try? decoder.decode(TypedEnvelope<FramePayload>.self, from: data),
               let raw = Data(base64Encoded: env.event.data) {
                return .deviceFrame(
                    deviceId: env.event.deviceId,
                    seq: env.event.seq,
                    kind: env.event.kind,
                    data: raw
                )
            }
        case "device.stream":
            if let env = try? decoder.decode(TypedEnvelope<StreamPayload>.self, from: data) {
                return .deviceStream(
                    deviceId: env.event.deviceId,
                    state: env.event.state,
                    error: env.event.error
                )
            }
        case "devices.restarted":
            return .devicesRestarted
        case "device.opened":
            if let env = try? decoder.decode(TypedEnvelope<OpenedPayload>.self, from: data) {
                return .deviceOpened(deviceId: env.event.deviceId, sessionId: env.event.sessionId)
            }
        case "device.act":
            if let env = try? decoder.decode(TypedEnvelope<ActPayload>.self, from: data) {
                return .deviceAct(deviceId: env.event.deviceId, at: env.event.at)
            }
        default:
            break
        }
        return .unknown(type: type)
    }

    public static func decode(from value: JSONValue) -> DeviceEvent {
        guard let obj = value.objectValue, let type = obj["type"]?.stringValue else {
            return .unknown(type: "invalid")
        }
        switch type {
        case "devices.changed":
            if let list = obj["devices"], let decoded = try? list.decode([MobileDeviceInfo].self) {
                return .devicesChanged(decoded)
            }
        case "device.screen":
            if let did = obj["deviceId"]?.stringValue,
               let screen = obj["screen"],
               let decoded = try? screen.decode(DeviceScreenInfo.self) {
                return .deviceScreen(deviceId: did, screen: decoded)
            }
        case "device.frame":
            if let did = obj["deviceId"]?.stringValue,
               let seq = obj["seq"]?.doubleValue,
               let kind = obj["kind"]?.stringValue,
               let b64 = obj["data"]?.stringValue,
               let raw = Data(base64Encoded: b64) {
                return .deviceFrame(deviceId: did, seq: Int(seq), kind: kind, data: raw)
            }
        case "device.stream":
            if let did = obj["deviceId"]?.stringValue,
               let state = obj["state"]?.stringValue {
                return .deviceStream(deviceId: did, state: state, error: obj["error"]?.stringValue)
            }
        case "devices.restarted":
            return .devicesRestarted
        case "device.opened":
            if let did = obj["deviceId"]?.stringValue,
               let sid = obj["sessionId"]?.stringValue {
                return .deviceOpened(deviceId: did, sessionId: sid)
            }
        case "device.act":
            if let did = obj["deviceId"]?.stringValue {
                let pt = obj["at"].flatMap { try? $0.decode(DeviceActPoint.self) }
                return .deviceAct(deviceId: did, at: pt)
            }
        default:
            break
        }
        return .unknown(type: type)
    }
}
