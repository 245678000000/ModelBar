using System.Diagnostics;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ModelBar.Core;

public sealed class EndpointClient
{
    private readonly HttpClient _http;

    public EndpointClient(TimeSpan? timeout = null)
    {
        _http = new HttpClient { Timeout = timeout ?? TimeSpan.FromSeconds(15) };
    }

    public async Task<List<ModelInfo>> FetchModelsAsync(string baseUrl, string? key)
    {
        using var request = MakeRequest(HttpMethod.Get, baseUrl, "models", key);
        using var response = await _http.SendAsync(request);
        var text = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode) throw new ConfigException(DescribeModelsError((int)response.StatusCode, text));
        var models = ModelListParser.Parse(text);
        if (models is not { Count: > 0 }) throw new ConfigException("接口返回的内容不是模型列表");
        return models;
    }

    /// <summary>依次测试模型列表、Chat、Responses 和 Anthropic。后三项各发一条极短的真实请求。</summary>
    public async Task<(ProbeResult Result, List<ModelInfo> Models)> ProbeAsync(string baseUrl, string? key, string? model)
    {
        var result = new ProbeResult();
        var models = new List<ModelInfo>();

        var watch = Stopwatch.StartNew();
        try
        {
            models = await FetchModelsAsync(baseUrl, key);
            result.Models = ProbeStatus.Ok;
            result.LatencyMs = (int)watch.ElapsedMilliseconds;
        }
        catch (Exception error) when (error is ConfigException or HttpRequestException or TaskCanceledException)
        {
            result.Models = ProbeStatus.Failed;
            result.Message = Friendly(error);
        }

        var selected = model ?? Endpoint.DefaultModel(models);
        if (selected is null) return (result, models);

        var chat = PostAsync(baseUrl, "chat/completions", key, new JsonObject
        {
            ["model"] = selected,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "ping" }),
            ["max_tokens"] = 1,
            ["stream"] = false,
        });
        var responses = PostAsync(baseUrl, "responses", key, new JsonObject
        {
            ["model"] = selected,
            ["input"] = "ping",
            ["max_output_tokens"] = 16,
            ["stream"] = false,
        });
        var messages = PostAsync(baseUrl, "messages", key, new JsonObject
        {
            ["model"] = selected,
            ["max_tokens"] = 1,
            ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "ping" }),
        }, anthropic: true);
        await Task.WhenAll(chat, responses, messages);

        result.Chat = chat.Result.Status;
        result.Responses = responses.Result.Status;
        result.Messages = messages.Result.Status;
        if (result.Message is null && chat.Result.Status == ProbeStatus.Failed && responses.Result.Status == ProbeStatus.Failed)
            result.Message = chat.Result.Message ?? responses.Result.Message;
        return (result, models);
    }

    private async Task<(ProbeStatus Status, string? Message)> PostAsync(string baseUrl, string path, string? key, JsonObject body, bool anthropic = false)
    {
        try
        {
            using var request = MakeRequest(HttpMethod.Post, baseUrl, path, key);
            request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
            if (anthropic)
            {
                request.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
                if (!string.IsNullOrEmpty(key)) request.Headers.TryAddWithoutValidation("x-api-key", key);
            }
            using var response = await _http.SendAsync(request);
            return Classify((int)response.StatusCode, await response.Content.ReadAsStringAsync());
        }
        catch (Exception error) when (error is ConfigException or HttpRequestException or TaskCanceledException)
        {
            return (ProbeStatus.Failed, Friendly(error));
        }
    }

    /// <summary>判断路由是否存在。参数被拒（400/422）或限流（429）都说明接口本身是通的。</summary>
    public static (ProbeStatus Status, string? Message) Classify(int status, string text)
    {
        var message = ErrorMessage(text);
        switch (status)
        {
            case >= 200 and < 300:
                return (ProbeStatus.Ok, null);
            case 400 or 422 or 429:
                string[] unsupported = ["not support", "unsupported", "不支持", "unknown url", "invalid url", "no route"];
                var lowered = message?.ToLowerInvariant() ?? "";
                return (unsupported.Any(lowered.Contains) ? ProbeStatus.Failed : ProbeStatus.Ok, message);
            case 401 or 403:
                return (ProbeStatus.Failed, $"API Key 被拒绝（HTTP {status}）");
            default:
                return (ProbeStatus.Failed, message ?? $"HTTP {status}");
        }
    }

    private static HttpRequestMessage MakeRequest(HttpMethod method, string baseUrl, string path, string? key)
    {
        if (!Endpoint.IsValidBaseUrl(baseUrl)) throw new ConfigException("接口地址无效");
        var request = new HttpRequestMessage(method, Endpoint.Normalize(baseUrl) + "/" + path);
        if (!string.IsNullOrEmpty(key)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return request;
    }

    private static string DescribeModelsError(int status, string text) => status switch
    {
        401 or 403 => "API Key 被拒绝（HTTP 401/403）",
        404 => "地址不对：/models 返回 404，请确认是否需要带 /v1",
        _ => $"接口返回 HTTP {status}" + (ErrorMessage(text) is { } message ? $"：{message}" : ""),
    };

    private static string Friendly(Exception error) => error is TaskCanceledException ? "连接超时" : error.Message;

    private static string? ErrorMessage(string text)
    {
        try
        {
            if (JsonNode.Parse(text) is not JsonObject root) return null;
            return root.Obj("error").Str("message") ?? root.Str("error") ?? root.Str("message");
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

/// <summary>不同网关的 /models 字段各不相同，这里统一成一种结构。</summary>
public static class ModelListParser
{
    public static List<ModelInfo>? Parse(string text)
    {
        JsonNode? root;
        try
        {
            root = JsonNode.Parse(text);
        }
        catch (JsonException)
        {
            return null;
        }
        var items = root is JsonObject obj
            ? obj.Arr("data") ?? obj.Arr("models") ?? obj.Arr("result")
            : root as JsonArray;
        return items?.Objects().Select(ParseModel).OfType<ModelInfo>().ToList();
    }

    private static ModelInfo? ParseModel(JsonObject item)
    {
        var id = item.Str("id") ?? item.Str("model") ?? item.Str("name");
        if (string.IsNullOrEmpty(id)) return null;
        var capabilities = item.Obj("capabilities");
        var topProvider = item.Obj("top_provider");

        var context = First(item, "context_length", "context_window", "max_context_tokens", "input_token_limit", "max_input_tokens")
            ?? First(capabilities, "context_length", "context_window")
            ?? First(topProvider, "context_length");
        var output = First(item, "max_output_tokens", "max_completion_tokens", "output_token_limit")
            ?? First(capabilities, "max_output_tokens")
            ?? First(topProvider, "max_completion_tokens");

        var levels = Strings(item.Obj("effort").Arr("supported_levels"))
            ?? Strings(capabilities.Arr("reasoning_effort"))
            ?? Strings(item.Arr("supported_reasoning_efforts"))
            ?? Strings(item.Arr("reasoning_effort"));

        var reasoning = item.Bool("supports_reasoning") ?? capabilities.Bool("supports_reasoning");
        if (reasoning is null && Strings(item.Arr("supported_parameters")) is { } parameters)
            reasoning = parameters.Contains("reasoning") || parameters.Contains("reasoning_effort");
        if (reasoning is null && levels is { Count: > 0 }) reasoning = true;

        return new ModelInfo { Id = id, ContextLength = context, MaxOutputTokens = output, SupportsReasoning = reasoning, EffortLevels = levels };
    }

    private static int? First(JsonObject? obj, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (obj.Int(key) is > 0 and var value) return value;
        }
        return null;
    }

    private static List<string>? Strings(JsonArray? array) =>
        array?.Select(node => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null).OfType<string>().ToList();
}
