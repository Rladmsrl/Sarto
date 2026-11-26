import Foundation

// MARK: - Own-Account Remote Claude Code Models (src/shared/remote-claude.ts)

/// Identifies the remote computer running Claude Code for a local session.
public struct ModelHostRef: Codable, Sendable, Equatable, Hashable {
    public let hostId: String
    public let hostName: String

    public init(hostId: String, hostName: String) {
        self.hostId = hostId
        self.hostName = hostName
    }
}

/// Availability reported by a remote host's `remoteClaude.status`.
public struct RemoteClaudeStatus: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let ready: Bool
    public let authRequired: Bool
    public let accountLabel: String?
    public let models: [ConfigOption]
    public let activeRuns: Int
    public let maxConcurrent: Int
    public let error: String?

    public init(
        enabled: Bool,
        ready: Bool,
        authRequired: Bool = false,
        accountLabel: String? = nil,
        models: [ConfigOption] = [],
        activeRuns: Int = 0,
        maxConcurrent: Int = 3,
        error: String? = nil
    ) {
        self.enabled = enabled
        self.ready = ready
        self.authRequired = authRequired
        self.accountLabel = accountLabel
        self.models = models
        self.activeRuns = activeRuns
        self.maxConcurrent = maxConcurrent
        self.error = error
    }

    public var isBusy: Bool {
        activeRuns >= maxConcurrent
    }

    public var isSelectable: Bool {
        enabled && ready && !authRequired && !isBusy
    }
}

/// Aggregated entry returned by local `remoteClaude.hosts` for the desktop UI.
public struct RemoteClaudeHostInfo: Codable, Sendable, Equatable, Identifiable {
    public let hostId: String
    public let hostName: String
    public let platform: String
    public let status: RemoteClaudeStatus

    public var id: String { hostId }

    public init(
        hostId: String,
        hostName: String,
        platform: String = "darwin",
        status: RemoteClaudeStatus
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.platform = platform
        self.status = status
    }
}

/// Summary of an active hosted run on this computer (for Settings and Disconnect All).
public struct RemoteClaudeActiveRun: Codable, Sendable, Equatable, Identifiable {
    public let runId: String
    public let deviceId: String
    public let deviceName: String
    public let startedAt: Double
    public let lastActiveAt: Double

    public var id: String { runId }

    public init(
        runId: String,
        deviceId: String,
        deviceName: String,
        startedAt: Double,
        lastActiveAt: Double
    ) {
        self.runId = runId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
    }
}

public struct RemoteClaudeDisconnectResult: Codable, Sendable, Equatable {
    public let closed: Int

    public init(closed: Int) {
        self.closed = closed
    }
}

// MARK: - SartoHostSession RPCs

extension SartoHostSession {
    /// `remoteClaude.hosts`: probes online same-account hosts for remote Claude Code availability.
    public func remoteClaudeHosts() async throws -> [RemoteClaudeHostInfo] {
        try await request("remoteClaude.hosts", params: .object([:]), as: [RemoteClaudeHostInfo].self)
    }

    /// `remoteClaude.active`: lists active hosted Claude Code runs served by this computer.
    public func remoteClaudeActive() async throws -> [RemoteClaudeActiveRun] {
        try await request("remoteClaude.active", params: .object([:]), as: [RemoteClaudeActiveRun].self)
    }

    /// `remoteClaude.disconnectAll`: immediately terminates all hosted runs served by this computer.
    public func remoteClaudeDisconnectAll() async throws -> RemoteClaudeDisconnectResult {
        try await request("remoteClaude.disconnectAll", params: .object([:]), as: RemoteClaudeDisconnectResult.self)
    }
}
