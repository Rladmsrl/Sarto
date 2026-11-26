import Foundation

// MARK: - Edit From a Sent Message (sessions.rewind / sessions.putBack)

extension SartoHostSession {
    /// `sessions.rewind`: takes the session back to before `entryId`, one of the user's messages. The turns
    /// from it on are set aside until the next send, and its content comes back for the composer, each
    /// attachment as a new record. `draft` is what the composer held, which Put back gives back.
    public func rewindSession(sessionId: String, entryId: String, draft: [UserContent]) async throws -> [UserContent] {
        let draftValue = try JSONValue(jsonData: JSONEncoder().encode(draft))
        let result = try await request(
            "sessions.rewind",
            params: .object([
                "sessionId": .string(sessionId),
                "entryId": .string(entryId),
                "draft": draftValue,
            ]),
            as: SessionRewindResult.self
        )
        return result.content
    }

    /// `sessions.putBack`: brings back the turns an edit set aside, with the draft the composer held before it.
    public func putBackSession(sessionId: String) async throws -> [UserContent] {
        let result = try await request(
            "sessions.putBack",
            params: .object(["sessionId": .string(sessionId)]),
            as: SessionPutBackResult.self
        )
        return result.draft
    }
}
