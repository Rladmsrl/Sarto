import Foundation
import Testing
@testable import SartoProtocol

/// A `SessionSummary` as `src/shared/agent-host.ts` shapes it, with `lastTurn` spliced in raw.
private func summaryJSON(lastTurn: String?) -> Data {
    let field = lastTurn.map { ",\n  \"lastTurn\": \($0)" } ?? ""
    return Data("""
    {
      "id": "s1",
      "agentId": "claude-code",
      "projectPath": "/work/app",
      "title": "Fix the login test",
      "status": "ready",
      "attention": "none",
      "permissionCount": 0,
      "createdAt": 1700000000000,
      "updatedAt": 1700000100000,
      "parentId": null,
      "origin": "user",
      "branch": "main",
      "model": "opus",
      "pinnedAt": null,
      "archivedAt": null,
      "acpSessionId": "acp-1",
      "turnStartedAt": null,
      "activity": null,
      "phase": null\(field)
    }
    """.utf8)
}

private func decodeSummary(lastTurn: String?) throws -> SessionSummary {
    try JSONDecoder().decode(SessionSummary.self, from: summaryJSON(lastTurn: lastTurn))
}

@Suite("Last turn ending and extra usage decoding")
struct LastTurnDecodingTests {
    @Test("Each stop reason decodes with when the turn ended", arguments: [
        ("end_turn", LastTurn.Reason.endTurn),
        ("max_tokens", .maxTokens),
        ("max_turn_requests", .maxTurnRequests),
        ("refusal", .refusal),
        ("cancelled", .cancelled),
    ])
    func stopReasons(raw: String, reason: LastTurn.Reason) throws {
        let summary = try decodeSummary(lastTurn: #"{ "reason": "\#(raw)", "endedAt": 1700000090000 }"#)
        let last = try #require(summary.lastTurn)
        #expect(last.reason == reason)
        #expect(last.reason.rawValue == raw)
        #expect(last.reason.isError == false)
        #expect(last.endedAt == 1_700_000_090_000)
        #expect(last.error == nil)
        #expect(last.limit == nil)
    }

    @Test("A failed turn carries its error's first line")
    func failedWithError() throws {
        let summary = try decodeSummary(lastTurn: """
        {
          "reason": "failed",
          "endedAt": 1700000090000,
          "error": "Internal error: The fake agent failed this turn on purpose"
        }
        """)
        let last = try #require(summary.lastTurn)
        #expect(last.reason == .failed)
        #expect(last.reason.isError)
        #expect(last.error == "Internal error: The fake agent failed this turn on purpose")
        #expect(last.errorLine == "Internal error: The fake agent failed this turn on purpose")
        #expect(last.limit == nil)
    }

    @Test("The error line skips blank lines and trims")
    func errorLine() {
        let last = LastTurn(reason: .failed, endedAt: 1, error: "\n   \n  Connection reset  \nstack")
        #expect(last.errorLine == "Connection reset")
        #expect(LastTurn(reason: .failed, endedAt: 1, error: " \n ").errorLine == nil)
        #expect(LastTurn(reason: .cancelled, endedAt: 1).errorLine == nil)
    }

    @Test("A turn a plan limit stopped names the window, its account and its reset")
    func limitWithWindow() throws {
        let summary = try decodeSummary(lastTurn: """
        {
          "reason": "limit",
          "endedAt": 1700000090000,
          "error": "Internal error: You've hit your limit",
          "limit": {
            "window": "five_hour",
            "label": "5-hour",
            "account": "Claude Max",
            "resetsAt": 1700003600000
          }
        }
        """)
        let last = try #require(summary.lastTurn)
        #expect(last.reason == .limit)
        #expect(last.reason.isError)
        #expect(last.error == "Internal error: You've hit your limit")
        let limit = try #require(last.limit)
        #expect(limit.window == "five_hour")
        #expect(limit.label == "5-hour")
        #expect(limit.account == "Claude Max")
        #expect(limit.resetsAt == 1_700_003_600_000)
        #expect(limit.holds(nowMs: 1_700_000_100_000))
        #expect(!limit.holds(nowMs: 1_700_003_600_000))
    }

    @Test("A limit whose reset is unknown holds until told otherwise")
    func limitWithUnknownReset() throws {
        let summary = try decodeSummary(lastTurn: """
        {
          "reason": "limit",
          "endedAt": 1700000090000,
          "error": "Rate limited",
          "limit": { "window": "seven_day", "label": "Weekly", "account": "Codex", "resetsAt": null }
        }
        """)
        let limit = try #require(summary.lastTurn?.limit)
        #expect(limit.resetsAt == nil)
        #expect(limit.holds(nowMs: .greatestFiniteMagnitude))
    }

    @Test("Absent from older hosts, or null while a turn runs, there is no ending")
    func absentOrNull() throws {
        #expect(try decodeSummary(lastTurn: nil).lastTurn == nil)
        #expect(try decodeSummary(lastTurn: "null").lastTurn == nil)
    }

    @Test("A reason this client does not know still decodes the summary")
    func unknownReason() throws {
        let summary = try decodeSummary(lastTurn: #"{ "reason": "paused", "endedAt": 1700000090000 }"#)
        #expect(summary.lastTurn?.reason == .unknown("paused"))
        #expect(summary.lastTurn?.reason.isError == false)
    }

    @Test("A malformed ending never fails the summary")
    func malformedEnding() throws {
        let badLimit = try decodeSummary(lastTurn: """
        { "reason": "limit", "endedAt": 1700000090000, "limit": { "window": 5 } }
        """)
        #expect(badLimit.lastTurn?.reason == .limit)
        #expect(badLimit.lastTurn?.limit == nil)

        let notAnObject = try decodeSummary(lastTurn: #""failed""#)
        #expect(notAnObject.lastTurn?.reason == .unknown(""))

        let noTime = try decodeSummary(lastTurn: #"{ "reason": "cancelled" }"#)
        #expect(noTime.lastTurn?.reason == .cancelled)
        #expect(noTime.lastTurn?.endedAt == 0)
    }

    @Test("A session.summary event and a sessions.list result carry the ending")
    func eventAndList() throws {
        let summary = String(decoding: summaryJSON(lastTurn: #"{ "reason": "cancelled", "endedAt": 1700000090000 }"#), as: UTF8.self)
        let envelope = Data(#"{ "type": "event", "event": { "type": "session.summary", "summary": \#(summary) } }"#.utf8)
        guard case .sessionSummary(let decoded)? = HostEvent.decode(fromEnvelopeData: envelope) else {
            Issue.record("Expected HostEvent.sessionSummary")
            return
        }
        #expect(decoded.lastTurn == LastTurn(reason: .cancelled, endedAt: 1_700_000_090_000))

        let older = String(decoding: summaryJSON(lastTurn: nil), as: UTF8.self)
        let list = try JSONDecoder().decode([SessionSummary].self, from: Data("[\(summary), \(older)]".utf8))
        #expect(list.map(\.lastTurn?.reason) == [.cancelled, nil])
    }

    @Test("An ending survives a round trip through the client's own encoding")
    func roundTrip() throws {
        let last = LastTurn(
            reason: .limit,
            endedAt: 1_700_000_090_000,
            error: "You've hit your limit",
            limit: LastTurnLimit(window: "five_hour", label: "5-hour", account: "Claude Max", resetsAt: nil)
        )
        let data = try JSONEncoder().encode(last)
        #expect(try JSONDecoder().decode(LastTurn.self, from: data) == last)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reason"] as? String == "limit")
    }

    @Test("A plan window says whether extra usage covers it, and older hosts say nothing")
    func extraUsageOnPlanLimit() throws {
        let envelope = Data("""
        {
          "type": "event",
          "event": {
            "type": "agent.status",
            "status": {
              "id": "claude-code",
              "name": "Claude Code",
              "state": "ready",
              "limits": [
                {
                  "window": "five_hour",
                  "label": "5-hour",
                  "usedPercent": 100,
                  "resetsAt": 1700003600000,
                  "state": "reached",
                  "observedAt": 1700000000000,
                  "extraUsage": true
                },
                {
                  "window": "seven_day",
                  "label": "Weekly",
                  "usedPercent": 40,
                  "resetsAt": 1700500000000,
                  "state": "ok",
                  "observedAt": 1700000000000
                }
              ]
            }
          }
        }
        """.utf8)
        guard case .agentStatus(let status)? = HostEvent.decode(fromEnvelopeData: envelope) else {
            Issue.record("Expected HostEvent.agentStatus")
            return
        }
        let limits = try #require(status.limits)
        #expect(limits.map(\.extraUsage) == [true, nil])
        #expect(limits.map(\.isCoveredByExtraUsage) == [true, false])

        let now = 1_700_000_100_000.0
        #expect(PlanLimitScope.heldBack(limits, nowMs: now) == nil)
        #expect(PlanLimitScope.coveredByExtraUsage(limits, nowMs: now)?.window == "five_hour")
        // Once the window resets, neither holds.
        #expect(PlanLimitScope.coveredByExtraUsage(limits, nowMs: 1_700_003_600_000) == nil)
    }

    @Test("A used-up window extra usage does not cover holds the session back")
    func heldBackWithoutExtraUsage() {
        let limits = [
            PlanLimitInfo(window: "five_hour", label: "5-hour", usedPercent: 100, resetsAt: nil, state: "reached"),
        ]
        #expect(PlanLimitScope.heldBack(limits, nowMs: 1)?.window == "five_hour")
        #expect(PlanLimitScope.coveredByExtraUsage(limits, nowMs: 1) == nil)
    }

    @Test("A per-model weekly window holds back only the model it names")
    func limitsForModel() {
        let choices = [
            ConfigChoice(value: "opus", name: "Opus 4.7", modelId: "claude-opus-4-7"),
            ConfigChoice(value: "sonnet", name: "Sonnet 4.6", modelId: "claude-sonnet-4-6"),
        ]
        let limits = [
            PlanLimitInfo(window: "five_hour", label: "5-hour", usedPercent: 10, resetsAt: nil, state: "ok"),
            PlanLimitInfo(window: "seven_day_opus", label: "Weekly · Opus", usedPercent: 100, resetsAt: nil, state: "reached"),
            PlanLimitInfo(window: "seven_day_fable", label: "Weekly · Fable", usedPercent: 100, resetsAt: nil, state: "reached"),
        ]
        let onSonnet = PlanLimitScope.limits(limits, choices: choices, model: "sonnet").map(\.window)
        // A window naming a model the menu does not know counts for every model.
        #expect(onSonnet == ["five_hour", "seven_day_fable"])
        let onOpus = PlanLimitScope.limits(limits, choices: choices, model: "opus").map(\.window)
        #expect(onOpus == ["five_hour", "seven_day_opus", "seven_day_fable"])
        #expect(PlanLimitScope.limits(limits, choices: choices, model: nil).count == 3)
        #expect(PlanLimitScope.limits(limits, choices: choices, model: "haiku").count == 3)
    }

    @Test("A group's window counts only on the models it lists")
    func groupedWindows() {
        let model = ConfigOption(
            id: "model",
            name: "Model",
            category: "model",
            type: "select",
            value: .string("flash"),
            choices: [
                ConfigChoice(value: "flash", name: "Gemini 3.8 Flash"),
                ConfigChoice(value: "pro", name: "Gemini 3.8 Pro"),
            ]
        )
        let limits = [
            PlanLimitInfo(window: "group_a", label: "Flash models", usedPercent: 100, resetsAt: nil, state: "reached", models: ["Gemini 3.8 Flash"]),
            PlanLimitInfo(window: "group_b", label: "Pro models", usedPercent: 20, resetsAt: nil, state: "ok", models: ["Gemini 3.8 Pro"]),
        ]
        #expect(PlanLimitScope.limits(limits, agentConfig: [model], model: "flash").map(\.window) == ["group_a"])
        #expect(PlanLimitScope.limits(limits, agentConfig: [model], model: "pro").map(\.window) == ["group_b"])
    }
}
