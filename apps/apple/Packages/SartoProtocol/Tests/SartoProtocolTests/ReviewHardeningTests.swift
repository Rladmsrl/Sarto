import Foundation
import Testing
@testable import SartoProtocol

/// Driver whose socket the relay closes with `closeCode` once `framesBeforeClose` frames were read.
private final class ClosingRelayDriver: ChannelWebSocketDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [URLSessionWebSocketTask.Message]
    private let closeCode: Int?
    private var closed = false

    init(frames: [URLSessionWebSocketTask.Message] = [], closeCode: Int?) {
        self.frames = frames
        self.closeCode = closeCode
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try lock.withLock {
            if !frames.isEmpty { return frames.removeFirst() }
            closed = true
            throw URLError(.networkConnectionLost)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    var peerCloseCode: Int? {
        lock.withLock { closed ? closeCode : nil }
    }
}

@Suite("Review hardening: relay refusals, lossy welcome, ANSI escapes, identity permissions")
struct ReviewHardeningTests {
    private func connect(_ driver: ClosingRelayDriver) async throws {
        _ = try await SartoRelayClient.connectViaRelayDriver(
            driver: driver,
            relayToken: "tok",
            localStaticKey: NoiseKeyPair(),
            hostStaticPublicKey: NoiseKeyPair().publicKeyData,
            psk: nil,
            timeout: 2.0
        )
    }

    @Test("A relay close code before join maps to relayRefused with its RelayCloseCode")
    func relayCloseCodesMapToRefusals() async throws {
        let cases: [(Int, RelayCloseCode)] = [
            (4404, .offline), (4403, .forbidden), (4429, .tooMany), (4401, .unauthorized),
        ]
        for (code, reason) in cases {
            do {
                try await connect(ClosingRelayDriver(frames: [.string("ping")], closeCode: code))
                Issue.record("expected relay refusal \(code)")
            } catch let error as RelayClientError {
                #expect(error == .relayRefused(code: code))
                #expect(error.relayRefusal == reason)
                #expect(error.errorDescription?.contains("\(code)") == false)
            }
        }
    }

    @Test("A relay close during the Noise handshake maps to relayRefused")
    func relayCloseDuringHandshakeMaps() async throws {
        let driver = ClosingRelayDriver(frames: [.string("{\"type\":\"joined\"}")], closeCode: 4408)
        await #expect(throws: RelayClientError.relayRefused(code: 4408)) {
            try await connect(driver)
        }
    }

    @Test("A close without a relay reason keeps the transport error")
    func plainCloseKeepsTransportError() async throws {
        for code in [nil, 1000, 1006] as [Int?] {
            await #expect(throws: URLError.self) {
                try await connect(ClosingRelayDriver(closeCode: code))
            }
        }
    }

    @Test("Welcome drops malformed addresses and features instead of failing")
    func welcomeDecodesLossily() throws {
        let json = """
        {"type":"welcome","protocol":4,
         "host":{"name":"Mac","platform":"darwin","version":"0.2.0"},
         "features":["bytes",3,null,{"x":1},"standby"],
         "device":{"id":"dev_123456","name":"iPhone"},
         "terminal":"yes",
         "addresses":[
           {"host":"192.168.1.20","port":4123},
           {"host":7,"port":4123},
           {"host":"evil.example/path?x","port":4123},
           {"host":"studio.local","port":70000},
           {"host":"","port":80},
           "10.0.0.1:80",
           {"host":"fe80::1","port":443},
           {"host":"studio.example.ts.net","port":8787}
         ]}
        """
        let welcome = try JSONDecoder().decode(WelcomeMessage.self, from: Data(json.utf8))
        #expect(welcome.features == ["bytes", "standby"])
        #expect(welcome.terminal == false)
        #expect(welcome.addresses == [
            DirectAddress(host: "192.168.1.20", port: 4123),
            DirectAddress(host: "fe80::1", port: 443),
            DirectAddress(host: "studio.example.ts.net", port: 8787),
        ])

        let notArrays = """
        {"type":"welcome","protocol":4,
         "host":{"name":"Mac","platform":"darwin","version":"0.2.0"},
         "features":"bytes","addresses":{"host":"10.0.0.1","port":1},
         "device":{"id":"dev_123456","name":"iPhone"}}
        """
        let bare = try JSONDecoder().decode(WelcomeMessage.self, from: Data(notArrays.utf8))
        #expect(bare.features.isEmpty)
        #expect(bare.addresses.isEmpty)

        let many = (0..<100).map { "{\"host\":\"10.0.0.\($0 % 250)\",\"port\":\(1000 + $0)}" }
        let manyJSON = """
        {"type":"welcome","protocol":4,
         "host":{"name":"Mac","platform":"darwin","version":"0.2.0"},
         "device":{"id":"dev_123456","name":"iPhone"},
         "addresses":[\(many.joined(separator: ","))]}
        """
        let capped = try JSONDecoder().decode(WelcomeMessage.self, from: Data(manyJSON.utf8))
        #expect(capped.addresses.count == WelcomeMessage.maxAddresses)
    }

    @Test("ANSI parser consumes ESC intermediates and final byte, e.g. tput sgr0's ESC ( B")
    func ansiDesignatorEscapes() {
        let sgr0 = "\u{1B}[1;31mERR\u{1B}(B\u{1B}[m ok"
        let spans = ANSITerminalParser.parse(sgr0)
        #expect(spans.map(\.text).joined() == "ERR ok")
        #expect(spans.first?.fgCode == 31)

        #expect(ANSITerminalParser.parse("a\u{1B}=b\u{1B}>c\u{1B}7d\u{1B}8e\u{1B}#8f").map(\.text).joined() == "abcdef")
        #expect(ANSITerminalParser.parse("x\u{1B}Pq#0;2;0;0;0\u{1B}\\y").map(\.text).joined() == "xy")
        #expect(ANSITerminalParser.parse("x\u{1B}\u{1B}[32my").map(\.text).joined() == "xy")

        var carry = ""
        let first = ANSITerminalParser.parse("tail\u{1B}(", carry: &carry)
        #expect(first.map(\.text).joined() == "tail")
        #expect(carry == "\u{1B}(")
        let second = ANSITerminalParser.parse("Bnext", carry: &carry)
        #expect(carry.isEmpty)
        #expect(second.map(\.text).joined() == "next")
    }

    @Test("ANSI parser joins a long combining-mark run into one cell in linear time")
    func ansiLongCombiningRun() {
        let marks = String(repeating: "\u{0301}", count: 20_000)
        let start = ContinuousClock.now
        let spans = ANSITerminalParser.parse("e\(marks)x\n")
        let elapsed = ContinuousClock.now - start
        let text = spans.map(\.text).joined()
        #expect(text.count == 3)
        #expect(text.hasSuffix("x\n"))
        #expect(elapsed < .seconds(2))

        let emoji = ANSITerminalParser.parse("👩‍👩‍👧‍👦 a\u{0308}\tb\r")
        #expect(emoji.map(\.text).joined() == "👩‍👩‍👧‍👦 ä\tb")
    }

    @Test("ANSI parser handles a megabyte of plain text quickly")
    func ansiPlainTextThroughput() {
        let line = String(repeating: "lorem ipsum dolor sit amet ", count: 4) + "\n"
        let raw = String(repeating: line, count: 1_000_000 / line.utf8.count)
        let start = ContinuousClock.now
        let spans = ANSITerminalParser.parse(raw)
        let elapsed = ContinuousClock.now - start
        #expect(spans.count == 1)
        #expect(spans[0].text == raw)
        #expect(elapsed < .seconds(2))
    }

    #if os(macOS)
    @Test("Device identity is written owner-only in an owner-only folder")
    func identityFilePermissions() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pk-perm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("Sarto", isDirectory: true)
        let fileURL = dir.appendingPathComponent("device-identity.json")
        let store = DeviceIdentityStore(fileURL: fileURL)

        let created = store.loadOrCreateIdentity()
        store.save(keyPair: created.keyPair, hosts: [])

        func mode(_ url: URL) throws -> Int? {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            return (attrs[.posixPermissions] as? NSNumber)?.intValue
        }
        #expect(try mode(dir) == 0o700)
        #expect(try mode(fileURL) == 0o600)
        #expect(try mode(fileURL.appendingPathExtension("bak")) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
        let reloaded = store.loadOrCreateIdentity()
        #expect(reloaded.keyPair.publicKeyData == created.keyPair.publicKeyData)
        #expect(try mode(dir) == 0o700)
        #expect(try mode(fileURL) == 0o600)
    }
    #endif
}

@Suite("Review hardening: where the relay token may go, and numbers a host sends")
struct RelayTrustAndNumberTests {
    @Test("The relay token goes only to the configured relay and hosts under it")
    func trustedRelays() {
        let main = "https://relay.sarto.dev"
        #expect(RelayProtocol.isTrustedRelay("https://relay.sarto.dev", main: main))
        #expect(RelayProtocol.isTrustedRelay("https://relay.sarto.dev/", main: main))
        #expect(RelayProtocol.isTrustedRelay("https://relay.sarto.dev:443", main: main))
        #expect(RelayProtocol.isTrustedRelay("HTTPS://Relay.Sarto.Dev", main: main))
        #expect(RelayProtocol.isTrustedRelay("https://hk.relay.sarto.dev", main: main))
        // A sibling under the same parent domain is someone else's host.
        #expect(!RelayProtocol.isTrustedRelay("https://relay-hk.sarto.dev", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://other.sarto.dev", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://sarto.dev", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://evilrelay.sarto.dev", main: main))
        #expect(!RelayProtocol.isTrustedRelay("http://relay.sarto.dev", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://relay.sarto.dev:8443", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://relay.sarto.dev.example.com", main: main))
        #expect(!RelayProtocol.isTrustedRelay("https://evilsarto.dev", main: main))

        #expect(RelayProtocol.isTrustedRelay("https://sarto.1o.ink", main: "https://sarto.1o.ink"))
        #expect(RelayProtocol.isTrustedRelay("https://hk.sarto.1o.ink", main: "https://sarto.1o.ink"))
        #expect(!RelayProtocol.isTrustedRelay("https://evil.1o.ink", main: "https://sarto.1o.ink"))
        #expect(!RelayProtocol.isTrustedRelay("https://1o.ink", main: "https://sarto.1o.ink"))

        // An address or a name of its own, as localhost, vouches for no other.
        #expect(RelayProtocol.isTrustedRelay("https://10.0.0.1", main: "https://10.0.0.1"))
        #expect(!RelayProtocol.isTrustedRelay("https://1.10.0.1", main: "https://10.0.0.1"))
        #expect(RelayProtocol.isTrustedRelay("http://localhost:8798", main: "http://localhost:8798"))
        #expect(!RelayProtocol.isTrustedRelay("http://localhost:8799", main: "http://localhost:8798"))
        #expect(!RelayProtocol.isTrustedRelay("http://evil.localhost:8798", main: "http://localhost:8798"))
        #expect(RelayProtocol.isTrustedRelay("http://[::1]:8798", main: "http://[::1]:8798"))
        #expect(!RelayProtocol.isTrustedRelay("http://[::2]:8798", main: "http://[::1]:8798"))
    }

    @Test("A relay URL that does not read as a plain origin is never trusted")
    func untrustedShapes() {
        let main = "https://sarto.1o.ink"
        for origin in [
            "",
            "sarto.1o.ink",
            "wss://sarto.1o.ink",
            "https://sarto.1o.ink@evil.example",
            "https://evil.example@hk.sarto.1o.ink",
            "https://evil.example/.sarto.1o.ink",
            "https://evil.example?.sarto.1o.ink",
            "https://evil.example#.sarto.1o.ink",
            "https://evil.example\\.sarto.1o.ink",
            "https://evil.example%2f.sarto.1o.ink",
            "https://hk.sarto.1o.ink/path",
            "https://hk.sarto.1o.ink:0",
            "https://hk.sarto.1o.ink:99999",
            "https://hk..sarto.1o.ink",
            "https://.sarto.1o.ink",
            "https:// hk.sarto.1o.ink",
        ] {
            #expect(!RelayProtocol.isTrustedRelay(origin, main: main), "\(origin)")
        }
        #expect(!RelayProtocol.isTrustedRelay("https://sarto.1o.ink", main: ""))
        #expect(!RelayProtocol.isTrustedRelay("https://sarto.1o.ink", main: "sarto.1o.ink"))
    }

    @Test("A number outside Int's range reads as none instead of trapping")
    func wholePartOfHostNumbers() {
        #expect(Int.wholePart(of: 42) == 42)
        #expect(Int.wholePart(of: 3.9) == 3)
        #expect(Int.wholePart(of: -3.9) == -3)
        #expect(Int.wholePart(of: 1e30) == nil)
        #expect(Int.wholePart(of: -1e30) == nil)
        #expect(Int.wholePart(of: .nan) == nil)
        #expect(Int.wholePart(of: .infinity) == nil)
        #expect(Int.wholePart(of: -.infinity) == nil)
        #expect(Int.wholePart(of: 0x1p63) == nil)
        #expect(Int.wholePart(of: -0x1p63) == Int.min)
    }

    @Test("A welcome, a tool's input digest and the settings survive a number too large for Int")
    func hugeNumbersFromAHost() throws {
        let json = """
        {"type":"welcome","protocol":4,
         "host":{"name":"Mac","platform":"darwin","version":"0.2.0"},
         "device":{"id":"dev_123456","name":"iPhone"},
         "resumed":{"request":1e30}}
        """
        let welcome = try JSONDecoder().decode(WelcomeMessage.self, from: Data(json.utf8))
        #expect(welcome.resumed == true)
        #expect(welcome.resumedRequest == nil)

        let digest = ToolEntryData.parseRawInputDigest(.object(["size": .number(1e30), "lines": .number(-1e30)]))
        #expect(digest.info == nil)
        let fine = ToolEntryData.parseRawInputDigest(.object(["size": .number(120), "lines": .number(4)]))
        #expect(fine.info == ToolInputDigestInfo(size: 120, lines: 4))

        let settings = HostSettingsSnapshot.from(json: .object([
            "idleSessions": .object([
                "outOfView": .number(1e30), "inView": .number(-1e30), "limit": .number(1e30),
            ]),
        ]))
        let defaults = HostSettingsSnapshot.from(json: .object([:]))
        #expect(settings.idleOutOfView == defaults.idleOutOfView)
        #expect(settings.idleInView == defaults.idleInView)
        #expect(settings.idleLimit == nil)

        let moved = JSONValue.array([.string("a")]).setting(.string("b"), at: [.number(1e30)])
        #expect(moved == .array([.string("a")]))
    }
}
