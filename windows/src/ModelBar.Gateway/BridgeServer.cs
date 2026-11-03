using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ModelBar.Core;

namespace ModelBar.Gateway;

/// <summary>
/// 只监听本机的 HTTP 服务：接收工具的 Responses 或 Anthropic 请求，转给上游的 Chat 接口。
/// 日志记录路径、状态、耗时和上游的报错，不记录密钥和请求内容。
/// </summary>
public sealed class BridgeServer
{
    private const int MaxRequestSize = 256 * 1024 * 1024;
    private readonly string _configFile;
    private readonly int _port;
    private readonly HttpClient _http = new(new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(5) })
    {
        Timeout = Timeout.InfiniteTimeSpan,
    };

    public BridgeServer(string configFile, int port)
    {
        _configFile = configFile;
        _port = port;
    }

    public async Task RunAsync()
    {
        var listener = new TcpListener(IPAddress.Loopback, _port);
        listener.Start();
        BridgeLog.Write($"listening on 127.0.0.1:{_port}");
        while (true)
        {
            var client = await listener.AcceptTcpClientAsync();
            _ = Task.Run(() => HandleAsync(client));
        }
    }

    private async Task HandleAsync(TcpClient tcp)
    {
        using (tcp)
        {
            try
            {
                tcp.NoDelay = true;
                var stream = tcp.GetStream();
                var request = await ReadRequestAsync(stream);
                if (request is null) return;
                var started = DateTime.UtcNow;
                var status = await RouteAsync(request, new Responder(stream));
                BridgeLog.Write($"{request.Method} {request.Path} {status} {(DateTime.UtcNow - started).TotalSeconds:0.00}s");
            }
            catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException or OperationCanceledException)
            {
                // 客户端提前断开。
            }
        }
    }

    private sealed record HttpRequest(string Method, string Path, Dictionary<string, string> Headers, byte[] Body);

    private static async Task<HttpRequest?> ReadRequestAsync(NetworkStream stream)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        int headerEnd;
        while ((headerEnd = IndexOfHeaderEnd(buffer)) < 0)
        {
            var count = await stream.ReadAsync(chunk);
            if (count == 0 || buffer.Length > 1024 * 1024) return null;
            buffer.Write(chunk, 0, count);
        }
        var data = buffer.GetBuffer();
        var lines = Encoding.UTF8.GetString(data, 0, headerEnd).Split("\r\n");
        var parts = lines[0].Split(' ');
        if (parts.Length < 2) return null;

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon > 0) headers[line[..colon].Trim()] = line[(colon + 1)..].Trim();
        }
        var length = headers.TryGetValue("content-length", out var text) && int.TryParse(text, out var parsed) ? parsed : 0;
        if (length > MaxRequestSize) return null;

        var bodyStart = headerEnd + 4;
        var body = new byte[length];
        var have = (int)Math.Min(buffer.Length - bodyStart, length);
        Array.Copy(data, bodyStart, body, 0, have);
        while (have < length)
        {
            var count = await stream.ReadAsync(body.AsMemory(have));
            if (count == 0) return null;
            have += count;
        }
        return new HttpRequest(parts[0], parts[1].Split('?', 2)[0], headers, body);
    }

    private static int IndexOfHeaderEnd(MemoryStream buffer)
    {
        var data = buffer.GetBuffer();
        for (var index = 0; index + 3 < buffer.Length; index++)
        {
            if (data[index] == '\r' && data[index + 1] == '\n' && data[index + 2] == '\r' && data[index + 3] == '\n') return index;
        }
        return -1;
    }

    // 路由

    private async Task<int> RouteAsync(HttpRequest request, Responder client)
    {
        if (!IsAllowedHost(request.Headers.GetValueOrDefault("host")))
        {
            await client.JsonErrorAsync(403, "只接受来自本机的请求");
            return 403;
        }
        if (request.Method == "GET" && request.Path == "/health")
        {
            await client.JsonAsync(200, new JsonObject { ["ok"] = true, ["version"] = BridgeInfo.Version });
            return 200;
        }

        BridgeConfig config;
        try
        {
            config = BridgeConfig.Load(_configFile);
        }
        catch (Exception error) when (error is IOException or ConfigException or JsonException)
        {
            await client.JsonErrorAsync(500, "无法读取转换服务配置");
            return 500;
        }
        if (!IsAuthorized(request, config.TokenFile))
        {
            await client.JsonErrorAsync(401, "本机访问令牌不正确");
            return 401;
        }

        switch (request.Method, request.Path)
        {
            case ("POST", "/v1/responses"):
                return await HandleResponsesAsync(request, config, client);
            case ("POST", "/v1/messages"):
                return await HandleMessagesAsync(request, config, client);
            case ("POST", "/v1/messages/count_tokens"):
                // 只用来估算上下文占用，按四个字节一个 token 粗算就够了。
                await client.JsonAsync(200, new JsonObject { ["input_tokens"] = request.Body.Length / 4 });
                return 200;
            case ("GET", "/v1/models"):
                // 工具要的是它们自己的模型目录格式，转发上游只会解析失败。回空列表，它们会用默认设置。
                await client.JsonAsync(200, new JsonObject { ["models"] = new JsonArray(), ["data"] = new JsonArray(), ["has_more"] = false });
                return 200;
            default:
                await client.JsonErrorAsync(404, "转换服务不支持这个路径");
                return 404;
        }
    }

    /// <summary>校验 Host，防止网页通过 DNS 重绑定访问本机服务。</summary>
    private bool IsAllowedHost(string? host) => host == $"127.0.0.1:{_port}" || host == $"localhost:{_port}";

    /// <summary>Claude Code 可能用 x-api-key 带令牌，其他工具用 Authorization。</summary>
    private static bool IsAuthorized(HttpRequest request, string tokenFile)
    {
        string expected;
        try
        {
            expected = File.ReadAllText(tokenFile);
        }
        catch (IOException)
        {
            return false;
        }
        if (expected.Length == 0) return false;
        return Equal(request.Headers.GetValueOrDefault("authorization"), $"Bearer {expected}")
            || Equal(request.Headers.GetValueOrDefault("x-api-key"), expected);

        static bool Equal(string? left, string right) =>
            left is not null && CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(left), Encoding.UTF8.GetBytes(right));
    }

    // Responses / Messages

    private async Task<int> HandleResponsesAsync(HttpRequest request, BridgeConfig config, Responder client)
    {
        if (request.Headers.TryGetValue("content-encoding", out var encoding) && encoding != "identity")
        {
            await client.JsonErrorAsync(415, "转换服务不支持压缩的请求");
            return 415;
        }
        if (ParseBody(request) is not { } body)
        {
            await client.JsonErrorAsync(400, "请求不是有效的 JSON");
            return 400;
        }
        var translated = ResponsesBridge.Translate(body);
        return await ConvertAsync(translated, new ResponsesStreamWriter(translated.Model, translated.Routes), config, client, anthropicErrors: false);
    }

    private async Task<int> HandleMessagesAsync(HttpRequest request, BridgeConfig config, Responder client)
    {
        if (ParseBody(request) is not { } body)
        {
            await client.AnthropicErrorAsync(400, "请求不是有效的 JSON");
            return 400;
        }
        var translated = AnthropicBridge.Translate(body, config.DefaultEffort);
        return await ConvertAsync(translated, new AnthropicStreamWriter(translated.Model, translated.Routes), config, client, anthropicErrors: true);
    }

    private static JsonObject? ParseBody(HttpRequest request)
    {
        try
        {
            return JsonNode.Parse(request.Body) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // 转发到 Chat 接口

    private async Task<int> ConvertAsync(TranslatedRequest translated, IChatStreamConsumer writer, BridgeConfig config, Responder client, bool anthropicErrors)
    {
        HttpResponseMessage response;
        try
        {
            using var upstream = new HttpRequestMessage(HttpMethod.Post, config.UpstreamBaseUrl + "/chat/completions")
            {
                Content = new StringContent(BridgeJson.Serialize(translated.Body), Encoding.UTF8, "application/json"),
            };
            upstream.Headers.Accept.ParseAdd(translated.IsStreaming ? "text/event-stream" : "application/json");
            if (config.UpstreamKeyFile is { } keyFile)
                upstream.Headers.Authorization = new AuthenticationHeaderValue("Bearer", File.ReadAllText(keyFile));
            response = await _http.SendAsync(upstream, HttpCompletionOption.ResponseHeadersRead);
        }
        catch (Exception error) when (error is HttpRequestException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            BridgeLog.Write($"upstream connection failed: {BridgeLog.Redacted(error.Message)}");
            var message = $"无法连接上游接口：{error.Message}";
            if (anthropicErrors) await client.AnthropicErrorAsync(502, message);
            else await client.JsonErrorAsync(502, message);
            return 502;
        }

        using (response)
        {
            if (!response.IsSuccessStatusCode)
            {
                await ForwardErrorAsync((int)response.StatusCode, response, client, anthropicErrors);
                return (int)response.StatusCode;
            }

            var isEventStream = response.Content.Headers.ContentType?.MediaType?.Contains("text/event-stream") == true;
            if (translated.IsStreaming)
            {
                await client.StartEventStreamAsync();
                await client.SendAsync(writer.Start());
            }
            var last = await ReadUpstreamAsync(response, isEventStream, writer, events => translated.IsStreaming ? client.SendAsync(events) : Task.CompletedTask);
            if (translated.IsStreaming)
            {
                await client.SendAsync(last);
                return 200;
            }
            var status = writer.DidFail ? 502 : 200;
            await client.JsonAsync(status, writer.FinalObject);
            return status;
        }
    }

    private static async Task<List<BridgeEvent>> ReadUpstreamAsync(HttpResponseMessage response, bool isEventStream, IChatStreamConsumer writer, Func<List<BridgeEvent>, Task> deliver)
    {
        try
        {
            if (!isEventStream)
            {
                // 接口忽略 stream: true、直接返回完整 JSON 时，当成一次性的数据块处理。
                var text = await response.Content.ReadAsStringAsync();
                JsonObject? completion = null;
                try
                {
                    completion = JsonNode.Parse(text) as JsonObject;
                }
                catch (JsonException)
                {
                }
                if (completion is null) return writer.Fail("上游返回的内容无法解析", "invalid_upstream_response");
                await deliver(writer.Consume(completion));
                return writer.Finish();
            }

            await using var stream = await response.Content.ReadAsStreamAsync();
            // StreamReader 只按 CR/LF 切行，不会把正文里的 U+2028 当成换行。
            using var reader = new StreamReader(stream, Encoding.UTF8);
            while (await reader.ReadLineAsync() is { } line)
            {
                if (!line.StartsWith("data:", StringComparison.Ordinal)) continue;
                var payload = line[5..].Trim();
                if (payload == "[DONE]") break;
                JsonObject? chunk = null;
                try
                {
                    chunk = JsonNode.Parse(payload) as JsonObject;
                }
                catch (JsonException)
                {
                }
                if (chunk is null) continue;
                if (chunk["error"] is { } error)
                {
                    var message = (error as JsonObject).Str("message") ?? (error is JsonValue ? error.ToString() : "上游接口返回了错误");
                    BridgeLog.Write($"upstream stream error: {BridgeLog.Redacted(message)}");
                    return writer.Fail(message, "upstream_error");
                }
                await deliver(writer.Consume(chunk));
            }
            return writer.Finish();
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            BridgeLog.Write($"upstream disconnected: {BridgeLog.Redacted(error.Message)}");
            return writer.Fail($"上游连接中断：{error.Message}", "upstream_disconnected");
        }
    }

    private static async Task ForwardErrorAsync(int status, HttpResponseMessage response, Responder client, bool anthropicErrors)
    {
        var text = await response.Content.ReadAsStringAsync();
        if (text.Length > 64 * 1024) text = text[..(64 * 1024)];
        BridgeLog.Write($"upstream returned {status}: {BridgeLog.Redacted(text)}");
        JsonObject? root = null;
        try
        {
            root = JsonNode.Parse(text) as JsonObject;
        }
        catch (JsonException)
        {
        }
        if (anthropicErrors)
        {
            var message = root.Obj("error").Str("message") ?? root.Str("error") ?? text;
            await client.AnthropicErrorAsync(status, message.Length == 0 ? $"上游接口返回 HTTP {status}" : message);
            return;
        }
        if (root?["error"] is not null)
        {
            await client.RawAsync(status, "application/json", Encoding.UTF8.GetBytes(text));
            return;
        }
        await client.JsonErrorAsync(status, $"上游接口返回 HTTP {status}" + (text.Length == 0 ? "" : $"：{text[..Math.Min(500, text.Length)]}"));
    }

    private sealed class Responder(NetworkStream stream)
    {
        public async Task RawAsync(int status, string contentType, byte[] body)
        {
            var head = $"HTTP/1.1 {status} {Reason(status)}\r\nContent-Type: {contentType}\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.UTF8.GetBytes(head));
            await stream.WriteAsync(body);
            await stream.FlushAsync();
        }

        public Task JsonAsync(int status, JsonObject body) =>
            RawAsync(status, "application/json", Encoding.UTF8.GetBytes(BridgeJson.Serialize(body)));

        public Task JsonErrorAsync(int status, string message) =>
            JsonAsync(status, new JsonObject { ["error"] = new JsonObject { ["message"] = message, ["type"] = "modelbar_bridge" } });

        public Task AnthropicErrorAsync(int status, string message)
        {
            var kind = status switch
            {
                400 => "invalid_request_error",
                401 => "authentication_error",
                403 => "permission_error",
                404 => "not_found_error",
                429 => "rate_limit_error",
                _ => "api_error",
            };
            return JsonAsync(status, new JsonObject { ["type"] = "error", ["error"] = new JsonObject { ["type"] = kind, ["message"] = message } });
        }

        public async Task StartEventStreamAsync()
        {
            const string head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n";
            await stream.WriteAsync(Encoding.UTF8.GetBytes(head));
            await stream.FlushAsync();
        }

        public async Task SendAsync(List<BridgeEvent> events)
        {
            if (events.Count == 0) return;
            foreach (var item in events) await stream.WriteAsync(item.SseData());
            await stream.FlushAsync();
        }

        private static string Reason(int status) => status switch
        {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            415 => "Unsupported Media Type",
            429 => "Too Many Requests",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            _ => "Error",
        };
    }
}

public static partial class BridgeLog
{
    private const long MaxLogSize = 2 * 1024 * 1024;
    private static string? _file;
    private static readonly object Gate = new();

    public static void Configure(string? file)
    {
        _file = file;
        if (file is not null) Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(file))!);
    }

    public static void Write(string message)
    {
        var line = $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ} {message}\n";
        lock (Gate)
        {
            if (_file is null)
            {
                Console.Error.Write(line);
                return;
            }
            try
            {
                // 没有系统日志轮转，超过上限就保留一份旧的。
                if (File.Exists(_file) && new FileInfo(_file).Length > MaxLogSize) File.Move(_file, _file + ".old", overwrite: true);
                File.AppendAllText(_file, line);
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary>上游的报错可能把 Key 带回来，写日志前先抹掉，并限制长度。</summary>
    public static string Redacted(string text)
    {
        var result = SecretPattern().Replace(text.ReplaceLineEndings(" "), "<redacted>");
        return result.Length > 200 ? result[..200] : result;
    }

    [GeneratedRegex(@"sk-[A-Za-z0-9_-]{6,}|Bearer [A-Za-z0-9._-]{6,}|mb-[0-9a-f]{8,}")]
    private static partial Regex SecretPattern();
}
