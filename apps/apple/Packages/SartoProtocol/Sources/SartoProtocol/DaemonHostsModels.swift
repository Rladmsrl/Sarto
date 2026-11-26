import Foundation

// MARK: - Other Hosts Through the Local Daemon (docs/sarto-remote-design.md)

/// Where another host is on the relay, as the daemon's `HostClient` keeps it.
public struct OtherHostRelay: Codable, Sendable, Equatable {
    public let id: String
    public let urls: [String]
}

/// How the daemon's connection to another host stands (`HostConnection` in `src/shared/remote/hosts.ts`).
public struct OtherHostConnection: Codable, Sendable, Equatable {
    /// `connecting`, `online`, `offline` or `stopped`.
    public let state: String
    /// Online through the relay: its origin. Offline: what the relay answered, if anything.
    public let relay: String?
    /// Online through a direct address.
    public let address: DirectAddress?
    /// Online: whether its owner allows devices the terminal.
    public let terminal: Bool?
    /// Stopped: `removed`, `update_client` or `update_host`.
    public let reason: String?

    public var isOnline: Bool { state == "online" }
    public var isConnecting: Bool { state == "connecting" }
    /// Online through the relay rather than a direct address.
    public var viaRelay: Bool { isOnline && address == nil }
    public var allowsTerminal: Bool { terminal == true }
}

/// Another host the daemon knows (`HostStatus` in `src/shared/remote/hosts.ts`).
public struct OtherHostStatus: Codable, Sendable, Equatable, Identifiable {
    /// 32 hexadecimal digits from the host's key: what the hosts socket names it by.
    public let id: String
    /// Its X25519 public key, in base64.
    public let publicKey: String
    public let name: String
    public let platform: String
    public let version: String
    /// This computer's name on the host.
    public let deviceName: String
    public let removed: Bool
    public let lastOnlineAt: Double?
    public let relay: OtherHostRelay?
    public let connection: OtherHostConnection
}

/// How a pairing the daemon runs for the app goes (`HostPairingState`).
public struct OtherHostPairingState: Codable, Sendable, Equatable {
    /// `connecting`, `confirm`, `compare`, `ssh`, `added` or `failed`.
    public let state: String
    /// `compare`: the code both screens show.
    public let code: String?
    public let matched: Bool?
    /// `added`: the host as it is kept now.
    public let host: OtherHostStatus?
    /// `failed`: why.
    public let reason: String?
    public let detail: String?

    public var isFinished: Bool { state == "added" || state == "failed" }
}

/// The key the local daemon connects to other hosts with, which this install publishes as its device.
public struct DaemonDeviceKeyInfo: Codable, Sendable, Equatable {
    public let id: String
    public let publicKey: String
}

/// The hosts of the account the relay lists, for pairing without a code (`DiscoveredHosts`).
public struct DiscoveredHostsInfo: Codable, Sendable, Equatable {
    public struct Host: Codable, Sendable, Equatable {
        public let relayId: String
        public let publicKey: String
        public let name: String
        public let platform: String
    }

    /// `ok` with `hosts`, `signed_out` or `unavailable`.
    public let state: String
    public let hosts: [Host]?
}

// MARK: - Cross-Host App Version & Remote Update Status

/// App version and updater state reported by a host (`AppUpdateStatus` in `src/shared/agent-host.ts`).
public struct AppUpdateStatusInfo: Codable, Sendable, Equatable {
    public let currentVersion: String
    /// `idle`, `checking`, `available`, `downloading`, `ready`, `restarting`, `error`, or `off`.
    public let state: String
    /// `install`, `link`, or `unavailable`.
    public let mode: String
    public let canInstall: Bool
    public let availableVersion: String?
    public let progress: Int?
    public let error: String?
    public let updatedAt: Double

    public init(
        currentVersion: String,
        state: String,
        mode: String,
        canInstall: Bool,
        availableVersion: String? = nil,
        progress: Int? = nil,
        error: String? = nil,
        updatedAt: Double = Date().timeIntervalSince1970 * 1000.0
    ) {
        self.currentVersion = currentVersion
        self.state = state
        self.mode = mode
        self.canInstall = canInstall
        self.availableVersion = availableVersion
        self.progress = progress
        self.error = error
        self.updatedAt = updatedAt
    }
}

/// Answer to `app.requestUpdate`.
public struct AppUpdateRequestResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    /// `app_not_running` or `install_unavailable` when `accepted` is false.
    public let reason: String?
    public let status: AppUpdateStatusInfo
}

extension SartoHostSession {
    /// `hosts.device`: the daemon's device key.
    public func daemonHostsDevice() async throws -> DaemonDeviceKeyInfo {
        try await request("hosts.device", params: .null, as: DaemonDeviceKeyInfo.self)
    }

    /// `hosts.list`: the other hosts the daemon knows.
    public func daemonHostsList() async throws -> [OtherHostStatus] {
        try await request("hosts.list", params: .null, as: [OtherHostStatus].self)
    }

    /// `hosts.subscribe`: the same, then `hosts.updated` events on this session.
    public func daemonHostsSubscribe() async throws -> [OtherHostStatus] {
        try await request("hosts.subscribe", params: .null, as: [OtherHostStatus].self)
    }

    /// `hosts.pairDiscovered`: pairs with a host of the account by its id on the relay.
    public func daemonHostsPairDiscovered(relayId: String, model: String) async throws -> Int {
        let result = try await request(
            "hosts.pairDiscovered",
            params: .object(["relayId": .string(relayId), "model": .string(model)])
        )
        guard let rawPairId = result.objectValue?["pairId"]?.doubleValue,
              let pairId = Int.wholePart(of: rawPairId) else {
            throw PortRPCError(code: "internal", message: "Missing pairId in hosts.pairDiscovered response")
        }
        return pairId
    }

    /// `hosts.pairMatch`: whether the code both screens show is the same.
    public func daemonHostsPairMatch(pairId: Int, match: Bool) async throws {
        _ = try await request(
            "hosts.pairMatch",
            params: .object(["pairId": .number(Double(pairId)), "match": .bool(match)])
        )
    }

    /// `hosts.pairClose`: ends a pairing unless the host was added.
    public func daemonHostsPairClose(pairId: Int) async throws {
        _ = try await request("hosts.pairClose", params: .object(["pairId": .number(Double(pairId))]))
    }

    /// `hosts.discover`: the account's hosts the relay lists.
    public func daemonHostsDiscover() async throws -> DiscoveredHostsInfo {
        try await request("hosts.discover", params: .null, as: DiscoveredHostsInfo.self)
    }

    /// `hosts.remove`: forgets a host.
    public func daemonHostsRemove(id: String) async throws {
        _ = try await request("hosts.remove", params: .object(["id": .string(id)]))
    }

    /// `hosts.rename`: renames this computer on a host; false when it is not connected.
    public func daemonHostsRename(id: String, name: String) async throws -> Bool {
        let result = try await request(
            "hosts.rename",
            params: .object(["id": .string(id), "name": .string(name)])
        )
        return result.objectValue?["renamed"]?.boolValue ?? false
    }
}
