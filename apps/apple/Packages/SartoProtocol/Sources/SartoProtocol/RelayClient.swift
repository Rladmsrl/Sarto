import Foundation

public enum RelayClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case httpStatus(Int)
    case relayRefused(code: Int)
    case relayDraining
    case timedOut
    case unexpectedFrame
    case handshakeIncomplete

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid relay URL"
        case .httpStatus(let status):
            return "Relay HTTP request failed with status \(status)"
        case .relayRefused(let code):
            switch RelayCloseCode(rawValue: code) {
            case .offline: return "Host is offline on the relay"
            case .forbidden: return "Relay refused this device for the host"
            case .unauthorized: return "Relay rejected the sign-in token"
            case .tooMany: return "Too many relay connections; try again shortly"
            case .timeout: return "Relay timed out waiting for the host"
            case .replaced: return "Relay connection was replaced by a newer one"
            case .malformed: return "Relay rejected a malformed request"
            case .tooBig: return "Relay message was too large"
            case nil: return "Relay refused connection (code \(code))"
            }
        case .relayDraining:
            return "Relay region is draining"
        case .timedOut:
            return "Connection timed out"
        case .unexpectedFrame:
            return "Unexpected WebSocket frame during handshake"
        case .handshakeIncomplete:
            return "Noise handshake did not complete"
        }
    }

    /// The relay's reason for closing the socket, when this error carries one.
    public var relayRefusal: RelayCloseCode? {
        if case .relayRefused(let code) = self { return RelayCloseCode(rawValue: code) }
        return nil
    }
}

/// Internal driver seam so WebSocket handshake, ping/drain control frames, and timeouts
/// can be verified deterministically without network sockets.
protocol ChannelWebSocketDriver: Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The close code the peer sent, or nil while the socket is open or closed without one.
    var peerCloseCode: Int? { get }
}

extension ChannelWebSocketDriver {
    var peerCloseCode: Int? { nil }

    /// Receives a frame, turning a relay's refusal close (4401, 4403, 4404, 4429, ...) into
    /// `RelayClientError.relayRefused` so callers can tell an offline host from a forbidden device.
    func receiveMappingRelayClose() async throws -> URLSessionWebSocketTask.Message {
        do {
            return try await receive()
        } catch {
            if let code = peerCloseCode, RelayCloseCode(rawValue: code) != nil {
                throw RelayClientError.relayRefused(code: code)
            }
            throw error
        }
    }
}

struct URLSessionWebSocketDriver: ChannelWebSocketDriver {
    let task: URLSessionWebSocketTask

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    var peerCloseCode: Int? {
        let code = task.closeCode
        return code == .invalid ? nil : code.rawValue
    }
}

private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class RelayLatencyMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var measuredRttMs: Int?

    var rttMs: Int? {
        lock.lock()
        defer { lock.unlock() }
        return measuredRttMs
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad })
            ?? metrics.transactionMetrics.last
        guard let transaction,
              let start = transaction.requestStartDate,
              let end = transaction.responseStartDate
        else { return }
        let ms = max(1, Int((end.timeIntervalSince(start) * 1000.0).rounded()))
        lock.lock()
        measuredRttMs = ms
        lock.unlock()
    }
}

private final class RelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Async WebSocket client that connects to a Sarto host (directly or through PrismRelayServer)
/// and establishes an E2EE Noise_IK / Noise_IKpsk1 SartoChannel.
public actor SartoRelayClient {
    public static let defaultDirectConnectTimeout: TimeInterval = 3.5
    public static let defaultRelayConnectTimeout: TimeInterval = 10.0
    private static let maxPreJoinControlFrames = 16

    private let session: URLSession
    private let noRedirectDelegate: RelayNoRedirectDelegate?

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            self.noRedirectDelegate = nil
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 15
            cfg.timeoutIntervalForResource = 30
            let delegate = RelayNoRedirectDelegate()
            self.noRedirectDelegate = delegate
            self.session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        }
    }

    private static func isAllowedOrigin(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }
        return false
    }

    /// Queries GET /v1 on a self-hosted or remote Sarto relay.
    public func fetchRelayInfo(origin: String) async throws -> RelayInfo {
        let base = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: "\(base)/v1") else { throw RelayClientError.invalidURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        try Self.validateHTTPResponse(response)
        return try JSONDecoder().decode(RelayInfo.self, from: data)
    }

    /// Probes GET /v1 and measures network round-trip latency in milliseconds.
    /// Prefers URLSessionTaskTransactionMetrics (requestStartDate -> responseStartDate) so DNS/TLS
    /// cold-start overhead does not skew the reading, falling back to elapsed wall time.
    public func measureRelayLatency(
        origin: String,
        timeout: TimeInterval = 5.0
    ) async throws -> (info: RelayInfo, latencyMs: Int) {
        let base = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: "\(base)/v1") else { throw RelayClientError.invalidURL }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = timeout
        let metricsDelegate = RelayLatencyMetricsDelegate()
        let startedAt = ContinuousClock.now
        let (data, response) = try await session.data(for: req, delegate: metricsDelegate)
        let elapsed = ContinuousClock.now - startedAt
        try Self.validateHTTPResponse(response)
        let info = try JSONDecoder().decode(RelayInfo.self, from: data)
        let fallbackMs = max(
            1,
            Int((Double(elapsed.components.seconds) * 1000.0 + Double(elapsed.components.attoseconds) / 1e15).rounded())
        )
        return (info: info, latencyMs: metricsDelegate.rttMs ?? fallbackMs)
    }

    /// Lists online hosts belonging to the authenticated account on GET /v1/hosts.
    public func listHosts(origin: String, bearerToken: String) async throws -> [RelayListedHost] {
        let base = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        guard let url = URL(string: "\(base)/v1/hosts"), Self.isAllowedOrigin(url) else {
            throw RelayClientError.invalidURL
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        try Self.validateHTTPResponse(response)
        struct Response: Decodable { let hosts: [RelayListedHost] }
        return try JSONDecoder().decode(Response.self, from: data).hosts
    }

    /// Connects through a Sarto Relay to a host and performs the Noise_IK handshake.
    public func connectViaRelay(
        origin: String,
        hostID: String,
        relayToken: String,
        localStaticKey: NoiseKeyPair,
        hostStaticPublicKey: Data,
        psk: Data? = nil,
        prologue: Data = NoiseConstants.defaultPrologue,
        timeout: TimeInterval = SartoRelayClient.defaultRelayConnectTimeout
    ) async throws -> (task: URLSessionWebSocketTask, channel: SartoChannel) {
        guard let url = RelayProtocol.connectSocketURL(origin: origin, hostID: hostID) else {
            throw RelayClientError.invalidURL
        }
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = max(RelayProtocol.maxMessageBytes, NoiseConstants.maxMessage)
        task.resume()
        let driver = URLSessionWebSocketDriver(task: task)
        let channel = try await Self.connectViaRelayDriver(
            driver: driver,
            relayToken: relayToken,
            localStaticKey: localStaticKey,
            hostStaticPublicKey: hostStaticPublicKey,
            psk: psk,
            prologue: prologue,
            timeout: timeout
        )
        return (task, channel)
    }

    /// Connects directly to a local or LAN Sarto host WebSocket (/channel) and runs Noise handshake.
    public func connectDirect(
        channelURL: URL,
        localStaticKey: NoiseKeyPair,
        hostStaticPublicKey: Data,
        psk: Data? = nil,
        timeout: TimeInterval = SartoRelayClient.defaultDirectConnectTimeout
    ) async throws -> (task: URLSessionWebSocketTask, channel: SartoChannel) {
        let task = session.webSocketTask(with: channelURL)
        task.maximumMessageSize = max(RelayProtocol.maxMessageBytes, NoiseConstants.maxMessage)
        task.resume()
        let driver = URLSessionWebSocketDriver(task: task)
        let channel = try await Self.connectDirectDriver(
            driver: driver,
            localStaticKey: localStaticKey,
            hostStaticPublicKey: hostStaticPublicKey,
            psk: psk,
            timeout: timeout
        )
        return (task, channel)
    }

    // MARK: - Internal Testable Handshake Flows

    static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RelayClientError.httpStatus(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw RelayClientError.httpStatus(http.statusCode)
        }
    }

    static func connectViaRelayDriver(
        driver: any ChannelWebSocketDriver,
        relayToken: String,
        localStaticKey: NoiseKeyPair,
        hostStaticPublicKey: Data,
        psk: Data?,
        prologue: Data = NoiseConstants.defaultPrologue,
        timeout: TimeInterval
    ) async throws -> SartoChannel {
        try await withBoundedTimeout(driver: driver, timeout: timeout) {
            let connectPayload = try JSONEncoder().encode(DeviceConnectMessage(token: relayToken))
            guard let connectJSON = String(data: connectPayload, encoding: .utf8) else {
                driver.cancel(with: .protocolError, reason: nil)
                throw RelayClientError.unexpectedFrame
            }
            try await driver.send(.string(connectJSON))

            // Wait for {"type":"joined"} (or {"type":"paired"}), responding to text "ping"
            // and failing cleanly on "drain".
            var controlFramesSeen = 0
            var didJoin = false
            while !didJoin {
                let frame = try await driver.receiveMappingRelayClose()
                guard case .string(let text) = frame else {
                    driver.cancel(with: .protocolError, reason: nil)
                    throw RelayClientError.unexpectedFrame
                }

                if text == RelayProtocol.ping {
                    try await driver.send(.string(RelayProtocol.pong))
                    continue
                }
                if text == "drain" {
                    driver.cancel(with: .goingAway, reason: nil)
                    throw RelayClientError.relayDraining
                }

                if let jsonData = text.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: jsonData),
                   let frameType = parsed["type"]?.stringValue {
                    switch frameType {
                    case "joined", "paired":
                        didJoin = true
                        continue
                    case "ping":
                        try await driver.send(.string(RelayProtocol.pong))
                        continue
                    case "drain":
                        driver.cancel(with: .goingAway, reason: nil)
                        throw RelayClientError.relayDraining
                    default:
                        break
                    }
                }

                controlFramesSeen += 1
                if controlFramesSeen >= maxPreJoinControlFrames {
                    driver.cancel(with: .protocolError, reason: nil)
                    throw RelayClientError.unexpectedFrame
                }
            }

            return try await performNoiseHandshake(
                driver: driver,
                localStaticKey: localStaticKey,
                hostStaticPublicKey: hostStaticPublicKey,
                psk: psk,
                prologue: prologue
            )
        }
    }

    static func connectDirectDriver(
        driver: any ChannelWebSocketDriver,
        localStaticKey: NoiseKeyPair,
        hostStaticPublicKey: Data,
        psk: Data?,
        timeout: TimeInterval
    ) async throws -> SartoChannel {
        try await withBoundedTimeout(driver: driver, timeout: timeout) {
            try await performNoiseHandshake(
                driver: driver,
                localStaticKey: localStaticKey,
                hostStaticPublicKey: hostStaticPublicKey,
                psk: psk,
                prologue: NoiseConstants.defaultPrologue
            )
        }
    }

    private static func withBoundedTimeout<T: Sendable>(
        driver: any ChannelWebSocketDriver,
        timeout: TimeInterval,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutFlag = TimeoutFlag()
        let safeSeconds = timeout.isFinite ? min(max(0.001, timeout), 3_600) : Self.defaultRelayConnectTimeout
        let clampedNs = UInt64(safeSeconds * 1_000_000_000)
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: clampedNs)
            guard !Task.isCancelled else { return }
            timeoutFlag.markTimedOut()
            driver.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await operation()
            } onCancel: {
                driver.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            driver.cancel(with: .goingAway, reason: nil)
            if timeoutFlag.didTimeOut && !(error is CancellationError) {
                throw RelayClientError.timedOut
            }
            if timeoutFlag.didTimeOut && !Task.isCancelled {
                throw RelayClientError.timedOut
            }
            throw error
        }
    }

    private static func performNoiseHandshake(
        driver: any ChannelWebSocketDriver,
        localStaticKey: NoiseKeyPair,
        hostStaticPublicKey: Data,
        psk: Data?,
        prologue: Data
    ) async throws -> SartoChannel {
        let pattern: NoisePattern = psk == nil ? .ik : .ikpsk1
        let handshake = try NoiseHandshake(
            pattern: pattern,
            role: .initiator,
            staticKey: localStaticKey,
            remoteStaticKey: hostStaticPublicKey,
            psk: psk,
            prologue: prologue
        )

        let msg1 = try handshake.writeMessage()
        try await driver.send(.data(msg1))

        var controlFrames = 0
        while true {
            let reply = try await driver.receiveMappingRelayClose()
            switch reply {
            case .data(let msg2):
                _ = try handshake.readMessage(msg2)
                guard handshake.isFinished else {
                    driver.cancel(with: .protocolError, reason: nil)
                    throw RelayClientError.handshakeIncomplete
                }
                let handshakeHash = try handshake.handshakeHash
                let ciphers = try handshake.split()
                return SartoChannel(ciphers: ciphers, handshakeHash: handshakeHash)

            case .string(let text):
                if text == RelayProtocol.ping {
                    try await driver.send(.string(RelayProtocol.pong))
                    continue
                }
                if text == "drain" || text.contains("\"drain\"") {
                    driver.cancel(with: .goingAway, reason: nil)
                    throw RelayClientError.relayDraining
                }
                controlFrames += 1
                if controlFrames >= maxPreJoinControlFrames {
                    driver.cancel(with: .protocolError, reason: nil)
                    throw RelayClientError.unexpectedFrame
                }

            @unknown default:
                driver.cancel(with: .protocolError, reason: nil)
                throw RelayClientError.unexpectedFrame
            }
        }
    }
}
