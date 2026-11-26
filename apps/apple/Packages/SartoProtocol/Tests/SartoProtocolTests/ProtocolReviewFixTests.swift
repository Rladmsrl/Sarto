import Foundation
import Testing
@testable import SartoProtocol

private final class FixWebSocketDriver: ChannelWebSocketDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var cancelled = false

    var peerCloseCode: Int? { nil }

    var isCancelled: Bool { lock.withLock { cancelled } }

    func push(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
            return
        }
        inbound.append(message)
        lock.unlock()
    }

    func takeSent() -> [URLSessionWebSocketTask.Message] {
        lock.withLock {
            let out = sent
            sent.removeAll()
            return out
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let wasCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            sent.append(message)
            return false
        }
        if wasCancelled { throw URLError(.cancelled) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if cancelled {
                lock.unlock()
                cont.resume(throwing: URLError(.cancelled))
                return
            }
            if !inbound.isEmpty {
                let next = inbound.removeFirst()
                lock.unlock()
                cont.resume(returning: next)
                return
            }
            waiters.append(cont)
            lock.unlock()
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(throwing: URLError(.cancelled)) }
    }
}

private func makeChannels() throws -> (client: SartoChannel, host: SartoChannel) {
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
    return (SartoChannel(ciphers: try initHS.split()), SartoChannel(ciphers: try respHS.split()))
}

private func welcomeData(protocolVersion: Int = 4) throws -> Data {
    try JSONEncoder().encode(WelcomeMessage(
        protocol: protocolVersion,
        host: WelcomeHostInfo(name: "Host", platform: "darwin", version: "0.2.0"),
        features: ["bytes"],
        device: WelcomeDeviceInfo(id: "dev_fix123", name: "Device")
    ))
}

private let testHello = HelloMessage(client: HelloClientInfo(kind: "desktop", version: "0.2.0", platform: "darwin"))

/// A connected transport whose host side the test drives through `host` and `driver`.
private struct ChannelHarness {
    let driver: FixWebSocketDriver
    let host: SartoChannel
    let transport: EncryptedChannelTransport

    static func make() async throws -> ChannelHarness {
        let (client, host) = try makeChannels()
        let driver = FixWebSocketDriver()
        for f in try host.seal(.json(try welcomeData())) { driver.push(.data(f)) }
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: client,
            hello: testHello,
            keepaliveInterval: 600,
            keepaliveTimeout: 600
        )
        let harness = ChannelHarness(driver: driver, host: host, transport: transport)
        _ = try harness.drainJSON()
        return harness
    }

    func push(_ json: String) throws {
        for f in try host.seal(.json(Data(json.utf8))) { driver.push(.data(f)) }
    }

    func pushBytes(stream: UInt32, _ data: Data) throws {
        for f in try host.seal(.bytes(stream: stream, data: data)) { driver.push(.data(f)) }
    }

    func drainJSON() throws -> [JSONValue] {
        var out: [JSONValue] = []
        for msg in driver.takeSent() {
            guard case .data(let frame) = msg, case .json(let data)? = try host.open(frame: frame) else { continue }
            out.append(try JSONDecoder().decode(JSONValue.self, from: data))
        }
        return out
    }

    func nextRequestID() async throws -> Int {
        for _ in 0..<500 {
            for value in try drainJSON() where value.objectValue?["type"] == .string("request") {
                return Int(value.objectValue?["id"]?.doubleValue ?? -1)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw PortRPCError(code: "timeout", message: "No request was sent")
    }
}

private func replica(with entries: [ThreadEntry]) -> ThreadReplica {
    ThreadReplica(snapshot: SessionSnapshot(
        session: SessionView(id: "s1", agentId: "claude", projectPath: "/p", status: .ready),
        entries: entries,
        seq: 1
    ))
}

private func patchBatch(_ json: String, seq: Int = 2) throws -> PatchBatch {
    try JSONDecoder().decode(PatchBatch.self, from: Data("{\"sessionId\":\"s1\",\"seq\":\(seq),\"patches\":[\(json)]}".utf8))
}

/// Polls until the condition holds, so a slow CI runner does not fail a fixed sleep.
func eventually(_ timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

@Suite("Protocol review fixes: replica merges, resync, welcome, binary streams, lifetimes")
struct ProtocolReviewFixTests {
    // MARK: - entry.update merges into every entry kind

    @Test("entry.update rewrites a sign-in notice like the agent host's settleSignInNotices")
    func noticeUpdateMerges() throws {
        var r = replica(with: [
            .notice(id: "n1", severity: "warning", title: "Sign in to Claude", description: "Run login", cause: nil, model: nil),
        ])
        let applied = r.apply(try patchBatch(
            "{\"op\":\"entry.update\",\"id\":\"n1\",\"changes\":{\"severity\":\"info\",\"title\":\"Signed in to Claude\",\"description\":\"You can send messages again\"}}"
        ))
        #expect(applied)
        #expect(r.byId["n1"] == .notice(id: "n1", severity: "info", title: "Signed in to Claude", description: "You can send messages again", cause: nil, model: nil))

        r.apply(try patchBatch("{\"op\":\"entry.update\",\"id\":\"n1\",\"changes\":{\"description\":null,\"cause\":\"turn_failed\"}}", seq: 3))
        #expect(r.byId["n1"] == .notice(id: "n1", severity: "info", title: "Signed in to Claude", description: nil, cause: "turn_failed", model: nil))
    }

    @Test("entry.update carries a takeover's agentId, summarize, turns, omitted and carried")
    func takeoverUpdateMerges() throws {
        var r = replica(with: [
            .takeover(id: "k1", agentId: "claude", turns: 0, omitted: 0, carried: "", summarize: nil),
        ])
        r.apply(try patchBatch("{\"op\":\"entry.update\",\"id\":\"k1\",\"changes\":{\"agentId\":\"codex\",\"summarize\":true}}"))
        #expect(r.byId["k1"] == .takeover(id: "k1", agentId: "codex", turns: 0, omitted: 0, carried: "", summarize: true))
        r.apply(try patchBatch("{\"op\":\"entry.update\",\"id\":\"k1\",\"changes\":{\"turns\":12,\"omitted\":3,\"carried\":\"Earlier: fixed the parser\"}}", seq: 3))
        #expect(r.byId["k1"] == .takeover(id: "k1", agentId: "codex", turns: 12, omitted: 3, carried: "Earlier: fixed the parser", summarize: true))
    }

    @Test("entry.update merges the remaining kinds, clears optional fields on null and never changes id or kind")
    func everyKindMerges() throws {
        var r = replica(with: [
            .turnEnd(id: "e1", stopReason: "end_turn", durationMs: 10),
            .sessionMessage(id: "m1", senderId: nil, content: [.text("hi")]),
            .subagent(id: "sa1", sessionId: "child-1"),
            .sessionStarted(id: "ss1", sessionId: "child-2", after: nil),
            .user(id: "u1", text: "hello", content: [.text("hello")], at: 5, approval: false),
            .agent(id: "a1", markdown: "md", streaming: true, at: 7),
            .thought(id: "t1", markdown: "think", streaming: true, durationMs: 9),
            .tool(ToolEntryData(id: "tool1", title: "Read", toolKind: "read", status: "pending", rawInput: "{}", description: "desc", label: "lbl", planVersion: 2)),
        ])
        let patches = [
            "{\"op\":\"entry.update\",\"id\":\"e1\",\"changes\":{\"stopReason\":\"cancelled\",\"durationMs\":99}}",
            "{\"op\":\"entry.update\",\"id\":\"m1\",\"changes\":{\"senderId\":\"s9\",\"content\":[{\"type\":\"text\",\"text\":\"bye\"}]}}",
            "{\"op\":\"entry.update\",\"id\":\"sa1\",\"changes\":{\"sessionId\":\"child-9\"}}",
            "{\"op\":\"entry.update\",\"id\":\"ss1\",\"changes\":{\"after\":\"a1\"}}",
            "{\"op\":\"entry.update\",\"id\":\"u1\",\"changes\":{\"approval\":true,\"at\":null,\"steered\":true}}",
            "{\"op\":\"entry.update\",\"id\":\"a1\",\"changes\":{\"at\":null,\"streaming\":false}}",
            "{\"op\":\"entry.update\",\"id\":\"t1\",\"changes\":{\"durationMs\":null,\"streaming\":false}}",
            "{\"op\":\"entry.update\",\"id\":\"tool1\",\"changes\":{\"description\":null,\"label\":null,\"rawInput\":null,\"planVersion\":null,\"status\":\"completed\"}}",
            "{\"op\":\"entry.update\",\"id\":\"e1\",\"changes\":{\"id\":\"other\",\"kind\":\"agent\"}}",
        ]
        #expect(r.apply(try patchBatch(patches.joined(separator: ","))))
        #expect(r.byId["e1"] == .turnEnd(id: "e1", stopReason: "cancelled", durationMs: 99))
        #expect(r.byId["m1"] == .sessionMessage(id: "m1", senderId: "s9", content: [.text("bye")]))
        #expect(r.byId["sa1"] == .subagent(id: "sa1", sessionId: "child-9"))
        #expect(r.byId["ss1"] == .sessionStarted(id: "ss1", sessionId: "child-2", after: "a1"))
        #expect(r.byId["u1"] == .user(id: "u1", text: "hello", content: [.text("hello")], at: nil, approval: true, steered: true))
        #expect(r.byId["a1"] == .agent(id: "a1", markdown: "md", streaming: false, at: nil))
        #expect(r.byId["t1"] == .thought(id: "t1", markdown: "think", streaming: false, durationMs: nil))
        guard case .tool(let tool)? = r.byId["tool1"] else {
            Issue.record("Expected the tool entry")
            return
        }
        #expect(tool.status == "completed")
        #expect(tool.description == nil)
        #expect(tool.label == nil)
        #expect(tool.rawInput == nil)
        #expect(tool.planVersion == nil)
        #expect(r.byId["other"] == nil)
        #expect(r.order.count == 8)
    }

    // MARK: - Streaming text deltas append in place

    @Test("entry.appendText appends in place instead of copying the whole message per delta")
    func appendTextIsLinear() throws {
        var r = replica(with: [.agent(id: "a1", markdown: "", streaming: true, at: nil)])
        let delta = String(repeating: "x", count: 64)
        let deltas = 40_000
        let start = Date()
        var seq = 1
        for _ in 0..<(deltas / 100) {
            seq += 1
            let patches = Array(repeating: ThreadPatch.entryAppendText(id: "a1", text: delta), count: 100)
            r.apply(PatchBatch(sessionId: "s1", seq: seq, patches: patches))
        }
        let elapsed = Date().timeIntervalSince(start)
        guard case .agent(_, let md, _, _, _)? = r.byId["a1"] else {
            Issue.record("Expected the agent entry")
            return
        }
        #expect(md.utf8.count == deltas * 64)
        // Copying the message per delta moves ~51 GB here; appending in place takes milliseconds.
        #expect(elapsed < 3, "40k deltas took \(elapsed)s")
    }

    // MARK: - thread.truncate (an edit from a sent message)

    @Test("thread.truncate drops the entry and every entry after it, and asks for a snapshot when it is not loaded")
    func threadTruncate() throws {
        var r = replica(with: [])
        let added = try patchBatch(
            "{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\",\"id\":\"a1\",\"markdown\":\"one\"}}," +
            "{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\",\"id\":\"a2\",\"markdown\":\"two\"}}," +
            "{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\",\"id\":\"a3\",\"markdown\":\"three\"}}",
            seq: 2
        )
        let addedApplied = r.apply(added)
        #expect(addedApplied)
        let event = "{\"type\":\"event\",\"event\":{\"type\":\"session.patches\",\"batch\":{\"sessionId\":\"s1\",\"seq\":3,\"patches\":[{\"op\":\"thread.truncate\",\"id\":\"a2\"}]}}}"
        guard case .sessionPatches(let batch)? = HostEvent.decode(fromEnvelopeData: Data(event.utf8)) else {
            Issue.record("Expected sessionPatches")
            return
        }
        let expected = try patchBatch("{\"op\":\"thread.truncate\",\"id\":\"a2\"}", seq: 3)
        #expect(batch == expected)
        let truncated = r.apply(batch)
        #expect(truncated)
        #expect(r.entries.map(\.id) == ["a1"])
        #expect(r.byId["a2"] == nil)
        #expect(r.byId["a3"] == nil)
        #expect(r.seq == 3)

        // An entry on an older page this replica lacks: only a snapshot sets the thread right.
        let missing = try patchBatch("{\"op\":\"thread.truncate\",\"id\":\"gone\"}", seq: 4)
        let missingApplied = r.apply(missing)
        #expect(missingApplied == false)
        #expect(r.seq == 3)
    }

    // MARK: - An undecodable patch batch asks for a resync

    @Test("A session.patches batch that does not decode asks for that session's resync instead of .unknown")
    func undecodableBatchRequestsResync() throws {
        let bad = "{\"type\":\"event\",\"event\":{\"type\":\"session.patches\",\"batch\":{\"sessionId\":\"s1\",\"seq\":5,\"patches\":[{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\"}}]}}}"
        guard case .sessionPatches(let batch)? = HostEvent.decode(fromEnvelopeData: Data(bad.utf8)) else {
            Issue.record("Expected a sessionPatches resync signal")
            return
        }
        #expect(batch.sessionId == "s1")
        #expect(batch.requiresResync)
        #expect(batch.patches.isEmpty)
        var r = replica(with: [])
        #expect(r.apply(batch) == false)

        let noSession = "{\"type\":\"event\",\"event\":{\"type\":\"session.patches\",\"batch\":{\"seq\":5,\"patches\":[]}}}"
        #expect(HostEvent.decode(fromEnvelopeData: Data(noSession.utf8)) == .resync)

        let good = "{\"type\":\"event\",\"event\":{\"type\":\"session.patches\",\"batch\":{\"sessionId\":\"s1\",\"seq\":2,\"patches\":[{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\",\"id\":\"a1\",\"markdown\":\"hi\"}},{\"op\":\"entry.update\",\"id\":\"a1\",\"changes\":{\"streaming\":true,\"n\":1.5,\"z\":[null,false,\"s\",{}]}},{\"op\":\"future.op\"}]}}}"
        guard case .sessionPatches(let goodBatch)? = HostEvent.decode(fromEnvelopeData: Data(good.utf8)) else {
            Issue.record("Expected sessionPatches")
            return
        }
        #expect(!goodBatch.requiresResync)
        #expect(goodBatch == (try JSONDecoder().decode(PatchBatch.self, from: Data(
            "{\"sessionId\":\"s1\",\"seq\":2,\"patches\":[{\"op\":\"entry.add\",\"entry\":{\"kind\":\"agent\",\"id\":\"a1\",\"markdown\":\"hi\"}},{\"op\":\"entry.update\",\"id\":\"a1\",\"changes\":{\"streaming\":true,\"n\":1.5,\"z\":[null,false,\"s\",{}]}},{\"op\":\"future.op\"}]}".utf8
        ))))
        #expect(HostEvent.decode(from: try JSONDecoder().decode(JSONValue.self, from: Data(
            "{\"type\":\"session.patches\",\"batch\":{\"sessionId\":\"s1\",\"seq\":5,\"patches\":[{\"op\":\"entry.add\"}]}}".utf8
        ))) == .sessionPatches(.resyncRequired(sessionId: "s1")))
    }

    // MARK: - Welcome

    @Test("An undecodable welcome fails the connection instead of being skipped")
    func undecodableWelcomeIsFatal() async throws {
        let (client, host) = try makeChannels()
        let driver = FixWebSocketDriver()
        for f in try host.seal(.json(Data("{\"type\":\"welcome\",\"protocol\":4,\"features\":[]}".utf8))) {
            driver.push(.data(f))
        }
        let start = Date()
        await #expect(throws: PortRPCError.self) {
            _ = try await EncryptedChannelTransport(driver: driver, channel: client, hello: testHello)
        }
        #expect(Date().timeIntervalSince(start) < 1)
        #expect(driver.isCancelled)

        let (client2, host2) = try makeChannels()
        let driver2 = FixWebSocketDriver()
        for f in try host2.seal(.json(try welcomeData(protocolVersion: 99))) { driver2.push(.data(f)) }
        await #expect(throws: PortRPCError.self) {
            _ = try await EncryptedChannelTransport(driver: driver2, channel: client2, hello: testHello)
        }
    }

    @Test("The wait for the welcome ends after the optional timeout")
    func welcomeTimeout() async throws {
        let (client, _) = try makeChannels()
        let driver = FixWebSocketDriver()
        let start = Date()
        do {
            _ = try await EncryptedChannelTransport(
                driver: driver,
                channel: client,
                hello: testHello,
                welcomeTimeout: 0.15
            )
            Issue.record("Expected the welcome wait to time out")
        } catch let error as PortRPCError {
            #expect(error.code == "host_offline")
            #expect(error.message == "The host did not answer in time")
        }
        let waited = Date().timeIntervalSince(start)
        #expect(waited >= 0.14 && waited < 2)
        #expect(driver.isCancelled)

        // A welcome inside the timeout connects as before.
        let harnessChannels = try makeChannels()
        let driver2 = FixWebSocketDriver()
        for f in try harnessChannels.host.seal(.json(try welcomeData())) { driver2.push(.data(f)) }
        let transport = try await EncryptedChannelTransport(
            driver: driver2,
            channel: harnessChannels.client,
            hello: testHello,
            welcomeTimeout: 5
        )
        #expect(transport.welcome.device.id == "dev_fix123")
        await transport.close()
    }

    // MARK: - Binary downloads out of band

    @Test("Stream downloads reach typed callers as raw Data and legacy callers as base64")
    func binaryDownloadsOutOfBand() async throws {
        let blob = Data((0..<300_000).map { UInt8(($0 * 7) & 0xff) })

        let h = try await ChannelHarness.make()
        let session = SartoHostSession(transport: h.transport)
        let task = Task { try await session.requestResponse("sessions.blob", params: .object(["hash": .string("x")])) }
        let id = try await h.nextRequestID()
        try h.push("{\"type\":\"response\",\"id\":\(id),\"result\":{\"mimeType\":\"image/png\",\"bytes\":{\"$stream\":2,\"size\":\(blob.count)}}}")
        try h.pushBytes(stream: 2, blob.prefix(200_000))
        try h.pushBytes(stream: 2, blob.suffix(from: 200_000))
        try h.push("{\"type\":\"stream.end\",\"stream\":2}")
        let response = try await task.value
        #expect(response.data(atKey: "bytes") == blob)
        #expect(response.data(at: [.string("bytes")]) == blob)
        #expect(response.buffers.count == 1)
        #expect(try response.result().objectValue?["mimeType"] == .string("image/png"))
        struct Mime: Decodable { let mimeType: String }
        #expect(try response.decodeResult(Mime.self).mimeType == "image/png")

        // The untyped request keeps returning base64 at the binary's place.
        let legacy = Task { try await session.request("sessions.blob", params: .null) }
        let id2 = try await h.nextRequestID()
        try h.push("{\"type\":\"response\",\"id\":\(id2),\"result\":{\"bytes\":{\"$stream\":4,\"size\":3}}}")
        try h.pushBytes(stream: 4, Data([1, 2, 3]))
        try h.push("{\"type\":\"stream.end\",\"stream\":4}")
        #expect(try await legacy.value.objectValue?["bytes"] == .string(Data([1, 2, 3]).base64EncodedString()))
        await session.close()

        // A consumer of the transport's plain `messages` sees the base64 inlined, as before.
        let h2 = try await ChannelHarness.make()
        try h2.push("{\"type\":\"response\",\"id\":1,\"result\":{\"png\":{\"$stream\":2,\"size\":2}}}")
        try h2.pushBytes(stream: 2, Data([9, 8]))
        try h2.push("{\"type\":\"stream.end\",\"stream\":2}")
        var iterator = h2.transport.messages.makeAsyncIterator()
        let first = try #require(try await iterator.next())
        let value = try JSONDecoder().decode(JSONValue.self, from: first)
        #expect(value.objectValue?["result"]?.objectValue?["png"] == .string(Data([9, 8]).base64EncodedString()))
        await h2.transport.close()
    }

    #if os(macOS)
    @Test("Unix socket WITH_BUFFERS frames keep their buffers out of band")
    func unixSocketBuffersOutOfBand() throws {
        let message = Data("{\"type\":\"response\",\"id\":3,\"result\":{\"data\":null,\"list\":[1,null]}}".utf8)
        let paths = Data("[[\"result\",\"data\"],[\"result\",\"list\",1]]".utf8)
        var wrapped = Data("[".utf8)
        wrapped.append(message)
        wrapped.append(Data(",".utf8))
        wrapped.append(paths)
        wrapped.append(Data("]".utf8))
        var body = Data()
        func be(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
        body.append(be(wrapped.count))
        body.append(wrapped)
        body.append(be(3))
        body.append(Data([1, 2, 3]))
        body.append(be(2))
        body.append(Data([4, 5]))

        let inbound = try #require(UnixSocketPortTransport.decodeInbound(body))
        #expect(inbound.buffers.map(\.path) == [[.string("result"), .string("data")], [.string("result"), .string("list"), .number(1)]])
        #expect(inbound.buffers.map(\.data) == [Data([1, 2, 3]), Data([4, 5])])
        let json = try JSONDecoder().decode(JSONValue.self, from: inbound.json)
        #expect(json.objectValue?["id"] == .number(3))

        let legacy = try #require(UnixSocketPortTransport.decodeWithBuffers(body))
        let legacyValue = try JSONDecoder().decode(JSONValue.self, from: legacy)
        #expect(legacyValue.objectValue?["result"]?.objectValue?["data"] == .string(Data([1, 2, 3]).base64EncodedString()))
        #expect(legacyValue.objectValue?["result"]?.objectValue?["list"] == .array([.number(1), .string(Data([4, 5]).base64EncodedString())]))
    }
    #endif

    // MARK: - Lifetimes

    @Test("A dropped transport and session deinit and close the socket")
    func droppedTransportAndSessionDeinit() async throws {
        weak var weakTransport: EncryptedChannelTransport?
        weak var weakSession: SartoHostSession?
        let driver: FixWebSocketDriver
        do {
            let h = try await ChannelHarness.make()
            driver = h.driver
            let session = SartoHostSession(transport: h.transport)
            weakTransport = h.transport
            weakSession = session
            try await Task.sleep(nanoseconds: 20_000_000)
            #expect(weakSession != nil)
        }
        #expect(await eventually { weakSession == nil })
        #expect(await eventually { weakTransport == nil })
        #expect(await eventually { driver.isCancelled })

        weak var weakTerminal: SartoTerminalSession?
        let driver2: FixWebSocketDriver
        do {
            let h = try await ChannelHarness.make()
            driver2 = h.driver
            let terminal = SartoTerminalSession(transport: h.transport)
            weakTerminal = terminal
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(await eventually { weakTerminal == nil })
        #expect(await eventually { driver2.isCancelled })
    }

    // MARK: - JSONValue fast paths

    @Test("JSONValue parses and serializes like JSONDecoder and JSONEncoder")
    func jsonValueFastPaths() throws {
        let samples = [
            "{\"a\":1,\"b\":-2.5,\"c\":1e21,\"d\":[true,false,null],\"e\":\"q\\\"\\\\\\/\\b\\f\\n\\r\\t\\u00e9\\ud83d\\ude00\",\"f\":{},\"g\":[],\"h\":0,\"i\":-0.0,\"j\":123456789012345678}",
            "[1, 2 ,3 ]",
            "\"plain\"",
            "  null  ",
            "9007199254740993",
            "{\"nested\":{\"deep\":[[[{\"x\":\"\u{4e2d}\u{6587}\"}]]]}}",
        ]
        for sample in samples {
            let data = Data(sample.utf8)
            let reference = try JSONDecoder().decode(JSONValue.self, from: data)
            let parsed = try JSONValue(jsonData: data)
            #expect(parsed == reference, "\(sample)")
            let reparsed = try JSONDecoder().decode(JSONValue.self, from: try parsed.jsonData())
            #expect(reparsed == reference, "\(sample)")
        }
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01", "1.", "\"\\x\"", "[1] 2", "\"a\u{01}\"", "-"] {
            #expect(throws: (any Error).self, "\(bad)") { _ = try JSONValue(jsonData: Data(bad.utf8)) }
        }
        let nested = String(repeating: "[", count: 128) + String(repeating: "]", count: 128)
        #expect(throws: Never.self) { _ = try JSONValue(jsonData: Data(nested.utf8)) }
        let deep = String(repeating: "[", count: 10_000) + String(repeating: "]", count: 10_000)
        #expect(throws: (any Error).self) { _ = try JSONValue(jsonData: Data(deep.utf8)) }
        #expect(throws: (any Error).self) { _ = try JSONValue.number(.infinity).jsonData() }
        #expect(String(decoding: try JSONValue.number(42).jsonData(), as: UTF8.self) == "42")
    }

    @Test("Typed requests decode a missing or null result like the untyped path")
    func typedRequestNullResult() async throws {
        let h = try await ChannelHarness.make()
        let session = SartoHostSession(transport: h.transport)
        let missing = Task { try await session.request("x.optional", params: .null, as: [String]?.self) }
        let id = try await h.nextRequestID()
        try h.push("{\"type\":\"response\",\"id\":\(id)}")
        #expect(try await missing.value == nil)

        let required = Task { try await session.request("x.required", params: .null, as: [String].self) }
        let id2 = try await h.nextRequestID()
        try h.push("{\"type\":\"response\",\"id\":\(id2),\"result\":null}")
        await #expect(throws: (any Error).self) { _ = try await required.value }

        let present = Task { try await session.request("x.list", params: .null, as: [String].self) }
        let id3 = try await h.nextRequestID()
        try h.push("{\"id\":\(id3),\"result\":[\"a\",\"b\"],\"type\":\"response\"}")
        #expect(try await present.value == ["a", "b"])
        await session.close()
    }
}
