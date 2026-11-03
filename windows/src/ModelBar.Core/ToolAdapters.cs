using System.Text;
using System.Text.Json.Nodes;

namespace ModelBar.Core;

public static class ManagedName
{
    public const string Provider = "modelbar";
}

/// <summary>工具用这条命令读取 Key 文件。不依赖 cmd、PowerShell 或 Git Bash，它们在各工具里并不统一。</summary>
public sealed record CredentialHelper(string Executable)
{
    public static readonly string[] Prefix = ["--print-file"];

    /// <summary>给会经过 shell 的工具用。正斜杠和双引号在 cmd 与 bash 里都能正确解析。</summary>
    public string ShellLine(string file) =>
        $"\"{Executable.Replace('\\', '/')}\" {Prefix[0]} \"{file.Replace('\\', '/')}\"";
}

public sealed record BridgeTarget(string BaseUrl, string TokenFile);

public sealed class SyncContext
{
    public required Endpoint Endpoint { get; init; }
    public required ModelInfo Model { get; init; }
    public string? KeyFile { get; init; }
    public required AppPaths Paths { get; init; }
    public required BackupStore Backups { get; init; }
    public required CredentialHelper Helper { get; init; }
    /// <summary>有值时，工具改连本机转换服务，而不是直接连接口。</summary>
    public BridgeTarget? Bridge { get; set; }

    public SyncContext WithBridge(BridgeTarget? bridge) => new()
    {
        Endpoint = Endpoint,
        Model = Model,
        KeyFile = KeyFile,
        Paths = Paths,
        Backups = Backups,
        Helper = Helper,
        Bridge = bridge,
    };
}

public interface IToolAdapter
{
    ToolId Id { get; }
    bool IsInstalled(AppPaths paths);
    string ConfigFile(AppPaths paths);
    string? Incompatibility(Endpoint endpoint, bool bridgeEnabled);
    /// <summary>写入配置。文件尚未被接管时返回需要保存的原值，否则返回 null。</summary>
    Dictionary<string, string>? Apply(SyncContext context);
    void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals);
    bool IsApplied(SyncContext context);
    /// <summary>让正在运行的进程读到新配置，返回需要告诉用户的说明。</summary>
    string? Reload(AppPaths paths) => null;
}

// opencode / Kilo

/// <summary>opencode 和 Kilo 共用同一种配置结构，只是目录和文件名不同。</summary>
public sealed class OpenCodeFamilyAdapter(
    ToolId id,
    string baseName,
    Func<AppPaths, string> directory,
    Func<AppPaths, bool> installed,
    Func<AppPaths, string?>? reloader = null) : IToolAdapter
{
    private const string ModelKey = "model";

    public ToolId Id => id;
    public bool IsInstalled(AppPaths paths) => installed(paths);
    public string ConfigFile(AppPaths paths) => AppPaths.JsonConfig(directory(paths), baseName);
    public string? Reload(AppPaths paths) => reloader?.Invoke(paths);

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled) =>
        endpoint.Probe is { Chat: ProbeStatus.Failed, Responses: ProbeStatus.Failed } ? "这个接口没有通过 Chat 和 Responses 测试" : null;

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var file = ConfigFile(context.Paths);
        var root = JsonConfigFile.Load(file);

        var current = root.Str(ModelKey);
        Dictionary<string, string>? originals = null;
        if (!IsManaged(current))
            originals = current is null ? [] : new() { [ModelKey] = current };

        var providers = root.Obj("provider") ?? [];
        providers[ManagedName.Provider] = ProviderBlock(context);
        root["provider"] = providers;
        root[ModelKey] = $"{ManagedName.Provider}/{context.Model.Id}";

        JsonConfigFile.Save(root, file, context.Backups, id.ToString());
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var file = ConfigFile(paths);
        if (!File.Exists(file)) return;
        var root = JsonConfigFile.Load(file);
        if (root.Obj("provider") is { } providers)
        {
            providers.Remove(ManagedName.Provider);
            if (providers.Count == 0) root.Remove("provider");
        }
        if (IsManaged(root.Str(ModelKey)))
        {
            if (originals.TryGetValue(ModelKey, out var model)) root[ModelKey] = model;
            else root.Remove(ModelKey);
        }
        JsonConfigFile.Save(root, file, backups, id.ToString());
    }

    public bool IsApplied(SyncContext context)
    {
        JsonObject root;
        try
        {
            root = JsonConfigFile.Load(ConfigFile(context.Paths));
        }
        catch (ConfigException)
        {
            return false;
        }
        var provider = root.Obj("provider").Obj(ManagedName.Provider);
        return root.Str(ModelKey) == $"{ManagedName.Provider}/{context.Model.Id}"
            && provider.Obj("options").Str("baseURL") == context.Endpoint.BaseUrl
            && provider.Obj("models").Obj(context.Model.Id) is { } model
            && model.Obj("options").Str("reasoningEffort") == context.Endpoint.Effort.WireValue();
    }

    private static bool IsManaged(string? model) => model?.StartsWith(ManagedName.Provider + "/", StringComparison.Ordinal) == true;

    private static JsonObject ProviderBlock(SyncContext context)
    {
        var endpoint = context.Endpoint;
        var usesResponses = endpoint.Probe is { Chat: ProbeStatus.Failed, Responses: ProbeStatus.Ok };
        var catalog = endpoint.Models.Take(300).ToList();
        if (catalog.All(m => m.Id != context.Model.Id)) catalog.Add(context.Model);

        var models = new JsonObject();
        foreach (var model in catalog)
        {
            models[model.Id] = ModelBlock(model, model.Id == context.Model.Id ? endpoint.Effort : ReasoningEffort.Automatic);
        }
        return new JsonObject
        {
            ["npm"] = usesResponses ? "@ai-sdk/openai" : "@ai-sdk/openai-compatible",
            ["name"] = $"ModelBar · {endpoint.Name}",
            ["options"] = new JsonObject
            {
                ["baseURL"] = endpoint.BaseUrl,
                ["apiKey"] = context.KeyFile is { } file ? $"{{file:{file}}}" : "none",
            },
            ["models"] = models,
        };
    }

    private static JsonObject ModelBlock(ModelInfo model, ReasoningEffort effort)
    {
        var block = new JsonObject
        {
            ["name"] = model.Id,
            ["tool_call"] = true,
            ["limit"] = new JsonObject
            {
                ["context"] = model.ContextLength ?? 128_000,
                ["output"] = model.MaxOutputTokens ?? 8_192,
            },
        };
        if (model.SupportsReasoning != false)
        {
            var variants = new JsonObject();
            foreach (var level in model.AvailableEfforts.Select(e => e.WireValue()).OfType<string>())
                variants[level] = new JsonObject { ["reasoningEffort"] = level };
            block["variants"] = variants;
        }
        if (model.SupportsReasoning == true || effort != ReasoningEffort.Automatic) block["reasoning"] = true;
        if (effort.WireValue() is { } value) block["options"] = new JsonObject { ["reasoningEffort"] = value };
        return block;
    }
}

// Codex CLI

public sealed class CodexAdapter : IToolAdapter
{
    private const string Table = "model_providers." + ManagedName.Provider;
    private const string Marker = "# Managed by ModelBar";
    private static readonly string[] ManagedKeys = ["model", "model_provider", "model_reasoning_effort", "model_context_window"];

    public ToolId Id => ToolId.Codex;
    public bool IsInstalled(AppPaths paths) => paths.FindBinary("codex") is not null || Directory.Exists(paths.CodexDirectory);
    public string ConfigFile(AppPaths paths) => paths.CodexConfig;

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled)
    {
        if (endpoint.Probe?.Responses != ProbeStatus.Failed) return null;
        if (endpoint.Probe.Chat == ProbeStatus.Failed) return "这个接口没有通过 Chat 和 Responses 测试，Codex 的配置保持不变";
        return bridgeEnabled ? null : "这个接口不支持 Responses API，Codex 的配置保持不变";
    }

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var file = ConfigFile(context.Paths);
        var document = new TomlDocument(ReadText(file));

        Dictionary<string, string>? originals = null;
        if (document.GetString("model_provider") != ManagedName.Provider)
        {
            originals = [];
            foreach (var key in ManagedKeys)
            {
                if (document.RawValue(key) is { } raw) originals[key] = raw;
            }
        }

        var endpoint = context.Endpoint;
        document.SetTopLevel("model", TomlDocument.Quote(context.Model.Id));
        document.SetTopLevel("model_provider", TomlDocument.Quote(ManagedName.Provider));
        document.SetTopLevel("model_reasoning_effort", endpoint.Effort.WireValue() is { } effort ? TomlDocument.Quote(effort) : null);
        document.SetTopLevel("model_context_window", context.Model.ContextLength?.ToString());

        document.RemoveTable(Table, Marker);
        var name = context.Bridge is null ? $"ModelBar · {endpoint.Name}" : $"ModelBar · {endpoint.Name}（本机转换）";
        var block = new List<string>
        {
            Marker,
            $"[{Table}]",
            $"name = {TomlDocument.Quote(name)}",
            $"base_url = {TomlDocument.Quote(context.Bridge?.BaseUrl ?? endpoint.BaseUrl)}",
            "wire_api = \"responses\"",
        };
        if ((context.Bridge?.TokenFile ?? context.KeyFile) is { } credential)
        {
            block.AddRange(
            [
                "",
                $"[{Table}.auth]",
                $"command = {TomlDocument.Quote(context.Helper.Executable)}",
                $"args = [{TomlDocument.Quote(CredentialHelper.Prefix[0])}, {TomlDocument.Quote(credential)}]",
            ]);
        }
        document.AppendBlock(block);

        context.Backups.Backup(file, Id.ToString());
        FileSupport.WriteAtomically(file, Encoding.UTF8.GetBytes(document.Text));
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var file = ConfigFile(paths);
        if (!File.Exists(file)) return;
        var document = new TomlDocument(ReadText(file));
        if (document.GetString("model_provider") == ManagedName.Provider)
        {
            foreach (var key in ManagedKeys) document.SetTopLevel(key, originals.GetValueOrDefault(key));
        }
        document.RemoveTable(Table, Marker);
        backups.Backup(file, Id.ToString());
        FileSupport.WriteAtomically(file, Encoding.UTF8.GetBytes(document.Text));
    }

    public bool IsApplied(SyncContext context)
    {
        var document = new TomlDocument(ReadText(ConfigFile(context.Paths)));
        return document.GetString("model_provider") == ManagedName.Provider
            && document.GetString("model") == context.Model.Id
            && document.GetString("base_url", Table) == (context.Bridge?.BaseUrl ?? context.Endpoint.BaseUrl)
            && document.GetString("model_reasoning_effort") == context.Endpoint.Effort.WireValue();
    }

    internal static string ReadText(string file) => File.Exists(file) ? File.ReadAllText(file) : "";
}

// Claude Code

/// <summary>写 settings.json 的 env 和 apiKeyHelper，VS Code 里的 Claude Code 扩展读的是同一份。</summary>
public sealed class ClaudeCodeAdapter : IToolAdapter
{
    private const string Marker = "MODELBAR_MANAGED";
    private const string HelperKey = "apiKeyHelper";
    private static readonly string[] ModelKeys =
    [
        "ANTHROPIC_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL",
        "ANTHROPIC_DEFAULT_SONNET_MODEL",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_SUBAGENT_MODEL",
    ];
    /// <summary>令牌类的环境变量优先级高于 apiKeyHelper，必须先移走。</summary>
    private static readonly string[] ManagedEnvKeys =
        [.. ModelKeys, "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_EFFORT_LEVEL"];

    public ToolId Id => ToolId.ClaudeCode;
    public bool IsInstalled(AppPaths paths) => paths.FindBinary("claude") is not null;
    public string ConfigFile(AppPaths paths) => paths.ClaudeSettings;

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled)
    {
        if (endpoint.Probe is not { } probe || probe.Messages == ProbeStatus.Ok) return null;
        if (probe.Chat == ProbeStatus.Failed) return "这个接口没有通过 Chat 和 Anthropic 测试，Claude Code 的配置保持不变";
        if (bridgeEnabled && probe.Messages == ProbeStatus.Failed) return null;
        return probe.Messages == ProbeStatus.Unknown
            ? "还不确定这个接口是否支持 Anthropic 协议，请重新测试接口"
            : "这个接口不支持 Anthropic 协议，Claude Code 的配置保持不变";
    }

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var file = ConfigFile(context.Paths);
        var root = JsonConfigFile.Load(file);
        var env = root.Obj("env") ?? [];

        Dictionary<string, string>? originals = null;
        if (!env.ContainsKey(Marker))
        {
            originals = [];
            foreach (var key in ManagedEnvKeys)
            {
                if (env.Str(key) is { } value) originals[$"env.{key}"] = value;
            }
            if (root.Str(HelperKey) is { } helper) originals[HelperKey] = helper;
        }

        foreach (var key in ManagedEnvKeys) env.Remove(key);
        env[Marker] = "1";
        env["ANTHROPIC_BASE_URL"] = BaseUrl(context);
        foreach (var key in ModelKeys) env[key] = context.Model.Id;
        if (context.Endpoint.Effort.WireValue() is { } effort) env["CLAUDE_CODE_EFFORT_LEVEL"] = effort;
        root["env"] = env;

        if ((context.Bridge?.TokenFile ?? context.KeyFile) is { } credential) root[HelperKey] = context.Helper.ShellLine(credential);
        else root.Remove(HelperKey);

        JsonConfigFile.Save(root, file, context.Backups, Id.ToString());
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var file = ConfigFile(paths);
        if (!File.Exists(file)) return;
        var root = JsonConfigFile.Load(file);
        if (root.Obj("env") is not { } env || !env.ContainsKey(Marker)) return;
        env.Remove(Marker);
        foreach (var key in ManagedEnvKeys)
        {
            if (originals.TryGetValue($"env.{key}", out var value)) env[key] = value;
            else env.Remove(key);
        }
        if (env.Count == 0) root.Remove("env");
        if (originals.TryGetValue(HelperKey, out var helper)) root[HelperKey] = helper;
        else root.Remove(HelperKey);
        JsonConfigFile.Save(root, file, backups, Id.ToString());
    }

    public bool IsApplied(SyncContext context)
    {
        JsonObject root;
        try
        {
            root = JsonConfigFile.Load(ConfigFile(context.Paths));
        }
        catch (ConfigException)
        {
            return false;
        }
        if (root.Obj("env") is not { } env || !env.ContainsKey(Marker)) return false;
        return env.Str("ANTHROPIC_BASE_URL") == BaseUrl(context)
            && env.Str("ANTHROPIC_MODEL") == context.Model.Id
            && env.Str("CLAUDE_CODE_EFFORT_LEVEL") == context.Endpoint.Effort.WireValue();
    }

    /// <summary>Claude Code 自己会加 /v1/messages，所以地址里不能带 /v1。</summary>
    private static string BaseUrl(SyncContext context)
    {
        var url = context.Bridge?.BaseUrl ?? context.Endpoint.BaseUrl;
        return url.EndsWith("/v1", StringComparison.Ordinal) ? url[..^3] : url;
    }
}

// pi

/// <summary>接口写进 models.json，默认模型写进 settings.json。</summary>
public sealed class PiAdapter : IToolAdapter
{
    private static readonly string[] SettingKeys = ["defaultProvider", "defaultModel", "defaultThinkingLevel"];
    private const string EnabledPrefix = ManagedName.Provider + "/";

    public ToolId Id => ToolId.Pi;
    public bool IsInstalled(AppPaths paths) => paths.FindBinary("pi") is not null;
    public string ConfigFile(AppPaths paths) => Path.Combine(paths.PiDirectory, "models.json");
    private static string SettingsFile(AppPaths paths) => Path.Combine(paths.PiDirectory, "settings.json");

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled) =>
        endpoint.Probe is { Chat: ProbeStatus.Failed, Responses: ProbeStatus.Failed } ? "这个接口没有通过 Chat 和 Responses 测试" : null;

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var modelsFile = ConfigFile(context.Paths);
        var settingsFile = SettingsFile(context.Paths);
        var models = JsonConfigFile.Load(modelsFile);
        var settings = JsonConfigFile.Load(settingsFile);

        Dictionary<string, string>? originals = null;
        if (settings.Str("defaultProvider") != ManagedName.Provider)
        {
            originals = [];
            foreach (var key in SettingKeys)
            {
                if (settings.Str(key) is { } value) originals[key] = value;
            }
        }

        var providers = models.Obj("providers") ?? [];
        providers[ManagedName.Provider] = ProviderBlock(context);
        models["providers"] = providers;

        settings["defaultProvider"] = ManagedName.Provider;
        settings["defaultModel"] = context.Model.Id;
        if (context.Endpoint.Effort.WireValue() is { } effort) settings["defaultThinkingLevel"] = effort;
        else settings.Remove("defaultThinkingLevel");

        // 有 enabledModels 白名单时，不在名单里的默认模型会被跳过。
        if (settings.Arr("enabledModels") is { } enabled)
        {
            RemoveManaged(enabled);
            enabled.Insert(0, EnabledPrefix + context.Model.Id);
        }

        JsonConfigFile.Save(models, modelsFile, context.Backups, "Pi-models");
        JsonConfigFile.Save(settings, settingsFile, context.Backups, "Pi-settings");
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var modelsFile = ConfigFile(paths);
        if (File.Exists(modelsFile))
        {
            var models = JsonConfigFile.Load(modelsFile);
            if (models.Obj("providers") is { } providers && providers.Remove(ManagedName.Provider))
            {
                if (providers.Count == 0) models.Remove("providers");
                JsonConfigFile.Save(models, modelsFile, backups, "Pi-models");
            }
        }
        var settingsFile = SettingsFile(paths);
        if (!File.Exists(settingsFile)) return;
        var settings = JsonConfigFile.Load(settingsFile);
        if (settings.Arr("enabledModels") is { } enabled) RemoveManaged(enabled);
        if (settings.Str("defaultProvider") == ManagedName.Provider)
        {
            foreach (var key in SettingKeys)
            {
                if (originals.TryGetValue(key, out var value)) settings[key] = value;
                else settings.Remove(key);
            }
        }
        JsonConfigFile.Save(settings, settingsFile, backups, "Pi-settings");
    }

    public bool IsApplied(SyncContext context)
    {
        JsonObject settings, models;
        try
        {
            settings = JsonConfigFile.Load(SettingsFile(context.Paths));
            models = JsonConfigFile.Load(ConfigFile(context.Paths));
        }
        catch (ConfigException)
        {
            return false;
        }
        if (settings.Arr("enabledModels") is { } enabled
            && !enabled.Any(node => node?.GetValue<string>() == EnabledPrefix + context.Model.Id)) return false;
        return settings.Str("defaultProvider") == ManagedName.Provider
            && settings.Str("defaultModel") == context.Model.Id
            && settings.Str("defaultThinkingLevel") == context.Endpoint.Effort.WireValue()
            && models.Obj("providers").Obj(ManagedName.Provider).Str("baseUrl") == context.Endpoint.BaseUrl;
    }

    private static void RemoveManaged(JsonArray enabled)
    {
        for (var index = enabled.Count - 1; index >= 0; index--)
        {
            if (enabled[index] is JsonValue value && value.TryGetValue<string>(out var text) && text.StartsWith(EnabledPrefix, StringComparison.Ordinal))
                enabled.RemoveAt(index);
        }
    }

    private static JsonObject ProviderBlock(SyncContext context)
    {
        var endpoint = context.Endpoint;
        var catalog = endpoint.Models.Take(300).ToList();
        if (catalog.All(m => m.Id != context.Model.Id)) catalog.Add(context.Model);
        var usesResponses = endpoint.Probe is { Chat: ProbeStatus.Failed, Responses: ProbeStatus.Ok };
        var models = new JsonArray();
        foreach (var model in catalog)
        {
            models.Add(new JsonObject
            {
                ["id"] = model.Id,
                ["name"] = model.Id,
                ["input"] = new JsonArray("text"),
                ["reasoning"] = model.SupportsReasoning != false,
                ["contextWindow"] = model.ContextLength ?? 128_000,
                ["maxTokens"] = model.MaxOutputTokens ?? 8_192,
                ["cost"] = new JsonObject { ["input"] = 0, ["output"] = 0, ["cacheRead"] = 0, ["cacheWrite"] = 0 },
            });
        }
        return new JsonObject
        {
            ["name"] = $"ModelBar · {endpoint.Name}",
            ["api"] = usesResponses ? "openai-responses" : "openai-completions",
            ["baseUrl"] = endpoint.BaseUrl,
            // 以 ! 开头时，pi 运行这条命令并用它的输出作为 Key。
            ["apiKey"] = context.KeyFile is { } file ? "!" + context.Helper.ShellLine(file) : "none",
            ["models"] = models,
        };
    }
}

// Grok

public sealed class GrokAdapter : IToolAdapter
{
    private const string ModelTable = "model." + ManagedName.Provider;
    private const string AuthTable = "auth_provider." + ManagedName.Provider;
    private const string Marker = "# Managed by ModelBar";

    public ToolId Id => ToolId.Grok;
    public bool IsInstalled(AppPaths paths) => paths.FindBinary("grok") is not null;
    public string ConfigFile(AppPaths paths) => paths.GrokConfig;

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled) =>
        endpoint.Probe?.Chat == ProbeStatus.Failed ? "这个接口没有通过 Chat 测试，Grok 的配置保持不变" : null;

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var file = ConfigFile(context.Paths);
        var document = new TomlDocument(CodexAdapter.ReadText(file));

        Dictionary<string, string>? originals = null;
        if (document.GetString("default", "models") != ManagedName.Provider)
            originals = document.RawValue("default", "models") is { } raw ? new() { ["default"] = raw } : [];

        document.Set("default", TomlDocument.Quote(ManagedName.Provider), "models");
        RemoveManagedTables(document);

        var endpoint = context.Endpoint;
        var block = new List<string>
        {
            Marker,
            $"[{ModelTable}]",
            $"model = {TomlDocument.Quote(context.Model.Id)}",
            $"base_url = {TomlDocument.Quote(endpoint.BaseUrl)}",
            $"name = {TomlDocument.Quote($"ModelBar · {endpoint.Name}")}",
        };
        if (context.Model.ContextLength is { } length) block.Add($"context_window = {length}");
        if (context.KeyFile is { } keyFile)
        {
            block.AddRange(
            [
                $"auth_provider = {TomlDocument.Quote(ManagedName.Provider)}",
                "",
                Marker,
                $"[{AuthTable}]",
                $"command = {TomlDocument.Quote(context.Helper.Executable)}",
                $"args = [{TomlDocument.Quote(CredentialHelper.Prefix[0])}, {TomlDocument.Quote(keyFile)}]",
            ]);
        }
        document.AppendBlock(block);

        context.Backups.Backup(file, Id.ToString());
        FileSupport.WriteAtomically(file, Encoding.UTF8.GetBytes(document.Text));
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var file = ConfigFile(paths);
        if (!File.Exists(file)) return;
        var document = new TomlDocument(CodexAdapter.ReadText(file));
        // 先删自己的表：它们前面的注释会让 [models] 看起来不是空表。
        RemoveManagedTables(document);
        if (document.GetString("default", "models") == ManagedName.Provider)
            document.Set("default", originals.GetValueOrDefault("default"), "models");
        backups.Backup(file, Id.ToString());
        FileSupport.WriteAtomically(file, Encoding.UTF8.GetBytes(document.Text));
    }

    public bool IsApplied(SyncContext context)
    {
        var document = new TomlDocument(CodexAdapter.ReadText(ConfigFile(context.Paths)));
        return document.GetString("default", "models") == ManagedName.Provider
            && document.GetString("model", ModelTable) == context.Model.Id
            && document.GetString("base_url", ModelTable) == context.Endpoint.BaseUrl;
    }

    private static void RemoveManagedTables(TomlDocument document)
    {
        document.RemoveTable(ModelTable, Marker);
        document.RemoveTable(AuthTable, Marker);
    }
}

// Factory Droid

/// <summary>Droid 的自定义模型只接受明文 Key，所以 Key 会写进它的配置文件。</summary>
public sealed class DroidAdapter : IToolAdapter
{
    private const string DisplayName = "ModelBar";
    private static readonly string[] DefaultKeys = ["model", "reasoningEffort"];

    public ToolId Id => ToolId.Droid;
    public bool IsInstalled(AppPaths paths) => paths.FindBinary("droid") is not null;
    public string ConfigFile(AppPaths paths) => paths.DroidSettings;

    public string? Incompatibility(Endpoint endpoint, bool bridgeEnabled) =>
        endpoint.Probe is { Chat: ProbeStatus.Failed, Responses: ProbeStatus.Failed } ? "这个接口没有通过 Chat 和 Responses 测试" : null;

    public Dictionary<string, string>? Apply(SyncContext context)
    {
        var file = ConfigFile(context.Paths);
        var root = JsonConfigFile.Load(file);
        var defaults = root.Obj("sessionDefaultSettings") ?? [];

        Dictionary<string, string>? originals = null;
        if (!IsManaged(defaults.Str("model")))
        {
            originals = [];
            foreach (var key in DefaultKeys)
            {
                if (defaults.Str(key) is { } value) originals[key] = value;
            }
        }

        var models = root.Arr("customModels") ?? [];
        RemoveManaged(models);
        var entry = new JsonObject
        {
            ["model"] = context.Model.Id,
            ["displayName"] = DisplayName,
            ["baseUrl"] = context.Endpoint.BaseUrl,
            ["apiKey"] = context.KeyFile is { } key2 ? File.ReadAllText(key2) : "none",
            ["provider"] = context.Endpoint.Probe?.Chat == ProbeStatus.Failed ? "openai" : "generic-chat-completion-api",
        };
        if (context.Model.MaxOutputTokens is { } limit) entry["maxOutputTokens"] = limit;
        models.Add(entry);
        root["customModels"] = models;

        // Droid 用“显示名-序号”引用自定义模型。
        defaults["model"] = $"custom:{DisplayName}-{models.Count - 1}";
        if (context.Endpoint.Effort.WireValue() is { } effort) defaults["reasoningEffort"] = effort;
        else defaults.Remove("reasoningEffort");
        root["sessionDefaultSettings"] = defaults;

        JsonConfigFile.Save(root, file, context.Backups, Id.ToString());
        FileSupport.RestrictFile(file);
        return originals;
    }

    public void Restore(AppPaths paths, BackupStore backups, Dictionary<string, string> originals)
    {
        var file = ConfigFile(paths);
        if (!File.Exists(file)) return;
        var root = JsonConfigFile.Load(file);
        if (root.Arr("customModels") is { } models)
        {
            RemoveManaged(models);
            if (models.Count == 0) root.Remove("customModels");
        }
        if (root.Obj("sessionDefaultSettings") is { } defaults && IsManaged(defaults.Str("model")))
        {
            foreach (var key in DefaultKeys)
            {
                if (originals.TryGetValue(key, out var value)) defaults[key] = value;
                else defaults.Remove(key);
            }
            if (defaults.Count == 0) root.Remove("sessionDefaultSettings");
        }
        JsonConfigFile.Save(root, file, backups, Id.ToString());
    }

    public bool IsApplied(SyncContext context)
    {
        JsonObject root;
        try
        {
            root = JsonConfigFile.Load(ConfigFile(context.Paths));
        }
        catch (ConfigException)
        {
            return false;
        }
        var defaults = root.Obj("sessionDefaultSettings");
        if (!IsManaged(defaults.Str("model")) || defaults.Str("reasoningEffort") != context.Endpoint.Effort.WireValue()) return false;
        var entry = root.Arr("customModels").Objects().FirstOrDefault(m => m.Str("displayName") == DisplayName);
        return entry.Str("model") == context.Model.Id && entry.Str("baseUrl") == context.Endpoint.BaseUrl;
    }

    private static bool IsManaged(string? model) => model?.StartsWith($"custom:{DisplayName}-", StringComparison.Ordinal) == true;

    private static void RemoveManaged(JsonArray models)
    {
        for (var index = models.Count - 1; index >= 0; index--)
        {
            if (models[index] is JsonObject model && model.Str("displayName") == DisplayName) models.RemoveAt(index);
        }
    }
}

// 默认工具集

public static class ToolCatalog
{
    public static readonly IReadOnlyList<IToolAdapter> Adapters =
    [
        new ClaudeCodeAdapter(),
        new CodexAdapter(),
        new OpenCodeFamilyAdapter(
            ToolId.OpenCode, "opencode", p => p.OpenCodeDirectory,
            p => p.FindBinary("opencode") is not null || Directory.Exists(p.OpenCodeDirectory),
            OpenCodeService.RestartIfRunning),
        new PiAdapter(),
        new GrokAdapter(),
        new DroidAdapter(),
        new OpenCodeFamilyAdapter(
            ToolId.Kilo, "kilo", p => p.KiloDirectory,
            p => p.FindBinary("kilo") is not null || Directory.Exists(p.KiloDirectory) || KiloExtension.IsInstalled(p)),
    ];

    public static IToolAdapter Adapter(ToolId id) => Adapters.First(a => a.Id == id);
}

public static class KiloExtension
{
    public const string Identifier = "kilocode.Kilo-Code";

    public static bool IsInstalled(AppPaths paths) => paths.ExtensionRoots.Any(root =>
        Directory.Exists(root)
        && Directory.GetDirectories(root).Any(item => Path.GetFileName(item).StartsWith("kilocode.kilo-code", StringComparison.OrdinalIgnoreCase)));

    public static string? CursorCli(AppPaths paths)
    {
        var candidate = Path.Combine(paths.Home, "AppData", "Local", "Programs", "cursor", "resources", "app", "bin", "cursor.cmd");
        return File.Exists(candidate) ? candidate : paths.FindBinary("cursor");
    }

    public static void InstallIntoCursor(AppPaths paths)
    {
        var cli = CursorCli(paths) ?? throw new ConfigException("没有找到 Cursor");
        var result = ProcessRunner.Run(cli, ["--install-extension", Identifier], TimeSpan.FromMinutes(3));
        if (result.ExitCode != 0)
            throw new ConfigException("安装失败：" + result.Output[^Math.Min(200, result.Output.Length)..]);
    }
}

public static class OpenCodeService
{
    /// <summary>运行中的后台服务不会重新读取配置，所以切换后需要重启它。</summary>
    public static string? RestartIfRunning(AppPaths paths)
    {
        if (paths.FindBinary("opencode") is not { } binary) return null;
        var environment = paths.IsSandboxed ? SandboxEnvironment(paths) : null;
        var status = ProcessRunner.Run(binary, ["service", "status"], TimeSpan.FromSeconds(10), environment);
        if (status.ExitCode != 0 || !status.Output.TrimStart().StartsWith("http", StringComparison.Ordinal)) return null;
        var restart = ProcessRunner.Run(binary, ["service", "restart"], TimeSpan.FromSeconds(20), environment);
        return restart.ExitCode == 0 ? "已重启 opencode 后台服务" : "opencode 后台服务重启失败，请手动运行 opencode service restart";
    }

    private static Dictionary<string, string> SandboxEnvironment(AppPaths paths) => new()
    {
        ["XDG_CONFIG_HOME"] = Path.Combine(paths.Home, ".config"),
        ["XDG_DATA_HOME"] = Path.Combine(paths.Home, ".local", "share"),
        ["XDG_STATE_HOME"] = Path.Combine(paths.Home, ".local", "state"),
        ["XDG_CACHE_HOME"] = Path.Combine(paths.Home, ".cache"),
    };
}
