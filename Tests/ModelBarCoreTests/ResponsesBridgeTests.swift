import Foundation
import Testing
@testable import ModelBarCore

private func json(_ text: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func messages(_ translated: TranslatedRequest) -> [[String: Any]] {
    translated.body["messages"] as? [[String: Any]] ?? []
}

@Suite struct RequestTranslationTests {
    @Test func mergesLeadingDeveloperMessagesAndKeepsUserText() throws {
        let translated = ResponsesBridge.translate(try json(#"""
        {"model":"m","stream":true,"input":[
          {"type":"message","role":"developer","content":[{"type":"input_text","text":"a"}]},
          {"type":"message","role":"developer","content":[{"type":"input_text","text":"b"},{"type":"input_text","text":"c"}]},
          {"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}
        ]}
        """#))
        let list = messages(translated)
        #expect(list.count == 2)
        #expect(list[0]["role"] as? String == "system")
        #expect(list[0]["content"] as? String == "a\n\nb\n\nc")
        #expect(list[1]["role"] as? String == "user")
        #expect(list[1]["content"] as? String == "hello")
        #expect(translated.isStreaming)
        #expect((translated.body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test func instructionsBecomeSystemAndMidConversationDeveloperBecomesUser() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","instructions":"rules","input":[
          {"type":"message","role":"user","content":"hi"},
          {"type":"message","role":"developer","content":[{"type":"input_text","text":"later"}]}
        ]}
        """#)))
        #expect(list.map { $0["role"] as? String } == ["system", "user", "user"])
        #expect(list[2]["content"] as? String == "later")
    }

    @Test func plainStringInputBecomesUserMessage() throws {
        let list = messages(ResponsesBridge.translate(try json(#"{"model":"m","input":"ping"}"#)))
        #expect(list.first?["role"] as? String == "user")
        #expect(list.first?["content"] as? String == "ping")
    }

    @Test func mapsParameters() throws {
        let body = ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[],"reasoning":{"effort":"high","summary":"auto"},"max_output_tokens":16,"temperature":0.2,
         "store":false,"include":["x"],"prompt_cache_key":"k","client_metadata":{},
         "text":{"format":{"type":"json_schema","name":"n","schema":{"type":"object"},"strict":true}}}
        """#)).body
        #expect(body["reasoning_effort"] as? String == "high")
        #expect(body["max_tokens"] as? Int == 16)
        #expect(body["temperature"] as? Double == 0.2)
        #expect(body["reasoning"] == nil)
        #expect(body["store"] == nil)
        #expect(body["include"] == nil)
        #expect(body["prompt_cache_key"] == nil)
        #expect(body["client_metadata"] == nil)
        let format = body["response_format"] as? [String: Any]
        #expect(format?["type"] as? String == "json_schema")
        #expect((format?["json_schema"] as? [String: Any])?["name"] as? String == "n")
    }

    @Test func effortNoneIsNotSent() throws {
        let body = ResponsesBridge.translate(try json(#"{"model":"m","input":[],"reasoning":{"effort":"none"}}"#)).body
        #expect(body["reasoning_effort"] == nil)
    }

    @Test func flattensToolsAndDropsHostedOnes() throws {
        let translated = ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[],"tool_choice":"auto","parallel_tool_calls":true,"tools":[
          {"type":"function","name":"exec_command","description":"run","strict":false,"parameters":{"type":"object","properties":{"cmd":{"type":"string"}}}},
          {"type":"namespace","name":"multi_agent_v1","tools":[{"type":"function","name":"close_agent","parameters":{"type":"object"}}]},
          {"type":"custom","name":"apply_patch","description":"patch","format":{"type":"grammar","definition":"G"}},
          {"type":"web_search","external_web_access":false}
        ]}
        """#))
        let tools = try #require(translated.body["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["exec_command", "multi_agent_v1__close_agent", "apply_patch"])
        #expect((tools[0]["function"] as? [String: Any])?["strict"] == nil)
        #expect(translated.routes["multi_agent_v1__close_agent"] == ToolRoute(kind: .function, namespace: "multi_agent_v1", name: "close_agent"))
        #expect(translated.routes["apply_patch"]?.kind == .custom)
        let customDescription = (tools[2]["function"] as? [String: Any])?["description"] as? String
        #expect(customDescription?.contains("G") == true)
        #expect(translated.body["tool_choice"] as? String == "auto")
        #expect(translated.body["parallel_tool_calls"] == nil)
    }

    @Test func omitsToolFieldsWhenOnlyHostedToolsExist() throws {
        let body = ResponsesBridge.translate(try json(#"{"model":"m","input":[],"tool_choice":"auto","tools":[{"type":"web_search"}]}"#)).body
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
    }

    @Test func longToolNamesStayValidAndStable() {
        let long = String(repeating: "x", count: 90)
        let first = ResponsesBridge.flatName(namespace: "ns", name: long)
        #expect(first.count <= 64)
        #expect(first == ResponsesBridge.flatName(namespace: "ns", name: long))
        #expect(first != ResponsesBridge.flatName(namespace: "other", name: long))
        #expect(ResponsesBridge.flatName(namespace: nil, name: "a.b c") == "a_b_c")
    }

    @Test func rebuildsToolHistoryWithParallelCalls() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[
          {"type":"message","role":"user","content":"go"},
          {"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]},
          {"type":"function_call","call_id":"c1","name":"exec_command","arguments":"{\"cmd\":\"a\"}"},
          {"type":"function_call","call_id":"c2","namespace":"ns","name":"tool","arguments":""},
          {"type":"function_call_output","call_id":"c1","output":"out1"},
          {"type":"function_call_output","call_id":"c2","output":[{"type":"input_text","text":"out2"}]},
          {"type":"web_search_call","id":"w"},
          {"type":"message","role":"user","content":"next"}
        ]}
        """#)))
        #expect(list.map { $0["role"] as? String } == ["user", "assistant", "tool", "tool", "user"])
        let calls = try #require(list[1]["tool_calls"] as? [[String: Any]])
        #expect(list[1]["content"] as? String == "ok")
        #expect(calls.count == 2)
        #expect(calls[0]["id"] as? String == "c1")
        #expect((calls[1]["function"] as? [String: Any])?["name"] as? String == "ns__tool")
        #expect((calls[1]["function"] as? [String: Any])?["arguments"] as? String == "{}")
        #expect(list[2]["tool_call_id"] as? String == "c1")
        #expect(list[3]["content"] as? String == "out2")
    }

    @Test func toolCallWithoutTextUsesNullContent() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[{"type":"function_call","call_id":"c","name":"t","arguments":"{}"},{"type":"function_call_output","call_id":"c","output":"o"}]}
        """#)))
        #expect(list[0]["content"] is NSNull)
    }

    @Test func customToolHistoryRoundTrips() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[
          {"type":"custom_tool_call","call_id":"c","name":"apply_patch","input":"PATCH"},
          {"type":"custom_tool_call_output","call_id":"c","output":"done"}
        ]}
        """#)))
        let call = (list[0]["tool_calls"] as? [[String: Any]])?.first?["function"] as? [String: Any]
        #expect(call?["name"] as? String == "apply_patch")
        let arguments = try json(call?["arguments"] as? String ?? "")
        #expect(arguments["input"] as? String == "PATCH")
        #expect(list[1]["content"] as? String == "done")
    }

    @Test func toolImagesFollowAllToolResults() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[
          {"type":"function_call","call_id":"a","name":"view_image","arguments":"{}"},
          {"type":"function_call","call_id":"b","name":"t","arguments":"{}"},
          {"type":"function_call_output","call_id":"a","output":[{"type":"input_image","image_url":"data:image/png;base64,AA"}]},
          {"type":"function_call_output","call_id":"b","output":"text"}
        ]}
        """#)))
        #expect(list.map { $0["role"] as? String } == ["assistant", "tool", "tool", "user"])
        let parts = try #require(list[3]["content"] as? [[String: Any]])
        #expect(parts.contains { ($0["image_url"] as? [String: Any])?["url"] as? String == "data:image/png;base64,AA" })
    }

    @Test func userImagesBecomeContentParts() throws {
        let list = messages(ResponsesBridge.translate(try json(#"""
        {"model":"m","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"see"},{"type":"input_image","image_url":"data:x"}]}]}
        """#)))
        let parts = try #require(list[0]["content"] as? [[String: Any]])
        #expect(parts[0]["text"] as? String == "see")
        #expect((parts[1]["image_url"] as? [String: Any])?["url"] as? String == "data:x")
    }
}

@Suite struct StreamTranslationTests {
    private func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    private func names(_ events: [BridgeEvent]) -> [String] { events.map(\.name) }

    @Test func textStreamProducesOrderedEvents() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        var events = writer.start()
        events += writer.consume(chunk(["role": "assistant", "content": "He"]))
        events += writer.consume(chunk(["content": "llo"]))
        events += writer.consume(chunk([:], finish: "stop"))
        events += writer.consume(["choices": [], "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5,
                                                           "completion_tokens_details": ["reasoning_tokens": 1],
                                                           "prompt_tokens_details": ["cached_tokens": 2]]])
        events += writer.finish()

        #expect(names(events) == [
            "response.created", "response.in_progress",
            "response.output_item.added", "response.content_part.added",
            "response.output_text.delta", "response.output_text.delta",
            "response.output_text.done", "response.content_part.done", "response.output_item.done",
            "response.completed",
        ])
        let completed = try #require(events.last?.payload["response"] as? [String: Any])
        #expect(completed["status"] as? String == "completed")
        let usage = try #require(completed["usage"] as? [String: Any])
        #expect(usage["input_tokens"] as? Int == 3)
        #expect(usage["output_tokens"] as? Int == 2)
        #expect((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int == 2)
        #expect((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int == 1)
        let item = (completed["output"] as? [[String: Any]])?.first
        #expect(((item?["content"] as? [[String: Any]])?.first)?["text"] as? String == "Hello")
    }

    @Test func toolCallFragmentsAreAssembled() throws {
        let routes = ["ns__tool": ToolRoute(kind: .function, namespace: "ns", name: "tool")]
        let writer = ResponsesStreamWriter(model: "m", routes: routes)
        var events = writer.consume(chunk(["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "ns__tool", "arguments": ""]]]]))
        events += writer.consume(chunk(["tool_calls": [["index": 0, "function": ["arguments": "{\"a\""]]]]))
        events += writer.consume(chunk(["tool_calls": [["index": 0, "function": ["arguments": ":1}"]]]]))
        events += writer.consume(chunk(["tool_calls": [["index": 1, "id": "call_2", "function": ["name": "plain", "arguments": "{}"]]]]))
        events += writer.consume(chunk([:], finish: "tool_calls"))
        events += writer.finish()

        let done = events.filter { $0.name == "response.output_item.done" }.compactMap { $0.payload["item"] as? [String: Any] }
        #expect(done.count == 2)
        #expect(done[0]["type"] as? String == "function_call")
        #expect(done[0]["call_id"] as? String == "call_1")
        #expect(done[0]["name"] as? String == "tool")
        #expect(done[0]["namespace"] as? String == "ns")
        #expect(done[0]["arguments"] as? String == "{\"a\":1}")
        #expect(done[1]["name"] as? String == "plain")
        #expect(done[1]["namespace"] == nil)
    }

    @Test func customToolReturnsRawInput() throws {
        let routes = ["apply_patch": ToolRoute(kind: .custom, namespace: nil, name: "apply_patch")]
        let writer = ResponsesStreamWriter(model: "m", routes: routes)
        var events = writer.consume(chunk(["tool_calls": [["index": 0, "id": "c", "function": ["name": "apply_patch", "arguments": "{\"input\":\"PATCH\"}"]]]]))
        events += writer.finish()
        #expect(!names(events).contains("response.function_call_arguments.delta"))
        let item = events.first { $0.name == "response.output_item.done" }?.payload["item"] as? [String: Any]
        #expect(item?["type"] as? String == "custom_tool_call")
        #expect(item?["input"] as? String == "PATCH")
    }

    @Test func handlesMissingIDsAndObjectArguments() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        var events = writer.consume(chunk(["tool_calls": [["function": ["name": "t", "arguments": ["k": "v"]]]]]))
        events += writer.finish()
        let item = events.first { $0.name == "response.output_item.done" }?.payload["item"] as? [String: Any]
        #expect((item?["call_id"] as? String)?.hasPrefix("call_") == true)
        #expect(item?["arguments"] as? String == "{\"k\":\"v\"}")
    }

    @Test func reasoningRoundTripsThroughEncryptedContent() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        var events = writer.consume(chunk(["reasoning_content": "想一"]))
        events += writer.consume(chunk(["reasoning_content": "想"]))
        events += writer.consume(chunk(["content": "答案"]))
        events += writer.finish()

        #expect(names(events).contains("response.reasoning_summary_text.delta"))
        let items = events.filter { $0.name == "response.output_item.done" }.compactMap { $0.payload["item"] as? [String: Any] }
        #expect(items.map { $0["type"] as? String } == ["reasoning", "message"])
        let stored = try #require(items[0]["encrypted_content"] as? String)

        let list = messages(ResponsesBridge.translate([
            "model": "m",
            "input": [
                ["type": "message", "role": "user", "content": "q"],
                ["type": "reasoning", "summary": [Any](), "encrypted_content": stored],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "答案"]]],
            ] as [[String: Any]],
        ]))
        #expect(list[1]["reasoning_content"] as? String == "想一想")
    }

    @Test func reasoningOfOtherOriginIsIgnored() {
        let list = messages(ResponsesBridge.translate([
            "model": "m",
            "input": [
                ["type": "reasoning", "summary": [Any](), "encrypted_content": "gAAAA-from-openai"],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "x"]]],
            ] as [[String: Any]],
        ]))
        #expect(list[0]["reasoning_content"] == nil)
    }

    @Test func lengthFinishIsIncomplete() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        var events = writer.consume(chunk(["content": "partial"], finish: "length"))
        events += writer.finish()
        #expect(events.last?.name == "response.incomplete")
        let response = events.last?.payload["response"] as? [String: Any]
        #expect((response?["incomplete_details"] as? [String: Any])?["reason"] as? String == "max_output_tokens")
    }

    @Test func emptyUpstreamFails() {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        let events = writer.finish()
        #expect(events.last?.name == "response.failed")
        #expect(writer.response["status"] as? String == "failed")
    }

    @Test func completionJSONIsAccepted() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        var events = writer.consumeCompletion(try json(#"""
        {"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"hi"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}
        """#))
        events += writer.finish()
        #expect(events.last?.name == "response.completed")
        #expect((writer.response["usage"] as? [String: Any])?["total_tokens"] as? Int == 2)
    }

    @Test func eventsEncodeAsServerSentEvents() throws {
        let writer = ResponsesStreamWriter(model: "m", routes: [:])
        let event = try #require(writer.start().first)
        let text = try #require(String(data: event.sseData, encoding: .utf8))
        #expect(text.hasPrefix("event: response.created\ndata: {"))
        #expect(text.hasSuffix("\n\n"))
        let sequence = writer.consume(chunk(["content": "x"])).compactMap { $0.payload["sequence_number"] as? Int }
        #expect(sequence == sequence.sorted())
    }
}

private final class FakeControl: BridgeServiceControl, @unchecked Sendable {
    private let lock = NSLock()
    private var _installs = 0
    private var _restarts = 0
    private var _uninstalls = 0
    var installs: Int { lock.withLock { _installs } }
    var restarts: Int { lock.withLock { _restarts } }
    var uninstalls: Int { lock.withLock { _uninstalls } }

    func install(executable: URL, configFile: URL, logFile: URL) throws { lock.withLock { _installs += 1 } }
    func restart() throws { lock.withLock { _restarts += 1 } }
    func uninstall() { lock.withLock { _uninstalls += 1 } }
}

@Suite struct BridgeEngineTests {
    private func setup(
        health: @escaping BridgeManager.HealthCheck = { _ in BridgeInfo.version }
    ) throws -> (AppPaths, InMemoryKeyStore, SyncEngine, FakeControl, AppState) {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "modelbar bridge \(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(home: home)
        try FileManager.default.createDirectory(at: paths.codexDirectory, withIntermediateDirectories: true)
        try "model = \"orig\"\n".write(to: paths.codexConfig, atomically: true, encoding: .utf8)

        let executable = home.appending(path: "ModelBarGateway")
        FileManager.default.createFile(atPath: executable.path, contents: Data(), attributes: [.posixPermissions: 0o755])

        let control = FakeControl()
        let keys = InMemoryKeyStore()
        let manager = BridgeManager(paths: paths, executable: executable, control: control, health: health, isPortFree: { _ in true })
        let engine = SyncEngine(paths: paths, keyStore: keys, bridge: manager)

        var state = AppState()
        let endpoint = Endpoint(
            name: "Q",
            baseURL: "https://q.example.com/v1",
            models: [ModelInfo(id: "lite")],
            selectedModel: "lite",
            probe: ProbeResult(models: .ok, chat: .ok, responses: .failed)
        )
        try keys.setKey("sk-upstream", for: endpoint.id)
        state.endpoints = [endpoint]
        state.activeEndpointID = endpoint.id
        state.enabledTools = [.codex]
        return (paths, keys, engine, control, state)
    }

    @Test func withoutBridgeCodexIsLeftAlone() async throws {
        let (paths, _, engine, control, state) = try setup()
        let report = await engine.sync(state)
        guard case .incompatible = report.statuses[.codex] else {
            Issue.record("expected incompatible")
            return
        }
        #expect(control.installs == 0)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == "model = \"orig\"\n")
    }

    @Test func bridgePointsCodexAtLocalServiceWithLocalToken() async throws {
        var (paths, _, engine, control, state) = try setup()
        state.bridgeEnabled = true
        let report = await engine.sync(state)
        #expect(report.statuses[.codex] == .synced)
        #expect(control.installs == 1)

        let text = try String(contentsOf: paths.codexConfig, encoding: .utf8)
        let document = TOMLDocument(text: text)
        #expect(document.string(forKey: "base_url", inTable: "model_providers.modelbar") == "http://127.0.0.1:\(BridgeInfo.defaultPort)/v1")
        #expect(document.rawValue(forKey: "args", inTable: "model_providers.modelbar.auth")?.contains("bridge.token") == true)
        #expect(!text.contains("sk-upstream"))

        let config = try BridgeConfig.load(from: paths.bridgeConfig)
        #expect(config.upstreamBaseURL == "https://q.example.com/v1")
        #expect(config.upstreamKeyFile == paths.keyFile(for: state.endpoints[0].id).path)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.bridgeToken.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let token = try String(contentsOf: paths.bridgeToken, encoding: .utf8)
        #expect(token.hasPrefix("mb-") && token.count > 60)

        let statuses = await engine.currentStatuses(state)
        #expect(statuses[.codex] == .synced)
    }

    @Test func repeatedSyncKeepsTokenAndPort() async throws {
        var (paths, _, engine, _, state) = try setup()
        state.bridgeEnabled = true
        _ = await engine.sync(state)
        let token = try String(contentsOf: paths.bridgeToken, encoding: .utf8)
        let config = try BridgeConfig.load(from: paths.bridgeConfig)
        _ = await engine.sync(state)
        #expect(try String(contentsOf: paths.bridgeToken, encoding: .utf8) == token)
        #expect(try BridgeConfig.load(from: paths.bridgeConfig) == config)
    }

    @Test func serviceNotRespondingIsReportedAndCodexUntouched() async throws {
        var (paths, _, engine, _, state) = try setup(health: { _ in nil })
        state.bridgeEnabled = true
        let report = await engine.sync(state)
        guard case .failed = report.statuses[.codex] else {
            Issue.record("expected failed, got \(String(describing: report.statuses[.codex]))")
            return
        }
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == "model = \"orig\"\n")
    }

    @Test func oldServiceVersionIsRestarted() async throws {
        var (_, _, engine, control, state) = try setup(health: { _ in BridgeInfo.version - 1 })
        state.bridgeEnabled = true
        _ = await engine.sync(state)
        #expect(control.restarts >= 1)
    }

    @Test func switchingToEndpointWithResponsesStopsService() async throws {
        var (paths, keys, engine, control, state) = try setup()
        state.bridgeEnabled = true
        _ = await engine.sync(state)

        let direct = Endpoint(
            name: "D",
            baseURL: "https://d.example.com/v1",
            models: [ModelInfo(id: "x")],
            selectedModel: "x",
            probe: ProbeResult(models: .ok, chat: .ok, responses: .ok)
        )
        try keys.setKey("sk-direct", for: direct.id)
        state.endpoints.append(direct)
        state.activeEndpointID = direct.id
        let report = await engine.sync(state)

        #expect(report.statuses[.codex] == .synced)
        #expect(control.uninstalls == 1)
        #expect(!FileManager.default.fileExists(atPath: paths.bridgeToken.path))
        let document = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        #expect(document.string(forKey: "base_url", inTable: "model_providers.modelbar") == "https://d.example.com/v1")
    }

    @Test func disablingCodexStopsServiceAndRestoresConfig() async throws {
        var (paths, _, engine, control, state) = try setup()
        state.bridgeEnabled = true
        let first = await engine.sync(state)
        state.originals[.codex] = first.originals[.codex]
        _ = await engine.disable(.codex, state: state)
        #expect(control.uninstalls == 1)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == "model = \"orig\"\n")
        #expect(!FileManager.default.fileExists(atPath: paths.bridgeConfig.path))
    }

    @Test func offerOnlyAppliesToChatOnlyEndpoints() throws {
        var (_, _, _, _, state) = try setup()
        #expect(state.toolsNeedingConversion == [.codex])
        #expect(!state.needsBridge)
        state.bridgeEnabled = true
        #expect(state.needsBridge)
        state.endpoints[0].probe = ProbeResult(models: .ok, chat: .failed, responses: .failed)
        #expect(!state.needsBridge)
    }
}
