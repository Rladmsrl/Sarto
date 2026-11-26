import Foundation
import XCTest
@testable import SartoProtocol

final class ExtensionsProtocolTests: XCTestCase {
    func testTerminalInfoDecodesCollaborationFieldsAndBackwardsCompatibility() throws {
        let richJson = """
        {
          "id": "term-42",
          "projectPath": "/Users/dev/project",
          "sessionId": "sess-9",
          "title": "Dev Server",
          "name": "Dev Server",
          "namedBy": "user",
          "owner": { "agentId": "claude-code", "sessionId": "sess-9", "fromReply": false },
          "agentAllowed": true,
          "agentAsks": false,
          "control": { "kind": "agent", "acting": true },
          "waiting": "password",
          "shell": "/bin/zsh",
          "busy": true,
          "exitCode": null,
          "createdAt": 1730000000000
        }
        """
        let rich = try JSONDecoder().decode(TerminalInfo.self, from: Data(richJson.utf8))
        XCTAssertEqual(rich.id, "term-42")
        XCTAssertEqual(rich.namedBy, "user")
        XCTAssertEqual(rich.owner?.agentId, "claude-code")
        XCTAssertEqual(rich.owner?.sessionId, "sess-9")
        XCTAssertEqual(rich.owner?.fromReply, false)
        XCTAssertTrue(rich.agentAllowed)
        XCTAssertFalse(rich.agentAsks)
        XCTAssertEqual(rich.control.kind, "agent")
        XCTAssertTrue(rich.control.isAgent)
        XCTAssertEqual(rich.control.acting, true)
        XCTAssertEqual(rich.waiting, "password")
        XCTAssertTrue(rich.isWaitingForPassword)

        let minimalJson = """
        {
          "id": "term-1",
          "projectPath": "/tmp",
          "title": "zsh",
          "shell": "/bin/zsh"
        }
        """
        let minimal = try JSONDecoder().decode(TerminalInfo.self, from: Data(minimalJson.utf8))
        XCTAssertEqual(minimal.id, "term-1")
        XCTAssertNil(minimal.namedBy)
        XCTAssertNil(minimal.owner)
        XCTAssertFalse(minimal.agentAllowed)
        XCTAssertEqual(minimal.control, .idle)
        XCTAssertFalse(minimal.isWaitingForPassword)
    }

    func testHostEventsDecodeSettingsOpenMemoryAndMarketplaceEvents() throws {
        let settingsEnvelope = """
        {"type":"event","event":{"type":"settings.open","section":"appearance","item":null,"row":"appearance.color-mode"}}
        """
        XCTAssertEqual(
            HostEvent.decode(fromEnvelopeData: Data(settingsEnvelope.utf8)),
            .settingsOpen(section: "appearance", item: nil, row: "appearance.color-mode")
        )

        let memoryEnvelope = """
        {"type":"event","event":{"type":"memory.changed"}}
        """
        XCTAssertEqual(HostEvent.decode(fromEnvelopeData: Data(memoryEnvelope.utf8)), .memoryChanged)

        let keysEnvelope = """
        {"type":"event","event":{"type":"market.keysChanged"}}
        """
        XCTAssertEqual(HostEvent.decode(fromEnvelopeData: Data(keysEnvelope.utf8)), .marketKeysChanged)

        let connEnvelope = """
        {"type":"event","event":{"type":"market.connectionChanged","serverId":"io.github/github","connection":{"state":"connected","account":"octocat"},"loginId":"login-1"}}
        """
        let decodedConn = HostEvent.decode(fromEnvelopeData: Data(connEnvelope.utf8))
        XCTAssertEqual(
            decodedConn,
            .marketConnectionChanged(
                serverId: "io.github/github",
                connection: MarketConnectionInfo(state: "connected", account: "octocat"),
                loginId: "login-1",
                error: nil
            )
        )
    }

    func testMarketServerAgentsSerializationAndSuggestedName() throws {
        let allAgentsJson = """
        {
          "id": "io.github/github-mcp-server",
          "name": "github",
          "title": "GitHub",
          "source": "registry",
          "version": "1.2.0",
          "spec": {
            "type": "http",
            "transport": "streamable-http",
            "url": "https://api.githubcopilot.com/mcp/",
            "headers": [],
            "oauth": { "flow": "device" }
          },
          "agents": "all",
          "on": true
        }
        """
        let serverAll = try JSONDecoder().decode(MarketServerInfo.self, from: Data(allAgentsJson.utf8))
        XCTAssertTrue(serverAll.agentsAll)
        XCTAssertEqual(serverAll.agentIds, [])
        XCTAssertEqual(serverAll.spec.oauth?.flow, "device")
        XCTAssertEqual(serverAll.toJSONValue().objectValue?["agents"], .string("all"))

        let scopedJson = """
        {
          "id": "manual:123",
          "name": "local-fs",
          "title": "Local FS",
          "source": "manual",
          "version": null,
          "spec": {
            "type": "stdio",
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem"],
            "env": [{"name": "ROOT_DIR", "input": true, "secret": false, "required": true}]
          },
          "agents": ["claude-code", "codex"],
          "on": false
        }
        """
        let serverScoped = try JSONDecoder().decode(MarketServerInfo.self, from: Data(scopedJson.utf8))
        XCTAssertFalse(serverScoped.agentsAll)
        XCTAssertEqual(serverScoped.agentIds, ["claude-code", "codex"])
        XCTAssertEqual(serverScoped.spec.inputs.count, 1)
        XCTAssertEqual(
            serverScoped.toJSONValue().objectValue?["agents"],
            .array([.string("claude-code"), .string("codex")])
        )

        // Reserved "sarto" and collisions should auto-suffix
        XCTAssertEqual(MarketServerInfo.suggestedName(from: "sarto", existing: []), "sarto-2")
        XCTAssertEqual(
            MarketServerInfo.suggestedName(from: "io.github/github-mcp-server", existing: [serverAll]),
            "github-2"
        )
    }

    func testHostSettingsSnapshotDecodesMcpAndMarketplaceMcp() throws {
        let json = """
        {
          "mcp": { "sarto": { "off": ["codex"] } },
          "marketplace": {
            "mcp": [
              {
                "id": "manual:abc",
                "name": "linear",
                "title": "Linear",
                "source": "manual",
                "version": null,
                "spec": {
                  "type": "http",
                  "transport": "streamable-http",
                  "url": "https://mcp.linear.app/mcp",
                  "headers": []
                },
                "agents": "all",
                "on": true
              }
            ]
          }
        }
        """
        let val = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let snap = HostSettingsSnapshot.from(json: val)
        XCTAssertEqual(snap.mcpSartoOff, ["codex"])
        XCTAssertEqual(snap.marketplaceMcp.count, 1)
        XCTAssertEqual(snap.marketplaceMcp.first?.name, "linear")
    }

    func testSearchContextImportAndPluginsModelsDecode() throws {
        let searchJson = """
        {
          "hits": [
            {"sessionId": "s1", "pos": 4, "entryId": "e4", "role": "assistant", "snippet": "Found token budget", "matches": 2}
          ],
          "indexing": {"done": 12, "total": 20}
        }
        """
        let search = try JSONDecoder().decode(SessionSearchResultInfo.self, from: Data(searchJson.utf8))
        XCTAssertEqual(search.hits.count, 1)
        XCTAssertEqual(search.hits.first?.matches, 2)
        XCTAssertEqual(search.indexing?.done, 12)

        let ctxJson = """
        {
          "model": "claude-opus-4-6",
          "used": 42000,
          "size": 200000,
          "categories": [
            {"name": "System prompt", "tokens": 6000, "share": 0.03},
            {"name": "Messages", "tokens": 36000, "share": 0.18}
          ],
          "lists": [],
          "observedAt": 1730000000000
        }
        """
        let ctx = try JSONDecoder().decode(ContextBreakdownInfo.self, from: Data(ctxJson.utf8))
        XCTAssertEqual(ctx.categories.count, 2)
        XCTAssertEqual(ctx.used, 42000)

        let importJson = """
        {
          "sessions": [
            {"acpSessionId": "cli-1", "title": "Refactor router", "updatedAt": "2026-11-22T10:00:00Z", "imported": false, "held": true}
          ],
          "nextCursor": "cursor-2"
        }
        """
        let page = try JSONDecoder().decode(ImportableSessionsPageInfo.self, from: Data(importJson.utf8))
        XCTAssertEqual(page.sessions.count, 1)
        XCTAssertEqual(page.sessions.first?.held, true)
        XCTAssertEqual(page.nextCursor, "cursor-2")

        let pluginsJson = """
        {
          "catalog": [
            {"id": "frontend-design@official", "harness": "claude-code", "name": "frontend-design", "title": "Frontend Design", "description": "UI design skills", "official": true, "marketplace": "official", "featured": true}
          ],
          "installed": [
            {"id": "frontend-design@official", "harness": "claude-code", "agentId": "claude-code", "version": "1.0.0", "scope": "user", "enabled": true}
          ],
          "marketplaces": [
            {"harness": "claude-code", "agentId": "claude-code", "name": "official", "source": "anthropics/plugins", "official": true}
          ],
          "errors": []
        }
        """
        let plugins = try JSONDecoder().decode(MarketPluginsInfo.self, from: Data(pluginsJson.utf8))
        XCTAssertEqual(plugins.catalog.count, 1)
        XCTAssertEqual(plugins.installed.first?.pluginId, "frontend-design@official")
        XCTAssertEqual(plugins.marketplaces.first?.official, true)
    }
}
