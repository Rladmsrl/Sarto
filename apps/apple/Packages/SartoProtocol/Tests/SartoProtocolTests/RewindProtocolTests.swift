import Foundation
import Testing
@testable import SartoProtocol

private actor RewindMockTransport: SartoPortTransport {
    private let handler: @Sendable (Data) async -> [Data]
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(handler: @escaping @Sendable (Data) async -> [Data]) {
        self.handler = handler
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        try await sendJSON(data, buffers: [])
    }

    func sendJSON(_ data: Data, buffers: [PortBuffer]) async throws {
        for reply in await handler(data) {
            continuation.yield(reply)
        }
    }

    func close() async {
        continuation.finish()
    }
}

/// The params each request carried, by method.
private actor RequestLog {
    private(set) var params: [String: JSONValue] = [:]

    func record(_ method: String, _ value: JSONValue) {
        params[method] = value
    }
}

@Suite("Edit from a sent message: sessions.rewind, sessions.putBack and the rewind fields")
struct RewindProtocolTests {
    /// A `sessions.open` result shaped like `SessionSnapshot` in src/shared/thread.ts after an edit.
    private static let snapshotJSON = """
    {
      "session": {
        "id": "s-1",
        "agentId": "claude-code",
        "projectPath": "/repo",
        "status": "ready",
        "config": [],
        "commands": [],
        "createdAt": 1,
        "updatedAt": 2,
        "background": [],
        "queue": [],
        "queuePaused": false,
        "rewound": { "turns": 2 },
        "noRewind": true
      },
      "entries": [
        { "kind": "user", "id": "e1", "content": [{ "type": "text", "text": "Plan the work" }], "at": 1000, "agentRef": "uuid-1" },
        { "kind": "agent", "id": "e2", "markdown": "Planned.", "streaming": false },
        { "kind": "turn_end", "id": "e3", "stopReason": "end_turn", "durationMs": 1200, "after": "e2", "used": 18000 },
        { "kind": "user", "id": "e4", "content": [{ "type": "text", "text": "Step one" }], "steered": true },
        { "kind": "user", "id": "e5", "content": [{ "type": "text", "text": "From the other one" }], "from": { "sessionId": "s-2", "title": "Other" } },
        { "kind": "user", "id": "e6", "content": [{ "type": "text", "text": "Workflow step" }], "sarto": true },
        { "kind": "user", "id": "e7", "content": [{ "type": "text", "text": "Approved" }], "approval": true },
        { "kind": "user", "id": "e8", "content": [{ "type": "text", "text": "Older host" }] },
        { "kind": "turn_end", "id": "e9", "stopReason": "cancelled", "durationMs": 40 }
      ],
      "seq": 7,
      "older": null,
      "plan": null
    }
    """

    @Test("A snapshot decodes rewound, noRewind and each entry's agentRef, from, sarto and used")
    func snapshotDecodesRewindFields() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(Self.snapshotJSON.utf8))
        #expect(snapshot.session.rewound == RewoundView(turns: 2))
        #expect(snapshot.session.noRewind == true)
        #expect(snapshot.entries.count == 9)

        let replica = ThreadReplica(snapshot: snapshot)
        #expect(replica.entryExtras["e1"] == ThreadEntryExtras(agentRef: "uuid-1"))
        #expect(replica.entryExtras["e3"] == ThreadEntryExtras(used: 18000))
        #expect(replica.entryExtras["e5"] == ThreadEntryExtras(from: FromSession(sessionId: "s-2", title: "Other")))
        #expect(replica.entryExtras["e5"]?.fromSession == true)
        #expect(replica.entryExtras["e6"] == ThreadEntryExtras(sarto: true))
        // An older host sends none of them: the entry still decodes, with no extras.
        #expect(replica.entryExtras["e8"] == nil)
        #expect(replica.entryExtras["e9"] == nil)
        if case .user(let id, let text, _, _, let approval, let steered)? = replica.byId["e8"] {
            #expect(id == "e8")
            #expect(text == "Older host")
            #expect(!approval && !steered)
        } else {
            Issue.record("Expected e8 to decode as a user entry")
        }
    }

    @Test("A session without the fields, or with them null, has none")
    func sessionViewWithoutRewindFields() throws {
        let absent = #"{"id":"s-1","agentId":"codex","projectPath":"/repo","status":"ready"}"#
        let view = try JSONDecoder().decode(SessionView.self, from: Data(absent.utf8))
        #expect(view.rewound == nil)
        #expect(view.noRewind == nil)

        let nulls = #"{"id":"s-1","agentId":"codex","projectPath":"/repo","status":"ready","rewound":null}"#
        #expect(try JSONDecoder().decode(SessionView.self, from: Data(nulls.utf8)).rewound == nil)

        let encoded = try JSONEncoder().encode(SessionView(
            id: "s-1", agentId: "codex", projectPath: "/repo", status: .ready,
            rewound: RewoundView(turns: 3), noRewind: true
        ))
        let back = try JSONDecoder().decode(SessionView.self, from: encoded)
        #expect(back.rewound?.turns == 3)
        #expect(back.noRewind == true)
    }

    @Test("Only the user's own prompts after the latest agent switch can be edited from")
    func editableMessagesFollowTheRules() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(Self.snapshotJSON.utf8))
        let replica = ThreadReplica(snapshot: snapshot)
        #expect(replica.editableEntryIDs == ["e1", "e8"])
        #expect(replica.canEditFrom("e1"))
        #expect(!replica.canEditFrom("e4")) // steered into a running turn
        #expect(!replica.canEditFrom("e5")) // another session's agent sent it
        #expect(!replica.canEditFrom("e6")) // Sarto wrote it
        #expect(!replica.canEditFrom("e7")) // a card's answer
        #expect(!replica.canEditFrom("missing"))

        // Every message from e1 on that opened a turn: e1, e5, e6, e7 and e8, not the steered e4.
        #expect(replica.turnsFrom(0) == 5)
        #expect(replica.turnsFrom(7) == 1)
        // The context as the turn before ended, 0 with none before, nil when it did not say.
        #expect(replica.usedAtEnd(before: 0) == 0)
        #expect(replica.usedAtEnd(before: 4) == 18000)
        #expect(replica.usedAtEnd(before: 9) == nil)

        let withSwitch = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s-1", agentId: "codex", projectPath: "/repo", status: .ready),
            entries: [
                .user(id: "u1", text: "Before", at: nil, approval: false),
                .takeover(id: "t1", agentId: "codex", turns: 1, omitted: 0, carried: "", summarize: nil),
                .user(id: "u2", text: "After", at: nil, approval: false),
            ],
            seq: 1
        ))
        #expect(withSwitch.lastSwitchIndex == 1)
        #expect(withSwitch.editableEntryIDs == ["u2"])
        #expect(!withSwitch.canEditFrom("u1"))
    }

    @Test("An edit's facts count turns, changed files, commands, the running turn and tasks")
    func rewindFacts() throws {
        let edit = ToolEntryData(
            id: "t1", title: "Edit", toolKind: "edit", status: "completed",
            content: [.diff(path: "/repo/a.swift", oldText: "a", newText: "b")],
            locations: [ToolLocation(path: "/repo/b.swift")]
        )
        let run = ToolEntryData(id: "t2", title: "Run", toolKind: "execute", status: "completed")
        let failedEdit = ToolEntryData(
            id: "t3", title: "Edit", toolKind: "edit", status: "failed",
            locations: [ToolLocation(path: "/repo/c.swift")]
        )
        var session = SessionView(id: "s-1", agentId: "claude-code", projectPath: "/repo", status: .running)
        session.background = [
            BackgroundTaskInfo(id: "b1", kind: "shell", title: "watch", status: "running", startedAt: 1),
            BackgroundTaskInfo(id: "b2", kind: "shell", title: "done", status: "completed", startedAt: 1),
        ]
        let replica = ThreadReplica(snapshot: SessionSnapshot(
            session: session,
            entries: [
                .user(id: "u1", text: "First", at: nil, approval: false),
                .turnEnd(id: "te1", stopReason: "end_turn", durationMs: 10),
                .user(id: "u2", text: "Second", at: nil, approval: false),
                .tool(edit),
                .tool(run),
                .tool(failedEdit),
            ],
            seq: 1,
            entryExtras: ["te1": ThreadEntryExtras(used: 5000)]
        ))
        let facts = try #require(replica.rewindFacts(from: "u2"))
        #expect(facts == RewindFacts(turns: 1, files: 2, commands: true, running: true, tasks: 1, kept: 5000))
        #expect(facts.needsConfirmation)

        let quiet = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s-1", agentId: "claude-code", projectPath: "/repo", status: .ready),
            entries: [.user(id: "u1", text: "Only", at: nil, approval: false)],
            seq: 1
        ))
        let only = try #require(quiet.rewindFacts(from: "u1"))
        #expect(only == RewindFacts(turns: 1, files: 0, commands: false, running: false, tasks: 0, kept: 0))
        #expect(!only.needsConfirmation)
        #expect(quiet.rewindFacts(from: "missing") == nil)
    }

    @Test("Patches keep rewound, noRewind and the entries' extras, on the live and the Codable path")
    func patchesTrackRewindFields() throws {
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(Self.snapshotJSON.utf8))
        // The patches an edit from e8 and the next send emit, as src/agent-host/sessions.ts does.
        let batchJSON = """
        {
          "sessionId": "s-1",
          "seq": 8,
          "patches": [
            { "op": "thread.truncate", "id": "e8" },
            { "op": "session.update", "changes": { "rewound": { "turns": 3 }, "error": null, "updatedAt": 9 } },
            { "op": "entry.add", "entry": { "kind": "user", "id": "e10", "content": [{ "type": "text", "text": "Edited" }], "sarto": true } },
            { "op": "entry.add", "entry": { "kind": "user", "id": "e11", "content": [{ "type": "text", "text": "Next" }] } },
            { "op": "entry.update", "id": "e11", "changes": { "agentRef": "uuid-11" } },
            { "op": "entry.add", "entry": { "kind": "turn_end", "id": "e12", "stopReason": "end_turn", "durationMs": 5, "used": 900 } }
          ]
        }
        """
        let envelope = #"{"type":"event","event":{"type":"session.patches","batch":\#(batchJSON)}}"#
        guard case .sessionPatches(let live)? = HostEvent.decode(fromEnvelopeData: Data(envelope.utf8)) else {
            Issue.record("Expected session.patches")
            return
        }
        let codable = try JSONDecoder().decode(PatchBatch.self, from: Data(batchJSON.utf8))
        #expect(live.entryExtras == codable.entryExtras)
        #expect(live.patches == codable.patches)

        for batch in [live, codable] {
            var replica = ThreadReplica(snapshot: snapshot)
            let appliedBatch = replica.apply(batch)
            #expect(appliedBatch)
            #expect(replica.session.rewound == RewoundView(turns: 3))
            #expect(replica.session.noRewind == true)
            #expect(replica.order == ["e1", "e2", "e3", "e4", "e5", "e6", "e7", "e10", "e11", "e12"])
            #expect(replica.entryExtras["e9"] == nil)
            #expect(replica.entryExtras["e10"] == ThreadEntryExtras(sarto: true))
            #expect(replica.entryExtras["e11"] == ThreadEntryExtras(agentRef: "uuid-11"))
            #expect(replica.entryExtras["e12"] == ThreadEntryExtras(used: 900))
            #expect(replica.editableEntryIDs == ["e1", "e11"])

            // The next send cuts the agent's session: the host clears `rewound`.
            let cleared = PatchBatch(sessionId: "s-1", seq: 9, patches: [
                .sessionUpdate(changes: ["rewound": .null, "noRewind": .null]),
            ])
            let appliedCleared = replica.apply(cleared)
            #expect(appliedCleared)
            #expect(replica.session.rewound == nil)
            #expect(replica.session.noRewind == nil)

            let reset = PatchBatch(sessionId: "s-1", seq: 10, patches: [.threadReset])
            let appliedReset = replica.apply(reset)
            #expect(appliedReset)
            #expect(replica.entryExtras.isEmpty)
        }
    }

    @Test("An older page brings its entries' extras")
    func olderPageCarriesExtras() throws {
        let pageJSON = """
        { "entries": [
            { "kind": "user", "id": "e0", "content": [{ "type": "text", "text": "Earlier" }], "agentRef": "turn-0" },
            { "kind": "turn_end", "id": "e0b", "stopReason": "end_turn", "durationMs": 3, "used": 1200 }
          ], "older": null }
        """
        let page = try JSONDecoder().decode(OlderPageInfo.self, from: Data(pageJSON.utf8))
        #expect(page.entryExtras["e0"] == ThreadEntryExtras(agentRef: "turn-0"))
        var replica = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s-1", agentId: "codex", projectPath: "/repo", status: .ready),
            entries: [.user(id: "e1", text: "Later", at: nil, approval: false)],
            seq: 1,
            older: 2
        ))
        replica.prependOlderPage(page)
        #expect(replica.order == ["e0", "e0b", "e1"])
        #expect(replica.entryExtras["e0b"] == ThreadEntryExtras(used: 1200))
        #expect(replica.usedAtEnd(before: 2) == 1200)
    }

    @Test("Agent capabilities read rewind, false when an older host leaves it out")
    func agentCapabilityRewind() throws {
        let withRewind = #"{"id":"codex","name":"Codex","state":"ready","capabilities":{"forkSession":true,"rewind":true}}"#
        #expect(try JSONDecoder().decode(AgentStatusInfo.self, from: Data(withRewind.utf8)).capabilities?.rewind == true)
        let without = #"{"id":"codex","name":"Codex","state":"ready","capabilities":{"forkSession":true}}"#
        #expect(try JSONDecoder().decode(AgentStatusInfo.self, from: Data(without.utf8)).capabilities?.rewind == false)
    }

    @Test("sessions.rewind and sessions.putBack send the params of the host contract and read its results")
    func rewindAndPutBackRequests() async throws {
        let log = RequestLog()
        let transport = RewindMockTransport { raw in
            let req = try! JSONDecoder().decode(JSONValue.self, from: raw).objectValue!
            let id = Int(req["id"]!.doubleValue!)
            let method = req["method"]!.stringValue!
            await log.record(method, req["params"]!)
            let result: String
            switch method {
            case "sessions.rewind":
                result = """
                {"content":[{"type":"text","text":"Plan the work"},{"type":"ref","ref":{"kind":"attachment","attachment":{"id":"att-new","type":"image","name":"Image 1","mimeType":"image/png","size":12}}}]}
                """
            case "sessions.putBack":
                result = #"{"draft":[{"type":"text","text":"held"}]}"#
            default:
                result = "null"
            }
            return [Data(#"{"type":"response","id":\#(id),"result":\#(result)}"#.utf8)]
        }
        let host = SartoHostSession(transport: transport)
        let held = AttachmentInfo(id: "att-held", type: "file", name: "notes.md", mimeType: "text/markdown", size: 4)
        let content = try await host.rewindSession(
            sessionId: "s-1",
            entryId: "e8",
            draft: [.text("held"), .ref(.attachment(held))]
        )
        #expect(SessionRewind.promptText(content) == "Plan the work")
        #expect(SessionRewind.attachments(content).map(\.id) == ["att-new"])

        let draft = try await host.putBackSession(sessionId: "s-1")
        #expect(draft == [.text("held")])

        let rewind = await log.params["sessions.rewind"]
        #expect(rewind == .object([
            "sessionId": .string("s-1"),
            "entryId": .string("e8"),
            "draft": .array([
                .object(["type": .string("text"), "text": .string("held")]),
                .object([
                    "type": .string("ref"),
                    "ref": .object([
                        "kind": .string("attachment"),
                        "attachment": .object([
                            "id": .string("att-held"),
                            "type": .string("file"),
                            "name": .string("notes.md"),
                            "mimeType": .string("text/markdown"),
                            "size": .number(4),
                        ]),
                    ]),
                ]),
            ]),
        ]))
        // An empty composer keeps nothing for Put back: the draft goes as an empty array.
        _ = try await host.rewindSession(sessionId: "s-1", entryId: "e1", draft: [])
        #expect(await log.params["sessions.rewind"]?.objectValue?["draft"] == .array([]))
        #expect(await log.params["sessions.putBack"] == .object(["sessionId": .string("s-1")]))
        await host.close()
    }

    @Test("A message's text for the composer joins its text parts with a blank line")
    func promptTextJoinsParts() {
        let image = AttachmentInfo(id: "a", type: "image", name: "Image 1")
        #expect(SessionRewind.promptText([.text("One"), .ref(.attachment(image)), .text("Two")]) == "One\n\nTwo")
        #expect(SessionRewind.promptText([.ref(.attachment(image))]).isEmpty)
    }

    @Test("Queued prompts and thread entries decode structured FromSession ended reports")
    func decodesFromSessionEndedOnQueueAndThread() throws {
        let json = """
        {
          "session": {
            "id": "s-parent",
            "agentId": "codex",
            "projectPath": "/repo",
            "status": "running",
            "config": [],
            "commands": [],
            "createdAt": 1,
            "updatedAt": 2,
            "background": [],
            "queue": [
              {
                "id": "q-report",
                "content": [{ "type": "text", "text": "Sarto: the turn you asked the Codex session child-1 for has ended. Read its reply with get_session." }],
                "at": 100,
                "from": {
                  "sessionId": "child-1",
                  "title": "Code review",
                  "ended": { "agent": "Codex", "stopReason": "end_turn" }
                }
              },
              {
                "id": "q-failed",
                "content": [{ "type": "text", "text": "Sarto: the turn you asked the Codex session child-2 for failed. Read its reply with get_session." }],
                "at": 101,
                "from": {
                  "sessionId": "child-2",
                  "title": "Failing check",
                  "ended": { "agent": "Codex", "stopReason": null }
                }
              },
              {
                "id": "q-device",
                "content": [{ "type": "text", "text": "Continue" }],
                "at": 102,
                "device": { "id": "dev-1", "name": "iPhone" },
                "comments": { "count": 2, "text": "Two comments" }
              }
            ],
            "queuePaused": false
          },
          "entries": [
            {
              "kind": "user",
              "id": "e-rep",
              "content": [{ "type": "text", "text": "Sarto: the turn you asked the Codex session child-1 for has ended. Read its reply with get_session." }],
              "at": 90,
              "from": {
                "sessionId": "child-1",
                "title": "Code review",
                "ended": { "agent": "Codex", "stopReason": "end_turn" }
              }
            }
          ],
          "seq": 3,
          "older": null,
          "plan": null
        }
        """

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.session.queue.count == 3)

        let reportItem = snapshot.session.queue[0]
        #expect(reportItem.isSessionReport)
        #expect(!reportItem.isUserEditable)
        #expect(reportItem.from == FromSession(
            sessionId: "child-1",
            title: "Code review",
            ended: FromSessionEnded(agent: "Codex", stopReason: "end_turn")
        ))

        let failedItem = snapshot.session.queue[1]
        #expect(failedItem.isSessionReport)
        #expect(failedItem.from?.ended == FromSessionEnded(agent: "Codex", stopReason: nil))

        let deviceItem = snapshot.session.queue[2]
        #expect(!deviceItem.isSessionReport)
        #expect(deviceItem.isUserEditable)
        #expect(deviceItem.device == FromDevice(id: "dev-1", name: "iPhone"))
        #expect(deviceItem.comments == QueuedComments(count: 2, text: "Two comments"))

        let replica = ThreadReplica(snapshot: snapshot)
        #expect(replica.entryExtras["e-rep"] == ThreadEntryExtras(
            from: FromSession(
                sessionId: "child-1",
                title: "Code review",
                ended: FromSessionEnded(agent: "Codex", stopReason: "end_turn")
            )
        ))
        #expect(replica.entryExtras["e-rep"]?.fromSession == true)
        #expect(!replica.canEditFrom("e-rep"))
    }
}
