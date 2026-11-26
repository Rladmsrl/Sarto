import Foundation

/// Typed RPC & PTY streaming client for Sarto's `terminal-host` (`src/shared/terminal-host.ts`).
/// Speaks over either a local POSIX `AF_UNIX` terminal socket or a remote Noise_IK channel.
public actor SartoTerminalSession {
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
    }

    private struct ErrorEnvelope: Decodable {
        let id: Double?
        let error: ErrorBody?
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
    private var closeError: Error = HostRPCError.disconnected("Terminal disconnected")
    private var listenerTask: Task<Void, Never>?

    private let eventStream: AsyncStream<TerminalEvent>
    private let eventContinuation: AsyncStream<TerminalEvent>.Continuation

    public init(transport: any SartoPortTransport) {
        self.transport = transport
        var cont: AsyncStream<TerminalEvent>.Continuation!
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
        // The loop holds the session only while handling a message, so a session nobody keeps deinits.
        listenerTask = Task.detached { [weak self] in
            do {
                try await source.forEach { message in
                    guard let session = self else { return false }
                    await session.handleInbound((try? message.inlinedJSON()) ?? message.json)
                    return true
                }
                await self?.listenEnded(nil)
            } catch {
                await self?.listenEnded(error)
            }
        }
    }

    public nonisolated var events: AsyncStream<TerminalEvent> {
        eventStream
    }

    public func close() async {
        if !isClosed {
            isClosed = true
            closeError = HostRPCError.disconnected("Terminal disconnected")
        }
        listenerTask?.cancel()
        outboundQueue.removeAll()
        await transport.close()
        failAllPending(with: closeError)
        eventContinuation.finish()
    }

    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
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
            Task {
                await self.cancelPendingRequest(id: id)
            }
        }
    }

    public func listTerminals(projectPath: String? = nil) async throws -> [TerminalInfo] {
        let params: JSONValue = projectPath.map { .object(["projectPath": .string($0)]) } ?? .object([:])
        return try await request("terminals.list", params: params).decode([TerminalInfo].self)
    }

    public func createTerminal(
        projectPath: String,
        sessionId: String? = nil,
        cols: Int = 96,
        rows: Int = 26,
        command: String? = nil,
        runCommand: Bool = false
    ) async throws -> TerminalInfo {
        var obj: [String: JSONValue] = [
            "projectPath": .string(projectPath),
            "cols": .number(Double(cols)),
            "rows": .number(Double(rows)),
        ]
        if let sessionId { obj["sessionId"] = .string(sessionId) }
        if let command, !command.isEmpty {
            var cmdObj: [String: JSONValue] = ["text": .string(command)]
            if runCommand { cmdObj["run"] = .bool(true) }
            obj["command"] = .object(cmdObj)
        }
        return try await request("terminals.create", params: .object(obj)).decode(TerminalInfo.self)
    }

    public func attach(id: String) async throws -> String {
        let res = try await request("terminals.attach", params: .object(["id": .string(id)]))
        return res.objectValue?["replay"]?.stringValue ?? ""
    }

    public func sendInput(id: String, data: String) async throws {
        _ = try await request("terminals.input", params: .object([
            "id": .string(id),
            "data": .string(data),
        ]))
    }

    public func resize(id: String, cols: Int, rows: Int) async throws {
        _ = try await request("terminals.resize", params: .object([
            "id": .string(id),
            "cols": .number(Double(cols)),
            "rows": .number(Double(rows)),
        ]))
    }

    public func ack(id: String, chars: Int) async throws {
        _ = try await request("terminals.ack", params: .object([
            "id": .string(id),
            "chars": .number(Double(chars)),
        ]))
    }

    public func kill(id: String) async throws {
        _ = try await request("terminals.kill", params: .object(["id": .string(id)]))
    }

    public func restart(id: String) async throws -> TerminalInfo {
        try await request("terminals.restart", params: .object(["id": .string(id)])).decode(TerminalInfo.self)
    }

    public func assign(projectPath: String, sessionId: String) async throws {
        _ = try await request("terminals.assign", params: .object([
            "projectPath": .string(projectPath),
            "sessionId": .string(sessionId),
        ]))
    }

    public func rename(id: String, name: String) async throws -> TerminalInfo {
        try await request("terminals.rename", params: .object([
            "id": .string(id),
            "name": .string(name),
        ])).decode(TerminalInfo.self)
    }

    public func takeOver(id: String) async throws -> Bool {
        let res = try await request("terminals.takeOver", params: .object(["id": .string(id)]))
        return res.boolValue ?? false
    }

    public func handBack(id: String) async throws -> Bool {
        let res = try await request("terminals.handBack", params: .object(["id": .string(id)]))
        return res.boolValue ?? false
    }

    // MARK: - Strict FIFO Outbound Transmission

    private func enqueueOutboundSend(id: Int, payload: Data) {
        outboundQueue.append(QueuedSend(id: id, payload: payload))
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
                try await transport.sendJSON(item.payload)
            } catch {
                failRequest(id: item.id, error: error)
            }
        }
        isSendingOutbound = false
    }

    private func handleInbound(_ data: Data) {
        let decoder = JSONDecoder()
        guard let type = PortEnvelopeSniffer.header(data)?.type
            ?? (try? decoder.decode(EnvelopeHeader.self, from: data))?.type
        else { return }

        switch type {
        case "response":
            if let resp = (try? JSONValue(jsonData: data))?.objectValue,
               let idNum = resp["id"]?.doubleValue.flatMap({ Int(exactly: $0) }),
               let cont = pending.removeValue(forKey: idNum) {
                cont.resume(returning: resp["result"] ?? .null)
            }
        case "error":
            if let errEnv = try? decoder.decode(ErrorEnvelope.self, from: data),
               let idNum = errEnv.id.flatMap({ Int(exactly: $0) }),
               let cont = pending.removeValue(forKey: idNum) {
                let code = errEnv.error?.code ?? "internal"
                let message = errEnv.error?.message ?? "Terminal request failed"
                cont.resume(throwing: PortRPCError(code: code, message: message))
            }
        case "event":
            if let evt = TerminalEvent.decode(fromEnvelopeData: data) {
                eventContinuation.yield(evt)
            } else if let evtEnv = try? decoder.decode(EventEnvelope.self, from: data) {
                eventContinuation.yield(TerminalEvent.decode(from: evtEnv.event))
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
                closeError = HostRPCError.disconnected("Terminal connection closed")
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
