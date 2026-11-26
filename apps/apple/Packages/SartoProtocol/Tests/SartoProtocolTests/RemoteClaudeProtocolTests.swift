import Foundation
import Testing
@testable import SartoProtocol

@Suite("Remote Claude Code protocol")
struct RemoteClaudeProtocolTests {
    @Test("A remote host's status decodes and says whether it can be picked")
    func decodesRemoteClaudeHostInfoAndSelectability() throws {
        let json = """
        {
          "hostId": "host-b",
          "hostName": "Mac Studio",
          "platform": "darwin",
          "status": {
            "enabled": true,
            "ready": true,
            "authRequired": false,
            "accountLabel": "claude-max",
            "models": [
              {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "value": "claude-sonnet-4-6",
                "choices": [
                  { "value": "claude-sonnet-4-6", "name": "Sonnet 4.6" }
                ]
              }
            ],
            "activeRuns": 1,
            "maxConcurrent": 3,
            "error": null
          }
        }
        """
        let host = try JSONDecoder().decode(RemoteClaudeHostInfo.self, from: Data(json.utf8))
        #expect(host.id == "host-b")
        #expect(host.hostName == "Mac Studio")
        #expect(host.status.isSelectable)
        #expect(!host.status.isBusy)
        #expect(host.status.models.count == 1)
    }

    @Test("A session's summary and view carry the computer its model runs on")
    func decodesModelHostOnSessionSummaryAndView() throws {
        let summaryJSON = """
        {
          "id": "s1",
          "agentId": "claude-code",
          "projectPath": "/tmp/proj",
          "status": "idle",
          "permissionCount": 0,
          "createdAt": 1000,
          "updatedAt": 1000,
          "modelHost": { "hostId": "host-b", "hostName": "Mac Studio" }
        }
        """
        let summary = try JSONDecoder().decode(SessionSummary.self, from: Data(summaryJSON.utf8))
        #expect(summary.modelHost == ModelHostRef(hostId: "host-b", hostName: "Mac Studio"))

        let viewJSON = """
        {
          "id": "s1",
          "agentId": "claude-code",
          "projectPath": "/tmp/proj",
          "status": "idle",
          "config": [],
          "commands": [],
          "createdAt": 1000,
          "updatedAt": 1000,
          "modelHost": { "hostId": "host-b", "hostName": "Mac Studio" }
        }
        """
        let view = try JSONDecoder().decode(SessionView.self, from: Data(viewJSON.utf8))
        #expect(view.modelHost == ModelHostRef(hostId: "host-b", hostName: "Mac Studio"))
    }

    @Test("A session update sets the model host, and null clears it when the agent moves here")
    func sessionUpdateChangesModelHost() throws {
        var replica = ThreadReplica(snapshot: SessionSnapshot(
            session: SessionView(id: "s1", agentId: "claude-code", projectPath: "/tmp/proj", status: .ready),
            entries: [],
            seq: 1,
            older: nil
        ))
        let set = PatchBatch(sessionId: "s1", seq: 2, patches: [
            .sessionUpdate(changes: [
                "modelHost": .object(["hostId": .string("host-b"), "hostName": .string("Mac Studio")]),
            ]),
        ])
        let appliedSet = replica.apply(set)
        #expect(appliedSet)
        #expect(replica.session.modelHost == ModelHostRef(hostId: "host-b", hostName: "Mac Studio"))

        let cleared = PatchBatch(sessionId: "s1", seq: 3, patches: [
            .sessionUpdate(changes: ["agentId": .string("codex"), "modelHost": .null]),
        ])
        let appliedCleared = replica.apply(cleared)
        #expect(appliedCleared)
        #expect(replica.session.modelHost == nil)
        #expect(replica.session.agentId == "codex")
    }

    @Test("The host settings carry remote.claude")
    func decodesHostSettingsRemoteClaude() throws {
        let raw = try JSONValue(jsonData: Data("""
        {
          "remote": {
            "terminal": true,
            "claude": {
              "enabled": true,
              "maxConcurrent": 5,
              "idleMinutes": 30
            }
          }
        }
        """.utf8))
        let settings = HostSettingsSnapshot.from(json: raw)
        #expect(settings.remoteClaudeEnabled)
        #expect(settings.remoteClaudeMaxConcurrent == 5)
        #expect(settings.remoteClaudeIdleMinutes == 30)
    }

    @Test("remoteClaude.activeChanged decodes the runs this computer hosts")
    func decodesRemoteClaudeActiveChangedEvent() throws {
        let data = Data("""
        {
          "type": "event",
          "event": {
            "type": "remoteClaude.activeChanged",
            "active": [
              {
                "runId": "run-1",
                "deviceId": "dev-a",
                "deviceName": "MacBook Air",
                "startedAt": 1000,
                "lastActiveAt": 2000
              }
            ]
          }
        }
        """.utf8)
        guard case .remoteClaudeActiveChanged(let active)? = HostEvent.decode(fromEnvelopeData: data) else {
            Issue.record("remoteClaude.activeChanged was not decoded")
            return
        }
        #expect(active.count == 1)
        #expect(active.first?.deviceName == "MacBook Air")
    }
}
