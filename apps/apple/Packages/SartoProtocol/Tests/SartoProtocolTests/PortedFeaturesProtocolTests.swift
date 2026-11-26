import Foundation
import Testing
@testable import SartoProtocol

private actor PortedFeaturesRecordingTransport: SartoPortTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let reply: @Sendable (_ id: Double, _ method: String) -> JSONValue
    private(set) var requests: [[String: JSONValue]] = []

    init(reply: @escaping @Sendable (_ id: Double, _ method: String) -> JSONValue) {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
        self.reply = reply
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
        requests.append(request)
        let id = request["id"]?.doubleValue ?? 0
        let method = request["method"]?.stringValue ?? ""
        continuation.yield(try JSONEncoder().encode(reply(id, method)))
    }

    func close() async {
        continuation.finish()
    }
}

@Suite("Ported Features Protocol Contracts")
struct PortedFeaturesProtocolTests {
    @Test("ConfigOption decodes transient pending switch")
    func configOptionPending() throws {
        let json = """
        {
          "id": "mode",
          "name": "Mode",
          "category": "mode",
          "type": "select",
          "value": "auto",
          "pending": { "value": "full-access", "wait": "turn" }
        }
        """
        let opt = try JSONDecoder().decode(ConfigOption.self, from: Data(json.utf8))
        #expect(opt.pending == PendingConfig(value: "full-access", wait: .turn))
    }

    @Test("SessionView decodes and patches suggestion")
    func sessionSuggestionPatch() throws {
        let json = """
        {
          "id": "s1",
          "agentId": "claude-code",
          "projectPath": "/repo",
          "status": "ready",
          "suggestion": "Run the tests"
        }
        """
        let session = try JSONDecoder().decode(SessionView.self, from: Data(json.utf8))
        var thread = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1))
        #expect(thread.session.suggestion == "Run the tests")

        let ok1 = thread.apply(PatchBatch(
            sessionId: "s1",
            seq: 2,
            from: 1,
            patches: [.sessionUpdate(changes: ["suggestion": .string("Commit these changes")])]
        ))
        #expect(ok1)
        #expect(thread.session.suggestion == "Commit these changes")

        let ok2 = thread.apply(PatchBatch(
            sessionId: "s1",
            seq: 3,
            from: 2,
            patches: [.sessionUpdate(changes: ["suggestion": .null])]
        ))
        #expect(ok2)
        #expect(thread.session.suggestion == nil)
    }

    @Test("AgentCapabilitiesInfo decodes rewindFiles leniently")
    func rewindFilesCapability() throws {
        let withFiles = try JSONDecoder().decode(
            AgentCapabilitiesInfo.self,
            from: Data(#"{"rewind": true, "rewindFiles": true}"#.utf8)
        )
        #expect(withFiles.rewind == true)
        #expect(withFiles.rewindFiles == true)

        let olderHost = try JSONDecoder().decode(
            AgentCapabilitiesInfo.self,
            from: Data(#"{"rewind": true}"#.utf8)
        )
        #expect(olderHost.rewind == true)
        #expect(olderHost.rewindFiles == false)
    }

    @Test("ProjectFileList decodes ignored entries leniently")
    func projectFileListIgnored() throws {
        let withIgnored = try JSONDecoder().decode(
            ProjectFileList.self,
            from: Data(#"{"paths":["a.ts"],"folders":["src"],"ignored":[".env"],"ignoredFolders":["node_modules"],"truncated":false}"#.utf8)
        )
        #expect(withIgnored.ignored == [".env"])
        #expect(withIgnored.ignoredFolders == ["node_modules"])

        let older = try JSONDecoder().decode(
            ProjectFileList.self,
            from: Data(#"{"paths":["a.ts"],"folders":[],"truncated":false}"#.utf8)
        )
        #expect(older.ignored.isEmpty)
        #expect(older.ignoredFolders.isEmpty)

        let folder = try JSONDecoder().decode(
            ProjectFolderList.self,
            from: Data(#"{"files":["node_modules/pkg/index.js"],"folders":["node_modules/pkg"],"truncated":false}"#.utf8)
        )
        #expect(folder.paths == ["node_modules/pkg/index.js"])
        #expect(folder.folders == ["node_modules/pkg"])
    }

    @Test("BrowserPageSize parses named presets and custom dimensions")
    func browserPageSizeParse() {
        #expect(BrowserPageSize.parse(args: ["size": .string("desktop")]) == .success(.desktop))
        #expect(BrowserPageSize.parse(args: ["size": .string("tablet")]) == .success(.tablet))
        #expect(BrowserPageSize.parse(args: ["size": .string("phone")]) == .success(.phone))
        #expect(
            BrowserPageSize.parse(args: ["width": .number(1024), "height": .number(700)])
                == .success(BrowserPageSize(name: .custom, width: 1024, height: 700, mobile: false))
        )
        if case .failure(let err) = BrowserPageSize.parse(args: ["size": .string("phone"), "width": .number(400)]) {
            #expect(err.code == "invalid")
        } else {
            Issue.record("Expected failure when both size and width are given")
        }
        if case .failure(let err) = BrowserPageSize.parse(args: ["width": .number(100), "height": .number(600)]) {
            #expect(err.code == "invalid")
        } else {
            Issue.record("Expected failure for out-of-range width")
        }
    }

    @Test("HostEvent decodes host.load from envelope and JSONValue")
    func hostLoadEvent() throws {
        let envelope = """
        {
          "type": "event",
          "event": {
            "type": "host.load",
            "load": {
              "at": 1700000000000,
              "cpu": { "percent": 34.5, "cores": 10 },
              "memory": { "used": 8000000000, "total": 16000000000, "state": "ok" },
              "disk": { "name": "Macintosh HD", "free": 120000000000, "total": 500000000000 },
              "battery": { "percent": 82, "charging": false, "onBattery": true, "minutesLeft": 240 }
            }
          }
        }
        """
        let decoded = HostEvent.decode(fromEnvelopeData: Data(envelope.utf8))
        guard case .hostLoad(let load) = decoded else {
            Issue.record("Expected .hostLoad event")
            return
        }
        #expect(load.cpu.percent == 34.5)
        #expect(load.cpu.cores == 10)
        #expect(load.memory.state == "ok")
        #expect(load.disk?.name == "Macintosh HD")
        #expect(load.battery?.percent == 82)
        #expect(load.battery?.onBattery == true)
    }

    @Test("HostSettingsSnapshot decodes promptSuggestions with default true")
    func hostSettingsPromptSuggestions() {
        let def = HostSettingsSnapshot.from(json: .object(["general": .object([:])]))
        #expect(def.promptSuggestions == true)

        let off = HostSettingsSnapshot.from(json: .object(["general": .object(["promptSuggestions": .bool(false)])]))
        #expect(off.promptSuggestions == false)
    }

    @Test("AgentSetPinnedModelsParams encodes and sends agents.setPinnedModels")
    func setPinnedModelsContract() async throws {
        let params = AgentSetPinnedModelsParams(agentId: "claude-code", models: ["opus", "sonnet"])
        #expect(params.jsonValue == .object([
            "agentId": .string("claude-code"),
            "models": .array([.string("opus"), .string("sonnet")]),
        ]))
        let roundTrip = try JSONDecoder().decode(AgentSetPinnedModelsParams.self, from: JSONEncoder().encode(params))
        #expect(roundTrip == params)

        let transport = PortedFeaturesRecordingTransport { id, _ in
            .object(["type": .string("response"), "id": .number(id), "result": .null])
        }
        let session = SartoHostSession(transport: transport)
        try await session.setPinnedModels(agentId: "claude-code", models: ["opus", "sonnet"])
        try await session.setPinnedModels(agentId: "claude-code", models: [])
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0]["method"] == .string("agents.setPinnedModels"))
        #expect(requests[0]["params"] == params.jsonValue)
        #expect(requests[1]["params"] == .object([
            "agentId": .string("claude-code"),
            "models": .array([]),
        ]))
        await session.close()
    }

    @Test("HostEvent decodes files.changed from envelope data and JSONValue")
    func filesChangedEventDecode() {
        let envelope = Data(#"{"type":"event","event":{"type":"files.changed","projectPath":"/repo/app"}}"#.utf8)
        #expect(HostEvent.decode(fromEnvelopeData: envelope) == .filesChanged(projectPath: "/repo/app"))

        let value = JSONValue.object([
            "type": .string("files.changed"),
            "projectPath": .string("/repo/other"),
        ])
        #expect(HostEvent.decode(from: value) == .filesChanged(projectPath: "/repo/other"))
    }

    @Test("files.watch, files.unwatch, and files.preview send expected RPC shapes")
    func filesWatchAndPreviewRPCs() async throws {
        let transport = PortedFeaturesRecordingTransport { id, method in
            if method == "files.preview" {
                return .object([
                    "type": .string("response"),
                    "id": .number(id),
                    "result": .string("http://127.0.0.1:43210/index.html"),
                ])
            }
            return .object(["type": .string("response"), "id": .number(id), "result": .null])
        }
        let session = SartoHostSession(transport: transport)
        try await session.watchFiles(projectPath: "/repo")
        try await session.unwatchFiles(projectPath: "/repo")
        let url = try await session.previewFile(sessionId: "s1", path: "docs/index.html")
        #expect(url == "http://127.0.0.1:43210/index.html")

        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0]["method"] == .string("files.watch"))
        #expect(requests[0]["params"] == .object(["projectPath": .string("/repo")]))
        #expect(requests[1]["method"] == .string("files.unwatch"))
        #expect(requests[1]["params"] == .object(["projectPath": .string("/repo")]))
        #expect(requests[2]["method"] == .string("files.preview"))
        #expect(requests[2]["params"] == .object([
            "sessionId": .string("s1"),
            "path": .string("docs/index.html"),
        ]))
        await session.close()
    }

    @Test("SessionSummary decodes stillRunning when present, null, absent, or malformed")
    func sessionSummaryStillRunning() throws {
        let base = """
          "id": "s1",
          "agentId": "claude-code",
          "projectPath": "/repo",
          "status": "ready",
          "permissionCount": 0,
          "createdAt": 100,
          "updatedAt": 200
        """

        let presentJSON = "{\(base), \"stillRunning\": {\"commands\": 2, \"subagents\": 1, \"reportsBack\": true}}"
        let present = try JSONDecoder().decode(SessionSummary.self, from: Data(presentJSON.utf8))
        #expect(present.stillRunning == StillRunningInfo(commands: 2, subagents: 1, reportsBack: true))
        #expect(present.stillRunning?.hasWork == true)
        #expect(StillRunningInfo(commands: 0, subagents: 0, reportsBack: false).hasWork == false)

        let nullJSON = "{\(base), \"stillRunning\": null}"
        let nullSummary = try JSONDecoder().decode(SessionSummary.self, from: Data(nullJSON.utf8))
        #expect(nullSummary.stillRunning == nil)

        let absentJSON = "{\(base)}"
        let absentSummary = try JSONDecoder().decode(SessionSummary.self, from: Data(absentJSON.utf8))
        #expect(absentSummary.stillRunning == nil)

        let malformedJSON = "{\(base), \"stillRunning\": {\"commands\": \"bad\"}}"
        let malformedSummary = try JSONDecoder().decode(SessionSummary.self, from: Data(malformedJSON.utf8))
        #expect(malformedSummary.stillRunning == nil)
    }
}
