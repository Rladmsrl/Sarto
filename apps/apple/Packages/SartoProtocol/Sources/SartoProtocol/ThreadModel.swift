import Foundation

public extension Int {
    /// `value` without its fraction; nil for NaN, an infinity or a number outside `Int`'s range,
    /// where `Int(_:)` traps. Every number a host or sync sends as a `Double` is read through this.
    static func wholePart(of value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }
}

/// Sendable recursive JSON value for dynamic Sarto RPC params, events, and partial patches.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Each failed attempt builds and throws a DecodingError, so the kinds go most common first:
        // strings outnumber every other value in host payloads, and containers hold the leaves.
        if container.decodeNil() {
            self = .null
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    /// Parses JSON text straight into a value, without the Codable machinery `JSONDecoder` needs.
    public init(jsonData data: Data) throws {
        self = try JSONValueParser.parse(data)
    }

    /// Serializes this value as compact JSON text, writing safe integers without a fraction like `encode(to:)`.
    public func jsonData() throws -> Data {
        var writer = JSONValueWriter()
        try writer.write(self)
        return Data(writer.out)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n):
            // Emit exact safe integers without fractional/scientific notation so JS Number.isSafeInteger checks pass.
            if n.isFinite,
               n.truncatingRemainder(dividingBy: 1) == 0,
               n >= -9_007_199_254_740_991,
               n <= 9_007_199_254_740_991 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: jsonData())
    }

    /// Returns a copy of this JSON value with `newValue` placed at `path` (string object keys or integer array indices).
    public func setting(_ newValue: JSONValue, at path: [JSONValue]) -> JSONValue {
        guard let first = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var dict), .string(let key)):
            let child = dict[key] ?? .null
            dict[key] = rest.isEmpty ? newValue : child.setting(newValue, at: rest)
            return .object(dict)
        case (.array(var arr), .number(let num)):
            if let idx = Int.wholePart(of: num), idx >= 0 && idx < arr.count {
                arr[idx] = rest.isEmpty ? newValue : arr[idx].setting(newValue, at: rest)
            }
            return .array(arr)
        default:
            return self
        }
    }
}

/// Recursive-descent JSON parser over UTF-8 bytes, strict about the grammar like `JSONDecoder`.
private struct JSONValueParser {
    /// Host payloads nest a few levels; the bound keeps a hostile one from overflowing the 512 KiB
    /// stack of a concurrency thread, where an unoptimized build spends about 1 KiB per level.
    private static let maxDepth = 128

    // A raw pointer rather than a buffer: its subscript has no bounds check, which keeps the byte loops
    // fast in unoptimized builds; every read is guarded by `index < count`.
    private let bytes: UnsafePointer<UInt8>
    private let count: Int
    private var index = 0
    private var depth = 0

    private init(bytes: UnsafePointer<UInt8>, count: Int) {
        self.bytes = bytes
        self.count = count
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, !raw.isEmpty else {
                throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Empty JSON"))
            }
            var parser = JSONValueParser(bytes: base, count: raw.count)
            parser.skipWhitespace()
            let value = try parser.parseValue()
            parser.skipWhitespace()
            guard parser.index == parser.count else {
                throw parser.failure("Unexpected text after the JSON value")
            }
            return value
        }
    }

    private func slice(_ range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: bytes + range.lowerBound, count: range.count)
    }

    private func failure(_ reason: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: [],
            debugDescription: "Invalid JSON at byte \(index): \(reason)"
        ))
    }

    private mutating func skipWhitespace() {
        while index < count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < count else { throw failure("Unexpected end of data") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expectLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expectLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expectLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw failure("Unexpected character")
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let length = literal.utf8CodeUnitCount
        guard count - index >= length else { throw failure("Unexpected end of data") }
        let start = literal.utf8Start
        for offset in 0..<length where bytes[index + offset] != start[offset] {
            throw failure("Invalid literal")
        }
        index += length
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw failure("Nested too deeply") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if index < count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < count, bytes[index] == UInt8(ascii: "\"") else { throw failure("Expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard index < count, bytes[index] == UInt8(ascii: ":") else { throw failure("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < count else { throw failure("Unexpected end of data") }
            let next = bytes[index]
            index += 1
            if next == UInt8(ascii: ",") { continue }
            if next == UInt8(ascii: "}") { return .object(object) }
            throw failure("Expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard index < count else { throw failure("Unexpected end of data") }
            let next = bytes[index]
            index += 1
            if next == UInt8(ascii: ",") { continue }
            if next == UInt8(ascii: "]") { return .array(array) }
            throw failure("Expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        let start = index
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: slice(start..<index), as: UTF8.self)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\\") {
                return try parseEscapedString(from: start)
            }
            guard byte >= 0x20 else { throw failure("Control character in a string") }
            index += 1
        }
        throw failure("Unterminated string")
    }

    private mutating func parseEscapedString(from start: Int) throws -> String {
        var out: [UInt8] = []
        out.reserveCapacity(index - start + 16)
        out.append(contentsOf: slice(start..<index))
        while index < count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: out, as: UTF8.self)
            }
            guard byte >= 0x20 else { throw failure("Control character in a string") }
            if byte != UInt8(ascii: "\\") {
                out.append(byte)
                index += 1
                continue
            }
            index += 1
            guard index < count else { throw failure("Unterminated string") }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                let unit = try parseHex4()
                var scalar: Unicode.Scalar?
                if (0xD800...0xDBFF).contains(unit),
                   count - index >= 6,
                   bytes[index] == UInt8(ascii: "\\"),
                   bytes[index + 1] == UInt8(ascii: "u") {
                    let saved = index
                    index += 2
                    let low = try parseHex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00))
                    } else {
                        index = saved
                    }
                } else {
                    scalar = Unicode.Scalar(UInt32(unit))
                }
                // A lone surrogate, which JSON.stringify escapes rather than drops, reads as U+FFFD.
                let resolved = scalar ?? Unicode.Scalar(0xFFFD)!
                UTF8.encode(resolved) { out.append($0) }
            default:
                throw failure("Invalid escape")
            }
        }
        throw failure("Unterminated string")
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard count - index >= 4 else { throw failure("Invalid unicode escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: throw failure("Invalid unicode escape")
            }
            value = value << 4 | UInt16(digit)
            index += 1
        }
        return value
    }

    private func isDigit(at position: Int) -> Bool {
        position < count && bytes[position] >= UInt8(ascii: "0") && bytes[position] <= UInt8(ascii: "9")
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        var negative = false
        if bytes[index] == UInt8(ascii: "-") {
            negative = true
            index += 1
        }
        guard isDigit(at: index) else { throw failure("Invalid number") }
        let digitsStart = index
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while isDigit(at: index) { index += 1 }
        }
        let integerDigits = index - digitsStart
        var isInteger = true
        if index < count, bytes[index] == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            guard isDigit(at: index) else { throw failure("Invalid number") }
            while isDigit(at: index) { index += 1 }
        }
        if index < count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if index < count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard isDigit(at: index) else { throw failure("Invalid number") }
            while isDigit(at: index) { index += 1 }
        }
        if isInteger && integerDigits <= 15 {
            var value: Int64 = 0
            for position in digitsStart..<index {
                value = value * 10 + Int64(bytes[position] - UInt8(ascii: "0"))
            }
            if negative { return value == 0 ? -0.0 : Double(-value) }
            return Double(value)
        }
        let text = String(decoding: slice(start..<index), as: UTF8.self)
        guard let value = Double(text), value.isFinite else { throw failure("Number out of range") }
        return value
    }
}

/// Writes compact JSON text for a `JSONValue`.
private struct JSONValueWriter {
    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    var out: [UInt8] = []

    mutating func write(_ value: JSONValue) throws {
        switch value {
        case .null:
            out.append(contentsOf: [0x6E, 0x75, 0x6C, 0x6C])
        case .bool(let flag):
            if flag {
                out.append(contentsOf: [0x74, 0x72, 0x75, 0x65])
            } else {
                out.append(contentsOf: [0x66, 0x61, 0x6C, 0x73, 0x65])
            }
        case .number(let number):
            try writeNumber(number)
        case .string(let text):
            writeString(text)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            var first = true
            for item in items {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                try write(item)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            var first = true
            for (key, member) in members {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                writeString(key)
                out.append(UInt8(ascii: ":"))
                try write(member)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private mutating func writeNumber(_ number: Double) throws {
        guard number.isFinite else {
            throw EncodingError.invalidValue(number, EncodingError.Context(
                codingPath: [],
                debugDescription: "Unable to encode \(number) directly in JSON."
            ))
        }
        if number.truncatingRemainder(dividingBy: 1) == 0,
           number >= -9_007_199_254_740_991,
           number <= 9_007_199_254_740_991 {
            out.append(contentsOf: String(Int64(number)).utf8)
        } else {
            out.append(contentsOf: "\(number)".utf8)
        }
    }

    private mutating func writeString(_ text: String) {
        out.append(UInt8(ascii: "\""))
        var text = text
        text.withUTF8 { utf8 in
            guard let base = utf8.baseAddress else { return }
            let count = utf8.count
            var runStart = 0
            var position = 0
            // A plain while loop over the raw pointer stays fast in unoptimized builds too.
            while position < count {
                let byte = base[position]
                if byte >= 0x20 && byte != 0x22 && byte != 0x5C {
                    position += 1
                    continue
                }
                if runStart < position {
                    out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: position - runStart))
                }
                position += 1
                runStart = position
                out.append(0x5C)
                switch byte {
                case 0x22: out.append(0x22)
                case 0x5C: out.append(0x5C)
                case 0x0A: out.append(UInt8(ascii: "n"))
                case 0x0D: out.append(UInt8(ascii: "r"))
                case 0x09: out.append(UInt8(ascii: "t"))
                case 0x08: out.append(UInt8(ascii: "b"))
                case 0x0C: out.append(UInt8(ascii: "f"))
                default:
                    out.append(contentsOf: [UInt8(ascii: "u"), 0x30, 0x30, Self.hex[Int(byte >> 4)], Self.hex[Int(byte & 0xF)]])
                }
            }
            if runStart < count {
                out.append(contentsOf: UnsafeBufferPointer(start: base + runStart, count: count - runStart))
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Reads the routing fields of a host envelope from its first bytes when it starts the way the hosts'
/// `JSON.stringify` writes it (`{"type":"…"` and then `"id":<integer>` or `"event":{"type":"…"`),
/// so a large message is not parsed once per routing decision. Nil means another shape: parse it.
enum PortEnvelopeSniffer {
    private static let typePrefix = Array("{\"type\":\"".utf8)
    private static let idPrefix = Array(",\"id\":".utf8)
    private static let eventPrefix = Array(",\"event\":{\"type\":\"".utf8)

    static func header(_ data: Data) -> (type: String, id: Int?)? {
        data.withUnsafeBytes { raw -> (type: String, id: Int?)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard var position = match(typePrefix, in: bytes, at: 0),
                  let type = readName(bytes, at: &position)
            else { return nil }
            guard var idStart = match(idPrefix, in: bytes, at: position) else { return (type, nil) }
            var value = 0
            let digitsStart = idStart
            while idStart < bytes.count, idStart - digitsStart < 15,
                  bytes[idStart] >= UInt8(ascii: "0"), bytes[idStart] <= UInt8(ascii: "9") {
                value = value * 10 + Int(bytes[idStart] - UInt8(ascii: "0"))
                idStart += 1
            }
            guard idStart > digitsStart, idStart < bytes.count,
                  bytes[idStart] == UInt8(ascii: ",") || bytes[idStart] == UInt8(ascii: "}")
            else { return (type, nil) }
            return (type, value)
        }
    }

    static func eventType(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard var position = match(typePrefix, in: bytes, at: 0),
                  readName(bytes, at: &position) == "event",
                  var inner = match(eventPrefix, in: bytes, at: position)
            else { return nil }
            return readName(bytes, at: &inner)
        }
    }

    private static func match(_ prefix: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, at start: Int) -> Int? {
        guard bytes.count - start >= prefix.count else { return nil }
        for offset in 0..<prefix.count where bytes[start + offset] != prefix[offset] {
            return nil
        }
        return start + prefix.count
    }

    /// Reads a short unescaped string up to its closing quote and moves past it.
    private static func readName(_ bytes: UnsafeBufferPointer<UInt8>, at position: inout Int) -> String? {
        let start = position
        while position < bytes.count, position - start <= 64 {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                let name = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
                position += 1
                return name
            }
            if byte == UInt8(ascii: "\\") || byte < 0x20 { return nil }
            position += 1
        }
        return nil
    }
}

// MARK: - Sessions, Agents & Projects (src/shared/agent-host.ts & thread.ts)

public enum SessionStatus: String, Codable, Sendable, Equatable {
    case starting
    case authRequired = "auth_required"
    case ready
    case running
    case awaitingPermission = "awaiting_permission"
    case failed
    case closed

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .ready
    }
}

public struct PlanProgress: Codable, Sendable, Equatable {
    public struct CurrentStep: Codable, Sendable, Equatable {
        public let index: Int
        public let text: String
    }
    public let done: Int
    public let total: Int
    public let current: CurrentStep?
}

public struct SessionActivity: Codable, Sendable, Equatable {
    public let entryId: String
    public let toolKind: String
    public let title: String
    public let detail: String?
    public let startedAt: Double
}

public struct SessionPullRequestInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { url }
    public let url: String
    public let owner: String?
    public let repo: String?
    public let number: Int
    public let state: String?
    public let failing: Bool?

    public init(
        url: String,
        owner: String? = nil,
        repo: String? = nil,
        number: Int,
        state: String? = nil,
        failing: Bool? = nil
    ) {
        self.url = url
        self.owner = owner
        self.repo = repo
        self.number = number
        self.state = state
        self.failing = failing
    }
}

public struct SessionWorktreeInfo: Codable, Sendable, Equatable {
    public let path: String?
    public let branch: String?
    public let base: String?

    public init(path: String? = nil, branch: String? = nil, base: String? = nil) {
        self.path = path
        self.branch = branch
        self.base = base
    }
}

public struct SessionOutputArtifact: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct SessionOutputsInfo: Codable, Sendable, Equatable {
    public let artifacts: [SessionOutputArtifact]
    public let references: [String]
    public let reply: String?
    public let turnMs: Double?

    public init(
        artifacts: [SessionOutputArtifact] = [],
        references: [String] = [],
        reply: String? = nil,
        turnMs: Double? = nil
    ) {
        self.artifacts = artifacts
        self.references = references
        self.reply = reply
        self.turnMs = turnMs
    }
}

public struct StartNoticeInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { optionId }
    public let reason: String // "not_offered" | "refused" | "replaced"
    public let optionId: String
    public let category: String
    public let option: String
    public let type: String // "select" | "boolean"
    public let wanted: JSONValue
    public let actual: JSONValue?

    public init(
        reason: String,
        optionId: String,
        category: String,
        option: String,
        type: String,
        wanted: JSONValue,
        actual: JSONValue? = nil
    ) {
        self.reason = reason
        self.optionId = optionId
        self.category = category
        self.option = option
        self.type = type
        self.wanted = wanted
        self.actual = actual
    }
}

public struct PreparedInfo: Codable, Sendable, Equatable {
    public let config: [ConfigOption]
    public let commands: [SlashCommand]?
    public let notices: [StartNoticeInfo]
    public let openedAt: Double

    enum CodingKeys: String, CodingKey {
        case config, commands, notices, openedAt
    }

    public init(
        config: [ConfigOption] = [],
        commands: [SlashCommand]? = nil,
        notices: [StartNoticeInfo] = [],
        openedAt: Double = 0
    ) {
        self.config = config
        self.commands = commands
        self.notices = notices
        self.openedAt = openedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.config = (try? c.decode([ConfigOption].self, forKey: .config)) ?? []
        self.commands = try? c.decodeIfPresent([SlashCommand].self, forKey: .commands)
        self.notices = (try? c.decode([StartNoticeInfo].self, forKey: .notices)) ?? []
        self.openedAt = try c.decodeIfPresent(Double.self, forKey: .openedAt) ?? 0
    }
}

public struct AgentOptionsInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { agentId }
    public let agentId: String
    public let config: [ConfigOption]
    public let levels: [String: ConfigOption]?
    public let remembered: [String: JSONValue]?
    public let defaults: [String: [String: JSONValue]]?
    public let observedAt: Double?
    public let provisional: Bool?
    public let startMode: String?
    /// The models pinned to the top of the agent's model menu, by value, in the order pinned.
    public let pinned: [String]?
    /// The models its sessions last started on or switched to, by value, the latest first.
    public let recent: [String]?

    enum CodingKeys: String, CodingKey {
        case agentId, config, levels, remembered, defaults, observedAt, provisional, startMode, pinned, recent
    }

    public init(
        agentId: String,
        config: [ConfigOption] = [],
        levels: [String: ConfigOption]? = nil,
        remembered: [String: JSONValue]? = nil,
        defaults: [String: [String: JSONValue]]? = nil,
        observedAt: Double? = nil,
        provisional: Bool? = nil,
        startMode: String? = nil,
        pinned: [String]? = nil,
        recent: [String]? = nil
    ) {
        self.agentId = agentId
        self.config = config
        self.levels = levels
        self.remembered = remembered
        self.defaults = defaults
        self.observedAt = observedAt
        self.provisional = provisional
        self.startMode = startMode
        self.pinned = pinned
        self.recent = recent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.agentId = try c.decode(String.self, forKey: .agentId)
        self.config = (try? c.decode([ConfigOption].self, forKey: .config)) ?? []
        self.levels = try? c.decodeIfPresent([String: ConfigOption].self, forKey: .levels)
        self.remembered = try? c.decodeIfPresent([String: JSONValue].self, forKey: .remembered)
        self.defaults = try? c.decodeIfPresent([String: [String: JSONValue]].self, forKey: .defaults)
        self.observedAt = try c.decodeIfPresent(Double.self, forKey: .observedAt)
        self.provisional = try c.decodeIfPresent(Bool.self, forKey: .provisional)
        self.startMode = try c.decodeIfPresent(String.self, forKey: .startMode)
        self.pinned = Self.modelList(try? c.decodeIfPresent([JSONValue].self, forKey: .pinned))
        self.recent = Self.modelList(try? c.decodeIfPresent([JSONValue].self, forKey: .recent))
    }
}

public struct RunningWorkInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let agentId: String
    public let title: String?
    public let turn: Bool
    public let waiting: Int
    public let subagents: Int?
    public let commands: Int?
    public let monitors: Int?
    public let tasks: Int?

    enum CodingKeys: String, CodingKey {
        case sessionId, agentId, title, turn, waiting, subagents, commands, monitors, tasks
    }

    public init(
        sessionId: String,
        agentId: String,
        title: String? = nil,
        turn: Bool = false,
        waiting: Int = 0,
        subagents: Int? = nil,
        commands: Int? = nil,
        monitors: Int? = nil,
        tasks: Int? = nil
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.title = title
        self.turn = turn
        self.waiting = waiting
        self.subagents = subagents
        self.commands = commands
        self.monitors = monitors
        self.tasks = tasks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.turn = try c.decodeIfPresent(Bool.self, forKey: .turn) ?? false
        self.waiting = try c.decodeIfPresent(Int.self, forKey: .waiting) ?? 0
        self.subagents = try c.decodeIfPresent(Int.self, forKey: .subagents)
        self.commands = try c.decodeIfPresent(Int.self, forKey: .commands)
        self.monitors = try c.decodeIfPresent(Int.self, forKey: .monitors)
        self.tasks = try c.decodeIfPresent(Int.self, forKey: .tasks)
    }
}

public struct ProjectWorktreeSettingsInfo: Codable, Sendable, Equatable {
    public let branchTemplate: String
    public let copy: [String]
    public let setup: String?
    public let waitForSetup: Bool

    enum CodingKeys: String, CodingKey {
        case branchTemplate, copy, setup, waitForSetup
    }

    public init(
        branchTemplate: String = "sarto/{slug}",
        copy: [String] = [],
        setup: String? = nil,
        waitForSetup: Bool = true
    ) {
        self.branchTemplate = branchTemplate
        self.copy = copy
        self.setup = setup
        self.waitForSetup = waitForSetup
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.branchTemplate = try c.decodeIfPresent(String.self, forKey: .branchTemplate) ?? "sarto/{slug}"
        self.copy = (try? c.decode([String].self, forKey: .copy)) ?? []
        self.setup = try c.decodeIfPresent(String.self, forKey: .setup)
        self.waitForSetup = try c.decodeIfPresent(Bool.self, forKey: .waitForSetup) ?? true
    }
}

public struct WorktreeCreateRequest: Codable, Sendable, Equatable {
    public let base: String
    public let branch: String?

    public init(base: String, branch: String? = nil) {
        self.base = base
        self.branch = branch
    }
}

/// What a session's agent still runs between turns, by its own reports: the background tasks the
/// session board lists and the subagents at work (`StillRunning` in `src/shared/agent-host.ts`).
public struct StillRunningInfo: Codable, Sendable, Equatable {
    public let commands: Int
    public let subagents: Int
    /// The agent starts a turn of its own to report once that work ends.
    public let reportsBack: Bool

    public init(commands: Int, subagents: Int, reportsBack: Bool) {
        self.commands = commands
        self.subagents = subagents
        self.reportsBack = reportsBack
    }

    public var hasWork: Bool { commands > 0 || subagents > 0 }
}

public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let agentId: String
    public let projectPath: String
    public let scratch: Bool?
    public let title: String?
    public let description: String?
    public let status: SessionStatus
    public let attention: String?
    public let permissionCount: Int
    public let createdAt: Double
    public let updatedAt: Double
    public let parentId: String?
    public let origin: String?
    public let branch: String?
    public let model: String?
    public let pinnedAt: Double?
    public let archivedAt: Double?
    public let acpSessionId: String?
    public let missing: Bool?
    public let worktree: SessionWorktreeInfo?
    public let prepared: PreparedInfo?
    public let prs: [SessionPullRequestInfo]?
    public let plan: PlanProgress?
    public let turnStartedAt: Double?
    public let activity: SessionActivity?
    public let phase: String?
    public let cache: PromptCacheInfo?
    /// How its last turn ended; nil while a turn runs, before any ended, and from older hosts.
    public let lastTurn: LastTurn?
    /// What runs on after its turn ended; nil while a turn runs, when nothing does, and from older hosts.
    public let stillRunning: StillRunningInfo?
    /// Set when this local session runs Claude Code on another computer of the same account.
    public let modelHost: ModelHostRef?

    enum CodingKeys: String, CodingKey {
        case id, agentId, projectPath, scratch, title, description, status, attention
        case permissionCount, createdAt, updatedAt, parentId, origin, branch, model
        case pinnedAt, archivedAt, acpSessionId, missing, worktree, prepared, prs
        case plan, turnStartedAt, activity, phase, cache, lastTurn, stillRunning, modelHost
    }

    public init(
        id: String,
        agentId: String,
        projectPath: String,
        scratch: Bool? = nil,
        title: String? = nil,
        description: String? = nil,
        status: SessionStatus,
        attention: String? = nil,
        permissionCount: Int = 0,
        createdAt: Double = 0,
        updatedAt: Double = 0,
        parentId: String? = nil,
        origin: String? = "user",
        branch: String? = nil,
        model: String? = nil,
        pinnedAt: Double? = nil,
        archivedAt: Double? = nil,
        acpSessionId: String? = nil,
        missing: Bool? = nil,
        worktree: SessionWorktreeInfo? = nil,
        prepared: PreparedInfo? = nil,
        prs: [SessionPullRequestInfo]? = nil,
        plan: PlanProgress? = nil,
        turnStartedAt: Double? = nil,
        activity: SessionActivity? = nil,
        phase: String? = nil,
        cache: PromptCacheInfo? = nil,
        lastTurn: LastTurn? = nil,
        stillRunning: StillRunningInfo? = nil,
        modelHost: ModelHostRef? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
        self.scratch = scratch
        self.title = title
        self.description = description
        self.status = status
        self.attention = attention
        self.permissionCount = permissionCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentId = parentId
        self.origin = origin
        self.branch = branch
        self.model = model
        self.pinnedAt = pinnedAt
        self.archivedAt = archivedAt
        self.acpSessionId = acpSessionId
        self.missing = missing
        self.worktree = worktree
        self.prepared = prepared
        self.prs = prs
        self.plan = plan
        self.turnStartedAt = turnStartedAt
        self.activity = activity
        self.phase = phase
        self.cache = cache
        self.lastTurn = lastTurn
        self.stillRunning = stillRunning
        self.modelHost = modelHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.agentId = try c.decode(String.self, forKey: .agentId)
        self.projectPath = try c.decode(String.self, forKey: .projectPath)
        self.scratch = try c.decodeIfPresent(Bool.self, forKey: .scratch)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description)
        self.status = try c.decode(SessionStatus.self, forKey: .status)
        self.attention = try c.decodeIfPresent(String.self, forKey: .attention)
        self.permissionCount = try c.decode(Int.self, forKey: .permissionCount)
        self.createdAt = try c.decode(Double.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin)
        self.branch = try c.decodeIfPresent(String.self, forKey: .branch)
        self.model = try c.decodeIfPresent(String.self, forKey: .model)
        self.pinnedAt = try c.decodeIfPresent(Double.self, forKey: .pinnedAt)
        self.archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt)
        self.acpSessionId = try c.decodeIfPresent(String.self, forKey: .acpSessionId)
        self.missing = try c.decodeIfPresent(Bool.self, forKey: .missing)
        self.worktree = try c.decodeIfPresent(SessionWorktreeInfo.self, forKey: .worktree)
        self.prepared = try c.decodeIfPresent(PreparedInfo.self, forKey: .prepared)
        self.prs = try c.decodeIfPresent([SessionPullRequestInfo].self, forKey: .prs)
        self.plan = try c.decodeIfPresent(PlanProgress.self, forKey: .plan)
        self.turnStartedAt = try c.decodeIfPresent(Double.self, forKey: .turnStartedAt)
        self.activity = try c.decodeIfPresent(SessionActivity.self, forKey: .activity)
        self.phase = try c.decodeIfPresent(String.self, forKey: .phase)
        self.cache = try c.decodeIfPresent(PromptCacheInfo.self, forKey: .cache)
        self.lastTurn = try c.decodeIfPresent(LastTurn.self, forKey: .lastTurn)
        self.stillRunning = (try? c.decodeIfPresent(StillRunningInfo.self, forKey: .stillRunning)) ?? nil
        self.modelHost = try c.decodeIfPresent(ModelHostRef.self, forKey: .modelHost)
    }
}

public struct SessionCost: Codable, Sendable, Equatable {
    public let amount: Double
    public let currency: String
}

public struct TokenTotals: Codable, Sendable, Equatable {
    public let total: Double
    public let input: Double
    public let output: Double
    public let thought: Double?
    public let cacheRead: Double?
    public let cacheWrite: Double?

    public init(
        total: Double,
        input: Double,
        output: Double,
        thought: Double? = nil,
        cacheRead: Double? = nil,
        cacheWrite: Double? = nil
    ) {
        self.total = total
        self.input = input
        self.output = output
        self.thought = thought
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct SessionUsage: Codable, Sendable, Equatable {
    public let used: Double
    public let size: Double
    public let cost: SessionCost?
    public let tokens: TokenTotals?
    public let cache: PromptCacheInfo?

    public init(
        used: Double,
        size: Double,
        cost: SessionCost? = nil,
        tokens: TokenTotals? = nil,
        cache: PromptCacheInfo? = nil
    ) {
        self.used = used
        self.size = size
        self.cost = cost
        self.tokens = tokens
        self.cache = cache
    }

    public var fillRatio: Double {
        guard size > 0 else { return 0 }
        return max(0, min(1, used / size))
    }
}

public struct ConfigChoice: Codable, Sendable, Equatable, Identifiable {
    public var id: String { value }
    public let value: String
    public let name: String
    public let description: String?
    public let group: String?
    public let older: Bool?
    public let shownAs: String?
    public let modelId: String?

    public init(
        value: String,
        name: String,
        description: String? = nil,
        group: String? = nil,
        older: Bool? = nil,
        shownAs: String? = nil,
        modelId: String? = nil
    ) {
        self.value = value
        self.name = name
        self.description = description
        self.group = group
        self.older = older
        self.shownAs = shownAs
        self.modelId = modelId
    }
}

public enum PendingConfigWait: String, Codable, Sendable, Equatable {
    case turn
    case background
    case restarting
}

public struct PendingConfig: Codable, Sendable, Equatable {
    public let value: String
    public let wait: PendingConfigWait

    public init(value: String, wait: PendingConfigWait) {
        self.value = value
        self.wait = wait
    }
}

public struct ConfigOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    public let category: String
    public let type: String
    public let value: JSONValue
    public let choices: [ConfigChoice]?
    public let idleOnly: Bool?
    public let defaultValue: Bool?
    public let indicator: Bool?
    public let pending: PendingConfig?

    public var resolvedBoolValue: Bool {
        if let b = value.boolValue { return b }
        if value.stringValue == "default" { return defaultValue ?? false }
        return false
    }

    public init(
        id: String,
        name: String,
        description: String? = nil,
        category: String,
        type: String,
        value: JSONValue,
        choices: [ConfigChoice]? = nil,
        idleOnly: Bool? = nil,
        defaultValue: Bool? = nil,
        indicator: Bool? = nil,
        pending: PendingConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.type = type
        self.value = value
        self.choices = choices
        self.idleOnly = idleOnly
        self.defaultValue = defaultValue
        self.indicator = indicator
        self.pending = pending
    }
}

public struct SessionErrorInfo: Codable, Sendable, Equatable {
    public let message: String
    public let detail: String?
}

public struct DayUsageInfo: Codable, Sendable, Equatable {
    public let day: Int
    public let agentId: String
    public let input: Double
    public let output: Double
    public let reasoning: Double?
    public let cacheRead: Double?
    public let cacheWrite: Double?
    public let requests: Int?
    public let turns: Int?

    public var totalTokens: Double {
        input + output + (reasoning ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0)
    }
}

public struct UsageSummaryInfo: Codable, Sendable, Equatable {
    public let days: [DayUsageInfo]
    public let agents: [String]?
}

public struct SlashCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let inputHint: String?

    public init(name: String, description: String, inputHint: String? = nil) {
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

/// How a turn a child session ran for its starter ended, null for a failure.
public struct FromSessionEnded: Codable, Sendable, Equatable {
    public let agent: String
    public let stopReason: String?

    public init(agent: String, stopReason: String? = nil) {
        self.agent = agent
        self.stopReason = stopReason
    }
}

/// The session that started, messaged, or reported back to this session through the session tools.
public struct FromSession: Codable, Sendable, Equatable {
    public let sessionId: String
    public let title: String
    public let report: Bool?
    public let ended: FromSessionEnded?

    public init(
        sessionId: String,
        title: String,
        report: Bool? = nil,
        ended: FromSessionEnded? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.report = report
        self.ended = ended
    }
}

/// The paired device a queued or sent prompt came from.
public struct FromDevice: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// How a queued prompt built from passage comments summarizes itself in the queue.
public struct QueuedComments: Codable, Sendable, Equatable {
    public let count: Int
    public let text: String

    public init(count: Int, text: String) {
        self.count = count
        self.text = text
    }
}

public struct QueuedPrompt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let content: [UserContent]
    public let at: Double
    public let from: FromSession?
    public let device: FromDevice?
    public let approval: Bool?
    public let sarto: Bool?
    public let comments: QueuedComments?

    public init(
        id: String,
        content: [UserContent],
        at: Double = 0,
        from: FromSession? = nil,
        device: FromDevice? = nil,
        approval: Bool? = nil,
        sarto: Bool? = nil,
        comments: QueuedComments? = nil
    ) {
        self.id = id
        self.content = content
        self.at = at
        self.from = from
        self.device = device
        self.approval = approval
        self.sarto = sarto
        self.comments = comments
    }

    public var textBody: String {
        content.compactMap(\.text).joined(separator: "\n")
    }

    public var attachmentCount: Int {
        content.reduce(0) { count, item in
            if case .ref = item { return count + 1 }
            return count
        }
    }

    /// True when this queued item is Sarto's automated turn-ended report from a started child session.
    public var isSessionReport: Bool {
        from?.ended != nil
    }

    /// Only user-authored prompts can be pulled back into the composer for editing.
    public var isUserEditable: Bool {
        from == nil && approval != true && sarto != true
    }
}

public struct SessionFindMatchInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { entryId }
    public let pos: Int
    public let entryId: String
    public let role: String

    public init(pos: Int, entryId: String, role: String) {
        self.pos = pos
        self.entryId = entryId
        self.role = role
    }
}

public struct SessionFindResult: Codable, Sendable, Equatable {
    public let matches: [SessionFindMatchInfo]
    public let capped: Bool

    public init(matches: [SessionFindMatchInfo], capped: Bool = false) {
        self.matches = matches
        self.capped = capped
    }
}

public struct OutlineEntryInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { entryId }
    public let pos: Int
    public let entryId: String
    public let text: String
    public let title: String?

    public init(pos: Int, entryId: String, text: String, title: String? = nil) {
        self.pos = pos
        self.entryId = entryId
        self.text = text
        self.title = title
    }
}

public struct OlderPageInfo: Codable, Sendable, Equatable {
    public let entries: [ThreadEntry]
    public let older: Int?
    /// What `entries` carry beyond their `ThreadEntry` cases, by entry id.
    public let entryExtras: [String: ThreadEntryExtras]

    enum CodingKeys: String, CodingKey {
        case entries, older
    }

    public init(entries: [ThreadEntry], older: Int? = nil, entryExtras: [String: ThreadEntryExtras] = [:]) {
        self.entries = entries
        self.older = older
        self.entryExtras = entryExtras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let read = try c.decode([ThreadEntryWithExtras].self, forKey: .entries)
        self.entries = read.map(\.entry)
        self.older = try c.decodeIfPresent(Int.self, forKey: .older)
        self.entryExtras = ThreadEntryWithExtras.extrasById(read)
    }
}

public struct BackgroundTaskInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: String // "shell" | "monitor" | "workflow" | "other"
    public let title: String
    public let command: String?
    public let status: String // "running" | "completed" | "failed" | "stopped"
    public let startedAt: Double
    public let endedAt: Double?
    public let summary: String?
    /// Set for a command running on in its own tool call entry (e.g. Antigravity ACP daemons).
    public let entryId: String?
    /// Whether the agent host supports stopping this task via `sessions.stopTask`.
    public let canStop: Bool?
    /// Whether the agent host supports reading live output via `sessions.taskOutput`.
    public let canReadOutput: Bool?

    /// Whether the UI can stop this task (either `sessions.stopTask` or canceling an in-turn tool).
    public var supportsStop: Bool {
        if id.hasPrefix("tool:") { return true }
        if let canStop { return canStop }
        return entryId == nil
    }

    /// Whether output can be shown (from host `sessions.taskOutput` or locally from its tool entry).
    public var supportsOutput: Bool {
        if id.hasPrefix("tool:") || entryId != nil { return true }
        return canReadOutput ?? true
    }

    public init(
        id: String,
        kind: String,
        title: String,
        command: String? = nil,
        status: String,
        startedAt: Double = 0,
        endedAt: Double? = nil,
        summary: String? = nil,
        entryId: String? = nil,
        canStop: Bool? = nil,
        canReadOutput: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.command = command
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.entryId = entryId
        self.canStop = canStop
        self.canReadOutput = canReadOutput
    }
}

public struct BackgroundTaskOutput: Codable, Sendable, Equatable {
    public let output: String
    public let truncated: Bool

    public init(output: String, truncated: Bool = false) {
        self.output = output
        self.truncated = truncated
    }
}

public struct SubagentInfoView: Codable, Sendable, Equatable {
    public let description: String?
    public let canCancel: Bool
    public let stateKnown: Bool?
    public let stopReason: String?
    public let model: String?

    public init(
        description: String? = nil,
        canCancel: Bool = false,
        stateKnown: Bool? = nil,
        stopReason: String? = nil,
        model: String? = nil
    ) {
        self.description = description
        self.canCancel = canCancel
        self.stateKnown = stateKnown
        self.stopReason = stopReason
        self.model = model
    }
}

public struct SessionView: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var agentId: String
    public let projectPath: String
    public var status: SessionStatus
    public var title: String?
    public var config: [ConfigOption]
    public var commands: [SlashCommand]
    public var usage: SessionUsage?
    public var speed: OutputSpeedInfo?
    public var lastRequest: LastRequestInfo?
    public var error: SessionErrorInfo?
    public var turnStartedAt: Double?
    public var turnStartUsed: Double?
    public let createdAt: Double
    public var updatedAt: Double
    public var parentId: String?
    public var origin: String?
    public var subagent: SubagentInfoView?
    public var background: [BackgroundTaskInfo]
    public var queue: [QueuedPrompt]
    public var queuePaused: Bool
    public var heldOutside: Bool?
    /// Set while an edit from a message holds the turns from it aside, until the next send.
    public var rewound: RewoundView?
    /// The agent said this conversation cannot be cut, as a Codex thread of the older format.
    public var noRewind: Bool?
    /// Ephemeral next-message suggestion shown as ghost text in an empty composer.
    public var suggestion: String?
    /// Set when this local session runs Claude Code on another computer of the same account.
    public var modelHost: ModelHostRef?

    enum CodingKeys: String, CodingKey {
        case id, agentId, projectPath, status, title, config, commands, usage
        case speed, lastRequest, error, turnStartedAt, turnStartUsed, createdAt, updatedAt
        case parentId, origin, subagent, background, queue, queuePaused, heldOutside
        case rewound, noRewind, suggestion, modelHost
    }

    public init(
        id: String,
        agentId: String,
        projectPath: String,
        status: SessionStatus,
        title: String? = nil,
        config: [ConfigOption] = [],
        commands: [SlashCommand] = [],
        usage: SessionUsage? = nil,
        speed: OutputSpeedInfo? = nil,
        lastRequest: LastRequestInfo? = nil,
        error: SessionErrorInfo? = nil,
        turnStartedAt: Double? = nil,
        turnStartUsed: Double? = nil,
        createdAt: Double = 0,
        updatedAt: Double = 0,
        parentId: String? = nil,
        origin: String? = nil,
        subagent: SubagentInfoView? = nil,
        background: [BackgroundTaskInfo] = [],
        queue: [QueuedPrompt] = [],
        queuePaused: Bool = false,
        heldOutside: Bool? = nil,
        rewound: RewoundView? = nil,
        noRewind: Bool? = nil,
        suggestion: String? = nil,
        modelHost: ModelHostRef? = nil
    ) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
        self.status = status
        self.title = title
        self.config = config
        self.commands = commands
        self.usage = usage
        self.speed = speed
        self.lastRequest = lastRequest
        self.error = error
        self.turnStartedAt = turnStartedAt
        self.turnStartUsed = turnStartUsed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentId = parentId
        self.origin = origin
        self.subagent = subagent
        self.background = background
        self.queue = queue
        self.queuePaused = queuePaused
        self.heldOutside = heldOutside
        self.rewound = rewound
        self.noRewind = noRewind
        self.suggestion = suggestion
        self.modelHost = modelHost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.agentId = try c.decode(String.self, forKey: .agentId)
        self.projectPath = try c.decode(String.self, forKey: .projectPath)
        self.status = try c.decode(SessionStatus.self, forKey: .status)
        self.title = try c.decodeIfPresent(String.self, forKey: .title)
        self.config = (try? c.decode([ConfigOption].self, forKey: .config)) ?? []
        self.commands = (try? c.decode([SlashCommand].self, forKey: .commands)) ?? []
        self.usage = try? c.decodeIfPresent(SessionUsage.self, forKey: .usage)
        self.speed = try? c.decodeIfPresent(OutputSpeedInfo.self, forKey: .speed)
        self.lastRequest = try? c.decodeIfPresent(LastRequestInfo.self, forKey: .lastRequest)
        self.error = try? c.decodeIfPresent(SessionErrorInfo.self, forKey: .error)
        self.turnStartedAt = try c.decodeIfPresent(Double.self, forKey: .turnStartedAt)
        self.turnStartUsed = try c.decodeIfPresent(Double.self, forKey: .turnStartUsed)
        self.createdAt = try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0
        self.updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        self.parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        self.origin = try c.decodeIfPresent(String.self, forKey: .origin)
        self.subagent = try? c.decodeIfPresent(SubagentInfoView.self, forKey: .subagent)
        self.background = (try? c.decode([BackgroundTaskInfo].self, forKey: .background)) ?? []
        self.queue = (try? c.decode([QueuedPrompt].self, forKey: .queue)) ?? []
        self.queuePaused = try c.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? false
        self.heldOutside = try c.decodeIfPresent(Bool.self, forKey: .heldOutside)
        self.rewound = try? c.decodeIfPresent(RewoundView.self, forKey: .rewound)
        self.noRewind = try? c.decodeIfPresent(Bool.self, forKey: .noRewind)
        self.suggestion = try? c.decodeIfPresent(String.self, forKey: .suggestion)
        self.modelHost = try? c.decodeIfPresent(ModelHostRef.self, forKey: .modelHost)
    }
}

// MARK: - Thread Entries & Permissions

/// Attachment metadata mirroring `Attachment` in `src/shared/thread.ts`.
public struct AttachmentInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String // "image" | "file" | "folder" | "text"
    public let name: String
    public let uri: String?
    public let mimeType: String?
    public let size: Int?
    public let sent: String? // "image" | "embedded" | "linked" | "inline" | nil
    public let thumb: String? // data:image/(webp|png|jpeg);base64,... or data:text/plain;...
    public let blob: String? // SHA-256 hash in thread store

    public init(
        id: String,
        type: String,
        name: String,
        uri: String? = nil,
        mimeType: String? = nil,
        size: Int? = nil,
        sent: String? = nil,
        thumb: String? = nil,
        blob: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.uri = uri
        self.mimeType = mimeType
        self.size = size
        self.sent = sent
        self.thumb = thumb
        self.blob = blob
    }
}

/// Forward-compatible Swift representation of `ContentRef` in `src/shared/thread.ts`.
public enum ContentRef: Codable, Sendable, Equatable {
    case imageData(mimeType: String, data: String)
    case imageBlob(mimeType: String, blob: String)
    case attachment(AttachmentInfo)
    case link(uri: String, name: String)
    case audio(mimeType: String, size: Int?, name: String?)
    case video(mimeType: String, size: Int?, name: String?)
    case terminal(terminalId: String, name: String)
    case page(tabId: String, name: String)
    case device(deviceId: String, name: String)
    case unsupported(label: String)
    case other(kind: String)

    enum CodingKeys: String, CodingKey {
        case kind, mimeType, data, blob, attachment, uri, name, size, terminalId, tabId, deviceId, label
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "image":
            let mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "image/png"
            if let blob = try c.decodeIfPresent(String.self, forKey: .blob) {
                self = .imageBlob(mimeType: mimeType, blob: blob)
            } else if let data = try c.decodeIfPresent(String.self, forKey: .data) {
                self = .imageData(mimeType: mimeType, data: data)
            } else {
                self = .other(kind: kind)
            }
        case "attachment":
            self = .attachment(try c.decode(AttachmentInfo.self, forKey: .attachment))
        case "link":
            self = .link(
                uri: try c.decode(String.self, forKey: .uri),
                name: try c.decode(String.self, forKey: .name)
            )
        case "audio":
            self = .audio(
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "audio/mpeg",
                size: try c.decodeIfPresent(Int.self, forKey: .size),
                name: try c.decodeIfPresent(String.self, forKey: .name)
            )
        case "video":
            self = .video(
                mimeType: try c.decodeIfPresent(String.self, forKey: .mimeType) ?? "video/mp4",
                size: try c.decodeIfPresent(Int.self, forKey: .size),
                name: try c.decodeIfPresent(String.self, forKey: .name)
            )
        case "terminal":
            self = .terminal(
                terminalId: try c.decode(String.self, forKey: .terminalId),
                name: try c.decode(String.self, forKey: .name)
            )
        case "page":
            self = .page(
                tabId: try c.decode(String.self, forKey: .tabId),
                name: try c.decode(String.self, forKey: .name)
            )
        case "device":
            self = .device(
                deviceId: try c.decode(String.self, forKey: .deviceId),
                name: try c.decode(String.self, forKey: .name)
            )
        case "unsupported":
            self = .unsupported(label: try c.decodeIfPresent(String.self, forKey: .label) ?? "Unsupported")
        default:
            self = .other(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .imageData(let mimeType, let data):
            try c.encode("image", forKey: .kind)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(data, forKey: .data)
        case .imageBlob(let mimeType, let blob):
            try c.encode("image", forKey: .kind)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encode(blob, forKey: .blob)
        case .attachment(let attachment):
            try c.encode("attachment", forKey: .kind)
            try c.encode(attachment, forKey: .attachment)
        case .link(let uri, let name):
            try c.encode("link", forKey: .kind)
            try c.encode(uri, forKey: .uri)
            try c.encode(name, forKey: .name)
        case .audio(let mimeType, let size, let name):
            try c.encode("audio", forKey: .kind)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(size, forKey: .size)
            try c.encodeIfPresent(name, forKey: .name)
        case .video(let mimeType, let size, let name):
            try c.encode("video", forKey: .kind)
            try c.encode(mimeType, forKey: .mimeType)
            try c.encodeIfPresent(size, forKey: .size)
            try c.encodeIfPresent(name, forKey: .name)
        case .terminal(let terminalId, let name):
            try c.encode("terminal", forKey: .kind)
            try c.encode(terminalId, forKey: .terminalId)
            try c.encode(name, forKey: .name)
        case .page(let tabId, let name):
            try c.encode("page", forKey: .kind)
            try c.encode(tabId, forKey: .tabId)
            try c.encode(name, forKey: .name)
        case .device(let deviceId, let name):
            try c.encode("device", forKey: .kind)
            try c.encode(deviceId, forKey: .deviceId)
            try c.encode(name, forKey: .name)
        case .unsupported(let label):
            try c.encode("unsupported", forKey: .kind)
            try c.encode(label, forKey: .label)
        case .other(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// Content item of a user message, mirroring `UserContent` in `src/shared/thread.ts`.
public enum UserContent: Codable, Sendable, Equatable {
    case text(String)
    case ref(ContentRef)

    public var text: String? {
        if case .text(let s) = self { return s }
        return nil
    }

    public var ref: ContentRef? {
        if case .ref(let r) = self { return r }
        return nil
    }

    public init(text: String) {
        self = .text(text)
    }

    public init(attachment: AttachmentInfo) {
        self = .ref(.attachment(attachment))
    }

    enum CodingKeys: String, CodingKey {
        case type, text, ref
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "ref":
            self = .ref(try c.decode(ContentRef.self, forKey: .ref))
        default:
            self = .ref(.other(kind: type))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .ref(let ref):
            try c.encode("ref", forKey: .type)
            try c.encode(ref, forKey: .ref)
        }
    }
}

public struct PlanItem: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public let content: String
    public let priority: String
    public let status: String

    /// Stable across status transitions ("pending" -> "in_progress" -> "completed").
    public var id: String { "\(index)-\(content)" }

    enum CodingKeys: String, CodingKey {
        case content, priority, status
    }

    public init(index: Int = 0, content: String, priority: String, status: String) {
        self.index = index
        self.content = content
        self.priority = priority
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.index = 0
        self.content = try c.decode(String.self, forKey: .content)
        self.priority = try c.decode(String.self, forKey: .priority)
        self.status = try c.decode(String.self, forKey: .status)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(content, forKey: .content)
        try c.encode(priority, forKey: .priority)
        try c.encode(status, forKey: .status)
    }

    public static func == (lhs: PlanItem, rhs: PlanItem) -> Bool {
        lhs.content == rhs.content && lhs.priority == rhs.priority && lhs.status == rhs.status
    }

    public static func indexed(_ items: [PlanItem]) -> [PlanItem] {
        items.enumerated().map { idx, item in
            var copy = item
            copy.index = idx
            return copy
        }
    }
}

public struct PermissionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let description: String?
    public let preferred: Bool?
    public let note: Bool?

    public init(id: String, name: String, kind: String, description: String? = nil, preferred: Bool? = nil, note: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.description = description
        self.preferred = preferred
        self.note = note
    }
}

public struct PendingQuestionOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String { label }
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct PendingQuestion: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(header)-\(question)" }
    public let header: String
    public let question: String
    public let multiSelect: Bool
    public let options: [PendingQuestionOption]
    public let allowsText: Bool
    public let secret: Bool

    public init(
        header: String = "",
        question: String,
        multiSelect: Bool = false,
        options: [PendingQuestionOption],
        allowsText: Bool = true,
        secret: Bool = false
    ) {
        self.header = header
        self.question = question
        self.multiSelect = multiSelect
        self.options = options
        self.allowsText = allowsText
        self.secret = secret
    }
}

public struct QuestionAnswer: Codable, Sendable, Equatable {
    public let question: Int
    public let choices: [Int]
    public let text: String?

    public init(question: Int, choices: [Int], text: String? = nil) {
        self.question = question
        self.choices = choices
        self.text = text
    }
}

public struct PendingPlanApproval: Codable, Sendable, Equatable {
    public let markdown: String
    public let previous: String?
}

public struct PendingPermission: Codable, Sendable, Equatable {
    public let requestId: String
    public let options: [PermissionOption]
    public let questions: [PendingQuestion]?
    public let plan: PendingPlanApproval?
    public let elicitation: PendingElicitation?

    public init(
        requestId: String,
        options: [PermissionOption],
        questions: [PendingQuestion]? = nil,
        plan: PendingPlanApproval? = nil,
        elicitation: PendingElicitation? = nil
    ) {
        self.requestId = requestId
        self.options = options
        self.questions = questions
        self.plan = plan
        self.elicitation = elicitation
    }
}

public struct ToolInputDigestInfo: Codable, Sendable, Equatable {
    public let size: Int
    public let lines: Int

    public init(size: Int, lines: Int) {
        self.size = size
        self.lines = lines
    }
}

public enum ToolContentItem: Codable, Sendable, Equatable {
    case markdown(String)
    case diff(path: String, oldText: String?, newText: String)
    case ref(ContentRef)
    case digest(of: String, path: String?, lines: Int?, size: Int, added: Int? = nil, removed: Int? = nil)
    case other(type: String)

    enum CodingKeys: String, CodingKey {
        case type, markdown, path, oldText, newText, ref, of, lines, size, added, removed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "markdown":
            self = .markdown(try c.decode(String.self, forKey: .markdown))
        case "diff":
            self = .diff(
                path: try c.decode(String.self, forKey: .path),
                oldText: try c.decodeIfPresent(String.self, forKey: .oldText),
                newText: try c.decode(String.self, forKey: .newText)
            )
        case "ref":
            self = .ref(try c.decode(ContentRef.self, forKey: .ref))
        case "digest":
            self = .digest(
                of: try c.decode(String.self, forKey: .of),
                path: try c.decodeIfPresent(String.self, forKey: .path),
                lines: try c.decodeIfPresent(Int.self, forKey: .lines),
                size: try c.decodeIfPresent(Int.self, forKey: .size) ?? 0,
                added: try c.decodeIfPresent(Int.self, forKey: .added),
                removed: try c.decodeIfPresent(Int.self, forKey: .removed)
            )
        default:
            self = .other(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .markdown(let md):
            try c.encode("markdown", forKey: .type)
            try c.encode(md, forKey: .markdown)
        case .diff(let path, let oldText, let newText):
            try c.encode("diff", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encodeIfPresent(oldText, forKey: .oldText)
            try c.encode(newText, forKey: .newText)
        case .ref(let ref):
            try c.encode("ref", forKey: .type)
            try c.encode(ref, forKey: .ref)
        case .digest(let of, let path, let lines, let size, let added, let removed):
            try c.encode("digest", forKey: .type)
            try c.encode(of, forKey: .of)
            try c.encodeIfPresent(path, forKey: .path)
            try c.encodeIfPresent(lines, forKey: .lines)
            try c.encode(size, forKey: .size)
            try c.encodeIfPresent(added, forKey: .added)
            try c.encodeIfPresent(removed, forKey: .removed)
        case .other(let t):
            try c.encode(t, forKey: .type)
        }
    }
}

public struct ToolLocation: Codable, Sendable, Equatable {
    public let path: String
    public let line: Int?

    public init(path: String, line: Int? = nil) {
        self.path = path
        self.line = line
    }
}

public struct ToolEntryData: Codable, Sendable, Equatable {
    public let id: String
    public var title: String
    public var toolKind: String
    public var status: String
    public var content: [ToolContentItem]
    public var locations: [ToolLocation]
    public var permission: PendingPermission?
    public var permissionResult: JSONValue?
    public var rawInput: String?
    public var rawInputDigest: String?
    public var rawInputDigestInfo: ToolInputDigestInfo?
    public var description: String?
    public var label: String?
    public var question: String?
    public var planVersion: Int?
    public var elicitation: ToolElicitationSummary?

    public init(
        id: String,
        title: String,
        toolKind: String,
        status: String,
        content: [ToolContentItem] = [],
        locations: [ToolLocation] = [],
        permission: PendingPermission? = nil,
        permissionResult: JSONValue? = nil,
        rawInput: String? = nil,
        description: String? = nil,
        label: String? = nil,
        question: String? = nil,
        planVersion: Int? = nil,
        elicitation: ToolElicitationSummary? = nil,
        rawInputDigest: String? = nil,
        rawInputDigestInfo: ToolInputDigestInfo? = nil
    ) {
        self.id = id
        self.title = title
        self.toolKind = toolKind
        self.status = status
        self.content = content
        self.locations = locations
        self.permission = permission
        self.permissionResult = permissionResult
        self.rawInput = rawInput
        self.rawInputDigest = rawInputDigest
        self.rawInputDigestInfo = rawInputDigestInfo
        self.description = description
        self.label = label
        self.question = question
        self.planVersion = planVersion
        self.elicitation = elicitation
    }

    /// True when the daemon omitted large tool content or raw input under `tool-digests`
    /// and the full entry can be fetched on demand via `sessions.entry`.
    public var hasDigestedContent: Bool {
        if rawInputDigestInfo != nil { return true }
        if let rawInputDigest, !rawInputDigest.isEmpty { return true }
        return content.contains { item in
            if case .digest = item { return true }
            return false
        }
    }

    static func parseRawInputDigest(_ value: JSONValue?) -> (text: String?, info: ToolInputDigestInfo?) {
        guard let value, value != .null else { return (nil, nil) }
        if let str = value.stringValue {
            return (str, nil)
        }
        if let obj = value.objectValue,
           let size = obj["size"]?.doubleValue.flatMap(Int.wholePart(of:)),
           let lines = obj["lines"]?.doubleValue.flatMap(Int.wholePart(of:)) {
            let info = ToolInputDigestInfo(size: size, lines: lines)
            return ("\(lines) lines (\(size) bytes)", info)
        }
        return (nil, nil)
    }
}

/// Forward-compatible Swift representation of Sarto's ThreadEntry union.
public enum ThreadEntry: Codable, Sendable, Equatable, Identifiable {
    case user(id: String, text: String, content: [UserContent] = [], at: Double?, approval: Bool, steered: Bool = false)
    case agent(id: String, markdown: String, streaming: Bool, at: Double?, attachments: [ContentRef] = [])
    case thought(id: String, markdown: String, streaming: Bool, durationMs: Double?)
    case tool(ToolEntryData)
    case subagent(id: String, sessionId: String)
    case sessionStarted(id: String, sessionId: String, after: String?)
    case sessionMessage(id: String, senderId: String?, content: [UserContent])
    case plan(id: String, items: [PlanItem])
    case notice(id: String, severity: String, title: String, description: String?, cause: String? = nil, model: String? = nil)
    case turnEnd(id: String, stopReason: String, durationMs: Double)
    case compaction(id: String, status: String, summary: String)
    case takeover(id: String, agentId: String, turns: Int, omitted: Int, carried: String, summarize: Bool?)
    case git(GitEntryPayload)
    case artifact(ArtifactEntryPayload)
    case memory(MemoryWriteEntryPayload)
    case settingsChange(SettingsChangeEntryPayload)
    case browserOrigin(BrowserOriginEntryPayload)
    case controlAsk(ControlAskEntryPayload)
    case controlNote(ControlNoteEntryPayload)
    case deviceAccess(DeviceAccessEntryPayload)
    case surfaceAccess(SurfaceAccessEntryPayload)
    case computerApp(ComputerAppEntryPayload)
    case computerSetup(ComputerSetupEntryPayload)
    case projectMcp(ProjectMcpEntryPayload)
    case projectHooks(ProjectHooksEntryPayload)
    case problemReport(ProblemReportEntryPayload)
    case marketPublish(MarketPublishEntryPayload)
    case unknown(id: String, kind: String)

    public var id: String {
        switch self {
        case .user(let id, _, _, _, _, _): return id
        case .agent(let id, _, _, _, _): return id
        case .thought(let id, _, _, _): return id
        case .tool(let data): return data.id
        case .subagent(let id, _): return id
        case .sessionStarted(let id, _, _): return id
        case .sessionMessage(let id, _, _): return id
        case .plan(let id, _): return id
        case .notice(let id, _, _, _, _, _): return id
        case .turnEnd(let id, _, _): return id
        case .compaction(let id, _, _): return id
        case .takeover(let id, _, _, _, _, _): return id
        case .git(let p): return p.id
        case .artifact(let p): return p.id
        case .memory(let p): return p.id
        case .settingsChange(let p): return p.id
        case .browserOrigin(let p): return p.id
        case .controlAsk(let p): return p.id
        case .controlNote(let p): return p.id
        case .deviceAccess(let p): return p.id
        case .surfaceAccess(let p): return p.id
        case .computerApp(let p): return p.id
        case .computerSetup(let p): return p.id
        case .projectMcp(let p): return p.id
        case .projectHooks(let p): return p.id
        case .problemReport(let p): return p.id
        case .marketPublish(let p): return p.id
        case .unknown(let id, _): return id
        }
    }

    public var agentAttachments: [ContentRef] {
        if case .agent(_, _, _, _, let attachments) = self {
            return attachments
        }
        return []
    }

    enum CodingKeys: String, CodingKey {
        case kind, id, content, at, approval, steered, markdown, attachments, streaming, durationMs
        case title, toolKind, status, locations, permission, permissionResult, rawInput, rawInputDigest
        case description, label, question, planVersion, elicitation
        case items, severity, cause, model, stopReason, summary
        case sessionId, after, senderId, agentId, turns, omitted, carried, summarize
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let id = try c.decode(String.self, forKey: .id)
        switch kind {
        case "user":
            let parts = (try? c.decode([UserContent].self, forKey: .content)) ?? []
            let joined = parts.compactMap(\.text).joined(separator: "\n")
            let at = try c.decodeIfPresent(Double.self, forKey: .at)
            let approval = try c.decodeIfPresent(Bool.self, forKey: .approval) ?? false
            let steered = try c.decodeIfPresent(Bool.self, forKey: .steered) ?? false
            self = .user(id: id, text: joined, content: parts, at: at, approval: approval, steered: steered)
        case "agent":
            self = .agent(
                id: id,
                markdown: try c.decodeIfPresent(String.self, forKey: .markdown) ?? "",
                streaming: try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false,
                at: try c.decodeIfPresent(Double.self, forKey: .at),
                attachments: (try? c.decode([ContentRef].self, forKey: .attachments)) ?? []
            )
        case "thought":
            self = .thought(
                id: id,
                markdown: try c.decodeIfPresent(String.self, forKey: .markdown) ?? "",
                streaming: try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false,
                durationMs: try c.decodeIfPresent(Double.self, forKey: .durationMs)
            )
        case "tool":
            let rawDigestVal = try? c.decodeIfPresent(JSONValue.self, forKey: .rawInputDigest)
            let parsedDigest = ToolEntryData.parseRawInputDigest(rawDigestVal)
            let data = ToolEntryData(
                id: id,
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "Tool",
                toolKind: try c.decodeIfPresent(String.self, forKey: .toolKind) ?? "other",
                status: try c.decodeIfPresent(String.self, forKey: .status) ?? "pending",
                content: (try? c.decode([ToolContentItem].self, forKey: .content)) ?? [],
                locations: (try? c.decode([ToolLocation].self, forKey: .locations)) ?? [],
                permission: try c.decodeIfPresent(PendingPermission.self, forKey: .permission),
                permissionResult: try c.decodeIfPresent(JSONValue.self, forKey: .permissionResult),
                rawInput: try c.decodeIfPresent(String.self, forKey: .rawInput),
                description: try c.decodeIfPresent(String.self, forKey: .description),
                label: try c.decodeIfPresent(String.self, forKey: .label),
                question: try c.decodeIfPresent(String.self, forKey: .question),
                planVersion: try c.decodeIfPresent(Int.self, forKey: .planVersion),
                elicitation: try? c.decodeIfPresent(ToolElicitationSummary.self, forKey: .elicitation),
                rawInputDigest: parsedDigest.text,
                rawInputDigestInfo: parsedDigest.info
            )
            self = .tool(data)
        case "subagent":
            self = .subagent(
                id: id,
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
            )
        case "session_started":
            self = .sessionStarted(
                id: id,
                sessionId: try c.decodeIfPresent(String.self, forKey: .sessionId) ?? "",
                after: try c.decodeIfPresent(String.self, forKey: .after)
            )
        case "session_message":
            self = .sessionMessage(
                id: id,
                senderId: try c.decodeIfPresent(String.self, forKey: .senderId),
                content: (try? c.decode([UserContent].self, forKey: .content)) ?? []
            )
        case "plan":
            let rawItems = (try? c.decode([PlanItem].self, forKey: .items)) ?? []
            self = .plan(id: id, items: PlanItem.indexed(rawItems))
        case "notice":
            self = .notice(
                id: id,
                severity: try c.decodeIfPresent(String.self, forKey: .severity) ?? "info",
                title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
                description: try c.decodeIfPresent(String.self, forKey: .description),
                cause: try c.decodeIfPresent(String.self, forKey: .cause),
                model: try c.decodeIfPresent(String.self, forKey: .model)
            )
        case "turn_end":
            self = .turnEnd(
                id: id,
                stopReason: try c.decodeIfPresent(String.self, forKey: .stopReason) ?? "end_turn",
                durationMs: try c.decodeIfPresent(Double.self, forKey: .durationMs) ?? 0
            )
        case "compaction":
            self = .compaction(
                id: id,
                status: try c.decodeIfPresent(String.self, forKey: .status) ?? "completed",
                summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
            )
        case "takeover":
            self = .takeover(
                id: id,
                agentId: try c.decodeIfPresent(String.self, forKey: .agentId) ?? "",
                turns: try c.decodeIfPresent(Int.self, forKey: .turns) ?? 0,
                omitted: try c.decodeIfPresent(Int.self, forKey: .omitted) ?? 0,
                carried: try c.decodeIfPresent(String.self, forKey: .carried) ?? "",
                summarize: try c.decodeIfPresent(Bool.self, forKey: .summarize)
            )
        case "git":
            self = .git(try GitEntryPayload(from: decoder))
        case "artifact":
            self = .artifact(try ArtifactEntryPayload(from: decoder))
        case "memory":
            self = .memory(try MemoryWriteEntryPayload(from: decoder))
        case "settings_change":
            self = .settingsChange(try SettingsChangeEntryPayload(from: decoder))
        case "browser_origin":
            self = .browserOrigin(try BrowserOriginEntryPayload(from: decoder))
        case "control_ask":
            self = .controlAsk(try ControlAskEntryPayload(from: decoder))
        case "control_note":
            self = .controlNote(try ControlNoteEntryPayload(from: decoder))
        case "device_access":
            self = .deviceAccess(try DeviceAccessEntryPayload(from: decoder))
        case "surface_access":
            self = .surfaceAccess(try SurfaceAccessEntryPayload(from: decoder))
        case "computer_app":
            self = .computerApp(try ComputerAppEntryPayload(from: decoder))
        case "computer_setup":
            self = .computerSetup(try ComputerSetupEntryPayload(from: decoder))
        case "project_mcp":
            self = .projectMcp(try ProjectMcpEntryPayload(from: decoder))
        case "project_hooks":
            self = .projectHooks(try ProjectHooksEntryPayload(from: decoder))
        case "problem_report":
            self = .problemReport(try ProblemReportEntryPayload(from: decoder))
        case "market_publish":
            self = .marketPublish(try MarketPublishEntryPayload(from: decoder))
        default:
            self = .unknown(id: id, kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let id, let text, let content, let at, let approval, let steered):
            try c.encode("user", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(content.isEmpty ? [UserContent(text: text)] : content, forKey: .content)
            try c.encodeIfPresent(at, forKey: .at)
            if approval { try c.encode(true, forKey: .approval) }
            if steered { try c.encode(true, forKey: .steered) }
        case .agent(let id, let markdown, let streaming, let at, let attachments):
            try c.encode("agent", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(markdown, forKey: .markdown)
            try c.encode(attachments, forKey: .attachments)
            try c.encode(streaming, forKey: .streaming)
            try c.encodeIfPresent(at, forKey: .at)
        case .thought(let id, let markdown, let streaming, let durationMs):
            try c.encode("thought", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(markdown, forKey: .markdown)
            try c.encode(streaming, forKey: .streaming)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
        case .tool(let data):
            try c.encode("tool", forKey: .kind)
            try c.encode(data.id, forKey: .id)
            try c.encode(data.title, forKey: .title)
            try c.encode(data.toolKind, forKey: .toolKind)
            try c.encode(data.status, forKey: .status)
            try c.encode(data.content, forKey: .content)
            if !data.locations.isEmpty { try c.encode(data.locations, forKey: .locations) }
            try c.encodeIfPresent(data.permission, forKey: .permission)
            try c.encodeIfPresent(data.permissionResult, forKey: .permissionResult)
            try c.encodeIfPresent(data.rawInput, forKey: .rawInput)
            if let digestInfo = data.rawInputDigestInfo {
                try c.encode(digestInfo, forKey: .rawInputDigest)
            } else {
                try c.encodeIfPresent(data.rawInputDigest, forKey: .rawInputDigest)
            }
            try c.encodeIfPresent(data.description, forKey: .description)
            try c.encodeIfPresent(data.label, forKey: .label)
            try c.encodeIfPresent(data.question, forKey: .question)
            try c.encodeIfPresent(data.planVersion, forKey: .planVersion)
            try c.encodeIfPresent(data.elicitation, forKey: .elicitation)
        case .subagent(let id, let sessionId):
            try c.encode("subagent", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
        case .sessionStarted(let id, let sessionId, let after):
            try c.encode("session_started", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(sessionId, forKey: .sessionId)
            try c.encodeIfPresent(after, forKey: .after)
        case .sessionMessage(let id, let senderId, let content):
            try c.encode("session_message", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(senderId, forKey: .senderId)
            try c.encode(content, forKey: .content)
        case .plan(let id, let items):
            try c.encode("plan", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(items, forKey: .items)
        case .notice(let id, let severity, let title, let description, let cause, let model):
            try c.encode("notice", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(severity, forKey: .severity)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(description, forKey: .description)
            try c.encodeIfPresent(cause, forKey: .cause)
            try c.encodeIfPresent(model, forKey: .model)
        case .turnEnd(let id, let stopReason, let durationMs):
            try c.encode("turn_end", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(stopReason, forKey: .stopReason)
            try c.encode(durationMs, forKey: .durationMs)
        case .compaction(let id, let status, let summary):
            try c.encode("compaction", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(status, forKey: .status)
            try c.encode(summary, forKey: .summary)
        case .takeover(let id, let agentId, let turns, let omitted, let carried, let summarize):
            try c.encode("takeover", forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(agentId, forKey: .agentId)
            try c.encode(turns, forKey: .turns)
            try c.encode(omitted, forKey: .omitted)
            try c.encode(carried, forKey: .carried)
            try c.encodeIfPresent(summarize, forKey: .summarize)
        case .git(let p):
            try c.encode("git", forKey: .kind)
            try p.encode(to: encoder)
        case .artifact(let p):
            try c.encode("artifact", forKey: .kind)
            try p.encode(to: encoder)
        case .memory(let p):
            try c.encode("memory", forKey: .kind)
            try p.encode(to: encoder)
        case .settingsChange(let p):
            try c.encode("settings_change", forKey: .kind)
            try p.encode(to: encoder)
        case .browserOrigin(let p):
            try c.encode("browser_origin", forKey: .kind)
            try p.encode(to: encoder)
        case .controlAsk(let p):
            try c.encode("control_ask", forKey: .kind)
            try p.encode(to: encoder)
        case .controlNote(let p):
            try c.encode("control_note", forKey: .kind)
            try p.encode(to: encoder)
        case .deviceAccess(let p):
            try c.encode("device_access", forKey: .kind)
            try p.encode(to: encoder)
        case .surfaceAccess(let p):
            try c.encode("surface_access", forKey: .kind)
            try p.encode(to: encoder)
        case .computerApp(let p):
            try c.encode("computer_app", forKey: .kind)
            try p.encode(to: encoder)
        case .computerSetup(let p):
            try c.encode("computer_setup", forKey: .kind)
            try p.encode(to: encoder)
        case .projectMcp(let p):
            try c.encode("project_mcp", forKey: .kind)
            try p.encode(to: encoder)
        case .projectHooks(let p):
            try c.encode("project_hooks", forKey: .kind)
            try p.encode(to: encoder)
        case .problemReport(let p):
            try c.encode("problem_report", forKey: .kind)
            try p.encode(to: encoder)
        case .marketPublish(let p):
            try c.encode("market_publish", forKey: .kind)
            try p.encode(to: encoder)
        case .unknown(let id, let kind):
            try c.encode(kind, forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public let session: SessionView
    public let entries: [ThreadEntry]
    public let seq: Int
    public let older: Int?
    public let plan: ThreadEntry?
    /// What `entries` carry beyond their `ThreadEntry` cases, by entry id.
    public let entryExtras: [String: ThreadEntryExtras]

    enum CodingKeys: String, CodingKey {
        case session, entries, seq, older, plan
    }

    public init(
        session: SessionView,
        entries: [ThreadEntry],
        seq: Int,
        older: Int? = nil,
        plan: ThreadEntry? = nil,
        entryExtras: [String: ThreadEntryExtras] = [:]
    ) {
        self.session = session
        self.entries = entries
        self.seq = seq
        self.older = older
        self.plan = plan
        self.entryExtras = entryExtras
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try c.decode(SessionView.self, forKey: .session)
        let read = try c.decode([ThreadEntryWithExtras].self, forKey: .entries)
        self.entries = read.map(\.entry)
        self.seq = try c.decode(Int.self, forKey: .seq)
        self.older = try c.decodeIfPresent(Int.self, forKey: .older)
        self.plan = try c.decodeIfPresent(ThreadEntry.self, forKey: .plan)
        self.entryExtras = ThreadEntryWithExtras.extrasById(read)
    }
}

public enum ThreadPatch: Codable, Sendable, Equatable {
    case entryAdd(ThreadEntry)
    case entryAppendText(id: String, text: String)
    case entryUpdate(id: String, changes: [String: JSONValue])
    case sessionUpdate(changes: [String: JSONValue])
    case threadReset
    /// The entry and every entry after it leave, as an edit from a sent message does.
    case threadTruncate(id: String)
    case unknown(String)

    enum CodingKeys: String, CodingKey {
        case op, entry, id, text, changes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "entry.add":
            self = .entryAdd(try c.decode(ThreadEntry.self, forKey: .entry))
        case "entry.appendText":
            self = .entryAppendText(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text)
            )
        case "entry.update":
            self = .entryUpdate(
                id: try c.decode(String.self, forKey: .id),
                changes: try c.decode([String: JSONValue].self, forKey: .changes)
            )
        case "session.update":
            self = .sessionUpdate(changes: try c.decode([String: JSONValue].self, forKey: .changes))
        case "thread.reset":
            self = .threadReset
        case "thread.truncate":
            self = .threadTruncate(id: try c.decode(String.self, forKey: .id))
        default:
            // Preserve forward compatibility so a new upstream patch op never drops an entire PatchBatch.
            self = .unknown(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .entryAdd(let entry):
            try c.encode("entry.add", forKey: .op)
            try c.encode(entry, forKey: .entry)
        case .entryAppendText(let id, let text):
            try c.encode("entry.appendText", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
        case .entryUpdate(let id, let changes):
            try c.encode("entry.update", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(changes, forKey: .changes)
        case .sessionUpdate(let changes):
            try c.encode("session.update", forKey: .op)
            try c.encode(changes, forKey: .changes)
        case .threadReset:
            try c.encode("thread.reset", forKey: .op)
        case .threadTruncate(let id):
            try c.encode("thread.truncate", forKey: .op)
            try c.encode(id, forKey: .id)
        case .unknown(let op):
            try c.encode(op, forKey: .op)
        }
    }
}

extension ThreadPatch {
    /// Builds a patch from an already parsed value. `entry` holds the added entry, decoded by the caller
    /// in one pass for the whole batch; nil means the patch has not the shape `init(from:)` requires.
    fileprivate init?(jsonValue: JSONValue, entry: ThreadEntry?) {
        guard let obj = jsonValue.objectValue, let op = obj["op"]?.stringValue else { return nil }
        switch op {
        case "entry.add":
            guard let entry else { return nil }
            self = .entryAdd(entry)
        case "entry.appendText":
            guard let id = obj["id"]?.stringValue, let text = obj["text"]?.stringValue else { return nil }
            self = .entryAppendText(id: id, text: text)
        case "entry.update":
            guard let id = obj["id"]?.stringValue, let changes = obj["changes"]?.objectValue else { return nil }
            self = .entryUpdate(id: id, changes: changes)
        case "session.update":
            guard let changes = obj["changes"]?.objectValue else { return nil }
            self = .sessionUpdate(changes: changes)
        case "thread.reset":
            self = .threadReset
        case "thread.truncate":
            guard let id = obj["id"]?.stringValue else { return nil }
            self = .threadTruncate(id: id)
        default:
            self = .unknown(op)
        }
    }
}

public struct PatchBatch: Codable, Sendable, Equatable {
    public let sessionId: String
    public let seq: Int
    public let from: Int?
    public let patches: [ThreadPatch]
    /// Set on a batch for `sessionId` that arrived but could not be read: it carries no patches, and
    /// `ThreadReplica.apply` refuses it so the caller reloads the session's snapshot.
    public private(set) var requiresResync = false
    /// What the added entries carry beyond their `ThreadEntry` cases, by entry id.
    public internal(set) var entryExtras: [String: ThreadEntryExtras] = [:]

    enum CodingKeys: String, CodingKey {
        case sessionId, seq, from, patches
    }

    public init(sessionId: String, seq: Int, from: Int? = nil, patches: [ThreadPatch]) {
        self.sessionId = sessionId
        self.seq = seq
        self.from = from
        self.patches = patches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sessionId = try c.decode(String.self, forKey: .sessionId)
        let seq = try c.decode(Int.self, forKey: .seq)
        let from = try c.decodeIfPresent(Int.self, forKey: .from)
        let read = try c.decode([ThreadPatchWithExtras].self, forKey: .patches)
        self.init(sessionId: sessionId, seq: seq, from: from, patches: read.map(\.patch))
        self.entryExtras = ThreadPatchWithExtras.extrasById(read)
    }

    /// A batch that only tells the replica of `sessionId` to resync from a fresh snapshot. Its `seq` is
    /// `Int.max`, so a caller that compares seqs before `apply` sees a gap rather than a replay.
    public static func resyncRequired(sessionId: String) -> PatchBatch {
        var batch = PatchBatch(sessionId: sessionId, seq: Int.max, patches: [])
        batch.requiresResync = true
        return batch
    }

    /// Reads a batch from an already parsed `{sessionId, seq, from?, patches}` value with the rules of
    /// `init(from:)`, decoding only the added entries through Codable.
    init?(jsonValue: JSONValue) {
        guard let obj = jsonValue.objectValue,
              let sessionId = obj["sessionId"]?.stringValue,
              let seq = obj["seq"].flatMap(Self.exactInt),
              let rawPatches = obj["patches"]?.arrayValue
        else { return nil }
        var from: Int?
        if let rawFrom = obj["from"], rawFrom != .null {
            guard let value = Self.exactInt(rawFrom) else { return nil }
            from = value
        }
        var addedValues: [JSONValue] = []
        for raw in rawPatches {
            guard let patch = raw.objectValue else { return nil }
            if patch["op"] == .string("entry.add") {
                guard let entry = patch["entry"] else { return nil }
                addedValues.append(entry)
            }
        }
        var added: [ThreadEntry] = []
        if !addedValues.isEmpty {
            guard let decoded = try? JSONValue.array(addedValues).decode([ThreadEntry].self) else { return nil }
            added = decoded
        }
        var patches: [ThreadPatch] = []
        patches.reserveCapacity(rawPatches.count)
        var nextAdded = 0
        for raw in rawPatches {
            var entry: ThreadEntry?
            if raw.objectValue?["op"] == .string("entry.add") {
                entry = added[nextAdded]
                nextAdded += 1
            }
            guard let patch = ThreadPatch(jsonValue: raw, entry: entry) else { return nil }
            patches.append(patch)
        }
        self.init(sessionId: sessionId, seq: seq, from: from, patches: patches)
        self.entryExtras = ThreadEntryExtras.collect(fromEntries: addedValues)
    }

    private static func exactInt(_ value: JSONValue) -> Int? {
        guard let number = value.doubleValue,
              number.truncatingRemainder(dividingBy: 1) == 0,
              number >= -9_007_199_254_740_991,
              number <= 9_007_199_254_740_991
        else { return nil }
        return Int(number)
    }
}

/// Incremental normalized thread replica mirroring src/shared/thread.ts.
public struct ThreadReplica: Sendable, Equatable {
    public var session: SessionView
    public var seq: Int
    public var older: Int?
    public var snapshotPlan: [PlanItem]?
    public var order: [String]
    public var byId: [String: ThreadEntry]
    /// What the entries carry beyond their `ThreadEntry` cases, by entry id; see `ThreadEntryExtras`.
    public internal(set) var entryExtras: [String: ThreadEntryExtras] = [:]

    public init(snapshot: SessionSnapshot) {
        self.session = snapshot.session
        self.seq = snapshot.seq
        self.older = snapshot.older
        if case .plan(_, let items)? = snapshot.plan, !items.isEmpty {
            self.snapshotPlan = PlanItem.indexed(items)
        } else {
            self.snapshotPlan = nil
        }
        var order: [String] = []
        var byId: [String: ThreadEntry] = [:]
        for rawEntry in snapshot.entries {
            let entry = Self.normalizedEntry(rawEntry)
            if byId[entry.id] == nil { order.append(entry.id) }
            byId[entry.id] = entry
        }
        self.order = order
        self.byId = byId
        self.entryExtras = snapshot.entryExtras
    }

    public var entries: [ThreadEntry] {
        order.compactMap { byId[$0] }
    }

    /// Prepends an older page returned by `sessions.page`, deduplicating any overlapping entry IDs.
    public mutating func prependOlderPage(_ page: OlderPageInfo) {
        var prependedOrder: [String] = []
        prependedOrder.reserveCapacity(page.entries.count)
        for rawEntry in page.entries {
            let entry = Self.normalizedEntry(rawEntry)
            if byId[entry.id] == nil {
                prependedOrder.append(entry.id)
                byId[entry.id] = entry
                entryExtras[entry.id] = page.entryExtras[entry.id]
            }
        }
        if !prependedOrder.isEmpty {
            order.insert(contentsOf: prependedOrder, at: 0)
        }
        older = page.older
    }

    /// Replaces an existing digested entry with the full entry returned by `sessions.entry`,
    /// keeping its position in `order` and leaving `seq` unchanged.
    @discardableResult
    public mutating func replaceHydratedEntry(_ entry: ThreadEntry) -> Bool {
        guard byId[entry.id] != nil else { return false }
        byId[entry.id] = Self.normalizedEntry(entry)
        return true
    }

    /// Pending tool permission requests currently awaiting user decision in this thread.
    public var pendingTools: [ToolEntryData] {
        entries.compactMap { entry in
            if case .tool(let data) = entry, data.permission != nil { return data }
            return nil
        }
    }

    /// Applies a patch batch if sequential. Returns false if a gap requires snapshot resync.
    @discardableResult
    public mutating func apply(_ batch: PatchBatch) -> Bool {
        if batch.requiresResync { return false }
        let startSeq = batch.from ?? batch.seq
        if batch.seq <= seq { return true }
        if startSeq > seq + 1 { return false }

        let hasTruncate = batch.patches.contains {
            if case .threadTruncate = $0 { return true }
            return false
        }
        if hasTruncate {
            var next = self
            for patch in batch.patches {
                if case .threadTruncate(let id) = patch, next.byId[id] == nil {
                    // The entry is on an older page this replica lacks, so only a snapshot sets it right.
                    return false
                }
                next.trackEntryExtras(patch, added: batch.entryExtras)
                next.applyPatch(patch)
            }
            next.seq = batch.seq
            self = next
            return true
        }

        // Mutate in place when no truncate can abort the batch so `byId` storage stays uniquely
        // referenced and `entry.appendText` appends in O(1) without copying the full string.
        var index = 0
        let count = batch.patches.count
        while index < count {
            let patch = batch.patches[index]
            if case .entryAppendText(let id, let firstText) = patch {
                // Coalesce consecutive text deltas for the same entry so `byId` is updated once.
                var nextIndex = index + 1
                if nextIndex < count, case .entryAppendText(let nextId, _) = batch.patches[nextIndex], nextId == id {
                    var combined = firstText
                    while nextIndex < count, case .entryAppendText(let runId, let runText) = batch.patches[nextIndex], runId == id {
                        combined.append(runText)
                        nextIndex += 1
                    }
                    applyAppendText(id: id, text: combined)
                    index = nextIndex
                    continue
                }
                applyAppendText(id: id, text: firstText)
                index += 1
                continue
            }
            trackEntryExtras(patch, added: batch.entryExtras)
            applyPatch(patch)
            index += 1
        }
        seq = batch.seq
        return true
    }

    private static func normalizedEntry(_ entry: ThreadEntry) -> ThreadEntry {
        if case .plan(let id, let items) = entry {
            return .plan(id: id, items: PlanItem.indexed(items))
        }
        return entry
    }

    /// Merges `entry.update` changes into any entry like `{...entry, ...changes}` in src/shared/thread.ts,
    /// through the entry's JSON form; a null change clears the field, and `id` and `kind` never change.
    private static func mergeStructuredEntry(_ entry: ThreadEntry, changes: [String: JSONValue]) -> ThreadEntry? {
        guard let encoded = try? JSONEncoder().encode(entry),
              case .object(var obj)? = try? JSONValue(jsonData: encoded)
        else { return nil }
        for (key, value) in changes where key != "id" && key != "kind" {
            if value == .null {
                obj.removeValue(forKey: key)
            } else {
                obj[key] = value
            }
        }
        return try? JSONValue.object(obj).decode(ThreadEntry.self)
    }

    /// A changed field the entry keeps as an optional: null clears it, a value of another type is ignored.
    private static func optionalChange<T>(_ change: JSONValue?, _ current: T?, _ read: (JSONValue) -> T?) -> T? {
        guard let change else { return current }
        if change == .null { return nil }
        return read(change) ?? current
    }

    /// A changed field the entry always has: null resets it to the default `init(from:)` gives a missing one.
    private static func requiredChange<T>(_ change: JSONValue?, _ current: T, default fallback: T, _ read: (JSONValue) -> T?) -> T {
        guard let change else { return current }
        if change == .null { return fallback }
        return read(change) ?? current
    }

    private mutating func applyAppendText(id: String, text: String) {
        guard let existing = byId.removeValue(forKey: id) else { return }
        switch consume existing {
        case .agent(let eid, var md, let streaming, let at, let attachments):
            md.append(text)
            byId[id] = .agent(id: eid, markdown: md, streaming: streaming, at: at, attachments: attachments)
        case .thought(let eid, var md, let streaming, let dur):
            md.append(text)
            byId[id] = .thought(id: eid, markdown: md, streaming: streaming, durationMs: dur)
        case .compaction(let eid, let status, var summary):
            summary.append(text)
            byId[id] = .compaction(id: eid, status: status, summary: summary)
        case let other:
            byId[id] = other
        }
    }

    private mutating func applyPatch(_ patch: ThreadPatch) {
        switch patch {
        case .threadReset:
            order.removeAll()
            byId.removeAll()
            older = nil
            snapshotPlan = nil

        case .threadTruncate(let id):
            guard let at = order.firstIndex(of: id) else { return }
            for dropped in order[at...] { byId.removeValue(forKey: dropped) }
            order.removeSubrange(at...)

        case .entryAdd(let rawEntry):
            let entry = Self.normalizedEntry(rawEntry)
            if byId[entry.id] == nil { order.append(entry.id) }
            byId[entry.id] = entry

        case .entryAppendText(let id, let text):
            applyAppendText(id: id, text: text)

        case .entryUpdate(let id, let changes):
            guard let existing = byId[id] else { return }
            // Agent, thought and tool entries change many times a turn, so they merge field by field;
            // every other kind merges through its JSON form.
            switch existing {
            case .agent(let eid, let md, let streaming, let at, let attachments):
                byId[id] = .agent(
                    id: eid,
                    markdown: Self.requiredChange(changes["markdown"], md, default: "") { $0.stringValue },
                    streaming: Self.requiredChange(changes["streaming"], streaming, default: false) { $0.boolValue },
                    at: Self.optionalChange(changes["at"], at) { $0.doubleValue },
                    attachments: Self.requiredChange(changes["attachments"], attachments, default: []) {
                        try? $0.decode([ContentRef].self)
                    }
                )
            case .thought(let eid, let md, let streaming, let dur):
                byId[id] = .thought(
                    id: eid,
                    markdown: Self.requiredChange(changes["markdown"], md, default: "") { $0.stringValue },
                    streaming: Self.requiredChange(changes["streaming"], streaming, default: false) { $0.boolValue },
                    durationMs: Self.optionalChange(changes["durationMs"], dur) { $0.doubleValue }
                )
            case .tool(var data):
                data.title = Self.requiredChange(changes["title"], data.title, default: "Tool") { $0.stringValue }
                data.toolKind = Self.requiredChange(changes["toolKind"], data.toolKind, default: "other") { $0.stringValue }
                data.status = Self.requiredChange(changes["status"], data.status, default: "pending") { $0.stringValue }
                data.rawInput = Self.optionalChange(changes["rawInput"], data.rawInput) { $0.stringValue }
                if let ridVal = changes["rawInputDigest"] {
                    let parsed = ToolEntryData.parseRawInputDigest(ridVal)
                    data.rawInputDigest = parsed.text
                    data.rawInputDigestInfo = parsed.info
                }
                data.description = Self.optionalChange(changes["description"], data.description) { $0.stringValue }
                data.label = Self.optionalChange(changes["label"], data.label) { $0.stringValue }
                data.question = Self.optionalChange(changes["question"], data.question) { $0.stringValue }
                data.planVersion = Self.optionalChange(changes["planVersion"], data.planVersion) { value in
                    value.doubleValue.flatMap { $0.truncatingRemainder(dividingBy: 1) == 0 ? Int(exactly: $0) : nil }
                }
                data.elicitation = Self.optionalChange(changes["elicitation"], data.elicitation) {
                    try? $0.decode(ToolElicitationSummary.self)
                }
                data.content = Self.requiredChange(changes["content"], data.content, default: []) {
                    try? $0.decode([ToolContentItem].self)
                }
                data.locations = Self.requiredChange(changes["locations"], data.locations, default: []) {
                    try? $0.decode([ToolLocation].self)
                }
                data.permission = Self.optionalChange(changes["permission"], data.permission) {
                    try? $0.decode(PendingPermission.self)
                }
                if let resVal = changes["permissionResult"] {
                    data.permissionResult = resVal == .null ? nil : resVal
                }
                byId[id] = .tool(data)
            case .unknown:
                break
            default:
                if let merged = Self.mergeStructuredEntry(existing, changes: changes) {
                    byId[id] = Self.normalizedEntry(merged)
                }
            }

        case .sessionUpdate(let changes):
            if let nextAgent = changes["agentId"]?.stringValue {
                session.agentId = nextAgent
            }
            if let statusRaw = changes["status"]?.stringValue,
               let status = SessionStatus(rawValue: statusRaw) {
                session.status = status
            }
            if let titleVal = changes["title"] {
                session.title = titleVal == .null ? nil : titleVal.stringValue
            }
            if let usageVal = changes["usage"] {
                session.usage = usageVal == .null ? nil : (try? usageVal.decode(SessionUsage.self))
            }
            if let turnStartedVal = changes["turnStartedAt"] {
                session.turnStartedAt = turnStartedVal == .null ? nil : turnStartedVal.doubleValue
            }
            if let turnStartUsedVal = changes["turnStartUsed"] {
                session.turnStartUsed = turnStartUsedVal == .null ? nil : turnStartUsedVal.doubleValue
            }
            if let speedVal = changes["speed"] {
                session.speed = speedVal == .null ? nil : (try? speedVal.decode(OutputSpeedInfo.self))
            }
            if let lastReqVal = changes["lastRequest"] {
                session.lastRequest = lastReqVal == .null ? nil : (try? lastReqVal.decode(LastRequestInfo.self))
            }
            if let configVal = changes["config"],
               let decoded = try? configVal.decode([ConfigOption].self) {
                session.config = decoded
            }
            if let cmdsVal = changes["commands"],
               let decoded = try? cmdsVal.decode([SlashCommand].self) {
                session.commands = decoded
            }
            if let queueVal = changes["queue"],
               let decoded = try? queueVal.decode([QueuedPrompt].self) {
                session.queue = decoded
            }
            if let qpVal = changes["queuePaused"]?.boolValue {
                session.queuePaused = qpVal
            }
            if let bgVal = changes["background"] {
                if bgVal == .null {
                    session.background = []
                } else if let decoded = try? bgVal.decode([BackgroundTaskInfo].self) {
                    session.background = decoded
                }
            }
            if let subVal = changes["subagent"] {
                session.subagent = subVal == .null ? nil : (try? subVal.decode(SubagentInfoView.self))
            }
            if let heldVal = changes["heldOutside"] {
                session.heldOutside = heldVal == .null ? nil : heldVal.boolValue
            }
            if let suggestionVal = changes["suggestion"] {
                session.suggestion = suggestionVal == .null ? nil : suggestionVal.stringValue
            }
            // Null once the session moves to an agent on this computer.
            if let modelHostVal = changes["modelHost"] {
                session.modelHost = modelHostVal == .null ? nil : (try? modelHostVal.decode(ModelHostRef.self))
            }
            session.applyRewindChanges(changes)
            if let errVal = changes["error"] {
                session.error = errVal == .null ? nil : (try? errVal.decode(SessionErrorInfo.self))
            }
            if let updated = changes["updatedAt"]?.doubleValue {
                session.updatedAt = updated
            }

        case .unknown:
            break
        }
    }
}

// MARK: - Agents, Projects & Host Events

public struct PlanLimitInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(window)-\(label)" }
    public let window: String
    public let label: String
    public let usedPercent: Double?
    public let resetsAt: Double?
    public let state: String
    public let observedAt: Double?
    public let models: [String]?
    /// True while extra usage covers this used-up window; absent from older hosts.
    public let extraUsage: Bool?

    public init(
        window: String,
        label: String,
        usedPercent: Double?,
        resetsAt: Double?,
        state: String,
        observedAt: Double? = nil,
        models: [String]? = nil,
        extraUsage: Bool? = nil
    ) {
        self.window = window
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.state = state
        self.observedAt = observedAt
        self.models = models
        self.extraUsage = extraUsage
    }
}

public struct AgentAccountInfo: Codable, Sendable, Equatable {
    public let kind: String
    public let label: String
    public let email: String?
    public let tier: String?

    public init(kind: String, label: String, email: String?, tier: String? = nil) {
        self.kind = kind
        self.label = label
        self.email = email
        self.tier = tier
    }
}

public struct AgentCapabilitiesInfo: Codable, Sendable, Equatable {
    public let loadSession: Bool
    public let listSessions: Bool
    public let resumeSession: Bool
    public let closeSession: Bool
    public let deleteSession: Bool
    public let forkSession: Bool
    public let forkAtMessage: Bool
    public let additionalDirectories: Bool
    public let steering: Bool
    /// Cuts a session's conversation before a turn, for an edit from a sent message.
    public let rewind: Bool
    /// Rewinding also reverts files changed since the edited message.
    public let rewindFiles: Bool

    public init(
        loadSession: Bool = false,
        listSessions: Bool = false,
        resumeSession: Bool = false,
        closeSession: Bool = false,
        deleteSession: Bool = false,
        forkSession: Bool = false,
        forkAtMessage: Bool = false,
        additionalDirectories: Bool = false,
        steering: Bool = false,
        rewind: Bool = false,
        rewindFiles: Bool = false
    ) {
        self.loadSession = loadSession
        self.listSessions = listSessions
        self.resumeSession = resumeSession
        self.closeSession = closeSession
        self.deleteSession = deleteSession
        self.forkSession = forkSession
        self.forkAtMessage = forkAtMessage
        self.additionalDirectories = additionalDirectories
        self.steering = steering
        self.rewind = rewind
        self.rewindFiles = rewindFiles
    }

    enum CodingKeys: String, CodingKey {
        case loadSession, listSessions, resumeSession, closeSession, deleteSession
        case forkSession, forkAtMessage, additionalDirectories, steering, rewind, rewindFiles
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.loadSession = try c.decodeIfPresent(Bool.self, forKey: .loadSession) ?? false
        self.listSessions = try c.decodeIfPresent(Bool.self, forKey: .listSessions) ?? false
        self.resumeSession = try c.decodeIfPresent(Bool.self, forKey: .resumeSession) ?? false
        self.closeSession = try c.decodeIfPresent(Bool.self, forKey: .closeSession) ?? false
        self.deleteSession = try c.decodeIfPresent(Bool.self, forKey: .deleteSession) ?? false
        self.forkSession = try c.decodeIfPresent(Bool.self, forKey: .forkSession) ?? false
        self.forkAtMessage = try c.decodeIfPresent(Bool.self, forKey: .forkAtMessage) ?? false
        self.additionalDirectories = (try? c.decodeIfPresent(Bool.self, forKey: .additionalDirectories)) ?? false
        self.steering = try c.decodeIfPresent(Bool.self, forKey: .steering) ?? false
        self.rewind = (try? c.decodeIfPresent(Bool.self, forKey: .rewind)) ?? false
        self.rewindFiles = (try? c.decodeIfPresent(Bool.self, forKey: .rewindFiles)) ?? false
    }
}

public struct AgentStatusInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let harnessId: String?
    public let harnessName: String?
    public let isDefault: Bool?
    public let state: String
    public let registered: Bool?
    public let uninstalled: Bool?
    public let disabled: Bool?
    public let hidden: Bool?
    public let color: String?
    public let version: String?
    public let detail: String?
    public let signIn: String?
    public let canLogout: Bool?
    public let apiKey: AgentApiKeyInfo?
    public let authMethods: [AgentAuthMethodInfo]?
    public let binaryPath: String?
    public let binaryOverride: String?
    public let binaryCommand: String?
    public let launchCommand: String?
    public let installUrl: String?
    public let update: AgentUpdateInfo?
    public let cli: AgentCliInfo?
    public let task: AgentTaskInfo?
    public let configDir: AgentConfigDirInfo?
    public let sartoServer: AgentSartoServerInfo?
    public let versionWarning: AgentVersionWarningInfo?
    public let account: AgentAccountInfo?
    public let limits: [PlanLimitInfo]?
    public let capabilities: AgentCapabilitiesInfo?
    /// Why its harness cannot run and how it installs, read from the status's own fields.
    public let availability: AgentAvailabilityInfo

    /// Compatibility alias matching Sarto's wire field `limits`.
    public var planLimits: [PlanLimitInfo]? { limits }

    enum CodingKeys: String, CodingKey {
        case id, name, harnessId, harnessName, isDefault, state, registered, uninstalled, disabled, hidden, color
        case version, detail, signIn, canLogout, apiKey, authMethods
        case binaryPath, binaryOverride, binaryCommand, launchCommand, installUrl
        case update, cli, task, configDir, sartoServer, versionWarning
        case account, limits, planLimits, capabilities
    }

    public init(
        id: String,
        name: String,
        harnessId: String? = nil,
        harnessName: String? = nil,
        isDefault: Bool? = nil,
        state: String,
        registered: Bool? = true,
        uninstalled: Bool? = nil,
        disabled: Bool? = nil,
        hidden: Bool? = nil,
        color: String? = nil,
        version: String? = nil,
        detail: String? = nil,
        signIn: String? = nil,
        canLogout: Bool? = nil,
        apiKey: AgentApiKeyInfo? = nil,
        authMethods: [AgentAuthMethodInfo]? = nil,
        binaryPath: String? = nil,
        binaryOverride: String? = nil,
        binaryCommand: String? = nil,
        launchCommand: String? = nil,
        installUrl: String? = nil,
        update: AgentUpdateInfo? = nil,
        cli: AgentCliInfo? = nil,
        task: AgentTaskInfo? = nil,
        configDir: AgentConfigDirInfo? = nil,
        sartoServer: AgentSartoServerInfo? = nil,
        versionWarning: AgentVersionWarningInfo? = nil,
        account: AgentAccountInfo? = nil,
        planLimits: [PlanLimitInfo]? = nil,
        capabilities: AgentCapabilitiesInfo? = nil,
        availability: AgentAvailabilityInfo = AgentAvailabilityInfo()
    ) {
        self.id = id
        self.name = name
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.isDefault = isDefault
        self.state = state
        self.registered = registered
        self.uninstalled = uninstalled
        self.disabled = disabled
        self.hidden = hidden
        self.color = color
        self.version = version
        self.detail = detail
        self.signIn = signIn
        self.canLogout = canLogout
        self.apiKey = apiKey
        self.authMethods = authMethods
        self.binaryPath = binaryPath
        self.binaryOverride = binaryOverride
        self.binaryCommand = binaryCommand
        self.launchCommand = launchCommand
        self.installUrl = installUrl
        self.update = update
        self.cli = cli
        self.task = task
        self.configDir = configDir
        self.sartoServer = sartoServer
        self.versionWarning = versionWarning
        self.account = account
        self.limits = planLimits
        self.capabilities = capabilities
        self.availability = availability
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.harnessId = try c.decodeIfPresent(String.self, forKey: .harnessId)
        self.harnessName = try c.decodeIfPresent(String.self, forKey: .harnessName)
        self.isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault)
        self.state = try c.decode(String.self, forKey: .state)
        self.registered = try c.decodeIfPresent(Bool.self, forKey: .registered)
        self.uninstalled = try c.decodeIfPresent(Bool.self, forKey: .uninstalled)
        self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled)
        self.hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
        self.color = try c.decodeIfPresent(String.self, forKey: .color)
        self.version = try c.decodeIfPresent(String.self, forKey: .version)
        self.detail = try c.decodeIfPresent(String.self, forKey: .detail)
        self.signIn = try c.decodeIfPresent(String.self, forKey: .signIn)
        self.canLogout = try c.decodeIfPresent(Bool.self, forKey: .canLogout)
        self.apiKey = try? c.decodeIfPresent(AgentApiKeyInfo.self, forKey: .apiKey)
        self.authMethods = try? c.decodeIfPresent([AgentAuthMethodInfo].self, forKey: .authMethods)
        self.binaryPath = try c.decodeIfPresent(String.self, forKey: .binaryPath)
        self.binaryOverride = try c.decodeIfPresent(String.self, forKey: .binaryOverride)
        self.binaryCommand = try c.decodeIfPresent(String.self, forKey: .binaryCommand)
        self.launchCommand = try c.decodeIfPresent(String.self, forKey: .launchCommand)
        self.installUrl = try c.decodeIfPresent(String.self, forKey: .installUrl)
        self.update = try? c.decodeIfPresent(AgentUpdateInfo.self, forKey: .update)
        self.cli = try? c.decodeIfPresent(AgentCliInfo.self, forKey: .cli)
        self.task = try? c.decodeIfPresent(AgentTaskInfo.self, forKey: .task)
        self.configDir = try? c.decodeIfPresent(AgentConfigDirInfo.self, forKey: .configDir)
        self.sartoServer = try? c.decodeIfPresent(AgentSartoServerInfo.self, forKey: .sartoServer)
        self.versionWarning = try? c.decodeIfPresent(AgentVersionWarningInfo.self, forKey: .versionWarning)
        self.account = try c.decodeIfPresent(AgentAccountInfo.self, forKey: .account)
        let wireLimits = try c.decodeIfPresent([PlanLimitInfo].self, forKey: .limits)
        let legacyLimits = try c.decodeIfPresent([PlanLimitInfo].self, forKey: .planLimits)
        self.limits = wireLimits ?? legacyLimits
        self.capabilities = try? c.decodeIfPresent(AgentCapabilitiesInfo.self, forKey: .capabilities)
        self.availability = AgentAvailabilityInfo(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(harnessId, forKey: .harnessId)
        try c.encodeIfPresent(harnessName, forKey: .harnessName)
        try c.encodeIfPresent(isDefault, forKey: .isDefault)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(registered, forKey: .registered)
        try c.encodeIfPresent(uninstalled, forKey: .uninstalled)
        try c.encodeIfPresent(disabled, forKey: .disabled)
        try c.encodeIfPresent(hidden, forKey: .hidden)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(signIn, forKey: .signIn)
        try c.encodeIfPresent(canLogout, forKey: .canLogout)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(authMethods, forKey: .authMethods)
        try c.encodeIfPresent(binaryPath, forKey: .binaryPath)
        try c.encodeIfPresent(binaryOverride, forKey: .binaryOverride)
        try c.encodeIfPresent(binaryCommand, forKey: .binaryCommand)
        try c.encodeIfPresent(launchCommand, forKey: .launchCommand)
        try c.encodeIfPresent(installUrl, forKey: .installUrl)
        try c.encodeIfPresent(update, forKey: .update)
        try c.encodeIfPresent(cli, forKey: .cli)
        try c.encodeIfPresent(task, forKey: .task)
        try c.encodeIfPresent(configDir, forKey: .configDir)
        try c.encodeIfPresent(sartoServer, forKey: .sartoServer)
        try c.encodeIfPresent(versionWarning, forKey: .versionWarning)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encodeIfPresent(limits, forKey: .limits)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try availability.encode(to: encoder)
    }
}

public struct ProjectInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let missing: Bool?
    public let lastOpenedAt: Double?
    public let pinnedAt: Double?
    public let order: Double?
    public let pinned: Bool?

    public var isPinned: Bool {
        pinnedAt != nil || pinned == true
    }

    public var isMissing: Bool {
        missing == true
    }

    public init(
        path: String,
        name: String,
        missing: Bool? = nil,
        lastOpenedAt: Double? = nil,
        pinnedAt: Double? = nil,
        order: Double? = nil,
        pinned: Bool? = nil
    ) {
        self.path = path
        self.name = name
        self.missing = missing
        self.lastOpenedAt = lastOpenedAt
        self.pinnedAt = pinnedAt
        self.order = order
        self.pinned = pinned
    }
}

public struct NoProjectInfo: Codable, Sendable, Equatable {
    public let pinnedAt: Double?

    public init(pinnedAt: Double? = nil) {
        self.pinnedAt = pinnedAt
    }
}

public enum HostEvent: Sendable, Equatable {
    case sessionSummary(SessionSummary)
    case sessionPatches(PatchBatch)
    case sessionRemoved(sessionId: String)
    case agentStatus(AgentStatusInfo)
    case agentOptions(AgentOptionsInfo)
    case agentSignInLink(agentId: String, url: String)
    case projectsChanged([ProjectInfo], noProject: NoProjectInfo?)
    /// To the ports watching the project's files, by the path each named it (`files.changed`).
    case filesChanged(projectPath: String)
    case pairing(codeId: Int, state: JSONValue)
    case syncUpdated(SartoSyncStatusInfo)
    case syncUsageUpdated(ownDeviceId: String, records: [SyncedUsageRecordInfo])
    case accountUpdated(CloudAccountStatusInfo)
    case browserCall(BrowserDeviceCall)
    case browserOriginDecided(sessionId: String, requestId: Int, decision: String)
    case browserTurnEnded(sessionId: String)
    case browserAskAnswered(sessionId: String, outcome: String)
    case settingsOpen(section: String, item: String?, row: String)
    case memoryChanged
    case marketKeysChanged
    /// The host's usage figures changed; a view showing them reads the overview again.
    case usageChanged
    case appUpdateState(AppUpdateStatusInfo)
    case appUpdateCommand(action: String)
    case marketConnectionChanged(serverId: String, connection: MarketConnectionInfo, loginId: String?, error: String?)
    case deviceEvent(DeviceEvent)
    /// The local daemon's other hosts changed (`hosts.updated`).
    case otherHostsUpdated([OtherHostStatus])
    /// A pairing the daemon runs for this session moved on (`hosts.pairing`).
    case otherHostPairing(pairId: Int, state: OtherHostPairingState)
    /// On the hosts socket: the daemon's session with the host opened (`hosts:open`). One that follows
    /// a `hostLinkClosed` is a new session, so what the app shows of the host is read again.
    case hostLinkOpen
    /// On the hosts socket: the daemon lost its session with the host (`hosts:closed`) and tries again.
    case hostLinkClosed
    /// Periodic system load sample while watching (`host.load`).
    case hostLoad(HostLoad)
    /// What the host's own sessions' work came to, for the Agent RPG (`work.facts`).
    case workFacts([WorkFact])
    /// The daemon's idle game link changed: whether it runs, reaches its service, and what it holds back.
    case gameStatus(GameLinkStatusInfo)
    /// A frame from the game service, as the daemon passed it on: state, live battle events or a notice.
    case gameFrame(GameFrame)
    /// Active remote Claude Code runs hosted by this computer changed (`remoteClaude.activeChanged`).
    case remoteClaudeActiveChanged([RemoteClaudeActiveRun])
    case resync
    case unknown(type: String)

    private struct EventTypeProbe: Decodable {
        struct Inner: Decodable {
            let type: String
        }
        let event: Inner
    }

    private struct TypedEnvelope<Payload: Decodable>: Decodable {
        let event: Payload
    }

    private struct SummaryPayload: Decodable {
        let summary: SessionSummary
    }

    private struct RemovedPayload: Decodable {
        let sessionId: String
    }

    private struct AgentStatusPayload: Decodable {
        let status: AgentStatusInfo
    }

    private struct AgentOptionsPayload: Decodable {
        let options: AgentOptionsInfo
    }

    private struct AgentSignInLinkPayload: Decodable {
        let agentId: String
        let url: String
    }

    private struct ProjectsChangedPayload: Decodable {
        let projects: [ProjectInfo]
        let noProject: NoProjectInfo?
    }

    private struct FilesChangedPayload: Decodable {
        let projectPath: String
    }

    private struct PairingPayloadEnvelope: Decodable {
        let codeId: Double
        let pairing: JSONValue?
        let state: JSONValue?
    }

    private struct SyncUpdatedEnvelope: Decodable {
        let status: SartoSyncStatusInfo
    }

    private struct SyncUsageUpdatedEnvelope: Decodable {
        let ownDeviceId: String
        let records: [SyncedUsageRecordInfo]
    }

    private struct AccountUpdatedEnvelope: Decodable {
        let status: CloudAccountStatusInfo
    }

    private struct BrowserCallEnvelope: Decodable {
        let call: BrowserDeviceCall
    }

    private struct BrowserOriginDecidedEnvelope: Decodable {
        let sessionId: String
        let requestId: Int
        let decision: String
    }

    private struct BrowserTurnEndedEnvelope: Decodable {
        let sessionId: String
    }

    private struct BrowserAskAnsweredEnvelope: Decodable {
        let sessionId: String
        let outcome: String
    }

    private struct SettingsOpenEnvelope: Decodable {
        let section: String
        let item: String?
        let row: String
    }

    private struct MarketConnectionChangedEnvelope: Decodable {
        let serverId: String
        let connection: MarketConnectionInfo
        let loginId: String?
        let error: String?
    }

    private struct AppUpdateStateEnvelope: Decodable {
        let status: AppUpdateStatusInfo
    }

    private struct AppUpdateCommandEnvelope: Decodable {
        let action: String
    }

    private struct HostLoadEnvelope: Decodable {
        let load: HostLoad
    }

    /// Decodes a `{"type":"event","event":...}` wire frame straight from its bytes. Returns nil only
    /// when the frame has no `event.type`.
    public static func decode(fromEnvelopeData data: Data) -> HostEvent? {
        let decoder = JSONDecoder()
        let eventType: String
        if let sniffed = PortEnvelopeSniffer.eventType(data) {
            eventType = sniffed
        } else if let probe = try? decoder.decode(EventTypeProbe.self, from: data) {
            eventType = probe.event.type
        } else {
            return nil
        }
        switch eventType {
        case "session.summary":
            if let env = try? decoder.decode(TypedEnvelope<SummaryPayload>.self, from: data) {
                return .sessionSummary(env.event.summary)
            }
        case "session.patches":
            let batch = (try? JSONValue(jsonData: data))?.objectValue?["event"]?.objectValue?["batch"]
            return patchesEvent(batch)
        case "session.removed":
            if let env = try? decoder.decode(TypedEnvelope<RemovedPayload>.self, from: data) {
                return .sessionRemoved(sessionId: env.event.sessionId)
            }
        case "agent.status":
            if let env = try? decoder.decode(TypedEnvelope<AgentStatusPayload>.self, from: data) {
                return .agentStatus(env.event.status)
            }
        case "agent.options":
            if let env = try? decoder.decode(TypedEnvelope<AgentOptionsPayload>.self, from: data) {
                return .agentOptions(env.event.options)
            }
        case "agents.signInLink":
            if let env = try? decoder.decode(TypedEnvelope<AgentSignInLinkPayload>.self, from: data) {
                return .agentSignInLink(agentId: env.event.agentId, url: env.event.url)
            }
        case "projects.changed":
            if let env = try? decoder.decode(TypedEnvelope<ProjectsChangedPayload>.self, from: data) {
                return .projectsChanged(env.event.projects, noProject: env.event.noProject)
            }
        case "files.changed":
            if let env = try? decoder.decode(TypedEnvelope<FilesChangedPayload>.self, from: data) {
                return .filesChanged(projectPath: env.event.projectPath)
            }
        case "pairing":
            if let env = try? decoder.decode(TypedEnvelope<PairingPayloadEnvelope>.self, from: data),
               let cid = Int.wholePart(of: env.event.codeId),
               let state = env.event.pairing ?? env.event.state {
                return .pairing(codeId: cid, state: state)
            }
        case "sync.updated":
            if let env = try? decoder.decode(TypedEnvelope<SyncUpdatedEnvelope>.self, from: data) {
                return .syncUpdated(env.event.status)
            }
        case "sync.usage.updated":
            if let env = try? decoder.decode(TypedEnvelope<SyncUsageUpdatedEnvelope>.self, from: data) {
                return .syncUsageUpdated(ownDeviceId: env.event.ownDeviceId, records: env.event.records)
            }
        case "account.updated":
            if let env = try? decoder.decode(TypedEnvelope<AccountUpdatedEnvelope>.self, from: data) {
                return .accountUpdated(env.event.status)
            }
        case "browser.call":
            if let env = try? decoder.decode(TypedEnvelope<BrowserCallEnvelope>.self, from: data) {
                return .browserCall(env.event.call)
            }
        case "browser.originDecided":
            if let env = try? decoder.decode(TypedEnvelope<BrowserOriginDecidedEnvelope>.self, from: data) {
                return .browserOriginDecided(
                    sessionId: env.event.sessionId,
                    requestId: env.event.requestId,
                    decision: env.event.decision
                )
            }
        case "browser.turnEnded":
            if let env = try? decoder.decode(TypedEnvelope<BrowserTurnEndedEnvelope>.self, from: data) {
                return .browserTurnEnded(sessionId: env.event.sessionId)
            }
        case "browser.askAnswered":
            if let env = try? decoder.decode(TypedEnvelope<BrowserAskAnsweredEnvelope>.self, from: data) {
                return .browserAskAnswered(sessionId: env.event.sessionId, outcome: env.event.outcome)
            }
        case "settings.open":
            if let env = try? decoder.decode(TypedEnvelope<SettingsOpenEnvelope>.self, from: data) {
                return .settingsOpen(section: env.event.section, item: env.event.item, row: env.event.row)
            }
        case "memory.changed":
            return .memoryChanged
        case "market.keysChanged":
            return .marketKeysChanged
        case "usage.changed":
            return .usageChanged
        case "app.updateState":
            if let env = try? decoder.decode(TypedEnvelope<AppUpdateStateEnvelope>.self, from: data) {
                return .appUpdateState(env.event.status)
            }
        case "app.updateCommand":
            if let env = try? decoder.decode(TypedEnvelope<AppUpdateCommandEnvelope>.self, from: data) {
                return .appUpdateCommand(action: env.event.action)
            }
        case "host.load":
            if let env = try? decoder.decode(TypedEnvelope<HostLoadEnvelope>.self, from: data) {
                return .hostLoad(env.event.load)
            }
        case "work.facts":
            if let facts = (try? JSONValue(jsonData: data))?.objectValue?["event"]?.objectValue?["facts"] {
                return .workFacts(WorkFact.decodeList(facts))
            }
        case "game.status", "game.frame":
            if let obj = (try? JSONValue(jsonData: data))?.objectValue?["event"]?.objectValue {
                return Self.gameEvent(type: eventType, obj)
            }
        case "market.connectionChanged":
            if let env = try? decoder.decode(TypedEnvelope<MarketConnectionChangedEnvelope>.self, from: data) {
                return .marketConnectionChanged(
                    serverId: env.event.serverId,
                    connection: env.event.connection,
                    loginId: env.event.loginId,
                    error: env.event.error
                )
            }
        case "hosts.updated", "hosts.pairing", "remoteClaude.activeChanged":
            if let event = (try? JSONValue(jsonData: data))?.objectValue?["event"] {
                return decode(from: event)
            }
        default:
            if DeviceEvent.knownEventTypes.contains(eventType),
               let devEvt = DeviceEvent.decode(fromEnvelopeData: data) {
                return .deviceEvent(devEvt)
            }
            break
        }
        return .unknown(type: eventType)
    }

    /// A batch that cannot be read still names its session, which then resyncs instead of going stale;
    /// without even that, every session resyncs.
    private static func patchesEvent(_ batch: JSONValue?) -> HostEvent {
        guard let batch else { return .resync }
        if let decoded = PatchBatch(jsonValue: batch) {
            return .sessionPatches(decoded)
        }
        if let sessionId = batch.objectValue?["sessionId"]?.stringValue {
            return .sessionPatches(.resyncRequired(sessionId: sessionId))
        }
        return .resync
    }

    public static func decode(from value: JSONValue) -> HostEvent {
        guard let obj = value.objectValue, let type = obj["type"]?.stringValue else {
            return .unknown(type: "invalid")
        }
        switch type {
        case "session.summary":
            if let s = obj["summary"], let decoded = try? s.decode(SessionSummary.self) {
                return .sessionSummary(decoded)
            }
        case "session.patches":
            return patchesEvent(obj["batch"])
        case "session.removed":
            if let sid = obj["sessionId"]?.stringValue {
                return .sessionRemoved(sessionId: sid)
            }
        case "agent.status":
            if let st = obj["status"], let decoded = try? st.decode(AgentStatusInfo.self) {
                return .agentStatus(decoded)
            }
        case "agent.options":
            if let opt = obj["options"], let decoded = try? opt.decode(AgentOptionsInfo.self) {
                return .agentOptions(decoded)
            }
        case "agents.signInLink":
            if let agentId = obj["agentId"]?.stringValue,
               let url = obj["url"]?.stringValue {
                return .agentSignInLink(agentId: agentId, url: url)
            }
        case "projects.changed":
            if let ps = obj["projects"], let decoded = try? ps.decode([ProjectInfo].self) {
                let noProj = obj["noProject"].flatMap { try? $0.decode(NoProjectInfo.self) }
                return .projectsChanged(decoded, noProject: noProj)
            }
        case "files.changed":
            if let projectPath = obj["projectPath"]?.stringValue {
                return .filesChanged(projectPath: projectPath)
            }
        case "pairing":
            if let rawCid = obj["codeId"]?.doubleValue,
               let cid = Int.wholePart(of: rawCid),
               let state = obj["pairing"] ?? obj["state"] {
                return .pairing(codeId: cid, state: state)
            }
        case "sync.updated":
            if let st = obj["status"], let decoded = try? st.decode(SartoSyncStatusInfo.self) {
                return .syncUpdated(decoded)
            }
        case "sync.usage.updated":
            if let ownId = obj["ownDeviceId"]?.stringValue,
               let rawRecs = obj["records"],
               let recs = try? rawRecs.decode([SyncedUsageRecordInfo].self) {
                return .syncUsageUpdated(ownDeviceId: ownId, records: recs)
            }
        case "account.updated":
            if let st = obj["status"], let decoded = try? st.decode(CloudAccountStatusInfo.self) {
                return .accountUpdated(decoded)
            }
        case "browser.call":
            if let c = obj["call"], let decoded = try? c.decode(BrowserDeviceCall.self) {
                return .browserCall(decoded)
            }
        case "browser.originDecided":
            if let sid = obj["sessionId"]?.stringValue,
               let rawReqId = obj["requestId"]?.doubleValue,
               let reqId = Int.wholePart(of: rawReqId),
               let decision = obj["decision"]?.stringValue {
                return .browserOriginDecided(sessionId: sid, requestId: reqId, decision: decision)
            }
        case "browser.turnEnded":
            if let sid = obj["sessionId"]?.stringValue {
                return .browserTurnEnded(sessionId: sid)
            }
        case "browser.askAnswered":
            if let sid = obj["sessionId"]?.stringValue,
               let outcome = obj["outcome"]?.stringValue {
                return .browserAskAnswered(sessionId: sid, outcome: outcome)
            }
        case "settings.open":
            if let section = obj["section"]?.stringValue,
               let row = obj["row"]?.stringValue {
                return .settingsOpen(section: section, item: obj["item"]?.stringValue, row: row)
            }
        case "memory.changed":
            return .memoryChanged
        case "market.keysChanged":
            return .marketKeysChanged
        case "usage.changed":
            return .usageChanged
        case "app.updateState":
            if let raw = obj["status"], let decoded = try? raw.decode(AppUpdateStatusInfo.self) {
                return .appUpdateState(decoded)
            }
        case "app.updateCommand":
            if let action = obj["action"]?.stringValue {
                return .appUpdateCommand(action: action)
            }
        case "host.load":
            if let raw = obj["load"], let decoded = try? raw.decode(HostLoad.self) {
                return .hostLoad(decoded)
            }
        case "work.facts":
            if let facts = obj["facts"] {
                return .workFacts(WorkFact.decodeList(facts))
            }
        case "game.status", "game.frame":
            return Self.gameEvent(type: type, obj)
        case "market.connectionChanged":
            if let sid = obj["serverId"]?.stringValue,
               let connVal = obj["connection"],
               let conn = try? connVal.decode(MarketConnectionInfo.self) {
                return .marketConnectionChanged(
                    serverId: sid,
                    connection: conn,
                    loginId: obj["loginId"]?.stringValue,
                    error: obj["error"]?.stringValue
                )
            }
        case "hosts.updated":
            if let list = obj["hosts"], let decoded = try? list.decode([OtherHostStatus].self) {
                return .otherHostsUpdated(decoded)
            }
        case "hosts.pairing":
            if let rawPairId = obj["pairId"]?.doubleValue,
               let pairId = Int.wholePart(of: rawPairId),
               let raw = obj["pairing"],
               let decoded = try? raw.decode(OtherHostPairingState.self) {
                return .otherHostPairing(pairId: pairId, state: decoded)
            }
        case "remoteClaude.activeChanged":
            if let list = obj["active"], let decoded = try? list.decode([RemoteClaudeActiveRun].self) {
                return .remoteClaudeActiveChanged(decoded)
            }
        default:
            if DeviceEvent.knownEventTypes.contains(type) {
                return .deviceEvent(DeviceEvent.decode(from: value))
            }
            break
        }
        return .unknown(type: type)
    }
}
