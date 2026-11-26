import Foundation

/// Typed RPC & H.264/HEVC streaming client for Sarto's `device-host` (`src/shared/device-host.ts`).
/// Speaks over a local POSIX `AF_UNIX` device-host socket (matching `SartoTerminalSession`).
public actor SartoDeviceSession {
    private struct QueuedSend {
        let id: Int
        let payload: Data
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

    private struct ResponseEnvelope: Decodable {
        let id: Double?
        let result: JSONValue?
    }

    private struct EventEnvelope: Decodable {
        let event: JSONValue
    }

    private let transport: any SartoPortTransport
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var outboundQueue: [QueuedSend] = []
    private var isSendingOutbound = false
    private var isClosed = false
    private var closeError: Error = HostRPCError.disconnected("Device host disconnected")
    private var listenerTask: Task<Void, Never>?

    private let eventStream: AsyncStream<DeviceEvent>
    private let eventContinuation: AsyncStream<DeviceEvent>.Continuation

    public init(transport: any SartoPortTransport) {
        self.transport = transport
        var cont: AsyncStream<DeviceEvent>.Continuation!
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
            let transport = self.transport
            Task { await transport.close() }
        }
    }

    private func startListening() {
        guard !isClosed, listenerTask == nil else { return }
        let source = PortInboundSource(transport)
        // The loop holds the client only while handling a message, so a client nobody keeps deinits.
        listenerTask = Task.detached { [weak self] in
            do {
                try await source.forEach { message in
                    guard let client = self else { return false }
                    await client.handleInbound((try? message.inlinedJSON()) ?? message.json)
                    return true
                }
                await self?.listenEnded(nil)
            } catch {
                await self?.listenEnded(error)
            }
        }
    }

    public nonisolated var events: AsyncStream<DeviceEvent> {
        eventStream
    }

    public func close() async {
        if !isClosed {
            isClosed = true
            closeError = HostRPCError.disconnected("Device host disconnected")
        }
        listenerTask?.cancel()
        outboundQueue.removeAll()
        await transport.close()
        failAllPending(with: closeError)
        eventContinuation.finish()
    }

    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !isClosed else { throw closeError }
        startListening()

        let id = nextRequestID
        nextRequestID += 1

        let envelope: [String: JSONValue] = [
            "type": .string("request"),
            "id": .number(Double(id)),
            "method": .string(method),
            "params": params,
        ]
        let payload = try JSONEncoder().encode(JSONValue.object(envelope))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if isClosed {
                    continuation.resume(throwing: closeError)
                    return
                }
                pending[id] = continuation
                enqueueOutboundSend(id: id, payload: payload)
            }
        } onCancel: {
            Task { await self.cancelPendingRequest(id: id) }
        }
    }

    // MARK: - Typed DeviceContract Methods

    public func environment() async throws -> DeviceEnvironmentInfo {
        try await request("devices.environment").decode(DeviceEnvironmentInfo.self)
    }

    public func listDevices(sessionId: String? = nil) async throws -> [MobileDeviceInfo] {
        let params: JSONValue = sessionId.map { .object(["sessionId": .string($0)]) } ?? .object([:])
        return try await request("devices.list", params: params).decode([MobileDeviceInfo].self)
    }

    public func openDevice(deviceId: String, sessionId: String) async throws -> MobileDeviceInfo {
        try await request("devices.open", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ])).decode(MobileDeviceInfo.self)
    }

    public func moveDevice(deviceId: String, sessionId: String) async throws -> MobileDeviceInfo {
        try await request("devices.move", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ])).decode(MobileDeviceInfo.self)
    }

    public func closeDevice(deviceId: String, sessionId: String, shutdown: Bool = false) async throws {
        _ = try await request("devices.close", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "shutdown": .bool(shutdown),
        ]))
    }

    public func shutdownDevice(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.shutdown", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func watch(deviceId: String, sessionId: String) async throws -> DeviceScreenInfo? {
        let res = try await request("devices.watch", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let screenVal = res.objectValue?["screen"], screenVal != .null else { return nil }
        return try screenVal.decode(DeviceScreenInfo.self)
    }

    public func unwatch(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.unwatch", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func ack(deviceId: String, sessionId: String, seq: Int) async throws {
        _ = try await request("devices.ack", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "seq": .number(Double(seq)),
        ]))
    }

    public func sendInput(deviceId: String, sessionId: String, input: DeviceInputAction) async throws {
        _ = try await request("devices.input", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "input": input.toJSONValue(),
        ]))
    }

    public func takeOver(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.takeOver", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func handBack(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.handBack", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func screenshot(deviceId: String, sessionId: String) async throws -> Data? {
        let res = try await request("devices.screenshot", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let b64 = res.objectValue?["png"]?.stringValue else { return nil }
        return Data(base64Encoded: b64)
    }

    public func appearance(deviceId: String, sessionId: String) async throws -> DeviceAppearance? {
        let res = try await request("devices.appearance", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let raw = res.objectValue?["appearance"]?.stringValue else { return nil }
        return DeviceAppearance(rawValue: raw)
    }

    public func setAppearance(deviceId: String, sessionId: String, appearance: DeviceAppearance) async throws {
        _ = try await request("devices.setAppearance", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "appearance": .string(appearance.rawValue),
        ]))
    }

    public func frame(deviceId: String, sessionId: String) async throws -> DeviceFrameInfo? {
        let res = try await request("devices.frame", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let frameVal = res.objectValue?["frame"], frameVal != .null else { return nil }
        return try frameVal.decode(DeviceFrameInfo.self)
    }

    // MARK: - Strict FIFO Outbound Transmission

    private func enqueueOutboundSend(id: Int, payload: Data) {
        outboundQueue.append(QueuedSend(id: id, payload: payload))
        guard !isSendingOutbound else { return }
        isSendingOutbound = true
        Task { await self.drainOutboundQueue() }
    }

    private func drainOutboundQueue() async {
        while !outboundQueue.isEmpty {
            let item = outboundQueue.removeFirst()
            guard !isClosed else {
                failRequest(id: item.id, error: closeError)
                continue
            }
            guard pending[item.id] != nil else { continue }
            do {
                try await transport.sendJSON(item.payload)
            } catch {
                failRequest(id: item.id, error: error)
            }
        }
        isSendingOutbound = false
    }

    private func handleInbound(_ data: Data) {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(EnvelopeHeader.self, from: data) else { return }
        switch header.type {
        case "response":
            if let resp = try? decoder.decode(ResponseEnvelope.self, from: data),
               let idNum = resp.id,
               let id = Int.wholePart(of: idNum),
               let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: resp.result ?? .null)
            }
        case "error":
            if let errEnv = try? decoder.decode(ErrorEnvelope.self, from: data),
               let idNum = errEnv.id,
               let id = Int.wholePart(of: idNum),
               let cont = pending.removeValue(forKey: id) {
                let code = errEnv.error?.code ?? "internal"
                let message = errEnv.error?.message ?? "Device request failed"
                cont.resume(throwing: PortRPCError(code: code, message: message, data: errEnv.error?.data))
            }
        case "event":
            if let evt = DeviceEvent.decode(fromEnvelopeData: data) {
                eventContinuation.yield(evt)
            } else if let evtEnv = try? decoder.decode(EventEnvelope.self, from: data) {
                eventContinuation.yield(DeviceEvent.decode(from: evtEnv.event))
            }
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
                closeError = HostRPCError.disconnected("Device host connection closed")
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
        let map = pending
        pending.removeAll()
        for (_, cont) in map { cont.resume(throwing: error) }
    }
}

/// Unified typed bridge so the UI drives `device-host` identically whether attached to a local
/// `SartoDeviceSession` Unix socket or multiplexed over a remote paired `SartoHostSession`.
public enum DeviceSessionBridge: Sendable {
    case local(SartoDeviceSession)
    case remote(SartoHostSession)

    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        switch self {
        case .local(let dev): return try await dev.request(method, params: params)
        case .remote(let host): return try await host.request(method, params: params)
        }
    }

    public func environment() async throws -> DeviceEnvironmentInfo {
        try await request("devices.environment").decode(DeviceEnvironmentInfo.self)
    }

    public func listDevices(sessionId: String? = nil) async throws -> [MobileDeviceInfo] {
        let params: JSONValue = sessionId.map { .object(["sessionId": .string($0)]) } ?? .object([:])
        return try await request("devices.list", params: params).decode([MobileDeviceInfo].self)
    }

    public func openDevice(deviceId: String, sessionId: String) async throws -> MobileDeviceInfo {
        try await request("devices.open", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ])).decode(MobileDeviceInfo.self)
    }

    public func moveDevice(deviceId: String, sessionId: String) async throws -> MobileDeviceInfo {
        try await request("devices.move", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ])).decode(MobileDeviceInfo.self)
    }

    public func closeDevice(deviceId: String, sessionId: String, shutdown: Bool = false) async throws {
        _ = try await request("devices.close", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "shutdown": .bool(shutdown),
        ]))
    }

    public func shutdownDevice(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.shutdown", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func watch(deviceId: String, sessionId: String) async throws -> DeviceScreenInfo? {
        let res = try await request("devices.watch", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let screenVal = res.objectValue?["screen"], screenVal != .null else { return nil }
        return try screenVal.decode(DeviceScreenInfo.self)
    }

    public func unwatch(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.unwatch", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func ack(deviceId: String, sessionId: String, seq: Int) async throws {
        _ = try await request("devices.ack", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "seq": .number(Double(seq)),
        ]))
    }

    public func sendInput(deviceId: String, sessionId: String, input: DeviceInputAction) async throws {
        _ = try await request("devices.input", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "input": input.toJSONValue(),
        ]))
    }

    public func takeOver(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.takeOver", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func handBack(deviceId: String, sessionId: String) async throws {
        _ = try await request("devices.handBack", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
    }

    public func screenshot(deviceId: String, sessionId: String) async throws -> Data? {
        let res = try await request("devices.screenshot", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let b64 = res.objectValue?["png"]?.stringValue else { return nil }
        return Data(base64Encoded: b64)
    }

    public func appearance(deviceId: String, sessionId: String) async throws -> DeviceAppearance? {
        let res = try await request("devices.appearance", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let raw = res.objectValue?["appearance"]?.stringValue else { return nil }
        return DeviceAppearance(rawValue: raw)
    }

    public func setAppearance(deviceId: String, sessionId: String, appearance: DeviceAppearance) async throws {
        _ = try await request("devices.setAppearance", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
            "appearance": .string(appearance.rawValue),
        ]))
    }

    public func frame(deviceId: String, sessionId: String) async throws -> DeviceFrameInfo? {
        let res = try await request("devices.frame", params: .object([
            "deviceId": .string(deviceId),
            "sessionId": .string(sessionId),
        ]))
        guard let frameVal = res.objectValue?["frame"], frameVal != .null else { return nil }
        return try frameVal.decode(DeviceFrameInfo.self)
    }
}
