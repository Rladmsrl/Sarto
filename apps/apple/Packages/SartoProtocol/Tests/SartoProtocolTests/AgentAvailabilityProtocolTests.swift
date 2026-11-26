import Foundation
import Testing
@testable import SartoProtocol

private actor CapturingTransport: SartoPortTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let results: [String: String]
    private(set) var requests: [[String: JSONValue]] = []

    init(results: [String: String]) {
        self.results = results
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        guard let request = try JSONValue(jsonData: data).objectValue,
              let id = request["id"]?.doubleValue,
              let method = request["method"]?.stringValue
        else { return }
        requests.append(request)
        let result = results[method] ?? "null"
        continuation.yield(Data("{\"type\":\"response\",\"id\":\(Int(id)),\"result\":\(result)}".utf8))
    }

    func close() async {
        continuation.finish()
    }
}

@Suite("Agent availability: harness reasons, install offers and agents.install")
struct AgentAvailabilityProtocolTests {
    // Shaped as `AgentStatus` in src/shared/agent-host.ts for Gemini CLI waiting for Node.js.
    private let statusJSON = """
    {
      "id": "gemini", "name": "Gemini CLI", "harnessId": "gemini", "harnessName": "Gemini CLI",
      "isDefault": true, "registered": true, "hidden": false, "apiKey": null,
      "state": "node-outdated", "version": null,
      "package": { "name": "@google/gemini-cli", "version": "0.31.0", "installed": true, "isCli": true },
      "release": null,
      "signIn": "unknown", "authMethods": [], "canLogout": false, "account": null, "limits": [],
      "detail": "Gemini CLI needs Node.js 22.19.0 or later; 20.11.1 is installed.",
      "reason": { "kind": "needs-node", "minimum": "22.19.0", "installed": "20.11.1" },
      "installUrl": "https://github.com/google-gemini/gemini-cli",
      "installNotice": "The official installer puts gemini in ~/.local/bin.",
      "progress": [], "launchCommand": "gemini --acp", "binaryOverride": null, "binaryCommand": null,
      "program": { "command": "gemini", "onPath": true },
      "update": null, "updateCheckedAt": null, "updateSkipped": false, "task": null,
      "installMethods": [
        { "id": "brew", "label": "brew install gemini-cli", "command": "brew install gemini-cli", "available": true },
        { "id": "npm", "label": "npm install -g @google/gemini-cli", "command": "npm install -g @google/gemini-cli", "available": false }
      ],
      "cli": {
        "command": "gemini",
        "installed": { "path": "/opt/homebrew/bin/gemini", "version": "0.20.0", "variable": null,
                       "problem": { "kind": "too-old", "minimum": "0.25.0" } },
        "method": "pnpm",
        "update": { "version": "0.31.0", "command": "pnpm add -g @google/gemini-cli@0.31.0" },
        "checkable": false
      },
      "uninstallCommand": "brew uninstall gemini-cli",
      "balance": { "state": "ready", "limits": [], "balances": [{ "label": "Balance", "amount": 0, "currency": "USD" }],
                   "observedAt": 1700000000000, "error": null },
      "providers": [
        { "id": "deepseek", "name": "DeepSeek", "methods": [], "accounts": [], "loginCommand": "opencode auth login",
          "usage": { "state": "ready", "limits": [], "balances": [{ "label": "Credit", "amount": 2.5, "currency": "CNY" }],
                     "observedAt": 1700000000000, "error": null } }
      ],
      "configDir": null, "sartoServer": { "runs": true, "active": null },
      "capabilities": { "loadSession": true, "listSessions": true, "resumeSession": false, "closeSession": false,
                        "deleteSession": false, "forkSession": false, "forkAtMessage": false, "steering": false,
                        "reports": false, "context": false, "liveContext": false, "account": false,
                        "mcpHttp": null, "prompt": null }
    }
    """

    @Test("AgentStatus decodes the reason, install methods, package, program and CLI problem")
    func statusDecodesAvailability() throws {
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(statusJSON.utf8))
        let availability = status.availability
        #expect(availability.reportsReason)
        #expect(availability.reason == .needsNode(minimum: "22.19.0", installed: "20.11.1", unreadable: false))
        #expect(availability.reason?.kind == "needs-node")
        #expect(availability.installNotice == "The official installer puts gemini in ~/.local/bin.")
        #expect(availability.installMethods.map(\.id) == ["brew", "npm"])
        #expect(availability.installMethods[1].available == false)
        #expect(availability.package == AgentPackageInfo(name: "@google/gemini-cli", version: "0.31.0", installed: true, isCli: true))
        #expect(availability.release == nil)
        #expect(availability.program == AgentProgramInfo(command: "gemini", onPath: true))
        #expect(availability.uninstallCommand == "brew uninstall gemini-cli")
        #expect(availability.balance?.state == "ready")
        #expect(availability.balance?.balances.first?.amount == 0)
        #expect(availability.providers?.first?.id == "deepseek")
        #expect(availability.providers?.first?.usage?.balances.first?.amount == 2.5)
        #expect(status.cli?.installed?.problem == .tooOld(minimum: "0.25.0"))
        #expect(status.cli?.checkable == false)
        #expect(status.cli?.method == "pnpm")
        // The fields the status read before keep decoding.
        #expect(status.state == "node-outdated")
        #expect(status.capabilities?.loadSession == true)
    }

    @Test("Every HarnessReason kind decodes, and an unknown kind does not fail the status")
    func harnessReasonKinds() throws {
        func reason(_ json: String) throws -> HarnessReason {
            try JSONDecoder().decode(HarnessReason.self, from: Data(json.utf8))
        }
        #expect(try reason(#"{"kind":"not-installed"}"#) == .notInstalled)
        #expect(try reason(#"{"kind":"needs-node","minimum":null,"installed":null,"unreadable":true}"#)
            == .needsNode(minimum: nil, installed: nil, unreadable: true))
        #expect(try reason(#"{"kind":"needs-npm"}"#) == .needsNpm)
        #expect(try reason(#"{"kind":"needs-uv","minimum":"0.5.0","installed":"0.4.2"}"#)
            == .needsUv(minimum: "0.5.0", installed: "0.4.2"))
        #expect(try reason(#"{"kind":"too-old","minimum":"1.0.30","installed":"1.0.12"}"#)
            == .tooOld(minimum: "1.0.30", installed: "1.0.12"))
        #expect(try reason(#"{"kind":"cannot-run","why":"/usr/local/bin/pi is missing or not executable"}"#)
            == .cannotRun(why: "/usr/local/bin/pi is missing or not executable"))
        #expect(try reason(#"{"kind":"no-version"}"#) == .noVersion)
        #expect(try reason(#"{"kind":"needs-rosetta"}"#) == .unknown(kind: "needs-rosetta"))

        let newer = #"{"id":"pi","name":"Pi","state":"not-installed","reason":{"kind":"needs-rosetta","arch":"x64"}}"#
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(newer.utf8))
        #expect(status.availability.reason == .unknown(kind: "needs-rosetta"))
    }

    @Test("An older host's status, without reason or install fields, decodes with none")
    func olderHostStatus() throws {
        let older = #"{"id":"codex","name":"Codex","state":"not-installed","detail":"codex was not found on PATH."}"#
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(older.utf8))
        #expect(status.availability.reportsReason == false)
        #expect(status.availability.reason == nil)
        #expect(status.availability.installMethods.isEmpty)
        #expect(status.availability.package == nil)
        #expect(status.availability.providers == nil)

        let ready = #"{"id":"codex","name":"Codex","state":"ready","reason":null}"#
        let readyStatus = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(ready.utf8))
        #expect(readyStatus.availability.reportsReason)
        #expect(readyStatus.availability.reason == nil)
    }

    @Test("AgentStatusInfo encodes its availability back into the status object")
    func statusRoundTrip() throws {
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(statusJSON.utf8))
        let encoded = try JSONEncoder().encode(status)
        let object = try JSONValue(jsonData: encoded).objectValue
        #expect(object?["reason"]?.objectValue?["kind"]?.stringValue == "needs-node")
        #expect(object?["availability"] == nil)
        #expect(object?["id"]?.stringValue == "gemini")
        let again = try JSONDecoder().decode(AgentStatusInfo.self, from: encoded)
        #expect(again == status)
    }

    // Shaped as `InstallOffer` for a package harness whose vendor also documents Homebrew and a script.
    private let offerJSON = """
    {
      "routes": [
        {
          "id": "copy", "command": null, "available": true,
          "details": {
            "what": { "kind": "npm", "name": "@moonshot-ai/kimi-cli" },
            "version": "1.4.2",
            "source": { "kind": "npm", "registry": "https://registry.npmmirror.com/" },
            "folder": "/Users/dev/.sarto/harnesses/kimi",
            "size": { "bytes": 18350080, "packageOnly": true },
            "needs": [
              { "kind": "node", "minimum": "22.19.0", "found": "24.1.0", "ok": true },
              { "kind": "npm", "ok": true }
            ]
          }
        },
        {
          "id": "brew", "command": "brew install kimi-cli", "available": false,
          "details": { "what": { "kind": "command" }, "version": null, "source": { "kind": "brew" },
                       "folder": "/opt/homebrew/bin", "size": null, "needs": [] }
        },
        {
          "id": "script", "command": "curl -fsSL https://kimi.example/install.sh | sh", "available": true,
          "details": { "what": { "kind": "command" }, "version": null,
                       "source": { "kind": "vendor", "url": "https://kimi.example/install.sh" },
                       "folder": "~/.local/bin", "size": null, "needs": [] }
        },
        {
          "id": "archive", "command": "https://cdn.example/kimi-1.4.2-darwin-arm64.tar.gz", "available": true,
          "details": { "what": { "kind": "archive", "name": "kimi-1.4.2-darwin-arm64.tar.gz" }, "version": "1.4.2",
                       "source": { "kind": "registry", "url": "https://cdn.example/kimi-1.4.2-darwin-arm64.tar.gz" },
                       "folder": "/Users/dev/.sarto/harnesses/kimi", "size": null, "needs": [] }
        },
        {
          "id": "npm", "command": "npm install -g @moonshot-ai/kimi-cli", "available": true,
          "details": { "what": { "kind": "command" }, "version": null, "source": { "kind": "npm", "registry": null },
                       "folder": null, "size": null,
                       "needs": [{ "kind": "node", "minimum": null, "found": null, "ok": false }, { "kind": "npm", "ok": false }] }
        },
        { "id": "malformed", "available": true },
        {
          "id": "copy", "command": null, "available": false, "firstStart": true,
          "details": { "what": { "kind": "uvx", "name": "kimi-cli" }, "version": "1.4.2", "source": { "kind": "pypi" },
                       "folder": null, "size": null, "needs": [{ "kind": "uv", "ok": true }] }
        }
      ]
    }
    """

    @Test("InstallOffer decodes every route, source, need and size, skipping a malformed route")
    func installOfferDecodes() throws {
        let offer = try JSONDecoder().decode(InstallOffer.self, from: Data(offerJSON.utf8))
        #expect(offer.routes.map(\.id) == ["copy", "brew", "script", "archive", "npm", "copy"])

        let copy = offer.routes[0]
        #expect(copy.method == nil)
        #expect(copy.command == nil)
        #expect(copy.installable)
        #expect(copy.details.what == .package(kind: "npm", name: "@moonshot-ai/kimi-cli"))
        #expect(copy.details.what.name == "@moonshot-ai/kimi-cli")
        #expect(copy.details.version == "1.4.2")
        #expect(copy.details.source == .npm(registry: "https://registry.npmmirror.com/"))
        #expect(copy.details.folder == "/Users/dev/.sarto/harnesses/kimi")
        #expect(copy.details.size == InstallSize(bytes: 18_350_080, packageOnly: true))
        #expect(copy.details.needs == [
            InstallNeed(kind: "node", minimum: "22.19.0", found: "24.1.0", ok: true),
            InstallNeed(kind: "npm", ok: true),
        ])

        let brew = offer.routes[1]
        #expect(brew.method == "brew")
        #expect(brew.details.what == .command)
        #expect(brew.details.source == .brew)
        #expect(!brew.installable)

        #expect(offer.routes[2].details.source == .vendor(url: "https://kimi.example/install.sh"))
        #expect(offer.routes[3].details.source == .registry(url: "https://cdn.example/kimi-1.4.2-darwin-arm64.tar.gz"))
        #expect(offer.routes[3].details.what == .package(kind: "archive", name: "kimi-1.4.2-darwin-arm64.tar.gz"))

        let npm = offer.routes[4]
        #expect(npm.details.source == .npm(registry: nil))
        #expect(npm.details.needs.allSatisfy { !$0.ok })
        #expect(!npm.installable)

        let uvx = offer.routes[5]
        #expect(uvx.firstStart)
        #expect(uvx.details.source == .pypi)
        #expect(!uvx.installable)

        let again = try JSONDecoder().decode(InstallOffer.self, from: JSONEncoder().encode(offer))
        #expect(again == offer)
    }

    @Test("agents.installOffer and agents.install send the params the host validates")
    func installRequestsEncode() async throws {
        #expect(SartoHostSession.installOfferParams(agentId: "kimi") == .object(["agentId": .string("kimi")]))
        #expect(SartoHostSession.installParams(agentId: "kimi", method: nil) == .object(["agentId": .string("kimi")]))
        #expect(SartoHostSession.installParams(agentId: "kimi", method: "copy") == .object(["agentId": .string("kimi")]))
        #expect(SartoHostSession.installParams(agentId: "opencode", method: "brew")
            == .object(["agentId": .string("opencode"), "method": .string("brew")]))

        let transport = CapturingTransport(results: ["agents.installOffer": offerJSON])
        let session = SartoHostSession(transport: transport)
        let offer = try await session.agentInstallOffer(agentId: "kimi")
        #expect(offer.routes.count == 6)
        try await session.installAgent(agentId: "kimi", method: "script")
        try await session.installAgent(agentId: "kimi")
        await session.close()

        let requests = await transport.requests
        #expect(requests.map { $0["method"]?.stringValue } == ["agents.installOffer", "agents.install", "agents.install"])
        #expect(requests[0]["params"] == .object(["agentId": .string("kimi")]))
        #expect(requests[1]["params"] == .object(["agentId": .string("kimi"), "method": .string("script")]))
        #expect(requests[2]["params"] == .object(["agentId": .string("kimi")]))
    }

    @Test("An older host's status implies an offer of its methods and Sarto's missing copy")
    func fallbackOffer() throws {
        let older = """
        {"id":"opencode","name":"OpenCode","state":"available",
         "package":{"name":"opencode-ai","version":"2.0.1","installed":false},
         "installMethods":[{"id":"brew","label":"brew install sst/tap/opencode","command":"brew install sst/tap/opencode","available":true},
                           {"id":"script","label":"curl -fsSL https://opencode.ai/install | bash","command":"curl -fsSL https://opencode.ai/install | bash","available":true}]}
        """
        let status = try JSONDecoder().decode(AgentStatusInfo.self, from: Data(older.utf8))
        let offer = InstallOffer(fallbackFor: status)
        #expect(offer.routes.map(\.id) == ["copy", "brew", "script"])
        #expect(offer.routes[0].details.what == .package(kind: "npm", name: "opencode-ai"))
        #expect(offer.routes[0].details.version == "2.0.1")
        #expect(offer.routes[1].details.source == .brew)
        #expect(offer.routes[2].details.source == .vendor(url: "curl -fsSL https://opencode.ai/install | bash"))
        #expect(offer.routes.allSatisfy { $0.installable })
    }
}
