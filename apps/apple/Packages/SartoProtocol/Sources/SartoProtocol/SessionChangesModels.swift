import Foundation

/// Where a copy of a host's session index stands, as `sessions.changes` gave it last.
public struct SessionsCursorInfo: Codable, Sendable, Equatable {
    /// The run of the agent host that numbered the changes.
    public let boot: String
    public let rev: Int

    public init(boot: String, rev: Int) {
        self.boot = boot
        self.rev = rev
    }
}

/// What changed in a host's session index since a cursor (`sessions.changes`).
public struct SessionChangesInfo: Decodable, Sendable, Equatable {
    public let cursor: SessionsCursorInfo
    /// Whether `summaries` is the whole index, as for a cursor of another run or none.
    public let full: Bool
    public let summaries: [SessionSummary]
    /// Every listed session's id.
    public let ids: [String]

    public init(cursor: SessionsCursorInfo, full: Bool, summaries: [SessionSummary], ids: [String]) {
        self.cursor = cursor
        self.full = full
        self.summaries = summaries
        self.ids = ids
    }

    /// The index after these changes, newest first; nil when `current` lacks a session these
    /// changes take for known, and the whole index must be read again.
    public func applied(to current: [SessionSummary]) -> [SessionSummary]? {
        if full { return summaries.sorted { $0.updatedAt > $1.updatedAt } }
        var byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for summary in summaries { byId[summary.id] = summary }
        var next: [SessionSummary] = []
        next.reserveCapacity(ids.count)
        for id in ids {
            guard let summary = byId[id] else { return nil }
            next.append(summary)
        }
        return next.sorted { $0.updatedAt > $1.updatedAt }
    }
}
