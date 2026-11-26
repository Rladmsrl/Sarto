import Foundation

// MARK: - Edit From a Sent Message (sessions.rewind / sessions.putBack)
//
// Mirrors `RewoundView` and the rewind fields of src/shared/thread.ts, the `sessions.rewind` and
// `sessions.putBack` results of src/shared/agent-host.ts, and the rules of src/shared/rewind.ts.

/// Set while an edit from a message holds the turns from it aside, until the next send.
public struct RewoundView: Codable, Sendable, Equatable {
    /// The turns set aside, which Put back brings back.
    public let turns: Int

    public init(turns: Int) {
        self.turns = turns
    }
}

/// The result of `sessions.rewind`: the edited message, its attachments as new records, for the composer.
public struct SessionRewindResult: Codable, Sendable, Equatable {
    public let content: [UserContent]

    public init(content: [UserContent]) {
        self.content = content
    }
}

/// The result of `sessions.putBack`: what the composer held before the edit.
public struct SessionPutBackResult: Codable, Sendable, Equatable {
    public let draft: [UserContent]

    public init(draft: [UserContent]) {
        self.draft = draft
    }
}

extension SessionView {
    /// Applies the rewind fields of a `session.update` patch; null clears them.
    mutating func applyRewindChanges(_ changes: [String: JSONValue]) {
        if let value = changes["rewound"] {
            rewound = value == .null ? nil : (try? value.decode(RewoundView.self))
        }
        if let value = changes["noRewind"] {
            noRewind = value == .null ? nil : value.boolValue
        }
    }
}

// MARK: - Entry Extras

/// Fields of a thread entry that its `ThreadEntry` case does not carry, kept beside it by entry id
/// so the cases keep their shapes: a user entry's `agentRef`, `from` and `sarto`, and a turn end's
/// `used`. Hosts older than the edit feature send none of them.
public struct ThreadEntryExtras: Codable, Sendable, Equatable {
    /// The agent's own id for the prompt that started the turn, which an edit cuts the agent's session at.
    public var agentRef: String?
    /// The prompt came from another session's agent (`from` is set).
    public var fromSession: Bool
    /// Structured sender metadata when another session started, messaged, or reported to this session.
    public var from: FromSession?
    /// Structured device metadata when a paired device sent this prompt.
    public var device: FromDevice?
    /// Sarto itself wrote the message to the agent, such as a workflow step's prompt.
    public var sarto: Bool
    /// The context in tokens as the turn ended.
    public var used: Double?

    public init(
        agentRef: String? = nil,
        fromSession: Bool = false,
        from: FromSession? = nil,
        device: FromDevice? = nil,
        sarto: Bool = false,
        used: Double? = nil
    ) {
        self.agentRef = agentRef
        self.fromSession = fromSession || from != nil
        self.from = from
        self.device = device
        self.sarto = sarto
        self.used = used
    }

    public var isEmpty: Bool {
        agentRef == nil && !fromSession && from == nil && device == nil && !sarto && used == nil
    }

    static let trackedKinds: Set<String> = ["user", "turn_end"]
    static let trackedKeys: Set<String> = ["agentRef", "from", "device", "sarto", "used"]

    /// The extras of one entry's JSON object, nil when it has none.
    init?(entryObject obj: [String: JSONValue]) {
        guard let kind = obj["kind"]?.stringValue, Self.trackedKinds.contains(kind) else { return nil }
        var extras = ThreadEntryExtras()
        extras.merge(changes: obj)
        guard !extras.isEmpty else { return nil }
        self = extras
    }

    /// Merges an `entry.update`'s changes or an entry's own fields; null or a missing value clears nothing
    /// it does not name.
    mutating func merge(changes: [String: JSONValue]) {
        if let value = changes["agentRef"] {
            agentRef = value.stringValue
        }
        if let value = changes["from"] {
            if value == .null {
                fromSession = false
                from = nil
            } else {
                fromSession = true
                from = try? value.decode(FromSession.self)
            }
        }
        if let value = changes["device"] {
            device = value == .null ? nil : (try? value.decode(FromDevice.self))
        }
        if let value = changes["sarto"] {
            sarto = value.boolValue == true
        }
        if let value = changes["used"] {
            used = value.doubleValue
        }
    }

    /// The extras of added entries' JSON objects, by entry id; a later entry with the same id wins.
    static func collect(fromEntries values: [JSONValue]) -> [String: ThreadEntryExtras] {
        var map: [String: ThreadEntryExtras] = [:]
        for value in values {
            guard let obj = value.objectValue, let id = obj["id"]?.stringValue else { continue }
            map[id] = ThreadEntryExtras(entryObject: obj)
        }
        return map
    }
}

/// Reads an entry's extras from its JSON object, never failing: a field of the wrong type is left out.
struct ThreadEntryExtrasProbe: Decodable {
    let id: String?
    let extras: ThreadEntryExtras?

    private enum CodingKeys: String, CodingKey {
        case kind, id, agentRef, from, device, sarto, used
    }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let id = try? c.decode(String.self, forKey: .id),
              let kind = try? c.decode(String.self, forKey: .kind),
              ThreadEntryExtras.trackedKinds.contains(kind)
        else {
            self.id = nil
            self.extras = nil
            return
        }
        let decodedFrom = try? c.decodeIfPresent(FromSession.self, forKey: .from)
        let hasFrom = decodedFrom != nil || (c.contains(.from) && (try? c.decodeNil(forKey: .from)) == false)
        let extras = ThreadEntryExtras(
            agentRef: try? c.decodeIfPresent(String.self, forKey: .agentRef),
            fromSession: hasFrom,
            from: decodedFrom,
            device: try? c.decodeIfPresent(FromDevice.self, forKey: .device),
            sarto: (try? c.decodeIfPresent(Bool.self, forKey: .sarto)) == true,
            used: try? c.decodeIfPresent(Double.self, forKey: .used)
        )
        self.id = id
        self.extras = extras.isEmpty ? nil : extras
    }
}

/// One entry and its extras, read from the same JSON object in one pass of the array.
struct ThreadEntryWithExtras: Decodable {
    let entry: ThreadEntry
    let extras: ThreadEntryExtras?

    init(from decoder: Decoder) throws {
        self.entry = try ThreadEntry(from: decoder)
        self.extras = ThreadEntryExtrasProbe(from: decoder).extras
    }

    static func extrasById(_ read: [ThreadEntryWithExtras]) -> [String: ThreadEntryExtras] {
        var map: [String: ThreadEntryExtras] = [:]
        for item in read {
            map[item.entry.id] = item.extras
        }
        return map
    }
}

/// One patch and, for an `entry.add`, its entry's extras.
struct ThreadPatchWithExtras: Decodable {
    let patch: ThreadPatch
    let extras: ThreadEntryExtras?

    private enum CodingKeys: String, CodingKey {
        case entry
    }

    init(from decoder: Decoder) throws {
        self.patch = try ThreadPatch(from: decoder)
        if case .entryAdd = patch, let c = try? decoder.container(keyedBy: CodingKeys.self) {
            self.extras = (try? c.decode(ThreadEntryExtrasProbe.self, forKey: .entry))?.extras
        } else {
            self.extras = nil
        }
    }

    static func extrasById(_ read: [ThreadPatchWithExtras]) -> [String: ThreadEntryExtras] {
        var map: [String: ThreadEntryExtras] = [:]
        for item in read {
            guard case .entryAdd(let entry) = item.patch else { continue }
            map[entry.id] = item.extras
        }
        return map
    }
}

extension ThreadReplica {
    /// Keeps `entryExtras` in step with a patch about to be applied.
    mutating func trackEntryExtras(_ patch: ThreadPatch, added: [String: ThreadEntryExtras]) {
        switch patch {
        case .threadReset:
            entryExtras.removeAll()
        case .threadTruncate(let id):
            guard !entryExtras.isEmpty, let at = order.firstIndex(of: id) else { return }
            for dropped in order[at...] {
                entryExtras.removeValue(forKey: dropped)
            }
        case .entryAdd(let entry):
            entryExtras[entry.id] = added[entry.id]
        case .entryUpdate(let id, let changes):
            guard changes.keys.contains(where: ThreadEntryExtras.trackedKeys.contains) else { return }
            switch byId[id] {
            case .user?, .turnEnd?:
                var extras = entryExtras[id] ?? ThreadEntryExtras()
                extras.merge(changes: changes)
                entryExtras[id] = extras.isEmpty ? nil : extras
            default:
                return
            }
        case .entryAppendText, .sessionUpdate, .unknown:
            return
        }
    }
}

// MARK: - Rewind Rules (src/shared/rewind.ts)

/// What an edit from a message takes away and stops, for its confirmation.
public struct RewindFacts: Sendable, Equatable {
    /// The turns that leave, the edited message's included.
    public let turns: Int
    /// Files changed since, which stay as they are.
    public let files: Int
    /// Commands ran since.
    public let commands: Bool
    /// A turn runs, which the edit stops.
    public let running: Bool
    /// Background tasks that run, which the edit stops.
    public let tasks: Int
    /// The context in tokens up to the message, which an expired cache sends again; nil when unknown.
    public let kept: Double?

    public init(turns: Int, files: Int, commands: Bool, running: Bool, tasks: Int, kept: Double?) {
        self.turns = turns
        self.files = files
        self.commands = commands
        self.running = running
        self.tasks = tasks
        self.kept = kept
    }

    /// Only the last message, whose turn changed no files and ran nothing, goes back unasked.
    public var needsConfirmation: Bool {
        turns > 1 || files > 0 || commands || running || tasks > 0
    }
}

public enum SessionRewind {
    /// The text of a message for the composer, its text parts joined by a blank line.
    public static func promptText(_ content: [UserContent]) -> String {
        content.compactMap(\.text).joined(separator: "\n\n")
    }

    /// The attachments a message holds.
    public static func attachments(_ content: [UserContent]) -> [AttachmentInfo] {
        content.compactMap { part in
            if case .ref(.attachment(let attachment)) = part { return attachment }
            return nil
        }
    }
}

extension ThreadReplica {
    /// A message the user sent as a turn of its own: not one steered into a running turn, nor one
    /// another session's agent, Sarto or a card's answer wrote.
    public func isOwnPrompt(_ entryId: String) -> Bool {
        guard case .user(_, _, _, _, let approval, let steered)? = byId[entryId], !approval, !steered else {
            return false
        }
        let extras = entryExtras[entryId]
        return extras?.fromSession != true && extras?.sarto != true
    }

    /// Where the latest agent switch is in the loaded thread, -1 for none: an edit goes back no further.
    public var lastSwitchIndex: Int {
        order.lastIndex { id in
            if case .takeover? = byId[id] { return true }
            return false
        } ?? -1
    }

    /// Whether an edit can start from the entry, judged on the loaded thread.
    public func canEditFrom(_ entryId: String) -> Bool {
        guard let at = order.firstIndex(of: entryId) else { return false }
        return at > lastSwitchIndex && isOwnPrompt(entryId)
    }

    /// Every message an edit can start from: the user's own prompts after the latest agent switch.
    public var editableEntryIDs: Set<String> {
        var ids: Set<String> = []
        for id in order.reversed() {
            guard let entry = byId[id] else { continue }
            if case .takeover = entry { break }
            if case .user = entry, isOwnPrompt(id) { ids.insert(id) }
        }
        return ids
    }

    /// The turns an edit from the entry at `index` takes away: every message from it on that opened one.
    public func turnsFrom(_ index: Int) -> Int {
        guard index < order.count else { return 0 }
        var turns = 0
        for id in order[max(0, index)...] {
            if case .user(_, _, _, _, _, let steered)? = byId[id], !steered { turns += 1 }
        }
        return turns
    }

    /// The context in tokens as the last turn before `index` ended: 0 with no turn before, nil when it
    /// did not say.
    public func usedAtEnd(before index: Int) -> Double? {
        var at = min(index, order.count) - 1
        while at >= 0 {
            if case .turnEnd? = byId[order[at]] {
                return entryExtras[order[at]]?.used
            }
            at -= 1
        }
        return 0
    }

    /// What an edit from `entryId` takes away and stops; nil when the entry is not in the thread.
    public func rewindFacts(from entryId: String) -> RewindFacts? {
        guard let at = order.firstIndex(of: entryId) else { return nil }
        var files: Set<String> = []
        var commands = false
        for id in order[at...] {
            guard case .tool(let tool)? = byId[id] else { continue }
            if tool.toolKind == "execute" { commands = true }
            guard ["edit", "delete", "move"].contains(tool.toolKind), tool.status == "completed" else { continue }
            for location in tool.locations { files.insert(location.path) }
            for item in tool.content {
                if case .diff(let path, _, _) = item { files.insert(path) }
            }
        }
        return RewindFacts(
            turns: turnsFrom(at),
            files: files.count,
            commands: commands,
            running: session.status == .running || session.status == .awaitingPermission,
            tasks: session.background.filter { $0.status == "running" }.count,
            kept: usedAtEnd(before: at)
        )
    }
}
