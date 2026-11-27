import Foundation
import Synchronization

public struct PortRPCError: Error, LocalizedError, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let data: JSONValue?

    public var errorDescription: String? { message }

    public init(code: String, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func disconnected(_ reason: String? = nil) -> PortRPCError {
        if let reason, !reason.isEmpty {
            return PortRPCError(code: "host_offline", message: reason)
        }
        return PortRPCError(code: "host_offline", message: "Disconnected")
    }
}

public typealias HostRPCError = PortRPCError

/// A binary payload carried alongside a JSON Port RPC envelope, anchored at `path` inside the envelope.
public struct PortBuffer: Sendable, Equatable {
    public let path: [String]
    public let data: Data

    public init(path: [String], data: Data) {
        self.path = path
        self.data = data
    }
}

/// A binary value that arrived beside a JSON message, at `path` (object keys and array indices) from
/// the message's root, where the JSON holds a placeholder.
public struct PortInboundBuffer: Sendable, Equatable {
    public let path: [JSONValue]
    public let data: Data

    public init(path: [JSONValue], data: Data) {
        self.path = path
        self.data = data
    }
}

/// One inbound message with its binary values beside the JSON instead of inlined as base64.
public struct PortInboundMessage: Sendable, Equatable {
    public let json: Data
    public let buffers: [PortInboundBuffer]

    public init(json: Data, buffers: [PortInboundBuffer] = []) {
        self.json = json
        self.buffers = buffers
    }

    /// The message as `SartoPortTransport.messages` delivers it: each buffer a base64 string at its path.
    public func inlinedJSON() throws -> Data {
        guard !buffers.isEmpty else { return json }
        var root = try JSONValue(jsonData: json)
        for buffer in buffers {
            root = root.setting(.string(buffer.data.base64EncodedString()), at: buffer.path)
        }
        return try root.jsonData()
    }
}

/// Abstract bidirectional JSON message transport carrying Sarto's Port RPC envelope.
public protocol SartoPortTransport: Sendable {
    var messages: AsyncThrowingStream<Data, Error> { get }
    func sendJSON(_ data: Data) async throws
    func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws
    func close() async
}

public extension SartoPortTransport {
    func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        if buffers.isEmpty {
            try await sendJSON(data)
        } else {
            throw PortRPCError(code: "unavailable", message: "Transport does not support binary buffers")
        }
    }
}

/// A transport that can hand binary values over beside the JSON. Its `messages` inlines them as
/// base64 for older readers; a reader takes either `inboundMessages` or `messages`, never both.
public protocol SartoBinaryPortTransport: SartoPortTransport {
    var inboundMessages: AsyncThrowingStream<PortInboundMessage, Error> { get }
}

/// What a session reads from its transport: the binary-aware stream when the transport has one.
enum PortInboundSource: Sendable {
    case binary(AsyncThrowingStream<PortInboundMessage, Error>)
    case plain(AsyncThrowingStream<Data, Error>)

    init(_ transport: any SartoPortTransport) {
        if let binary = transport as? any SartoBinaryPortTransport {
            self = .binary(binary.inboundMessages)
        } else {
            self = .plain(transport.messages)
        }
    }

    /// Hands each message to `deliver` until the stream ends or `deliver` returns false.
    func forEach(_ deliver: (PortInboundMessage) async -> Bool) async throws {
        switch self {
        case .binary(let stream):
            for try await message in stream {
                guard await deliver(message) else { return }
            }
        case .plain(let stream):
            for try await data in stream {
                guard await deliver(PortInboundMessage(json: data)) else { return }
            }
        }
    }

    /// `messages` for a binary transport: the same stream with every buffer inlined as base64.
    static func inlined(_ source: AsyncThrowingStream<PortInboundMessage, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in source {
                        if let data = try? message.inlinedJSON() {
                            continuation.yield(data)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Settles the race between the welcome and its timeout exactly once.
private final class WelcomeWait: Sendable {
    private enum State { case waiting, welcomed, expired }
    private let state = Mutex(State.waiting)

    /// The timeout fired: true when no welcome came first.
    func expire() -> Bool {
        state.withLock { current in
            guard current == .waiting else { return false }
            current = .expired
            return true
        }
    }

    /// The welcome came: true when the timeout had not fired first.
    func welcome() -> Bool {
        state.withLock { current in
            guard current == .waiting else { return false }
            current = .welcomed
            return true
        }
    }

    var expired: Bool {
        state.withLock { $0 == .expired }
    }
}

/// Encrypted WebSocket transport (direct /channel or self-hosted Relay) implementing Noise_IK /
/// Noise_IKpsk1 + SartoChannel framing + Protocol v4 hello/welcome/ack/ping keepalive + byte streams.
public actor EncryptedChannelTransport: SartoBinaryPortTransport {
    /// Matches ACK_EVERY, ACK_BYTES, and ACK_MS in src/shared/remote/acks.ts.
    public static let ackEvery = 32
    public static let ackBytes = 256 * 1024
    public static let ackCoalesceSeconds: TimeInterval = 0.020

    /// Matches DEVICE_KEEPALIVE in src/shared/remote/keepalive.ts (quietMs: 10_000, answerMs: 5_000).
    public static let defaultKeepaliveInterval: TimeInterval = 10.0
    public static let defaultKeepaliveTimeout: TimeInterval = 5.0

    /// WELCOME_TIMEOUT_MS in src/shared/remote/link.ts: how long a known host has to send its welcome.
    public static let knownHostWelcomeTimeout: TimeInterval = 15.0

    private static let pingPayload = Data("{\"type\":\"ping\"}".utf8)
    private static let pongPayload = Data("{\"type\":\"pong\"}".utf8)
    private static let streamMarkerBytes = Data("\"$stream\"".utf8)
    /// What all the streams of one response may hold together, so a host cannot reserve 32 MiB per ref.
    static let maxResponseStreamBytes = SartoChannel.maxMessageBytes

    /// Control JSON message types sent directly on the channel rather than through Outbox.
    private static let nonOutboxMessageTypes: Set<String> = [
        "ping",
        "pong",
        "closing",
        "standby",
    ]

    /// Small control messages whose other fields the receive loop reads.
    private static let probedMessageTypes: Set<String> = [
        "ping",
        "pong",
        "closing",
        "standby",
        "stream.end",
        "stream.cancel",
    ]

    private struct ChannelEnvelopeProbe: Decodable {
        let type: String?
        let id: JSONValue?
        let reason: String?
        let stream: Double?
        let error: JSONValue?
    }

    private struct TypeProbe: Decodable {
        let type: String?
    }

    private struct ClosingProbe: Decodable {
        let reason: String?
    }

    private struct AwaitedDownload {
        let json: Data
        let requestID: JSONValue?
        var buffers: [PortInboundBuffer]
        var remaining: Int
        /// Bytes received across all of the response's streams, held to `maxResponseStreamBytes`.
        var receivedBytes: Int
    }

    private struct ActiveDownload {
        let awaitedKey: Int
        let path: [JSONValue]
        let expectedSize: Int
        var data: Data
    }

    private let driver: any ChannelWebSocketDriver
    private let channel: SartoChannel
    public nonisolated let welcome: WelcomeMessage

    private let keepaliveInterval: TimeInterval
    private let keepaliveTimeout: TimeInterval

    private var receivedCount = 0
    private var unackedCount = 0
    private var unackedBytes = 0
    private var ackTask: Task<Void, Never>?

    private var lastInboundAt: TimeInterval
    private var lastPongAt: TimeInterval?
    private var awaitingPongSince: TimeInterval?
    private var keepaliveTask: Task<Void, Never>?

    // Strict FIFO lock serializing seal() + WebSocket send() so transport nonces hit the wire in order.
    private var isSending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    private var closed = false
    public private(set) var closeReason: String?
    private var nextUploadStream: UInt32 = 1
    private var nextAwaitedKey = 1
    private var awaitedDownloads: [Int: AwaitedDownload] = [:]
    private var activeDownloads: [UInt32: ActiveDownload] = [:]
    private let incomingStream: AsyncThrowingStream<PortInboundMessage, Error>
    private let incomingContinuation: AsyncThrowingStream<PortInboundMessage, Error>.Continuation
    private let legacyMessages = Mutex<AsyncThrowingStream<Data, Error>?>(nil)
    private var readerTask: Task<Void, Never>?

    /// `welcomeTimeout` bounds the wait for the host's welcome; nil waits as long as the owner takes to
    /// answer a pairing, and a known host should get `knownHostWelcomeTimeout`.
    public init(
        task: URLSessionWebSocketTask,
        channel: SartoChannel,
        hello: HelloMessage,
        welcomeTimeout: TimeInterval? = nil,
        confirmDiscoveryCode: (@Sendable (String) async -> Bool)? = nil
    ) async throws {
        try await self.init(
            driver: URLSessionWebSocketDriver(task: task),
            channel: channel,
            hello: hello,
            keepaliveInterval: Self.defaultKeepaliveInterval,
            keepaliveTimeout: Self.defaultKeepaliveTimeout,
            welcomeTimeout: welcomeTimeout,
            confirmDiscoveryCode: confirmDiscoveryCode
        )
    }

    init(
        driver: any ChannelWebSocketDriver,
        channel: SartoChannel,
        hello: HelloMessage,
        keepaliveInterval: TimeInterval = EncryptedChannelTransport.defaultKeepaliveInterval,
        keepaliveTimeout: TimeInterval = EncryptedChannelTransport.defaultKeepaliveTimeout,
        welcomeTimeout: TimeInterval? = nil,
        confirmDiscoveryCode: (@Sendable (String) async -> Bool)? = nil
    ) async throws {
        self.driver = driver
        self.channel = channel
        self.keepaliveInterval = keepaliveInterval
        self.keepaliveTimeout = keepaliveTimeout
        self.lastInboundAt = ProcessInfo.processInfo.systemUptime

        let wait = WelcomeWait()
        var timer: Task<Void, Never>?
        if let welcomeTimeout, welcomeTimeout.isFinite {
            let safeSeconds = min(max(0, welcomeTimeout), 3_600)
            let delayNs = UInt64(safeSeconds * 1_000_000_000)
            timer = Task.detached { [driver] in
                try? await Task.sleep(nanoseconds: delayNs)
                if !Task.isCancelled, wait.expire() {
                    driver.cancel(with: .goingAway, reason: nil)
                }
            }
        }

        do {
            let decoder = JSONDecoder()

            // Account-authenticated discovery (`src/shared/remote/discovery.ts`):
            // commit -> host pair-nonce -> reveal -> hello -> confirm code -> pair-confirm -> welcome.
            var discoveryCode: String?
            if confirmDiscoveryCode != nil {
                let deviceNonce = DiscoveryPairProtocol.randomNonce()
                let commitObj: [String: String] = [
                    "type": "pair-commit",
                    "commit": DiscoveryPairProtocol.commit(nonce: deviceNonce),
                ]
                let commitBytes = try JSONEncoder().encode(commitObj)
                for frame in try channel.seal(.json(commitBytes)) {
                    try await driver.send(.data(frame))
                }

                struct NonceProbe: Decodable { let type: String?; let nonce: String? }
                var hostNonce: Data?
                while hostNonce == nil {
                    let wsMsg = try await driver.receive()
                    self.lastInboundAt = ProcessInfo.processInfo.systemUptime
                    switch wsMsg {
                    case .string(let text):
                        if text == RelayProtocol.ping {
                            try await driver.send(.string(RelayProtocol.pong))
                        } else if text == "drain" {
                            driver.cancel(with: .goingAway, reason: nil)
                            throw HostRPCError.disconnected("drain")
                        }
                    case .data(let frame):
                        if case .json(let jsonData)? = try channel.open(frame: frame) {
                            let type = PortEnvelopeSniffer.header(jsonData)?.type
                                ?? (try? decoder.decode(TypeProbe.self, from: jsonData))?.type
                            if type == "pair-nonce",
                               let probe = try? decoder.decode(NonceProbe.self, from: jsonData),
                               let rawNonce = probe.nonce,
                               let decodedNonce = BaseEncoding.base64URLDecode(rawNonce),
                               decodedNonce.count == DiscoveryPairProtocol.nonceBytes {
                                hostNonce = decodedNonce
                            } else if type == "closing" {
                                let reason = (try? decoder.decode(ClosingProbe.self, from: jsonData))?.reason ?? "closed"
                                driver.cancel(with: .normalClosure, reason: nil)
                                throw HostRPCError.disconnected(reason)
                            } else {
                                driver.cancel(with: .protocolError, reason: nil)
                                throw HostRPCError.disconnected("invalid")
                            }
                        }
                    @unknown default:
                        break
                    }
                }

                let revealObj: [String: String] = [
                    "type": "pair-reveal",
                    "nonce": BaseEncoding.base64URLEncode(deviceNonce),
                ]
                let revealBytes = try JSONEncoder().encode(revealObj)
                for frame in try channel.seal(.json(revealBytes)) {
                    try await driver.send(.data(frame))
                }
                discoveryCode = DiscoveryPairProtocol.pairCode(
                    handshakeHash: channel.handshakeHash,
                    hostNonce: hostNonce!,
                    deviceNonce: deviceNonce
                )
            }

            let helloBytes = try JSONEncoder().encode(hello)
            for frame in try channel.seal(.json(helloBytes)) {
                try await driver.send(.data(frame))
            }

            let readUntilWelcome: @Sendable () async throws -> WelcomeMessage = {
                let localDecoder = JSONDecoder()
                while true {
                    let wsMsg = try await driver.receive()
                    switch wsMsg {
                    case .string(let text):
                        if text == RelayProtocol.ping {
                            try await driver.send(.string(RelayProtocol.pong))
                        } else if text == "drain" {
                            driver.cancel(with: .goingAway, reason: nil)
                            throw HostRPCError.disconnected("drain")
                        }
                    case .data(let frame):
                        if case .json(let jsonData)? = try channel.open(frame: frame) {
                            let type = PortEnvelopeSniffer.header(jsonData)?.type
                                ?? (try? localDecoder.decode(TypeProbe.self, from: jsonData))?.type
                            if type == "welcome" {
                                return try Self.readWelcome(jsonData, decoder: localDecoder)
                            } else if type == "closing" {
                                let reason = (try? localDecoder.decode(ClosingProbe.self, from: jsonData))?.reason ?? "closed"
                                driver.cancel(with: .normalClosure, reason: nil)
                                throw HostRPCError.disconnected(reason)
                            }
                        }
                    @unknown default:
                        break
                    }
                }
            }

            let receivedWelcome: WelcomeMessage
            if let confirmDiscoveryCode, let discoveryCode {
                // Keep reading while the user compares the 6-digit code so relay pings are answered
                // and an early host rejection surfaces immediately.
                enum ConfirmRaceResult: Sendable {
                    case confirmed(Bool)
                    case earlyWelcome(WelcomeMessage)
                }
                let welcomeTask = Task { try await readUntilWelcome() }
                let raceOutcome: ConfirmRaceResult = try await withThrowingTaskGroup(of: ConfirmRaceResult.self) { group in
                    group.addTask {
                        let matched = await confirmDiscoveryCode(discoveryCode)
                        return .confirmed(matched)
                    }
                    group.addTask {
                        let welcome = try await welcomeTask.value
                        return .earlyWelcome(welcome)
                    }
                    do {
                        guard let first = try await group.next() else {
                            throw HostRPCError.disconnected("closed")
                        }
                        group.cancelAll()
                        return first
                    } catch {
                        group.cancelAll()
                        welcomeTask.cancel()
                        throw error
                    }
                }
                switch raceOutcome {
                case .earlyWelcome(let welcome):
                    receivedWelcome = welcome
                case .confirmed(let matched):
                    guard matched else {
                        welcomeTask.cancel()
                        driver.cancel(with: .normalClosure, reason: nil)
                        throw PortRPCError(code: "cancelled", message: "Verification code did not match")
                    }
                    let confirmBytes = Data("{\"type\":\"pair-confirm\"}".utf8)
                    for frame in try channel.seal(.json(confirmBytes)) {
                        try await driver.send(.data(frame))
                    }
                    receivedWelcome = try await welcomeTask.value
                }
            } else {
                receivedWelcome = try await readUntilWelcome()
            }
            self.lastInboundAt = ProcessInfo.processInfo.systemUptime
            timer?.cancel()
            guard wait.welcome() else { throw Self.welcomeTimeoutError }
            self.welcome = receivedWelcome
        } catch {
            timer?.cancel()
            driver.cancel(with: .goingAway, reason: nil)
            // The timeout ends the wait by cancelling the socket, which surfaces here as its error.
            throw wait.expired ? Self.welcomeTimeoutError : error
        }

        var cont: AsyncThrowingStream<PortInboundMessage, Error>.Continuation!
        self.incomingStream = AsyncThrowingStream { cont = $0 }
        self.incomingContinuation = cont

        // The loops hold the transport only while handling a message, so a transport nobody keeps
        // deinits and its deinit closes the socket.
        self.readerTask = Task.detached { [weak self, driver] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await driver.receive()
                } catch {
                    await self?.receiveFailed(error)
                    return
                }
                guard let transport = self else {
                    driver.cancel(with: .goingAway, reason: nil)
                    return
                }
                guard await transport.handleInbound(message) else { return }
            }
        }
        if welcome.`protocol` >= 3 {
            self.keepaliveTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    guard let delayNs = await self?.keepaliveStep() else { return }
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }
        }
    }

    deinit {
        readerTask?.cancel()
        keepaliveTask?.cancel()
        ackTask?.cancel()
        if !closed {
            driver.cancel(with: .goingAway, reason: nil)
            incomingContinuation.finish()
        }
    }

    private static let welcomeTimeoutError = PortRPCError(
        code: "host_offline",
        message: "The host did not answer in time"
    )

    /// Like parseWelcome in src/shared/remote/protocol.ts, but a welcome that does not parse ends the
    /// connection here rather than leaving it to wait for one that never comes.
    private static func readWelcome(_ data: Data, decoder: JSONDecoder) throws -> WelcomeMessage {
        guard let welcome = try? decoder.decode(WelcomeMessage.self, from: data) else {
            throw PortRPCError(code: "internal", message: "The host sent a welcome this app cannot read")
        }
        guard (HostProtocolVersion.min...HostProtocolVersion.max).contains(welcome.`protocol`) else {
            throw PortRPCError(
                code: "internal",
                message: "The host answered with protocol \(welcome.`protocol`), which this app does not speak"
            )
        }
        return welcome
    }

    public nonisolated var inboundMessages: AsyncThrowingStream<PortInboundMessage, Error> {
        incomingStream
    }

    public nonisolated var messages: AsyncThrowingStream<Data, Error> {
        legacyMessages.withLock { cached in
            if let cached { return cached }
            let stream = PortInboundSource.inlined(incomingStream)
            cached = stream
            return stream
        }
    }

    var currentReceivedCount: Int {
        receivedCount
    }

    public func sendJSON(_ data: Data) async throws {
        try await sendSealedMessage(.json(data))
    }

    public func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        if buffers.isEmpty {
            try await sendJSON(data)
            return
        }
        guard !closed else { throw HostRPCError.disconnected(closeReason) }
        guard welcome.features.contains("bytes") else {
            throw PortRPCError(code: "invalid_params", message: "This host does not support binary uploads")
        }

        var root = try JSONValue(jsonData: data)
        let chunkSize = max(1024, SartoChannel.maxPayloadBytes - 4)

        for buf in buffers {
            let stream = nextUploadStream
            nextUploadStream &+= 2

            let openMsg = Data("{\"type\":\"stream.open\",\"stream\":\(stream),\"size\":\(buf.data.count)}".utf8)
            try await sendSealedMessage(.json(openMsg))

            var offset = buf.data.startIndex
            while offset < buf.data.endIndex {
                let end = buf.data.index(
                    offset,
                    offsetBy: min(chunkSize, buf.data.distance(from: offset, to: buf.data.endIndex))
                )
                let chunk = Data(buf.data[offset..<end])
                try await sendSealedMessage(.bytes(stream: stream, data: chunk))
                offset = end
            }

            let endMsg = Data("{\"type\":\"stream.end\",\"stream\":\(stream)}".utf8)
            try await sendSealedMessage(.json(endMsg))

            root = root.setting(
                .object(["$stream": .number(Double(stream))]),
                at: buf.path.map(JSONValue.string)
            )
        }

        try await sendSealedMessage(.json(try root.jsonData()))
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        ackTask?.cancel()
        ackTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        readerTask?.cancel()
        readerTask = nil
        driver.cancel(with: .normalClosure, reason: nil)
        awaitedDownloads.removeAll()
        activeDownloads.removeAll()
        incomingContinuation.finish()
    }

    // MARK: - Strict FIFO Nonce Serialization

    private func acquireSendLock() async {
        if !isSending {
            isSending = true
            return
        }
        await withCheckedContinuation { cont in
            sendWaiters.append(cont)
        }
    }

    private func releaseSendLock() {
        if !sendWaiters.isEmpty {
            let next = sendWaiters.removeFirst()
            next.resume()
        } else {
            isSending = false
        }
    }

    private func sendSealedMessage(_ message: ChannelMessage) async throws {
        await acquireSendLock()
        defer { releaseSendLock() }
        guard !closed else {
            throw HostRPCError.disconnected(closeReason)
        }
        let frames = try channel.seal(message)
        do {
            for frame in frames {
                try await driver.send(.data(frame))
            }
        } catch {
            // Once seal() has advanced the cipher nonce, a failed WebSocket write permanently
            // desynchronizes the transport stream, so tear down the socket immediately.
            handleTransportFatal(error: error)
            throw HostRPCError.disconnected(closeReason ?? error.localizedDescription)
        }
    }

    private func sendWebSocketText(_ text: String) async throws {
        await acquireSendLock()
        defer { releaseSendLock() }
        guard !closed else {
            throw HostRPCError.disconnected(closeReason)
        }
        try await driver.send(.string(text))
    }

    private func handleTransportFatal(error: Error) {
        guard !closed else { return }
        closed = true
        ackTask?.cancel()
        ackTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        driver.cancel(with: .goingAway, reason: nil)
        awaitedDownloads.removeAll()
        activeDownloads.removeAll()
        let resolved = (error as? PortRPCError) ?? HostRPCError.disconnected(closeReason ?? error.localizedDescription)
        incomingContinuation.finish(throwing: resolved)
    }

    // MARK: - Outbox Ack Accounting & Coalescing (src/shared/remote/acks.ts)

    private func recordOutboxMessage(bytes: Int) async {
        receivedCount += 1
        guard welcome.`protocol` >= 2 else { return }
        unackedCount += 1
        unackedBytes += max(0, bytes)
        if unackedCount >= Self.ackEvery || unackedBytes >= Self.ackBytes {
            await flushAckNow()
        } else if ackTask == nil {
            let delayNs = UInt64(max(0.001, Self.ackCoalesceSeconds) * 1_000_000_000)
            ackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delayNs)
                guard !Task.isCancelled else { return }
                await self?.flushAckFromTimer()
            }
        }
    }

    private func flushAckFromTimer() async {
        ackTask = nil
        await flushAckNow()
    }

    private func flushAckNow() async {
        ackTask?.cancel()
        ackTask = nil
        guard !closed, welcome.`protocol` >= 2, unackedCount > 0 else { return }
        unackedCount = 0
        unackedBytes = 0
        let ackData = Data("{\"type\":\"ack\",\"received\":\(receivedCount)}".utf8)
        try? await sendSealedMessage(.json(ackData))
    }

    // MARK: - Client Keepalive Heartbeat (src/shared/remote/keepalive.ts)

    private func noteInboundActivity() {
        let now = ProcessInfo.processInfo.systemUptime
        lastInboundAt = now
        if let pingAt = awaitingPongSince, now >= pingAt {
            awaitingPongSince = nil
        }
    }

    /// One turn of the keepalive: pings a quiet host, gives up on a silent one, and returns how long to
    /// sleep before the next turn, or nil once the transport is closed.
    private func keepaliveStep() async -> UInt64? {
        guard !closed else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let nextSleepSeconds: TimeInterval

        if let pingSentAt = awaitingPongSince {
            if lastInboundAt >= pingSentAt {
                awaitingPongSince = nil
                let quiet = now - lastInboundAt
                nextSleepSeconds = max(0.005, keepaliveInterval - quiet)
            } else {
                let waited = now - pingSentAt
                if waited >= keepaliveTimeout {
                    handleTransportFatal(error: HostRPCError.disconnected("Keepalive timeout"))
                    return nil
                }
                nextSleepSeconds = max(0.005, keepaliveTimeout - waited)
            }
        } else {
            let quiet = now - lastInboundAt
            if quiet >= keepaliveInterval {
                awaitingPongSince = ProcessInfo.processInfo.systemUptime
                do {
                    try await sendSealedMessage(.json(Self.pingPayload))
                } catch {
                    return nil
                }
                nextSleepSeconds = max(0.005, keepaliveTimeout)
            } else {
                nextSleepSeconds = max(0.005, keepaliveInterval - quiet)
            }
        }
        return UInt64(nextSleepSeconds * 1_000_000_000)
    }

    // MARK: - Inbound Receive Loop & Zero-CoW Stream Downloads

    private func receiveFailed(_ error: Error) {
        guard !closed else { return }
        if Task.isCancelled {
            closed = true
            ackTask?.cancel()
            ackTask = nil
            keepaliveTask?.cancel()
            keepaliveTask = nil
            incomingContinuation.finish()
        } else {
            handleTransportFatal(error: error)
        }
    }

    /// Handles one WebSocket message; false once the transport has closed.
    private func handleInbound(_ wsMsg: URLSessionWebSocketTask.Message) async -> Bool {
        guard !closed else { return false }
        noteInboundActivity()
        do {
            switch wsMsg {
            case .string(let text):
                if text == RelayProtocol.ping {
                    try? await sendWebSocketText(RelayProtocol.pong)
                }
            case .data(let frame):
                guard let msg = try channel.open(frame: frame) else { return !closed }
                switch msg {
                case .bytes(let stream, let chunk):
                    await recordOutboxMessage(bytes: chunk.count)
                    // Remove entry before mutating `Data` so refcount stays 1 (eliminates O(N^2) CoW copies).
                    guard var active = activeDownloads.removeValue(forKey: stream) else {
                        return !closed
                    }
                    let received = awaitedDownloads[active.awaitedKey]?.receivedBytes ?? 0
                    if received + chunk.count > Self.maxResponseStreamBytes {
                        let siblings = cancelSiblingDownloadsAndFail(
                            awaitedKey: active.awaitedKey,
                            error: .object([
                                "code": .string("invalid_params"),
                                "message": .string("Stream download exceeded 32 MiB limit"),
                            ])
                        )
                        for given in [stream] + siblings {
                            await sendStreamCancel(given)
                        }
                        return !closed
                    }
                    active.data.append(chunk)
                    activeDownloads[stream] = active
                    awaitedDownloads[active.awaitedKey]?.receivedBytes += chunk.count

                case .json(let jsonData):
                    return await handleJSON(jsonData)
                }
            @unknown default:
                break
            }
        } catch {
            handleTransportFatal(error: error)
            return false
        }
        return !closed
    }

    private func handleJSON(_ jsonData: Data) async -> Bool {
        let sniffedType = PortEnvelopeSniffer.header(jsonData)?.type
        var probe: ChannelEnvelopeProbe?
        if sniffedType.map(Self.probedMessageTypes.contains) ?? true {
            probe = try? JSONDecoder().decode(ChannelEnvelopeProbe.self, from: jsonData)
        }
        let msgType = sniffedType ?? probe?.type

        if let msgType, Self.nonOutboxMessageTypes.contains(msgType) {
            switch msgType {
            case "ping":
                if let id = probe?.id, let pongData = try? JSONValue.object(["type": .string("pong"), "id": id]).jsonData() {
                    try? await sendSealedMessage(.json(pongData))
                } else {
                    try? await sendSealedMessage(.json(Self.pongPayload))
                }
            case "pong":
                lastPongAt = ProcessInfo.processInfo.systemUptime
            case "closing":
                let reason = probe?.reason
                closeReason = reason
                closed = true
                ackTask?.cancel()
                ackTask = nil
                keepaliveTask?.cancel()
                keepaliveTask = nil
                driver.cancel(with: .normalClosure, reason: nil)
                awaitedDownloads.removeAll()
                activeDownloads.removeAll()
                incomingContinuation.finish(throwing: HostRPCError.disconnected(reason ?? "closed"))
                return false
            default:
                break
            }
            return true
        }

        // Every other JSON message, `addresses` included, came through remote-host's Outbox.
        await recordOutboxMessage(bytes: jsonData.count)

        if let msgType {
            if msgType == "addresses" || msgType == "terminal" || msgType == "renamed" || msgType == "host.renamed" || msgType == "relay.regions" {
                return true
            }
            if msgType == "stream.end", let streamNum = probe?.stream,
               streamNum.isFinite, streamNum.rounded() == streamNum,
               streamNum >= 0, streamNum <= Double(UInt32.max) {
                handleDownloadEnd(stream: UInt32(streamNum))
                return true
            }
            if msgType == "stream.cancel", let streamNum = probe?.stream,
               streamNum.isFinite, streamNum.rounded() == streamNum,
               streamNum >= 0, streamNum <= Double(UInt32.max) {
                handleDownloadCancel(stream: UInt32(streamNum), error: probe?.error)
                return true
            }
            if msgType == "response",
               jsonData.range(of: Self.streamMarkerBytes) != nil,
               let decoded = try? JSONValue(jsonData: jsonData),
               let obj = decoded.objectValue,
               let result = obj["result"] {
                let refs = Self.findStreamRefs(result, prefix: [.string("result")])
                if !refs.isEmpty {
                    // Sizes are clamped to maxMessageBytes + 1, so the sum cannot overflow.
                    let declaredBytes = refs.reduce(0) { $0 + max($1.size, 0) }
                    let activeDeclaredBytes = activeDownloads.values.reduce(0) { $0 + max($1.expectedSize, 0) }
                    let maxAggregateStreamBytes = Self.maxResponseStreamBytes * 2
                    let streamIDs = Set(refs.map(\.stream))
                    let repeatsID = streamIDs.count != refs.count
                        || streamIDs.contains { activeDownloads[$0] != nil }
                    if refs.contains(where: { $0.size < 0 })
                        || declaredBytes > Self.maxResponseStreamBytes
                        || activeDeclaredBytes + declaredBytes > maxAggregateStreamBytes
                        || repeatsID {
                        // A stream another response is still downloading is not this one's to cancel.
                        for stream in streamIDs.sorted() where activeDownloads[stream] == nil {
                            await sendStreamCancel(stream)
                        }
                        if let reqId = obj["id"] {
                            yieldError(id: reqId, error: .object([
                                "code": .string("invalid_params"),
                                "message": .string(
                                    repeatsID ? "Response repeats a stream id" : "Stream exceeds memory limit"
                                ),
                            ]))
                        }
                        return true
                    }

                    let key = nextAwaitedKey
                    nextAwaitedKey += 1
                    awaitedDownloads[key] = AwaitedDownload(
                        json: jsonData,
                        requestID: obj["id"],
                        buffers: [],
                        remaining: refs.count,
                        receivedBytes: 0
                    )
                    for ref in refs {
                        var buf = Data()
                        buf.reserveCapacity(min(max(ref.size, 0), 1024 * 1024))
                        activeDownloads[ref.stream] = ActiveDownload(
                            awaitedKey: key,
                            path: ref.path,
                            expectedSize: ref.size,
                            data: buf
                        )
                    }
                    return true
                }
            }
        }

        incomingContinuation.yield(PortInboundMessage(json: jsonData))
        return true
    }

    private func yieldError(id: JSONValue, error: JSONValue) {
        let message = JSONValue.object(["type": .string("error"), "id": id, "error": error])
        if let encoded = try? message.jsonData() {
            incomingContinuation.yield(PortInboundMessage(json: encoded))
        }
    }

    private func handleDownloadEnd(stream: UInt32) {
        guard let dl = activeDownloads.removeValue(forKey: stream) else { return }
        if dl.expectedSize > 0 && dl.data.count != dl.expectedSize {
            cancelSiblingDownloadsAndFail(
                awaitedKey: dl.awaitedKey,
                error: .object([
                    "code": .string("internal"),
                    "message": .string("Stream ended before declared byte count"),
                ])
            )
            return
        }
        guard var awaited = awaitedDownloads.removeValue(forKey: dl.awaitedKey) else { return }
        // The bytes travel beside the JSON; only a reader of `messages` turns them into base64.
        awaited.buffers.append(PortInboundBuffer(path: dl.path, data: dl.data))
        awaited.remaining -= 1
        if awaited.remaining <= 0 {
            incomingContinuation.yield(PortInboundMessage(json: awaited.json, buffers: awaited.buffers))
        } else {
            awaitedDownloads[dl.awaitedKey] = awaited
        }
    }

    private func handleDownloadCancel(stream: UInt32, error: JSONValue?) {
        guard let dl = activeDownloads.removeValue(forKey: stream) else { return }
        cancelSiblingDownloadsAndFail(awaitedKey: dl.awaitedKey, error: error)
    }

    /// Returns the sibling streams it dropped.
    @discardableResult
    private func cancelSiblingDownloadsAndFail(awaitedKey: Int, error: JSONValue?) -> [UInt32] {
        // Remove any sibling streams belonging to the same multi-stream RPC response.
        let siblingStreams = activeDownloads.compactMap { key, val in
            val.awaitedKey == awaitedKey ? key : nil
        }
        for sibling in siblingStreams {
            activeDownloads.removeValue(forKey: sibling)
        }

        guard let awaited = awaitedDownloads.removeValue(forKey: awaitedKey) else { return siblingStreams }
        if let reqId = awaited.requestID {
            yieldError(id: reqId, error: error ?? .object([
                "code": .string("internal"),
                "message": .string("Stream cancelled by host"),
            ]))
        }
        return siblingStreams
    }

    private func sendStreamCancel(_ stream: UInt32) async {
        let cancelMsg = Data("{\"type\":\"stream.cancel\",\"stream\":\(stream)}".utf8)
        try? await sendSealedMessage(.json(cancelMsg))
    }

    private static func findStreamRefs(
        _ value: JSONValue,
        prefix: [JSONValue]
    ) -> [(path: [JSONValue], stream: UInt32, size: Int)] {
        switch value {
        case .object(let dict):
            if let streamNum = dict["$stream"]?.doubleValue,
               dict.count <= 2,
               streamNum.isFinite,
               streamNum.rounded() == streamNum,
               streamNum >= 0,
               streamNum <= Double(UInt32.max) {
                if dict.count == 2, dict["size"] == nil {
                    // Not a StreamRef object.
                } else {
                    let sizeVal: Int
                    if let rawSize = dict["size"]?.doubleValue {
                        if !rawSize.isFinite || rawSize < 0 {
                            sizeVal = -1
                        } else if rawSize > Double(SartoChannel.maxMessageBytes) {
                            sizeVal = SartoChannel.maxMessageBytes + 1
                        } else {
                            sizeVal = Int(rawSize)
                        }
                    } else {
                        sizeVal = 0
                    }
                    return [(prefix, UInt32(streamNum), sizeVal)]
                }
            }
            var found: [(path: [JSONValue], stream: UInt32, size: Int)] = []
            for (k, v) in dict {
                found.append(contentsOf: findStreamRefs(v, prefix: prefix + [.string(k)]))
            }
            return found
        case .array(let arr):
            var found: [(path: [JSONValue], stream: UInt32, size: Int)] = []
            for (idx, item) in arr.enumerated() {
                found.append(contentsOf: findStreamRefs(item, prefix: prefix + [.number(Double(idx))]))
            }
            return found
        default:
            return []
        }
    }
}

/// A response with its binary values beside the JSON, as `SartoHostSession.requestResponse` returns it.
public struct PortResponse: Sendable, Equatable {
    /// The raw `{"type":"response","id":…,"result":…}` envelope; a binary value's place in it holds a
    /// placeholder such as `{"$stream":2,"size":…}`.
    public let envelope: Data
    /// The binary values of the result, with paths from the result's root.
    public let buffers: [PortInboundBuffer]

    public init(envelope: Data, buffers: [PortInboundBuffer]) {
        self.envelope = envelope
        self.buffers = buffers
    }

    /// The result without its binary values, which stay in `buffers`.
    public func result() throws -> JSONValue {
        try JSONValue(jsonData: envelope).objectValue?["result"] ?? .null
    }

    /// Decodes the result straight from the envelope's bytes.
    public func decodeResult<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(PortResultEnvelope<T>.self, from: envelope).result
    }

    /// The binary value at `path` from the result's root.
    public func data(at path: [JSONValue]) -> Data? {
        buffers.first { $0.path == path }?.data
    }

    /// The binary value of the result's top-level field `key`.
    public func data(atKey key: String) -> Data? {
        data(at: [.string(key)])
    }
}

/// `{"result": T}`, reading a missing result as null the way the untyped request path does.
struct PortResultEnvelope<Result: Decodable>: Decodable {
    let result: Result

    private enum CodingKeys: String, CodingKey {
        case result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.result) {
            result = try c.decode(Result.self, forKey: .result)
        } else {
            result = try JSONDecoder().decode(Result.self, from: Data("null".utf8))
        }
    }
}

/// High-level typed RPC & event client for Sarto's agent-host and daemon control ports.
public actor SartoHostSession {
    private struct QueuedOutbound {
        let id: Int
        let payload: Data
        let buffers: [PortBuffer]
    }

    private struct EnvelopeHeader: Decodable {
        let type: String
        let id: Double?
    }

    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
        let data: JSONValue?
    }

    private struct ErrorEnvelope: Decodable {
        let id: Double?
        let error: ErrorBody?
    }

    private struct EventFallbackEnvelope: Decodable {
        let event: JSONValue
    }

    private let transport: any SartoPortTransport
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<PortInboundMessage, Error>] = [:]
    private var outboundQueue: [QueuedOutbound] = []
    private var isSendingOutbound = false
    private var isClosed = false
    private var closeError: Error = HostRPCError.disconnected()
    private var listenerTask: Task<Void, Never>?

    private let eventStream: AsyncStream<HostEvent>
    private let eventContinuation: AsyncStream<HostEvent>.Continuation

    public init(transport: any SartoPortTransport) {
        self.transport = transport
        var cont: AsyncStream<HostEvent>.Continuation!
        self.eventStream = AsyncStream { cont = $0 }
        self.eventContinuation = cont

        Task {
            await self.startListening()
        }
    }

    deinit {
        listenerTask?.cancel()
        eventContinuation.finish()
        if !isClosed {
            // Nobody else can read the transport's single-reader stream once this session is gone.
            let transport = self.transport
            Task { await transport.close() }
        }
    }

    private func startListening() {
        guard !isClosed, listenerTask == nil else { return }
        let source = PortInboundSource(transport)
        // The loop holds the session only while handling a message, so a session nobody keeps deinits.
        listenerTask = Task.detached { [weak self] in
            do {
                try await source.forEach { message in
                    guard let session = self else { return false }
                    await session.handleInbound(message)
                    return true
                }
                await self?.listenEnded(nil)
            } catch {
                await self?.listenEnded(error)
            }
        }
    }

    public nonisolated var events: AsyncStream<HostEvent> {
        eventStream
    }

    public func close() async {
        if !isClosed {
            isClosed = true
            closeError = HostRPCError.disconnected("Disconnected")
        }
        listenerTask?.cancel()
        outboundQueue.removeAll()
        await transport.close()
        failAllPending(with: closeError)
        eventContinuation.finish()
    }

    /// Sends a Port RPC request. Note: `.null` serializes `"params": null` so daemon `control.ts`
    /// methods validated by `none()` (`status`, `pair.open`, `devices.list`) succeed strictly.
    /// A binary value of the result arrives as a base64 string; `requestResponse` keeps it as `Data`.
    public func request(
        _ method: String,
        params: JSONValue = .null,
        buffers: [PortBuffer] = []
    ) async throws -> JSONValue {
        try Self.inlinedResult(of: try await exchange(method, params: params, buffers: buffers))
    }

    /// Sends a Port RPC request and decodes its result straight from the response's bytes.
    public func request<T: Decodable>(
        _ method: String,
        params: JSONValue = .null,
        buffers: [PortBuffer] = [],
        as type: T.Type
    ) async throws -> T {
        let message = try await exchange(method, params: params, buffers: buffers)
        if message.buffers.isEmpty {
            return try JSONDecoder().decode(PortResultEnvelope<T>.self, from: message.json).result
        }
        return try Self.inlinedResult(of: message).decode(T.self)
    }

    /// Sends a Port RPC request and returns the response with its binary values as `Data`.
    public func requestResponse(
        _ method: String,
        params: JSONValue = .null,
        buffers: [PortBuffer] = []
    ) async throws -> PortResponse {
        let message = try await exchange(method, params: params, buffers: buffers)
        let resultBuffers = message.buffers.compactMap { buffer -> PortInboundBuffer? in
            guard buffer.path.first == .string("result") else { return nil }
            return PortInboundBuffer(path: Array(buffer.path.dropFirst()), data: buffer.data)
        }
        return PortResponse(envelope: message.json, buffers: resultBuffers)
    }

    private static func inlinedResult(of message: PortInboundMessage) throws -> JSONValue {
        var result = try JSONValue(jsonData: message.json).objectValue?["result"] ?? .null
        for buffer in message.buffers where buffer.path.first == .string("result") {
            result = result.setting(
                .string(buffer.data.base64EncodedString()),
                at: Array(buffer.path.dropFirst())
            )
        }
        return result
    }

    private func exchange(
        _ method: String,
        params: JSONValue,
        buffers: [PortBuffer]
    ) async throws -> PortInboundMessage {
        try Task.checkCancellation()
        guard !isClosed else {
            throw closeError
        }
        startListening()

        let id = nextRequestID
        nextRequestID += 1

        let envelope: [String: JSONValue] = [
            "type": .string("request"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]
        let payload = try JSONValue.object(envelope).jsonData()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PortInboundMessage, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if isClosed {
                    continuation.resume(throwing: closeError)
                    return
                }
                pending[id] = continuation
                enqueueOutboundSend(id: id, payload: payload, buffers: buffers)
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(id: id)
            }
        }
    }

    // MARK: - Agents, Projects & Sessions (src/shared/agent-host.ts)

    public func listAgents() async throws -> [AgentStatusInfo] {
        try await request("agents.list", params: .null, as: [AgentStatusInfo].self)
    }

    public func listAgentOptions() async throws -> [AgentOptionsInfo] {
        try await request("agents.options", params: .null, as: [AgentOptionsInfo].self)
    }

    public func readAgentOptions(agentId: String, projectPath: String?) async throws {
        _ = try await request("agents.readOptions", params: .object([
            "agentId": .string(agentId),
            "projectPath": projectPath.map(JSONValue.string) ?? .null,
        ]))
    }

    public func refreshAgentLimits(agentId: String, force: Bool = false) async throws {
        var obj: [String: JSONValue] = ["agentId": .string(agentId)]
        if force { obj["force"] = .bool(true) }
        _ = try await request("agents.refreshLimits", params: .object(obj))
    }

    public func checkAgents(agentId: String? = nil) async throws -> [AgentStatusInfo] {
        let params: JSONValue = agentId.map { .object(["agentId": .string($0)]) } ?? .object([:])
        return try await request("agents.check", params: params, as: [AgentStatusInfo].self)
    }

    public func reloadAgentEnvironment() async throws -> [AgentStatusInfo] {
        try await request("agents.reloadEnvironment", params: .null, as: [AgentStatusInfo].self)
    }

    public func agentEnvironment() async throws -> EnvironmentStatusInfo {
        try await request("agents.environment", params: .null, as: EnvironmentStatusInfo.self)
    }

    public func checkAgentUpdates() async throws -> [AgentStatusInfo] {
        try await request("agents.checkUpdates", params: .null, as: [AgentStatusInfo].self)
    }

    public func updateAgent(agentId: String) async throws {
        _ = try await request("agents.update", params: .object(["agentId": .string(agentId)]))
    }

    public func updateAgentCli(agentId: String) async throws {
        _ = try await request("agents.updateCli", params: .object(["agentId": .string(agentId)]))
    }

    public func retryAgent(agentId: String) async throws {
        _ = try await request("agents.retry", params: .object(["agentId": .string(agentId)]))
    }

    public func reinstallAgent(agentId: String) async throws {
        _ = try await request("agents.reinstall", params: .object(["agentId": .string(agentId)]))
    }

    public func authenticateAgent(agentId: String, methodId: String) async throws {
        _ = try await request("agents.authenticate", params: .object([
            "agentId": .string(agentId),
            "methodId": .string(methodId),
        ]))
    }

    public func logoutAgent(agentId: String) async throws {
        _ = try await request("agents.logout", params: .object(["agentId": .string(agentId)]))
    }

    public func setAgentApiKey(agentId: String, key: String) async throws {
        _ = try await request("agents.setApiKey", params: .object([
            "agentId": .string(agentId),
            "key": .string(key),
        ]))
    }

    public func clearAgentApiKey(agentId: String) async throws {
        _ = try await request("agents.clearApiKey", params: .object(["agentId": .string(agentId)]))
    }

    public func refreshAgentAccount(agentId: String, force: Bool = true) async throws {
        _ = try await request("agents.refreshAccount", params: .object([
            "agentId": .string(agentId),
            "force": .bool(force),
        ]))
    }

    public func listLightAgents() async throws -> [LightAgentInfo] {
        let res = try await request("agents.lightAgents", params: .null)
        if let arr = res.objectValue?["agents"] {
            return try arr.decode([LightAgentInfo].self)
        }
        return []
    }

    public func agentClaudeSettings(agentId: String) async throws -> ClaudeSettingsInfo {
        try await request("agents.claudeSettings", params: .object(["agentId": .string(agentId)]), as: ClaudeSettingsInfo.self)
    }

    public func setAgentClaudePromptCacheTtl(agentId: String, ttl: String?) async throws {
        _ = try await request("agents.setClaudeSetting", params: .object([
            "agentId": .string(agentId),
            "change": .object([
                "setting": .string("promptCacheTtl"),
                "value": ttl.map(JSONValue.string) ?? .null,
            ]),
        ]))
    }

    public func agentAutoCompact(agentId: String) async throws -> AutoCompactSettingsInfo {
        try await request("agents.autoCompact", params: .object(["agentId": .string(agentId)]), as: AutoCompactSettingsInfo.self)
    }

    public func setAgentAutoCompact(agentId: String, model: String?, value: Int?) async throws {
        _ = try await request("agents.setAutoCompact", params: .object([
            "agentId": .string(agentId),
            "change": .object([
                "model": model.map(JSONValue.string) ?? .null,
                "value": value.map { JSONValue.number(Double($0)) } ?? .null,
            ]),
        ]))
    }

    // MARK: - Memory Management (src/shared/memory.ts)

    public func memoryOverview() async throws -> MemoryOverviewInfo {
        try await request("memory.overview", params: .null, as: MemoryOverviewInfo.self)
    }

    public func memoryList(layer: String, project: String? = nil) async throws -> [MemoryEntryInfo] {
        var scope: [String: JSONValue] = ["layer": .string(layer)]
        if let project, layer == "project" {
            scope["project"] = .string(project)
        }
        return try await request("memory.list", params: .object(["scope": .object(scope)]), as: [MemoryEntryInfo].self)
    }

    public func memorySave(
        layer: String,
        project: String? = nil,
        id: String? = nil,
        title: String,
        description: String,
        body: String
    ) async throws -> MemoryEntryInfo {
        var scope: [String: JSONValue] = ["layer": .string(layer)]
        if let project, layer == "project" {
            scope["project"] = .string(project)
        }
        let resolvedId: JSONValue = {
            if let id, !id.isEmpty { return .string(id) }
            return .null
        }()
        let params: [String: JSONValue] = [
            "scope": .object(scope),
            "id": resolvedId,
            "draft": .object([
                "title": .string(title),
                "description": .string(description),
                "body": .string(body),
            ]),
        ]
        return try await request("memory.save", params: .object(params), as: MemoryEntryInfo.self)
    }

    public func memoryRemove(layer: String, project: String? = nil, id: String) async throws {
        var scope: [String: JSONValue] = ["layer": .string(layer)]
        if let project, layer == "project" {
            scope["project"] = .string(project)
        }
        _ = try await request("memory.remove", params: .object([
            "scope": .object(scope),
            "id": .string(id),
        ]))
    }

    public func memoryMoveToGlobal(project: String, id: String) async throws -> MemoryEntryInfo {
        try await request("memory.moveToGlobal", params: .object([
            "project": .string(project),
            "id": .string(id),
        ]), as: MemoryEntryInfo.self)
    }

    public func memorySetEnabled(_ enabled: Bool) async throws {
        _ = try await request("memory.setEnabled", params: .object(["enabled": .bool(enabled)]))
    }

    public func memoryImportScan() async throws -> MemoryImportScanInfo {
        try await request("memory.importScan", params: .null, as: MemoryImportScanInfo.self)
    }

    public func memoryImport(
        sources: [(agentId: String, project: String)],
        globalKeys: [String]
    ) async throws -> MemoryImportResultInfo {
        let sourceValues: [JSONValue] = sources.map {
            .object([
                "agentId": .string($0.agentId),
                "project": .string($0.project),
            ])
        }
        return try await request("memory.import", params: .object([
            "sources": .array(sourceValues),
            "global": .array(globalKeys.map(JSONValue.string)),
        ]), as: MemoryImportResultInfo.self)
    }

    // MARK: - Project Worktree & Session Maintenance

    public func setProjectWorktreeSettings(
        path: String,
        branchTemplate: String,
        copy: [String],
        setup: String?,
        waitForSetup: Bool
    ) async throws {
        _ = try await request("projects.setWorktreeSettings", params: .object([
            "path": .string(path),
            "settings": .object([
                "branchTemplate": .string(branchTemplate),
                "copy": .array(copy.map(JSONValue.string)),
                "setup": setup.map(JSONValue.string) ?? .null,
                "waitForSetup": .bool(waitForSetup),
            ]),
        ]))
    }

    public func removeAllSessions() async throws {
        _ = try await request("sessions.removeAll", params: .null)
    }

    public func usageSummary(
        dayStarts: [Double],
        from: Double,
        to: Double,
        scope: String = "computer"
    ) async throws -> UsageSummaryInfo {
        let roundedDays = dayStarts.map { Double(Int64($0.rounded())) }
        let roundedFrom = Double(Int64(from.rounded()))
        let roundedTo = Double(Int64(to.rounded()))
        let params: JSONValue = .object([
            "dayStarts": .array(roundedDays.map(JSONValue.number)),
            "from": .number(roundedFrom),
            "to": .number(roundedTo),
            "scope": .string(scope),
        ])
        return try await request("usage.summary", params: params, as: UsageSummaryInfo.self)
    }

    public func usageSummary(
        dayStarts: [Date],
        since: Date,
        until: Date,
        scope: String = "computer"
    ) async throws -> UsageSummaryInfo {
        let dayMs = dayStarts.map { Double(Int64(($0.timeIntervalSince1970 * 1000.0).rounded())) }
        let sinceMs = Double(Int64((since.timeIntervalSince1970 * 1000.0).rounded()))
        let untilMs = Double(Int64((until.timeIntervalSince1970 * 1000.0).rounded()))
        return try await usageSummary(dayStarts: dayMs, from: sinceMs, to: untilMs, scope: scope)
    }

    /// Everything the usage views show under `scope`, computed by the host (`usage.overview`).
    public func usageOverview(scope: UsageOverviewScope) async throws -> UsageOverviewInfo {
        try await request(
            "usage.overview",
            params: .object(["scope": .string(scope.rawValue)]),
            as: UsageOverviewInfo.self
        )
    }

    /// Asks the host to read what is new in the agents' logs now; resolves once the scan is done.
    public func usageSync() async throws {
        _ = try await request("usage.sync", params: .null)
    }

    /// Removes an account, by its fingerprint, from the usage overview and what this Mac shares,
    /// until the account is used again.
    public func usageForgetAccount(agentId: String, account: String) async throws {
        _ = try await request(
            "usage.forgetAccount",
            params: .object(["agentId": .string(agentId), "account": .string(account)])
        )
    }

    /// Reads the host's reported Sarto app version and updater state (`app.updateStatus`).
    public func appUpdateStatus() async throws -> AppUpdateStatusInfo {
        try await request("app.updateStatus", params: .null, as: AppUpdateStatusInfo.self)
    }

    /// Reports this Mac's local `SartoUpdater` state to the local daemon (`app.reportUpdateState`).
    public func reportAppUpdateState(_ status: AppUpdateStatusInfo) async throws {
        var obj: [String: JSONValue] = [
            "currentVersion": .string(status.currentVersion),
            "state": .string(status.state),
            "mode": .string(status.mode),
            "canInstall": .bool(status.canInstall),
            "updatedAt": .number(status.updatedAt),
        ]
        if let avail = status.availableVersion { obj["availableVersion"] = .string(avail) }
        if let prog = status.progress { obj["progress"] = .number(Double(prog)) }
        if let err = status.error { obj["error"] = .string(err) }
        _ = try await request("app.reportUpdateState", params: .object(obj))
    }

    /// Asks a host's running Sarto desktop app to check or install an update (`app.requestUpdate`).
    public func requestAppUpdate(action: String) async throws -> AppUpdateRequestResult {
        try await request(
            "app.requestUpdate",
            params: .object(["action": .string(action)]),
            as: AppUpdateRequestResult.self
        )
    }

    public func listProjects() async throws -> [ProjectInfo] {
        try await request("projects.list", params: .null, as: [ProjectInfo].self)
    }

    public func noProjectState() async throws -> NoProjectInfo {
        try await request("projects.noProject", params: .null, as: NoProjectInfo.self)
    }

    public func addProject(path: String) async throws -> ProjectInfo {
        try await request("projects.add", params: .object(["path": .string(path)]), as: ProjectInfo.self)
    }

    public func removeProject(path: String) async throws {
        _ = try await request("projects.remove", params: .object(["path": .string(path)]))
    }

    public func pinProject(path: String?, pinned: Bool) async throws {
        _ = try await request("projects.pin", params: .object([
            "path": path.map(JSONValue.string) ?? .null,
            "pinned": .bool(pinned),
        ]))
    }

    public func moveProject(path: String, before: String?) async throws {
        _ = try await request("projects.move", params: .object([
            "path": .string(path),
            "before": before.map(JSONValue.string) ?? .null,
        ]))
    }

    public func projectWorktreeSettings(path: String) async throws -> ProjectWorktreeSettingsInfo {
        try await request("projects.worktreeSettings", params: .object([
            "path": .string(path),
        ]), as: ProjectWorktreeSettingsInfo.self)
    }

    /// What changed in the session index since `since`; the whole index without one.
    public func sessionChanges(since: SessionsCursorInfo?) async throws -> SessionChangesInfo {
        var params: [String: JSONValue] = [:]
        if let since {
            params["since"] = .object(["boot": .string(since.boot), "rev": .number(Double(since.rev))])
        }
        return try await request("sessions.changes", params: .object(params), as: SessionChangesInfo.self)
    }

    public func listSessions(projectPath: String? = nil) async throws -> [SessionSummary] {
        let params: JSONValue = projectPath.map { .object(["projectPath": .string($0)]) } ?? .object([:])
        return try await request("sessions.list", params: params, as: [SessionSummary].self)
    }

    public func prepareSession(
        agentId: String,
        projectPath: String?,
        parentId: String? = nil,
        options: [String: JSONValue]? = nil,
        replace: Bool = false,
        modelHostId: String? = nil
    ) async throws -> SessionSummary {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "projectPath": projectPath.map(JSONValue.string) ?? .null,
        ]
        if let parentId, !parentId.isEmpty {
            obj["parentId"] = .string(parentId)
        }
        if let options, !options.isEmpty {
            obj["options"] = .object(options)
        }
        if replace {
            obj["replace"] = .bool(true)
        }
        if let modelHostId, !modelHostId.isEmpty {
            obj["modelHostId"] = .string(modelHostId)
        }
        return try await request("sessions.prepare", params: .object(obj), as: SessionSummary.self)
    }

    public func discardPreparedSession(sessionId: String) async throws {
        _ = try await request("sessions.discard", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func createSession(
        agentId: String,
        projectPath: String? = nil,
        prompt: String? = nil,
        parentId: String? = nil,
        options: [String: JSONValue]? = nil,
        preparedId: String? = nil,
        worktree: WorktreeCreateRequest? = nil,
        modelHostId: String? = nil
    ) async throws -> SessionSummary {
        let content: [UserContent]? = prompt.flatMap { $0.isEmpty ? nil : [.text($0)] }
        return try await createSession(
            agentId: agentId,
            projectPath: projectPath,
            promptContent: content,
            parentId: parentId,
            options: options,
            preparedId: preparedId,
            worktree: worktree,
            modelHostId: modelHostId
        )
    }

    public func createSession(
        agentId: String,
        projectPath: String? = nil,
        promptContent: [UserContent]?,
        parentId: String? = nil,
        options: [String: JSONValue]? = nil,
        preparedId: String? = nil,
        worktree: WorktreeCreateRequest? = nil,
        modelHostId: String? = nil
    ) async throws -> SessionSummary {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "projectPath": projectPath.map(JSONValue.string) ?? .null,
        ]
        if let parentId, !parentId.isEmpty {
            obj["parentId"] = .string(parentId)
        }
        if let options, !options.isEmpty {
            obj["options"] = .object(options)
        }
        if let preparedId, !preparedId.isEmpty {
            obj["preparedId"] = .string(preparedId)
        }
        if let modelHostId, !modelHostId.isEmpty {
            obj["modelHostId"] = .string(modelHostId)
        }
        if let worktree {
            var wtObj: [String: JSONValue] = ["base": .string(worktree.base)]
            if let branch = worktree.branch, !branch.isEmpty {
                wtObj["branch"] = .string(branch)
            }
            obj["worktree"] = .object(wtObj)
        }
        if let promptContent, !promptContent.isEmpty {
            let encoded = try JSONEncoder().encode(promptContent)
            obj["prompt"] = try JSONDecoder().decode(JSONValue.self, from: encoded)
        }
        return try await request("sessions.create", params: .object(obj), as: SessionSummary.self)
    }

    public func openSession(sessionId: String) async throws -> SessionSnapshot {
        try await request("sessions.open", params: .object(["sessionId": .string(sessionId)]), as: SessionSnapshot.self)
    }

    /// Read-only snapshot of a session's stored or live thread without waking or starting its agent.
    public func sessionSnapshot(sessionId: String, from: Int? = nil) async throws -> SessionSnapshot {
        var obj: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let from { obj["from"] = .number(Double(from)) }
        return try await request("sessions.snapshot", params: .object(obj), as: SessionSnapshot.self)
    }

    public func loadSessionPage(
        sessionId: String,
        before: Int,
        from: Int? = nil
    ) async throws -> OlderPageInfo {
        var obj: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "before": .number(Double(before)),
        ]
        if let from { obj["from"] = .number(Double(from)) }
        return try await request("sessions.page", params: .object(obj), as: OlderPageInfo.self)
    }

    public func watchSession(sessionId: String) async throws {
        _ = try await request("sessions.watch", params: .object(["sessionId": .string(sessionId)]))
    }

    public func unwatchSession(sessionId: String) async throws {
        _ = try await request("sessions.unwatch", params: .object(["sessionId": .string(sessionId)]))
    }

    /// Tells Sarto daemon which session(s) are currently visible in front (`inFront`), keeping the
    /// agent warm for `releaseShownMs` (30 min) instead of releasing after `releaseHiddenMs` (60 s).
    public func showSessions(_ sessionIds: [String]) async throws {
        _ = try await request("sessions.show", params: .object([
            "sessionIds": .array(sessionIds.map(JSONValue.string)),
        ]))
    }

    public func sendPrompt(sessionId: String, text: String) async throws {
        try await sendPrompt(sessionId: sessionId, content: [.text(text)])
    }

    public func sendPrompt(sessionId: String, content: [UserContent]) async throws {
        let encoded = try JSONEncoder().encode(content)
        let contentVal = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "content": contentVal,
        ])
        _ = try await request("sessions.prompt", params: params)
    }

    // MARK: - Queue, Steering, Retry, Fork, Find, Outline & Agent Switch

    public func queuePrompt(sessionId: String, content: [UserContent]) async throws -> String? {
        let encoded = try JSONEncoder().encode(content)
        let contentVal = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let res = try await request("sessions.queue", params: .object([
            "sessionId": .string(sessionId),
            "content": contentVal,
        ]))
        return res.objectValue?["itemId"]?.stringValue
    }

    public func unqueuePrompt(sessionId: String, itemId: String) async throws {
        _ = try await request("sessions.unqueue", params: .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
        ]))
    }

    public func steerPrompt(sessionId: String, itemId: String) async throws {
        _ = try await request("sessions.steer", params: .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
        ]))
    }

    public func sendQueuedNow(sessionId: String, itemId: String) async throws {
        _ = try await request("sessions.sendNow", params: .object([
            "sessionId": .string(sessionId),
            "itemId": .string(itemId),
        ]))
    }

    public func resumeQueue(sessionId: String) async throws {
        _ = try await request("sessions.resumeQueue", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func retryTurn(sessionId: String) async throws {
        _ = try await request("sessions.retry", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func archiveSession(sessionId: String, subSessions: Bool? = nil) async throws {
        var obj: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let subSessions { obj["subSessions"] = .bool(subSessions) }
        _ = try await request("sessions.archive", params: .object(obj))
    }

    public func unarchiveSession(sessionId: String) async throws {
        _ = try await request("sessions.unarchive", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func forkSession(sessionId: String, entryId: String? = nil) async throws -> SessionSummary {
        var obj: [String: JSONValue] = ["sessionId": .string(sessionId)]
        if let entryId { obj["entryId"] = .string(entryId) }
        return try await request("sessions.fork", params: .object(obj), as: SessionSummary.self)
    }

    public func findInSession(sessionId: String, query: String) async throws -> SessionFindResult {
        try await request("sessions.find", params: .object([
            "sessionId": .string(sessionId),
            "query": .string(query),
        ]), as: SessionFindResult.self)
    }

    public func sessionOutline(sessionId: String) async throws -> [OutlineEntryInfo] {
        let res = try await request("sessions.outline", params: .object([
            "sessionId": .string(sessionId),
        ]))
        guard let entriesVal = res.objectValue?["entries"] else { return [] }
        return (try? entriesVal.decode([OutlineEntryInfo].self)) ?? []
    }

    public func loadSessionOutline(sessionId: String) async throws -> [OutlineEntryInfo] {
        try await sessionOutline(sessionId: sessionId)
    }

    /// Reads one thread entry in full, used to hydrate digested tool entries on demand.
    public func sessionEntry(sessionId: String, entryId: String) async throws -> ThreadEntry {
        try await request("sessions.entry", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
        ]), as: ThreadEntry.self)
    }

    public func switchAgent(
        sessionId: String,
        agentId: String,
        content: [UserContent],
        options: [String: JSONValue]? = nil,
        summarize: Bool = false
    ) async throws {
        let encoded = try JSONEncoder().encode(content)
        let contentVal = try JSONDecoder().decode(JSONValue.self, from: encoded)
        var obj: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "agentId": .string(agentId),
            "content": contentVal,
        ]
        if let options, !options.isEmpty {
            obj["options"] = .object(options)
        }
        if summarize { obj["summarize"] = .bool(true) }
        _ = try await request("sessions.switchAgent", params: .object(obj))
    }

    public func attachSessionEarly(sessionId: String) async throws {
        _ = try await request("sessions.attachEarly", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func refreshSessionModels(sessionId: String) async throws {
        _ = try await request("sessions.refreshModels", params: .object([
            "sessionId": .string(sessionId),
        ]))
    }

    public func runningWork(sessionIds: [String]) async throws -> [RunningWorkInfo] {
        let res = try await request("sessions.runningWork", params: .object([
            "sessionIds": .array(sessionIds.map(JSONValue.string)),
        ]))
        guard let arr = res.objectValue?["sessions"] else { return [] }
        return (try? arr.decode([RunningWorkInfo].self)) ?? []
    }

    // MARK: - Attachments & Session Blobs (src/agent-host/attachments.ts)

    public func addAttachment(
        bytes: Data,
        mimeType: String,
        name: String,
        thumb: String? = nil
    ) async throws -> AttachmentInfo {
        let params: JSONValue = .object([
            "source": .object([
                "bytes": .null,
                "mimeType": .string(mimeType),
                "name": .string(name),
            ]),
            "thumb": thumb.map(JSONValue.string) ?? .null,
        ])
        let buffer = PortBuffer(path: ["params", "source", "bytes"], data: bytes)
        return try await request("attachments.add", params: params, buffers: [buffer], as: AttachmentInfo.self)
    }

    public func addProjectAttachment(
        projectPath: String,
        path: String,
        thumb: String? = nil
    ) async throws -> AttachmentInfo {
        let params: JSONValue = .object([
            "source": .object([
                "projectPath": .string(projectPath),
                "path": .string(path),
            ]),
            "thumb": thumb.map(JSONValue.string) ?? .null,
        ])
        return try await request("attachments.add", params: params, as: AttachmentInfo.self)
    }

    public func removeAttachment(id: String) async throws {
        _ = try await request("attachments.remove", params: .object(["id": .string(id)]))
    }

    public func heldAttachments(ids: [String]) async throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try await request(
            "attachments.held",
            params: .object(["ids": .array(ids.map(JSONValue.string))]),
            as: [String].self
        )
    }

    public func readAttachment(id: String) async throws -> Data {
        let response = try await requestResponse("attachments.read", params: .object(["id": .string(id)]))
        if let data = response.data(atKey: "bytes") {
            return data
        }
        if let b64 = try response.result().objectValue?["bytes"]?.stringValue,
           let decoded = Data(base64Encoded: b64) {
            return decoded
        }
        throw PortRPCError(code: "internal", message: "Invalid attachment payload returned by host")
    }

    public func readSessionBlob(sessionId: String, hash: String) async throws -> (mimeType: String, data: Data) {
        let response = try await requestResponse("sessions.blob", params: .object([
            "sessionId": .string(sessionId),
            "hash": .string(hash),
        ]))
        let invalid = PortRPCError(code: "internal", message: "Invalid blob payload returned by host")
        guard let obj = try response.result().objectValue, let mimeType = obj["mimeType"]?.stringValue else {
            throw invalid
        }
        if let data = response.data(atKey: "bytes") {
            return (mimeType, data)
        }
        // A transport without out-of-band buffers delivers the bytes as base64.
        guard let b64 = obj["bytes"]?.stringValue, let decoded = Data(base64Encoded: b64) else {
            throw invalid
        }
        return (mimeType, decoded)
    }

    public func cancelTurn(sessionId: String) async throws {
        _ = try await request("sessions.cancel", params: .object(["sessionId": .string(sessionId)]))
    }

    public func stopBackgroundTask(sessionId: String, taskId: String) async throws {
        _ = try await request("sessions.stopTask", params: .object([
            "sessionId": .string(sessionId),
            "taskId": .string(taskId),
        ]))
    }

    public func readBackgroundTaskOutput(sessionId: String, taskId: String) async throws -> BackgroundTaskOutput {
        try await request("sessions.taskOutput", params: .object([
            "sessionId": .string(sessionId),
            "taskId": .string(taskId),
        ]), as: BackgroundTaskOutput.self)
    }

    public func setConfigOption(sessionId: String, optionId: String, value: JSONValue) async throws {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "optionId": .string(optionId),
            "value": value,
        ])
        _ = try await request("sessions.setConfigOption", params: params)
    }

    public func renameSession(sessionId: String, title: String?) async throws {
        _ = try await request("sessions.rename", params: .object([
            "sessionId": .string(sessionId),
            "title": title.map(JSONValue.string) ?? .null,
        ]))
    }

    public func deleteSession(sessionId: String) async throws {
        _ = try await request("sessions.delete", params: .object(["sessionId": .string(sessionId)]))
    }

    public func pinSession(sessionId: String, pinned: Bool) async throws {
        _ = try await request("sessions.pin", params: .object([
            "sessionId": .string(sessionId),
            "pinned": .bool(pinned),
        ]))
    }

    public func markSessionUnread(sessionId: String, unread: Bool) async throws {
        _ = try await request("sessions.markUnread", params: .object([
            "sessionId": .string(sessionId),
            "unread": .bool(unread),
        ]))
    }

    public func sessionOutputs(sessionId: String) async throws -> SessionOutputsInfo {
        try await request("sessions.outputs", params: .object([
            "sessionId": .string(sessionId),
        ]), as: SessionOutputsInfo.self)
    }

    public func respondPermission(
        sessionId: String,
        requestId: String,
        optionId: String? = nil,
        note: String? = nil,
        answers: [QuestionAnswer]? = nil,
        values: [String: JSONValue]? = nil
    ) async throws {
        var obj: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
        ]
        if let optionId { obj["optionId"] = .string(optionId) }
        if let note, !note.isEmpty { obj["note"] = .string(note) }
        if let answers {
            let encoded = try JSONEncoder().encode(answers)
            obj["answers"] = try JSONDecoder().decode(JSONValue.self, from: encoded)
        }
        if let values {
            obj["values"] = .object(values)
        }
        _ = try await request("permissions.respond", params: .object(obj))
    }

    // MARK: - Interactive Thread Entry RPCs (Memory, Settings, Access, Control)

    public func answerMemory(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("sessions.answerMemory", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func undoMemory(sessionId: String, entryId: String) async throws {
        _ = try await request("sessions.undoMemory", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
        ]))
    }

    public func answerSettingsChange(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("settings.answerChange", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func undoSettingsChange(sessionId: String, entryId: String) async throws {
        _ = try await request("settings.undoChange", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
        ]))
    }

    public func answerBrowserOrigin(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("browser.answerOrigin", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    // MARK: - Desktop Browser Host RPCs (src/shared/agent-host.ts)

    public func browserAnswer(callId: Int, answer: BrowserCallAnswer) async throws {
        _ = try await request("browser.answer", params: .object([
            "callId": .number(Double(callId)),
            "answer": answer.toJSONValue(),
        ]))
    }

    public func browserWaiting(callId: Int, waiting: Bool) async throws {
        _ = try await request("browser.waiting", params: .object([
            "callId": .number(Double(callId)),
            "waiting": .bool(waiting),
        ]))
    }

    public func browserOrigin(sessionId: String, requestId: Int, origin: String) async throws {
        _ = try await request("browser.origin", params: .object([
            "sessionId": .string(sessionId),
            "requestId": .number(Double(requestId)),
            "origin": .string(origin),
        ]))
    }

    public func browserOriginSettled(requestId: Int, decision: String) async throws {
        _ = try await request("browser.originSettled", params: .object([
            "requestId": .number(Double(requestId)),
            "decision": .string(decision),
        ]))
    }

    public func browserHandedBack(sessionId: String, durationMs: Int) async throws {
        _ = try await request("browser.handedBack", params: .object([
            "sessionId": .string(sessionId),
            "durationMs": .number(Double(max(0, durationMs))),
        ]))
    }

    public func answerControlAsk(sessionId: String, entryId: String, outcome: String) async throws {
        _ = try await request("control.answerAsk", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "outcome": .string(outcome),
        ]))
    }

    public func answerDeviceAccess(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("devices.answerAccess", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func revokeDeviceAccess(sessionId: String, deviceId: String) async throws {
        _ = try await request("devices.revokeAccess", params: .object([
            "sessionId": .string(sessionId),
            "deviceId": .string(deviceId),
        ]))
    }

    public func allowedDevices() async throws -> [String] {
        let res = try await request("devices.allowed", params: .object([:]))
        return res.objectValue?["deviceIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    public func forgetDevice(deviceId: String) async throws {
        _ = try await request("devices.forget", params: .object([
            "deviceId": .string(deviceId),
        ]))
    }

    public func answerSurfaceAccess(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("surfaces.answerAccess", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func revokeTerminalAccess(sessionId: String, terminalId: String) async throws {
        _ = try await request("terminals.revokeAccess", params: .object([
            "sessionId": .string(sessionId),
            "terminalId": .string(terminalId),
        ]))
    }

    public func answerComputerApp(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("computer.answerApp", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func declineComputerSetup(sessionId: String, entryId: String) async throws {
        _ = try await request("computer.declineSetup", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
        ]))
    }

    public func answerProjectMcp(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("sessions.answerProjectMcp", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func answerProjectHooks(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("sessions.answerProjectHooks", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    public func answerProblemReport(
        sessionId: String,
        entryId: String,
        outcomeKind: String,
        reportId: String? = nil
    ) async throws {
        var outcome: [String: JSONValue] = ["kind": .string(outcomeKind)]
        if outcomeKind == "sent", let reportId, !reportId.isEmpty {
            outcome["reportId"] = .string(reportId)
        }
        _ = try await request("sessions.answerReport", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "outcome": .object(outcome),
        ]))
    }

    public func draftProblemReport(
        origin: String?,
        sessionId: String?,
        agentId: String?,
        error: String?,
        language: String,
        draftAgentId: String? = nil,
        draftModel: String? = nil,
        fallbackAgentId: String? = nil,
        fallbackModel: String? = nil
    ) async throws -> ReportDraftResultInfo {
        var params: [String: JSONValue] = [
            "origin": origin.map(JSONValue.string) ?? .null,
            "sessionId": sessionId.map(JSONValue.string) ?? .null,
            "agentId": agentId.map(JSONValue.string) ?? .null,
            "error": error.map(JSONValue.string) ?? .null,
            "language": .string(language),
        ]
        if let draftAgentId, !draftAgentId.isEmpty {
            params["draftAgentId"] = .string(draftAgentId)
        }
        if let draftModel, !draftModel.isEmpty {
            params["draftModel"] = .string(draftModel)
        }
        if let fallbackAgentId, !fallbackAgentId.isEmpty {
            params["fallbackAgentId"] = .string(fallbackAgentId)
        }
        if let fallbackModel, !fallbackModel.isEmpty {
            params["fallbackModel"] = .string(fallbackModel)
        }
        return try await request("agents.draftReport", params: .object(params), as: ReportDraftResultInfo.self)
    }

    public func answerMarketPublish(sessionId: String, entryId: String, decision: String) async throws {
        _ = try await request("market.answerPublish", params: .object([
            "sessionId": .string(sessionId),
            "entryId": .string(entryId),
            "decision": .string(decision),
        ]))
    }

    // MARK: - Git Workbench RPCs (src/shared/git.ts & agent-host.ts)

    public func gitStatus(projectPath: String, watcher: String? = nil) async throws -> GitStatusInfo {
        var obj: [String: JSONValue] = ["projectPath": .string(projectPath)]
        if let watcher { obj["watcher"] = .string(watcher) }
        return try await request("git.status", params: .object(obj), as: GitStatusInfo.self)
    }

    public func gitChanges(projectPath: String) async throws -> [ChangedFileInfo] {
        try await request("git.changes", params: .object(["projectPath": .string(projectPath)]), as: [ChangedFileInfo].self)
    }

    public func gitFileDiff(
        projectPath: String,
        path: String,
        oldPath: String? = nil,
        ref: String? = nil
    ) async throws -> FileDiffInfo {
        let obj: [String: JSONValue] = [
            "projectPath": .string(projectPath),
            "path": .string(path),
            "oldPath": oldPath.map(JSONValue.string) ?? .null,
            "ref": ref.map(JSONValue.string) ?? .null,
        ]
        return try await request("git.fileDiff", params: .object(obj), as: FileDiffInfo.self)
    }

    public func gitBranches(projectPath: String) async throws -> BranchListInfo {
        try await request("git.branches", params: .object(["projectPath": .string(projectPath)]), as: BranchListInfo.self)
    }

    public func gitSwitchBranch(projectPath: String, branch: String, create: Bool = false) async throws -> GitOperationResult {
        try await request("git.switchBranch", params: .object([
            "projectPath": .string(projectPath),
            "branch": .string(branch),
            "create": .bool(create),
        ]), as: GitOperationResult.self)
    }

    public func gitCommitChanges(projectPath: String, message: String, paths: [String]) async throws -> GitOperationResult {
        try await request("git.commitChanges", params: .object([
            "projectPath": .string(projectPath),
            "message": .string(message),
            "paths": .array(paths.map(JSONValue.string)),
        ]), as: GitOperationResult.self)
    }

    public func gitDiscardChanges(projectPath: String, paths: [String]) async throws -> GitOperationResult {
        try await request("git.discardChanges", params: .object([
            "projectPath": .string(projectPath),
            "paths": .array(paths.map(JSONValue.string)),
        ]), as: GitOperationResult.self)
    }

    public func gitCommitMessage(projectPath: String, paths: [String]) async throws -> String {
        let res = try await request("git.commitMessage", params: .object([
            "projectPath": .string(projectPath),
            "paths": .array(paths.map(JSONValue.string)),
        ]))
        return res.stringValue ?? ""
    }

    // MARK: - Global Search, Context Breakdown & External CLI Session Import

    public func searchSessions(query: String) async throws -> SessionSearchResultInfo {
        try await request("sessions.search", params: .object([
            "query": .string(query),
        ]), as: SessionSearchResultInfo.self)
    }

    public func sessionContext(sessionId: String) async throws -> ContextBreakdownInfo? {
        try await request("sessions.context", params: .object([
            "sessionId": .string(sessionId),
        ]), as: ContextBreakdownInfo?.self)
    }

    public func sessionContextEstimates(sessionId: String) async throws -> ContextEstimatesInfo? {
        try await request("sessions.contextEstimates", params: .object([
            "sessionId": .string(sessionId),
        ]), as: ContextEstimatesInfo?.self)
    }

    public func listAgentSessions(
        agentId: String,
        projectPath: String,
        cursor: String? = nil
    ) async throws -> ImportableSessionsPageInfo {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "projectPath": .string(projectPath),
        ]
        if let cursor { obj["cursor"] = .string(cursor) }
        return try await request("agents.listSessions", params: .object(obj), as: ImportableSessionsPageInfo.self)
    }

    public func importSession(
        agentId: String,
        projectPath: String,
        acpSessionId: String,
        fork: Bool = false
    ) async throws -> SessionSummary {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "projectPath": .string(projectPath),
            "acpSessionId": .string(acpSessionId),
        ]
        if fork { obj["fork"] = .bool(true) }
        return try await request("sessions.import", params: .object(obj), as: SessionSummary.self)
    }

    // MARK: - MCP Hub, OAuth Proxy & Agent Plugins (src/shared/marketplace.ts)

    public func mcpStatus() async throws -> McpStatusInfo {
        try await request("mcp.status", params: .null, as: McpStatusInfo.self)
    }

    public func mcpRetry() async throws -> McpStatusInfo {
        try await request("mcp.retry", params: .null, as: McpStatusInfo.self)
    }

    public func marketCatalog(refresh: Bool = false, cached: Bool = false) async throws -> MarketCatalogInfo {
        var obj: [String: JSONValue] = [:]
        if refresh { obj["refresh"] = .bool(true) }
        if cached { obj["cached"] = .bool(true) }
        return try await request("market.catalog", params: .object(obj), as: MarketCatalogInfo.self)
    }

    public func marketSearch(query: String) async throws -> MarketSearchInfo {
        try await request("market.search", params: .object([
            "query": .string(query),
        ]), as: MarketSearchInfo.self)
    }

    public func marketKeys() async throws -> [String: [String]] {
        try await request("market.keys", params: .null, as: [String: [String]].self)
    }

    public func marketConnections() async throws -> [String: MarketConnectionInfo] {
        try await request("market.connections", params: .null, as: [String: MarketConnectionInfo].self)
    }

    public func marketConnect(serverId: String) async throws -> ConnectStartInfo {
        try await request("market.connect", params: .object([
            "serverId": .string(serverId),
        ]), as: ConnectStartInfo.self)
    }

    public func marketDetectSignIn(
        url: String,
        headers: [(name: String, value: String)] = []
    ) async throws -> McpOAuthInfo? {
        let headerValues = headers.map { pair in
            JSONValue.object(["name": .string(pair.name), "value": .string(pair.value)])
        }
        let res = try await request("market.detectSignIn", params: .object([
            "url": .string(url),
            "headers": .array(headerValues),
        ]))
        guard let oauthVal = res.objectValue?["oauth"], oauthVal != .null else { return nil }
        return try oauthVal.decode(McpOAuthInfo.self)
    }

    public func marketCancelConnect(loginId: String) async throws {
        _ = try await request("market.cancelConnect", params: .object([
            "loginId": .string(loginId),
        ]))
    }

    public func marketDisconnect(serverId: String) async throws {
        _ = try await request("market.disconnect", params: .object([
            "serverId": .string(serverId),
        ]))
    }

    public func marketPlugins(refresh: Bool = false, cached: Bool = false) async throws -> MarketPluginsInfo {
        var obj: [String: JSONValue] = [:]
        if refresh { obj["refresh"] = .bool(true) }
        if cached { obj["cached"] = .bool(true) }
        return try await request("market.plugins", params: .object(obj), as: MarketPluginsInfo.self)
    }

    public func marketPluginDetails(agentId: String, pluginId: String) async throws -> PluginDetailsInfo {
        try await request("market.pluginDetails", params: .object([
            "agentId": .string(agentId),
            "pluginId": .string(pluginId),
        ]), as: PluginDetailsInfo.self)
    }

    public func marketInstallPlugin(
        agentId: String,
        pluginId: String,
        scope: String = "user",
        projectPath: String? = nil
    ) async throws -> InstalledPluginInfo {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "pluginId": .string(pluginId),
            "scope": .string(scope),
        ]
        if let projectPath { obj["projectPath"] = .string(projectPath) }
        return try await request("market.installPlugin", params: .object(obj), as: InstalledPluginInfo.self)
    }

    public func marketUninstallPlugin(
        agentId: String,
        pluginId: String,
        scope: String = "user",
        projectPath: String? = nil
    ) async throws {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "pluginId": .string(pluginId),
            "scope": .string(scope),
        ]
        if let projectPath { obj["projectPath"] = .string(projectPath) }
        _ = try await request("market.uninstallPlugin", params: .object(obj))
    }

    public func marketSetPluginEnabled(
        agentId: String,
        pluginId: String,
        enabled: Bool,
        scope: String = "user",
        projectPath: String? = nil
    ) async throws {
        var obj: [String: JSONValue] = [
            "agentId": .string(agentId),
            "pluginId": .string(pluginId),
            "enabled": .bool(enabled),
            "scope": .string(scope),
        ]
        if let projectPath { obj["projectPath"] = .string(projectPath) }
        _ = try await request("market.setPluginEnabled", params: .object(obj))
    }

    public func marketAddMarketplace(agentId: String, source: String) async throws -> PluginMarketplaceInfo {
        try await request("market.addMarketplace", params: .object([
            "agentId": .string(agentId),
            "source": .string(source),
        ]), as: PluginMarketplaceInfo.self)
    }

    public func marketRemoveMarketplace(agentId: String, name: String) async throws {
        _ = try await request("market.removeMarketplace", params: .object([
            "agentId": .string(agentId),
            "name": .string(name),
        ]))
    }

    // MARK: - Files Workbench RPCs (src/shared/files.ts & agent-host.ts)

    public func filesList(projectPath: String) async throws -> ProjectFileList {
        try await request("files.list", params: .object(["projectPath": .string(projectPath)]), as: ProjectFileList.self)
    }

    public func watchFiles(projectPath: String) async throws {
        _ = try await request("files.watch", params: .object(["projectPath": .string(projectPath)]))
    }

    public func unwatchFiles(projectPath: String) async throws {
        _ = try await request("files.unwatch", params: .object(["projectPath": .string(projectPath)]))
    }

    public func filesListFolder(projectPath: String, path: String) async throws -> ProjectFolderList {
        try await request("files.listFolder", params: .object([
            "projectPath": .string(projectPath),
            "path": .string(path),
        ]), as: ProjectFolderList.self)
    }

    public func filesUpload(
        projectPath: String,
        path: String,
        bytes: Data,
        replace: Bool = false
    ) async throws {
        var obj: [String: JSONValue] = [
            "projectPath": .string(projectPath),
            "path": .string(path),
            "source": .object(["bytes": .null]),
        ]
        if replace { obj["replace"] = .bool(true) }
        let buffer = PortBuffer(path: ["params", "source", "bytes"], data: bytes)
        _ = try await request("files.upload", params: .object(obj), buffers: [buffer])
    }

    public func filesUploadGrant(
        projectPath: String,
        path: String,
        grantId: String,
        replace: Bool = false
    ) async throws {
        var obj: [String: JSONValue] = [
            "projectPath": .string(projectPath),
            "path": .string(path),
            "source": .object(["grantId": .string(grantId)]),
        ]
        if replace { obj["replace"] = .bool(true) }
        _ = try await request("files.upload", params: .object(obj))
    }

    // MARK: - Host System Load RPCs (src/shared/host-load.ts)

    public func watchHostLoad() async throws -> HostLoadWatch {
        try await request("host.load.watch", params: .null, as: HostLoadWatch.self)
    }

    public func unwatchHostLoad() async throws {
        _ = try await request("host.load.unwatch", params: .null)
    }

    public func filesRead(projectPath: String, path: String, asText: Bool = false) async throws -> ProjectFileContent {
        var obj: [String: JSONValue] = [
            "projectPath": .string(projectPath),
            "path": .string(path),
        ]
        if asText { obj["asText"] = .bool(true) }
        return try await request("files.read", params: .object(obj), as: ProjectFileContent.self)
    }

    public func filesAgentFolder(sessionId: String) async throws -> String? {
        let value = try await request("files.agentFolder", params: .object([
            "sessionId": .string(sessionId),
        ]))
        return value.stringValue
    }

    public func filesReadAgentFile(sessionId: String, path: String) async throws -> ProjectFileContent {
        try await request("files.readAgentFile", params: .object([
            "sessionId": .string(sessionId),
            "path": .string(path),
        ]), as: ProjectFileContent.self)
    }

    public func filesWrite(projectPath: String, path: String, text: String, version: String? = nil) async throws -> ProjectFileWritten {
        try await request("files.write", params: .object([
            "projectPath": .string(projectPath),
            "path": .string(path),
            "text": .string(text),
            "version": version.map(JSONValue.string) ?? .null,
        ]), as: ProjectFileWritten.self)
    }

    public func filesSearch(projectPath: String, query: String) async throws -> ProjectFileSearch {
        try await request("files.search", params: .object([
            "projectPath": .string(projectPath),
            "query": .string(query),
        ]), as: ProjectFileSearch.self)
    }

    public func previewFile(sessionId: String, path: String) async throws -> String {
        try await request("files.preview", params: .object([
            "sessionId": .string(sessionId),
            "path": .string(path),
        ]), as: String.self)
    }

    // MARK: - Daemon Control Socket Helpers (src/daemon/control.ts)

    public func daemonHostSocketPath(host: String = "agent") async throws -> String {
        let res = try await request("host.socket", params: .object(["host": .string(host)]))
        guard let path = res.objectValue?["path"]?.stringValue else {
            throw PortRPCError(code: "internal", message: "Missing socket path in host.socket response")
        }
        return path
    }

    public func daemonStatus() async throws -> DaemonStatusInfo {
        try await request("status", params: .null, as: DaemonStatusInfo.self)
    }

    public func daemonListDevices() async throws -> [PairedDeviceSummary] {
        try await request("devices.list", params: .null, as: [PairedDeviceSummary].self)
    }

    public func daemonRemoveDevice(id: String) async throws {
        _ = try await request("devices.remove", params: .object(["id": .string(id)]))
    }

    public func daemonTerminalAllowedGet() async throws -> Bool {
        let res = try await request("terminal.get", params: .null)
        return res.objectValue?["allowed"]?.boolValue ?? false
    }

    public func daemonTerminalAllowedSet(_ allowed: Bool) async throws -> Bool {
        let res = try await request("terminal.set", params: .object(["allowed": .bool(allowed)]))
        return res.objectValue?["allowed"]?.boolValue ?? allowed
    }

    public func daemonSetPresence(_ present: Bool) async throws {
        _ = try await request("presence.set", params: .object(["present": .bool(present)]))
    }

    public func daemonSetVerbose(_ on: Bool) async throws -> Double? {
        let res = try await request("verbose.set", params: .object(["on": .bool(on)]))
        return res.objectValue?["until"]?.doubleValue
    }

    public func daemonBuildReport(description: String = "Sarto diagnostic report") async throws -> ReportBuildResultInfo {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await request("report.build", params: .object([
            "request": .object([
                "description": .string(trimmed.isEmpty ? "Sarto diagnostic report" : trimmed),
                "range": .object(["kind": .string("today")]),
                "extras": .array([]),
            ]),
        ]), as: ReportBuildResultInfo.self)
    }

    public func daemonPrepareReport(
        description: String,
        rangeKind: String,
        extras: [String],
        sessionId: String? = nil,
        agentId: String? = nil,
        error: String? = nil,
        client: ReportClientPayloadInfo? = nil
    ) async throws -> PreparedReportInfo {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var reqObj: [String: JSONValue] = [
            "description": .string(trimmed.isEmpty ? "Sarto problem report" : trimmed),
            "range": .object(["kind": .string(rangeKind)]),
            "extras": .array(extras.map(JSONValue.string)),
        ]
        if sessionId != nil || agentId != nil || error != nil {
            reqObj["context"] = .object([
                "sessionId": sessionId.map(JSONValue.string) ?? .null,
                "agentId": agentId.map(JSONValue.string) ?? .null,
                "error": error.map(JSONValue.string) ?? .null,
            ])
        } else {
            reqObj["context"] = .null
        }
        var params: [String: JSONValue] = ["request": .object(reqObj)]
        if let client {
            params["client"] = client.toJSONValue()
        }
        return try await request("report.prepare", params: .object(params), as: PreparedReportInfo.self)
    }

    public func daemonAdoptReport(
        zipBase64: String,
        files: [ReportFileInfo],
        redactionCount: Int? = nil
    ) async throws -> PreparedReportInfo {
        var params: [String: JSONValue] = [
            "zip": .string(zipBase64),
            "files": .array(files.map {
                .object([
                    "path": .string($0.path),
                    "size": .number(Double($0.size)),
                    "kind": .string($0.kind),
                ])
            }),
        ]
        if let redactionCount {
            params["redactionCount"] = .number(Double(redactionCount))
        }
        return try await request("report.adopt", params: .object(params), as: PreparedReportInfo.self)
    }

    public func daemonReadReportFile(id: String, path: String) async throws -> ReportFileViewInfo {
        try await request("report.read", params: .object([
            "id": .string(id),
            "path": .string(path),
        ]), as: ReportFileViewInfo.self)
    }

    public func daemonSaveReport(id: String, destination: String, overwrite: Bool = true) async throws -> ReportSaveResultInfo {
        try await request("report.save", params: .object([
            "id": .string(id),
            "destination": .string(destination),
            "overwrite": .bool(overwrite),
        ]), as: ReportSaveResultInfo.self)
    }

    public func daemonSubmitReport(id: String, allowAnonymous: Bool = true) async throws -> ReportSubmitResultInfo {
        try await request("report.submit", params: .object([
            "id": .string(id),
            "allowAnonymous": .bool(allowAnonymous),
        ]), as: ReportSubmitResultInfo.self)
    }

    public func daemonDropReport(id: String) async throws {
        _ = try await request("report.drop", params: .object(["id": .string(id)]))
    }

    public func daemonListReports(limit: Int = 20, status: String? = nil) async throws -> CloudReportListInfo {
        var params: [String: JSONValue] = ["limit": .number(Double(limit))]
        if let status, !status.isEmpty { params["status"] = .string(status) }
        return try await request("report.list", params: .object(params), as: CloudReportListInfo.self)
    }

    public func adminHostReport(
        description: String,
        rangeKind: String,
        extras: [String],
        sessionId: String? = nil,
        agentId: String? = nil,
        error: String? = nil
    ) async throws -> DeviceReportInfo {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var reqObj: [String: JSONValue] = [
            "description": .string(trimmed.isEmpty ? "Sarto problem report" : trimmed),
            "range": .object(["kind": .string(rangeKind)]),
            "extras": .array(extras.map(JSONValue.string)),
        ]
        if sessionId != nil || agentId != nil || error != nil {
            reqObj["context"] = .object([
                "sessionId": sessionId.map(JSONValue.string) ?? .null,
                "agentId": agentId.map(JSONValue.string) ?? .null,
                "error": error.map(JSONValue.string) ?? .null,
            ])
        } else {
            reqObj["context"] = .null
        }
        return try await request("host.report", params: .object(["request": .object(reqObj)]), as: DeviceReportInfo.self)
    }

    public func adminHostSubmitReport(ref: String, allowAnonymous: Bool = true) async throws -> ReportSubmitResultInfo {
        try await request("host.submitReport", params: .object([
            "ref": .string(ref),
            "allowAnonymous": .bool(allowAnonymous),
        ]), as: ReportSubmitResultInfo.self)
    }

    // MARK: - HostAdmin RPCs (Direct Remote Channel OR Local Daemon Control `admin` Passthrough)

    public func adminSettingsGet() async throws -> HostSettingsSnapshot {
        let res = try await request("settings.get", params: .null)
        return HostSettingsSnapshot.from(json: res)
    }

    public func adminSettingsUpdate(_ patch: [String: JSONValue]) async throws -> HostSettingsSnapshot {
        let res = try await request("settings.update", params: .object([
            "patch": .object(patch),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func adminSetAgentBinary(harnessId: String, path: String) async throws -> HostSettingsSnapshot {
        let res = try await request("settings.setAgentBinary", params: .object([
            "harnessId": .string(harnessId),
            "path": .string(path),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func adminSetShellPath(_ path: String) async throws -> HostSettingsSnapshot {
        let res = try await request("settings.setShellPath", params: .object([
            "path": .string(path),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func adminMarketplaceSetKeys(
        serverId: String,
        values: [String: String?]
    ) async throws -> [String: [String]] {
        let mapped = values.mapValues { $0.map(JSONValue.string) ?? .null }
        return try await request("marketplace.setKeys", params: .object([
            "patch": .object([
                "serverId": .string(serverId),
                "values": .object(mapped),
            ]),
        ]), as: [String: [String]].self)
    }

    public func adminMarketplaceSetAgentEnv(
        agentId: String,
        variable: String,
        value: String?
    ) async throws {
        _ = try await request("marketplace.setAgentEnv", params: .object([
            "agentId": .string(agentId),
            "variable": .string(variable),
            "value": value.map(JSONValue.string) ?? .null,
        ]))
    }

    public func daemonAdminCall(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        var payload: [String: JSONValue] = ["method": .string(method)]
        if let params, params != .null {
            payload["params"] = params
        }
        return try await request("admin", params: .object(payload))
    }

    public func daemonSettingsGet() async throws -> HostSettingsSnapshot {
        let res = try await daemonAdminCall("settings.get")
        return HostSettingsSnapshot.from(json: res)
    }

    public func daemonSettingsUpdate(_ patch: [String: JSONValue]) async throws -> HostSettingsSnapshot {
        let res = try await daemonAdminCall("settings.update", params: .object([
            "patch": .object(patch),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func daemonSetAgentBinary(harnessId: String, path: String) async throws -> HostSettingsSnapshot {
        let res = try await daemonAdminCall("settings.setAgentBinary", params: .object([
            "harnessId": .string(harnessId),
            "path": .string(path),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func daemonSetShellPath(_ path: String) async throws -> HostSettingsSnapshot {
        let res = try await daemonAdminCall("settings.setShellPath", params: .object([
            "path": .string(path),
        ]))
        return HostSettingsSnapshot.from(json: res)
    }

    public func daemonMarketplaceSetKeys(
        serverId: String,
        values: [String: String?]
    ) async throws -> [String: [String]] {
        let mapped = values.mapValues { $0.map(JSONValue.string) ?? .null }
        return try await daemonAdminCall("marketplace.setKeys", params: .object([
            "patch": .object([
                "serverId": .string(serverId),
                "values": .object(mapped),
            ]),
        ])).decode([String: [String]].self)
    }

    public func daemonMarketplaceSetAgentEnv(
        agentId: String,
        variable: String,
        value: String?
    ) async throws {
        _ = try await daemonAdminCall("marketplace.setAgentEnv", params: .object([
            "agentId": .string(agentId),
            "variable": .string(variable),
            "value": value.map(JSONValue.string) ?? .null,
        ]))
    }

    // MARK: - Sarto Cloud Account & E2EE Workspace Sync Control RPCs (`src/daemon/control.ts`)

    public func daemonAccountStatus() async throws -> CloudAccountStatusInfo {
        try await request("account.status", params: .null, as: CloudAccountStatusInfo.self)
    }

    public func daemonAccountSubscribe() async throws -> CloudAccountStatusInfo {
        try await request("account.subscribe", params: .null, as: CloudAccountStatusInfo.self)
    }

    /// The idle game's link and latest state; `gameStatus` and `gameFrame` events follow while the
    /// connection stays open.
    public func daemonGameSubscribe() async throws -> (GameLinkStatusInfo, GameStateInfo?) {
        HostEvent.gameSubscription(try await request("game.subscribe", params: .null, as: JSONValue.self))
    }

    /// Tells the daemon whether a game surface is visible on screen, opening or closing the live stream.
    public func daemonGameWatch(_ watching: Bool) async throws {
        _ = try await request("game.watch", params: .object(["watching": .bool(watching)]), as: JSONValue.self)
    }

    /// Turns the idle game on or off for this Mac; the daemon answers with the link's new status.
    public func daemonGameSetEnabled(_ enabled: Bool) async throws -> GameLinkStatusInfo {
        let raw = try await request(
            "game.setEnabled",
            params: .object(["enabled": .bool(enabled)]),
            as: JSONValue.self
        )
        return GameLinkStatusInfo(raw.objectValue ?? [:])
    }

    /// Sends a player command to the idle game service through the daemon.
    public func daemonGameCommand(type: String, args: [String: JSONValue] = [:]) async throws -> GameCommandOutcome {
        let raw = try await request(
            "game.command",
            params: .object(["type": .string(type), "args": .object(args)]),
            as: JSONValue.self
        )
        return GameCommandOutcome(raw)
    }

    public func daemonAccountSignIn(
        serverUrl: String? = nil,
        openBrowser: Bool? = nil
    ) async throws -> CloudAccountStatusInfo {
        var obj: [String: JSONValue] = [:]
        if let serverUrl, !serverUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            obj["serverUrl"] = .string(serverUrl.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let openBrowser {
            obj["openBrowser"] = .bool(openBrowser)
        }
        return try await request("account.signIn", params: .object(obj), as: CloudAccountStatusInfo.self)
    }

    public func daemonAccountCancelSignIn() async throws -> CloudAccountStatusInfo {
        try await request("account.cancelSignIn", params: .null, as: CloudAccountStatusInfo.self)
    }

    public func daemonAccountSignOut() async throws -> CloudAccountStatusInfo {
        try await request("account.signOut", params: .null, as: CloudAccountStatusInfo.self)
    }

    public func daemonAccountCheck() async throws -> CloudAccountStatusInfo {
        try await request("account.check", params: .null, as: CloudAccountStatusInfo.self)
    }

    public func daemonAccountDevices() async throws -> [CloudDeviceInfo] {
        try await request("account.devices", params: .null, as: [CloudDeviceInfo].self)
    }

    public func daemonAccountRemoveDevice(id: String) async throws {
        _ = try await request("account.removeDevice", params: .object(["id": .string(id)]))
    }

    public func daemonAccountRelayToken() async throws -> CloudRelayTokenInfo {
        try await request("account.relayToken", params: .null, as: CloudRelayTokenInfo.self)
    }

    public func daemonAccountPreferences() async throws -> CloudAccountPreferencesInfo {
        try await request("account.preferences", params: .null, as: CloudAccountPreferencesInfo.self)
    }

    public func daemonAccountSetPreferences(
        appTheme: String? = nil
    ) async throws -> CloudAccountPreferencesInfo {
        var obj: [String: JSONValue] = [:]
        if let appTheme { obj["appTheme"] = .string(appTheme) }
        return try await request("account.setPreferences", params: .object(obj), as: CloudAccountPreferencesInfo.self)
    }

    public func daemonSyncStatus() async throws -> SartoSyncStatusInfo {
        try await request("sync.status", params: .null, as: SartoSyncStatusInfo.self)
    }

    public func daemonSyncSubscribe() async throws -> SartoSyncStatusInfo {
        try await request("sync.subscribe", params: .null, as: SartoSyncStatusInfo.self)
    }

    public func daemonSyncSetupVault() async throws -> SyncVaultSetupResult {
        try await request("sync.setupVault", params: .null, as: SyncVaultSetupResult.self)
    }

    public func daemonSyncUnlockRecovery(recoveryKey: String) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.unlockRecovery",
            params: .object(["recoveryKey": .string(recoveryKey)]),
            as: SartoSyncStatusInfo.self
        )
    }

    public func daemonSyncApproveDevice(deviceId: String) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.approveDevice",
            params: .object(["deviceId": .string(deviceId)]),
            as: SartoSyncStatusInfo.self
        )
    }

    /// On a Mac waiting for approval: whether its code matches the one the answering Mac shows.
    public func daemonSyncConfirmApproval(matches: Bool) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.confirmApproval",
            params: .object(["matches": .bool(matches)]),
            as: SartoSyncStatusInfo.self
        )
    }

    public func daemonSyncRejectDevice(deviceId: String) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.rejectDevice",
            params: .object(["deviceId": .string(deviceId)]),
            as: SartoSyncStatusInfo.self
        )
    }

    public func daemonSyncRemoveDeviceWrap(deviceId: String) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.removeDeviceWrap",
            params: .object(["deviceId": .string(deviceId)]),
            as: SartoSyncStatusInfo.self
        )
    }

    public func daemonSyncGetUsage() async throws -> SyncUsageSnapshotResult {
        try await request("sync.getUsage", params: .null, as: SyncUsageSnapshotResult.self)
    }

    public func daemonSyncRemoveUsage(deviceId: String) async throws -> SartoSyncStatusInfo {
        try await request(
            "sync.removeUsage",
            params: .object(["deviceId": .string(deviceId)]),
            as: SartoSyncStatusInfo.self
        )
    }

    public func daemonSyncDisconnect() async throws -> SartoSyncStatusInfo {
        try await request("sync.disconnect", params: .null, as: SartoSyncStatusInfo.self)
    }

    public func daemonSyncNow() async throws -> SartoSyncStatusInfo {
        try await request("sync.now", params: .null, as: SartoSyncStatusInfo.self)
    }

    public func daemonSyncPushClientState(
        uiPrefs: [String: SartoSyncedUiPrefEntry]? = nil,
        device: SartoTrustedDeviceInput? = nil
    ) async throws -> SartoSyncStatusInfo {
        var obj: [String: JSONValue] = [:]
        if let uiPrefs, !uiPrefs.isEmpty {
            var prefsObj: [String: JSONValue] = [:]
            for (k, entry) in uiPrefs {
                prefsObj[k] = .object([
                    "value": entry.value,
                    "updatedAt": .number(entry.updatedAt),
                ])
            }
            obj["uiPrefs"] = .object(prefsObj)
        }
        if let device {
            obj["device"] = device.toJSONValue()
        }
        return try await request("sync.pushClientState", params: .object(obj), as: SartoSyncStatusInfo.self)
    }

    // MARK: - Strict FIFO Outbound Queue & Dispatch Loop

    private func enqueueOutboundSend(id: Int, payload: Data, buffers: [PortBuffer]) {
        outboundQueue.append(QueuedOutbound(id: id, payload: payload, buffers: buffers))
        guard !isSendingOutbound else { return }
        isSendingOutbound = true
        Task {
            await self.drainOutboundQueue()
        }
    }

    private func drainOutboundQueue() async {
        while !outboundQueue.isEmpty {
            let item = outboundQueue.removeFirst()
            guard !isClosed else {
                failRequest(id: item.id, error: closeError)
                continue
            }
            guard pending[item.id] != nil else {
                continue
            }
            do {
                if item.buffers.isEmpty {
                    try await transport.sendJSON(item.payload)
                } else {
                    try await transport.sendJSON(item.payload, buffers: item.buffers)
                }
            } catch {
                failRequest(id: item.id, error: error)
            }
        }
        isSendingOutbound = false
    }

    private func handleInbound(_ message: PortInboundMessage) {
        let data = message.json
        let type: String
        var id: Int?
        if let sniffed = PortEnvelopeSniffer.header(data) {
            type = sniffed.type
            id = sniffed.id
        } else if let header = try? JSONDecoder().decode(EnvelopeHeader.self, from: data) {
            type = header.type
            id = header.id.flatMap { Int(exactly: $0) }
        } else {
            return
        }
        switch type {
        case "response":
            if id == nil {
                id = (try? JSONDecoder().decode(EnvelopeHeader.self, from: data))?.id.flatMap { Int(exactly: $0) }
            }
            if let id, let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: message)
            }
        case "error":
            if let errEnv = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
               let idNum = errEnv.id.flatMap({ Int(exactly: $0) }),
               let cont = pending.removeValue(forKey: idNum) {
                let code = errEnv.error?.code ?? "internal"
                let message = errEnv.error?.message ?? "Host request failed"
                cont.resume(throwing: PortRPCError(code: code, message: message, data: errEnv.error?.data))
            }
        case "event":
            if let event = HostEvent.decode(fromEnvelopeData: data) {
                eventContinuation.yield(event)
            } else if let fallback = try? JSONDecoder().decode(EventFallbackEnvelope.self, from: data) {
                eventContinuation.yield(HostEvent.decode(from: fallback.event))
            }
        case "resync":
            eventContinuation.yield(.resync)
        case "hosts:open":
            eventContinuation.yield(.hostLinkOpen)
        case "hosts:closed":
            eventContinuation.yield(.hostLinkClosed)
        default:
            break
        }
    }

    private func listenEnded(_ error: Error?) {
        if !isClosed {
            isClosed = true
            if let error {
                closeError = (error as? PortRPCError) ?? HostRPCError.disconnected(error.localizedDescription)
            } else {
                closeError = HostRPCError.disconnected("Connection closed")
            }
        }
        outboundQueue.removeAll()
        failAllPending(with: closeError)
        eventContinuation.finish()
    }

    private func cancelPendingRequest(id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CancellationError())
        }
    }

    private func failRequest(id: Int, error: Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAllPending(with error: Error) {
        let all = pending.values
        pending.removeAll()
        for cont in all {
            cont.resume(throwing: error)
        }
    }
}
