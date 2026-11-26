import CryptoKit
import Foundation
import Testing
@testable import SartoProtocol
#if os(macOS)
import Darwin
#endif

/// Programmable in-memory WebSocket driver for testing `EncryptedChannelTransport` and `SartoRelayClient`
/// deterministically inside the sandbox without TCP sockets.
private final class MockWebSocketDriver: ChannelWebSocketDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var inboundQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receiverWaiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelCount = 0
    private(set) var isCancelled = false

    var onSend: (@Sendable (URLSessionWebSocketTask.Message, Int) async throws -> Void)?

    func pushInbound(_ message: URLSessionWebSocketTask.Message) {
        var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        lock.lock()
        if !receiverWaiters.isEmpty {
            waiter = receiverWaiters.removeFirst()
        } else {
            inboundQueue.append(.success(message))
        }
        lock.unlock()
        waiter?.resume(returning: message)
    }

    func failInbound(_ error: Error) {
        var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        lock.lock()
        if !receiverWaiters.isEmpty {
            waiter = receiverWaiters.removeFirst()
        } else {
            inboundQueue.append(.failure(error))
        }
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    func snapshotSent() -> [URLSessionWebSocketTask.Message] {
        lock.lock()
        defer { lock.unlock() }
        return sentMessages
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let (index, cancelled, hook) = lock.withLock { () -> (Int, Bool, (@Sendable (URLSessionWebSocketTask.Message, Int) async throws -> Void)?) in
            let wasCancelled = isCancelled
            sentMessages.append(message)
            return (sentMessages.count - 1, wasCancelled, onSend)
        }

        if cancelled {
            throw URLError(.cancelled)
        }
        if let hook {
            try await hook(message, index)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if isCancelled {
                lock.unlock()
                cont.resume(throwing: URLError(.cancelled))
                return
            }
            if !inboundQueue.isEmpty {
                let next = inboundQueue.removeFirst()
                lock.unlock()
                cont.resume(with: next)
                return
            }
            receiverWaiters.append(cont)
            lock.unlock()
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>]
        lock.lock()
        isCancelled = true
        cancelCount += 1
        waiters = receiverWaiters
        receiverWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }
}

private func makeNoiseChannelPair() throws -> (client: SartoChannel, host: SartoChannel) {
    let clientKey = NoiseKeyPair()
    let hostKey = NoiseKeyPair()
    let initHS = try NoiseHandshake(
        pattern: .ik,
        role: .initiator,
        staticKey: clientKey,
        remoteStaticKey: hostKey.publicKeyData
    )
    let respHS = try NoiseHandshake(
        pattern: .ik,
        role: .responder,
        staticKey: hostKey,
        acceptRemoteStatic: { $0 == clientKey.publicKeyData }
    )
    _ = try respHS.readMessage(try initHS.writeMessage())
    _ = try initHS.readMessage(try respHS.writeMessage())
    return (
        SartoChannel(ciphers: try initHS.split()),
        SartoChannel(ciphers: try respHS.split())
    )
}

private func makeWelcomeJSON(protocolVersion: Int = 4, features: [String] = ["bytes", "standby"]) throws -> Data {
    let welcome = WelcomeMessage(
        protocol: protocolVersion,
        host: WelcomeHostInfo(name: "Test Mac", platform: "darwin", version: "0.2.0"),
        features: features,
        role: "owner",
        device: WelcomeDeviceInfo(id: "dev_123456", name: "iPhone"),
        terminal: true,
        addresses: [DirectAddress(host: "127.0.0.1", port: 4123)],
        resume: "tok_abc123"
    )
    return try JSONEncoder().encode(welcome)
}

@Suite("Slice 2 Protocol, Crypto, Framing & Diff Hardening")
struct ProtocolHardeningTests {
    // MARK: - 1. HostRPCClient: Keepalive, Outbox Acks, Nonce Serialization & Streams

    @Test("EncryptedChannelTransport answers bare {type:ping} without id, echoes id when present, and disconnects on keepalive silence")
    func keepalivePingWithoutIdAndSilenceTimeout() async throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()
        let driver = MockWebSocketDriver()

        // Pre-enqueue welcome so EncryptedChannelTransport init completes once hello is sent.
        let welcomeFrames = try hostChan.seal(.json(try makeWelcomeJSON()))
        for f in welcomeFrames { driver.pushInbound(.data(f)) }

        let hello = HelloMessage(client: HelloClientInfo(kind: "ios", version: "0.2.0", platform: "ios"))
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: hello,
            keepaliveInterval: 0.06,
            keepaliveTimeout: 0.06
        )

        // Drain initial hello on hostChannel so hostChannel.open stays in sync.
        for msg in driver.snapshotSent() {
            if case .data(let frame) = msg {
                _ = try hostChan.open(frame: frame)
            }
        }

        // 1) Send Sarto v3+ bare {"type":"ping"} with NO "id" field -> must answer {"type":"pong"}!
        for f in try hostChan.seal(.json(Data("{\"type\":\"ping\"}".utf8))) {
            driver.pushInbound(.data(f))
        }
        #expect(await eventually { driver.snapshotSent().count >= 2 })

        let afterBarePing = driver.snapshotSent()
        #expect(afterBarePing.count == 2)
        if case .data(let pongFrame) = afterBarePing[1],
           case .json(let pongData)? = try hostChan.open(frame: pongFrame) {
            let pongObj = try JSONDecoder().decode([String: JSONValue].self, from: pongData)
            #expect(pongObj["type"] == .string("pong"))
            #expect(pongObj["id"] == nil)
        } else {
            Issue.record("Expected encrypted {\"type\":\"pong\"} response without id")
        }

        // 2) Send {"type":"ping","id":77} -> must answer {"type":"pong","id":77}!
        for f in try hostChan.seal(.json(Data("{\"type\":\"ping\",\"id\":77}".utf8))) {
            driver.pushInbound(.data(f))
        }
        #expect(await eventually { driver.snapshotSent().count >= 3 })

        let afterIdPing = driver.snapshotSent()
        #expect(afterIdPing.count == 3)
        if case .data(let pongFrame2) = afterIdPing[2],
           case .json(let pongData2)? = try hostChan.open(frame: pongFrame2) {
            let pongObj2 = try JSONDecoder().decode([String: JSONValue].self, from: pongData2)
            #expect(pongObj2["type"] == .string("pong"))
            #expect(pongObj2["id"] == .number(77))
        } else {
            Issue.record("Expected encrypted {\"type\":\"pong\",\"id\":77}")
        }

        // Neither ping incremented Outbox receivedCount!
        #expect(await transport.currentReceivedCount == 0)

        // 3) Leave connection idle past keepaliveInterval (60ms) + keepaliveTimeout (60ms) with NO pong:
        // client must emit {"type":"ping"} and then cancel the WebSocket driver cleanly!
        let session = SartoHostSession(transport: transport)
        #expect(await eventually(5) { driver.isCancelled })

        let allSent = driver.snapshotSent()
        #expect(allSent.count >= 4)
        if case .data(let clientPingFrame) = allSent[3],
           case .json(let clientPingData)? = try hostChan.open(frame: clientPingFrame) {
            let pingObj = try JSONDecoder().decode([String: JSONValue].self, from: clientPingData)
            #expect(pingObj == ["type": .string("ping")])
        } else {
            Issue.record("Expected client heartbeat {\"type\":\"ping\"}")
        }

        // Subsequent requests on SartoHostSession fail immediately with HostRPCError.disconnected!
        await #expect(throws: HostRPCError.self) {
            _ = try await session.listProjects()
        }
    }

    @Test("Outbox receivedCount excludes ping/pong/standby/closing, counts addresses and .bytes > 1 MiB, and coalesces acks")
    func outboxReceivedCountAndLargeByteStreamAcks() async throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()
        let driver = MockWebSocketDriver()

        for f in try hostChan.seal(.json(try makeWelcomeJSON())) {
            driver.pushInbound(.data(f))
        }

        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "desktop", version: "0.2.0", platform: "darwin")),
            keepaliveInterval: 60.0,
            keepaliveTimeout: 10.0
        )
        let session = SartoHostSession(transport: transport)

        // Consume client hello on host side.
        for msg in driver.snapshotSent() {
            if case .data(let f) = msg { _ = try hostChan.open(frame: f) }
        }
        var hostProcessedIndex = driver.snapshotSent().count

        func drainHostMessages() throws -> [JSONValue] {
            let snapshot = driver.snapshotSent()
            var out: [JSONValue] = []
            while hostProcessedIndex < snapshot.count {
                defer { hostProcessedIndex += 1 }
                if case .data(let f) = snapshot[hostProcessedIndex],
                   case .json(let data)? = try hostChan.open(frame: f),
                   let val = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    out.append(val)
                }
            }
            return out
        }

        // Send non-Outbox control frames: ping, pong, standby -> receivedCount MUST stay 0!
        for ctrl in [
            "{\"type\":\"ping\"}",
            "{\"type\":\"pong\"}",
            "{\"type\":\"standby\"}",
        ] {
            for f in try hostChan.seal(.json(Data(ctrl.utf8))) {
                driver.pushInbound(.data(f))
            }
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(await transport.currentReceivedCount == 0)

        // Send Outbox control updates ("addresses" & "terminal"): both go through remote-host Outbox (server.ts:1312,1318) -> received == 2!
        for outboxCtrl in [
            "{\"type\":\"addresses\",\"addresses\":[{\"host\":\"10.0.0.2\",\"port\":4123}]}",
            "{\"type\":\"terminal\",\"allowed\":true}",
        ] {
            for f in try hostChan.seal(.json(Data(outboxCtrl.utf8))) {
                driver.pushInbound(.data(f))
            }
        }
        #expect(await eventually { await transport.currentReceivedCount == 2 })
        var earlyAcks: [JSONValue] = []
        #expect(await eventually {
            earlyAcks += ((try? drainHostMessages()) ?? []).filter { $0.objectValue?["type"]?.stringValue == "ack" }
            return earlyAcks.last?.objectValue?["received"]?.doubleValue == 2
        })

        // Now perform a 1.2 MiB (> 1 MiB IN_FLIGHT_BYTES) sessions.blob stream download!
        let largeBlob = Data((0..<(1_200_000)).map { UInt8(($0 * 31) & 0xff) })
        let blobTask = Task {
            try await session.readSessionBlob(sessionId: "s-1", hash: "deadbeef")
        }
        var clientRequests: [JSONValue] = []
        #expect(await eventually {
            clientRequests += ((try? drainHostMessages()) ?? []).filter { $0.objectValue?["type"]?.stringValue == "request" }
            return !clientRequests.isEmpty
        })
        let reqID = Int(try #require(clientRequests.first?.objectValue?["id"]?.doubleValue))

        // Host sends response with $stream: 2 (Outbox message #2), then 20 chunks of 60 KiB (.bytes #3..#22), then stream.end (#23).
        let streamResp = """
        {"type":"response","id":\(reqID),"result":{"mimeType":"image/png","bytes":{"$stream":2,"size":\(largeBlob.count)}}}
        """
        for f in try hostChan.seal(.json(Data(streamResp.utf8))) {
            driver.pushInbound(.data(f))
        }
        let chunkLen = 60_000
        var offset = 0
        while offset < largeBlob.count {
            let end = min(offset + chunkLen, largeBlob.count)
            let chunk = Data(largeBlob[offset..<end])
            for f in try hostChan.seal(.bytes(stream: 2, data: chunk)) {
                driver.pushInbound(.data(f))
            }
            offset = end
        }
        for f in try hostChan.seal(.json(Data("{\"type\":\"stream.end\",\"stream\":2}".utf8))) {
            driver.pushInbound(.data(f))
        }

        let resolvedBlob = try await blobTask.value
        #expect(resolvedBlob.mimeType == "image/png")
        #expect(resolvedBlob.data == largeBlob)

        // 2 ("addresses" + "terminal") + 1 (response) + 20 (.bytes chunks) + 1 ("stream.end") = 24 Outbox messages!
        #expect(await eventually { await transport.currentReceivedCount == 24 })
        var streamAcks: [JSONValue] = []
        #expect(await eventually {
            streamAcks += ((try? drainHostMessages()) ?? []).filter { $0.objectValue?["type"]?.stringValue == "ack" }
            return streamAcks.last?.objectValue?["received"]?.doubleValue == 24
        })
        #expect(streamAcks.count >= 4) // Immediate 256 KiB byte-threshold acks fired during download!
        #expect(streamAcks.last?.objectValue?["received"]?.doubleValue == 24)

        // Finally send closing(reason: "stopping") -> surfaces reason via HostRPCError.disconnected and cancels task!
        let waiter = Task {
            try await session.listProjects()
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        for f in try hostChan.seal(.json(Data("{\"type\":\"closing\",\"reason\":\"stopping\"}".utf8))) {
            driver.pushInbound(.data(f))
        }

        do {
            _ = try await waiter.value
            Issue.record("Expected closing message to fail pending request")
        } catch let err as PortRPCError {
            #expect(err.code == "host_offline")
            #expect(err.message == "stopping")
            #expect(err == HostRPCError.disconnected("stopping"))
        }
        #expect(driver.isCancelled == true)
        #expect(await transport.closeReason == "stopping")
    }

    @Test("Concurrent EncryptedChannelTransport sends serialize nonces strictly in FIFO order across multi-frame messages")
    func strictOutboundNonceSerializationUnderConcurrency() async throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()
        let driver = MockWebSocketDriver()

        for f in try hostChan.seal(.json(try makeWelcomeJSON())) {
            driver.pushInbound(.data(f))
        }

        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "desktop", version: "0.2.0", platform: "darwin")),
            keepaliveInterval: 60.0,
            keepaliveTimeout: 10.0
        )

        // Inject staggered suspension delays inside WebSocket send() so reentrant tasks would scramble
        // nonces if seal() + send() were not serialized.
        driver.onSend = { _, idx in
            let delayNs = UInt64(((idx % 5) + 1) * 1_000_000)
            try await Task.sleep(nanoseconds: delayNs)
        }

        // Launch 12 concurrent multi-frame JSON + binary upload sends (~140 KiB each -> 3 Noise frames per message).
        let bigChunk = Data((0..<140_000).map { UInt8(($0 * 17) & 0xff) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<12 {
                group.addTask {
                    if i % 2 == 0 {
                        let req = JSONValue.object([
                            "type": .string("request"),
                            "id": .number(Double(100 + i)),
                            "method": .string("attachments.add"),
                            "params": .object(["blob": .null]),
                        ])
                        let data = try JSONEncoder().encode(req)
                        try await transport.sendJSON(
                            data,
                            buffers: [PortBuffer(path: ["params", "blob"], data: bigChunk)]
                        )
                    } else {
                        // Incompressible multi-frame JSON message (>65 KiB)
                        let b64 = bigChunk.base64EncodedString()
                        let msg = Data("{\"type\":\"request\",\"id\":\(100 + i),\"payload\":\"\(b64)\"}".utf8)
                        try await transport.sendJSON(msg)
                    }
                }
            }
            try await group.waitForAll()
        }

        // Every single frame recorded on the wire MUST decrypt cleanly in exact arrival order!
        var decryptedJSONCount = 0
        var decryptedBytesCount = 0
        for wsMsg in driver.snapshotSent() {
            guard case .data(let frame) = wsMsg else { continue }
            if let opened = try hostChan.open(frame: frame) {
                switch opened {
                case .json: decryptedJSONCount += 1
                case .bytes: decryptedBytesCount += 1
                }
            }
        }
        // 1 hello + 6*(stream.open + stream.end + request) + 6*(large JSON request) = 25 JSON messages, 6*3 = 18 byte chunks.
        #expect(decryptedJSONCount == 25)
        #expect(decryptedBytesCount >= 12)
        await transport.close()
    }

    @Test("Oversized >32 MiB StreamRef is rejected before allocation and sibling downloads are cleaned on cancel")
    func oversizedStreamRejectedAndSiblingCancelCleanup() async throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()
        let driver = MockWebSocketDriver()
        for f in try hostChan.seal(.json(try makeWelcomeJSON())) {
            driver.pushInbound(.data(f))
        }
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "ios", version: "0.2.0", platform: "ios")),
            keepaliveInterval: 60.0,
            keepaliveTimeout: 10.0
        )
        let session = SartoHostSession(transport: transport)

        // 1) Oversized > 32 MiB StreamRef
        let oversizedTask = Task {
            try await session.readSessionBlob(sessionId: "s-1", hash: "huge")
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let tooBigBytes = SartoChannel.maxMessageBytes + 1024
        let resp1 = """
        {"type":"response","id":1,"result":{"mimeType":"image/png","bytes":{"$stream":2,"size":\(tooBigBytes)}}}
        """
        for f in try hostChan.seal(.json(Data(resp1.utf8))) {
            driver.pushInbound(.data(f))
        }
        await #expect(throws: PortRPCError.self) {
            _ = try await oversizedTask.value
        }

        // 2) Multi-stream response where stream 4 cancels -> cleans up sibling stream 6 and fails RPC!
        let multiTask = Task {
            try await session.request("custom.twoBlobs", params: .null)
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let resp2 = """
        {"type":"response","id":2,"result":{"a":{"$stream":4,"size":100},"b":{"$stream":6,"size":100}}}
        """
        for f in try hostChan.seal(.json(Data(resp2.utf8))) {
            driver.pushInbound(.data(f))
        }
        for f in try hostChan.seal(.json(Data("{\"type\":\"stream.cancel\",\"stream\":4}".utf8))) {
            driver.pushInbound(.data(f))
        }
        await #expect(throws: PortRPCError.self) {
            _ = try await multiTask.value
        }

        // 3) Task cancellation on in-flight request resumes immediately with CancellationError!
        let cancellableTask = Task {
            try await session.request("sessions.list", params: .object([:]))
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        cancellableTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancellableTask.value
        }

        await session.close()
    }

    @Test("A response's streams share one 32 MiB budget, and a response that repeats a stream id fails")
    func responseStreamsShareBudgetAndRejectRepeatedIDs() async throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()
        let driver = MockWebSocketDriver()
        for f in try hostChan.seal(.json(try makeWelcomeJSON())) {
            driver.pushInbound(.data(f))
        }
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "ios", version: "0.2.0", platform: "ios")),
            keepaliveInterval: 60.0,
            keepaliveTimeout: 10.0
        )
        let session = SartoHostSession(transport: transport)

        // Each stream fits the message limit on its own; together they exceed it.
        let overBudget = Task {
            try await session.request("custom.twoBlobs", params: .null)
        }
        let overBudgetWatchdog = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            overBudget.cancel()
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let part = SartoChannel.maxMessageBytes / 2 + 1
        let resp1 = """
        {"type":"response","id":1,"result":{"a":{"$stream":2,"size":\(part)},"b":{"$stream":4,"size":\(part)}}}
        """
        for f in try hostChan.seal(.json(Data(resp1.utf8))) {
            driver.pushInbound(.data(f))
        }
        await #expect(throws: PortRPCError.self) {
            _ = try await overBudget.value
        }
        overBudgetWatchdog.cancel()

        // The same stream id twice would otherwise leave the request waiting for a second end forever.
        let repeated = Task {
            try await session.request("custom.twoBlobs", params: .null)
        }
        let repeatedWatchdog = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            repeated.cancel()
        }
        try await Task.sleep(nanoseconds: 15_000_000)
        let resp2 = """
        {"type":"response","id":2,"result":{"a":{"$stream":6,"size":3},"b":{"$stream":6,"size":3}}}
        """
        for f in try hostChan.seal(.json(Data(resp2.utf8))) {
            driver.pushInbound(.data(f))
        }
        for f in try hostChan.seal(.bytes(stream: 6, data: Data("abc".utf8))) {
            driver.pushInbound(.data(f))
        }
        for f in try hostChan.seal(.json(Data("{\"type\":\"stream.end\",\"stream\":6}".utf8))) {
            driver.pushInbound(.data(f))
        }
        await #expect(throws: PortRPCError.self) {
            _ = try await repeated.value
        }
        repeatedWatchdog.cancel()

        await session.close()
    }

    @Test("usageSummary rounds fractional timestamps and emits exact JSON safe integers without float/scientific notation")
    func usageSummaryIntegerTimestampsAndFIFO() async throws {
        actor CaptureTransport: SartoPortTransport {
            private let stream: AsyncThrowingStream<Data, Error>
            private let cont: AsyncThrowingStream<Data, Error>.Continuation
            private(set) var rawPayloads: [String] = []

            init() {
                var c: AsyncThrowingStream<Data, Error>.Continuation!
                self.stream = AsyncThrowingStream { c = $0 }
                self.cont = c
            }

            nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

            func sendJSON(_ data: Data) async throws {
                let raw = String(decoding: data, as: UTF8.self)
                rawPayloads.append(raw)
                let obj = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
                let id = Int(obj["id"]!.doubleValue!)
                cont.yield(Data("{\"type\":\"response\",\"id\":\(id),\"result\":{\"days\":[]}}".utf8))
            }

            func close() async { cont.finish() }
        }

        let capture = CaptureTransport()
        let session = SartoHostSession(transport: capture)
        _ = try await session.usageSummary(
            dayStarts: [1_795_274_235_123.7, 1_795_360_635_123.2],
            from: 1_795_274_235_123.7,
            to: 1_795_360_635_123.2
        )
        let payloads = await capture.rawPayloads
        #expect(payloads.count == 1)
        let sentJSON = payloads[0]
        #expect(sentJSON.contains("1795274235124"))
        #expect(sentJSON.contains("1795360635123"))
        #expect(!sentJSON.contains(".7"))
        #expect(!sentJSON.contains("e+"))
        #expect(!sentJSON.contains("E+"))
        await session.close()
    }

    // MARK: - 2. ChannelFraming: Incompressible Payload & Truncated Deflate Termination

    @Test("SartoChannel emits uncompressed JSON when deflate would expand payload and terminates on truncated deflate")
    func channelFramingIncompressibleAndTruncatedDeflate() throws {
        let (clientChan, hostChan) = try makeNoiseChannelPair()

        // 1) Full 8-bit uniform high-entropy payload > compressThreshold (1024 bytes):
        // 8 bits/byte cannot shrink under RFC 1951 deflate, so seal() MUST fall back to uncompressed jsonKind!
        var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15
        var incompressiblePayload = Data(capacity: 4096)
        for _ in 0..<4096 {
            rngState ^= rngState << 13
            rngState ^= rngState >> 7
            rngState ^= rngState << 17
            incompressiblePayload.append(UInt8(truncatingIfNeeded: rngState))
        }
        #expect(incompressiblePayload.count > SartoChannel.compressThreshold)
        #expect(SartoChannel.deflateRaw(incompressiblePayload) == nil)

        let frames = try clientChan.seal(.json(incompressiblePayload))
        #expect(frames.count == 1)
        #expect(try hostChan.open(frame: frames[0]) == .json(incompressiblePayload))

        // 2) Truncated raw deflate stream MUST return nil immediately instead of spinning forever!
        let compressible = Data(repeating: UInt8(ascii: "A"), count: 16_384)
        let validDeflated = try #require(SartoChannel.deflateRaw(compressible))
        #expect(validDeflated.count < compressible.count)

        // Strip final bytes so BFINAL / end-of-block marker is missing.
        for cut in [1, 2, 4, validDeflated.count / 2] where validDeflated.count > cut {
            let truncated = validDeflated.prefix(validDeflated.count - cut)
            let result = SartoChannel.inflateRaw(truncated, limit: SartoChannel.maxMessageBytes)
            #expect(result == nil)
        }
        // Empty slice returns empty Data cleanly.
        #expect(SartoChannel.inflateRaw(Data()[0..<0], limit: 1024) == Data())
    }

    // MARK: - 3. DeviceIdentityStore: Non-Destructive Load, Backup, Permissions & Ed25519 Key

    @Test("DeviceIdentityStore preserves existing identity on corrupt read, recovers from .bak, and decodes hostEd25519PublicKey")
    func deviceIdentityStoreSafetyAndEd25519Key() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pk-id-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("device-identity.json")
        let bakURL = fileURL.appendingPathExtension("bak")

        let store = DeviceIdentityStore(fileURL: fileURL)
        #expect(DeviceIdentityStore.defaultAppGroupIdentifier == "group.dev.sarto.shared")

        // 1) Missing file -> loadExistingIdentity returns nil!
        #expect(try store.loadExistingIdentity() == nil)

        // 2) First loadOrCreateIdentity creates file with 0o600 permissions (and sets isExcludedFromBackup when OS permits).
        let initial = store.loadOrCreateIdentity()
        let resolvedFileURL = fileURL.resolvingSymlinksInPath()
        #expect(FileManager.default.fileExists(atPath: resolvedFileURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: resolvedFileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
        // Verify isExcludedFromBackup whenever the current directory/sandbox permits setting CSBackup xattrs.
        var probeURL = dir.resolvingSymlinksInPath().appendingPathComponent("probe.txt")
        try Data("x".utf8).write(to: probeURL)
        var probeVals = URLResourceValues()
        probeVals.isExcludedFromBackup = true
        if (try? probeURL.setResourceValues(probeVals)) != nil,
           (try? probeURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true {
            let resVals = try resolvedFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(resVals.isExcludedFromBackup == true)
        }

        // 3) Save paired host & update Ed25519 key (creates .bak of previous valid state).
        let edPriv = Curve25519.Signing.PrivateKey()
        let edPubBytes = edPriv.publicKey.rawRepresentation
        let edHex = BaseEncoding.hexEncode(edPubBytes)
        let edB64URL = BaseEncoding.base64URLEncode(edPubBytes)
        let edB64 = edPubBytes.base64EncodedString()

        let recHex = PairedHostRecord(id: "h-1", name: "Studio Mac", hostPublicKey: edB64URL, hostEd25519PublicKey: edHex)
        let recB64U = PairedHostRecord(id: "h-2", name: "Mini", hostPublicKey: edB64URL, hostEd25519PublicKey: edB64URL)
        let recB64 = PairedHostRecord(id: "h-3", name: "Linux", hostPublicKey: edB64URL, hostEd25519PublicKey: edB64)
        #expect(recHex.hostEd25519PublicKeyData == edPubBytes)
        #expect(recB64U.hostEd25519PublicKeyData == edPubBytes)
        #expect(recB64.hostEd25519PublicKeyData == edPubBytes)

        let savedHost = PairedHostRecord(id: "host-main", name: "MacBook Pro", hostPublicKey: edB64URL)
        store.save(keyPair: initial.keyPair, hosts: [savedHost])
        store.updateHostEd25519PublicKey(hostId: "host-main", ed25519PublicKey: edHex)

        let reloaded = try #require(try store.loadExistingIdentity())
        #expect(reloaded.keyPair.publicKeyData == initial.keyPair.publicKeyData)
        #expect(reloaded.hosts.count == 1)
        #expect(reloaded.hosts[0].hostEd25519PublicKeyData == edPubBytes)
        #expect(FileManager.default.fileExists(atPath: bakURL.path))

        // 4) Corrupt primary file on disk: loadExistingIdentity MUST throw, and loadOrCreateIdentity
        // MUST NOT overwrite fileURL with hosts: [] (recovers from .bak and leaves fileURL untouched!).
        let corruptBytes = Data("{corrupt-json".utf8)
        try corruptBytes.write(to: fileURL)
        #expect(throws: (any Error).self) {
            _ = try store.loadExistingIdentity()
        }
        let recovered = store.loadOrCreateIdentity()
        #expect(recovered.keyPair.publicKeyData == initial.keyPair.publicKeyData)
        #expect(recovered.hosts.count == 1)
        // Verify primary file was NOT clobbered on disk!
        #expect(try Data(contentsOf: fileURL) == corruptBytes)

        // Remove .bak too: loadOrCreateIdentity returns ephemeral key WITHOUT overwriting fileURL!
        try FileManager.default.removeItem(at: bakURL)
        _ = store.loadOrCreateIdentity()
        #expect(try Data(contentsOf: fileURL) == corruptBytes)
    }

    // MARK: - 4. UnixSocketPort, PairingCode IPv6, Relay & TerminalRPCClient

    @Test("PairingCode encodes/decodes IPv6 [::1] relay origins and browser /pair links")
    func pairingCodeIPv6CanonicalOrigin() throws {
        let hostKey = Data((0..<32).map { UInt8($0 + 1) })
        let secret = Data((0..<32).map { UInt8(200 - $0) })
        let payload = PairingPayload(
            version: 2,
            hostKey: hostKey,
            secret: secret,
            addresses: [DirectAddress(host: "::1", port: 4567)],
            relay: PairingRelay(
                id: "aeiscmkbkfqxdamrugy4dupb6e",
                urls: ["http://[::1]:8787", "https://[2001:db8::1]:9443"]
            )
        )

        let code = try PairingCode.encode(payload)
        let decoded = try #require(PairingCode.decode(code))
        #expect(decoded == payload)
    }

    @Test("HostProtocol, RelayInfo, RelayClient control frames/timeouts, and TerminalRPCClient FIFO & close")
    func protocolDefaultsRelayControlAndTerminalFIFO() async throws {
        // 1) HelloMessage omits "tool-digests" by default; WelcomeMessage decodes relay & resumed
        let hello = HelloMessage(client: HelloClientInfo(kind: "ios", version: "0.2.0", platform: "ios"))
        #expect(hello.features == ["image-refs"])
        #expect(hello.features?.contains("tool-digests") == false)

        let welcomeObjJSON = """
        {
          "type": "welcome",
          "protocol": 4,
          "host": { "name": "Dev", "platform": "darwin", "version": "0.2.0" },
          "features": ["bytes"],
          "role": "owner",
          "device": { "id": "dev_1", "name": "iPad" },
          "terminal": true,
          "addresses": [],
          "relay": { "id": "aeiscmkbkfqxdamrugy4dupb6e", "urls": ["https://relay.sarto.dev"] },
          "resumed": { "request": 12 }
        }
        """
        let welcome = try JSONDecoder().decode(WelcomeMessage.self, from: Data(welcomeObjJSON.utf8))
        #expect(welcome.resumed == true)
        #expect(welcome.resumedRequest == 12)
        #expect(welcome.relay?.objectValue?["id"]?.stringValue == "aeiscmkbkfqxdamrugy4dupb6e")

        let welcomeBoolJSON = welcomeObjJSON.replacingOccurrences(of: "{ \"request\": 12 }", with: "true")
        let welcomeBool = try JSONDecoder().decode(WelcomeMessage.self, from: Data(welcomeBoolJSON.utf8))
        #expect(welcomeBool.resumed == true)

        // 2) RelayInfo decodes missing features as []
        let relayJSON = #"{"relay":"sarto","protocol":1,"regions":[]}"#
        let relayInfo = try JSONDecoder().decode(RelayInfo.self, from: Data(relayJSON.utf8))
        #expect(relayInfo.features == [])

        // 3) SartoRelayClient HTTP status validation, pre-join ping->pong, drain error, and timeout
        let badResp = HTTPURLResponse(url: URL(string: "https://relay.sarto.dev/v1")!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        #expect(throws: RelayClientError.httpStatus(503)) {
            try SartoRelayClient.validateHTTPResponse(badResp)
        }

        // Pre-join ping -> pong -> paired -> Noise_IK handshake
        let clientKey = NoiseKeyPair()
        let hostKey = NoiseKeyPair()
        let relayDriver = MockWebSocketDriver()
        final class HandshakeBox: @unchecked Sendable {
            let hs: NoiseHandshake
            init(_ hs: NoiseHandshake) { self.hs = hs }
        }
        let hsBox = HandshakeBox(try NoiseHandshake(
            pattern: .ik,
            role: .responder,
            staticKey: hostKey,
            acceptRemoteStatic: { $0 == clientKey.publicKeyData }
        ))
        relayDriver.onSend = { [weak relayDriver] msg, idx in
            guard let relayDriver else { return }
            if idx == 0 {
                // After client sends "connect", relay sends text "ping", benign notice, then {"type":"paired"}
                relayDriver.pushInbound(.string("ping"))
                relayDriver.pushInbound(.string("{\"type\":\"info\"}"))
                relayDriver.pushInbound(.string("{\"type\":\"paired\"}"))
            } else if case .data(let msg1) = msg {
                _ = try hsBox.hs.readMessage(msg1)
                let msg2 = try hsBox.hs.writeMessage()
                relayDriver.pushInbound(.data(msg2))
            }
        }
        let established = try await SartoRelayClient.connectViaRelayDriver(
            driver: relayDriver,
            relayToken: "tok_test",
            localStaticKey: clientKey,
            hostStaticPublicKey: hostKey.publicKeyData,
            psk: nil,
            timeout: 2.0
        )
        let hostChannel = SartoChannel(ciphers: try hsBox.hs.split())
        let testFrame = try established.seal(.json(Data("{\"ok\":true}".utf8)))[0]
        #expect(try hostChannel.open(frame: testFrame) == .json(Data("{\"ok\":true}".utf8)))
        #expect(relayDriver.snapshotSent().contains {
            if case .string(let s) = $0 { return s == "pong" }
            return false
        })

        // Drain before join throws .relayDraining and cancels driver
        let drainDriver = MockWebSocketDriver()
        drainDriver.pushInbound(.string("{\"type\":\"drain\"}"))
        await #expect(throws: RelayClientError.relayDraining) {
            _ = try await SartoRelayClient.connectViaRelayDriver(
                driver: drainDriver,
                relayToken: "tok",
                localStaticKey: clientKey,
                hostStaticPublicKey: hostKey.publicKeyData,
                psk: nil,
                timeout: 1.0
            )
        }
        #expect(drainDriver.isCancelled == true)

        // Hung socket times out cleanly and cancels driver
        let hungDriver = MockWebSocketDriver()
        await #expect(throws: RelayClientError.timedOut) {
            _ = try await SartoRelayClient.connectDirectDriver(
                driver: hungDriver,
                localStaticKey: clientKey,
                hostStaticPublicKey: hostKey.publicKeyData,
                psk: nil,
                timeout: 0.05
            )
        }
        #expect(hungDriver.isCancelled == true)

        // 4) SartoTerminalSession sends rapid input/resize/ack in strict FIFO order and tracks isClosed
        actor OrderedTermTransport: SartoPortTransport {
            private let stream: AsyncThrowingStream<Data, Error>
            private let cont: AsyncThrowingStream<Data, Error>.Continuation
            private(set) var receivedIDs: [Int] = []

            init() {
                var c: AsyncThrowingStream<Data, Error>.Continuation!
                self.stream = AsyncThrowingStream { c = $0 }
                self.cont = c
            }

            nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

            func sendJSON(_ data: Data) async throws {
                try await Task.sleep(nanoseconds: 2_000_000)
                let obj = try JSONDecoder().decode(JSONValue.self, from: data).objectValue!
                let id = Int(obj["id"]!.doubleValue!)
                receivedIDs.append(id)
                cont.yield(Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8))
            }

            func close() async { cont.finish() }
        }

        let termTransport = OrderedTermTransport()
        let term = SartoTerminalSession(transport: termTransport)
        var tasks: [Task<Void, Error>] = []
        for idx in 1...12 {
            let str = "\(idx)"
            tasks.append(Task {
                try await term.sendInput(id: "t-1", data: str)
            })
            try await Task.sleep(nanoseconds: 200_000)
        }
        for t in tasks { try await t.value }
        let ids = await termTransport.receivedIDs
        #expect(ids == Array(1...12))

        await term.close()
        await #expect(throws: HostRPCError.self) {
            try await term.ack(id: "t-1", chars: 10)
        }
    }

    #if os(macOS)
    @Test("UnixSocketPortTransport rejects malformed WITH_BUFFERS frames, trims SARTO_DAEMON_DATA, and closes cleanly")
    func unixSocketMalformedFrameAndDaemonEnv() async throws {
        #expect(UnixSocketPortTransport.maxMessageBytes == 256 * 1024 * 1024)
        #expect(
            SartoDaemonPaths.defaultDataDirectory(environment: ["SARTO_DAEMON_DATA": "  /tmp/custom-sarto \n"])
                == "/tmp/custom-sarto"
        )

        // Malformed WITH_BUFFERS payloads must return nil
        #expect(UnixSocketPortTransport.decodeWithBuffers(Data([0, 0])) == nil)
        #expect(UnixSocketPortTransport.decodeWithBuffers(Data([0, 0, 0, 99, 0x5B])) == nil)

        // Truncated buffer payload inside WITH_BUFFERS socket stream fails incoming stream with .malformedFrame!
        var pair: [Int32] = [-1, -1]
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        var noSigPipe: Int32 = 1
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let serverSideFD = pair[1]

        DispatchQueue.global().async {
            defer { Darwin.close(serverSideFD) }

            // Send WITH_BUFFERS header claiming 10-byte body whose inner jsonLen is 50 (truncated/malformed!)
            var frame = Data()
            var hdr = (UInt32(0x8000_0000) | UInt32(10)).bigEndian
            withUnsafeBytes(of: &hdr) { frame.append(contentsOf: $0) }
            var badJsonLen = UInt32(50).bigEndian
            withUnsafeBytes(of: &badJsonLen) { frame.append(contentsOf: $0) }
            frame.append(contentsOf: [1, 2, 3, 4, 5, 6])
            frame.withUnsafeBytes { raw in
                _ = Darwin.write(serverSideFD, raw.baseAddress!, frame.count)
            }
        }

        let transport = UnixSocketPortTransport(connectedFD: pair[0])
        var caughtMalformed = false
        do {
            for try await _ in transport.messages {}
        } catch let err as UnixSocketError {
            caughtMalformed = (err == .malformedFrame)
        }
        #expect(caughtMalformed == true)
        await transport.close()
    }
    #endif

    // MARK: - 5. ThreadReplica, UnifiedDiffEngine (CRLF + Myers O(ND)), ANSITerminalParser & LiveTelemetry

    @Test("ThreadReplica handles compaction updates, toolKind/question/ref/digest, agent attachments, unknown ops, stable PlanItem.id & reset")
    func threadReplicaComprehensiveFixes() throws {
        let initialPlan = ThreadEntry.plan(id: "plan-0", items: [
            PlanItem(content: "Audit framing", priority: "high", status: "pending"),
            PlanItem(content: "Write tests", priority: "medium", status: "pending"),
        ])
        let linkRef = ContentRef.link(uri: "https://sarto.1o.ink", name: "Sarto")
        let snapshot = SessionSnapshot(
            session: SessionView(id: "s-hard", agentId: "claude-code", projectPath: "/repo", status: .running),
            entries: [
                .agent(id: "a-1", markdown: "Hello", streaming: true, at: 1000, attachments: [linkRef]),
                .compaction(id: "c-1", status: "in_progress", summary: "Summarizing..."),
                .tool(ToolEntryData(
                    id: "t-1",
                    title: "Run",
                    toolKind: "other",
                    status: "in_progress",
                    content: [
                        .ref(.terminal(terminalId: "term-9", name: "zsh")),
                        .digest(of: "diff", path: "a.swift", lines: nil, size: 12000, added: 42, removed: 11),
                    ],
                    rawInputDigest: "50 lines (2400 bytes)",
                    rawInputDigestInfo: ToolInputDigestInfo(size: 2400, lines: 50)
                )),
                initialPlan,
            ],
            seq: 1,
            plan: initialPlan
        )

        var replica = ThreadReplica(snapshot: snapshot)
        #expect(replica.snapshotPlan?.map(\.id) == ["0-Audit framing", "1-Write tests"])
        #expect(replica.byId["a-1"]?.agentAttachments == [linkRef])

        // Verify JSON round-trip preserves agent attachments, ToolContentItem.ref, digest added/removed, and rawInputDigest!
        let encodedEntries = try JSONEncoder().encode(replica.entries)
        let decodedEntries = try JSONDecoder().decode([ThreadEntry].self, from: encodedEntries)
        #expect(decodedEntries == replica.entries)

        // Apply batch containing an unknown upstream op + compaction update + toolKind/question update + plan status transition + agent appendText!
        let batchJSON = """
        {
          "sessionId": "s-hard",
          "seq": 2,
          "patches": [
            { "op": "future.experimentalOp", "payload": { "x": 1 } },
            { "op": "entry.appendText", "id": "a-1", "text": " world!" },
            { "op": "entry.update", "id": "a-1", "changes": { "streaming": false } },
            { "op": "entry.update", "id": "c-1", "changes": { "status": "completed", "summary": "Folded 14 turns." } },
            { "op": "entry.update", "id": "t-1", "changes": { "toolKind": "execute", "question": "Proceed with deploy?" } },
            {
              "op": "entry.update",
              "id": "plan-0",
              "changes": {
                "items": [
                  { "content": "Audit framing", "priority": "high", "status": "completed" },
                  { "content": "Write tests", "priority": "medium", "status": "in_progress" }
                ]
              }
            }
          ]
        }
        """
        let batch = try JSONDecoder().decode(PatchBatch.self, from: Data(batchJSON.utf8))
        #expect(batch.patches.first == .unknown("future.experimentalOp"))
        #expect(replica.apply(batch) == true)

        // Agent entry kept its attachments across appendText + entryUpdate!
        if case .agent(_, let md, let streaming, _, let atts) = replica.byId["a-1"] {
            #expect(md == "Hello world!")
            #expect(streaming == false)
            #expect(atts == [linkRef])
        } else {
            Issue.record("Expected updated agent entry")
        }

        // Compaction updated status & summary!
        #expect(replica.byId["c-1"] == .compaction(id: "c-1", status: "completed", summary: "Folded 14 turns."))

        // Tool updated toolKind & question!
        if case .tool(let tData) = replica.byId["t-1"] {
            #expect(tData.toolKind == "execute")
            #expect(tData.question == "Proceed with deploy?")
        } else {
            Issue.record("Expected updated tool entry")
        }

        // PlanItem.id stayed identical across status transitions!
        if case .plan(_, let updatedItems) = replica.byId["plan-0"] {
            #expect(updatedItems.map(\.id) == ["0-Audit framing", "1-Write tests"])
            #expect(updatedItems[0].status == "completed")
            #expect(updatedItems[1].status == "in_progress")
        } else {
            Issue.record("Expected updated plan entry")
        }

        // thread.reset clears snapshotPlan = nil!
        #expect(replica.apply(PatchBatch(sessionId: "s-hard", seq: 3, patches: [.threadReset])) == true)
        #expect(replica.snapshotPlan == nil)
        #expect(replica.entries.isEmpty)
    }

    @Test("UnifiedDiffEngine splits CRLF cleanly and runs Myers O(ND) on 4,000-line files without materializing untouched regions")
    func unifiedDiffCRLFAndLargeMyers() {
        // 1) CRLF file: Swift's Character("\r\n") != Character("\n") previously collapsed all lines into 1!
        let oldCRLF = "alpha\r\nbeta\r\ngamma\r\ndelta\r\n"
        let newCRLF = "alpha\r\nbeta-updated\r\ngamma\r\ndelta\r\n"
        let crlfDiff = UnifiedDiffEngine.compute(oldText: oldCRLF, newText: newCRLF, contextLines: 1)
        #expect(crlfDiff.insertions == 1)
        #expect(crlfDiff.deletions == 1)
        #expect(crlfDiff.hunks.count == 1)
        #expect(crlfDiff.hunks[0].lines.map(\.text) == ["alpha", "beta", "beta-updated", "gamma"])

        // 2) 4,000-line file (4,000 * 4,000 = 16,000,000 >> old 1.2M DP limit!) with 2 edits at lines 10 and 3,990:
        // Myers O(ND) must produce 2 compact hunks with exact +2/-2 counts instead of a 4,000-line replace block!
        let oldLines = (1...4000).map { "let value_\($0) = \($0)" }
        var newLines = oldLines
        newLines[9] = "let value_10 = 10_000"
        newLines[3989] = "let value_3990 = 39_900"

        let largeDiff = UnifiedDiffEngine.compute(
            oldText: oldLines.joined(separator: "\n") + "\n",
            newText: newLines.joined(separator: "\n") + "\n",
            contextLines: 2
        )
        #expect(largeDiff.insertions == 2)
        #expect(largeDiff.deletions == 2)
        #expect(largeDiff.hunks.count == 2)
        // Only contextLines (2 before + 2 after) + 2 changed lines = 6 lines per hunk materialized!
        #expect(largeDiff.hunks[0].lines.count == 6)
        #expect(largeDiff.hunks[1].lines.count == 6)
        #expect(largeDiff.hunks[0].oldStart == 8)
        #expect(largeDiff.hunks[1].oldStart == 3988)
    }

    @Test("ANSITerminalParser handles 256-color & truecolor SGR without misinterpreting 0/1/31..37, standalone CR overwrites, and trailing CSI")
    func ansiExtendedSGRCarriageReturnAndIncompleteEscape() {
        // 1) Bold (1) + green fg (32) + truecolor bg 48;2;31;1;0 -> R=31, G=1, B=0 MUST NOT reset bold or clobber fg=32!
        let sgrRaw = "\u{1B}[1;32;48;2;31;1;0mBOLD_GREEN\u{1B}[0m"
        let sgrSpans = ANSITerminalParser.parse(sgrRaw)
        #expect(sgrSpans.count == 1)
        #expect(sgrSpans[0].text == "BOLD_GREEN")
        #expect(sgrSpans[0].fgCode == 32)
        #expect(sgrSpans[0].isBold == true)

        // 2) 256-color fg 38;5;1 (red -> 31) and 48;5;0 (black bg -> must NOT reset bold!)
        let sgr256 = "\u{1B}[1;38;5;1;48;5;0mALERT\u{1B}[0m"
        let spans256 = ANSITerminalParser.parse(sgr256)
        #expect(spans256.count == 1)
        #expect(spans256[0].text == "ALERT")
        #expect(spans256[0].fgCode == 31)
        #expect(spans256[0].isBold == true)

        // 3) Standalone \r rewinds column cursor and overwrites progress line cleanly (including \r\x1b[K)!
        let progress = "Downloading 12%\rDownloading 100%\r\nBuilding very long target...\r\u{1B}[KDone!\n"
        let progressSpans = ANSITerminalParser.parse(progress)
        let rendered = progressSpans.map(\.text).joined()
        #expect(rendered == "Downloading 100%\nDone!\n")

        // 4) Incomplete trailing CSI / OSC sequences never leak raw "[38;2;255" into output, and carry across chunks!
        var carry = ""
        let part1 = ANSITerminalParser.parse("Hello \u{1B}[1;34", carry: &carry)
        #expect(part1.map(\.text).joined() == "Hello ")
        #expect(carry == "\u{1B}[1;34")
        let part2 = ANSITerminalParser.parse("mWorld\u{1B}[0m", carry: &carry)
        #expect(carry.isEmpty)
        #expect(part2.count == 1)
        #expect(part2[0].text == "World")
        #expect(part2[0].fgCode == 34)
        #expect(part2[0].isBold == true)
    }

    @Test("LiveSessionTelemetryTracker resets TTFT on new turn without leaking stale host firstTokenMs and uses Unix epoch seconds")
    func liveTelemetryTurnBoundaryTTFTAndEpoch() {
        var tracker = LiveSessionTelemetryTracker()
        let t0: TimeInterval = 1_795_274_200.0

        // Turn 1 finishes with host firstTokenMs = 640ms
        var session = SessionView(
            id: "s-ttft",
            agentId: "claude-code",
            projectPath: "/repo",
            status: .ready,
            speed: OutputSpeedInfo(last: SpeedSampleInfo(tokens: 200, ms: 2000, approx: false, firstTokenMs: 640))
        )
        var replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1))
        tracker.syncSnapshot(replica: replica, at: t0)
        #expect(tracker.snapshot(for: replica, at: t0).ttftMs == 640)

        // Turn 2 starts: while awaiting Turn 2's first token, stale Turn 1 firstTokenMs (640) MUST NOT be reported!
        tracker.recordPromptSent(sessionId: "s-ttft", at: t0 + 10.0)
        session.status = .running
        session.turnStartedAt = (t0 + 10.0) * 1000.0
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 2))
        #expect(tracker.snapshot(for: replica, at: t0 + 10.2).ttftMs == nil)

        // First chunk of Turn 2 arrives 310ms after prompt: measuredTTFTMs = 310ms takes effect!
        let batch = PatchBatch(
            sessionId: "s-ttft",
            seq: 3,
            patches: [.entryAdd(.agent(id: "a-2", markdown: "Hi!", streaming: true, at: nil))]
        )
        tracker.recordBatch(batch, replica: replica, at: t0 + 10.31)
        #expect(tracker.snapshot(for: replica, at: t0 + 10.31).ttftMs == 310)

        // Remote-triggered Turn 3 with turnStartedAt in Unix ms computes TTFT accurately against Unix-epoch `now`!
        session.status = .ready
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 4))
        tracker.syncSnapshot(replica: replica, at: t0 + 20.0)

        session.status = .running
        session.turnStartedAt = (t0 + 30.0) * 1000.0
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 5))
        let batch3 = PatchBatch(
            sessionId: "s-ttft",
            seq: 5,
            patches: [.entryAppendText(id: "a-3", text: "Remote start")]
        )
        tracker.recordBatch(batch3, replica: replica, at: t0 + 30.45)
        #expect(tracker.snapshot(for: replica, at: t0 + 30.45).ttftMs == 450)
    }

    @Test("ToolEntryData.hasDigestedContent and ThreadReplica.replaceHydratedEntry preserve order and seq")
    func toolDigestHydrationPreservesOrderAndSeq() throws {
        let digestedJSON = """
        {
          "kind": "tool",
          "id": "tool_1",
          "title": "Edit sessions.ts",
          "toolKind": "edit",
          "status": "completed",
          "rawInputDigest": { "size": 4096, "lines": 120 },
          "content": [
            { "type": "digest", "of": "diff", "path": "/repo/src/sessions.ts", "size": 912000, "added": 12, "removed": 4 }
          ]
        }
        """
        let digestedEntry = try JSONDecoder().decode(ThreadEntry.self, from: Data(digestedJSON.utf8))
        guard case .tool(let digestedTool) = digestedEntry else {
            Issue.record("Expected digested tool entry")
            return
        }
        #expect(digestedTool.hasDigestedContent == true)
        #expect(digestedTool.rawInputDigestInfo == ToolInputDigestInfo(size: 4096, lines: 120))

        let session = SessionView(id: "s-digest", agentId: "antigravity", projectPath: "/repo", status: .ready)
        let snapshot = SessionSnapshot(
            session: session,
            entries: [
                .user(id: "u1", text: "Fix bug", at: 1000, approval: false),
                digestedEntry,
                .agent(id: "a1", markdown: "Done", streaming: false, at: 2000),
            ],
            seq: 42
        )
        var replica = ThreadReplica(snapshot: snapshot)

        let fullTool = ToolEntryData(
            id: "tool_1",
            title: "Edit sessions.ts",
            toolKind: "edit",
            status: "completed",
            content: [.diff(path: "/repo/src/sessions.ts", oldText: "old", newText: "new")],
            rawInput: "{\"file\":\"src/sessions.ts\"}"
        )
        #expect(fullTool.hasDigestedContent == false)

        let replaced = replica.replaceHydratedEntry(.tool(fullTool))
        #expect(replaced == true)
        #expect(replica.seq == 42)
        #expect(replica.order == ["u1", "tool_1", "a1"])
        if case .tool(let updated)? = replica.byId["tool_1"] {
            #expect(updated.hasDigestedContent == false)
            #expect(updated.rawInput == "{\"file\":\"src/sessions.ts\"}")
            #expect(updated.content == [.diff(path: "/repo/src/sessions.ts", oldText: "old", newText: "new")])
        } else {
            Issue.record("Expected hydrated tool entry in replica")
        }

        // Hydrating an unknown entry ID does not insert or mutate the replica.
        let unknownReplaced = replica.replaceHydratedEntry(.tool(ToolEntryData(
            id: "tool_missing",
            title: "Missing",
            toolKind: "read",
            status: "completed"
        )))
        #expect(unknownReplaced == false)
        #expect(replica.order == ["u1", "tool_1", "a1"])
    }

    @Test("DeviceIdentityStore never replaces a stored identity with another key")
    func deviceIdentityStoreKeepsStoredKey() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pk-id-keep-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("device-identity.json").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let fileURL = dir.appendingPathComponent("device-identity.json")
        let bakURL = fileURL.appendingPathExtension("bak")
        let store = DeviceIdentityStore(fileURL: fileURL)

        let first = store.loadIdentity()
        #expect(first.isPersisted)
        let host = PairedHostRecord(id: "host-main", name: "MacBook Pro", hostPublicKey: BaseEncoding.base64URLEncode(Data(repeating: 7, count: 32)))
        #expect(store.save(keyPair: first.keyPair, hosts: [host]))

        // The files cannot be read, as before the first unlock after a restart: the app gets a key
        // for this run only and is told so.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: bakURL.path)
        let locked = store.loadIdentity()
        #expect(!locked.isPersisted)
        #expect(locked.hosts.isEmpty)
        #expect(locked.keyPair.privateKeyData != first.keyPair.privateKeyData)
        // Saving that key, as pairing a host again would, must not reach the disk.
        #expect(!store.save(keyPair: locked.keyPair, hosts: []))

        // Readable again: the stored identity is there, hosts included, and another key still
        // cannot take its place.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bakURL.path)
        #expect(!store.save(keyPair: locked.keyPair, hosts: []))
        let again = store.loadIdentity()
        #expect(again.isPersisted)
        #expect(again.keyPair.privateKeyData == first.keyPair.privateKeyData)
        #expect(again.hosts.map(\.id) == ["host-main"])
        // The device's own key still saves.
        #expect(store.save(keyPair: again.keyPair, hosts: []))
    }
}
