import Foundation

// MARK: - 1. FZF-Style Path & Folder Matching (mirrors src/renderer/src/features/files/paths.ts & mentions.ts)

public struct ComposerMentionRow: Sendable, Equatable, Identifiable {
    public var id: String { "\(isFolder ? "d" : "f"):\(path)" }
    public let path: String
    public let isFolder: Bool
    /// Character offsets into `path` (or `path + "/"` for folders) that matched the query.
    public let positions: [Int]

    public init(path: String, isFolder: Bool, positions: [Int] = []) {
        self.path = path
        self.isFolder = isFolder
        self.positions = positions
    }

    /// The token inserted into the prompt after `@`: filename, or folder name with trailing `/`.
    public var mentionName: String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return isFolder ? "\(base)/" : base
    }
}

public struct ComposerMarkedRun: Sendable, Equatable {
    public let text: String
    public let marked: Bool

    public init(text: String, marked: Bool) {
        self.text = text
        self.marked = marked
    }
}

public enum ComposerPathMatcher {
    public static let mentionLimit = 50
    private static let separators: Set<Character> = ["/", "-", "_", ".", " "]

    /// Every folder containing at least one file in `files`, with trailing `/`.
    public static func folders(of files: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for file in files {
            var idx = file.lastIndex(of: "/")
            while let slash = idx, slash > file.startIndex {
                let folder = String(file[...slash])
                if !seen.insert(folder).inserted {
                    break
                }
                result.append(folder)
                let before = file.index(before: slash)
                idx = file[..<before].lastIndex(of: "/")
            }
        }
        return result
    }

    private struct ScoredPath {
        let path: String
        let isFolder: Bool
        let score: Double
        let positions: [Int]
    }

    private static func normalizeQuery(_ query: String) -> [Character] {
        Array(query.lowercased().filter { !$0.isWhitespace })
    }

    /// Fzf-style forward-then-backward shortest-stretch scoring with bonuses for consecutive matches,
    /// word boundaries and filename matches.
    public static func scorePath(query: String, path: String) -> (score: Double, positions: [Int])? {
        let q = normalizeQuery(query)
        guard !q.isEmpty else { return (0, []) }
        let chars = Array(path)
        let lower = chars.map { Character(String($0).lowercased()) }
        guard !chars.isEmpty else { return nil }

        // Last '/' before the final character (ignoring a folder's trailing '/').
        var nameStart = 0
        if chars.count >= 2 {
            for i in stride(from: chars.count - 2, through: 0, by: -1) {
                if chars[i] == "/" {
                    nameStart = i + 1
                    break
                }
            }
        }

        // Forward scan to end of first full subsequence match.
        var at = 0
        for ch in q {
            var found = false
            while at < lower.count {
                if lower[at] == ch {
                    found = true
                    at += 1
                    break
                }
                at += 1
            }
            if !found { return nil }
        }
        at -= 1

        // Backward scan to tighten onto the shortest stretch ending at `at`.
        var positions = Array(repeating: 0, count: q.count)
        for i in stride(from: q.count - 1, through: 0, by: -1) {
            while lower[at] != q[i] {
                at -= 1
            }
            positions[i] = at
            at -= 1
        }

        var score = 0.0
        for i in 0..<q.count {
            let idx = positions[i]
            score += 1
            if i > 0 && positions[i - 1] == idx - 1 { score += 5 }
            if idx == 0 || separators.contains(chars[idx - 1]) { score += 4 }
            if idx >= nameStart { score += 2 }
        }
        return (score - Double(chars.count) / 1000.0, positions)
    }

    /// Best matching project files and folders for `query`, sorted by score descending then path ascending.
    public static func matchMentions(
        query: String,
        files: [String],
        folders: [String]? = nil,
        limit: Int = mentionLimit
    ) -> [ComposerMentionRow] {
        guard limit > 0 else { return [] }
        let folderList = folders ?? Self.folders(of: files)
        let q = normalizeQuery(query)
        var best: [ScoredPath] = []
        best.reserveCapacity(min(limit + 1, 64))

        func consider(_ rawPath: String, isFolder: Bool) {
            let scored: (score: Double, positions: [Int])
            if q.isEmpty {
                scored = (0, [])
            } else if let hit = scorePath(query: query, path: rawPath) {
                scored = hit
            } else {
                return
            }
            let item = ScoredPath(path: rawPath, isFolder: isFolder, score: scored.score, positions: scored.positions)
            if best.count == limit, let tail = best.last, !ranksBefore(item, tail) {
                return
            }
            var low = 0
            var high = best.count
            while low < high {
                let mid = (low + high) >> 1
                if ranksBefore(item, best[mid]) {
                    high = mid
                } else {
                    low = mid + 1
                }
            }
            best.insert(item, at: low)
            if best.count > limit {
                best.removeLast()
            }
        }

        for file in files { consider(file, isFolder: false) }
        for folder in folderList { consider(folder, isFolder: true) }

        return best.map { item in
            let cleanPath = item.isFolder && item.path.hasSuffix("/")
                ? String(item.path.dropLast())
                : item.path
            return ComposerMentionRow(path: cleanPath, isFolder: item.isFolder, positions: item.positions)
        }
    }

    private static func ranksBefore(_ lhs: ScoredPath, _ rhs: ScoredPath) -> Bool {
        lhs.score > rhs.score || (lhs.score == rhs.score && lhs.path < rhs.path)
    }

    /// Splits `segment` (starting at character index `offset` in the full path) into runs of matched
    /// and unmatched characters for highlight rendering.
    public static func markedRuns(
        text: String,
        offset: Int,
        positions: [Int]
    ) -> [ComposerMarkedRun] {
        guard !text.isEmpty else { return [] }
        if positions.isEmpty { return [ComposerMarkedRun(text: text, marked: false)] }
        let marked = Set(positions)
        let chars = Array(text)
        var runs: [ComposerMarkedRun] = []
        var start = 0
        for i in 1...chars.count {
            if i < chars.count && marked.contains(offset + i) == marked.contains(offset + start) {
                continue
            }
            runs.append(ComposerMarkedRun(
                text: String(chars[start..<i]),
                marked: marked.contains(offset + start)
            ))
            start = i
        }
        return runs
    }

    /// Files the session's `read` / `edit` tool calls touched, most recent first, intersected with `known`.
    public static func usedFiles(
        from entries: [ThreadEntry],
        projectPath: String,
        known: Set<String>,
        limit: Int = mentionLimit
    ) -> [String] {
        guard !known.isEmpty, limit > 0 else { return [] }
        var used: [String] = []
        var seen = Set<String>()
        for entry in entries.reversed() {
            guard case .tool(let tool) = entry else { continue }
            guard tool.toolKind == "read" || tool.toolKind == "edit" else { continue }
            var candidates: [String] = tool.locations.map(\.path)
            for item in tool.content {
                switch item {
                case .diff(let path, _, _):
                    candidates.append(path)
                case .digest(_, let path?, _, _, _, _):
                    candidates.append(path)
                default:
                    break
                }
            }
            for raw in candidates {
                let rel = normalizeRelativePath(raw, projectPath: projectPath)
                guard !rel.isEmpty, known.contains(rel), seen.insert(rel).inserted else { continue }
                used.append(rel)
                if used.count >= limit { return used }
            }
        }
        return used
    }

    public static func normalizeRelativePath(_ path: String, projectPath: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let root = projectPath.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !root.isEmpty {
            let prefix = "/\(root)/"
            if normalized.hasPrefix(prefix) {
                return String(normalized.dropFirst(prefix.count))
            }
            let rawPrefix = "\(root)/"
            if normalized.hasPrefix(rawPrefix) {
                return String(normalized.dropFirst(rawPrefix.count))
            }
        }
        if normalized.hasPrefix("./") {
            return String(normalized.dropFirst(2))
        }
        return normalized
    }
}

// MARK: - 2. Caret-Aware `@` & `/` Triggers + Replacement (mirrors trigger.ts, mentions.ts, slash.ts)

public struct ComposerMentionToken: Sendable, Equatable {
    public let startUTF16: Int
    public let endUTF16: Int
    public let query: String

    public init(startUTF16: Int, endUTF16: Int, query: String) {
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.query = query
    }
}

public struct ComposerSlashToken: Sendable, Equatable {
    public let startUTF16: Int
    public let endUTF16: Int
    public let query: String

    public init(startUTF16: Int, endUTF16: Int, query: String) {
        self.startUTF16 = startUTF16
        self.endUTF16 = endUTF16
        self.query = query
    }
}

public struct ComposerTextEdit: Sendable, Equatable {
    public let text: String
    public let caretUTF16: Int

    public init(text: String, caretUTF16: Int) {
        self.text = text
        self.caretUTF16 = caretUTF16
    }
}

public enum ComposerTrigger {
    private static let asciiAt: UInt16 = 0x0040
    private static let fullWidthAt: UInt16 = 0xFF20
    private static let asciiSlash: UInt16 = 0x002F

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// True at text start, after whitespace, or after any non-ASCII character (so Chinese text
    /// without spaces can trigger `@` or `/` directly, while `a@b` and `a/b` stay plain text).
    public static func startsWord(in units: [UInt16], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let prev = units[index - 1]
        return isWhitespace(prev) || prev > 0x7F
    }

    public static func startsWord(in text: String, at utf16Index: Int) -> Bool {
        let units = Array(text.utf16)
        guard utf16Index >= 0 && utf16Index <= units.count else { return false }
        return startsWord(in: units, at: utf16Index)
    }

    /// The nearest `@` or full-width `@` before `caretUTF16` in the current word that starts a word.
    public static func mentionAt(text: String, caretUTF16: Int?) -> ComposerMentionToken? {
        guard let caret = caretUTF16 else { return nil }
        let units = Array(text.utf16)
        guard caret >= 0 && caret <= units.count else { return nil }
        var at = caret - 1
        while at >= 0 && !isWhitespace(units[at]) {
            if (units[at] == asciiAt || units[at] == fullWidthAt) && startsWord(in: units, at: at) {
                let query = String(decoding: units[(at + 1)..<caret], as: UTF16.self)
                return ComposerMentionToken(startUTF16: at, endUTF16: caret, query: query)
            }
            at -= 1
        }
        return nil
    }

    /// The nearest `/` before `caretUTF16` in the current word that starts a word, extending to the end of its word.
    public static func slashAt(text: String, caretUTF16: Int?) -> ComposerSlashToken? {
        guard let caret = caretUTF16 else { return nil }
        let units = Array(text.utf16)
        guard caret >= 0 && caret <= units.count else { return nil }
        var at = caret - 1
        while at >= 0 && !isWhitespace(units[at]) {
            if units[at] == asciiSlash && startsWord(in: units, at: at) {
                var end = caret
                while end < units.count && !isWhitespace(units[end]) {
                    end += 1
                }
                let query = String(decoding: units[(at + 1)..<end], as: UTF16.self)
                return ComposerSlashToken(startUTF16: at, endUTF16: end, query: query)
            }
            at -= 1
        }
        return nil
    }

    /// Prefix matches first, then name-substring matches, then description matches, preserving agent order within each tier.
    public static func orderSlashMatches(commands: [SlashCommand], query: String) -> [SlashCommand] {
        let needle = query.lowercased()
        if needle.isEmpty { return commands }
        var starts: [SlashCommand] = []
        var contains: [SlashCommand] = []
        var descMatches: [SlashCommand] = []
        for cmd in commands {
            let name = cmd.name.lowercased()
            if name.hasPrefix(needle) {
                starts.append(cmd)
            } else if name.contains(needle) {
                contains.append(cmd)
            } else if cmd.description.lowercased().contains(needle) {
                descMatches.append(cmd)
            }
        }
        return starts + contains + descMatches
    }

    /// UTF-16 length of the leading `/command` when it matches one of `names` exactly, else 0.
    public static func leadingCommandLengthUTF16(in text: String, names: [String]) -> Int {
        guard text.hasPrefix("/"), !names.isEmpty else { return 0 }
        let units = Array(text.utf16)
        var end = 1
        while end < units.count && !isWhitespace(units[end]) {
            end += 1
        }
        guard end > 1 else { return 0 }
        let name = String(decoding: units[1..<end], as: UTF16.self)
        return names.contains(name) ? end : 0
    }

    /// Replaces only the typed `@query` up to the caret with `@name `, preserving everything after the caret.
    public static func replaceMention(text: String, mention: ComposerMentionToken, name: String) -> ComposerTextEdit {
        let ns = text as NSString
        let prefix = ns.substring(to: mention.startUTF16)
        let after = ns.substring(from: mention.endUTF16)
        let before = "\(prefix)@\(name)"
        let next = after.hasPrefix(" ") ? "\(before)\(after)" : "\(before) \(after)"
        return ComposerTextEdit(text: next, caretUTF16: (before as NSString).length + 1)
    }

    /// Replaces the typed `@query` up to the caret with a full mention token (such as `@[Session Title]`)
    /// followed by a space when needed, preserving everything after the caret.
    public static func replaceSessionMention(
        text: String,
        mention: ComposerMentionToken,
        token: String
    ) -> ComposerTextEdit {
        let ns = text as NSString
        let prefix = ns.substring(to: mention.startUTF16)
        let after = ns.substring(from: mention.endUTF16)
        let before = "\(prefix)\(token)"
        let next = after.hasPrefix(" ") ? "\(before)\(after)" : "\(before) \(after)"
        return ComposerTextEdit(text: next, caretUTF16: (before as NSString).length + 1)
    }

    /// Places `/name ` at the start of `text`, removing the typed `/query` word and any previous leading command,
    /// keeping the caret right where the user was typing.
    public static func placeCommand(
        text: String,
        slash: ComposerSlashToken,
        name: String,
        knownNames: [String]
    ) -> ComposerTextEdit {
        let ns = text as NSString
        let head = "/\(name) "
        let headLen = (head as NSString).length
        if slash.startUTF16 == 0 {
            let after = ns.substring(from: slash.endUTF16)
            let trimmedAfter = after.hasPrefix(" ") ? String(after.dropFirst()) : after
            return ComposerTextEdit(text: "\(head)\(trimmedAfter)", caretUTF16: headLen)
        }
        let before = ns.substring(to: slash.startUTF16)
        let after = ns.substring(from: slash.endUTF16)
        let joinedAfter = (before.hasSuffix(" ") && after.hasPrefix(" ")) ? String(after.dropFirst()) : after
        var rest = before + joinedAfter
        var caret = (before as NSString).length
        let led = leadingCommandLengthUTF16(in: rest, names: knownNames)
        if led > 0 {
            let restNS = rest as NSString
            let hasSpace = led < restNS.length && restNS.character(at: led) == 0x20
            let drop = hasSpace ? led + 1 : led
            rest = restNS.substring(from: drop)
            caret -= drop
        }
        let restUnits = Array(rest.utf16)
        var blank = 0
        while blank < restUnits.count && isWhitespace(restUnits[blank]) {
            blank += 1
        }
        let tail = (rest as NSString).substring(from: blank)
        return ComposerTextEdit(text: "\(head)\(tail)", caretUTF16: headLen + max(0, caret - blank))
    }

    /// Inserts `@` or `/` at the current selection with a leading space when not at a word boundary.
    public static func insertSign(text: String, fromUTF16: Int, toUTF16: Int, sign: String) -> ComposerTextEdit {
        let ns = text as NSString
        let safeFrom = max(0, min(fromUTF16, ns.length))
        let safeTo = max(safeFrom, min(toUTF16, ns.length))
        let before = ns.substring(to: safeFrom)
        let after = ns.substring(from: safeTo)
        let needsSpace = !before.isEmpty && !(before.last?.isWhitespace ?? false)
        let typed = needsSpace ? " \(sign)" : sign
        let next = before + typed + after
        return ComposerTextEdit(text: next, caretUTF16: safeFrom + (typed as NSString).length)
    }
}

// MARK: - 3. Inline Chips & Links Parser (mirrors chips.ts)

public struct ComposerGitHubRef: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case issue
        case pull
    }
    public let owner: String
    public let repo: String
    public let kind: Kind
    public let number: Int

    public init(owner: String, repo: String, kind: Kind, number: Int) {
        self.owner = owner
        self.repo = repo
        self.kind = kind
        self.number = number
    }

    public var shortLabel: String {
        "\(owner)/\(repo)#\(number)"
    }
}

public enum ComposerMentionKind: String, Sendable, Equatable, Hashable {
    case file
    case folder
    case image
}

public struct ComposerResolvedMention: Sendable, Equatable {
    public let kind: ComposerMentionKind
    public let path: String?
    public let attachmentKey: String?
    public let missing: Bool

    public init(
        kind: ComposerMentionKind,
        path: String? = nil,
        attachmentKey: String? = nil,
        missing: Bool = false
    ) {
        self.kind = kind
        self.path = path
        self.attachmentKey = attachmentKey
        self.missing = missing
    }
}

public enum ComposerChip: Sendable, Equatable {
    case command(fromUTF16: Int, toUTF16: Int, name: String)
    case session(
        fromUTF16: Int,
        toUTF16: Int,
        rawToken: String,
        sessionId: String,
        title: String,
        agentName: String,
        missing: Bool
    )
    case mention(
        fromUTF16: Int,
        toUTF16: Int,
        kind: ComposerMentionKind,
        rawToken: String,
        label: String,
        lines: String?,
        path: String?,
        attachmentKey: String?,
        missing: Bool
    )
    case link(
        fromUTF16: Int,
        toUTF16: Int,
        url: String,
        host: String,
        path: String,
        isLocal: Bool,
        githubRef: ComposerGitHubRef?
    )

    public var fromUTF16: Int {
        switch self {
        case .command(let f, _, _): return f
        case .session(let f, _, _, _, _, _, _): return f
        case .mention(let f, _, _, _, _, _, _, _, _): return f
        case .link(let f, _, _, _, _, _, _): return f
        }
    }

    public var toUTF16: Int {
        switch self {
        case .command(_, let t, _): return t
        case .session(_, let t, _, _, _, _, _): return t
        case .mention(_, let t, _, _, _, _, _, _, _): return t
        case .link(_, let t, _, _, _, _, _): return t
        }
    }

    public var rawText: String {
        switch self {
        case .command(_, _, let name): return "/\(name)"
        case .session(_, _, let rawToken, _, _, _, _): return rawToken
        case .mention(_, _, _, let rawToken, _, _, _, _, _): return rawToken
        case .link(_, _, let url, _, _, _, _): return url
        }
    }

    public var attachmentKey: String? {
        if case .mention(_, _, _, _, _, _, _, let key, _) = self { return key }
        return nil
    }

    public var sessionID: String? {
        if case .session(_, _, _, let sid, _, _, _) = self { return sid }
        return nil
    }

    public func hasSameVisualContent(as other: ComposerChip) -> Bool {
        switch (self, other) {
        case let (.command(_, _, a), .command(_, _, b)):
            return a == b
        case let (.session(_, _, rt1, id1, t1, ag1, m1), .session(_, _, rt2, id2, t2, ag2, m2)):
            return rt1 == rt2 && id1 == id2 && t1 == t2 && ag1 == ag2 && m1 == m2
        case let (.mention(_, _, k1, rt1, lb1, ln1, p1, ak1, m1), .mention(_, _, k2, rt2, lb2, ln2, p2, ak2, m2)):
            return k1 == k2 && rt1 == rt2 && lb1 == lb2 && ln1 == ln2 && p1 == p2 && ak1 == ak2 && m1 == m2
        case let (.link(_, _, u1, h1, p1, l1, g1), .link(_, _, u2, h2, p2, l2, g2)):
            return u1 == u2 && h1 == h2 && p1 == p2 && l1 == l2 && g1 == g2
        default:
            return false
        }
    }
}

public enum ComposerChipsParser {
    private static let linkCharsLimit = 44
    private static let mentionRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s\u0080-\uFFFF]))[@＠]([^\s@＠\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65]+)"#,
        options: []
    )
    private static let mentionAtEndRegex = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s\u0080-\uFFFF]))[@＠][^\s@＠\u3000-\u303F\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF65]*$"#,
        options: []
    )
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"https?://[^\s<>"'`\u3000-\u303F\u4E00-\u9FFF\uFF00-\uFFEF]+"#,
        options: []
    )
    private static let lineRangeRegex = try! NSRegularExpression(
        pattern: #"(?::(\d+)(?:[-–](\d+))?|#L(\d+)(?:-L?(\d+))?)$"#,
        options: []
    )
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)]}>'\"。，；：！？）、")
    private static let sentenceEnd = CharacterSet(charactersIn: ".,;:!?>'\"")
    private static let githubRefRegex = try! NSRegularExpression(
        pattern: #"^/([^/]+)/([^/]+)/(issues|pull)/(\d+)(?:[/?#].*)?$"#,
        options: []
    )
    private static let localHostRegex = try! NSRegularExpression(
        pattern: #"^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])$|\.localhost$"#,
        options: [.caseInsensitive]
    )

    public static func splitLines(_ token: String) -> (name: String, lines: String?) {
        let ns = token as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = lineRangeRegex.firstMatch(in: token, range: full),
              match.range.location > 0
        else {
            return (token, nil)
        }
        let startRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 3)
        let endRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 4)
        let start = ns.substring(with: startRange)
        let end = endRange.location != NSNotFound ? ns.substring(with: endRange) : nil
        let lines = (end != nil && end != start) ? "\(start)–\(end!)" : start
        return (ns.substring(to: match.range.location), lines)
    }

    public static func trimLink(_ url: String) -> String {
        var chars = Array(url)
        let openers: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        while let last = chars.last {
            if last.unicodeScalars.count == 1, let sc = last.unicodeScalars.first, sentenceEnd.contains(sc) {
                chars.removeLast()
            } else if let opener = openers[last] {
                let openCount = chars.filter { $0 == opener }.count
                let closeCount = chars.filter { $0 == last }.count
                if openCount < closeCount {
                    chars.removeLast()
                } else {
                    break
                }
            } else {
                break
            }
        }
        return String(chars)
    }

    public static func shortLinkPath(host: String, path: String) -> String {
        if host.count + path.count <= linkCharsLimit { return path }
        let queryOrHash = path.firstIndex(where: { $0 == "?" || $0 == "#" })
        let basePath = queryOrHash.map { String(path[..<$0]) } ?? path
        let suffix = queryOrHash.map { String(path[$0...]) } ?? ""
        var segments = basePath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        guard !segments.isEmpty else { return path }
        var tail = segments.removeLast() + suffix
        while let prev = segments.last {
            let next = "\(prev)/\(tail)"
            if host.count + 3 + next.count > linkCharsLimit { break }
            tail = next
            segments.removeLast()
        }
        return segments.isEmpty ? path : "/…/\(tail)"
    }

    public static func githubReference(from urlString: String) -> ComposerGitHubRef? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        let path = url.path
        let ns = path as NSString
        guard let m = githubRefRegex.firstMatch(in: path, range: NSRange(location: 0, length: ns.length)),
              let num = Int(ns.substring(with: m.range(at: 4)))
        else { return nil }
        let owner = ns.substring(with: m.range(at: 1))
        let repo = ns.substring(with: m.range(at: 2))
        let kindStr = ns.substring(with: m.range(at: 3))
        return ComposerGitHubRef(owner: owner, repo: repo, kind: kindStr == "pull" ? .pull : .issue, number: num)
    }

    public static func findLinks(in text: String) -> [ComposerChip] {
        let ns = text as NSString
        let matches = urlRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result: [ComposerChip] = []
        for match in matches {
            let raw = ns.substring(with: match.range)
            let urlStr = trimLink(raw)
            guard let url = URL(string: urlStr),
                  let hostName = url.host,
                  !hostName.isEmpty
            else { continue }
            let hostWithPort = url.port.map { "\(hostName):\($0)" } ?? hostName
            var pathPart = url.path
            if let q = url.query { pathPart += "?\(q)" }
            if let f = url.fragment { pathPart += "#\(f)" }
            if pathPart == "/" { pathPart = "" }
            let hostNS = hostName as NSString
            let isLocal = localHostRegex.firstMatch(in: hostName, range: NSRange(location: 0, length: hostNS.length)) != nil
            let from = match.range.location
            let to = from + (urlStr as NSString).length
            result.append(.link(
                fromUTF16: from,
                toUTF16: to,
                url: urlStr,
                host: hostWithPort,
                path: pathPart,
                isLocal: isLocal,
                githubRef: githubReference(from: urlStr)
            ))
        }
        return result
    }

    public static func findChips(
        in text: String,
        commands: [String],
        sessionReferences: [DraftSessionReference] = [],
        missingSessionIDs: Set<String> = [],
        resolveMention: (String) -> ComposerResolvedMention?
    ) -> [ComposerChip] {
        let ns = text as NSString
        let units = Array(text.utf16)
        var chips: [ComposerChip] = []

        let cmdLen = ComposerTrigger.leadingCommandLengthUTF16(in: text, names: commands)
        if cmdLen > 1 {
            let name = ns.substring(with: NSRange(location: 1, length: cmdLen - 1))
            chips.append(.command(fromUTF16: 0, toUTF16: cmdLen, name: name))
        }

        // Match referenced session tokens first (longest first so titles with shared prefixes never collide).
        if !sessionReferences.isEmpty && ns.length > 0 {
            let orderedRefs = sessionReferences
                .filter { !$0.token.isEmpty }
                .sorted { ($0.token as NSString).length > ($1.token as NSString).length }
            for ref in orderedRefs {
                var searchFrom = 0
                while searchFrom < ns.length {
                    let found = ns.range(
                        of: ref.token,
                        options: [],
                        range: NSRange(location: searchFrom, length: ns.length - searchFrom)
                    )
                    guard found.location != NSNotFound, found.length > 0 else { break }
                    let from = found.location
                    let to = NSMaxRange(found)
                    searchFrom = to
                    guard ComposerTrigger.startsWord(in: units, at: from) else { continue }
                    let overlaps = chips.contains { from < $0.toUTF16 && to > $0.fromUTF16 }
                    if !overlaps {
                        chips.append(.session(
                            fromUTF16: from,
                            toUTF16: to,
                            rawToken: ref.token,
                            sessionId: ref.id,
                            title: ref.title,
                            agentName: ref.agentName,
                            missing: missingSessionIDs.contains(ref.id)
                        ))
                    }
                }
            }
        }

        let fullRange = NSRange(location: 0, length: ns.length)
        for match in mentionRegex.matches(in: text, range: fullRange) {
            let from = match.range.location
            let token = ns.substring(with: match.range(at: 1))
            guard let resolved = resolveMentionToken(token, resolve: resolveMention) else { continue }
            let to = from + 1 + (resolved.token as NSString).length
            let overlaps = chips.contains { from < $0.toUTF16 && to > $0.fromUTF16 }
            if overlaps { continue }
            let raw = ns.substring(with: NSRange(location: from, length: to - from))
            let base = resolved.name.split(separator: "/").last.map(String.init) ?? resolved.name
            let label = resolved.target.kind == .folder
                ? (resolved.name.hasSuffix("/") ? resolved.name : "\(resolved.name)/")
                : base
            chips.append(.mention(
                fromUTF16: from,
                toUTF16: to,
                kind: resolved.target.kind,
                rawToken: raw,
                label: label,
                lines: resolved.lines,
                path: resolved.target.path,
                attachmentKey: resolved.target.attachmentKey,
                missing: resolved.target.missing
            ))
        }

        for link in findLinks(in: text) {
            let overlaps = chips.contains { link.fromUTF16 < $0.toUTF16 && link.toUTF16 > $0.fromUTF16 }
            if !overlaps {
                chips.append(link)
            }
        }

        return chips.sorted { $0.fromUTF16 < $1.fromUTF16 }
    }

    private static func resolveMentionToken(
        _ token: String,
        resolve: (String) -> ComposerResolvedMention?
    ) -> (token: String, name: String, lines: String?, target: ComposerResolvedMention)? {
        let trimmed = trimTrailingPunctuation(token)
        var candidates = trimmed == token ? [token] : [token, trimmed]

        // Allow unspaced CJK text immediately after an ASCII path/extension or trailing `/`
        // (e.g. `@README.md看看`, `@App.swift:10-20分析一下`, `@说明.md看看`).
        let scalars = Array(trimmed.unicodeScalars)
        if let firstNonASCII = scalars.firstIndex(where: { $0.value > 0x7F }), firstNonASCII > 0 {
            let asciiPrefix = trimTrailingPunctuation(String(String.UnicodeScalarView(scalars[0..<firstNonASCII])))
            if !asciiPrefix.isEmpty && !candidates.contains(asciiPrefix) {
                candidates.append(asciiPrefix)
            }
        }
        if scalars.contains(where: { $0.value > 0x7F }) {
            // Also try cutting right after the last ASCII extension/line-spec run for non-ASCII filenames.
            var idx = scalars.count - 1
            while idx >= 0 && scalars[idx].value > 0x7F {
                idx -= 1
            }
            if idx >= 0 && idx < scalars.count - 1 {
                let prefix = trimTrailingPunctuation(String(String.UnicodeScalarView(scalars[0...idx])))
                if !prefix.isEmpty && !candidates.contains(prefix) {
                    candidates.append(prefix)
                }
            }
        }

        for cand in candidates where !cand.isEmpty {
            let split = splitLines(cand)
            if let target = resolve(split.name) {
                return (cand, split.name, split.lines, target)
            }
        }
        return nil
    }

    private static func trimTrailingPunctuation(_ token: String) -> String {
        var scalars = Array(token.unicodeScalars)
        while let last = scalars.last, trailingPunctuation.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Range of a mention or URL currently being typed around `caretUTF16`, so it remains editable
    /// plain text until the caret moves past it.
    public static func typingRange(in text: String, caretUTF16: Int) -> Range<Int>? {
        let ns = text as NSString
        guard caretUTF16 >= 0 && caretUTF16 <= ns.length else { return nil }
        for link in findLinks(in: text) {
            if caretUTF16 >= link.fromUTF16 && caretUTF16 <= link.toUTF16 {
                return link.fromUTF16..<link.toUTF16
            }
        }
        let before = ns.substring(to: caretUTF16)
        let beforeNS = before as NSString
        if let m = mentionAtEndRegex.firstMatch(in: before, range: NSRange(location: 0, length: beforeNS.length)) {
            let start = m.range.location
            return start..<caretUTF16
        }
        // Partial URL still being typed (`https:/`).
        let beforeChars = Array(before.utf16)
        var wordStart = beforeChars.count
        while wordStart > 0 && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(beforeChars[wordStart - 1]) ?? " ") {
            wordStart -= 1
        }
        if wordStart < caretUTF16 {
            let word = beforeNS.substring(from: wordStart)
            if word.hasPrefix("http:") || word.hasPrefix("https:") {
                return wordStart..<caretUTF16
            }
        }
        return nil
    }
}

// MARK: - 4. Cross-Session Mentions & Context Formatting

public struct DraftSessionReference: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let token: String
    public let title: String
    public let agentId: String
    public let agentName: String
    public let projectPath: String
    public let branch: String?
    public let updatedAt: Double

    public init(
        id: String,
        token: String,
        title: String,
        agentId: String,
        agentName: String,
        projectPath: String,
        branch: String? = nil,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.token = token
        self.title = title
        self.agentId = agentId
        self.agentName = agentName
        self.projectPath = projectPath
        self.branch = branch
        self.updatedAt = updatedAt
    }
}

public struct ComposerSessionCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let agentId: String
    public let agentName: String
    public let projectPath: String
    public let branch: String?
    public let status: SessionStatus
    public let updatedAt: Double

    public init(
        id: String,
        title: String,
        agentId: String,
        agentName: String,
        projectPath: String,
        branch: String? = nil,
        status: SessionStatus = .ready,
        updatedAt: Double = 0
    ) {
        self.id = id
        self.title = title
        self.agentId = agentId
        self.agentName = agentName
        self.projectPath = projectPath
        self.branch = branch
        self.status = status
        self.updatedAt = updatedAt
    }
}

public struct ComposerSessionMentionRow: Sendable, Equatable, Identifiable {
    public var id: String { candidate.id }
    public let candidate: ComposerSessionCandidate
    /// Character offsets into `candidate.title` matched by the fuzzy query.
    public let titlePositions: [Int]

    public init(candidate: ComposerSessionCandidate, titlePositions: [Int] = []) {
        self.candidate = candidate
        self.titlePositions = titlePositions
    }
}

public enum ComposerSessionMatcher {
    public static let mentionLimit = 50
    private static let maxTokenTitleChars = 48

    /// Produces a clean, space-safe mention token (`@[Title]`) guaranteed unique against `existingTokens`.
    public static func makeToken(
        title: String,
        sessionId: String,
        existingTokens: Set<String>
    ) -> String {
        let collapsed = title
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let baseTitle: String
        if collapsed.isEmpty {
            baseTitle = String(sessionId.prefix(8))
        } else if collapsed.count > maxTokenTitleChars {
            baseTitle = String(collapsed.prefix(maxTokenTitleChars - 1)) + "…"
        } else {
            baseTitle = collapsed
        }

        let direct = "@[\(baseTitle)]"
        if !existingTokens.contains(direct) {
            return direct
        }
        let suffix = String(sessionId.prefix(4))
        let disambiguated = "@[\(baseTitle) #\(suffix)]"
        if !existingTokens.contains(disambiguated) {
            return disambiguated
        }
        return "@[\(baseTitle) #\(String(sessionId.prefix(8)))]"
    }

    /// Fuzzy-matches unarchived same-project sessions by title, agent name, or branch, sorted by score then recency.
    public static func matchSessions(
        query: String,
        candidates: [ComposerSessionCandidate],
        limit: Int = mentionLimit
    ) -> [ComposerSessionMentionRow] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return candidates
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
                .map { ComposerSessionMentionRow(candidate: $0, titlePositions: []) }
        }

        var scored: [(candidate: ComposerSessionCandidate, score: Double, positions: [Int])] = []
        for item in candidates {
            if let titleHit = ComposerPathMatcher.scorePath(query: trimmed, path: item.title) {
                scored.append((item, titleHit.score + 10.0, titleHit.positions))
                continue
            }
            if let agentHit = ComposerPathMatcher.scorePath(query: trimmed, path: item.agentName) {
                scored.append((item, agentHit.score, []))
                continue
            }
            if let branch = item.branch, !branch.isEmpty,
               let branchHit = ComposerPathMatcher.scorePath(query: trimmed, path: branch) {
                scored.append((item, branchHit.score + 2.0, []))
                continue
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.updatedAt > rhs.candidate.updatedAt
        }
        return scored.prefix(limit).map {
            ComposerSessionMentionRow(candidate: $0.candidate, titlePositions: $0.positions)
        }
    }
}

public struct ComposerSessionPreviewExcerpt: Sendable, Equatable, Identifiable {
    public let id: Int
    public let role: String // "user" | "assistant"
    public let text: String

    public init(id: Int, role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

public struct ComposerSessionPreview: Sendable, Equatable {
    public let turnCount: Int
    public let excerpts: [ComposerSessionPreviewExcerpt]

    public init(turnCount: Int, excerpts: [ComposerSessionPreviewExcerpt]) {
        self.turnCount = turnCount
        self.excerpts = excerpts
    }
}

public enum ComposerSessionContextFormatter {
    public static let defaultMaxChars = 16_000
    private static let maxSingleMessageChars = 3_500
    private static let maxToolResultChars = 240

    private struct RenderedTurn {
        let number: Int
        let user: String
        var assistant: String
    }

    /// Lightweight hover preview: total turns and the last 3 non-empty user/assistant excerpts.
    public static func preview(from entries: [ThreadEntry]) -> ComposerSessionPreview {
        let turns = extractTurns(from: entries)
        var excerpts: [ComposerSessionPreviewExcerpt] = []
        var nextID = 0
        for turn in turns.suffix(2) {
            if !turn.user.isEmpty {
                excerpts.append(ComposerSessionPreviewExcerpt(
                    id: nextID,
                    role: "user",
                    text: compactExcerpt(turn.user, limit: 160)
                ))
                nextID += 1
            }
            if !turn.assistant.isEmpty {
                excerpts.append(ComposerSessionPreviewExcerpt(
                    id: nextID,
                    role: "assistant",
                    text: compactExcerpt(turn.assistant, limit: 200)
                ))
                nextID += 1
            }
        }
        return ComposerSessionPreview(turnCount: turns.count, excerpts: Array(excerpts.suffix(3)))
    }

    /// Formats a referenced session's thread entries into a concise, structured context block
    /// compatible with every coding agent (Claude Code, Codex, ACP, etc.).
    public static func formatContextBlock(
        reference: DraftSessionReference,
        entries: [ThreadEntry],
        maxChars: Int = defaultMaxChars
    ) -> String {
        let turns = extractTurns(from: entries)
        let titleAttr = escapeAttribute(reference.title)
        let agentAttr = escapeAttribute(reference.agentName)
        let idAttr = escapeAttribute(reference.id)
        let openTag = "<referenced_session id=\"\(idAttr)\" title=\"\(titleAttr)\" agent=\"\(agentAttr)\" turns=\"\(turns.count)\">"
        let closeTag = "</referenced_session>"

        guard !turns.isEmpty else {
            return "\(openTag)\n(This session has no conversation messages yet.)\n\(closeTag)"
        }

        func renderTurn(_ turn: RenderedTurn) -> String {
            var lines: [String] = []
            lines.append("[Turn \(turn.number)]")
            if !turn.user.isEmpty {
                lines.append("User:\n\(truncate(turn.user, max: maxSingleMessageChars))")
            }
            if !turn.assistant.isEmpty {
                lines.append("Assistant:\n\(truncate(turn.assistant, max: maxSingleMessageChars))")
            }
            return lines.joined(separator: "\n")
        }

        let renderedAll = turns.map(renderTurn)
        let budget = max(1_000, maxChars - openTag.count - closeTag.count - 32)
        let joinedAll = renderedAll.joined(separator: "\n\n")
        if joinedAll.count <= budget {
            return "\(openTag)\n\(joinedAll)\n\(closeTag)"
        }

        // Over budget: keep Turn 1 (initial goal) + as many latest turns as fit, marking omitted turns.
        var tailBlocks: [String] = []
        var used = 0
        let firstBlock = renderedAll[0]
        let reserveFirst = min(firstBlock.count + 48, budget / 3)
        let tailBudget = max(400, budget - reserveFirst)

        for idx in stride(from: renderedAll.count - 1, through: 1, by: -1) {
            let block = renderedAll[idx]
            let extra = tailBlocks.isEmpty ? block.count : block.count + 2
            if used + extra > tailBudget {
                if tailBlocks.isEmpty {
                    tailBlocks.append(truncate(block, max: tailBudget))
                    used = tailBlocks[0].count
                }
                break
            }
            tailBlocks.insert(block, at: 0)
            used += extra
        }

        let omittedCount = max(0, turns.count - 1 - tailBlocks.count)
        var sections: [String] = []
        sections.append(truncate(firstBlock, max: max(300, budget - used - 64)))
        if omittedCount > 0 {
            sections.append("[... \(omittedCount) earlier turn(s) omitted for length ...]")
        }
        sections.append(contentsOf: tailBlocks)
        return "\(openTag)\n\(sections.joined(separator: "\n\n"))\n\(closeTag)"
    }

    /// Combines the user's message first (so thread outlines and bubbles lead with the user's request)
    /// followed by structured referenced-session context blocks.
    public static func composePromptWithSessionContexts(text: String, contexts: [String]) -> String {
        guard !contexts.isEmpty else { return text }
        let body = contexts.joined(separator: "\n\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let block = "<referenced_sessions>\nThe user referenced the following session(s) from this project as background context. Use them to inform your answer without resuming or re-executing tasks from them unless asked.\n\n\(body)\n</referenced_sessions>"
        if trimmed.isEmpty {
            return block
        }
        return "\(trimmed)\n\n\(block)"
    }

    private static func extractTurns(from entries: [ThreadEntry]) -> [RenderedTurn] {
        var turns: [RenderedTurn] = []
        var assistantParts: [String] = []

        func closeCurrent() {
            guard !turns.isEmpty else {
                assistantParts.removeAll()
                return
            }
            turns[turns.count - 1].assistant = assistantParts.joined(separator: "\n\n")
            assistantParts.removeAll()
        }

        for entry in entries {
            switch entry {
            case .user(_, let text, let content, _, _, let steered):
                let body = userText(fallback: text, content: content)
                guard !body.isEmpty else { continue }
                if steered && !turns.isEmpty {
                    assistantParts.append("[User follow-up during turn]\n\(body)")
                } else {
                    closeCurrent()
                    turns.append(RenderedTurn(number: turns.count + 1, user: body, assistant: ""))
                }

            case .agent(_, let markdown, _, _, _):
                let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    assistantParts.append(trimmed)
                }

            case .tool(let tool):
                let summary = summarizeTool(tool)
                if !summary.isEmpty {
                    assistantParts.append(summary)
                }

            case .compaction(_, _, let summary):
                let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    assistantParts.append("[Compacted earlier context: \(truncate(trimmed, max: 400))]")
                }

            case .git(let git):
                if !git.event.isEmpty {
                    assistantParts.append("[git: \(git.event)]")
                }

            case .artifact(let art):
                assistantParts.append("[artifact \"\(art.title)\": \(art.action)]")

            default:
                continue
            }
        }
        closeCurrent()
        return turns
    }

    private static func userText(fallback: String, content: [UserContent]) -> String {
        if !content.isEmpty {
            let joined = content.map { part -> String in
                switch part {
                case .text(let s):
                    return s
                case .ref(let ref):
                    switch ref {
                    case .attachment(let info):
                        return "[attached \(info.name)]"
                    case .link(let uri, let name):
                        return "[\(name)](\(uri))"
                    case .imageData, .imageBlob:
                        return "[image]"
                    case .audio(_, _, let name):
                        return name.map { "[audio \($0)]" } ?? "[audio]"
                    case .video(_, _, let name):
                        return name.map { "[video \($0)]" } ?? "[video]"
                    case .terminal(_, let name):
                        return "[terminal \(name)]"
                    case .page(_, let name):
                        return "[page \(name)]"
                    case .device(_, let name):
                        return "[device \(name)]"
                    case .unsupported(let label):
                        return "[\(label)]"
                    case .other(let kind):
                        return "[\(kind)]"
                    }
                }
            }.joined(separator: " ")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarizeTool(_ tool: ToolEntryData) -> String {
        var details: [String] = []
        for item in tool.content {
            switch item {
            case .diff(let path, _, _):
                details.append("edited \(path)")
            case .digest(_, let path?, _, _, let added, let removed):
                if let added, let removed {
                    details.append("\(path) (+\(added)/-\(removed))")
                } else {
                    details.append(path)
                }
            case .markdown(let md):
                let trimmed = md.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && details.isEmpty {
                    details.append(truncate(trimmed, max: maxToolResultChars))
                }
            default:
                break
            }
        }
        let header = "[tool: \(tool.title) (\(tool.status))]"
        if details.isEmpty {
            return header
        }
        return "\(header) \(details.prefix(3).joined(separator: "; "))"
    }

    private static func compactExcerpt(_ text: String, limit: Int) -> String {
        let singleLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return truncate(singleLine, max: limit)
    }

    private static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max, max > 4 else { return text }
        let idx = text.index(text.startIndex, offsetBy: max - 1)
        return String(text[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - 5. Passage Comments & Long-Paste Rules

public struct DraftReplyComment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let entryId: String?
    public let passage: String
    public var comment: String

    public init(id: String = UUID().uuidString, entryId: String? = nil, passage: String, comment: String) {
        self.id = id
        self.entryId = entryId
        self.passage = passage
        self.comment = comment
    }
}

public enum ComposerComments {
    public static let quoteLimit = 2000

    public static func quoteBlock(_ passage: String) -> String {
        var normalized = passage
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        while normalized.contains("\n\n\n") {
            normalized = normalized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count > quoteLimit {
            let endIdx = normalized.index(normalized.startIndex, offsetBy: quoteLimit)
            normalized = String(normalized[..<endIdx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                if s.isEmpty { return ">" }
                let trimmedLeading = s.drop(while: { $0 == " " })
                let leadingSpaces = s.count - trimmedLeading.count
                if leadingSpaces <= 3 && trimmedLeading.hasPrefix(">") {
                    let prefix = String(repeating: " ", count: leadingSpaces)
                    return "> \(prefix)\\\(trimmedLeading)"
                }
                return "> \(s)"
            }
            .joined(separator: "\n")
    }

    public static func commentsMessage(comments: [DraftReplyComment], text: String) -> String {
        guard !comments.isEmpty else { return text }
        var parts = comments.map { item -> String in
            let quote = quoteBlock(item.passage)
            let body = item.comment.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? quote : "\(quote)\n\n\(body)"
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts.joined(separator: "\n\n")
    }
}

public enum ComposerAttachmentRules {
    public static let pastedTextThreshold = 10_000
    private static let previewLinesCount = 3
    private static let previewLineChars = 120

    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let breaks = normalized.filter { $0 == "\n" }.count
        return normalized.hasSuffix("\n") ? breaks : breaks + 1
    }

    public static func textThumb(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized
            .split(separator: "\n", maxSplits: previewLinesCount, omittingEmptySubsequences: false)
            .prefix(previewLinesCount)
            .map { String($0.prefix(previewLineChars)) }
            .joined(separator: "\n")
        let encoded = lines.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lines
        return "data:text/plain;charset=utf-8;lines=\(lineCount(text)),\(encoded)"
    }

    public static func readTextThumb(_ thumb: String?) -> (lines: [String], count: Int)? {
        guard let thumb, thumb.hasPrefix("data:text/plain;charset=utf-8;lines=") else { return nil }
        let rest = thumb.dropFirst("data:text/plain;charset=utf-8;lines=".count)
        guard let comma = rest.firstIndex(of: ","),
              let count = Int(rest[..<comma])
        else { return nil }
        let bodyRaw = String(rest[rest.index(after: comma)...])
        let decoded = bodyRaw.removingPercentEncoding ?? bodyRaw
        return (decoded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), count)
    }

    /// Spreadsheets copy both cell text (containing `\t` or `\n`) and an image snapshot; prefer text.
    public static func shouldPreferPlainTextOverImage(_ plainText: String?) -> Bool {
        guard let plainText else { return false }
        return plainText.contains("\t") || plainText.contains("\n")
    }
}

// MARK: - 5. Waiting Card Keyboard Resolution (mirrors waiting-card.ts)

public enum ComposerCardKey: Sendable, Equatable {
    case escape
    case enter
    case confirm
}

public enum ComposerWaitingCardAction: Sendable, Equatable {
    case respondPermission(requestId: String, optionId: String?)
    case answerMemory(entryId: String, decision: String)
    case answerSettingsChange(entryId: String, decision: String)
    case answerBrowserOrigin(entryId: String, decision: String)
    case answerControlAsk(entryId: String, outcome: String)
    case answerDeviceAccess(entryId: String, decision: String)
    case answerSurfaceAccess(entryId: String, decision: String)
    case answerComputerApp(entryId: String, decision: String)
    case declineComputerSetup(entryId: String)
    case answerProjectMcp(entryId: String, decision: String)
    case answerProjectHooks(entryId: String, decision: String)
}

public enum ComposerWaitingCard {
    /// Finds the first waiting card in `entries` and resolves what `key` does on it.
    public static func action(for key: ComposerCardKey, in entries: [ThreadEntry]) -> ComposerWaitingCardAction? {
        for entry in entries {
            switch entry {
            case .tool(let tool):
                guard let perm = tool.permission else { continue }
                if let questions = perm.questions, !questions.isEmpty {
                    // Unanswered question cards only cancel on Esc; Enter must not submit blank answers.
                    if key == .escape {
                        let reject = perm.options.first(where: { $0.kind.contains("reject") })?.id
                        return .respondPermission(requestId: perm.requestId, optionId: reject)
                    }
                    return nil
                }
                if key == .escape {
                    if let reject = perm.options.first(where: { $0.kind.contains("reject") }) {
                        return .respondPermission(requestId: perm.requestId, optionId: reject.id)
                    }
                    return nil
                }
                if let primary = perm.options.first(where: { $0.preferred == true })
                    ?? perm.options.first(where: { $0.kind == "allow_once" })
                    ?? perm.options.first(where: { !$0.kind.contains("reject") }) {
                    return .respondPermission(requestId: perm.requestId, optionId: primary.id)
                }
                return nil

            case .browserOrigin(let p) where p.decision == nil:
                return .answerBrowserOrigin(entryId: p.id, decision: key == .escape ? "deny" : "allow")

            case .deviceAccess(let p) where p.decision == nil:
                return .answerDeviceAccess(entryId: p.id, decision: key == .escape ? "deny" : "allow")

            case .surfaceAccess(let p) where p.decision == nil:
                return .answerSurfaceAccess(entryId: p.id, decision: key == .escape ? "deny" : "allow")

            case .computerApp(let p) where p.decision == nil:
                return .answerComputerApp(entryId: p.id, decision: key == .escape ? "deny" : "allow")

            case .computerSetup(let p) where p.outcome == nil:
                return key == .escape ? .declineComputerSetup(entryId: p.id) : nil

            case .controlAsk(let p) where p.outcome == nil:
                return .answerControlAsk(entryId: p.id, outcome: key == .escape ? "skip" : "done")

            case .settingsChange(let p) where p.asked && p.outcome == nil:
                return .answerSettingsChange(entryId: p.id, decision: key == .escape ? "keep" : "change")

            case .memory(let p) where p.awaitsAnswer:
                return .answerMemory(entryId: p.id, decision: key == .escape ? "skip" : "remember")

            case .projectMcp(let p) where p.decision == nil:
                return .answerProjectMcp(entryId: p.id, decision: key == .escape ? "skip" : "use")

            case .projectHooks(let p) where p.decision == nil:
                return .answerProjectHooks(entryId: p.id, decision: key == .escape ? "skip" : "use")

            default:
                continue
            }
        }
        return nil
    }

    public static func hasWaitingCard(in entries: [ThreadEntry]) -> Bool {
        action(for: .escape, in: entries) != nil || action(for: .enter, in: entries) != nil
    }

    public static func awaitsQuestionAnswer(in entries: [ThreadEntry]) -> Bool {
        entries.contains { entry in
            if case .tool(let tool) = entry, let questions = tool.permission?.questions, !questions.isEmpty {
                return true
            }
            return false
        }
    }

    public static func endedOnRejection(in entries: [ThreadEntry]) -> Bool {
        guard let last = entries.last(where: { entry in
            switch entry {
            case .turnEnd, .tool: return true
            default: return false
            }
        }) else { return false }
        if case .turnEnd(_, let reason, _) = last {
            return reason == "rejected" || reason == "denied"
        }
        return false
    }
}
