import Foundation
import Testing
@testable import SartoProtocol

private actor RecordingPortTransport: SartoPortTransport {
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let reply: @Sendable (_ id: Double) -> JSONValue
    private(set) var requests: [[String: JSONValue]] = []

    init(reply: @escaping @Sendable (_ id: Double) -> JSONValue) {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.stream = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
        self.reply = reply
    }

    nonisolated var messages: AsyncThrowingStream<Data, Error> { stream }

    func sendJSON(_ data: Data) async throws {
        let request = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
        requests.append(request)
        let id = request["id"]?.doubleValue ?? 0
        continuation.yield(try JSONEncoder().encode(reply(id)))
    }

    func close() async {
        continuation.finish()
    }
}

private func choice(_ value: String, _ name: String, shownAs: String? = nil, modelId: String? = nil, older: Bool? = nil, group: String? = nil) -> ConfigChoice {
    ConfigChoice(value: value, name: name, group: group, older: older, shownAs: shownAs, modelId: modelId)
}

/// Claude Code's model option as `src/agent-host/agent-options.test.ts` builds it.
private let claudeChoices: [ConfigChoice] = [
    choice("default", "Default (recommended)", shownAs: "opus"),
    choice("opus", "Opus 5.5"),
    choice("sonnet", "Sonnet 5.5"),
    choice("haiku", "Haiku 5.5"),
    choice("claude-fable-5-2", "Fable 5.2"),
    choice("claude-opus-4-8", "Opus 4.8"),
]

/// Pi's model option: `provider/name` names, values `provider/id`, models from several providers.
private let piChoices: [ConfigChoice] = [
    choice("anthropic/claude-opus-5-5", "anthropic/Claude Opus 5.5"),
    choice("anthropic/claude-opus-4-8", "anthropic/Claude Opus 4.8"),
    choice("deepseek/deepseek-v4", "deepseek/DeepSeek V4"),
    choice("deepseek/deepseek-v4-flash", "deepseek/DeepSeek V4 Flash"),
    choice("openai/gpt-6.2", "openai/GPT-6.2"),
    choice("openai/gpt-6.1", "openai/GPT-6.1"),
]

@Suite("Model menu: pinned models, agents.pinModel and the menus' lists")
struct ModelMenuProtocolTests {
    @Test("agents.options decodes pinned and recent models shaped as AgentOptions")
    func agentOptionsDecodePinnedAndRecent() throws {
        let json = Data("""
        [
          {
            "agentId": "claude-code",
            "config": [
              {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "value": "default",
                "choices": [
                  { "value": "default", "name": "Default (recommended)", "shownAs": "opus" },
                  { "value": "opus", "name": "Opus 5.5" },
                  { "value": "sonnet", "name": "Sonnet 5.5" }
                ]
              }
            ],
            "levels": {},
            "remembered": { "model": "sonnet" },
            "observedAt": 1,
            "pinned": ["sonnet", "opus"],
            "recent": ["haiku", "sonnet"],
            "startMode": "default"
          },
          {
            "agentId": "codex",
            "config": [],
            "levels": {},
            "remembered": {},
            "observedAt": 2
          }
        ]
        """.utf8)
        let options = try JSONDecoder().decode([AgentOptionsInfo].self, from: json)
        #expect(options[0].pinned == ["sonnet", "opus"])
        #expect(options[0].recent == ["haiku", "sonnet"])
        #expect(options[0].keptModels == KeptModels(pinned: ["sonnet", "opus"], recent: ["haiku", "sonnet"]))
        #expect(options[0].isPinned("opus"))
        #expect(!options[0].isPinned("haiku"))
        #expect(options[0].startMode == "default")
        // An older host sends neither list.
        #expect(options[1].pinned == nil)
        #expect(options[1].recent == nil)
        #expect(options[1].keptModels == KeptModels())
    }

    @Test("agent.options events carry the pinned list the host keeps after agents.pinModel")
    func agentOptionsEventCarriesPins() {
        let envelope = Data("""
        {
          "type": "event",
          "event": {
            "type": "agent.options",
            "options": {
              "agentId": "opencode",
              "config": [],
              "levels": {},
              "remembered": {},
              "observedAt": 1700000000300,
              "pinned": ["deepseek/deepseek-v4-pro"],
              "recent": ["deepseek/deepseek-v4-pro", "openai/gpt-6.2"]
            }
          }
        }
        """.utf8)
        guard case .agentOptions(let options)? = HostEvent.decode(fromEnvelopeData: envelope) else {
            Issue.record("Expected HostEvent.agentOptions")
            return
        }
        #expect(options.agentId == "opencode")
        #expect(options.pinned == ["deepseek/deepseek-v4-pro"])
        #expect(options.recent == ["deepseek/deepseek-v4-pro", "openai/gpt-6.2"])
    }

    @Test("Pinned and recent lists keep strings once and drop what is not a list of models")
    func keptListsDecodeTolerantly() throws {
        let json = Data("""
        [
          { "agentId": "a", "config": [], "pinned": ["a", "b", "a", 7, "", null, "c"], "recent": ["x"] },
          { "agentId": "b", "config": [], "pinned": "opus", "recent": [null, 3] },
          { "agentId": "c", "config": [], "pinned": null, "recent": {} }
        ]
        """.utf8)
        let options = try JSONDecoder().decode([AgentOptionsInfo].self, from: json)
        #expect(options[0].pinned == ["a", "b", "c"])
        #expect(options[0].recent == ["x"])
        #expect(options[1].pinned == nil)
        #expect(options[1].recent == nil)
        #expect(options[2].pinned == nil)
        #expect(options[2].recent == nil)
    }

    @Test("Pinned and recent lists survive an encode and decode")
    func keptListsRoundTrip() throws {
        let options = AgentOptionsInfo(agentId: "pi", pinned: ["a/b"], recent: ["a/b", "c/d"])
        let decoded = try JSONDecoder().decode(AgentOptionsInfo.self, from: JSONEncoder().encode(options))
        #expect(decoded == options)
    }

    @Test("agents.pinModel sends the agent, the model value and the pinned flag")
    func pinModelEncodesParams() async throws {
        let transport = RecordingPortTransport { id in
            .object(["type": .string("response"), "id": .number(id), "result": .null])
        }
        let session = SartoHostSession(transport: transport)
        try await session.pinModel(agentId: "opencode", model: "deepseek/deepseek-v4-pro", pinned: true)
        try await session.pinModel(agentId: "claude-code", model: "opus", pinned: false)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0]["method"] == .string("agents.pinModel"))
        #expect(requests[0]["params"] == .object([
            "agentId": .string("opencode"),
            "model": .string("deepseek/deepseek-v4-pro"),
            "pinned": .bool(true),
        ]))
        #expect(requests[1]["params"] == .object([
            "agentId": .string("claude-code"),
            "model": .string("opus"),
            "pinned": .bool(false),
        ]))
        await session.close()

        let encoded = try JSONEncoder().encode(AgentPinModelParams(agentId: "codex", model: "gpt-6.2-sol", pinned: true))
        let object = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(object == AgentPinModelParams(agentId: "codex", model: "gpt-6.2-sol", pinned: true).jsonValue)
    }

    @Test("agents.pinModel surfaces the host's refusal of a fifth pin")
    func pinModelSurfacesConflict() async throws {
        let transport = RecordingPortTransport { id in
            .object([
                "type": .string("error"),
                "id": .number(id),
                "error": .object([
                    "code": .string("conflict"),
                    "message": .string("Up to 4 models can be pinned; unpin one first"),
                ]),
            ])
        }
        let session = SartoHostSession(transport: transport)
        await #expect(throws: PortRPCError.self) {
            try await session.pinModel(agentId: "claude-code", model: "haiku", pinned: true)
        }
        await session.close()
    }

    @Test("Pins go after the ones pinned before, a fifth is refused, and none left is no list")
    func pinnedModelsFollowTheHostRule() throws {
        var options = AgentOptionsInfo(agentId: "claude-code")
        options = options.replacingPinned(try options.pinnedModels(setting: "sonnet", pinned: true))
        options = options.replacingPinned(try options.pinnedModels(setting: "opus", pinned: true))
        options = options.replacingPinned(try options.pinnedModels(setting: "sonnet", pinned: true))
        #expect(options.pinned == ["sonnet", "opus"])
        options = options.replacingPinned(try options.pinnedModels(setting: "haiku", pinned: true))
        options = options.replacingPinned(try options.pinnedModels(setting: "claude-fable-5-2", pinned: true))
        #expect(throws: ModelPinRefusal.full(limit: 4)) {
            try options.pinnedModels(setting: "claude-opus-4-8", pinned: true)
        }
        // Pinning one already pinned, or unpinning, is never refused.
        #expect(try options.pinnedModels(setting: "opus", pinned: true) == ["sonnet", "opus", "haiku", "claude-fable-5-2"])
        options = options.replacingPinned(try options.pinnedModels(setting: "opus", pinned: false))
        #expect(options.pinned == ["sonnet", "haiku", "claude-fable-5-2"])
        for model in ["sonnet", "haiku", "claude-fable-5-2"] {
            options = options.replacingPinned(try options.pinnedModels(setting: model, pinned: false))
        }
        #expect(options.pinned == nil)
    }

    @Test("One provider: the current generation leads, largest family first, older versions fold")
    func mainListFromOneProvider() {
        let lists = ModelMenuLists(choices: claudeChoices, current: "default")
        #expect(lists.all.map(\.value) == ["opus", "sonnet", "haiku", "claude-fable-5-2", "claude-opus-4-8"])
        #expect(!lists.several)
        #expect(lists.main.map(\.value) == ["claude-fable-5-2", "opus", "sonnet", "haiku"])
        #expect(lists.more.map(\.value) == ["claude-opus-4-8"])
        #expect(lists.all.first { $0.value == "claude-opus-4-8" }?.older == true)
        #expect(lists.chosen?.value == "opus")
        #expect(lists.extra == nil)
        #expect(lists.defaultValue == "opus")
        #expect(lists.numbered(1)?.value == "claude-fable-5-2")
        #expect(lists.numbered(4)?.value == "haiku")
        #expect(lists.numbered(5) == nil)
        #expect(lists.numbered(0) == nil)
    }

    @Test("Pinned models lead in the order pinned, and a chosen model left out follows the main list")
    func pinnedModelsLeadTheMainList() {
        let lists = ModelMenuLists(
            choices: claudeChoices,
            current: "haiku",
            kept: KeptModels(pinned: ["claude-opus-4-8", "sonnet", "gone", "sonnet"])
        )
        #expect(lists.main.map(\.value) == ["claude-opus-4-8", "sonnet", "claude-fable-5-2", "opus"])
        #expect(lists.more.map(\.value) == ["haiku"])
        #expect(lists.chosen?.value == "haiku")
        #expect(lists.extra?.value == "haiku")
        #expect(lists.moreInOrder.map(\.value) == ["haiku"])
    }

    @Test("Several providers: pins, then recent models, then the agent's current models")
    func mainListFromSeveralProviders() {
        let lists = ModelMenuLists(
            choices: piChoices,
            current: "openai/gpt-6.1",
            kept: KeptModels(
                pinned: ["deepseek/deepseek-v4-flash"],
                recent: ["openai/gpt-6.2", "deepseek/deepseek-v4"]
            )
        )
        #expect(lists.several)
        #expect(lists.all.map(\.provider) == ["anthropic", "anthropic", "deepseek", "deepseek", "openai", "openai"])
        #expect(lists.all.first?.name == "Claude Opus 5.5")
        #expect(lists.main.map(\.value) == [
            "deepseek/deepseek-v4-flash",
            "anthropic/claude-opus-5-5",
            "deepseek/deepseek-v4",
            "openai/gpt-6.2",
        ])
        #expect(lists.more.map(\.value) == ["anthropic/claude-opus-4-8", "openai/gpt-6.1"])
        #expect(lists.extra?.value == "openai/gpt-6.1")
        let groups = ModelMenuLists.familyGroups(lists.more)
        #expect(groups.map(\.provider) == ["anthropic", "openai"])
        #expect(groups[0].items.map(\.name) == ["Claude Opus"])
    }

    @Test("A search finds models by provider, name or id, every word, each family's newest first")
    func searchByProviderNameAndId() {
        let lists = ModelMenuLists(choices: piChoices, current: nil)
        let deep = lists.search("deep")
        #expect(deep.map(\.provider) == ["deepseek"])
        #expect(deep[0].items.map(\.value) == ["deepseek/deepseek-v4", "deepseek/deepseek-v4-flash"])
        let opus = lists.search("  opus ANTHROPIC ")
        #expect(opus.map(\.provider) == ["anthropic"])
        #expect(opus[0].items.map(\.value) == ["anthropic/claude-opus-5-5", "anthropic/claude-opus-4-8"])
        #expect(lists.search("nothing-like-it").isEmpty)
        #expect(lists.search("").flatMap(\.items).count == piChoices.count)
    }

    @Test("Versions read from names and ids: dashes join an id's numbers, dates and builds are no versions")
    func versionsFromNamesAndIds() {
        let haiku = ModelMenuLists.readVersion("claude-haiku-4-5-20251001", id: true)
        #expect(haiku?.version == "4.5")
        #expect(haiku?.words == ["claude", "haiku"])
        let qwen = ModelMenuLists.readVersion("Qwen3.6 Coder")
        #expect(qwen?.version == "3.6")
        #expect(qwen?.words == ["Qwen", "Coder"])
        #expect(ModelMenuLists.readVersion("DeepSeek V4")?.version == "4")
        #expect(ModelMenuLists.readVersion("Build 1017") == nil)

        let qualified = ModelMenuLists.readModel(choice("gpt-6.2-sol", "GPT-6.2-Sol · Codex"), order: 0)
        #expect(qualified.version == [6, 2])
        #expect(qualified.familyName == "GPT Sol · Codex")
        let fromId = ModelMenuLists.readModel(choice("x", "Mystery", modelId: "vendor/mystery-2-1"), order: 0)
        #expect(fromId.versionName == "2.1")
        #expect(fromId.familyName == "Mystery")
    }

    @Test("A Default on a row of its own names the model it runs, and an agent's older mark holds alone")
    func defaultRowAndOlderMarks() {
        let choices = [
            choice("default", "Default (recommended)", modelId: "claude-opus-5-5"),
            choice("opus", "Opus 5.5", modelId: "claude-opus-5-5"),
            choice("legacy", "Legacy Model", older: true),
            choice("sonnet-4-6", "Sonnet 4.6", older: true),
            choice("sonnet-5-5", "Sonnet 5.5", older: true),
        ]
        let lists = ModelMenuLists(choices: choices, current: "default")
        let defaultRead = lists.all[0]
        #expect(defaultRead.isDefault)
        #expect(lists.defaultUses(defaultRead) == "Opus 5.5")
        #expect(lists.defaultValue == nil)
        #expect(lists.all.first { $0.value == "legacy" }?.older == true)
        #expect(lists.all.first { $0.value == "sonnet-4-6" }?.older == true)
        // The versions show Sonnet 5.5 is its family's newest, which outweighs the agent's mark.
        #expect(lists.all.first { $0.value == "sonnet-5-5" }?.older == false)
        #expect(lists.main.map(\.value) == ["opus", "sonnet-5-5", "default"])

        let allOlder = ModelMenuLists(choices: [choice("a", "Alpha", older: true), choice("b", "Beta", older: true)], current: "b")
        #expect(allOlder.main.map(\.value) == ["a", "b"])
    }
}
