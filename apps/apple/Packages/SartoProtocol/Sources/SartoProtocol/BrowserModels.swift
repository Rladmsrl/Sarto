import Foundation

// MARK: - Browser Wire Protocol Models (src/shared/browser.ts & src/shared/agent-host.ts)

/// A loopback TCP target the host names when an agent opens a local dev server on the host.
public struct BrowserForward: Codable, Sendable, Equatable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Named viewport presets matching `PAGE_SIZE_NAMES` in `src/shared/browser.ts`.
public enum BrowserPageSizeName: String, Codable, Sendable, Equatable, CaseIterable {
    case desktop
    case tablet
    case phone
    case custom
}

/// Fixed layout size a browser tab keeps, with optional mobile UA/touch emulation.
public struct BrowserPageSize: Codable, Sendable, Equatable {
    public static let minSide = 320
    public static let maxSide = 2560
    public static let sizeLineRoom: Double = 36

    public static let desktop = BrowserPageSize(name: .desktop, width: 1280, height: 800, mobile: false)
    public static let tablet = BrowserPageSize(name: .tablet, width: 768, height: 1024, mobile: true)
    public static let phone = BrowserPageSize(name: .phone, width: 390, height: 844, mobile: true)

    public let name: BrowserPageSizeName
    public let width: Int
    public let height: Int
    public let mobile: Bool

    public init(name: BrowserPageSizeName, width: Int, height: Int, mobile: Bool) {
        self.name = name
        self.width = width
        self.height = height
        self.mobile = mobile
    }

    public static func preset(named raw: String) -> BrowserPageSize? {
        switch raw {
        case "desktop": return .desktop
        case "tablet": return .tablet
        case "phone": return .phone
        default: return nil
        }
    }

    /// Parses `browser_resize` tool arguments, mirroring `pageSizeOf` in `src/shared/browser.ts`.
    public static func parse(args: [String: JSONValue]) -> Result<BrowserPageSize, BrowserToolError> {
        let sizeVal = args["size"]
        let widthVal = args["width"]
        let heightVal = args["height"]
        if let sizeVal, sizeVal != .null {
            if (widthVal != nil && widthVal != .null) || (heightVal != nil && heightVal != .null) {
                return .failure(BrowserToolError(code: "invalid", message: "Give size, or width and height, not both."))
            }
            guard let name = sizeVal.stringValue, let preset = preset(named: name) else {
                return .failure(BrowserToolError(code: "invalid", message: "size must be desktop, tablet or phone."))
            }
            return .success(preset)
        }
        let hasWidth = widthVal != nil && widthVal != .null
        let hasHeight = heightVal != nil && heightVal != .null
        if !hasWidth && !hasHeight {
            return .failure(BrowserToolError(code: "invalid", message: "Give size (desktop, tablet or phone), or width and height."))
        }
        func validSide(_ val: JSONValue?) -> Int? {
            guard let n = val?.doubleValue, n.isFinite, n.truncatingRemainder(dividingBy: 1) == 0,
                  let i = Int.wholePart(of: n), (minSide...maxSide).contains(i)
            else { return nil }
            return i
        }
        guard let w = validSide(widthVal), let h = validSide(heightVal) else {
            return .failure(BrowserToolError(
                code: "invalid",
                message: "width and height must both be whole numbers from \(minSide) to \(maxSide)."
            ))
        }
        return .success(BrowserPageSize(name: .custom, width: w, height: h, mobile: false))
    }
}

/// An incoming `browser.call` event dispatched by `agent-host` to a desktop app port with `browser: true`.
public struct BrowserDeviceCall: Codable, Sendable, Equatable {
    public let callId: Int
    public let sessionId: String
    public let tool: String
    public let args: [String: JSONValue]
    public let projectPath: String
    public let allowTab: String?
    public let forward: BrowserForward?

    public init(
        callId: Int,
        sessionId: String,
        tool: String,
        args: [String: JSONValue] = [:],
        projectPath: String = "",
        allowTab: String? = nil,
        forward: BrowserForward? = nil
    ) {
        self.callId = callId
        self.sessionId = sessionId
        self.tool = tool
        self.args = args
        self.projectPath = projectPath
        self.allowTab = allowTab
        self.forward = forward
    }

    enum CodingKeys: String, CodingKey {
        case callId
        case sessionId
        case tool
        case args
        case projectPath
        case allowTab
        case forward
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.callId = try c.decode(Int.self, forKey: .callId)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.tool = try c.decode(String.self, forKey: .tool)
        self.args = try c.decodeIfPresent([String: JSONValue].self, forKey: .args) ?? [:]
        self.projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath) ?? ""
        self.allowTab = try c.decodeIfPresent(String.self, forKey: .allowTab)
        self.forward = try c.decodeIfPresent(BrowserForward.self, forKey: .forward)
    }
}

/// Successful tool answer returned inside `browser.answer`.
public struct BrowserCallResult: Codable, Sendable, Equatable {
    public let text: String
    public let value: [String: JSONValue]
    public let image: String?

    public init(text: String, value: [String: JSONValue], image: String? = nil) {
        self.text = text
        self.value = value
        self.image = image
    }

    public func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [
            "text": .string(text),
            "value": .object(value),
        ]
        if let image {
            obj["image"] = .string(image)
        }
        return .object(obj)
    }
}

/// Identifies a user-opened tab that needs explicit approval (`code == "needs_allow"`).
public struct BrowserToolErrorTab: Codable, Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// Failure answer returned inside `browser.answer`.
public struct BrowserToolError: Error, Codable, Sendable, Equatable {
    public let code: String
    public let message: String
    public let tab: BrowserToolErrorTab?

    public init(code: String, message: String, tab: BrowserToolErrorTab? = nil) {
        self.code = code
        self.message = message
        self.tab = tab
    }

    public func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [
            "code": .string(code),
            "message": .string(message),
        ]
        if let tab {
            obj["tab"] = .object([
                "id": .string(tab.id),
                "title": .string(tab.title),
            ])
        }
        return .object(obj)
    }
}

/// Union payload of `browser.answer`'s `answer` field.
public enum BrowserCallAnswer: Sendable, Equatable {
    case result(BrowserCallResult)
    case error(BrowserToolError)

    public func toJSONValue() -> JSONValue {
        switch self {
        case .result(let res):
            return .object(["result": res.toJSONValue()])
        case .error(let err):
            return .object(["error": err.toJSONValue()])
        }
    }
}

/// Parsed keyboard stroke matching `src/main/browser/cdp.ts` `parseKey`.
public struct BrowserKeyStroke: Sendable, Equatable {
    public let key: String
    public let code: String
    public let keyCode: Int
    public let text: String?
    public let altKey: Bool
    public let ctrlKey: Bool
    public let metaKey: Bool
    public let shiftKey: Bool

    public init(
        key: String,
        code: String,
        keyCode: Int,
        text: String? = nil,
        altKey: Bool = false,
        ctrlKey: Bool = false,
        metaKey: Bool = false,
        shiftKey: Bool = false
    ) {
        self.key = key
        self.code = code
        self.keyCode = keyCode
        self.text = text
        self.altKey = altKey
        self.ctrlKey = ctrlKey
        self.metaKey = metaKey
        self.shiftKey = shiftKey
    }
}

// MARK: - Browser Security & URL Policy (faithful port of src/main/browser/policy.ts & cdp.ts)

public enum BrowserPolicy {
    public static let maxSessionTabs = 50
    public static let maxSnapshotLines = 2_000
    public static let maxConsoleMessages = 200
    public static let maxNetworkRequests = 300
    public static let maxEvaluateBytes = 64 * 1024
    public static let maxShotSide = 2_000
    public static let maxPageHeight = 8_000
    public static let controlWaitSeconds: TimeInterval = 45.0
    public static let originWaitSeconds: TimeInterval = 120.0

    private static let neverOpenedSchemes: Set<String> = [
        "file",
        "javascript",
        "data",
        "blob",
        "chrome",
        "devtools",
        "view-source",
    ]

    /// Hosts an agent may open without asking: local dev servers on this machine.
    public static func isLocalHost(_ hostname: String) -> Bool {
        let host = hostname
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".test")
    }

    public static func isNeverOpened(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return neverOpenedSchemes.contains(scheme) || scheme.hasPrefix("sarto-")
    }

    public static func isHttp(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public static func isLocalAddress(_ url: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard isHttp(url), let host = url.host else { return false }
        return isLocalHost(host)
    }

    public static func isAllowedNavigation(_ raw: String) -> Bool {
        if raw == "about:blank" || raw == "about:srcdoc" { return true }
        guard let url = URL(string: raw) else { return false }
        return isHttp(url)
    }

    /// Validates an agent-requested URL against Sarto's navigation policy.
    public static func checkAgentNavigation(_ raw: String) -> Result<String, BrowserToolError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            return .failure(BrowserToolError(code: "invalid", message: "\"\(raw)\" is not an absolute URL."))
        }
        if url.absoluteString == "about:blank" {
            return .success("about:blank")
        }
        if isNeverOpened(url) {
            return .failure(BrowserToolError(code: "not_allowed", message: "\(scheme): pages never open in Sarto."))
        }
        guard isHttp(url), url.host != nil else {
            return .failure(BrowserToolError(code: "not_allowed", message: "\(scheme): pages never open in Sarto."))
        }
        return .success(url.absoluteString)
    }

    /// Normalizes a user-typed address bar string into a safe `http(s)` or `about:blank` URL.
    public static func normalizeUserInputURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "about:blank" {
            return URL(string: "about:blank")
        }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), isHttp(url), url.host != nil else { return nil }
            return url
        }
        // Reject dangerous schemes typed without `//` such as `javascript:` or `file:`
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains("."),
           !trimmed[..<colon].contains("/") {
            let prefix = String(trimmed[..<colon]).lowercased()
            if neverOpenedSchemes.contains(prefix) || prefix.hasPrefix("sarto-") {
                return nil
            }
            // Otherwise likely `localhost:3000` or `127.0.0.1:5173`
            let hostPart = prefix
            let scheme = isLocalHost(hostPart) ? "http" : "https"
            guard let url = URL(string: "\(scheme)://\(trimmed)"), isHttp(url), url.host != nil else {
                return nil
            }
            return url
        }
        let hostCandidate = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let hostOnly = hostCandidate.split(separator: ":").first.map(String.init) ?? hostCandidate
        let scheme = isLocalHost(hostOnly) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(trimmed)"), isHttp(url), url.host != nil else {
            return nil
        }
        return url
    }

    /// Canonical origin string (`scheme://host[:port]`) used for origin approval rules.
    public static func originOf(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased()
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Human-readable site host shown on control banners and ask cards.
    public static func siteOf(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              isHttp(url),
              let host = url.host?.lowercased()
        else { return nil }
        let defaultPort = url.scheme?.lowercased() == "https" ? 443 : 80
        if let port = url.port, port != defaultPort {
            return "\(host):\(port)"
        }
        return host
    }

    private static let namedKeys: [String: (code: String, vk: Int, text: String?)] = [
        "enter": ("Enter", 13, "\r"),
        "return": ("Enter", 13, "\r"),
        "tab": ("Tab", 9, "\t"),
        "escape": ("Escape", 27, nil),
        "esc": ("Escape", 27, nil),
        "backspace": ("Backspace", 8, nil),
        "delete": ("Delete", 46, nil),
        "arrowup": ("ArrowUp", 38, nil),
        "arrowdown": ("ArrowDown", 40, nil),
        "arrowleft": ("ArrowLeft", 37, nil),
        "arrowright": ("ArrowRight", 39, nil),
        "up": ("ArrowUp", 38, nil),
        "down": ("ArrowDown", 40, nil),
        "left": ("ArrowLeft", 37, nil),
        "right": ("ArrowRight", 39, nil),
        "home": ("Home", 36, nil),
        "end": ("End", 35, nil),
        "pageup": ("PageUp", 33, nil),
        "pagedown": ("PageDown", 34, nil),
        "space": ("Space", 32, " "),
    ]

    private static let punctuationCodes: [Character: String] = [
        "`": "Backquote",
        "-": "Minus",
        "=": "Equal",
        "[": "BracketLeft",
        "]": "BracketRight",
        "\\": "Backslash",
        ";": "Semicolon",
        "'": "Quote",
        ",": "Comma",
        ".": "Period",
        "/": "Slash",
    ]

    /// Parses a key name or combo (`Control+A`, `Shift+Enter`, `Meta+ArrowLeft`) matching `cdp.ts`.
    public static func parseKey(_ input: String) -> Result<BrowserKeyStroke, BrowserToolError> {
        var parts = input.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let last = parts.popLast() ?? ""
        var alt = false
        var ctrl = false
        var meta = false
        var shift = false

        for raw in parts {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "alt", "option": alt = true
            case "control", "ctrl": ctrl = true
            case "meta", "cmd", "command", "super": meta = true
            case "shift": shift = true
            default:
                return .failure(BrowserToolError(code: "invalid", message: "Unknown modifier \"\(raw)\"."))
            }
        }

        let key = last.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            return .failure(BrowserToolError(code: "invalid", message: "The key is empty."))
        }

        let lower = key.lowercased()
        if let named = namedKeys[lower] {
            let emittedText = (named.text != nil && !ctrl) ? named.text : nil
            return .success(BrowserKeyStroke(
                key: named.code == "Space" ? " " : named.code,
                code: named.code,
                keyCode: named.vk,
                text: emittedText,
                altKey: alt,
                ctrlKey: ctrl,
                metaKey: meta,
                shiftKey: shift
            ))
        }

        if lower.hasPrefix("f"), let n = Int(lower.dropFirst()), (1...12).contains(n) {
            return .success(BrowserKeyStroke(
                key: "F\(n)",
                code: "F\(n)",
                keyCode: 111 + n,
                text: nil,
                altKey: alt,
                ctrlKey: ctrl,
                metaKey: meta,
                shiftKey: shift
            ))
        }

        if key.count == 1, let ch = key.first {
            let scalar = ch.unicodeScalars.first?.value ?? 0
            let isLetter = (scalar >= 65 && scalar <= 90) || (scalar >= 97 && scalar <= 122)
            let isDigit = scalar >= 48 && scalar <= 57
            let upper = String(ch).uppercased()
            let code: String
            let vk: Int
            if isLetter {
                code = "Key\(upper)"
                vk = Int(upper.unicodeScalars.first?.value ?? 0)
            } else if isDigit {
                code = "Digit\(ch)"
                vk = Int(scalar)
            } else if let p = punctuationCodes[ch] {
                code = p
                vk = 0
            } else {
                return .failure(BrowserToolError(code: "invalid", message: "Unknown key \"\(input)\"."))
            }
            let typed = (shift && isLetter) ? upper : String(ch)
            let emittedText = (!ctrl && !meta) ? typed : nil
            return .success(BrowserKeyStroke(
                key: typed,
                code: code,
                keyCode: vk,
                text: emittedText,
                altKey: alt,
                ctrlKey: ctrl,
                metaKey: meta,
                shiftKey: shift
            ))
        }

        return .failure(BrowserToolError(
            code: "invalid",
            message: "Unknown key \"\(input)\". Use a key name or a combination."
        ))
    }
}

// MARK: - Local Daemon Browser Device Identity (src/shared/remote/device.ts `identifyPort`)

public enum LocalBrowserPortIdentity {
    private static let defaultsKey = "dev.sarto.localBrowserDeviceId"

    /// Stable 32-lowercase-hex device identifier satisfying Sarto's `DEVICE_ID = /^[0-9a-f]{32}$/`.
    public static func stableDeviceID() -> String {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           isValidDeviceID(saved) {
            return saved
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: defaultsKey)
        return hex
    }

    public static func isValidDeviceID(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.unicodeScalars.allSatisfy { s in
            (s.value >= 48 && s.value <= 57) || (s.value >= 97 && s.value <= 102)
        }
    }

    /// Encodes the `host:connect` identification message read by `identifyPort` on `agent-host`'s Unix socket.
    public static func connectFrameData(deviceId: String? = nil, name: String = "Sarto") throws -> Data {
        let resolvedID = deviceId.flatMap { isValidDeviceID($0) ? $0 : nil } ?? stableDeviceID()
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName.isEmpty ? "Sarto" : String(trimmedName.prefix(64))
        let payload: JSONValue = .object([
            "type": .string("host:connect"),
            "device": .object([
                "id": .string(resolvedID),
                "name": .string(safeName),
                "local": .bool(true),
                "browser": .bool(true),
                "imageRefs": .bool(true),
                "toolDigests": .bool(true),
            ]),
        ])
        return try JSONEncoder().encode(payload)
    }
}
