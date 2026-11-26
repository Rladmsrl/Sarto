import Foundation

// MARK: - Live Request, Prompt Cache & Output Speed Wire Models
// Mirrors src/shared/model-requests.ts (LastRequest) and src/shared/output-speed.ts (OutputSpeed).

public struct PromptCacheInfo: Codable, Sendable, Equatable {
    public let lastRequestAt: Double
    public let ttl: Double?

    public var expiresAt: Double? {
        ttl.map { lastRequestAt + $0 }
    }

    public init(lastRequestAt: Double, ttl: Double? = nil) {
        self.lastRequestAt = lastRequestAt
        self.ttl = ttl
    }
}

/// The main thread's latest model API request, pushed live by Claude Code, Codex, and OpenCode.
public struct LastRequestInfo: Codable, Sendable, Equatable {
    public let at: Double
    public let input: Double?
    public let cacheRead: Double?
    public let cacheWrite: Double?
    public let output: Double?
    public let ms: Double?

    public init(
        at: Double,
        input: Double? = nil,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil,
        output: Double? = nil,
        ms: Double? = nil
    ) {
        self.at = at
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
        self.ms = ms
    }

    /// Total input-side tokens for this request (uncached + cacheRead + cacheWrite).
    public var inputTotal: Double? {
        if input == nil && cacheRead == nil && cacheWrite == nil {
            return nil
        }
        return (input ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }

    /// Cache hit percentage in 0...100 matching `cacheHitShare()` in src/shared/model-requests.ts.
    public var cacheHitPercent: Double? {
        guard let cacheRead, let total = inputTotal, total > 0 else { return nil }
        return max(0, min(100, (cacheRead / total) * 100.0))
    }
}

public struct SpeedReadingInfo: Codable, Sendable, Equatable {
    public let rate: Double
    public let approx: Bool

    public init(rate: Double, approx: Bool) {
        self.rate = rate
        self.approx = approx
    }
}

public struct SpeedSampleInfo: Codable, Sendable, Equatable {
    public let tokens: Double
    public let ms: Double
    public let approx: Bool?
    public let firstTokenMs: Double?

    public init(tokens: Double, ms: Double, approx: Bool? = nil, firstTokenMs: Double? = nil) {
        self.tokens = tokens
        self.ms = ms
        self.approx = approx
        self.firstTokenMs = firstTokenMs
    }

    public var rate: Double {
        ms > 0 ? (tokens * 1000.0) / ms : 0
    }
}

public struct SpeedTotalsInfo: Codable, Sendable, Equatable {
    public let tokens: Double
    public let ms: Double
    public let requests: Int?
    public let approx: Int?
    public let since: Double?

    public init(tokens: Double, ms: Double, requests: Int? = nil, approx: Int? = nil, since: Double? = nil) {
        self.tokens = tokens
        self.ms = ms
        self.requests = requests
        self.approx = approx
        self.since = since
    }

    public var rate: Double {
        ms > 0 ? (tokens * 1000.0) / ms : 0
    }
}

public struct OutputSpeedInfo: Codable, Sendable, Equatable {
    public let last: SpeedSampleInfo?
    public let recent: [SpeedReadingInfo]?
    public let turn: SpeedTotalsInfo?
    public let session: SpeedTotalsInfo?

    public init(
        last: SpeedSampleInfo? = nil,
        recent: [SpeedReadingInfo]? = nil,
        turn: SpeedTotalsInfo? = nil,
        session: SpeedTotalsInfo? = nil
    ) {
        self.last = last
        self.recent = recent
        self.turn = turn
        self.session = session
    }
}

// MARK: - Live Session Telemetry Engine (Burst Sliding-Window tok/s + Per-Request / Per-Turn Cache)

public enum LiveCacheSource: String, Sendable, Equatable {
    /// Live per-API-request cache hit pushed by Claude Code / Codex / OpenCode via `session.lastRequest`.
    case liveRequest
    /// Computed delta of the most recently finished turn (prevents Turn 1 cold-start from diluting later turns).
    case lastTurn
    /// Session-wide cumulative cache hit loaded from history before a local turn delta is observed.
    case session
    /// ACP agent (e.g. Antigravity `agy`) is mid-turn; `usage_update.used` is live while `cacheRead` arrives on `end_turn`.
    case pendingTurn
    /// No cache telemetry has been reported yet.
    case unavailable
}

public struct LiveTelemetrySnapshot: Sendable, Equatable {
    public let tps: Double?
    public let tpsIsApprox: Bool
    public let ttftMs: Int?
    public let primaryCacheHitPercent: Double?
    public let sessionCacheHitPercent: Double?
    public let cacheSource: LiveCacheSource
    public let turnContextDelta: Double?
    public let isStreaming: Bool

    public init(
        tps: Double? = nil,
        tpsIsApprox: Bool = false,
        ttftMs: Int? = nil,
        primaryCacheHitPercent: Double? = nil,
        sessionCacheHitPercent: Double? = nil,
        cacheSource: LiveCacheSource = .unavailable,
        turnContextDelta: Double? = nil,
        isStreaming: Bool = false
    ) {
        self.tps = tps
        self.tpsIsApprox = tpsIsApprox
        self.ttftMs = ttftMs
        self.primaryCacheHitPercent = primaryCacheHitPercent
        self.sessionCacheHitPercent = sessionCacheHitPercent
        self.cacheSource = cacheSource
        self.turnContextDelta = turnContextDelta
        self.isStreaming = isStreaming
    }
}

/// Pure, deterministic per-session live telemetry tracker for macOS and iOS clients:
/// 1. Sliding-window burst `tok/s` with CJK-aware token estimation that freezes cleanly across tool-call pauses.
/// 2. Live per-request cache hit (`session.lastRequest`) for Claude/Codex/OpenCode.
/// 3. Per-turn delta cache hit + live `turnContextDelta` (`usage.used - turnStartUsed`) for ACP (`agy`) agents.
public struct LiveSessionTelemetryTracker: Sendable {
    public struct ChunkSample: Sendable, Equatable {
        public let at: TimeInterval
        public let tokens: Double
    }

    private struct SessionMetricsState: Sendable {
        var promptSentAt: TimeInterval?
        var firstChunkAt: TimeInterval?
        var measuredTTFTMs: Int?
        var awaitingFirstToken: Bool = false
        var preTurnHostSpeedSample: SpeedSampleInfo?

        // Sliding-window burst speed tracking
        var burstSamples: [ChunkSample] = []
        var burstStartAt: TimeInterval?
        var lastChunkAt: TimeInterval?
        var lastBurstTPS: Double?
        var lastBurstEndedAt: TimeInterval?

        // Last observed host speed sample to detect fresh authoritative updates
        var lastHostSpeedSample: SpeedSampleInfo?
        var lastHostSpeedUpdatedAt: TimeInterval?

        // Turn-boundary baselines for per-turn cache delta & live context growth
        var wasRunning: Bool = false
        var turnBaselineTokens: TokenTotals?
        var turnBaselineUsed: Double?
        var lastObservedTokens: TokenTotals?
        var lastTurnCacheHitPercent: Double?
    }

    /// Gaps longer than this (e.g. waiting on a tool call) end the active streaming burst
    /// so dead wait time never drags down live `tok/s`.
    public let burstGapSeconds: TimeInterval
    /// Rolling measurement window for smooth live burst `tok/s`.
    public let slidingWindowSeconds: TimeInterval
    /// Minimum burst duration before emitting an estimated rate (prevents single-chunk spikes).
    public let minBurstDurationSeconds: TimeInterval

    private var states: [String: SessionMetricsState] = [:]

    public init(
        burstGapSeconds: TimeInterval = 1.5,
        slidingWindowSeconds: TimeInterval = 2.5,
        minBurstDurationSeconds: TimeInterval = 0.18
    ) {
        self.burstGapSeconds = burstGapSeconds
        self.slidingWindowSeconds = slidingWindowSeconds
        self.minBurstDurationSeconds = minBurstDurationSeconds
    }

    /// CJK-aware token estimator: CJK ideographs/kana/hangul/emoji average ~1.45 chars/token,
    /// while ASCII/Latin code and prose average ~3.85 chars/token.
    public static func estimateTokens(for text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        var cjkCount = 0
        var otherCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 {
                cjkCount += 1
            } else {
                otherCount += 1
            }
        }
        return (Double(cjkCount) / 1.45) + (Double(otherCount) / 3.85)
    }

    /// Computes cache hit percentage in 0...100 from cumulative `TokenTotals` (`cacheRead / (input + cacheRead + cacheWrite)`).
    public static func cacheHitPercent(for tokens: TokenTotals) -> Double? {
        guard let cacheRead = tokens.cacheRead else { return nil }
        let denom = max(0, tokens.input) + max(0, cacheRead) + max(0, tokens.cacheWrite ?? 0)
        guard denom > 0 else { return nil }
        return max(0, min(100, (cacheRead / denom) * 100.0))
    }

    /// Call right when the user sends a prompt so TTFT and turn token/context baselines start cleanly.
    public mutating func recordPromptSent(
        sessionId: String,
        baselineTokens: TokenTotals? = nil,
        baselineUsed: Double? = nil,
        at now: TimeInterval = Date().timeIntervalSince1970
    ) {
        var st = states[sessionId] ?? SessionMetricsState()
        st.promptSentAt = now
        st.firstChunkAt = nil
        st.measuredTTFTMs = nil
        st.awaitingFirstToken = true
        st.preTurnHostSpeedSample = st.lastHostSpeedSample
        st.burstSamples.removeAll(keepingCapacity: true)
        st.burstStartAt = nil
        st.lastChunkAt = nil
        st.turnBaselineTokens = baselineTokens ?? st.lastObservedTokens
        st.turnBaselineUsed = baselineUsed
        st.wasRunning = true
        states[sessionId] = st
    }

    /// Call whenever a session snapshot is opened or reloaded.
    public mutating func syncSnapshot(
        replica: ThreadReplica,
        at now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let isInitialLoad = states[replica.session.id] == nil
        var st = states[replica.session.id] ?? SessionMetricsState()
        let hasPriorOutput = Self.hasPriorTurnOutput(in: replica.entries, excludingIDs: [])
        reconcileSessionState(
            &st,
            session: replica.session,
            at: now,
            isInitialSnapshot: isInitialLoad,
            hasPriorTurnOutput: hasPriorOutput
        )
        if replica.session.speed == nil, st.lastBurstTPS == nil,
           let historicalRate = Self.estimateHistoricalThoughtTPS(from: replica.entries) {
            st.lastBurstTPS = historicalRate
            st.lastBurstEndedAt = now
        }
        states[replica.session.id] = st
    }

    /// Call on every streaming `PatchBatch` applied to `replica`.
    public mutating func recordBatch(
        _ batch: PatchBatch,
        replica: ThreadReplica,
        at now: TimeInterval = Date().timeIntervalSince1970
    ) {
        let sessionId = replica.session.id
        var st = states[sessionId] ?? SessionMetricsState()
        let isRunning = replica.session.status == .running || replica.session.status == .awaitingPermission

        // Apply turn-start transition BEFORE recording chunks so a batch that flips status to `.running`
        // and carries the first text chunk does not wipe its own burst samples.
        if isRunning && !st.wasRunning {
            var addedIDs: Set<String> = []
            for patch in batch.patches {
                if case .entryAdd(let entry) = patch {
                    addedIDs.insert(entry.id)
                }
            }
            let hasPriorOutput = Self.hasPriorTurnOutput(in: replica.entries, excludingIDs: addedIDs)
            beginRunningTurn(
                &st,
                session: replica.session,
                at: now,
                isInitialSnapshot: false,
                hasPriorTurnOutput: hasPriorOutput
            )
        }

        var addedTokens = 0.0
        var completedThoughtRate: Double? = nil
        for patch in batch.patches {
            switch patch {
            case .entryAppendText(_, let text) where !text.isEmpty:
                addedTokens += Self.estimateTokens(for: text)
            case .entryAdd(let entry):
                switch entry {
                case .agent(_, let md, let streaming, _, _) where streaming && !md.isEmpty:
                    addedTokens += Self.estimateTokens(for: md)
                case .thought(_, let md, let streaming, _) where streaming && !md.isEmpty:
                    addedTokens += Self.estimateTokens(for: md)
                case .compaction(_, _, let summary) where !summary.isEmpty:
                    addedTokens += Self.estimateTokens(for: summary)
                default:
                    break
                }
            case .entryUpdate(let id, let changes):
                if let durMs = changes["durationMs"]?.doubleValue,
                   durMs >= 500.0,
                   case .thought(_, let md, _, _)? = replica.byId[id] {
                    let est = Self.estimateTokens(for: md)
                    if est >= 15.0 {
                        completedThoughtRate = min(500.0, max(1.0, est / (durMs / 1000.0)))
                    }
                }
            default:
                break
            }
        }

        if addedTokens > 0 {
            st.awaitingFirstToken = false
            if st.firstChunkAt == nil {
                st.firstChunkAt = now
                if let sent = st.promptSentAt, now >= sent {
                    st.measuredTTFTMs = max(1, Int(round((now - sent) * 1000.0)))
                }
            }

            if let prevAt = st.lastChunkAt, (now - prevAt) > burstGapSeconds {
                // Freeze the finished burst before starting a new one so tool-call pauses never dilute tok/s.
                if let frozen = computeActiveBurstRate(state: st, at: prevAt) {
                    st.lastBurstTPS = frozen
                    st.lastBurstEndedAt = prevAt
                }
                st.burstSamples.removeAll(keepingCapacity: true)
                st.burstStartAt = now
            }

            if st.burstStartAt == nil {
                st.burstStartAt = now
            }
            st.burstSamples.append(ChunkSample(at: now, tokens: addedTokens))
            st.lastChunkAt = now

            let cutoff = now - slidingWindowSeconds
            if let firstValid = st.burstSamples.firstIndex(where: { $0.at >= cutoff }), firstValid > 0 {
                st.burstSamples.removeFirst(firstValid)
            }

            if let liveRate = computeActiveBurstRate(state: st, at: now) {
                st.lastBurstTPS = liveRate
                st.lastBurstEndedAt = now
            }
        }

        // If a host-timed thought finished without a multi-chunk sliding window rate (e.g., short or coalesced burst),
        // use Sarto's exact host-measured `durationMs`.
        if let completedThoughtRate, computeActiveBurstRate(state: st, at: now) == nil {
            st.lastBurstTPS = completedThoughtRate
            st.lastBurstEndedAt = now
        }

        reconcileSessionState(
            &st,
            session: replica.session,
            at: now,
            isInitialSnapshot: false,
            hasPriorTurnOutput: false
        )
        states[sessionId] = st
    }

    /// Produces a unified real-time telemetry snapshot for the composer bar and Optical Vial popover.
    public func snapshot(
        for replica: ThreadReplica,
        at now: TimeInterval = Date().timeIntervalSince1970
    ) -> LiveTelemetrySnapshot {
        let session = replica.session
        let st = states[session.id]
        let isRunning = session.status == .running || session.status == .awaitingPermission

        // 1. Output Speed (tok/s) & TTFT
        let activeBurstRate: Double? = {
            guard let st, let lastAt = st.lastChunkAt, (now - lastAt) <= burstGapSeconds else {
                return nil
            }
            return computeActiveBurstRate(state: st, at: now) ?? st.lastBurstTPS
        }()

        let hostLastSample = session.speed?.last
        let hostSessionRate = session.speed?.session?.rate
        let hostSampleIsFromPreviousTurn = isRunning && (st != nil) && (hostLastSample != nil) && (hostLastSample == st?.preTurnHostSpeedSample)
        let hostHasFreshSample: Bool = {
            guard let sample = hostLastSample, sample.rate > 0, !hostSampleIsFromPreviousTurn else { return false }
            if activeBurstRate == nil { return true }
            if let hostAt = st?.lastHostSpeedUpdatedAt, let chunkAt = st?.lastChunkAt, hostAt >= chunkAt {
                return true
            }
            return false
        }()

        let resolvedTPS: Double?
        let resolvedApprox: Bool
        if hostHasFreshSample, let sample = hostLastSample {
            resolvedTPS = sample.rate
            resolvedApprox = sample.approx ?? false
        } else if let burst = activeBurstRate {
            resolvedTPS = burst
            resolvedApprox = true
        } else if let sample = hostLastSample, sample.rate > 0, !hostSampleIsFromPreviousTurn {
            resolvedTPS = sample.rate
            resolvedApprox = sample.approx ?? false
        } else if let lastBurst = st?.lastBurstTPS, lastBurst > 0 {
            resolvedTPS = lastBurst
            resolvedApprox = true
        } else if let sample = hostLastSample, sample.rate > 0 {
            resolvedTPS = sample.rate
            resolvedApprox = sample.approx ?? false
        } else if let sessRate = hostSessionRate, sessRate > 0 {
            resolvedTPS = sessRate
            resolvedApprox = (session.speed?.session?.approx ?? 0) > 0
        } else {
            resolvedTPS = nil
            resolvedApprox = false
        }

        // Only fall back to hostLastSample?.firstTokenMs when not awaiting the first token of a new turn
        // (firstChunkAt != nil || !isRunning, or when opening an already-active snapshot whose sample is fresh).
        let awaitingNewTurnFirstToken = isRunning && (st?.firstChunkAt == nil) && (st?.awaitingFirstToken == true)
        let resolvedTTFT: Int? = {
            if awaitingNewTurnFirstToken {
                return st?.measuredTTFTMs
            }
            if hostSampleIsFromPreviousTurn, let measured = st?.measuredTTFTMs {
                return measured
            }
            if let ms = hostLastSample?.firstTokenMs, ms > 0 {
                return Int(round(ms))
            }
            return st?.measuredTTFTMs
        }()

        // 2. Live Context Delta during active turn (from Sarto's `turnStartUsed` or local pre-turn baseline)
        let turnContextDelta: Double? = {
            guard isRunning, let used = session.usage?.used else { return nil }
            let startUsed = session.turnStartUsed ?? st?.turnBaselineUsed
            guard let startUsed, used > startUsed else { return nil }
            return used - startUsed
        }()

        // 3. Multi-source Cache Hit Rate
        let sessionCachePct = session.usage?.tokens.flatMap(Self.cacheHitPercent(for:))
        let lastTurnCachePct = st?.lastTurnCacheHitPercent

        let primaryCachePct: Double?
        let cacheSource: LiveCacheSource
        if let liveReqPct = session.lastRequest?.cacheHitPercent {
            primaryCachePct = liveReqPct
            cacheSource = .liveRequest
        } else if isRunning {
            // ACP / agy does not emit per-request cacheRead mid-turn; expose prior turn/session rate
            // in the popover while signalling `.pendingTurn` so the compact strip avoids misleading stale copy.
            primaryCachePct = lastTurnCachePct ?? sessionCachePct
            cacheSource = .pendingTurn
        } else if let lastTurnCachePct {
            primaryCachePct = lastTurnCachePct
            cacheSource = .lastTurn
        } else if let sessionCachePct {
            primaryCachePct = sessionCachePct
            cacheSource = .session
        } else {
            primaryCachePct = nil
            cacheSource = .unavailable
        }

        return LiveTelemetrySnapshot(
            tps: resolvedTPS,
            tpsIsApprox: resolvedApprox,
            ttftMs: resolvedTTFT,
            primaryCacheHitPercent: primaryCachePct,
            sessionCacheHitPercent: sessionCachePct,
            cacheSource: cacheSource,
            turnContextDelta: turnContextDelta,
            isStreaming: isRunning
        )
    }

    public mutating func reset(sessionId: String) {
        states.removeValue(forKey: sessionId)
    }

    // MARK: - Internal Reconciliation

    private func computeActiveBurstRate(state st: SessionMetricsState, at now: TimeInterval) -> Double? {
        guard let first = st.burstSamples.first else { return nil }
        let windowStart = max(st.burstStartAt ?? first.at, now - slidingWindowSeconds)
        let elapsed = now - windowStart
        guard elapsed >= minBurstDurationSeconds else { return nil }
        let totalTokens = st.burstSamples.reduce(0.0) { $0 + $1.tokens }
        guard totalTokens >= 2.0 else { return nil }
        return min(500.0, max(1.0, totalTokens / elapsed))
    }

    /// Derives a real host-timed approximate speed from persisted `.thought(durationMs:)` entries
    /// for ACP sessions that do not report `session.speed` (filters out buffered bursts < 500 ms).
    public static func estimateHistoricalThoughtTPS(from entries: [ThreadEntry]) -> Double? {
        var fallbackRate: Double? = nil
        for entry in entries.reversed() {
            guard case .thought(_, let md, let streaming, let durationMs) = entry,
                  !streaming,
                  let durMs = durationMs,
                  durMs >= 500.0
            else { continue }
            let estTokens = estimateTokens(for: md)
            if estTokens >= 50.0 {
                return min(500.0, max(1.0, estTokens / (durMs / 1000.0)))
            }
            if fallbackRate == nil && estTokens >= 15.0 {
                fallbackRate = min(500.0, max(1.0, estTokens / (durMs / 1000.0)))
            }
        }
        return fallbackRate
    }

    /// Whether the current turn already produced agent output or tool calls before the latest batch.
    /// Used to avoid measuring fake multi-minute TTFT from `turnStartedAt` when attaching mid-turn.
    private static func hasPriorTurnOutput(in entries: [ThreadEntry], excludingIDs: Set<String>) -> Bool {
        for entry in entries.reversed() {
            switch entry {
            case .user, .turnEnd:
                return false
            case .thought(let id, _, _, _), .agent(let id, _, _, _, _):
                if !excludingIDs.contains(id) { return true }
            case .tool(let data):
                if !excludingIDs.contains(data.id) { return true }
            default:
                continue
            }
        }
        return false
    }

    private func beginRunningTurn(
        _ st: inout SessionMetricsState,
        session: SessionView,
        at now: TimeInterval,
        isInitialSnapshot: Bool = false,
        hasPriorTurnOutput: Bool = false
    ) {
        // Transitioned into a new running turn (e.g. triggered remotely, queued, or via another client).
        st.turnBaselineTokens = st.lastObservedTokens ?? session.usage?.tokens
        st.turnBaselineUsed = session.turnStartUsed ?? session.usage?.used
        st.burstSamples.removeAll(keepingCapacity: true)
        st.burstStartAt = nil
        st.lastChunkAt = nil
        st.firstChunkAt = nil
        st.measuredTTFTMs = nil
        st.preTurnHostSpeedSample = st.lastHostSpeedSample

        // Reattaching mid-turn after the agent already produced output or reported host speed:
        // do not start a client TTFT timer from `turnStartedAt`, which would measure turn elapsed time.
        let attachedMidTurn = hasPriorTurnOutput || (isInitialSnapshot && session.speed?.last != nil)
        st.awaitingFirstToken = !attachedMidTurn

        if attachedMidTurn {
            st.promptSentAt = nil
        } else if let startedMs = session.turnStartedAt {
            let startedSec = startedMs / 1000.0
            // Compare in Unix-epoch seconds (`timeIntervalSince1970`) when `now` is in epoch range.
            if now >= 1_000_000_000 && startedSec <= now + 60 {
                let age = max(0, now - startedSec)
                st.promptSentAt = now - age
            } else if now < 1_000_000_000 && startedSec < 1_000_000_000 && startedSec <= now {
                st.promptSentAt = startedSec
            } else {
                st.promptSentAt = now
            }
        } else {
            st.promptSentAt = now
        }
        st.wasRunning = true
    }

    private func reconcileSessionState(
        _ st: inout SessionMetricsState,
        session: SessionView,
        at now: TimeInterval,
        isInitialSnapshot: Bool,
        hasPriorTurnOutput: Bool
    ) {
        let isRunning = session.status == .running || session.status == .awaitingPermission

        if isRunning && !st.wasRunning {
            beginRunningTurn(
                &st,
                session: session,
                at: now,
                isInitialSnapshot: isInitialSnapshot,
                hasPriorTurnOutput: hasPriorTurnOutput
            )
        } else if !isRunning && st.wasRunning {
            // Turn just ended: freeze the final active burst reading if we have one.
            if let lastAt = st.lastChunkAt, let frozen = computeActiveBurstRate(state: st, at: lastAt) {
                st.lastBurstTPS = frozen
                st.lastBurstEndedAt = lastAt
            }
            st.burstSamples.removeAll(keepingCapacity: true)
            st.burstStartAt = nil
            st.awaitingFirstToken = false
        } else if !isRunning {
            st.awaitingFirstToken = false
        }

        if let turnStartUsed = session.turnStartUsed {
            st.turnBaselineUsed = turnStartUsed
        }

        if let currentTokens = session.usage?.tokens {
            if let baseline = st.turnBaselineTokens {
                let dInput = max(0, currentTokens.input - baseline.input)
                let dCacheRead = max(0, (currentTokens.cacheRead ?? 0) - (baseline.cacheRead ?? 0))
                let dCacheWrite = max(0, (currentTokens.cacheWrite ?? 0) - (baseline.cacheWrite ?? 0))
                let dDenom = dInput + dCacheRead + dCacheWrite
                if dDenom > 0 && (currentTokens.cacheRead != nil || dCacheRead > 0) {
                    st.lastTurnCacheHitPercent = max(0, min(100, (dCacheRead / dDenom) * 100.0))
                }
            } else if st.lastObservedTokens == nil && !isRunning {
                // First snapshot of an already-existing session: leave `lastTurnCacheHitPercent` nil
                // so `.session` accurately labels it as session cumulative until a new turn finishes.
            }
            st.lastObservedTokens = currentTokens
        }

        if let hostSample = session.speed?.last, hostSample != st.lastHostSpeedSample {
            if st.awaitingFirstToken && hostSample != st.preTurnHostSpeedSample {
                st.awaitingFirstToken = false
            }
            st.lastHostSpeedSample = hostSample
            st.lastHostSpeedUpdatedAt = now
        }

        st.wasRunning = isRunning
    }
}
