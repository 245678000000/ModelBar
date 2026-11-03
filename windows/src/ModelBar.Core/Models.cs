using System.Text.Json;
using System.Text.Json.Serialization;

namespace ModelBar.Core;

/// <summary>推理档位。Automatic 表示不覆盖，由接口或模型自行决定。</summary>
[JsonConverter(typeof(JsonStringEnumConverter<ReasoningEffort>))]
public enum ReasoningEffort { Automatic, Low, Medium, High, Xhigh }

public static class ReasoningEffortExtensions
{
    public static string Title(this ReasoningEffort effort) => effort switch
    {
        ReasoningEffort.Low => "低",
        ReasoningEffort.Medium => "中",
        ReasoningEffort.High => "高",
        ReasoningEffort.Xhigh => "极高",
        _ => "默认",
    };

    /// <summary>写入配置和请求时使用的值，Automatic 没有对应值。</summary>
    public static string? WireValue(this ReasoningEffort effort) =>
        effort == ReasoningEffort.Automatic ? null : effort.ToString().ToLowerInvariant();
}

public sealed class ModelInfo
{
    public required string Id { get; set; }
    public int? ContextLength { get; set; }
    public int? MaxOutputTokens { get; set; }
    public bool? SupportsReasoning { get; set; }
    public List<string>? EffortLevels { get; set; }

    /// <summary>接口声明了可选档位时只显示声明的档位，否则显示全部。</summary>
    [JsonIgnore]
    public IReadOnlyList<ReasoningEffort> AvailableEfforts =>
        EffortLevels is { Count: > 0 } levels
            ? Enum.GetValues<ReasoningEffort>().Where(e => e == ReasoningEffort.Automatic || levels.Contains(e.WireValue()!)).ToList()
            : Enum.GetValues<ReasoningEffort>();

    [JsonIgnore]
    public string? ContextLabel => ContextLength switch
    {
        null => null,
        >= 1_000_000 and var n => n % 1_000_000 == 0 ? $"{n / 1_000_000}M" : $"{n / 1_000_000.0:0.#}M",
        var n => $"{n / 1000}K",
    };
}

[JsonConverter(typeof(JsonStringEnumConverter<ProbeStatus>))]
public enum ProbeStatus { Unknown, Ok, Failed }

public sealed class ProbeResult
{
    public ProbeStatus Models { get; set; }
    public ProbeStatus Chat { get; set; }
    public ProbeStatus Responses { get; set; }
    public ProbeStatus Messages { get; set; }
    public int? LatencyMs { get; set; }
    public string? Message { get; set; }
    public DateTimeOffset TestedAt { get; set; } = DateTimeOffset.UtcNow;
}

public sealed class Endpoint
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public required string Name { get; set; }
    public required string BaseUrl { get; set; }
    public List<ModelInfo> Models { get; set; } = [];
    public string? SelectedModel { get; set; }
    public ReasoningEffort Effort { get; set; }
    public ProbeResult? Probe { get; set; }
    public bool HasKey { get; set; }

    [JsonIgnore]
    public string Host => Uri.TryCreate(BaseUrl, UriKind.Absolute, out var uri) ? uri.Host : BaseUrl;

    [JsonIgnore]
    public ModelInfo? CurrentModel => SelectedModel is null
        ? null
        : Models.FirstOrDefault(m => m.Id == SelectedModel) ?? new ModelInfo { Id = SelectedModel };

    /// <summary>去掉首尾空白、结尾斜杠，以及被误粘贴的具体接口路径。</summary>
    public static string Normalize(string raw)
    {
        var value = raw.Trim();
        foreach (var suffix in new[] { "/chat/completions", "/responses", "/models" })
        {
            if (value.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
            {
                value = value[..^suffix.Length];
                break;
            }
        }
        return value.TrimEnd('/');
    }

    public static bool IsValidBaseUrl(string raw) =>
        Uri.TryCreate(Normalize(raw), UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps)
        && !string.IsNullOrEmpty(uri.Host);

    /// <summary>跳过明显不是对话模型的条目，避免默认选中向量或语音模型。</summary>
    public static string? DefaultModel(IReadOnlyList<ModelInfo> models)
    {
        string[] excluded = ["embed", "whisper", "tts", "moderation", "rerank", "image", "dall-e", "audio", "transcribe", "ocr"];
        var chat = models.FirstOrDefault(m => !excluded.Any(word => m.Id.Contains(word, StringComparison.OrdinalIgnoreCase)));
        return (chat ?? models.FirstOrDefault())?.Id;
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<ToolId>))]
public enum ToolId { ClaudeCode, Codex, OpenCode, Pi, Grok, Droid, Kilo }

public static class ToolIdExtensions
{
    public static string Title(this ToolId tool) => tool switch
    {
        ToolId.ClaudeCode => "Claude Code",
        ToolId.Codex => "Codex CLI",
        ToolId.OpenCode => "opencode",
        ToolId.Pi => "pi",
        ToolId.Grok => "Grok",
        ToolId.Droid => "Factory Droid",
        _ => "Kilo Code",
    };

    public static string Subtitle(this ToolId tool) => tool switch
    {
        ToolId.ClaudeCode => "终端和 VS Code 扩展",
        ToolId.Codex => "终端和 Cursor / VS Code 扩展",
        ToolId.Kilo => "Cursor / VS Code 扩展",
        _ => "终端 Agent",
    };

    /// <summary>这个工具用不了接口的原生协议，需要本机转换才能接入。</summary>
    public static bool NeedsConversion(this ToolId tool, ProbeResult? probe)
    {
        if (probe is null || probe.Chat == ProbeStatus.Failed) return false;
        return tool switch
        {
            ToolId.Codex => probe.Responses == ProbeStatus.Failed,
            ToolId.ClaudeCode => probe.Messages == ProbeStatus.Failed,
            _ => false,
        };
    }
}

public sealed record Preset(string Name, string BaseUrl, bool NeedsKey)
{
    public static readonly IReadOnlyList<Preset> All =
    [
        new("DeepSeek", "https://api.deepseek.com/v1", true),
        new("OpenRouter", "https://openrouter.ai/api/v1", true),
        new("Kimi", "https://api.moonshot.cn/v1", true),
        new("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", true),
        new("硅基流动", "https://api.siliconflow.cn/v1", true),
        new("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", true),
        new("Ollama", "http://127.0.0.1:11434/v1", false),
    ];
}

public sealed class AppState
{
    public List<Endpoint> Endpoints { get; set; } = [];
    public Guid? ActiveEndpointId { get; set; }
    public List<ToolId> EnabledTools { get; set; } = [];
    public Dictionary<ToolId, Dictionary<string, string>> Originals { get; set; } = [];
    public bool BridgeEnabled { get; set; }

    [JsonIgnore]
    public Endpoint? ActiveEndpoint => Endpoints.FirstOrDefault(e => e.Id == ActiveEndpointId);

    /// <summary>用户开启了本机转换，并且有已启用的工具用不了当前接口的原生协议。</summary>
    [JsonIgnore]
    public bool NeedsBridge => BridgeEnabled && ToolsNeedingConversion.Count > 0;

    [JsonIgnore]
    public List<ToolId> ToolsNeedingConversion =>
        EnabledTools.Where(tool => tool.NeedsConversion(ActiveEndpoint?.Probe)).ToList();

    public AppState Clone() =>
        JsonSerializer.Deserialize(JsonSerializer.SerializeToUtf8Bytes(this, StateJsonContext.Default.AppState), StateJsonContext.Default.AppState)!;
}

[JsonSourceGenerationOptions(WriteIndented = true, PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UseStringEnumConverter = true)]
[JsonSerializable(typeof(AppState))]
public partial class StateJsonContext : JsonSerializerContext;

public sealed class StateStore(string file)
{
    public string File => file;

    public AppState Load()
    {
        if (!System.IO.File.Exists(file)) return new AppState();
        return JsonSerializer.Deserialize(System.IO.File.ReadAllBytes(file), StateJsonContext.Default.AppState) ?? new AppState();
    }

    public void Save(AppState state) =>
        FileSupport.WritePrivate(file, JsonSerializer.SerializeToUtf8Bytes(state, StateJsonContext.Default.AppState));

    /// <summary>读不了的文件先改名留存，防止之后保存时把它覆盖掉。</summary>
    public string? Quarantine()
    {
        if (!System.IO.File.Exists(file)) return null;
        var target = Path.Combine(Path.GetDirectoryName(file)!, $"state-unreadable-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.json");
        try
        {
            System.IO.File.Move(file, target);
            return target;
        }
        catch (IOException)
        {
            return null;
        }
    }
}
