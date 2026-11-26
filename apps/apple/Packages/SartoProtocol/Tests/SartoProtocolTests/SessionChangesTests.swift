import Foundation
import Testing
@testable import SartoProtocol

private func summary(_ id: String, title: String, updatedAt: Double) throws -> SessionSummary {
    let json = """
    {
      "id": "\(id)",
      "agentId": "claude-code",
      "projectPath": "/work/app",
      "title": "\(title)",
      "status": "ready",
      "attention": "none",
      "permissionCount": 0,
      "createdAt": 1700000000000,
      "updatedAt": \(updatedAt),
      "parentId": null,
      "origin": "user",
      "branch": null,
      "model": null,
      "pinnedAt": null,
      "archivedAt": null,
      "acpSessionId": null
    }
    """
    return try JSONDecoder().decode(SessionSummary.self, from: Data(json.utf8))
}

private let cursor = SessionsCursorInfo(boot: "run", rev: 9)

@Suite("A session index read again as its changes")
struct SessionChangesTests {
    @Test("Changed summaries replace the copy's, sessions that went leave, newest first")
    func merges() throws {
        let a = try summary("a", title: "A", updatedAt: 1)
        let b = try summary("b", title: "B", updatedAt: 2)
        let gone = try summary("gone", title: "Gone", updatedAt: 3)
        let newerA = try summary("a", title: "A again", updatedAt: 5)
        let changes = SessionChangesInfo(cursor: cursor, full: false, summaries: [newerA], ids: ["b", "a"])
        let merged = try #require(changes.applied(to: [a, b, gone]))
        #expect(merged.map(\.id) == ["a", "b"])
        #expect(merged.first?.title == "A again")
    }

    @Test("A session the copy lacks asks for the whole index")
    func missing() throws {
        let a = try summary("a", title: "A", updatedAt: 1)
        let changes = SessionChangesInfo(cursor: cursor, full: false, summaries: [], ids: ["a", "unknown"])
        #expect(changes.applied(to: [a]) == nil)
    }

    @Test("The whole index replaces the copy")
    func whole() throws {
        let a = try summary("a", title: "A", updatedAt: 1)
        let b = try summary("b", title: "B", updatedAt: 2)
        let changes = SessionChangesInfo(cursor: cursor, full: true, summaries: [a, b], ids: ["a", "b"])
        #expect(changes.applied(to: [try summary("old", title: "Old", updatedAt: 9)])?.map(\.id) == ["b", "a"])
    }
}
