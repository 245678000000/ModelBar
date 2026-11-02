import Foundation
import Testing
@testable import ModelBarCore

private func makeHome() throws -> AppPaths {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "modelbar agents \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AppPaths(home: url)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func read(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
}

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func context(_ paths: AppPaths, effort: ReasoningEffort = .high, bridge: BridgeTarget? = nil) throws -> SyncContext {
    let endpoint = Endpoint(
        name: "Q",
        baseURL: "https://q.example.com/v1",
        models: [ModelInfo(id: "lite", contextLength: 64_000, maxOutputTokens: 4_096, supportsReasoning: true), ModelInfo(id: "other")],
        selectedModel: "lite",
        effort: effort
    )
    let keyFile = paths.keyFile(for: endpoint.id)
    try FileSupport.writePrivate(Data("sk-secret-value".utf8), to: keyFile)
    return SyncContext(
        endpoint: endpoint,
        model: endpoint.currentModel!,
        keyFile: keyFile,
        paths: paths,
        backups: BackupStore(directory: paths.backupsDirectory),
        bridge: bridge
    )
}

@Suite struct ClaudeCodeAdapterTests {
    let adapter = ClaudeCodeAdapter()
    let original = #"{"env":{"ANTHROPIC_AUTH_TOKEN":"tok","ANTHROPIC_BASE_URL":"https://gw.example.com","DISABLE_AUTOUPDATER":"1","ANTHROPIC_DEFAULT_OPUS_MODEL_NAME":"Big"},"theme":"dark"}"#

    @Test func replacesTokenWithHelperAndRestoresEverything() throws {
        let paths = try makeHome()
        try write(original, to: paths.claudeSettings)
        let before = try read(paths.claudeSettings)
        let ctx = try context(paths)

        let captured = try #require(try adapter.apply(ctx))
        #expect(captured["env.ANTHROPIC_AUTH_TOKEN"] == "tok")
        #expect(captured["env.ANTHROPIC_BASE_URL"] == "https://gw.example.com")
        #expect(adapter.isApplied(ctx))

        let root = try read(paths.claudeSettings)
        let env = try #require(root["env"] as? [String: Any])
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(env["ANTHROPIC_BASE_URL"] as? String == "https://q.example.com")
        #expect(env["ANTHROPIC_MODEL"] as? String == "lite")
        #expect(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] as? String == "lite")
        #expect(env["CLAUDE_CODE_EFFORT_LEVEL"] as? String == "high")
        #expect(env["DISABLE_AUTOUPDATER"] as? String == "1")
        #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL_NAME"] as? String == "Big")
        #expect(root["theme"] as? String == "dark")
        let helper = try #require(root["apiKeyHelper"] as? String)
        #expect(helper.hasPrefix("/bin/cat '") && helper.contains(ctx.keyFile!.lastPathComponent))
        #expect(try !String(contentsOf: paths.claudeSettings, encoding: .utf8).contains("sk-secret-value"))

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        let after = try read(paths.claudeSettings)
        #expect(NSDictionary(dictionary: after).isEqual(to: before))
    }

    @Test func repeatedApplyKeepsOriginals() throws {
        let paths = try makeHome()
        try write(original, to: paths.claudeSettings)
        var ctx = try context(paths)
        #expect(try adapter.apply(ctx) != nil)
        ctx.endpoint.effort = .low
        #expect(try adapter.apply(ctx) == nil)
        #expect(adapter.isApplied(ctx))
    }

    @Test func bridgeUsesLocalAddressAndToken() throws {
        let paths = try makeHome()
        let token = paths.bridgeToken
        let ctx = try context(paths, bridge: BridgeTarget(baseURL: "http://127.0.0.1:47631/v1", tokenFile: token))
        _ = try adapter.apply(ctx)
        let root = try read(paths.claudeSettings)
        #expect((root["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:47631")
        #expect((root["apiKeyHelper"] as? String)?.contains("bridge.token") == true)
        #expect(adapter.isApplied(ctx))
    }

    @Test func createsSettingsWhenMissingAndRemovesThemCleanly() throws {
        let paths = try makeHome()
        let ctx = try context(paths)
        let captured = try #require(try adapter.apply(ctx))
        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(try read(paths.claudeSettings).isEmpty)
    }

    @Test func compatibilityRules() {
        var endpoint = Endpoint(name: "Q", baseURL: "https://q/v1")
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: false) == nil)
        endpoint.probe = ProbeResult(models: .ok, chat: .ok, responses: .failed, messages: .ok)
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: false) == nil)
        endpoint.probe = ProbeResult(models: .ok, chat: .ok, responses: .ok, messages: .failed)
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: false) != nil)
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: true) == nil)
        endpoint.probe = ProbeResult(models: .ok, chat: .failed, responses: .ok, messages: .failed)
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: true) != nil)
        endpoint.probe = ProbeResult(models: .ok, chat: .ok, responses: .ok)
        #expect(adapter.incompatibility(with: endpoint, bridgeEnabled: true) != nil)
    }

    @Test func oldSavedProbeWithoutMessagesStillDecodes() throws {
        let data = Data(#"{"chat":"ok","models":"ok","responses":"failed","testedAt":"2026-11-02T14:50:36Z","latencyMs":3}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe = try decoder.decode(ProbeResult.self, from: data)
        #expect(probe.messages == .unknown)
        #expect(probe.responses == .failed)
        #expect(probe.latencyMs == 3)
    }
}

@Suite struct PiAdapterTests {
    let adapter = PiAdapter()

    @Test func addsProviderAndRestoresDefaults() throws {
        let paths = try makeHome()
        let models = paths.piDirectory.appending(path: "models.json")
        let settings = paths.piDirectory.appending(path: "settings.json")
        try write(#"{"providers":{"mine":{"name":"M"}}}"#, to: models)
        try write(#"{"defaultProvider":"mine","defaultModel":"m1","defaultThinkingLevel":"low","theme":"t","enabledModels":["a"]}"#, to: settings)
        let ctx = try context(paths)

        let captured = try #require(try adapter.apply(ctx))
        #expect(captured["defaultProvider"] == "mine")
        #expect(adapter.isApplied(ctx))

        let provider = try #require((try read(models))["providers"] as? [String: Any])
        #expect(provider["mine"] != nil)
        let managed = try #require(provider["modelbar"] as? [String: Any])
        #expect(managed["api"] as? String == "openai-completions")
        #expect((managed["apiKey"] as? String)?.hasPrefix("!/bin/cat '") == true)
        let list = try #require(managed["models"] as? [[String: Any]])
        #expect(list.map { $0["id"] as? String } == ["lite", "other"])
        #expect(list[0]["contextWindow"] as? Int == 64_000)
        #expect(list[0]["reasoning"] as? Bool == true)
        let current = try read(settings)
        #expect(current["defaultProvider"] as? String == "modelbar")
        #expect(current["defaultModel"] as? String == "lite")
        #expect(current["defaultThinkingLevel"] as? String == "high")
        #expect(current["theme"] as? String == "t")
        #expect(current["enabledModels"] as? [String] == ["modelbar/lite", "a"])
        #expect(try !String(contentsOf: models, encoding: .utf8).contains("sk-secret-value"))

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        let restored = try read(settings)
        #expect(restored["defaultProvider"] as? String == "mine")
        #expect(restored["defaultModel"] as? String == "m1")
        #expect(restored["defaultThinkingLevel"] as? String == "low")
        #expect(restored["enabledModels"] as? [String] == ["a"])
        let remaining = try #require((try read(models))["providers"] as? [String: Any])
        #expect(remaining["modelbar"] == nil)
        #expect(remaining["mine"] != nil)
    }

    @Test func doesNotCreateAnAllowlistWhenThereIsNone() throws {
        let paths = try makeHome()
        let settings = paths.piDirectory.appending(path: "settings.json")
        try write(#"{"defaultProvider":"mine"}"#, to: settings)
        let ctx = try context(paths)
        _ = try adapter.apply(ctx)
        #expect((try read(settings))["enabledModels"] == nil)
        #expect(adapter.isApplied(ctx))
    }

    @Test func manualDefaultSurvivesRestore() throws {
        let paths = try makeHome()
        let settings = paths.piDirectory.appending(path: "settings.json")
        let ctx = try context(paths)
        let captured = try #require(try adapter.apply(ctx))
        try write(#"{"defaultProvider":"hand","defaultModel":"picked"}"#, to: settings)
        #expect(!adapter.isApplied(ctx))
        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect((try read(settings))["defaultModel"] as? String == "picked")
    }
}

@Suite struct GrokAdapterTests {
    let adapter = GrokAdapter()
    let original = """
    [cli]
    theme = "x"

    [models]
    default = "grok-4.7-build-fast"
    default_reasoning_effort = "xhigh"

    [mcp_servers.exa]
    command = "exa"

    """

    @Test func applyThenRestoreIsByteIdentical() throws {
        let paths = try makeHome()
        try write(original, to: paths.grokConfig)
        let ctx = try context(paths)
        let captured = try #require(try adapter.apply(ctx))
        #expect(captured["default"] == "\"grok-4.7-build-fast\"")
        #expect(adapter.isApplied(ctx))

        let text = try String(contentsOf: paths.grokConfig, encoding: .utf8)
        #expect(!text.contains("sk-secret-value"))
        let document = TOMLDocument(text: text)
        #expect(document.string(forKey: "default", inTable: "models") == "modelbar")
        #expect(document.string(forKey: "default_reasoning_effort", inTable: "models") == "xhigh")
        #expect(document.string(forKey: "auth_provider", inTable: "model.modelbar") == "modelbar")
        #expect(document.string(forKey: "command", inTable: "auth_provider.modelbar")?.hasPrefix("/bin/cat '") == true)
        #expect(document.rawValue(forKey: "context_window", inTable: "model.modelbar") == "64000")

        #expect(try adapter.apply(ctx) == nil)
        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(try String(contentsOf: paths.grokConfig, encoding: .utf8) == original)
    }

    @Test func createsModelsTableWhenMissing() throws {
        let paths = try makeHome()
        try write("[cli]\ntheme = \"x\"\n", to: paths.grokConfig)
        let ctx = try context(paths)
        let captured = try #require(try adapter.apply(ctx))
        #expect(captured.isEmpty)
        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(try String(contentsOf: paths.grokConfig, encoding: .utf8) == "[cli]\ntheme = \"x\"\n")
    }
}

@Suite struct DroidAdapterTests {
    let adapter = DroidAdapter()
    let original = #"{"customModels":[{"model":"mimo","displayName":"Xiaomi MiMo","baseUrl":"https://x/v1","apiKey":"mine","provider":"generic-chat-completion-api"}],"sessionDefaultSettings":{"model":"custom:Xiaomi-MiMo-0","reasoningEffort":"low","autonomyMode":"auto-medium"},"diffMode":"github"}"#

    @Test func appendsModelAndRestoresDefaults() throws {
        let paths = try makeHome()
        try write(original, to: paths.droidSettings)
        let before = try read(paths.droidSettings)
        let ctx = try context(paths)

        let captured = try #require(try adapter.apply(ctx))
        #expect(captured["model"] == "custom:Xiaomi-MiMo-0")
        #expect(adapter.isApplied(ctx))

        let root = try read(paths.droidSettings)
        let models = try #require(root["customModels"] as? [[String: Any]])
        #expect(models.count == 2)
        #expect(models[1]["apiKey"] as? String == "sk-secret-value")
        #expect(models[1]["provider"] as? String == "generic-chat-completion-api")
        #expect(models[1]["maxOutputTokens"] as? Int == 4_096)
        let defaults = try #require(root["sessionDefaultSettings"] as? [String: Any])
        #expect(defaults["model"] as? String == "custom:ModelBar-1")
        #expect(defaults["reasoningEffort"] as? String == "high")
        #expect(defaults["autonomyMode"] as? String == "auto-medium")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.droidSettings.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)

        #expect(try adapter.apply(ctx) == nil)
        #expect((try read(paths.droidSettings))["customModels"].map { ($0 as? [[String: Any]])?.count } == 2)

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(NSDictionary(dictionary: try read(paths.droidSettings)).isEqual(to: before))
    }
}

@Suite struct TOMLTableEditTests {
    @Test func setsInsertsAndRemovesInsideTables() {
        var document = TOMLDocument(text: "[a]\nx = 1\n\n[b]\ny = 2\n")
        document.set("x", rawValue: "9", inTable: "a")
        document.set("z", rawValue: "3", inTable: "a")
        #expect(document.text == "[a]\nx = 9\nz = 3\n\n[b]\ny = 2\n")
        document.set("z", rawValue: nil, inTable: "a")
        #expect(document.text == "[a]\nx = 9\n\n[b]\ny = 2\n")
        document.set("n", rawValue: "1", inTable: "c")
        #expect(document.string(forKey: "n", inTable: nil) == nil)
        #expect(document.rawValue(forKey: "n", inTable: "c") == "1")
    }

    @Test func removingLastKeyRemovesEmptyTable() {
        var document = TOMLDocument(text: "[a]\nx = 1\n\n[b]\ny = 2\n")
        document.set("y", rawValue: nil, inTable: "b")
        #expect(document.text == "[a]\nx = 1\n")
    }
}

@Suite struct AnthropicRequestTests {
    @Test func translatesSystemMessagesToolsAndParameters() throws {
        let translated = AnthropicBridge.translate(try json(#"""
        {"model":"lite","max_tokens":1024,"stream":true,"temperature":0.5,"stop_sequences":["END"],
         "system":[{"type":"text","text":"rules","cache_control":{"type":"ephemeral"}},{"type":"text","text":"more"}],
         "tools":[{"name":"Bash","description":"run","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}},
                  {"type":"web_search_20250305","name":"web_search"}],
         "tool_choice":{"type":"any"},
         "messages":[{"role":"user","content":"hi"},
                     {"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},
                     {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file"}]},{"type":"text","text":"next"}]}]}
        """#))
        let body = translated.body
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "tool", "user"])
        #expect(messages[0]["content"] as? String == "rules\n\nmore")
        let call = (messages[2]["tool_calls"] as? [[String: Any]])?.first
        #expect(call?["id"] as? String == "t1")
        let function = call?["function"] as? [String: Any]
        #expect(function?["name"] as? String == "Bash")
        #expect(try json(function?["arguments"] as? String ?? "")["command"] as? String == "ls")
        #expect(messages[3]["tool_call_id"] as? String == "t1")
        #expect(messages[3]["content"] as? String == "file")
        #expect(messages[4]["content"] as? String == "next")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(body["tool_choice"] as? String == "required")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["temperature"] as? Double == 0.5)
        #expect(body["stop"] as? [String] == ["END"])
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test func largeMaxTokensIsDropped() throws {
        let body = AnthropicBridge.translate(try json(#"{"model":"m","max_tokens":64000,"messages":[]}"#)).body
        #expect(body["max_tokens"] == nil)
    }

    @Test func effortComesFromRequestThenDefault() throws {
        #expect(AnthropicBridge.translate(try json(#"{"model":"m","messages":[],"output_config":{"effort":"max"}}"#), defaultEffort: "low").body["reasoning_effort"] as? String == "xhigh")
        #expect(AnthropicBridge.translate(try json(#"{"model":"m","messages":[],"thinking":{"type":"enabled","budget_tokens":2000}}"#)).body["reasoning_effort"] as? String == "low")
        #expect(AnthropicBridge.translate(try json(#"{"model":"m","messages":[],"thinking":{"type":"enabled","budget_tokens":30000}}"#)).body["reasoning_effort"] as? String == "high")
        #expect(AnthropicBridge.translate(try json(#"{"model":"m","messages":[]}"#), defaultEffort: "medium").body["reasoning_effort"] as? String == "medium")
        #expect(AnthropicBridge.translate(try json(#"{"model":"m","messages":[]}"#)).body["reasoning_effort"] == nil)
    }

    @Test func imagesAndErrorsInToolResults() throws {
        let messages = AnthropicBridge.translate(try json(#"""
        {"model":"m","messages":[
          {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}}]},
          {"role":"user","content":[
            {"type":"tool_result","tool_use_id":"a","is_error":true,"content":[{"type":"text","text":"boom"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA"}}]},
            {"type":"image","source":{"type":"url","url":"https://x/y.png"}}
          ]}
        ]}
        """#)).body["messages"] as? [[String: Any]]
        let list = try #require(messages)
        #expect(list.map { $0["role"] as? String } == ["assistant", "tool", "user", "user"])
        #expect(list[0]["content"] is NSNull)
        #expect(list[1]["content"] as? String == "Error: boom")
        let toolImage = (list[2]["content"] as? [[String: Any]])?.last?["image_url"] as? [String: Any]
        #expect(toolImage?["url"] as? String == "data:image/png;base64,AA")
        let userImage = (list[3]["content"] as? [[String: Any]])?.first?["image_url"] as? [String: Any]
        #expect(userImage?["url"] as? String == "https://x/y.png")
    }

    @Test func onlyOurOwnThinkingIsSentBack() throws {
        let ours = AnthropicBridge.translate(try json(#"""
        {"model":"m","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"modelbar"},{"type":"text","text":"x"}]}]}
        """#)).body["messages"] as? [[String: Any]]
        #expect(ours?.first?["reasoning_content"] as? String == "hmm")
        let theirs = AnthropicBridge.translate(try json(#"""
        {"model":"m","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"abc"},{"type":"text","text":"x"}]}]}
        """#)).body["messages"] as? [[String: Any]]
        #expect(theirs?.first?["reasoning_content"] == nil)
    }
}

@Suite struct AnthropicStreamTests {
    private func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    @Test func textStreamFollowsAnthropicEventOrder() throws {
        let writer = AnthropicStreamWriter(model: "m", routes: [:])
        var events = writer.start()
        events += writer.consume(chunk(["content": "He"]))
        events += writer.consume(chunk(["content": "llo"], finish: "stop"))
        events += writer.consume(["choices": [], "usage": ["prompt_tokens": 7, "completion_tokens": 2]])
        events += writer.finish()
        #expect(events.map(\.name) == [
            "message_start", "content_block_start", "content_block_delta", "content_block_delta",
            "content_block_stop", "message_delta", "message_stop",
        ])
        let delta = events[5].payload
        #expect((delta["delta"] as? [String: Any])?["stop_reason"] as? String == "end_turn")
        #expect((delta["usage"] as? [String: Any])?["input_tokens"] as? Int == 7)
        #expect((writer.finalObject["content"] as? [[String: Any]])?.first?["text"] as? String == "Hello")
    }

    @Test func thinkingTextAndToolsBecomeSeparateBlocks() throws {
        let routes = ["Bash": ToolRoute(kind: .function, namespace: nil, name: "Bash")]
        let writer = AnthropicStreamWriter(model: "m", routes: routes)
        var events = writer.consume(chunk(["reasoning_content": "think"]))
        events += writer.consume(chunk(["content": "run"]))
        events += writer.consume(chunk(["tool_calls": [["index": 0, "id": "c1", "function": ["name": "Bash", "arguments": "{\"command\":"]]]]))
        events += writer.consume(chunk(["tool_calls": [["index": 0, "function": ["arguments": "\"ls\"}"]]]], finish: "tool_calls"))
        events += writer.finish()

        let starts = events.filter { $0.name == "content_block_start" }.compactMap { $0.payload["content_block"] as? [String: Any] }
        #expect(starts.map { $0["type"] as? String } == ["thinking", "text", "tool_use"])
        #expect(starts[2]["id"] as? String == "c1")
        let indexes = events.filter { $0.name == "content_block_start" }.compactMap { $0.payload["index"] as? Int }
        #expect(indexes == [0, 1, 2])
        let deltas = events.filter { $0.name == "content_block_delta" }.compactMap { $0.payload["delta"] as? [String: Any] }
        #expect(deltas.contains { $0["type"] as? String == "signature_delta" && $0["signature"] as? String == "modelbar" })
        #expect(deltas.last?["partial_json"] as? String == "{\"command\":\"ls\"}")
        let stop = events.first { $0.name == "message_delta" }?.payload["delta"] as? [String: Any]
        #expect(stop?["stop_reason"] as? String == "tool_use")
        let tool = (writer.finalObject["content"] as? [[String: Any]])?.last
        #expect((tool?["input"] as? [String: Any])?["command"] as? String == "ls")
    }

    @Test func mapsLengthAndEmptyAndErrors() {
        let long = AnthropicStreamWriter(model: "m", routes: [:])
        _ = long.consume(chunk(["content": "x"], finish: "length"))
        let events = long.finish()
        #expect((events.first { $0.name == "message_delta" }?.payload["delta"] as? [String: Any])?["stop_reason"] as? String == "max_tokens")

        let empty = AnthropicStreamWriter(model: "m", routes: [:])
        #expect(empty.finish().last?.name == "error")
        #expect(empty.didFail)
    }
}

@Suite struct KeyFileReuseTests {
    private struct FailingKeyStore: KeyStore {
        func key(for id: UUID) throws -> String? { throw ConfigError("不应该读钥匙串") }
        func setKey(_ key: String?, for id: UUID) throws {}
    }

    @Test func existingKeyFileAvoidsReadingTheKeychain() async throws {
        let paths = try makeHome()
        try FileManager.default.createDirectory(at: paths.opencodeDirectory, withIntermediateDirectories: true)
        var state = AppState()
        let endpoint = Endpoint(name: "A", baseURL: "https://a/v1", models: [ModelInfo(id: "m")], selectedModel: "m")
        state.endpoints = [endpoint]
        state.activeEndpointID = endpoint.id
        state.enabledTools = [.opencode]
        try FileSupport.writePrivate(Data("sk-existing".utf8), to: paths.keyFile(for: endpoint.id))

        let report = await SyncEngine(paths: paths, keyStore: FailingKeyStore()).sync(state)
        #expect(report.statuses[.opencode] == .synced)
        #expect(try String(contentsOf: paths.keyFile(for: endpoint.id), encoding: .utf8) == "sk-existing")
    }

    @Test func missingKeyFileIsWrittenFromTheKeyStore() async throws {
        let paths = try makeHome()
        try FileManager.default.createDirectory(at: paths.opencodeDirectory, withIntermediateDirectories: true)
        let keys = InMemoryKeyStore()
        var state = AppState()
        let endpoint = Endpoint(name: "A", baseURL: "https://a/v1", models: [ModelInfo(id: "m")], selectedModel: "m")
        try keys.setKey("sk-new", for: endpoint.id)
        state.endpoints = [endpoint]
        state.activeEndpointID = endpoint.id
        state.enabledTools = [.opencode]
        _ = await SyncEngine(paths: paths, keyStore: keys).sync(state)
        #expect(try String(contentsOf: paths.keyFile(for: endpoint.id), encoding: .utf8) == "sk-new")
    }
}

@Suite struct MultiToolBridgeTests {
    private final class NoopControl: BridgeServiceControl, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var uninstalls: Int { lock.withLock { count } }
        func install(executable: URL, configFile: URL, logFile: URL) throws {}
        func restart() throws {}
        func uninstall() { lock.withLock { count += 1 } }
    }

    private func setup() throws -> (AppPaths, SyncEngine, NoopControl, AppState) {
        let paths = try makeHome()
        let executable = paths.home.appending(path: "ModelBarGateway")
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        for binary in ["claude", "codex"] {
            let file = paths.home.appending(path: ".local/bin/\(binary)")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        let control = NoopControl()
        let keys = InMemoryKeyStore()
        let manager = BridgeManager(paths: paths, executable: executable, control: control, health: { _ in BridgeInfo.version }, isPortFree: { _ in true })
        let engine = SyncEngine(paths: paths, keyStore: keys, bridge: manager)
        var state = AppState()
        let endpoint = Endpoint(
            name: "Q",
            baseURL: "https://q.example.com/v1",
            models: [ModelInfo(id: "lite")],
            selectedModel: "lite",
            probe: ProbeResult(models: .ok, chat: .ok, responses: .failed, messages: .failed)
        )
        try keys.setKey("sk-up", for: endpoint.id)
        state.endpoints = [endpoint]
        state.activeEndpointID = endpoint.id
        state.enabledTools = [.claudeCode, .codex]
        state.bridgeEnabled = true
        return (paths, engine, control, state)
    }

    @Test func bothToolsShareTheBridgeAndServiceStopsWithTheLastOne() async throws {
        var (paths, engine, control, state) = try setup()
        let report = await engine.sync(state)
        #expect(report.statuses[.claudeCode] == .synced)
        #expect(report.statuses[.codex] == .synced)
        let claude = try read(paths.claudeSettings)
        #expect((claude["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:\(BridgeInfo.defaultPort)")
        state.originals[.codex] = report.originals[.codex]
        state.originals[.claudeCode] = report.originals[.claudeCode]

        _ = await engine.disable(.codex, state: state)
        state.enabledTools = [.claudeCode]
        #expect(control.uninstalls == 0)
        #expect(FileManager.default.fileExists(atPath: paths.bridgeConfig.path))

        _ = await engine.disable(.claudeCode, state: state)
        #expect(control.uninstalls == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.bridgeConfig.path))
    }

    @Test func effortReachesTheBridgeConfig() async throws {
        var (paths, engine, _, state) = try setup()
        state.endpoints[0].effort = .high
        _ = await engine.sync(state)
        #expect(try BridgeConfig.load(from: paths.bridgeConfig).defaultEffort == "high")
    }
}
