import Foundation
import Testing
@testable import SartoProtocol

private actor MockPortTransport: SartoPortTransport {
    private let handler: @Sendable (Data, [PortBuffer]) async -> [Data]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(handler: @escaping @Sendable (Data) async -> [Data]) {
        self.handler = { data, _ in await handler(data) }
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    init(bufferHandler: @escaping @Sendable (Data, [PortBuffer]) async -> [Data]) {
        self.handler = bufferHandler
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        try await sendJSON(data, buffers: [])
    }

    func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        let replies = await handler(data, buffers)
        for reply in replies {
            continuation.yield(reply)
        }
    }

    func close() async {
        continuation.finish()
    }
}

@Suite("M2 Git, Files, Terminal RPC, UnifiedDiff & ANSI Tests")
struct M2ProtocolTests {
    @Test("Control socket methods with no params send JSON null matching src/daemon/control.ts")
    func controlNullParamsCompliance() async throws {
        let transport = MockPortTransport { raw in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = req["id"]!.doubleValue!
            let method = req["method"]!.stringValue!
            let params = req["params"]!
            #expect(method == "terminal.get")
            #expect(params == .null)
            let reply = JSONValue.object([
                "type": .string("response"),
                "id": .number(id),
                "result": .object(["allowed": .bool(true)]),
            ])
            return [try! JSONEncoder().encode(reply)]
        }

        let session = SartoHostSession(transport: transport)
        let allowed = try await session.daemonTerminalAllowedGet()
        #expect(allowed == true)
        await session.close()
    }

    @Test("Git and Files RPC payloads decode exact Sarto host JSON shapes")
    func gitAndFilesRPCDecoding() async throws {
        let transport = MockPortTransport { raw in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = req["id"]!.doubleValue!
            let method = req["method"]!.stringValue!

            let resultJSON: String
            switch method {
            case "git.status":
                resultJSON = """
                {
                  "projectPath": "/Users/dev/Sarto",
                  "repo": { "root": "/Users/dev/Sarto", "gitDir": "/Users/dev/Sarto/.git" },
                  "head": { "branch": "feat/sarto-init", "oid": "abc1234", "detached": false },
                  "upstream": { "name": "origin/feat/sarto-init", "ahead": 2, "behind": 0 },
                  "changes": { "staged": 1, "unstaged": 2, "untracked": 1, "conflicted": 0, "insertions": 45, "deletions": 8 },
                  "commits": [{ "oid": "abc1234", "subject": "feat: add M2 workbench", "authoredAt": 1700000000000, "pushed": false }],
                  "defaultBranch": "main",
                  "updatedAt": 1700000001000,
                  "stale": false
                }
                """
            case "git.changes":
                resultJSON = """
                [
                  { "path": "apps/apple/macOS/MacWorkbenchView.swift", "oldPath": null, "status": "modified", "insertions": 40, "deletions": 8 },
                  { "path": "apps/apple/Shared/GitDiffView.swift", "oldPath": null, "status": "untracked", "insertions": null, "deletions": null }
                ]
                """
            case "git.fileDiff":
                resultJSON = """
                { "path": "README.md", "oldText": "line1\\nline2\\n", "newText": "line1\\nline2-mod\\nline3\\n", "binary": false, "tooLarge": false }
                """
            case "files.list":
                resultJSON = """
                { "paths": ["README.md", "src/daemon/main.ts"], "folders": ["docs"], "truncated": false }
                """
            case "files.read":
                resultJSON = """
                { "kind": "text", "path": "README.md", "size": 12, "text": "# Sarto", "version": "sha256-xyz", "editable": true }
                """
            case "files.agentFolder":
                resultJSON = "\"/Users/dev/.gemini/antigravity-cli/brain/conv-1\""
            case "files.readAgentFile":
                resultJSON = """
                { "kind": "text", "path": "/Users/dev/.gemini/antigravity-cli/brain/conv-1/plan.md", "size": 14, "text": "# Plan", "version": "sha256-plan", "editable": false }
                """
            default:
                resultJSON = "null"
            }

            let wrapped = "{\"type\":\"response\",\"id\":\(Int(id)),\"result\":\(resultJSON)}"
            return [Data(wrapped.utf8)]
        }

        let session = SartoHostSession(transport: transport)
        let status = try await session.gitStatus(projectPath: "/Users/dev/Sarto")
        #expect(status.head.branch == "feat/sarto-init")
        #expect(status.changes.totalChanged == 4)

        let changes = try await session.gitChanges(projectPath: "/Users/dev/Sarto")
        #expect(changes.count == 2)
        #expect(changes[0].status == .modified)
        #expect(changes[1].status == .untracked)

        let diff = try await session.gitFileDiff(projectPath: "/Users/dev/Sarto", path: "README.md")
        #expect(diff.binary == false)
        #expect(diff.newText?.contains("line3") == true)

        let files = try await session.filesList(projectPath: "/Users/dev/Sarto")
        #expect(files.paths.count == 2)

        let content = try await session.filesRead(projectPath: "/Users/dev/Sarto", path: "README.md")
        if case .text(let path, _, let text, let version, let editable) = content {
            #expect(path == "README.md")
            #expect(text == "# Sarto")
            #expect(version == "sha256-xyz")
            #expect(editable == true)
        } else {
            Issue.record("Expected text FileContent")
        }

        let agentFolder = try await session.filesAgentFolder(sessionId: "s-1")
        #expect(agentFolder == "/Users/dev/.gemini/antigravity-cli/brain/conv-1")

        let agentContent = try await session.filesReadAgentFile(
            sessionId: "s-1",
            path: "/Users/dev/.gemini/antigravity-cli/brain/conv-1/plan.md"
        )
        if case .text(let path, _, let text, let version, let editable) = agentContent {
            #expect(path == "/Users/dev/.gemini/antigravity-cli/brain/conv-1/plan.md")
            #expect(text == "# Plan")
            #expect(version == "sha256-plan")
            #expect(editable == false)
        } else {
            Issue.record("Expected text FileContent from files.readAgentFile")
        }

        await session.close()
    }

    @Test("SartoTerminalSession runs create/input RPCs and receives terminal.data events")
    func terminalSessionRPCAndEvents() async throws {
        let transport = MockPortTransport { raw in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = Int(req["id"]!.doubleValue!)
            let method = req["method"]!.stringValue!

            if method == "terminals.create" {
                let res = """
                {"type":"response","id":\(id),"result":{"id":"term-1","projectPath":"/tmp/p","sessionId":null,"shell":"zsh","title":"zsh","name":null,"busy":false,"exitCode":null,"createdAt":1000}}
                """
                return [Data(res.utf8)]
            }
            if method == "terminals.input" {
                let res = "{\"type\":\"response\",\"id\":\(id),\"result\":null}"
                let evt = "{\"type\":\"event\",\"event\":{\"type\":\"terminal.data\",\"id\":\"term-1\",\"data\":\"hello from pty\\r\\n\"}}"
                return [Data(res.utf8), Data(evt.utf8)]
            }
            return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
        }

        let term = SartoTerminalSession(transport: transport)
        let created = try await term.createTerminal(projectPath: "/tmp/p", cols: 80, rows: 24)
        #expect(created.id == "term-1")
        #expect(created.shell == "zsh")

        let evtTask = Task<TerminalEvent?, Never> {
            for await event in term.events {
                return event
            }
            return nil
        }

        try await term.sendInput(id: "term-1", data: "echo hello\n")
        let evt = await evtTask.value
        #expect(evt == .data(id: "term-1", data: "hello from pty\r\n"))
        await term.close()
    }

    @Test("UnifiedDiffEngine computes accurate hunks and insertion/deletion counts")
    func unifiedDiffComputation() {
        let old = "a\nb\nc\nd\ne\ng\nh\ni\n"
        let new = "a\nb\nc-edited\nd\ne\ng\nh\ni\nf\n"
        let diff = UnifiedDiffEngine.compute(oldText: old, newText: new, contextLines: 1)
        #expect(diff.insertions == 2)
        #expect(diff.deletions == 1)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].lines.contains { $0.kind == .deleted && $0.text == "c" })
        #expect(diff.hunks[0].lines.contains { $0.kind == .added && $0.text == "c-edited" })
        #expect(diff.hunks[1].lines.contains { $0.kind == .added && $0.text == "f" })
    }

    @Test("ANSITerminalParser strips OSC/CSI noise and preserves SGR colors")
    func ansiParsing() {
        let raw = "\u{001B}]0;zsh\u{0007}\u{001B}[1;32mPASS\u{001B}[0m test ok\r\n"
        let spans = ANSITerminalParser.parse(raw)
        #expect(spans.count == 2)
        #expect(spans[0].text == "PASS")
        #expect(spans[0].fgCode == 32)
        #expect(spans[0].isBold == true)
        #expect(spans[1].text == " test ok\n")
        #expect(spans[1].fgCode == nil)
        #expect(spans[1].isBold == false)
    }

    @Test("AgentStatusInfo decodes live Sarto limits/version fields and HostEvent decodes control.ts pairing key")
    func liveAgentStatusAndPairingEventDecoding() throws {
        let agyJSON = """
        {
          "id": "antigravity",
          "name": "Google Antigravity",
          "harnessId": "antigravity",
          "state": "available",
          "registered": true,
          "disabled": false,
          "hidden": false,
          "version": "1.5.14",
          "signIn": "signed-in",
          "binaryPath": "/Users/dev/.local/bin/agy",
          "account": { "kind": "account", "label": "Antigravity Pro", "email": null, "tier": "pro" },
          "limits": [
            {
              "window": "five_hour",
              "label": "Gemini 3.8 Flash",
              "usedPercent": 12.5,
              "resetsAt": 1700003600000,
              "state": "ok",
              "observedAt": 1700000000000,
              "models": ["Gemini 3.8 Flash"]
            }
          ]
        }
        """
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(agyJSON.utf8))
        #expect(status.id == "antigravity")
        #expect(status.version == "1.5.14")
        #expect(status.registered == true)
        #expect(status.limits?.count == 1)
        #expect(status.planLimits?.first?.usedPercent == 12.5)
        #expect(status.planLimits?.first?.models == ["Gemini 3.8 Flash"])

        let pairingJSON = """
        {
          "type": "pairing",
          "codeId": 7,
          "pairing": { "state": "waiting", "link": "sarto://pair#test" }
        }
        """
        let val = try JSONDecoder().decode(JSONValue.self, from: Data(pairingJSON.utf8))
        let event = HostEvent.decode(from: val)
        if case .pairing(let cid, let stateVal) = event {
            #expect(cid == 7)
            #expect(stateVal.objectValue?["state"]?.stringValue == "waiting")
            #expect(stateVal.objectValue?["link"]?.stringValue == "sarto://pair#test")
        } else {
            Issue.record("Expected .pairing HostEvent")
        }
    }

    @Test("AttachmentInfo, ContentRef, UserContent, and attachments.add binary RPCs conform to Sarto wire contract")
    func attachmentsProtocolAndBinaryRPC() async throws {
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02])
        let thumbURL = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="

        let transport = MockPortTransport { raw, buffers in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = Int(req["id"]!.doubleValue!)
            let method = req["method"]!.stringValue!

            if method == "attachments.add" {
                let params = req["params"]!.objectValue!
                let source = params["source"]!.objectValue!
                #expect(source["bytes"] == .null)
                #expect(source["mimeType"]?.stringValue == "image/png")
                #expect(source["name"]?.stringValue == "shot.png")
                #expect(params["thumb"]?.stringValue == thumbURL)
                #expect(buffers.count == 1)
                #expect(buffers[0].path == ["params", "source", "bytes"])
                #expect(buffers[0].data == pngBytes)

                let res = """
                {
                  "type": "response",
                  "id": \(id),
                  "result": {
                    "id": "att-1",
                    "type": "image",
                    "name": "shot.png",
                    "uri": null,
                    "mimeType": "image/png",
                    "size": 10,
                    "sent": null,
                    "thumb": "\(thumbURL)",
                    "blob": null
                  }
                }
                """
                return [Data(res.utf8)]
            }

            if method == "sessions.prompt" {
                let params = req["params"]!.objectValue!
                let items = params["content"]!.arrayValue!
                #expect(items.count == 2)
                #expect(items[0].objectValue?["type"]?.stringValue == "text")
                #expect(items[1].objectValue?["type"]?.stringValue == "ref")
                let ref = items[1].objectValue?["ref"]?.objectValue
                #expect(ref?["kind"]?.stringValue == "attachment")
                #expect(ref?["attachment"]?.objectValue?["id"]?.stringValue == "att-1")
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
            }

            if method == "sessions.blob" {
                let b64 = pngBytes.base64EncodedString()
                let res = """
                {"type":"response","id":\(id),"result":{"mimeType":"image/png","bytes":"\(b64)"}}
                """
                return [Data(res.utf8)]
            }

            return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
        }

        let session = SartoHostSession(transport: transport)
        let added = try await session.addAttachment(
            bytes: pngBytes,
            mimeType: "image/png",
            name: "shot.png",
            thumb: thumbURL
        )
        #expect(added.id == "att-1")
        #expect(added.type == "image")
        #expect(added.thumb == thumbURL)

        try await session.sendPrompt(sessionId: "s-1", content: [
            .text("Inspect this UI screenshot"),
            .ref(.attachment(added)),
        ])

        let blob = try await session.readSessionBlob(sessionId: "s-1", hash: "abc123")
        #expect(blob.mimeType == "image/png")
        #expect(blob.data == pngBytes)

        // Verify ThreadEntry.user preserves attachment content & updates via entry.update patch
        let userEntryJSON = """
        {
          "kind": "user",
          "id": "u-1",
          "content": [
            { "type": "text", "text": "Check image" },
            {
              "type": "ref",
              "ref": {
                "kind": "attachment",
                "attachment": {
                  "id": "att-1",
                  "type": "image",
                  "name": "shot.png",
                  "uri": null,
                  "mimeType": "image/png",
                  "size": 10,
                  "sent": "image",
                  "thumb": "\(thumbURL)",
                  "blob": "deadbeef"
                }
              }
            }
          ],
          "at": 1000
        }
        """
        let decoded = try JSONDecoder().decode(ThreadEntry.self, from: Data(userEntryJSON.utf8))
        if case .user(let uid, let text, let content, _, _, _) = decoded {
            #expect(uid == "u-1")
            #expect(text == "Check image")
            #expect(content.count == 2)
            if case .ref(.attachment(let att)) = content[1] {
                #expect(att.sent == "image")
                #expect(att.blob == "deadbeef")
            } else {
                Issue.record("Expected attachment ref in user content")
            }
        } else {
            Issue.record("Expected user ThreadEntry")
        }

        // Verify ToolEntry decodes locations & label and ThreadReplica updates turnStartedAt
        let toolJSON = """
        {
          "kind": "tool",
          "id": "t-loc",
          "title": "Read file",
          "toolKind": "read",
          "status": "completed",
          "content": [],
          "locations": [{ "path": "/repo/src/main.swift", "line": 42 }],
          "label": "Inspecting main entry"
        }
        """
        let decodedTool = try JSONDecoder().decode(ThreadEntry.self, from: Data(toolJSON.utf8))
        if case .tool(let data) = decodedTool {
            #expect(data.locations.count == 1)
            #expect(data.locations[0].path == "/repo/src/main.swift")
            #expect(data.locations[0].line == 42)
            #expect(data.label == "Inspecting main entry")
        } else {
            Issue.record("Expected tool ThreadEntry with locations and label")
        }

        var replica = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s-1", agentId: "antigravity", projectPath: "/repo", status: .running),
            entries: [decodedTool],
            seq: 1
        ))
        _ = replica.apply(PatchBatch(
            sessionId: "s-1",
            seq: 2,
            patches: [.sessionUpdate(changes: ["turnStartedAt": .number(1700000123456)])]
        ))
        #expect(replica.session.turnStartedAt == 1700000123456)

        await session.close()
    }

    @Test("Sarto parity models & RPCs: pagination, queue, subagent, takeover, fork, switchAgent, snapshot")
    func sartoParityModelsAndRPCs() async throws {
        // 1. Decode new ThreadEntry variants & SessionView queue/commands
        let subagentJSON = #"{"kind":"subagent","id":"sub-1","sessionId":"child-42"}"#
        if case .subagent(let id, let sid) = try JSONDecoder().decode(ThreadEntry.self, from: Data(subagentJSON.utf8)) {
            #expect(id == "sub-1")
            #expect(sid == "child-42")
        } else {
            Issue.record("Expected .subagent")
        }

        let takeoverJSON = #"{"kind":"takeover","id":"tk-1","agentId":"claude-code","turns":5,"omitted":2,"carried":"summary","summarize":true,"after":null}"#
        if case .takeover(let id, let agentId, let turns, let omitted, let carried, let summarize) =
            try JSONDecoder().decode(ThreadEntry.self, from: Data(takeoverJSON.utf8)) {
            #expect(id == "tk-1")
            #expect(agentId == "claude-code")
            #expect(turns == 5)
            #expect(omitted == 2)
            #expect(carried == "summary")
            #expect(summarize == true)
        } else {
            Issue.record("Expected .takeover")
        }

        let noticeJSON = #"{"kind":"notice","id":"n-1","severity":"error","title":"Turn failed","description":"boom","cause":"turn_failed","model":"claude-sonnet"}"#
        if case .notice(let id, let sev, let title, let desc, let cause, let model) =
            try JSONDecoder().decode(ThreadEntry.self, from: Data(noticeJSON.utf8)) {
            #expect(id == "n-1")
            #expect(sev == "error")
            #expect(title == "Turn failed")
            #expect(desc == "boom")
            #expect(cause == "turn_failed")
            #expect(model == "claude-sonnet")
        } else {
            Issue.record("Expected .notice with cause & model")
        }

        // 2. ThreadReplica prependOlderPage & sessionUpdate for queue/commands
        var replica = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s-1", agentId: "antigravity", projectPath: "/repo", status: .running),
            entries: [.user(id: "u-2", text: "Latest", at: 2000, approval: false)],
            seq: 1,
            older: 10
        ))
        #expect(replica.older == 10)
        replica.prependOlderPage(OlderPageInfo(
            entries: [
                .user(id: "u-1", text: "Older", at: 1000, approval: false),
                .user(id: "u-2", text: "Latest", at: 2000, approval: false),
            ],
            older: nil
        ))
        #expect(replica.order == ["u-1", "u-2"])
        #expect(replica.older == nil)

        let patchJSON = """
        {
          "sessionId": "s-1",
          "seq": 2,
          "patches": [
            {
              "op": "session.update",
              "changes": {
                "queue": [
                  { "id": "q-1", "content": [{ "type": "text", "text": "Follow up" }], "at": 2500 }
                ],
                "queuePaused": true,
                "commands": [
                  { "name": "review", "description": "Review diff", "inputHint": "<path>" }
                ]
              }
            }
          ]
        }
        """
        let batch = try JSONDecoder().decode(PatchBatch.self, from: Data(patchJSON.utf8))
        #expect(replica.apply(batch) == true)
        #expect(replica.session.queue.count == 1)
        #expect(replica.session.queue[0].textBody == "Follow up")
        #expect(replica.session.queuePaused == true)
        #expect(replica.session.commands.first?.name == "review")

        // 3. RPC contract checks: sessions.queue, sessions.page, sessions.fork, sessions.switchAgent, sessions.snapshot
        let transport = MockPortTransport { raw in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = Int(req["id"]!.doubleValue!)
            let method = req["method"]!.stringValue!
            let params = req["params"]!.objectValue!

            switch method {
            case "sessions.queue":
                #expect(params["sessionId"]?.stringValue == "s-1")
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":{\"itemId\":\"q-99\"}}".utf8)]
            case "sessions.page":
                #expect(params["before"]?.doubleValue == 10)
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":{\"entries\":[],\"older\":null}}".utf8)]
            case "sessions.fork":
                #expect(params["entryId"]?.stringValue == "a-1")
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":{\"id\":\"s-fork\",\"agentId\":\"antigravity\",\"projectPath\":\"/repo\",\"status\":\"ready\",\"permissionCount\":0,\"createdAt\":1,\"updatedAt\":2}}".utf8)]
            case "sessions.switchAgent":
                #expect(params["agentId"]?.stringValue == "claude-code")
                #expect(params["summarize"]?.boolValue == true)
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
            case "sessions.snapshot":
                #expect(params["sessionId"]?.stringValue == "s-2")
                #expect(params["from"]?.doubleValue == 0)
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":{\"session\":{\"id\":\"s-2\",\"agentId\":\"codex\",\"projectPath\":\"/repo\",\"status\":\"ready\"},\"entries\":[],\"seq\":1}}".utf8)]
            case "sessions.show":
                #expect(params["sessionIds"]?.arrayValue?.compactMap(\.stringValue) == ["s-1"])
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
            default:
                return [Data("{\"type\":\"response\",\"id\":\(id),\"result\":null}".utf8)]
            }
        }

        let host = SartoHostSession(transport: transport)
        try await host.showSessions(["s-1"])
        let qid = try await host.queuePrompt(sessionId: "s-1", content: [.text("Next step")])
        #expect(qid == "q-99")
        let page = try await host.loadSessionPage(sessionId: "s-1", before: 10)
        #expect(page.older == nil)
        let forked = try await host.forkSession(sessionId: "s-1", entryId: "a-1")
        #expect(forked.id == "s-fork")
        try await host.switchAgent(sessionId: "s-1", agentId: "claude-code", content: [.text("Continue")], summarize: true)
        let snap = try await host.sessionSnapshot(sessionId: "s-2", from: 0)
        #expect(snap.session.id == "s-2")

        // Verify PortRPCError exposes readable localizedDescription instead of "error 1"
        let err = PortRPCError(code: "agent_unavailable", message: "Antigravity does not support forking")
        #expect(err.localizedDescription == "Antigravity does not support forking")

        // Verify AgentCapabilitiesInfo & BackgroundTaskInfo decoding
        let capJSON = #"{"id":"claude-code","name":"Claude Code","state":"ready","capabilities":{"forkSession":true,"forkAtMessage":true,"steering":true}}"#
        let ag = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(capJSON.utf8))
        #expect(ag.capabilities?.forkSession == true)
        #expect(ag.capabilities?.forkAtMessage == true)
        #expect(ag.capabilities?.steering == true)

        let bgPatchJSON = """
        {
          "sessionId": "s-1",
          "seq": 3,
          "patches": [
            {
              "op": "session.update",
              "changes": {
                "background": [
                  { "id": "bg-1", "kind": "shell", "title": "xcodebuild", "command": "xcodebuild build", "status": "running", "startedAt": 3000, "endedAt": null, "summary": null }
                ]
              }
            }
          ]
        }
        """
        let bgBatch = try JSONDecoder().decode(PatchBatch.self, from: Data(bgPatchJSON.utf8))
        #expect(replica.apply(bgBatch) == true)
        #expect(replica.session.background.count == 1)
        #expect(replica.session.background[0].title == "xcodebuild")
        #expect(replica.session.background[0].status == "running")

        await host.close()
    }
}
