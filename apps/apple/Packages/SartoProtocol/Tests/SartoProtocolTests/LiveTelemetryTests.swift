import Foundation
import Testing
@testable import SartoProtocol

@Suite("Live Session Telemetry: Burst tok/s, Per-Request lastRequest & ACP Turn-Delta Cache")
struct LiveTelemetryTests {
    @Test("LastRequestInfo, OutputSpeedInfo, PromptCacheInfo, and turnStartUsed decode exact Sarto wire JSON")
    func wireModelsDecodeAndPatch() throws {
        let json = """
        {
          "id": "sess-claude-1",
          "agentId": "claude-code",
          "projectPath": "/Users/test/Sarto",
          "status": "running",
          "title": "Refactor renderer",
          "config": [],
          "usage": {
            "used": 148000,
            "size": 200000,
            "cost": { "amount": 0.42, "currency": "USD" },
            "tokens": { "total": 152000, "input": 10000, "output": 4000, "thought": 1200, "cacheRead": 132000, "cacheWrite": 6000 },
            "cache": { "lastRequestAt": 1795274235000, "ttl": 300000 }
          },
          "error": null,
          "turnStartedAt": 1795274200000,
          "turnStartUsed": 112000,
          "speed": {
            "last": { "tokens": 420, "ms": 5000, "approx": false, "firstTokenMs": 610 },
            "recent": [{ "rate": 84.0, "approx": false }],
            "turn": { "tokens": 420, "ms": 5000, "requests": 1, "approx": 0, "since": 1795274200000 },
            "session": { "tokens": 1260, "ms": 15000, "requests": 3, "approx": 0 }
          },
          "lastRequest": {
            "at": 1795274235000,
            "input": 2000,
            "cacheRead": 92000,
            "cacheWrite": 6000,
            "output": 420,
            "ms": 5000
          },
          "createdAt": 1795274000000,
          "updatedAt": 1795274235000
        }
        """

        let session = try JSONDecoder().decode(SessionView.self, from: Data(json.utf8))
        #expect(session.turnStartUsed == 112_000)
        #expect(session.usage?.cache?.ttl == 300_000)
        #expect(session.speed?.last?.rate == 84.0)
        #expect(session.speed?.last?.firstTokenMs == 610)
        #expect(session.lastRequest?.inputTotal == 100_000)
        #expect(abs((session.lastRequest?.cacheHitPercent ?? 0) - 92.0) < 0.01)

        // Verify ThreadReplica applies incremental `lastRequest`, `speed`, and `turnStartUsed` patches
        var replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1, older: nil))
        let patchJSON = """
        {
          "sessionId": "sess-claude-1",
          "seq": 2,
          "patches": [
            {
              "op": "session.update",
              "changes": {
                "turnStartUsed": 148000,
                "lastRequest": { "at": 1795274240000, "input": 1000, "cacheRead": 98000, "cacheWrite": 1000, "output": 200, "ms": 2000 },
                "speed": { "last": { "tokens": 200, "ms": 2000, "approx": false, "firstTokenMs": 420 } }
              }
            }
          ]
        }
        """
        let batch = try JSONDecoder().decode(PatchBatch.self, from: Data(patchJSON.utf8))
        replica.apply(batch)

        #expect(replica.session.turnStartUsed == 148_000)
        #expect(abs((replica.session.lastRequest?.cacheHitPercent ?? 0) - 98.0) < 0.01)
        #expect(replica.session.speed?.last?.rate == 100.0)
    }

    @Test("Sliding-window burst tok/s stays accurate across 15-second tool-call pauses and distinguishes CJK vs Latin")
    func burstSpeedIgnoresToolWaitPauses() {
        // CJK estimation sanity check (~1.45 chars/tok vs ~3.85 chars/tok for English)
        let enEst = LiveSessionTelemetryTracker.estimateTokens(for: String(repeating: "a", count: 385))
        let zhEst = LiveSessionTelemetryTracker.estimateTokens(for: String(repeating: "测", count: 145))
        #expect(abs(enEst - 100.0) < 1.0)
        #expect(abs(zhEst - 100.0) < 1.0)

        var tracker = LiveSessionTelemetryTracker()
        let session = SessionView(id: "s-agy", agentId: "antigravity", projectPath: "/repo", status: .running)
        let replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 0, older: nil))

        tracker.recordPromptSent(sessionId: "s-agy", at: 100.0)

        // Burst 1: 10 chunks over 0.9s (~38 chars = ~10 tok every 0.1s => ~100 tok/s)
        let chunk = String(repeating: "a", count: 38)
        for i in 0..<10 {
            let t = 100.5 + Double(i) * 0.1
            let batch = PatchBatch(sessionId: "s-agy", seq: i + 1, patches: [.entryAppendText(id: "e1", text: chunk)])
            tracker.recordBatch(batch, replica: replica, at: t)
        }

        let snapBurst1 = tracker.snapshot(for: replica, at: 101.4)
        #expect(snapBurst1.ttftMs == 500)
        #expect(snapBurst1.tpsIsApprox == true)
        #expect((snapBurst1.tps ?? 0) > 85 && (snapBurst1.tps ?? 0) < 125)

        // Simulate a 15-second tool execution pause (no text deltas from t=101.4 to t=116.4)
        let snapDuringTool = tracker.snapshot(for: replica, at: 110.0)
        // Must freeze the previous burst reading rather than dividing by 10 seconds!
        #expect((snapDuringTool.tps ?? 0) > 85 && (snapDuringTool.tps ?? 0) < 125)

        // Burst 2 resumes at t=116.5 at ~60 tok/s (~23 chars = ~6 tok every 0.1s over 0.9s)
        let chunk2 = String(repeating: "b", count: 23)
        for i in 0..<10 {
            let t = 116.5 + Double(i) * 0.1
            let batch = PatchBatch(sessionId: "s-agy", seq: 20 + i, patches: [.entryAppendText(id: "e2", text: chunk2)])
            tracker.recordBatch(batch, replica: replica, at: t)
        }

        let snapBurst2 = tracker.snapshot(for: replica, at: 117.4)
        #expect(snapBurst2.tpsIsApprox == true)
        #expect((snapBurst2.tps ?? 0) > 48 && (snapBurst2.tps ?? 0) < 75)
    }

    @Test("ACP Antigravity 3-turn lifecycle tracks pending turn context delta and per-turn 94.7% hit rate without cold-start dilution")
    func acpThreeTurnRealWorldScenario() {
        var tracker = LiveSessionTelemetryTracker()

        // Turn 1 complete: cold start (32,723 input, 0 cacheRead -> 0%)
        var session = SessionView(
            id: "b4639c6f",
            agentId: "antigravity",
            projectPath: "/Users/dev/Sarto",
            status: .ready,
            usage: SessionUsage(
                used: 32_768,
                size: 1_048_576,
                tokens: TokenTotals(total: 32_768, input: 32_723, output: 45, cacheRead: 0, cacheWrite: 0)
            )
        )
        var replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1, older: nil))
        tracker.syncSnapshot(replica: replica, at: 10.0)

        let afterT1 = tracker.snapshot(for: replica, at: 10.0)
        #expect(afterT1.cacheSource == .session)
        #expect(afterT1.primaryCacheHitPercent == 0.0)

        // Turn 2 starts & ends: +36,002 input, +33,074 cacheRead => Turn 2 = 47.9%, Session = 32.5%
        tracker.recordPromptSent(sessionId: session.id, baselineTokens: session.usage?.tokens, baselineUsed: session.usage?.used, at: 20.0)
        session.status = .ready
        session.usage = SessionUsage(
            used: 69_076,
            size: 1_048_576,
            tokens: TokenTotals(total: 102_537, input: 68_725, output: 738, cacheRead: 33_074, cacheWrite: 0)
        )
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 2, older: nil))
        tracker.syncSnapshot(replica: replica, at: 35.0)

        let afterT2 = tracker.snapshot(for: replica, at: 35.0)
        #expect(afterT2.cacheSource == .lastTurn)
        #expect(abs((afterT2.primaryCacheHitPercent ?? 0) - 47.88) < 0.2)
        #expect(abs((afterT2.sessionCacheHitPercent ?? 0) - 32.49) < 0.2)

        // Turn 3 starts and runs for 12 minutes with live `usage_update.used` rising from 69,076 -> 189,076 (+120k)
        tracker.recordPromptSent(sessionId: session.id, baselineTokens: session.usage?.tokens, baselineUsed: session.usage?.used, at: 40.0)
        session.status = .running
        session.turnStartUsed = 69_076
        session.usage = SessionUsage(
            used: 189_076,
            size: 1_048_576,
            tokens: session.usage?.tokens
        )
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 3, older: nil))
        tracker.syncSnapshot(replica: replica, at: 300.0)

        let midT3 = tracker.snapshot(for: replica, at: 300.0)
        #expect(midT3.cacheSource == .pendingTurn)
        #expect(midT3.turnContextDelta == 120_000)

        // Turn 3 ends: +314,687 input, +5,580,228 cacheRead => Turn 3 = 94.7%, Session = 93.6%
        session.status = .ready
        session.usage = SessionUsage(
            used: 347_697,
            size: 1_048_576,
            tokens: TokenTotals(total: 6_069_986, input: 383_412, output: 73_272, cacheRead: 5_613_302, cacheWrite: 0)
        )
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 4, older: nil))
        tracker.syncSnapshot(replica: replica, at: 740.0)

        let afterT3 = tracker.snapshot(for: replica, at: 740.0)
        #expect(afterT3.cacheSource == .lastTurn)
        #expect(abs((afterT3.primaryCacheHitPercent ?? 0) - 94.66) < 0.2)
        #expect(abs((afterT3.sessionCacheHitPercent ?? 0) - 93.61) < 0.2)
        #expect(afterT3.turnContextDelta == nil)
    }

    @Test("Claude Code / Codex session.lastRequest yields live per-request cache hit even mid-turn and exact host speed takes precedence")
    func claudeLiveLastRequestAndExactSpeed() {
        var tracker = LiveSessionTelemetryTracker()
        let session = SessionView(
            id: "s-claude",
            agentId: "claude-code",
            projectPath: "/repo",
            status: .running,
            usage: SessionUsage(
                used: 120_000,
                size: 200_000,
                tokens: TokenTotals(total: 200_000, input: 40_000, output: 10_000, cacheRead: 140_000, cacheWrite: 10_000)
            ),
            speed: OutputSpeedInfo(
                last: SpeedSampleInfo(tokens: 300, ms: 3000, approx: false, firstTokenMs: 520)
            ),
            lastRequest: LastRequestInfo(
                at: 1000,
                input: 1500,
                cacheRead: 95_000,
                cacheWrite: 3500,
                output: 300,
                ms: 3000
            ),
            turnStartUsed: 95_000
        )
        let replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1, older: nil))
        tracker.syncSnapshot(replica: replica, at: 50.0)

        let snap = tracker.snapshot(for: replica, at: 50.0)
        #expect(snap.cacheSource == .liveRequest)
        #expect(abs((snap.primaryCacheHitPercent ?? 0) - 95.0) < 0.01)
        #expect(abs((snap.sessionCacheHitPercent ?? 0) - 73.68) < 0.2)
        #expect(snap.tps == 100.0)
        #expect(snap.tpsIsApprox == false)
        #expect(snap.ttftMs == 520)
        #expect(snap.turnContextDelta == 25_000)
    }

    @Test("ACP snapshot hydrates host-timed thought tok/s on relaunch while ignoring short buffered bursts")
    func acpSnapshotHydratesHistoricalThoughtTPS() {
        var tracker = LiveSessionTelemetryTracker()
        let session = SessionView(id: "s-agy-relaunch", agentId: "antigravity", projectPath: "/repo", status: .ready)
        let entries: [ThreadEntry] = [
            // Genuine host-timed thought: ~100 tokens over 2.0s => ~50 tok/s
            .thought(id: "t1", markdown: String(repeating: "a", count: 385), streaming: false, durationMs: 2000),
            // Short buffered thought (< 500 ms): must be ignored so it never produces fake 500+ tok/s spikes
            .thought(id: "t2", markdown: String(repeating: "b", count: 336), streaming: false, durationMs: 187),
        ]
        let replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: entries, seq: 10, older: nil))
        tracker.syncSnapshot(replica: replica, at: 500.0)

        let snap = tracker.snapshot(for: replica, at: 500.0)
        #expect(snap.tpsIsApprox == true)
        #expect((snap.tps ?? 0) > 45.0 && (snap.tps ?? 0) < 55.0)
    }

    @Test("Streaming entry.add + turn-start transition in same batch preserves burst samples and computes tok/s")
    func entryAddOnTurnStartPreservesBurst() {
        var tracker = LiveSessionTelemetryTracker()
        var session = SessionView(id: "s-agy-queued", agentId: "antigravity", projectPath: "/repo", status: .ready)
        var replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 1, older: nil))
        tracker.syncSnapshot(replica: replica, at: 10.0)

        // Queued turn starts remotely: status flips to `.running` in the same batch as `.entryAdd(.agent(...))`
        session.status = .running
        replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: [], seq: 2, older: nil))
        let firstBatch = PatchBatch(
            sessionId: session.id,
            seq: 2,
            patches: [
                .sessionUpdate(changes: ["status": .string("running")]),
                .entryAdd(.agent(id: "a1", markdown: String(repeating: "x", count: 77), streaming: true, at: nil)),
            ]
        )
        tracker.recordBatch(firstBatch, replica: replica, at: 20.0)

        let secondBatch = PatchBatch(
            sessionId: session.id,
            seq: 3,
            patches: [.entryAppendText(id: "a1", text: String(repeating: "x", count: 77))]
        )
        tracker.recordBatch(secondBatch, replica: replica, at: 20.5)

        let snap = tracker.snapshot(for: replica, at: 20.5)
        #expect(snap.tpsIsApprox == true)
        #expect((snap.tps ?? 0) > 60.0 && (snap.tps ?? 0) < 100.0)
    }

    @Test("Attaching mid-turn to a running ACP session does not fabricate multi-minute TTFT from turnStartedAt")
    func midTurnAttachDoesNotFabricateTTFT() {
        var tracker = LiveSessionTelemetryTracker()
        // Turn started 8 minutes ago (480s), already has a thought entry in this turn.
        let startedAtMs = 1_795_500_000_000.0
        let nowSec = startedAtMs / 1000.0 + 484.0
        var session = SessionView(
            id: "s-agy-midturn",
            agentId: "antigravity",
            projectPath: "/repo",
            status: .running,
            turnStartedAt: startedAtMs
        )
        let entries: [ThreadEntry] = [
            .user(id: "u1", text: "continue", content: [], at: startedAtMs, approval: false),
            .thought(id: "th1", markdown: "Already thinking earlier in this turn", streaming: false, durationMs: 3000),
        ]
        var replica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: entries, seq: 10, older: nil))
        tracker.syncSnapshot(replica: replica, at: nowSec)

        // New text chunk arrives 484s after turnStartedAt: must NOT record 484,000 ms (8:04) TTFT!
        let batch = PatchBatch(
            sessionId: session.id,
            seq: 11,
            patches: [.entryAdd(.agent(id: "a1", markdown: "Hello world", streaming: true, at: nil))]
        )
        replica.apply(batch)
        tracker.recordBatch(batch, replica: replica, at: nowSec + 0.5)

        let snapBeforeHost = tracker.snapshot(for: replica, at: nowSec + 0.5)
        #expect(snapBeforeHost.ttftMs == nil)

        // Once the daemon pushes real host-measured speed/TTFT, it displays accurately.
        session.speed = OutputSpeedInfo(
            last: SpeedSampleInfo(tokens: 500, ms: 5000, approx: false, firstTokenMs: 1850),
            recent: [SpeedReadingInfo(rate: 100, approx: false)],
            turn: SpeedTotalsInfo(tokens: 500, ms: 5000, requests: 1, approx: 0, since: startedAtMs),
            session: SpeedTotalsInfo(tokens: 500, ms: 5000, requests: 1, approx: 0)
        )
        let hostReplica = ThreadReplica(snapshot: SessionSnapshot(session: session, entries: replica.entries, seq: 12, older: nil))
        tracker.syncSnapshot(replica: hostReplica, at: nowSec + 1.0)

        let snapAfterHost = tracker.snapshot(for: hostReplica, at: nowSec + 1.0)
        #expect(snapAfterHost.ttftMs == 1850)
        #expect(snapAfterHost.tps == 100.0)
        #expect(snapAfterHost.tpsIsApprox == false)
    }

    @Test("AgentCapabilitiesInfo decodes additionalDirectories capability")
    func decodesAdditionalDirectoriesCapability() throws {
        let json = #"{"loadSession":true,"listSessions":true,"resumeSession":true,"closeSession":true,"deleteSession":false,"forkSession":false,"forkAtMessage":false,"additionalDirectories":true,"steering":true}"#
        let caps = try JSONDecoder().decode(AgentCapabilitiesInfo.self, from: Data(json.utf8))
        #expect(caps.additionalDirectories == true)
        #expect(caps.forkSession == false)
    }
}
