import Foundation

// MARK: - Host System Load Models (src/shared/host-load.ts)

public enum HostLoadConstants {
    /// How long a `host.load.watch` lease lasts unless renewed.
    public static let leaseSeconds: TimeInterval = 30
    /// Renew well before the 30s lease expires.
    public static let renewSeconds: TimeInterval = 20
    public static let diskWarnBytes: Double = 10_000_000_000
    public static let diskCriticalBytes: Double = 2_000_000_000
    public static let batteryWarnPercent: Double = 20
    public static let batteryCriticalPercent: Double = 10
    /// Feature advertised in `WelcomeMessage.features` by hosts supporting `host.load.watch`.
    public static let feature = "load"
}

public struct HostLoadCPU: Codable, Sendable, Equatable {
    public let percent: Double
    public let cores: Double

    public init(percent: Double, cores: Double) {
        self.percent = percent
        self.cores = cores
    }
}

public struct HostLoadMemory: Codable, Sendable, Equatable {
    public let used: Double
    public let total: Double
    /// `"ok"` | `"low"` | `"critical"`
    public let state: String

    public init(used: Double, total: Double, state: String) {
        self.used = used
        self.total = total
        self.state = state
    }

    public var usedPercent: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }
}

public struct HostLoadDisk: Codable, Sendable, Equatable {
    public let name: String
    public let free: Double
    public let total: Double

    public init(name: String, free: Double, total: Double) {
        self.name = name
        self.free = free
        self.total = total
    }

    public var usedPercent: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, ((total - free) / total) * 100))
    }
}

public struct HostLoadIO: Codable, Sendable, Equatable {
    public let readPerSecond: Double
    public let writePerSecond: Double

    public init(readPerSecond: Double, writePerSecond: Double) {
        self.readPerSecond = readPerSecond
        self.writePerSecond = writePerSecond
    }
}

public struct HostLoadNetwork: Codable, Sendable, Equatable {
    public let receivePerSecond: Double
    public let sendPerSecond: Double

    public init(receivePerSecond: Double, sendPerSecond: Double) {
        self.receivePerSecond = receivePerSecond
        self.sendPerSecond = sendPerSecond
    }
}

public struct HostBattery: Codable, Sendable, Equatable {
    public let percent: Double?
    public let charging: Bool
    public let onBattery: Bool
    public let minutesLeft: Double?

    public init(percent: Double? = nil, charging: Bool, onBattery: Bool, minutesLeft: Double? = nil) {
        self.percent = percent
        self.charging = charging
        self.onBattery = onBattery
        self.minutesLeft = minutesLeft
    }
}

public struct HostLoad: Codable, Sendable, Equatable {
    public let at: Double
    public let cpu: HostLoadCPU
    public let memory: HostLoadMemory
    public let disk: HostLoadDisk?
    public let io: HostLoadIO?
    public let network: HostLoadNetwork?
    public let battery: HostBattery?
    public let container: Bool?

    public init(
        at: Double,
        cpu: HostLoadCPU,
        memory: HostLoadMemory,
        disk: HostLoadDisk? = nil,
        io: HostLoadIO? = nil,
        network: HostLoadNetwork? = nil,
        battery: HostBattery? = nil,
        container: Bool? = nil
    ) {
        self.at = at
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.io = io
        self.network = network
        self.battery = battery
        self.container = container
    }
}

public struct HostLoadWatch: Codable, Sendable, Equatable {
    public let load: HostLoad

    public init(load: HostLoad) {
        self.load = load
    }
}
