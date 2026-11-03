using System.Text.Json.Nodes;
using static ModelBar.Core.Tests.Support;

namespace ModelBar.Core.Tests;

public class CodexAdapterTests
{
    private readonly CodexAdapter _adapter = new();
    private const string Original = """
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

        """;

    [Fact]
    public void ApplyThenRestoreIsByteIdentical()
    {
        var paths = MakeHome();
        Write(paths.CodexConfig, Original);
        var context = Context(paths);
        var captured = _adapter.Apply(context)!;
        Assert.Equal("\"gpt-6.1-sol\"", captured["model"]);
        Assert.Equal("\"xhigh\"", captured["model_reasoning_effort"]);
        Assert.False(captured.ContainsKey("model_provider"));
        Assert.True(_adapter.IsApplied(context));

        _adapter.Restore(paths, context.Backups, captured);
        Assert.Equal(Original, File.ReadAllText(paths.CodexConfig));
    }

    [Fact]
    public void RepeatedApplyKeepsOriginalsAndDoesNotGrow()
    {
        var paths = MakeHome();
        Write(paths.CodexConfig, Original);
        var context = Context(paths);
        var captured = _adapter.Apply(context)!;
        var length = File.ReadAllText(paths.CodexConfig).Length;
        Assert.Null(_adapter.Apply(context));
        Assert.Equal(length, File.ReadAllText(paths.CodexConfig).Length);
        _adapter.Restore(paths, context.Backups, captured);
        Assert.Equal(Original, File.ReadAllText(paths.CodexConfig));
    }

    [Fact]
    public void WritesCommandAuthAndNeverTheKey()
    {
        var paths = MakeHome();
        var context = Context(paths);
        _adapter.Apply(context);
        var text = File.ReadAllText(paths.CodexConfig);
        var document = new TomlDocument(text);
        Assert.Equal(paths.InstalledGateway, document.GetString("command", "model_providers.modelbar.auth"));
        var args = document.RawValue("args", "model_providers.modelbar.auth")!;
        Assert.Contains("--print-file", args);
        Assert.Contains(TomlDocument.Quote(context.KeyFile!), args);
        Assert.Equal("https://api.example.com/v1", document.GetString("base_url", "model_providers.modelbar"));
        Assert.Equal("64000", document.RawValue("model_context_window"));
        Assert.DoesNotContain("sk-secret-value", text);
    }

    [Fact]
    public void RestoreDoesNotClobberManualChoice()
    {
        var paths = MakeHome();
        Write(paths.CodexConfig, Original);
        var context = Context(paths);
        var captured = _adapter.Apply(context)!;
        var document = new TomlDocument(File.ReadAllText(paths.CodexConfig));
        document.SetTopLevel("model_provider", "\"magpie\"");
        document.SetTopLevel("model", "\"hand-picked\"");
        File.WriteAllText(paths.CodexConfig, document.Text);
        Assert.False(_adapter.IsApplied(context));

        _adapter.Restore(paths, context.Backups, captured);
        var after = new TomlDocument(File.ReadAllText(paths.CodexConfig));
        Assert.Equal("hand-picked", after.GetString("model"));
        Assert.False(after.HasTable("model_providers.modelbar"));
    }

    [Fact]
    public void BacksUpBeforeWriting()
    {
        var paths = MakeHome();
        Write(paths.CodexConfig, Original);
        var context = Context(paths);
        _adapter.Apply(context);
        var backups = context.Backups.Backups("Codex");
        Assert.Single(backups);
        Assert.Equal(Original, File.ReadAllText(backups[0]));
    }
}

public class OpenCodeAdapterTests
{
    private readonly IToolAdapter _adapter = ToolCatalog.Adapter(ToolId.OpenCode);

    [Fact]
    public void MergesAndRestores()
    {
        var paths = MakeHome();
        var file = Path.Combine(paths.OpenCodeDirectory, "opencode.json");
        Write(file, """{"$schema":"s","permission":"allow","model":"anthropic/x","mcp":{"a":{"type":"local"}},"provider":{"mine":{"name":"M"}}}""");
        var before = Read(file);
        var context = Context(paths);

        var captured = _adapter.Apply(context)!;
        Assert.Equal("anthropic/x", captured["model"]);
        Assert.True(_adapter.IsApplied(context));

        var root = Read(file);
        Assert.Equal("allow", root.Str("permission"));
        Assert.Equal("modelbar/m1", root.Str("model"));
        var managed = root.Obj("provider").Obj("modelbar");
        Assert.NotNull(root.Obj("provider").Obj("mine"));
        Assert.Equal("https://api.example.com/v1", managed.Obj("options").Str("baseURL"));
        Assert.Equal($"{{file:{context.KeyFile}}}", managed.Obj("options").Str("apiKey"));
        Assert.Equal("@ai-sdk/openai-compatible", managed.Str("npm"));
        var selected = managed.Obj("models").Obj("m1");
        Assert.Equal("high", selected.Obj("options").Str("reasoningEffort"));
        Assert.Equal(["high", "low"], selected.Obj("variants")!.Select(p => p.Key).Order());
        Assert.Equal(64_000, selected.Obj("limit").Int("context"));
        Assert.Null(managed.Obj("models").Obj("m2").Obj("options"));

        _adapter.Restore(paths, context.Backups, captured);
        Assert.True(SameJson(before, Read(file)));
    }

    [Fact]
    public void RefusesToOverwriteUnparsableConfig()
    {
        var paths = MakeHome();
        var file = Path.Combine(paths.OpenCodeDirectory, "opencode.json");
        Write(file, "{ this is not json");
        Assert.Throws<ConfigException>(() => _adapter.Apply(Context(paths)));
        Assert.Equal("{ this is not json", File.ReadAllText(file));
    }

    [Fact]
    public void ReadsCommentsTrailingCommasAndBom()
    {
        var paths = MakeHome();
        var file = Path.Combine(paths.OpenCodeDirectory, "opencode.jsonc");
        Directory.CreateDirectory(paths.OpenCodeDirectory);
        File.WriteAllText(file, "{\n  // note\n  \"permission\": \"allow\",\n}\n", new System.Text.UTF8Encoding(true));
        _adapter.Apply(Context(paths));
        Assert.Equal("allow", Read(file).Str("permission"));
    }

    [Fact]
    public void UsesResponsesPackageWhenChatIsUnavailable()
    {
        var paths = MakeHome();
        _adapter.Apply(Context(paths, probe: new ProbeResult { Models = ProbeStatus.Ok, Chat = ProbeStatus.Failed, Responses = ProbeStatus.Ok }));
        Assert.Equal("@ai-sdk/openai", Read(Path.Combine(paths.OpenCodeDirectory, "opencode.json")).Obj("provider").Obj("modelbar").Str("npm"));
    }
}

public class ClaudeCodeAdapterTests
{
    private readonly ClaudeCodeAdapter _adapter = new();
    private const string Original = """{"env":{"ANTHROPIC_AUTH_TOKEN":"tok","ANTHROPIC_BASE_URL":"https://gw.example.com","DISABLE_AUTOUPDATER":"1"},"theme":"dark"}""";

    [Fact]
    public void ReplacesTokenWithHelperAndRestoresEverything()
    {
        var paths = MakeHome();
        Write(paths.ClaudeSettings, Original);
        var before = Read(paths.ClaudeSettings);
        var context = Context(paths);

        var captured = _adapter.Apply(context)!;
        Assert.Equal("tok", captured["env.ANTHROPIC_AUTH_TOKEN"]);
        Assert.True(_adapter.IsApplied(context));

        var root = Read(paths.ClaudeSettings);
        var env = root.Obj("env")!;
        Assert.Null(env["ANTHROPIC_AUTH_TOKEN"]);
        Assert.Equal("https://api.example.com", env.Str("ANTHROPIC_BASE_URL"));
        Assert.Equal("m1", env.Str("ANTHROPIC_DEFAULT_HAIKU_MODEL"));
        Assert.Equal("high", env.Str("CLAUDE_CODE_EFFORT_LEVEL"));
        Assert.Equal("1", env.Str("DISABLE_AUTOUPDATER"));
        var helper = root.Str("apiKeyHelper")!;
        Assert.StartsWith("\"", helper);
        Assert.Contains("--print-file", helper);
        Assert.DoesNotContain("\\", helper);
        Assert.DoesNotContain("sk-secret-value", File.ReadAllText(paths.ClaudeSettings));

        _adapter.Restore(paths, context.Backups, captured);
        Assert.True(SameJson(before, Read(paths.ClaudeSettings)));
    }

    [Fact]
    public void BridgeUsesLocalAddressAndToken()
    {
        var paths = MakeHome();
        var context = Context(paths, bridge: new BridgeTarget("http://127.0.0.1:47631/v1", paths.BridgeToken));
        _adapter.Apply(context);
        var root = Read(paths.ClaudeSettings);
        Assert.Equal("http://127.0.0.1:47631", root.Obj("env").Str("ANTHROPIC_BASE_URL"));
        Assert.Contains("bridge.token", root.Str("apiKeyHelper"));
        Assert.True(_adapter.IsApplied(context));
    }

    [Fact]
    public void CompatibilityRules()
    {
        var endpoint = new Endpoint { Name = "Q", BaseUrl = "https://q/v1" };
        Assert.Null(_adapter.Incompatibility(endpoint, false));
        endpoint.Probe = new ProbeResult { Chat = ProbeStatus.Ok, Messages = ProbeStatus.Ok };
        Assert.Null(_adapter.Incompatibility(endpoint, false));
        endpoint.Probe = new ProbeResult { Chat = ProbeStatus.Ok, Messages = ProbeStatus.Failed };
        Assert.NotNull(_adapter.Incompatibility(endpoint, false));
        Assert.Null(_adapter.Incompatibility(endpoint, true));
        endpoint.Probe = new ProbeResult { Chat = ProbeStatus.Failed, Messages = ProbeStatus.Failed };
        Assert.NotNull(_adapter.Incompatibility(endpoint, true));
    }
}

public class PiAdapterTests
{
    private readonly PiAdapter _adapter = new();

    [Fact]
    public void AddsProviderAndAllowlistThenRestores()
    {
        var paths = MakeHome();
        var models = Path.Combine(paths.PiDirectory, "models.json");
        var settings = Path.Combine(paths.PiDirectory, "settings.json");
        Write(models, """{"providers":{"mine":{"name":"M"}}}""");
        Write(settings, """{"defaultProvider":"mine","defaultModel":"m1","defaultThinkingLevel":"low","theme":"t","enabledModels":["a"]}""");
        var (modelsBefore, settingsBefore) = (Read(models), Read(settings));
        var context = Context(paths);

        var captured = _adapter.Apply(context)!;
        Assert.Equal("mine", captured["defaultProvider"]);
        Assert.True(_adapter.IsApplied(context));
        var provider = Read(models).Obj("providers").Obj("modelbar");
        Assert.Equal("openai-completions", provider.Str("api"));
        Assert.StartsWith("!\"", provider.Str("apiKey"));
        Assert.Equal("modelbar/m1", Read(settings).Arr("enabledModels")![0]!.GetValue<string>());
        Assert.DoesNotContain("sk-secret-value", File.ReadAllText(models));

        _adapter.Restore(paths, context.Backups, captured);
        Assert.True(SameJson(modelsBefore, Read(models)));
        Assert.True(SameJson(settingsBefore, Read(settings)));
    }

    [Fact]
    public void DoesNotCreateAllowlistWhenThereIsNone()
    {
        var paths = MakeHome();
        var settings = Path.Combine(paths.PiDirectory, "settings.json");
        Write(settings, """{"defaultProvider":"mine"}""");
        var context = Context(paths);
        _adapter.Apply(context);
        Assert.Null(Read(settings)["enabledModels"]);
        Assert.True(_adapter.IsApplied(context));
    }
}

public class GrokAdapterTests
{
    private readonly GrokAdapter _adapter = new();
    private const string Original = """
        [cli]
        theme = "x"

        [models]
        default = "grok-4.7-build-fast"
        default_reasoning_effort = "xhigh"

        [mcp_servers.exa]
        command = "exa"

        """;

    [Fact]
    public void ApplyThenRestoreIsByteIdentical()
    {
        var paths = MakeHome();
        Write(paths.GrokConfig, Original);
        var context = Context(paths);
        var captured = _adapter.Apply(context)!;
        Assert.True(_adapter.IsApplied(context));
        var text = File.ReadAllText(paths.GrokConfig);
        Assert.DoesNotContain("sk-secret-value", text);
        var document = new TomlDocument(text);
        Assert.Equal("modelbar", document.GetString("default", "models"));
        Assert.Equal(paths.InstalledGateway, document.GetString("command", "auth_provider.modelbar"));
        Assert.Contains("--print-file", document.RawValue("args", "auth_provider.modelbar"));

        Assert.Null(_adapter.Apply(context));
        _adapter.Restore(paths, context.Backups, captured);
        Assert.Equal(Original, File.ReadAllText(paths.GrokConfig));
    }

    [Fact]
    public void CreatesModelsTableWhenMissingAndRemovesIt()
    {
        var paths = MakeHome();
        Write(paths.GrokConfig, "[cli]\ntheme = \"x\"\n");
        var context = Context(paths);
        var captured = _adapter.Apply(context)!;
        _adapter.Restore(paths, context.Backups, captured);
        Assert.Equal("[cli]\ntheme = \"x\"\n", File.ReadAllText(paths.GrokConfig));
    }
}

public class DroidAdapterTests
{
    private readonly DroidAdapter _adapter = new();

    [Fact]
    public void AppendsModelAndRestoresDefaults()
    {
        var paths = MakeHome();
        Write(paths.DroidSettings, """{"customModels":[{"model":"mimo","displayName":"Xiaomi MiMo","baseUrl":"https://x/v1","apiKey":"mine","provider":"generic-chat-completion-api"}],"sessionDefaultSettings":{"model":"custom:Xiaomi-MiMo-0","reasoningEffort":"low","autonomyMode":"auto-medium"},"diffMode":"github"}""");
        var before = Read(paths.DroidSettings);
        var context = Context(paths);

        var captured = _adapter.Apply(context)!;
        Assert.Equal("custom:Xiaomi-MiMo-0", captured["model"]);
        Assert.True(_adapter.IsApplied(context));
        var root = Read(paths.DroidSettings);
        var models = root.Arr("customModels")!;
        Assert.Equal(2, models.Count);
        Assert.Equal("sk-secret-value", ((JsonObject)models[1]!).Str("apiKey"));
        Assert.Equal("custom:ModelBar-1", root.Obj("sessionDefaultSettings").Str("model"));

        Assert.Null(_adapter.Apply(context));
        Assert.Equal(2, Read(paths.DroidSettings).Arr("customModels")!.Count);
        _adapter.Restore(paths, context.Backups, captured);
        Assert.True(SameJson(before, Read(paths.DroidSettings)));
    }
}

public class EndpointTests
{
    [Fact]
    public void NormalizesPastedUrls()
    {
        Assert.Equal("https://a.com/v1", Endpoint.Normalize(" https://a.com/v1/ \n"));
        Assert.Equal("https://a.com/v1", Endpoint.Normalize("https://a.com/v1/chat/completions"));
        Assert.True(Endpoint.IsValidBaseUrl("http://127.0.0.1:11434/v1"));
        Assert.False(Endpoint.IsValidBaseUrl("api.example.com/v1"));
        Assert.False(Endpoint.IsValidBaseUrl("ftp://a.com"));
    }

    [Fact]
    public void DefaultModelSkipsNonChatModels()
    {
        Assert.Equal("gpt-x", Endpoint.DefaultModel(new[] { "text-embedding-3", "whisper-1", "gpt-x" }.Select(id => new ModelInfo { Id = id }).ToList()));
        Assert.Null(Endpoint.DefaultModel([]));
    }

    [Fact]
    public void ParsesCommonModelListShapes()
    {
        var a = ModelListParser.Parse("""{"object":"list","data":[{"id":"a","context_length":1000,"max_output_tokens":10,"supports_reasoning":true,"effort":{"supported_levels":["low","high"]}}]}""")![0];
        Assert.Equal(1000, a.ContextLength);
        Assert.Equal(10, a.MaxOutputTokens);
        Assert.Equal([ReasoningEffort.Automatic, ReasoningEffort.Low, ReasoningEffort.High], a.AvailableEfforts);

        var b = ModelListParser.Parse("""{"data":[{"id":"o/b","top_provider":{"max_completion_tokens":20},"supported_parameters":["tools","reasoning"]}]}""")![0];
        Assert.Equal(20, b.MaxOutputTokens);
        Assert.True(b.SupportsReasoning);

        Assert.Equal("llama3", ModelListParser.Parse("""{"models":[{"name":"llama3"}]}""")![0].Id);
        Assert.Equal(3000, ModelListParser.Parse("""[{"id":"c","capabilities":{"context_length":"3000"}}]""")![0].ContextLength);
        Assert.Null(ModelListParser.Parse("<html>"));
    }

    [Fact]
    public void ClassifiesProbeResponses()
    {
        Assert.Equal(ProbeStatus.Ok, EndpointClient.Classify(200, "").Status);
        Assert.Equal(ProbeStatus.Failed, EndpointClient.Classify(404, "").Status);
        Assert.Equal(ProbeStatus.Failed, EndpointClient.Classify(401, "").Status);
        Assert.Equal(ProbeStatus.Ok, EndpointClient.Classify(429, "").Status);
        Assert.Equal(ProbeStatus.Ok, EndpointClient.Classify(400, """{"error":{"message":"max_tokens is too small"}}""").Status);
        Assert.Equal(ProbeStatus.Failed, EndpointClient.Classify(400, """{"error":{"message":"This endpoint is not supported"}}""").Status);
    }

    [Fact]
    public void ContextLabels()
    {
        Assert.Equal("128K", new ModelInfo { Id = "x", ContextLength = 128_000 }.ContextLabel);
        Assert.Equal("1M", new ModelInfo { Id = "x", ContextLength = 1_000_000 }.ContextLabel);
        Assert.Equal("1.5M", new ModelInfo { Id = "x", ContextLength = 1_500_000 }.ContextLabel);
    }
}

public class StateAndFileTests
{
    [Fact]
    public void StateRoundTripsAndToleratesMissingFields()
    {
        var paths = MakeHome();
        var store = new StateStore(paths.StateFile);
        Assert.Empty(store.Load().Endpoints);
        var state = new AppState { BridgeEnabled = true };
        state.Endpoints.Add(new Endpoint { Name = "A", BaseUrl = "https://a/v1", Effort = ReasoningEffort.Xhigh, Probe = new ProbeResult { Chat = ProbeStatus.Ok } });
        state.EnabledTools.Add(ToolId.Kilo);
        state.Originals[ToolId.Codex] = new() { ["model"] = "\"x\"" };
        store.Save(state);

        var loaded = store.Load();
        Assert.Equal("A", loaded.Endpoints[0].Name);
        Assert.Equal(ReasoningEffort.Xhigh, loaded.Endpoints[0].Effort);
        Assert.Equal(ProbeStatus.Ok, loaded.Endpoints[0].Probe!.Chat);
        Assert.Equal([ToolId.Kilo], loaded.EnabledTools);
        Assert.Equal("\"x\"", loaded.Originals[ToolId.Codex]["model"]);

        File.WriteAllText(paths.StateFile, """{"enabledTools":["Codex"]}""");
        Assert.Equal([ToolId.Codex], store.Load().EnabledTools);
    }

    [Fact]
    public void BrokenStateIsKeptNotOverwritten()
    {
        var paths = MakeHome();
        Write(paths.StateFile, "{ broken");
        var controller = new AppController(paths, new InMemoryKeyStore(), new BridgeManager(paths, null, new FakeControl()));
        Assert.True(controller.Notice!.IsError);
        Assert.False(File.Exists(paths.StateFile));
        Assert.Single(Directory.GetFiles(paths.Support, "state-unreadable-*.json"));
    }

    [Fact]
    public void BackupsArePrunedToLimit()
    {
        var paths = MakeHome();
        var file = Path.Combine(paths.Home, "config.toml");
        Write(file, "x");
        var store = new BackupStore(paths.BackupsDirectory, 3);
        for (var offset = 0; offset < 6; offset++) store.Backup(file, "codex", DateTimeOffset.UnixEpoch.AddSeconds(offset));
        Assert.Equal(3, store.Backups("codex").Count);
    }

    [Fact]
    public void WriteKeepsExistingPermissions()
    {
        if (OperatingSystem.IsWindows()) return;
        var paths = MakeHome();
        var file = Path.Combine(paths.Home, "c.toml");
        Write(file, "x");
        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
        FileSupport.WriteAtomically(file, "y"u8.ToArray());
        Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead, File.GetUnixFileMode(file));
        Assert.Equal("y", File.ReadAllText(file));
    }

    [Fact]
    public void CredentialLineWorksInEveryShell()
    {
        var line = new CredentialHelper(@"C:\Users\John Doe\ModelBarGateway.exe").ShellLine(@"C:\Users\John Doe\key.key");
        Assert.Equal("\"C:/Users/John Doe/ModelBarGateway.exe\" --print-file \"C:/Users/John Doe/key.key\"", line);
    }
}

public class SyncEngineTests
{
    private static (AppPaths, InMemoryKeyStore, SyncEngine, FakeControl, AppState) Setup(ProbeResult? probe = null, Func<int, int?>? health = null)
    {
        var paths = MakeHome();
        Directory.CreateDirectory(paths.CodexDirectory);
        Directory.CreateDirectory(paths.OpenCodeDirectory);
        InstallBinary(paths, "claude");
        File.WriteAllText(paths.CodexConfig, "model = \"orig\"\n");
        Directory.CreateDirectory(Path.GetDirectoryName(paths.InstalledGateway)!);
        File.WriteAllText(paths.InstalledGateway, "");
        var control = new FakeControl();
        var keys = new InMemoryKeyStore();
        var bridge = new BridgeManager(paths, null, control, health ?? (_ => BridgeInfo.Version), _ => true);
        var engine = new SyncEngine(paths, keys, bridge);
        var endpoint = new Endpoint { Name = "Q", BaseUrl = "https://q.example.com/v1", Models = [new ModelInfo { Id = "lite" }], SelectedModel = "lite", Probe = probe };
        keys.SetKey(endpoint.Id, "sk-upstream");
        var state = new AppState { ActiveEndpointId = endpoint.Id };
        state.Endpoints.Add(endpoint);
        return (paths, keys, engine, control, state);
    }

    private static readonly ProbeResult ChatOnly = new() { Models = ProbeStatus.Ok, Chat = ProbeStatus.Ok, Responses = ProbeStatus.Failed, Messages = ProbeStatus.Failed };

    [Fact]
    public void WritesPrivateKeyFileAndKeepsKeyOutOfConfigs()
    {
        var (paths, _, engine, _, state) = Setup();
        state.EnabledTools.AddRange([ToolId.OpenCode, ToolId.Codex]);
        var report = engine.Sync(state);
        Assert.IsType<ToolState.Synced>(report.Statuses[ToolId.OpenCode]);
        Assert.IsType<ToolState.Synced>(report.Statuses[ToolId.Codex]);
        Assert.IsType<ToolState.NotInstalled>(report.Statuses[ToolId.Kilo]);
        Assert.NotNull(report.Originals[ToolId.Codex]);

        var keyFile = paths.KeyFile(state.Endpoints[0].Id);
        Assert.Equal("sk-upstream", File.ReadAllText(keyFile));
        if (!OperatingSystem.IsWindows()) Assert.Equal(UnixFileMode.UserRead | UnixFileMode.UserWrite, File.GetUnixFileMode(keyFile));
        Assert.DoesNotContain("sk-upstream", File.ReadAllText(paths.CodexConfig));
    }

    [Fact]
    public void ExistingKeyFileAvoidsReadingKeyStore()
    {
        var (paths, keys, engine, _, state) = Setup();
        state.EnabledTools.Add(ToolId.OpenCode);
        FileSupport.WritePrivate(paths.KeyFile(state.Endpoints[0].Id), "sk-existing"u8.ToArray());
        keys.SetKey(state.Endpoints[0].Id, null);
        Assert.IsType<ToolState.Synced>(engine.Sync(state).Statuses[ToolId.OpenCode]);
        Assert.Equal("sk-existing", File.ReadAllText(paths.KeyFile(state.Endpoints[0].Id)));
    }

    [Fact]
    public void SecondSyncDoesNotRewriteWhenNothingChanged()
    {
        var (paths, _, engine, _, state) = Setup();
        state.EnabledTools.Add(ToolId.Codex);
        engine.Sync(state);
        var count = new BackupStore(paths.BackupsDirectory).Backups("Codex").Count;
        engine.Sync(state);
        Assert.Equal(count, new BackupStore(paths.BackupsDirectory).Backups("Codex").Count);
    }

    [Fact]
    public void IncompatibleToolIsLeftUntouchedAndKeepsOldKeyFile()
    {
        var (paths, keys, engine, _, state) = Setup();
        state.EnabledTools.AddRange([ToolId.OpenCode, ToolId.Codex]);
        engine.Sync(state);
        var oldFile = paths.KeyFile(state.Endpoints[0].Id);

        var next = new Endpoint { Name = "B", BaseUrl = "https://b.example.com/v1", Models = [new ModelInfo { Id = "x" }], SelectedModel = "x", Probe = ChatOnly };
        keys.SetKey(next.Id, "sk-next");
        state.Endpoints.Add(next);
        state.ActiveEndpointId = next.Id;
        var report = engine.Sync(state);
        Assert.IsType<ToolState.Synced>(report.Statuses[ToolId.OpenCode]);
        Assert.IsType<ToolState.Incompatible>(report.Statuses[ToolId.Codex]);
        Assert.True(File.Exists(oldFile));
        Assert.Equal("https://q.example.com/v1", new TomlDocument(File.ReadAllText(paths.CodexConfig)).GetString("base_url", "model_providers.modelbar"));
    }

    [Fact]
    public void DisableRestoresAndNoEnabledToolsRemovesKeyFiles()
    {
        var (paths, _, engine, _, state) = Setup();
        state.EnabledTools.Add(ToolId.Codex);
        var first = engine.Sync(state);
        state.Originals[ToolId.Codex] = first.Originals[ToolId.Codex];
        engine.Disable(ToolId.Codex, state);
        Assert.Equal("model = \"orig\"\n", File.ReadAllText(paths.CodexConfig));
        state.EnabledTools.Clear();
        engine.Sync(state);
        Assert.False(File.Exists(paths.KeyFile(state.Endpoints[0].Id)));
    }

    [Fact]
    public void ExternalChangeIsStale()
    {
        var (paths, _, engine, _, state) = Setup();
        state.EnabledTools.Add(ToolId.Codex);
        engine.Sync(state);
        File.WriteAllText(paths.CodexConfig, "model = \"changed\"\n");
        Assert.IsType<ToolState.Stale>(engine.CurrentStatuses(state)[ToolId.Codex]);
    }

    [Fact]
    public void BridgePointsToolsAtLocalService()
    {
        var (paths, _, engine, control, state) = Setup(ChatOnly);
        state.EnabledTools.AddRange([ToolId.Codex, ToolId.ClaudeCode]);
        state.BridgeEnabled = true;
        state.Endpoints[0].Effort = ReasoningEffort.High;
        var report = engine.Sync(state);
        Assert.IsType<ToolState.Synced>(report.Statuses[ToolId.Codex]);
        Assert.IsType<ToolState.Synced>(report.Statuses[ToolId.ClaudeCode]);
        Assert.Equal(1, control.Installs);
        var text = File.ReadAllText(paths.CodexConfig);
        Assert.Contains($"http://127.0.0.1:{BridgeInfo.SandboxPort}/v1", text);
        Assert.Contains("bridge.token", text.Replace("\\\\", "\\"));
        Assert.DoesNotContain("sk-upstream", text);
        Assert.Equal($"http://127.0.0.1:{BridgeInfo.SandboxPort}", Read(paths.ClaudeSettings).Obj("env").Str("ANTHROPIC_BASE_URL"));

        var config = BridgeConfig.Load(paths.BridgeConfig);
        Assert.Equal("https://q.example.com/v1", config.UpstreamBaseUrl);
        Assert.Equal("high", config.DefaultEffort);
        Assert.StartsWith("mb-", File.ReadAllText(paths.BridgeToken));
        Assert.IsType<ToolState.Synced>(engine.CurrentStatuses(state)[ToolId.Codex]);
    }

    [Fact]
    public void WithoutBridgeCodexIsLeftAlone()
    {
        var (paths, _, engine, control, state) = Setup(ChatOnly);
        state.EnabledTools.Add(ToolId.Codex);
        Assert.IsType<ToolState.Incompatible>(engine.Sync(state).Statuses[ToolId.Codex]);
        Assert.Equal(0, control.Installs);
        Assert.Equal("model = \"orig\"\n", File.ReadAllText(paths.CodexConfig));
    }

    [Fact]
    public void ServiceNotRespondingIsReportedAndCodexUntouched()
    {
        var (paths, _, engine, _, state) = Setup(ChatOnly, _ => null);
        state.EnabledTools.Add(ToolId.Codex);
        state.BridgeEnabled = true;
        Assert.IsType<ToolState.Failed>(engine.Sync(state).Statuses[ToolId.Codex]);
        Assert.Equal("model = \"orig\"\n", File.ReadAllText(paths.CodexConfig));
    }

    [Fact]
    public void OldServiceVersionIsRestarted()
    {
        var (_, _, engine, control, state) = Setup(ChatOnly, _ => BridgeInfo.Version - 1);
        state.EnabledTools.Add(ToolId.Codex);
        state.BridgeEnabled = true;
        engine.Sync(state);
        Assert.True(control.Restarts >= 1);
    }

    [Fact]
    public void ServiceStopsWithTheLastBridgedTool()
    {
        var (paths, _, engine, control, state) = Setup(ChatOnly);
        state.EnabledTools.AddRange([ToolId.Codex, ToolId.ClaudeCode]);
        state.BridgeEnabled = true;
        var report = engine.Sync(state);
        state.Originals[ToolId.Codex] = report.Originals[ToolId.Codex];
        state.Originals[ToolId.ClaudeCode] = report.Originals[ToolId.ClaudeCode];

        engine.Disable(ToolId.Codex, state);
        state.EnabledTools.Remove(ToolId.Codex);
        Assert.Equal(0, control.Uninstalls);
        engine.Disable(ToolId.ClaudeCode, state);
        Assert.Equal(1, control.Uninstalls);
        Assert.False(File.Exists(paths.BridgeConfig));
        Assert.False(File.Exists(paths.BridgeToken));
    }
}

#pragma warning disable CA1416 // 每个测试开头都判断了系统
public class WindowsOnlyTests
{
    [Fact]
    public void CredentialManagerRoundTrips()
    {
        if (!OperatingSystem.IsWindows()) return;
        var store = new CredentialManagerStore("ModelBar.Tests");
        var id = Guid.NewGuid();
        try
        {
            Assert.Null(store.GetKey(id));
            store.SetKey(id, "sk-first");
            Assert.Equal("sk-first", store.GetKey(id));
            store.SetKey(id, "sk-秘钥-second");
            Assert.Equal("sk-秘钥-second", store.GetKey(id));
        }
        finally
        {
            store.SetKey(id, null);
        }
        Assert.Null(store.GetKey(id));
    }

    [Fact]
    public void PrivateFilesAreOnlyReadableByCurrentUserAndSystem()
    {
        if (!OperatingSystem.IsWindows()) return;
        var paths = MakeHome();
        var file = paths.KeyFile(Guid.NewGuid());
        FileSupport.WritePrivate(file, "x"u8.ToArray());
        var security = new FileInfo(file).GetAccessControl();
        Assert.True(security.AreAccessRulesProtected);
        var identities = security.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier))
            .Cast<System.Security.AccessControl.FileSystemAccessRule>()
            .Select(rule => rule.IdentityReference.Value)
            .ToHashSet();
        Assert.Equal(
            new HashSet<string> { System.Security.Principal.WindowsIdentity.GetCurrent().User!.Value, "S-1-5-18" },
            identities);
    }
}
#pragma warning restore CA1416

public class EnvironmentTests
{
    [Fact]
    public void ReadsEnvironmentDespiteCaseVariants()
    {
        Environment.SetEnvironmentVariable("modelbar_case_probe", "a");
        Environment.SetEnvironmentVariable("MODELBAR_CASE_PROBE", "b");
        try
        {
            Assert.True(AppPaths.ReadEnvironment().ContainsKey("Modelbar_Case_Probe"));
        }
        finally
        {
            Environment.SetEnvironmentVariable("modelbar_case_probe", null);
            Environment.SetEnvironmentVariable("MODELBAR_CASE_PROBE", null);
        }
    }
}
