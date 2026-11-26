import Foundation

/// What a host's own sessions' work came to (`work.facts`, `src/shared/work-facts.ts`), for the
/// Agent RPG. A host tells only of the sessions it runs, so each fact is counted once.
public struct WorkFact: Decodable, Sendable, Equatable, Identifiable {
    public enum WorkKind: String, Decodable, Sendable {
        case think, scan, command, edit
    }

    public enum Kind: Sendable, Equatable {
        /// Seconds of a running turn, all spent on `work`; `child` for a user-started sub-session.
        case active(seconds: Int, work: WorkKind, child: Bool)
        case permissionGranted
        case todoCompleted(count: Int)
        case planCompleted(steps: Int)
        case turnEnded(ok: Bool)
        /// A kind a newer host sends; skipped.
        case unknown(String)
    }

    public let id: String
    public let sessionId: String
    public let agentId: String
    /// When the host saw it, in ms since the epoch.
    public let at: Double
    public let kind: Kind

    public init(id: String, sessionId: String, agentId: String, at: Double, kind: Kind) {
        self.id = id
        self.sessionId = sessionId
        self.agentId = agentId
        self.at = at
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, agentId, at, kind, seconds, work, child, count, steps, ok
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agentId = try c.decode(String.self, forKey: .agentId)
        at = try c.decode(Double.self, forKey: .at)
        let raw = try c.decode(String.self, forKey: .kind)
        switch raw {
        case "work.active":
            kind = .active(
                seconds: try c.decode(Int.self, forKey: .seconds),
                work: (try? c.decode(WorkKind.self, forKey: .work)) ?? .edit,
                child: (try? c.decode(Bool.self, forKey: .child)) ?? false
            )
        case "permission.granted":
            kind = .permissionGranted
        case "todo.completed":
            kind = .todoCompleted(count: try c.decode(Int.self, forKey: .count))
        case "plan.completed":
            kind = .planCompleted(steps: try c.decode(Int.self, forKey: .steps))
        case "turn.ended":
            kind = .turnEnded(ok: try c.decode(Bool.self, forKey: .ok))
        default:
            kind = .unknown(raw)
        }
    }

    /// Decodes each fact on its own, so one that cannot be read leaves the others.
    static func decodeList(_ value: JSONValue) -> [WorkFact] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { try? $0.decode(WorkFact.self) }
    }
}
