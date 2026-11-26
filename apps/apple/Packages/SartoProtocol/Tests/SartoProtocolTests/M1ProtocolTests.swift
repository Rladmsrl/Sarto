import Foundation
import Testing
@testable import SartoProtocol
#if os(macOS)
import Darwin
#endif

/// In-memory Noise_IK + SartoChannel transport connecting a Swift client to a mock Sarto host.
private actor LoopbackNoiseTransport: SartoPortTransport {
    private let channel: SartoChannel
    private let peerDeliver: @Sendable (Data) async -> Void
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(channel: SartoChannel, peerDeliver: @escaping @Sendable (Data) async -> Void) {
        self.channel = channel
        self.peerDeliver = peerDeliver
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func receiveSealed(_ sealedFrame: Data) throws {
        if case .json(let data)? = try channel.open(frame: sealedFrame) {
            continuation.yield(data)
        }
    }

    func sendJSON(_ data: Data) async throws {
        let frames = try channel.seal(.json(data))
        for frame in frames {
            await peerDeliver(frame)
        }
    }

    func close() async {
        continuation.finish()
    }
}

@Suite("M1 Pairing, ThreadReplica, RPC over Noise & Unix Socket Tests")
struct M1ProtocolTests {
    @Test("PairingCode encodes and decodes v1 direct and v2 relay payloads matching Sarto format")
    func pairingCodeRoundTrip() throws {
        let hostKey = Data((0..<32).map { UInt8($0) })
        let secret = Data((0..<32).map { UInt8(255 - $0) })
        let direct = PairingPayload(
            version: 1,
            hostKey: hostKey,
            secret: secret,
            addresses: [
                DirectAddress(host: "192.168.1.8", port: 47821),
                DirectAddress(host: "frp.example.com", port: 60021),
            ]
        )

        #expect(PairingCode.decode(try PairingCode.encode(direct)) == direct)

        let relayed = PairingPayload(
            version: 2,
            hostKey: hostKey,
            secret: secret,
            addresses: [DirectAddress(host: "10.0.0.5", port: 4567)],
            relay: PairingRelay(
                id: "aeiscmkbkfqxdamrugy4dupb6e",
                urls: ["https://relay.sarto.dev", "http://127.0.0.1:8787"]
            )
        )
        let encoded = try PairingCode.encode(relayed)
        #expect(PairingCode.decode(encoded) == relayed)
    }

    @Test("ThreadReplica applies streaming patches, tool permission updates, and session updates")
    func threadReplicaReducer() throws {
        let snapshot = SessionSnapshot(
            session: SessionView(
                id: "s-1",
                agentId: "claude-code",
                projectPath: "/tmp/demo",
                status: .ready,
                title: "Initial",
                usage: SessionUsage(used: 100_000, size: 512_000)
            ),
            entries: [
                .user(id: "e-1", text: "Run tests", at: 1000, approval: false),
            ],
            seq: 1,
            older: nil
        )

        var replica = ThreadReplica(snapshot: snapshot)
        #expect(replica.entries.count == 1)
        #expect(replica.pendingTools.isEmpty)

        // Add streaming agent reply + tool requesting permission
        let perm = PendingPermission(
            requestId: "req-1",
            options: [
                PermissionOption(id: "allow_once", name: "Allow once", kind: "allow_once"),
                PermissionOption(id: "reject", name: "Deny", kind: "reject_once"),
            ]
        )
        let batch2 = PatchBatch(
            sessionId: "s-1",
            seq: 2,
            patches: [
                .sessionUpdate(changes: ["status": .string("awaiting_permission")]),
                .entryAdd(.agent(id: "e-2", markdown: "Running ", streaming: true, at: 1001)),
                .entryAppendText(id: "e-2", text: "tests now..."),
                .entryAdd(.tool(ToolEntryData(
                    id: "t-1",
                    title: "swift test",
                    toolKind: "execute",
                    status: "pending",
                    permission: perm,
                    rawInput: "swift test"
                ))),
            ]
        )
        #expect(replica.apply(batch2) == true)
        #expect(replica.session.status == .awaitingPermission)
        #expect(replica.pendingTools.count == 1)
        if case .agent(_, let md, let streaming, _, _) = replica.byId["e-2"] {
            #expect(md == "Running tests now...")
            #expect(streaming == true)
        } else {
            Issue.record("Expected agent entry e-2")
        }

        // Resolve permission and finish streaming
        let batch3 = PatchBatch(
            sessionId: "s-1",
            seq: 3,
            patches: [
                .entryUpdate(id: "t-1", changes: ["permission": .null, "status": .string("completed")]),
                .entryUpdate(id: "e-2", changes: ["streaming": .bool(false)]),
                .sessionUpdate(changes: ["status": .string("ready")]),
            ]
        )
        #expect(replica.apply(batch3) == true)
        #expect(replica.pendingTools.isEmpty)
        #expect(replica.session.status == .ready)

        // Gap in sequence triggers resync signal (returns false)
        let gapBatch = PatchBatch(sessionId: "s-1", seq: 6, patches: [])
        #expect(replica.apply(gapBatch) == false)
    }

    @Test("SartoHostSession runs full RPC and streaming events over Noise_IK + SartoChannel")
    func hostSessionOverNoiseChannel() async throws {
        let clientKey = NoiseKeyPair()
        let hostKey = NoiseKeyPair()
        let clientHS = try NoiseHandshake(
            pattern: .ik,
            role: .initiator,
            staticKey: clientKey,
            remoteStaticKey: hostKey.publicKeyData
        )
        let hostHS = try NoiseHandshake(
            pattern: .ik,
            role: .responder,
            staticKey: hostKey,
            acceptRemoteStatic: { $0 == clientKey.publicKeyData }
        )
        _ = try hostHS.readMessage(try clientHS.writeMessage())
        _ = try clientHS.readMessage(try hostHS.writeMessage())

        let clientChannel = SartoChannel(ciphers: try clientHS.split())
        let hostChannel = SartoChannel(ciphers: try hostHS.split())

        // Wire bidirectional loopback actors
        final class Box: @unchecked Sendable {
            var clientTransport: LoopbackNoiseTransport?
        }
        let box = Box()

        let clientTransport = LoopbackNoiseTransport(channel: clientChannel) { sealed in
            // Host side decrypts request and responds with encrypted response + streaming patch event
            guard case .json(let reqData)? = try? hostChannel.open(frame: sealed),
                  let req = try? JSONDecoder().decode(JSONValue.self, from: reqData).objectValue,
                  let id = req["id"]?.doubleValue,
                  let method = req["method"]?.stringValue
            else { return }

            let result: JSONValue
            if method == "sessions.list" {
                let sample = [
                    SessionSummary(
                        id: "live-1",
                        agentId: "claude-code",
                        projectPath: "/Users/dev/app",
                        title: "Live Noise Session",
                        status: .running,
                        permissionCount: 0,
                        createdAt: 1000,
                        updatedAt: 2000
                    ),
                ]
                let data = try! JSONEncoder().encode(sample)
                result = try! JSONDecoder().decode(JSONValue.self, from: data)
            } else {
                result = .null
            }

            let resp = JSONValue.object([
                "type": .string("response"),
                "id": .number(id),
                "result": result,
            ])
            let respBytes = try! JSONEncoder().encode(resp)
            for frame in try! hostChannel.seal(.json(respBytes)) {
                try? await box.clientTransport?.receiveSealed(frame)
            }

            if method == "sessions.prompt" {
                let patch = PatchBatch(
                    sessionId: "live-1",
                    seq: 2,
                    patches: [.entryAppendText(id: "a-1", text: "Hello over Noise_IK!")]
                )
                let batchVal = try! JSONDecoder().decode(JSONValue.self, from: try! JSONEncoder().encode(patch))
                let evt = JSONValue.object([
                    "type": .string("event"),
                    "event": .object([
                        "type": .string("session.patches"),
                        "batch": batchVal,
                    ]),
                ])
                let evtBytes = try! JSONEncoder().encode(evt)
                for frame in try! hostChannel.seal(.json(evtBytes)) {
                    try? await box.clientTransport?.receiveSealed(frame)
                }
            }
        }
        box.clientTransport = clientTransport

        let session = SartoHostSession(transport: clientTransport)
        let list = try await session.listSessions()
        #expect(list.count == 1)
        #expect(list[0].id == "live-1")
        #expect(list[0].title == "Live Noise Session")

        // Send prompt and verify streaming patch event arrives over Noise_IK
        let eventTask = Task<HostEvent?, Never> {
            for await event in session.events {
                return event
            }
            return nil
        }
        try await session.sendPrompt(sessionId: "live-1", text: "Hi")
        let received = await eventTask.value
        if case .sessionPatches(let batch)? = received {
            #expect(batch.sessionId == "live-1")
            #expect(batch.patches == [.entryAppendText(id: "a-1", text: "Hello over Noise_IK!")])
        } else {
            Issue.record("Expected sessionPatches event")
        }

        await session.close()
    }

    #if os(macOS)
    private static func openTestUnixTransportPair(
        sockPath: String,
        serverHandler: @escaping @Sendable (Int32) -> Void
    ) throws -> UnixSocketPortTransport {
        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if serverFD >= 0 {
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(sockPath.utf8)
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in pathBytes.enumerated() { buf[i] = b }
                buf[pathBytes.count] = 0
            }
            let bindRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if bindRC == 0 && Darwin.listen(serverFD, 1) == 0 {
                do {
                    // POSIX AF_UNIX connect() completes against the kernel listen backlog immediately.
                    let transport = try UnixSocketPortTransport(socketPath: sockPath)
                    DispatchQueue.global().async {
                        let clientFD = Darwin.accept(serverFD, nil, nil)
                        Darwin.close(serverFD)
                        guard clientFD >= 0 else { return }
                        var noSigPipe: Int32 = 1
                        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                        defer { Darwin.close(clientFD) }
                        serverHandler(clientFD)
                    }
                    return transport
                } catch UnixSocketError.connectFailed(EPERM) {
                    Darwin.close(serverFD)
                } catch {
                    Darwin.close(serverFD)
                    throw error
                }
            } else {
                Darwin.close(serverFD)
            }
        }

        // Sandboxed CI environments blocking connect() on filesystem sockets still allow AF_UNIX socketpair.
        var pair: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw UnixSocketError.connectFailed(errno)
        }
        var noSigPipe: Int32 = 1
        setsockopt(pair[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let serverSide = pair[1]
        DispatchQueue.global().async {
            defer { Darwin.close(serverSide) }
            serverHandler(serverSide)
        }
        return UnixSocketPortTransport(connectedFD: pair[0])
    }

    @Test("UnixSocketPortTransport speaks Sarto 4-byte BE socket-port framing over AF_UNIX")
    func unixSocketPortRoundTrip() async throws {
        let sockPath = "/tmp/pk-test-\(UUID().uuidString.prefix(8)).sock"
        unlink(sockPath)
        defer { unlink(sockPath) }

        let transport = try Self.openTestUnixTransportPair(sockPath: sockPath) { clientFD in
            var header = [UInt8](repeating: 0, count: 4)
            _ = Darwin.read(clientFD, &header, 4)
            let len = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            var body = [UInt8](repeating: 0, count: len)
            _ = Darwin.read(clientFD, &body, len)

            let reply = Data("{\"type\":\"response\",\"id\":1,\"result\":{\"path\":\"/tmp/agent.sock\"}}".utf8)
            var outLen = UInt32(reply.count).bigEndian
            var outFrame = Data()
            withUnsafeBytes(of: &outLen) { outFrame.append(contentsOf: $0) }
            outFrame.append(reply)
            outFrame.withUnsafeBytes { raw in
                _ = Darwin.write(clientFD, raw.baseAddress!, outFrame.count)
            }
        }

        let session = SartoHostSession(transport: transport)
        let agentPath = try await session.daemonHostSocketPath(host: "agent")
        #expect(agentPath == "/tmp/agent.sock")
        await session.close()
    }

    @Test("UnixSocketPortTransport encodes and decodes WITH_BUFFERS binary framing matching socket-port.ts")
    func unixSocketPortBinaryBufferRoundTrip() async throws {
        let sockPath = "/tmp/pk-bin-\(UUID().uuidString.prefix(8)).sock"
        unlink(sockPath)
        defer { unlink(sockPath) }

        let payloadBytes = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD, 0xBE, 0xEF])

        let transport = try Self.openTestUnixTransportPair(sockPath: sockPath) { clientFD in
            func readAll(_ count: Int) -> Data {
                var buf = [UInt8](repeating: 0, count: count)
                var got = 0
                while got < count {
                    let n = Darwin.read(clientFD, &buf[got], count - got)
                    if n <= 0 { break }
                    got += n
                }
                return Data(buf.prefix(got))
            }

            let hdr = readAll(4)
            guard hdr.count == 4 else { return }
            let rawHdr = (UInt32(hdr[0]) << 24) | (UInt32(hdr[1]) << 16) | (UInt32(hdr[2]) << 8) | UInt32(hdr[3])
            let hasBuffers = (rawHdr & 0x8000_0000) != 0
            let bodyLen = Int(rawHdr & ~0x8000_0000)
            let body = readAll(bodyLen)
            guard body.count == bodyLen else { return }

            // Parse [jsonLen][json([msg, paths])][bufLen][bufBytes]
            let jsonLen = Int((UInt32(body[0]) << 24) | (UInt32(body[1]) << 16) | (UInt32(body[2]) << 8) | UInt32(body[3]))
            let wrappedJSON = Data(body[4..<(4 + jsonLen)])
            let bufOff = 4 + jsonLen
            let bufLen = Int((UInt32(body[bufOff]) << 24) | (UInt32(body[bufOff + 1]) << 16) | (UInt32(body[bufOff + 2]) << 8) | UInt32(body[bufOff + 3]))
            let receivedBuf = Data(body[(bufOff + 4)..<(bufOff + 4 + bufLen)])

            if hasBuffers, receivedBuf == payloadBytes,
               let arr = try? JSONDecoder().decode([JSONValue].self, from: wrappedJSON),
               arr.count == 2,
               let reqId = arr[0].objectValue?["id"]?.doubleValue {
                // Reply with a buffer-carrying response (as sessions.blob / attachments.read sends)
                let replyJSON = Data("[{\"type\":\"response\",\"id\":\(Int(reqId)),\"result\":{\"mimeType\":\"image/png\",\"bytes\":null}},[[\"result\",\"bytes\"]]]".utf8)
                var replyBody = Data()
                var jLen = UInt32(replyJSON.count).bigEndian
                withUnsafeBytes(of: &jLen) { replyBody.append(contentsOf: $0) }
                replyBody.append(replyJSON)
                var bLen = UInt32(receivedBuf.count).bigEndian
                withUnsafeBytes(of: &bLen) { replyBody.append(contentsOf: $0) }
                replyBody.append(receivedBuf)

                var outHdr = (UInt32(0x8000_0000) | UInt32(replyBody.count)).bigEndian
                var outFrame = Data()
                withUnsafeBytes(of: &outHdr) { outFrame.append(contentsOf: $0) }
                outFrame.append(replyBody)
                outFrame.withUnsafeBytes { raw in
                    _ = Darwin.write(clientFD, raw.baseAddress!, outFrame.count)
                }
            }
        }

        let session = SartoHostSession(transport: transport)
        let res = try await session.request(
            "attachments.add",
            params: .object([
                "source": .object(["bytes": .null, "mimeType": .string("image/png"), "name": .string("a.png")]),
                "thumb": .null,
            ]),
            buffers: [PortBuffer(path: ["params", "source", "bytes"], data: payloadBytes)]
        )
        #expect(res.objectValue?["mimeType"]?.stringValue == "image/png")
        let returnedB64 = res.objectValue?["bytes"]?.stringValue ?? ""
        #expect(Data(base64Encoded: returnedB64) == payloadBytes)
        await session.close()
    }
    #endif

    @Test("Prepared sessions, AgentOptions, HostEvent.agentOptions, boolean ConfigOptions, RunningWork & Worktree settings decode exact Sarto JSON")
    func newSessionAndAgentOptionsProtocolDecoding() throws {
        let preparedJSON = Data("""
        {
          "id": "prep-1",
          "agentId": "claude-code",
          "projectPath": "/tmp/proj",
          "scratch": false,
          "status": "ready",
          "permissionCount": 0,
          "createdAt": 1700000000000,
          "updatedAt": 1700000000100,
          "prepared": {
            "config": [
              {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "value": "sonnet-alias",
                "choices": [
                  { "value": "sonnet-4", "name": "Claude Sonnet 4", "modelId": "claude-sonnet-4" },
                  { "value": "sonnet-alias", "name": "Default", "shownAs": "sonnet-4" },
                  { "value": "sonnet-35", "name": "Sonnet 3.5", "older": true }
                ]
              },
              {
                "id": "fast_mode",
                "name": "Fast mode",
                "category": "model_config",
                "type": "boolean",
                "value": "default",
                "defaultValue": true,
                "indicator": true
              }
            ],
            "commands": [{ "name": "compact", "description": "Compact context" }],
            "notices": [{
              "reason": "replaced",
              "optionId": "model",
              "category": "model",
              "option": "Model",
              "type": "select",
              "wanted": "opus",
              "actual": "sonnet-4"
            }],
            "openedAt": 1700000000200
          }
        }
        """.utf8)

        let summary = try JSONDecoder().decode(SessionSummary.self, from: preparedJSON)
        #expect(summary.prepared?.config.count == 2)
        #expect(summary.prepared?.commands?.first?.name == "compact")
        #expect(summary.prepared?.notices.first?.reason == "replaced")
        let modelChoices = summary.prepared?.config.first?.choices ?? []
        #expect(modelChoices.first(where: { $0.value == "sonnet-alias" })?.shownAs == "sonnet-4")
        #expect(modelChoices.first(where: { $0.value == "sonnet-35" })?.older == true)
        #expect(summary.prepared?.config.last?.resolvedBoolValue == true)
        #expect(summary.prepared?.config.last?.indicator == true)

        let agentOptionsEnvelope = Data("""
        {
          "type": "event",
          "event": {
            "type": "agent.options",
            "options": {
              "agentId": "codex",
              "config": [
                { "id": "mode", "name": "Mode", "category": "mode", "type": "select", "value": "workspace-write" }
              ],
              "remembered": { "mode": "auto" },
              "startMode": "workspace-write",
              "observedAt": 1700000000300
            }
          }
        }
        """.utf8)
        let decodedEvent = HostEvent.decode(fromEnvelopeData: agentOptionsEnvelope)
        guard case .agentOptions(let opts)? = decodedEvent else {
            Issue.record("Expected HostEvent.agentOptions")
            return
        }
        #expect(opts.agentId == "codex")
        #expect(opts.remembered?["mode"] == .string("auto"))
        #expect(opts.startMode == "workspace-write")

        let workJSON = Data("""
        { "sessionId": "s1", "agentId": "claude-code", "title": "Build", "turn": false, "waiting": 1, "subagents": 2, "commands": 1 }
        """.utf8)
        let work = try JSONDecoder().decode(RunningWorkInfo.self, from: workJSON)
        #expect(work.waiting == 1)
        #expect(work.subagents == 2)

        let wtSettings = try JSONDecoder().decode(
            ProjectWorktreeSettingsInfo.self,
            from: Data("{\"branchTemplate\":\"feat/{slug}\",\"copy\":[\".env\"],\"setup\":null,\"waitForSetup\":true}".utf8)
        )
        #expect(wtSettings.branchTemplate == "feat/{slug}")
        #expect(wtSettings.copy == [".env"])
    }

    @Test("Decode all 15 extended Sarto ThreadEntry kinds, PendingElicitation, and entry.update merge")
    func extendedThreadEntriesAndUpdates() throws {
        let entriesJSON = Data("""
        [
          { "kind": "git", "id": "g1", "event": "commit", "commits": [{ "oid": "abc1234", "subject": "feat: add tests" }], "more": 0 },
          { "kind": "artifact", "id": "a1", "artifactId": "art_01", "title": "Architecture Spec", "action": "create", "version": 2, "writes": 2 },
          { "kind": "memory", "id": "m1", "layer": "global", "action": "remember", "memoryId": null, "title": "Prefer SwiftUI", "status": "pending", "undo": null, "draft": { "title": "Prefer SwiftUI", "description": "UI framework preference", "body": "Always use SwiftUI." } },
          { "kind": "settings_change", "id": "sc1", "asked": true, "expiresAt": 1700001000000, "outcome": null, "items": [{ "id": "appearance.color-mode", "place": "Appearance", "name": "Theme", "from": { "value": "light", "text": "Light" }, "to": { "value": "dark", "text": "Dark" } }] },
          { "kind": "browser_origin", "id": "bo1", "requestId": 7, "origin": "https://example.com", "decision": null },
          { "kind": "control_ask", "id": "ca1", "surface": "browser", "step": "sign_in", "target": "github.com", "reason": "Sign in to continue", "outcome": null },
          { "kind": "control_note", "id": "cn1", "surface": "browser", "event": "handed_back", "durationMs": 4200 },
          { "kind": "device_access", "id": "da1", "deviceId": "ios-sim:1", "deviceName": "iPhone 16", "decision": null },
          { "kind": "surface_access", "id": "sa1", "surface": "terminal", "targetId": "t1", "targetName": "Dev Server", "decision": null },
          { "kind": "computer_app", "id": "cp1", "requestId": 3, "appId": "com.apple.Safari", "appName": "Safari", "decision": null },
          { "kind": "computer_setup", "id": "cs1", "requestId": 4, "steps": ["accessibility"], "done": [], "outcome": null },
          { "kind": "project_mcp", "id": "pm1", "servers": [{ "name": "postgres", "target": "npx pg-mcp" }], "decision": null },
          { "kind": "project_hooks", "id": "ph1", "hooks": [{ "event": "PreToolUse", "target": "./check.sh" }], "decision": null },
          { "kind": "problem_report", "id": "pr1", "title": "IPC timeout", "details": "Timed out", "error": "ETIMEDOUT", "at": 1700000000000, "outcome": null },
          { "kind": "market_publish", "id": "mp1", "action": "publish", "item": { "name": "My Skill", "slug": "my-skill", "kind": "skill", "description": "Helper" }, "version": "1.0.0", "folder": "~/skills", "bytes": 1024, "outcome": null },
          { "kind": "tool", "id": "el1", "title": "MCP Input", "toolKind": "other", "status": "in_progress", "content": [], "locations": [], "elicitation": { "server": "linear", "kind": "form" }, "permission": { "requestId": "req-el", "options": [], "elicitation": { "kind": "form", "server": "linear", "message": "Enter project key", "fields": [{ "key": "project", "title": "Project", "required": true, "type": "text" }] } } }
        ]
        """.utf8)
        let decoded = try JSONDecoder().decode([ThreadEntry].self, from: entriesJSON)
        #expect(decoded.count == 16)
        for entry in decoded {
            if case .unknown(_, let k) = entry {
                Issue.record("Unexpected unknown entry kind: \(k)")
            }
        }
        guard case .tool(let elTool) = decoded.last else {
            Issue.record("Expected trailing tool entry with elicitation")
            return
        }
        #expect(elTool.permission?.elicitation?.server == "linear")
        #expect(elTool.permission?.elicitation?.fields.first?.key == "project")

        let snap = SessionSnapshot(
            session: SessionView(id: "s-ext", agentId: "claude-code", projectPath: "/tmp", status: .running),
            entries: decoded,
            seq: 1
        )
        var replica = ThreadReplica(snapshot: snap)
        let applied = replica.apply(PatchBatch(
            sessionId: "s-ext",
            seq: 2,
            from: 2,
            patches: [
                .entryUpdate(id: "m1", changes: ["status": .string("accepted"), "memoryId": .string("mem_9")]),
                .entryUpdate(id: "bo1", changes: ["decision": .string("allow")]),
                .entryUpdate(id: "a1", changes: ["version": .number(3), "writes": .number(3)]),
            ]
        ))
        #expect(applied)
        if case .memory(let m)? = replica.byId["m1"] {
            #expect(m.status == "accepted")
            #expect(m.memoryId == "mem_9")
        } else {
            Issue.record("Expected updated memory entry")
        }
        if case .browserOrigin(let b)? = replica.byId["bo1"] {
            #expect(b.decision == "allow")
        } else {
            Issue.record("Expected updated browserOrigin entry")
        }
        if case .artifact(let a)? = replica.byId["a1"] {
            #expect(a.version == 3)
            #expect(a.writes == 3)
        } else {
            Issue.record("Expected updated artifact entry")
        }
    }

    @Test("SettingsModels decode HostSettingsSnapshot, DaemonStatusInfo, MemoryOverviewInfo, and extended AgentStatusInfo")
    func settingsProtocolModelsDecode() throws {
        let hostJSON: JSONValue = .object([
            "general": .object([
                "sessionTitles": .bool(false),
                "lightModel": .object([
                    "mode": .string("pinned"),
                    "agentId": .string("claude-code"),
                    "model": .string("claude-haiku-4-5"),
                ]),
            ]),
            "disabledAgents": .array([.string("codex")]),
            "startModes": .object(["claude-code": .string("acceptEdits")]),
            "agents": .object(["claude-code": .object(["binaryPath": .string("/usr/local/bin/claude")])]),
            "proxy": .object(["mode": .string("custom"), "url": .string("http://127.0.0.1:7890"), "noProxy": .string("localhost")]),
            "terminal": .object(["shellPath": .string("/bin/zsh")]),
            "git": .object(["backgroundFetch": .bool(false), "worktreeRoot": .string("/tmp/wt")]),
            "idleSessions": .object(["release": .string("custom"), "outOfView": .number(45)]),
            "usage": .object(["fromComputer": .bool(false)]),
            "remote": .object(["name": .string("Studio-Mac"), "terminal": .bool(true)]),
        ])
        let snap = HostSettingsSnapshot.from(json: hostJSON)
        #expect(snap.sessionTitles == false)
        #expect(snap.lightModelMode == "pinned")
        #expect(snap.lightModelAgentId == "claude-code")
        #expect(snap.lightModelId == "claude-haiku-4-5")
        #expect(snap.disabledAgents == ["codex"])
        #expect(snap.startModes["claude-code"] == "acceptEdits")
        #expect(snap.agentBinaryPaths["claude-code"] == "/usr/local/bin/claude")
        #expect(snap.proxyMode == "custom")
        #expect(snap.proxyUrl == "http://127.0.0.1:7890")
        #expect(snap.terminalShellPath == "/bin/zsh")
        #expect(snap.gitBackgroundFetch == false)
        #expect(snap.gitWorktreeRoot == "/tmp/wt")
        #expect(snap.idleRelease == "custom")
        #expect(snap.idleOutOfView == 45)
        #expect(snap.usageFromComputer == false)
        #expect(snap.remoteTerminal == true)

        let daemonData = Data(#"""
        {"version":"0.9.0","build":"261125143512","channel":"beta","commit":"a1b2c3d","origin":"bundled","pid":1234,"startedAt":1700000000000,"stopping":false,"dataPath":"/tmp/kd","service":false,"hosts":{"agent":{"state":"running","pid":1235,"restarts":0},"terminal":{"state":"idle","pid":null,"restarts":0},"remote":{"state":"running","pid":1236,"restarts":1}},"connectedDevices":2}
        """#.utf8)
        let status = try JSONDecoder().decode(DaemonStatusInfo.self, from: daemonData)
        #expect(status.version == "0.9.0")
        #expect(status.build == "261125143512")
        #expect(status.channel == "beta")
        #expect(status.commit == "a1b2c3d")
        #expect(status.origin == "bundled")
        #expect(status.hosts.agent.state == "running")
        #expect(status.hosts.remote.restarts == 1)
        #expect(status.connectedDevices == 2)

        let memData = Data(#"""
        {"enabled":true,"global":[{"id":"pref-1","title":"No Artifacts","description":"Skip artifacts","body":"Details","createdAt":10,"updatedAt":20}],"projects":[{"path":"/repo/app","name":"app","count":1}],"importable":3}
        """#.utf8)
        let mem = try JSONDecoder().decode(MemoryOverviewInfo.self, from: memData)
        #expect(mem.enabled == true)
        #expect(mem.global.count == 1)
        #expect(mem.projects.first?.project == "/repo/app")
        #expect(mem.projects.first?.name == "app")
        #expect(mem.importable == 3)

        let agentData = Data(#"""
        {"id":"claude-code","name":"Claude Code","state":"ready","update":{"adapterVersion":"1.2.0","cliVersion":"2.1.4"},"cli":{"command":"claude","installed":{"path":"/opt/homebrew/bin/claude","version":"2.1.0","variable":null},"method":"brew","update":{"version":"2.1.4","command":"brew upgrade claude"}},"task":{"kind":"update","state":"failed","command":"brew upgrade claude","method":"brew","progress":[],"error":"Permission denied"}}
        """#.utf8)
        let agent = try JSONDecoder().decode(AgentStatusInfo.self, from: agentData)
        #expect(agent.update?.displayVersion == "2.1.4")
        #expect(agent.cli?.canUpdate == true)
        #expect(agent.cli?.update?.version == "2.1.4")
        #expect(agent.task?.isRunning == false)
        #expect(agent.task?.error == "Permission denied")

        let signInEvtData = Data(#"{"type":"event","event":{"type":"agents.signInLink","agentId":"codex","url":"https://auth.openai.com/authorize"}}"#.utf8)
        #expect(HostEvent.decode(fromEnvelopeData: signInEvtData) == .agentSignInLink(agentId: "codex", url: "https://auth.openai.com/authorize"))
    }
}
