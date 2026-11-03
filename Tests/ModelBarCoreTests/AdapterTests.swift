import Foundation
import Testing
@testable import ModelBarCore

private func makeHome() throws -> AppPaths {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "modelbar tests \(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return AppPaths(home: url)
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func context(
    _ paths: AppPaths,
    effort: ReasoningEffort = .high,
    probe: ProbeResult? = nil,
    model: String = "m1"
) -> SyncContext {
    let models = [
        ModelInfo(id: "m1", contextLength: 64_000, maxOutputTokens: 4_096, supportsReasoning: true, effortLevels: ["low", "high"]),
        ModelInfo(id: "m2"),
    ]
    let endpoint = Endpoint(
        name: "Test \"API\"",
        baseURL: "https://api.example.com/v1/",
        models: models,
        selectedModel: model,
        effort: effort,
        probe: probe
    )
    return SyncContext(
        endpoint: endpoint,
        model: endpoint.currentModel!,
        keyFile: paths.keyFile(for: endpoint.id),
        paths: paths,
        backups: BackupStore(directory: paths.backupsDirectory)
    )
}

private let opencode = ToolCatalog.adapter(for: .opencode)

@Suite struct CodexAdapterTests {
    let adapter = CodexAdapter()
    let original = """
    model_instructions_file = "/x/y.md"
    model = "gpt-6.1-sol"
    model_reasoning_effort = "xhigh"
    notify = [
      "/a b/client",
      "turn-ended"
    ]

    [model_providers.OpenAI]
    name = "OpenAI"
    wire_api = "responses"

    [model_providers.magpie]
    base_url = "http://127.0.0.1:3425/v1"

    """

    @Test func applyThenRestoreIsByteIdentical() throws {
        let paths = try makeHome()
        try write(original, to: paths.codexConfig)
        let ctx = context(paths)

        let captured = try #require(try adapter.apply(ctx))
        #expect(captured["model"] == "\"gpt-6.1-sol\"")
        #expect(captured["model_reasoning_effort"] == "\"xhigh\"")
        #expect(captured["model_provider"] == nil)
        #expect(adapter.isApplied(ctx))

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == original)
    }

    @Test func repeatedApplyKeepsOriginalsAndDoesNotGrow() throws {
        let paths = try makeHome()
        try write(original, to: paths.codexConfig)
        var ctx = context(paths)

        let captured = try #require(try adapter.apply(ctx))
        let firstLength = try String(contentsOf: paths.codexConfig, encoding: .utf8).count
        ctx.endpoint.effort = .low
        #expect(try adapter.apply(ctx) == nil)
        ctx.endpoint.effort = .high
        #expect(try adapter.apply(ctx) == nil)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8).count == firstLength)

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == original)
    }

    @Test func writesCommandAuthAndNeverTheKey() throws {
        let paths = try makeHome()
        let ctx = context(paths)
        _ = try adapter.apply(ctx)
        let document = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        #expect(document.string(forKey: "command", inTable: "model_providers.modelbar.auth") == "/bin/cat")
        #expect(document.rawValue(forKey: "args", inTable: "model_providers.modelbar.auth")?.contains(ctx.keyFile!.path) == true)
        #expect(document.string(forKey: "base_url", inTable: "model_providers.modelbar") == "https://api.example.com/v1")
        #expect(document.string(forKey: "model_reasoning_effort") == "high")
        #expect(document.rawValue(forKey: "model_context_window") == "64000")
    }

    @Test func automaticEffortRemovesOverride() throws {
        let paths = try makeHome()
        try write(original, to: paths.codexConfig)
        let ctx = context(paths, effort: .automatic)
        _ = try adapter.apply(ctx)
        let document = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        #expect(document.rawValue(forKey: "model_reasoning_effort") == nil)
        #expect(adapter.isApplied(ctx))
    }

    @Test func restoreDoesNotClobberAModelChosenAfterManualEdit() throws {
        let paths = try makeHome()
        try write(original, to: paths.codexConfig)
        let ctx = context(paths)
        let captured = try #require(try adapter.apply(ctx))

        var document = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        document.setTopLevel("model_provider", rawValue: "\"magpie\"")
        document.setTopLevel("model", rawValue: "\"hand-picked\"")
        try document.text.write(to: paths.codexConfig, atomically: true, encoding: .utf8)
        #expect(!adapter.isApplied(ctx))

        try adapter.restore(paths: paths, backups: ctx.backups, originals: captured)
        let after = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        #expect(after.string(forKey: "model") == "hand-picked")
        #expect(after.string(forKey: "model_provider") == "magpie")
        #expect(!after.hasTable("model_providers.modelbar"))
    }

    @Test func detectsIncompatibleEndpoint() throws {
        let paths = try makeHome()
        let ctx = context(paths, probe: ProbeResult(models: .ok, chat: .ok, responses: .failed))
        #expect(adapter.incompatibility(with: ctx.endpoint) != nil)
    }

    @Test func backsUpBeforeWriting() throws {
        let paths = try makeHome()
        try write(original, to: paths.codexConfig)
        let ctx = context(paths)
        _ = try adapter.apply(ctx)
        let backups = ctx.backups.backups(label: "codex")
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backups[0], encoding: .utf8) == original)
    }
}

@Suite struct OpenCodeAdapterTests {
    private func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url), options: [.json5Allowed]) as! [String: Any]
    }

    @Test func mergesAndPreservesOtherSettings() throws {
        let paths = try makeHome()
        let file = paths.opencodeDirectory.appending(path: "opencode.json")
        try write(#"{"$schema":"s","permission":"allow","model":"anthropic/x","mcp":{"a":{"type":"local"}},"provider":{"mine":{"name":"M"}}}"#, to: file)
        let ctx = context(paths)

        let captured = try #require(try opencode.apply(ctx))
        #expect(captured["model"] == "anthropic/x")
        #expect(opencode.isApplied(ctx))

        let root = try read(file)
        #expect(root["permission"] as? String == "allow")
        #expect(root["model"] as? String == "modelbar/m1")
        #expect((root["mcp"] as? [String: Any])?["a"] != nil)
        let providers = try #require(root["provider"] as? [String: Any])
        #expect(providers["mine"] != nil)
        let managed = try #require(providers["modelbar"] as? [String: Any])
        let options = try #require(managed["options"] as? [String: Any])
        #expect(options["baseURL"] as? String == "https://api.example.com/v1")
        #expect(options["apiKey"] as? String == "{file:\(ctx.keyFile!.path)}")
        #expect(managed["npm"] as? String == "@ai-sdk/openai-compatible")

        let models = try #require(managed["models"] as? [String: Any])
        let selected = try #require(models["m1"] as? [String: Any])
        #expect((selected["options"] as? [String: Any])?["reasoningEffort"] as? String == "high")
        let variants = try #require(selected["variants"] as? [String: Any])
        #expect(Set(variants.keys) == ["low", "high"])
        #expect((selected["limit"] as? [String: Any])?["context"] as? Int == 64_000)
        let other = try #require(models["m2"] as? [String: Any])
        #expect(other["options"] == nil)

        try opencode.restore(paths: paths, backups: ctx.backups, originals: captured)
        let restored = try read(file)
        #expect(restored["model"] as? String == "anthropic/x")
        let remaining = try #require(restored["provider"] as? [String: Any])
        #expect(remaining["modelbar"] == nil)
        #expect(remaining["mine"] != nil)
    }

    @Test func refusesToOverwriteUnparsableConfig() throws {
        let paths = try makeHome()
        let file = paths.opencodeDirectory.appending(path: "opencode.json")
        let broken = "{ this is not json"
        try write(broken, to: file)
        #expect(throws: ConfigError.self) { _ = try opencode.apply(context(paths)) }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
    }

    @Test func readsCommentedJSONC() throws {
        let paths = try makeHome()
        let file = paths.opencodeDirectory.appending(path: "opencode.jsonc")
        try write("{\n  // keep me semantically\n  \"permission\": \"allow\",\n}\n", to: file)
        _ = try opencode.apply(context(paths))
        #expect(try read(file)["permission"] as? String == "allow")
    }

    @Test func createsConfigWhenMissingAndRestoreRemovesModel() throws {
        let paths = try makeHome()
        let ctx = context(paths)
        let captured = try #require(try opencode.apply(ctx))
        #expect(captured.isEmpty)
        let file = paths.opencodeDirectory.appending(path: "opencode.json")
        try opencode.restore(paths: paths, backups: ctx.backups, originals: captured)
        let root = try read(file)
        #expect(root["model"] == nil)
        #expect(root["provider"] == nil)
    }

    @Test func usesResponsesPackageWhenChatIsUnavailable() throws {
        let paths = try makeHome()
        let ctx = context(paths, probe: ProbeResult(models: .ok, chat: .failed, responses: .ok))
        _ = try opencode.apply(ctx)
        let root = try read(paths.opencodeDirectory.appending(path: "opencode.json"))
        let managed = (root["provider"] as? [String: Any])?["modelbar"] as? [String: Any]
        #expect(managed?["npm"] as? String == "@ai-sdk/openai")
    }

    @Test func keepsSlashesAndModelIDsWithSlashes() throws {
        let paths = try makeHome()
        var ctx = context(paths)
        ctx.endpoint.models.append(ModelInfo(id: "deepseek/deepseek-v4"))
        ctx.endpoint.selectedModel = "deepseek/deepseek-v4"
        ctx.model = ctx.endpoint.currentModel!
        _ = try opencode.apply(ctx)
        #expect(opencode.isApplied(ctx))
        let text = try String(contentsOf: paths.opencodeDirectory.appending(path: "opencode.json"), encoding: .utf8)
        #expect(text.contains("modelbar/deepseek/deepseek-v4"))
    }
}

@Suite struct SyncEngineTests {
    private func makeState(_ paths: AppPaths, keys: KeyStore, tools: [ToolID]) throws -> AppState {
        var state = AppState()
        let endpoint = Endpoint(name: "A", baseURL: "https://a.example.com/v1", models: [ModelInfo(id: "m1")], selectedModel: "m1")
        try keys.setKey("sk-secret", for: endpoint.id)
        state.endpoints = [endpoint]
        state.activeEndpointID = endpoint.id
        state.enabledTools = tools
        return state
    }

    private func install(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.codexDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.opencodeDirectory, withIntermediateDirectories: true)
    }

    @Test func syncWritesPrivateKeyFileAndKeepsKeyOutOfConfigs() async throws {
        let paths = try makeHome()
        try install(paths)
        let keys = InMemoryKeyStore()
        let state = try makeState(paths, keys: keys, tools: [.opencode, .codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)

        let report = await engine.sync(state)
        #expect(report.statuses[.opencode] == .synced)
        #expect(report.statuses[.codex] == .synced)
        #expect(report.statuses[.kilo] == .notInstalled)
        #expect(report.originals[.codex] != nil)

        let keyFile = paths.keyFile(for: state.endpoints[0].id)
        #expect(try String(contentsOf: keyFile, encoding: .utf8) == "sk-secret")
        let attributes = try FileManager.default.attributesOfItem(atPath: keyFile.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try !String(contentsOf: paths.codexConfig, encoding: .utf8).contains("sk-secret"))
        #expect(try !String(contentsOf: paths.opencodeDirectory.appending(path: "opencode.json"), encoding: .utf8).contains("sk-secret"))
    }

    @Test func secondSyncDoesNotRewriteOrBackupWhenNothingChanged() async throws {
        let paths = try makeHome()
        try install(paths)
        let keys = InMemoryKeyStore()
        let state = try makeState(paths, keys: keys, tools: [.codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)
        _ = await engine.sync(state)
        let before = BackupStore(directory: paths.backupsDirectory).backups(label: "codex").count
        _ = await engine.sync(state)
        #expect(BackupStore(directory: paths.backupsDirectory).backups(label: "codex").count == before)
    }

    @Test func incompatibleToolIsLeftUntouched() async throws {
        let paths = try makeHome()
        try install(paths)
        try write("model = \"keep\"\n", to: paths.codexConfig)
        let keys = InMemoryKeyStore()
        var state = try makeState(paths, keys: keys, tools: [.codex])
        state.endpoints[0].probe = ProbeResult(models: .ok, chat: .ok, responses: .failed)
        let report = await SyncEngine(paths: paths, keyStore: keys).sync(state)
        guard case .incompatible = report.statuses[.codex] else {
            Issue.record("expected incompatible")
            return
        }
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == "model = \"keep\"\n")
    }

    @Test func switchingEndpointRemovesOldKeyFile() async throws {
        let paths = try makeHome()
        try install(paths)
        let keys = InMemoryKeyStore()
        var state = try makeState(paths, keys: keys, tools: [.codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)
        _ = await engine.sync(state)
        let oldFile = paths.keyFile(for: state.endpoints[0].id)

        let next = Endpoint(name: "B", baseURL: "https://b.example.com/v1", models: [ModelInfo(id: "x")], selectedModel: "x")
        try keys.setKey("sk-next", for: next.id)
        state.endpoints.append(next)
        state.activeEndpointID = next.id
        _ = await engine.sync(state)

        #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.keyFile(for: next.id).path))
    }

    @Test func incompatibleToolKeepsKeyFileOfTheEndpointItStillUses() async throws {
        let paths = try makeHome()
        try install(paths)
        let keys = InMemoryKeyStore()
        var state = try makeState(paths, keys: keys, tools: [.opencode, .codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)
        _ = await engine.sync(state)
        let oldFile = paths.keyFile(for: state.endpoints[0].id)

        let next = Endpoint(
            name: "B",
            baseURL: "https://b.example.com/v1",
            models: [ModelInfo(id: "x")],
            selectedModel: "x",
            probe: ProbeResult(models: .ok, chat: .ok, responses: .failed)
        )
        try keys.setKey("sk-next", for: next.id)
        state.endpoints.append(next)
        state.activeEndpointID = next.id
        let report = await engine.sync(state)

        #expect(report.statuses[.opencode] == .synced)
        guard case .incompatible = report.statuses[.codex] else {
            Issue.record("expected incompatible")
            return
        }
        // Codex 仍指向旧接口，所以旧 Key 文件必须还在。
        #expect(FileManager.default.fileExists(atPath: oldFile.path))
        #expect(FileManager.default.fileExists(atPath: paths.keyFile(for: next.id).path))
        let codex = TOMLDocument(text: try String(contentsOf: paths.codexConfig, encoding: .utf8))
        #expect(codex.string(forKey: "base_url", inTable: "model_providers.modelbar") == "https://a.example.com/v1")
    }

    @Test func disableRestoresAndNoEnabledToolsRemovesKeyFiles() async throws {
        let paths = try makeHome()
        try install(paths)
        try write("model = \"orig\"\n", to: paths.codexConfig)
        let keys = InMemoryKeyStore()
        var state = try makeState(paths, keys: keys, tools: [.codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)

        let first = await engine.sync(state)
        state.originals[.codex] = first.originals[.codex]
        _ = await engine.disable(.codex, state: state)
        #expect(try String(contentsOf: paths.codexConfig, encoding: .utf8) == "model = \"orig\"\n")

        state.enabledTools = []
        _ = await engine.sync(state)
        #expect(!FileManager.default.fileExists(atPath: paths.keyFile(for: state.endpoints[0].id).path))
    }

    @Test func reportsExternalChangeAsStale() async throws {
        let paths = try makeHome()
        try install(paths)
        let keys = InMemoryKeyStore()
        let state = try makeState(paths, keys: keys, tools: [.codex])
        let engine = SyncEngine(paths: paths, keyStore: keys)
        _ = await engine.sync(state)
        try write("model = \"changed\"\n", to: paths.codexConfig)
        let statuses = await engine.currentStatuses(state)
        #expect(statuses[.codex] == .stale)
    }

    @Test func originalsAreStoredAsReadableObjectAndBrokenStateIsKept() throws {
        let paths = try makeHome()
        let store = StateStore(file: paths.stateFile)
        var state = AppState()
        state.originals = [.codex: ["model": "\"x\""]]
        try store.save(state)
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any]
        #expect(raw?["originals"] is [String: Any])

        try write("{ broken", to: store.file)
        #expect(throws: (any Error).self) { _ = try store.load() }
        let kept = try #require(store.quarantine())
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ broken")
        #expect(!FileManager.default.fileExists(atPath: store.file.path))
        #expect(try store.load() == AppState())
    }

    @Test func stateRoundTripsAndToleratesMissingFields() throws {
        let paths = try makeHome()
        let store = StateStore(file: paths.stateFile)
        #expect(try store.load() == AppState())
        var state = AppState()
        state.endpoints = [Endpoint(name: "A", baseURL: "https://a/v1", probe: ProbeResult(models: .ok))]
        state.enabledTools = [.kilo]
        state.originals = [.codex: ["model": "\"x\""]]
        try store.save(state)
        let loaded = try store.load()
        #expect(loaded.endpoints.first?.name == "A")
        #expect(loaded.enabledTools == [.kilo])
        #expect(loaded.originals[.codex]?["model"] == "\"x\"")
        try write("{\"enabledTools\":[\"codex\"]}", to: store.file)
        #expect(try store.load().enabledTools == [.codex])
    }
}

@Suite struct EndpointParsingTests {
    @Test func normalizesPastedURLs() {
        #expect(Endpoint.normalize(baseURL: " https://a.com/v1/ \n") == "https://a.com/v1")
        #expect(Endpoint.normalize(baseURL: "https://a.com/v1/chat/completions") == "https://a.com/v1")
        #expect(Endpoint.normalize(baseURL: "https://a.com/v1/models/") == "https://a.com/v1/models")
        #expect(Endpoint.isValid(baseURL: "http://127.0.0.1:11434/v1"))
        #expect(!Endpoint.isValid(baseURL: "api.example.com/v1"))
        #expect(!Endpoint.isValid(baseURL: "ftp://a.com"))
    }

    @Test func parsesCommonModelListShapes() throws {
        let openAI = Data(#"{"object":"list","data":[{"id":"a","context_length":1000,"max_output_tokens":10,"supports_reasoning":true,"effort":{"supported_levels":["low","high"]}}]}"#.utf8)
        let a = try #require(ModelListParser.parse(openAI)?.first)
        #expect(a.contextLength == 1000)
        #expect(a.maxOutputTokens == 10)
        #expect(a.supportsReasoning == true)
        #expect(a.availableEfforts == [.automatic, .low, .high])

        let openRouter = Data(#"{"data":[{"id":"o/b","context_length":2000,"top_provider":{"max_completion_tokens":20},"supported_parameters":["tools","reasoning"]}]}"#.utf8)
        let b = try #require(ModelListParser.parse(openRouter)?.first)
        #expect(b.maxOutputTokens == 20)
        #expect(b.supportsReasoning == true)

        let ollama = Data(#"{"models":[{"name":"llama3"}]}"#.utf8)
        #expect(ModelListParser.parse(ollama)?.first?.id == "llama3")

        let bare = Data(#"[{"id":"c","capabilities":{"context_length":"3000","reasoning_effort":["high"]}}]"#.utf8)
        let c = try #require(ModelListParser.parse(bare)?.first)
        #expect(c.contextLength == 3000)
        #expect(c.supportsReasoning == true)

        #expect(ModelListParser.parse(Data("<html>".utf8)) == nil)
    }

    @Test func defaultModelSkipsNonChatModels() {
        let models = ["text-embedding-3", "whisper-1", "gpt-x", "tts-1"].map { ModelInfo(id: $0) }
        #expect(Endpoint.defaultModel(from: models) == "gpt-x")
        #expect(Endpoint.defaultModel(from: [ModelInfo(id: "whisper-1")]) == "whisper-1")
        #expect(Endpoint.defaultModel(from: []) == nil)
    }

    @Test func classifiesProbeResponses() {
        let empty = Data()
        #expect(EndpointClient.classify(status: 200, data: empty).status == .ok)
        #expect(EndpointClient.classify(status: 404, data: empty).status == .failed)
        #expect(EndpointClient.classify(status: 401, data: empty).status == .failed)
        #expect(EndpointClient.classify(status: 429, data: empty).status == .ok)
        let badParameter = Data(#"{"error":{"message":"max_tokens is too small"}}"#.utf8)
        #expect(EndpointClient.classify(status: 400, data: badParameter).status == .ok)
        let unsupported = Data(#"{"error":{"message":"This endpoint is not supported"}}"#.utf8)
        #expect(EndpointClient.classify(status: 400, data: unsupported).status == .failed)
    }
}

@Suite struct KeychainTests {
    /// 会写真实钥匙串，只在显式要求时运行。测试结束后删除写入的条目。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MODELBAR_KEYCHAIN_TEST"] == "1"))
    func roundTripsThroughRealKeychain() throws {
        let store = KeychainStore(service: "ModelBar.tests")
        let id = UUID()
        defer { try? store.setKey(nil, for: id) }
        #expect(try store.key(for: id) == nil)
        try store.setKey("sk-first", for: id)
        #expect(try store.key(for: id) == "sk-first")
        try store.setKey("sk-second", for: id)
        #expect(try store.key(for: id) == "sk-second")
        try store.setKey(nil, for: id)
        #expect(try store.key(for: id) == nil)
    }
}

@Suite struct FileSupportTests {
    @Test func backupsArePrunedToLimit() throws {
        let paths = try makeHome()
        let file = paths.home.appending(path: "config.toml")
        try write("x", to: file)
        let store = BackupStore(directory: paths.backupsDirectory, limit: 3)
        for offset in 0..<6 {
            try store.backup(file, label: "codex", now: Date(timeIntervalSince1970: Double(offset)))
        }
        #expect(store.backups(label: "codex").count == 3)
    }

    @Test func writeKeepsExistingPermissions() throws {
        let paths = try makeHome()
        let file = paths.home.appending(path: "c.toml")
        try write("x", to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        try FileSupport.writeAtomically(Data("y".utf8), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
    }
}

@Suite struct FileKeyStoreTests {
    private func makeStore() throws -> (store: FileKeyStore, directory: URL) {
        let directory = try makeHome().masterKeysDirectory
        return (FileKeyStore(directory: directory), directory)
    }

    @Test func roundTrips() throws {
        let (store, _) = try makeStore()
        let id = UUID()
        #expect(try store.key(for: id) == nil)
        try store.setKey("sk-first", for: id)
        #expect(try store.key(for: id) == "sk-first")
        try store.setKey("sk-second", for: id)
        #expect(try store.key(for: id) == "sk-second")
        try store.setKey(nil, for: id)
        #expect(try store.key(for: id) == nil)
    }

    @Test func emptyKeyRemovesTheFile() throws {
        let (store, directory) = try makeStore()
        let id = UUID()
        try store.setKey("sk-first", for: id)
        try store.setKey("", for: id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try store.setKey(nil, for: id)
    }

    @Test func onlyTheOwnerCanRead() throws {
        let (store, directory) = try makeStore()
        let id = UUID()
        try store.setKey("sk-first", for: id)
        let manager = FileManager.default
        let file = try #require(try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        #expect(try manager.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try manager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func emptyFileCountsAsNoKey() throws {
        let (store, directory) = try makeStore()
        let id = UUID()
        try store.setKey("sk-first", for: id)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data().write(to: file)
        #expect(try store.key(for: id) == nil)
    }

    @Test func failureToRemoveIsReported() throws {
        let (store, directory) = try makeStore()
        let id = UUID()
        try store.setKey("sk-first", for: id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        #expect(throws: (any Error).self) { try store.setKey(nil, for: id) }
    }
}

@Suite struct MigratingKeyStoreTests {
    /// 模拟钥匙串，可以让读取或删除失败，并记录被读了几次。
    private final class FakeLegacy: KeyStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UUID: String] = [:]
        private var readCount = 0
        var failsReads = false
        var failsDeletes = false

        var reads: Int { lock.withLock { readCount } }

        func value(for id: UUID) -> String? { lock.withLock { values[id] } }

        func seed(_ key: String, for id: UUID) { lock.withLock { values[id] = key } }

        func key(for id: UUID) throws -> String? {
            try lock.withLock {
                readCount += 1
                if failsReads { throw ConfigError("用户拒绝了钥匙串授权") }
                return values[id]
            }
        }

        func setKey(_ key: String?, for id: UUID) throws {
            try lock.withLock {
                if key == nil, failsDeletes { throw ConfigError("无法删除") }
                values[id] = key
            }
        }
    }

    private func setup() throws -> (store: MigratingKeyStore, files: FileKeyStore, legacy: FakeLegacy, directory: URL) {
        let directory = try makeHome().masterKeysDirectory
        let files = FileKeyStore(directory: directory)
        let legacy = FakeLegacy()
        return (MigratingKeyStore(primary: files, legacy: legacy), files, legacy, directory)
    }

    @Test func firstReadMovesTheKeyToAFileAndRemovesTheOldEntry() throws {
        let (store, files, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        #expect(try store.key(for: id) == "sk-old")
        #expect(try files.key(for: id) == "sk-old")
        #expect(legacy.value(for: id) == nil)
    }

    @Test func laterReadsDoNotTouchTheKeychain() throws {
        let (store, _, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        _ = try store.key(for: id)
        let readsAfterMigration = legacy.reads
        #expect(try store.key(for: id) == "sk-old")
        #expect(legacy.reads == readsAfterMigration)
    }

    @Test func readingAKeyThatExistsNowhereIsNil() throws {
        let (store, _, _, _) = try setup()
        #expect(try store.key(for: UUID()) == nil)
    }

    @Test func deniedKeychainAccessIsReportedAndCanBeRetried() throws {
        let (store, files, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        legacy.failsReads = true
        #expect(throws: (any Error).self) { _ = try store.key(for: id) }
        #expect(try files.key(for: id) == nil)
        #expect(legacy.value(for: id) == "sk-old")
        legacy.failsReads = false
        #expect(try store.key(for: id) == "sk-old")
    }

    @Test func oldEntryIsKeptWhenTheFileCannotBeWritten() throws {
        let (store, _, legacy, directory) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "挡住目录".write(to: directory, atomically: true, encoding: .utf8)
        #expect(try store.key(for: id) == "sk-old")
        #expect(legacy.value(for: id) == "sk-old")
    }

    @Test func failureToRemoveTheOldEntryStillReturnsTheKey() throws {
        let (store, files, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        legacy.failsDeletes = true
        #expect(try store.key(for: id) == "sk-old")
        #expect(try files.key(for: id) == "sk-old")
    }

    @Test func savingANewKeyReplacesTheOldEntryWithoutReadingIt() throws {
        let (store, files, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        try store.setKey("sk-new", for: id)
        #expect(try files.key(for: id) == "sk-new")
        #expect(legacy.value(for: id) == nil)
        #expect(legacy.reads == 0)
    }

    @Test func savedKeyWinsEvenIfTheOldEntryCannotBeRemoved() throws {
        let (store, _, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        legacy.failsDeletes = true
        try store.setKey("sk-new", for: id)
        #expect(try store.key(for: id) == "sk-new")
    }

    @Test func removingAKeyClearsBothPlaces() throws {
        let (store, files, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        try files.setKey("sk-file", for: id)
        try store.setKey(nil, for: id)
        #expect(try store.key(for: id) == nil)
        #expect(legacy.value(for: id) == nil)
    }

    /// 否则下次读取时，已经清除的 Key 会从钥匙串里复活。
    @Test func failureToRemoveTheOldEntryIsReportedWhenClearingAKey() throws {
        let (store, _, legacy, _) = try setup()
        let id = UUID()
        legacy.seed("sk-old", for: id)
        legacy.failsDeletes = true
        #expect(throws: (any Error).self) { try store.setKey(nil, for: id) }
    }

    /// 会写真实钥匙串，只在显式要求时运行。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MODELBAR_KEYCHAIN_TEST"] == "1"))
    func migratesFromTheRealKeychain() throws {
        let legacy = KeychainStore(service: "ModelBar.tests")
        let id = UUID()
        defer { try? legacy.setKey(nil, for: id) }
        try legacy.setKey("sk-old", for: id)
        let files = FileKeyStore(directory: try makeHome().masterKeysDirectory)
        let store = MigratingKeyStore(primary: files, legacy: legacy)
        #expect(try store.key(for: id) == "sk-old")
        #expect(try files.key(for: id) == "sk-old")
        #expect(try legacy.key(for: id) == nil)
    }
}
