import Darwin
import Foundation
import Testing
@testable import SartoProtocol

/// In-memory WebSocket driver for driving `EncryptedChannelTransport` from the benchmarks.
private final class BenchWebSocketDriver: ChannelWebSocketDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var sent: [URLSessionWebSocketTask.Message] = []
    private var cancelled = false

    var peerCloseCode: Int? { nil }

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
        lock.lock()
        defer { lock.unlock() }
        let out = sent
        sent.removeAll()
        return out
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

private func makeBenchChannelPair() throws -> (client: SartoChannel, host: SartoChannel) {
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

/// A `sessions.open` result shaped like a long agent session: prose, thoughts, tools and turn ends.
func makeBenchSnapshotJSON(entries count: Int) throws -> Data {
    let prose = String(repeating: "The quick brown fox jumps over the lazy dog, \"quoted\" and \\escaped\\. ", count: 20)
    var entries: [ThreadEntry] = []
    entries.reserveCapacity(count)
    for i in 0..<count {
        switch i % 5 {
        case 0:
            entries.append(.user(id: "u\(i)", text: "Prompt \(i)", content: [.text("Prompt \(i): \(prose.prefix(200))")], at: 1_700_000_000_000 + Double(i), approval: false))
        case 1:
            entries.append(.agent(id: "a\(i)", markdown: prose, streaming: false, at: 1_700_000_000_000 + Double(i)))
        case 2:
            entries.append(.thought(id: "t\(i)", markdown: String(prose.prefix(600)), streaming: false, durationMs: 1234.5))
        case 3:
            entries.append(.tool(ToolEntryData(
                id: "tool\(i)",
                title: "Edit src/file\(i).ts",
                toolKind: "edit",
                status: "completed",
                content: [
                    .markdown(String(prose.prefix(300))),
                    .diff(path: "src/file\(i).ts", oldText: String(prose.prefix(400)), newText: String(prose.prefix(500))),
                ],
                locations: [ToolLocation(path: "src/file\(i).ts", line: i)],
                permissionResult: .object(["outcome": .string("allow"), "always": .bool(false), "count": .number(3)]),
                rawInput: "{\"path\":\"src/file\(i).ts\",\"old\":\"a\",\"new\":\"b\"}"
            )))
        default:
            entries.append(.turnEnd(id: "e\(i)", stopReason: "end_turn", durationMs: 4567))
        }
    }
    let snapshot = SessionSnapshot(
        session: SessionView(id: "s-bench", agentId: "claude", projectPath: "/tmp/project", status: .ready, title: "Bench"),
        entries: entries,
        seq: 42
    )
    return try JSONEncoder().encode(snapshot)
}

private func envelope(id: Int, result: Data) -> Data {
    var data = Data("{\"type\":\"response\",\"id\":\(id),\"result\":".utf8)
    data.append(result)
    data.append(UInt8(ascii: "}"))
    return data
}

private func median(_ values: [Duration]) -> Duration {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func ms(_ d: Duration) -> String {
    let c = d.components
    let value = Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    return String(format: "%.1f ms", value)
}

@Suite("Decode pipeline benchmarks", .serialized)
struct PerformanceBenchmarkTests {
    @Test("sessions.open over the encrypted channel: transport + session + typed decode")
    func sessionsOpenEndToEnd() async throws {
        let result = try makeBenchSnapshotJSON(entries: 3000)
        let (clientChan, hostChan) = try makeBenchChannelPair()
        let driver = BenchWebSocketDriver()
        let welcome = WelcomeMessage(
            host: WelcomeHostInfo(name: "Bench", platform: "darwin", version: "0.2.0"),
            features: ["bytes"],
            device: WelcomeDeviceInfo(id: "dev_bench1", name: "Bench")
        )
        for f in try hostChan.seal(.json(try JSONEncoder().encode(welcome))) { driver.push(.data(f)) }
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "desktop", version: "0.2.0", platform: "darwin")),
            keepaliveInterval: 600,
            keepaliveTimeout: 600
        )
        let session = SartoHostSession(transport: transport)

        func drainSentRequestIDs() throws -> [Int] {
            var ids: [Int] = []
            for msg in driver.takeSent() {
                guard case .data(let frame) = msg, case .json(let data)? = try hostChan.open(frame: frame) else { continue }
                let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
                if obj["type"] == .string("request"), let id = obj["id"]?.doubleValue { ids.append(Int(id)) }
            }
            return ids
        }
        _ = try drainSentRequestIDs()

        var times: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<7 {
            let task = Task { try await session.openSession(sessionId: "s-bench") }
            var reqID: Int?
            while reqID == nil {
                try await Task.sleep(nanoseconds: 1_000_000)
                reqID = try drainSentRequestIDs().first
            }
            let frames = try hostChan.seal(.json(envelope(id: reqID!, result: result)))
            let start = clock.now
            for f in frames { driver.push(.data(f)) }
            let snapshot = try await task.value
            times.append(clock.now - start)
            #expect(snapshot.entries.count == 3000)
            #expect(snapshot.seq == 42)
        }
        print("[bench] sessions.open \(result.count / 1024) KiB, 3000 entries, channel e2e: median \(ms(median(times))), min \(ms(times.min()!))")
        await session.close()
    }

    @Test("session.patches event decode (entry.update changes through JSONValue)")
    func sessionPatchesDecode() throws {
        var patches: [String] = []
        let blob = String(repeating: "line of tool output with some text in it\\n", count: 20)
        for i in 0..<300 {
            if i % 3 == 0 {
                patches.append("{\"op\":\"entry.update\",\"id\":\"tool\(i)\",\"changes\":{\"status\":\"in_progress\",\"content\":[{\"type\":\"markdown\",\"markdown\":\"\(blob)\"}],\"locations\":[{\"path\":\"a.ts\",\"line\":\(i)}],\"permissionResult\":{\"outcome\":\"allow\",\"n\":\(i),\"ok\":true,\"list\":[1,2,3,null]}}}")
            } else if i % 3 == 1 {
                patches.append("{\"op\":\"entry.appendText\",\"id\":\"a\(i)\",\"text\":\"delta \(i) \"}")
            } else {
                patches.append("{\"op\":\"session.update\",\"changes\":{\"updatedAt\":\(1_700_000_000_000 + i),\"usage\":{\"used\":\(i),\"size\":200000},\"status\":\"running\"}}")
            }
        }
        let event = "{\"type\":\"event\",\"event\":{\"type\":\"session.patches\",\"batch\":{\"sessionId\":\"s1\",\"seq\":7,\"patches\":[\(patches.joined(separator: ","))]}}}"
        let data = Data(event.utf8)

        let clock = ContinuousClock()
        var times: [Duration] = []
        for _ in 0..<15 {
            let start = clock.now
            let decoded = HostEvent.decode(fromEnvelopeData: data)
            times.append(clock.now - start)
            guard case .sessionPatches(let batch)? = decoded else {
                Issue.record("Expected sessionPatches")
                return
            }
            #expect(batch.patches.count == 300)
        }
        print("[bench] session.patches \(data.count / 1024) KiB, 300 patches: median \(ms(median(times))), min \(ms(times.min()!))")
    }

    @Test("JSONValue parse and typed decode of a large result")
    func jsonValueParseAndDecode() throws {
        let result = try makeBenchSnapshotJSON(entries: 3000)
        let clock = ContinuousClock()

        var parseTimes: [Duration] = []
        var value: JSONValue = .null
        for _ in 0..<5 {
            let start = clock.now
            value = try JSONDecoder().decode(JSONValue.self, from: result)
            parseTimes.append(clock.now - start)
        }
        var decodeTimes: [Duration] = []
        for _ in 0..<5 {
            let start = clock.now
            let snapshot = try value.decode(SessionSnapshot.self)
            decodeTimes.append(clock.now - start)
            #expect(snapshot.entries.count == 3000)
        }
        var fastParseTimes: [Duration] = []
        for _ in 0..<5 {
            let start = clock.now
            let parsed = try JSONValue(jsonData: result)
            fastParseTimes.append(clock.now - start)
            #expect(parsed == value)
        }
        var writeTimes: [Duration] = []
        for _ in 0..<5 {
            let start = clock.now
            _ = try value.jsonData()
            writeTimes.append(clock.now - start)
        }
        print("[bench] JSONDecoder->JSONValue \(result.count / 1024) KiB: median \(ms(median(parseTimes))); JSONValue(jsonData:): median \(ms(median(fastParseTimes))); jsonData(): median \(ms(median(writeTimes))); JSONValue.decode(SessionSnapshot): median \(ms(median(decodeTimes)))")
    }
}

/// Samples the process's physical footprint on a background thread and keeps the highest value.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private var thread: Thread?

    static func current() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        peak = Self.current()
        let t = Thread { [self] in
            while lock.withLock({ running }) {
                let now = Self.current()
                lock.withLock { peak = max(peak, now) }
                usleep(500)
            }
        }
        thread = t
        t.start()
    }

    func stop() -> UInt64 {
        lock.withLock { running = false }
        return lock.withLock { peak }
    }
}

@Suite("Binary download memory benchmark", .serialized)
struct BinaryDownloadBenchmarkTests {
    @Test("32 MiB sessions.blob download over the encrypted channel: peak footprint growth")
    func largeBlobDownloadFootprint() async throws {
        let (clientChan, hostChan) = try makeBenchChannelPair()
        let driver = BenchWebSocketDriver()
        let welcome = WelcomeMessage(
            host: WelcomeHostInfo(name: "Bench", platform: "darwin", version: "0.2.0"),
            features: ["bytes"],
            device: WelcomeDeviceInfo(id: "dev_bench1", name: "Bench")
        )
        for f in try hostChan.seal(.json(try JSONEncoder().encode(welcome))) { driver.push(.data(f)) }
        let transport = try await EncryptedChannelTransport(
            driver: driver,
            channel: clientChan,
            hello: HelloMessage(client: HelloClientInfo(kind: "desktop", version: "0.2.0", platform: "darwin")),
            keepaliveInterval: 600,
            keepaliveTimeout: 600
        )
        let session = SartoHostSession(transport: transport)
        for msg in driver.takeSent() {
            if case .data(let frame) = msg { _ = try hostChan.open(frame: frame) }
        }

        let size = SartoChannel.maxMessageBytes - 1024
        var blob = Data(count: size)
        blob.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt32.self)
            for i in 0..<p.count { p[i] = UInt32(truncatingIfNeeded: i &* 2_654_435_761) }
        }
        let task = Task { try await session.readSessionBlob(sessionId: "s-1", hash: "big") }
        var reqID: Int?
        while reqID == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
            for msg in driver.takeSent() {
                guard case .data(let frame) = msg, case .json(let data)? = try hostChan.open(frame: frame) else { continue }
                let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
                if obj["type"] == .string("request"), let id = obj["id"]?.doubleValue { reqID = Int(id) }
            }
        }
        // Seal every frame up front, in wire order, so the measured window holds only the client's own copies.
        let head = try hostChan.seal(.json(Data(
            "{\"type\":\"response\",\"id\":\(reqID!),\"result\":{\"mimeType\":\"application/octet-stream\",\"bytes\":{\"$stream\":2,\"size\":\(size)}}}".utf8
        )))
        let chunk = SartoChannel.maxPayloadBytes - 4
        var frames: [Data] = []
        var offset = 0
        while offset < size {
            let end = min(offset + chunk, size)
            frames.append(contentsOf: try hostChan.seal(.bytes(stream: 2, data: blob.subdata(in: offset..<end))))
            offset = end
        }
        let endFrames = try hostChan.seal(.json(Data("{\"type\":\"stream.end\",\"stream\":2}".utf8)))

        let sampler = FootprintSampler()
        let clock = ContinuousClock()
        sampler.start()
        let base = FootprintSampler.current()
        let start = clock.now
        for f in head { driver.push(.data(f)) }
        for f in frames { driver.push(.data(f)) }
        for f in endFrames { driver.push(.data(f)) }
        let got = try await task.value
        let elapsed = clock.now - start
        let peak = sampler.stop()
        withExtendedLifetime(frames) {}
        #expect(got.data == blob)
        let growthMB = Double(peak > base ? peak - base : 0) / 1_048_576
        print("[bench] 32 MiB blob download: \(String(format: "%.1f", growthMB)) MB peak footprint growth, \(elapsed)")
        await session.close()
    }
}
