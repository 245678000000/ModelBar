using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ModelBar.Core;

public enum ToolRouteKind { Function, Custom }

public sealed record ToolRoute(ToolRouteKind Kind, string? Namespace, string Name);

public sealed class TranslatedRequest
{
    public required JsonObject Body { get; init; }
    public required Dictionary<string, ToolRoute> Routes { get; init; }
    public required bool IsStreaming { get; init; }
    public required string Model { get; init; }
}

public sealed record BridgeEvent(string Name, JsonObject Payload)
{
    public byte[] SseData() => Encoding.UTF8.GetBytes($"event: {Name}\ndata: {Payload.ToJsonString(BridgeJson.Options)}\n\n");
}

public static class BridgeJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string Serialize(JsonNode? node) => node?.ToJsonString(Options) ?? "null";

    public static string ShortId() => Guid.NewGuid().ToString("N")[..24];
}

/// <summary>转换服务读取 Chat 回复时用的统一接口，Responses 和 Anthropic 各有一种实现。</summary>
public interface IChatStreamConsumer
{
    JsonObject FinalObject { get; }
    bool DidFail { get; }
    List<BridgeEvent> Start();
    List<BridgeEvent> Consume(JsonObject chunk);
    List<BridgeEvent> Finish();
    List<BridgeEvent> Fail(string message, string code);
}

/// <summary>把 Codex 发来的 Responses 请求翻译成 Chat Completions。</summary>
public static class ResponsesBridge
{
    /// <summary>上游的推理内容存进 encrypted_content，下一轮 Codex 原样带回时再还原。</summary>
    internal const string ReasoningPrefix = "modelbar:";

    public static TranslatedRequest Translate(JsonObject request)
    {
        var routes = new Dictionary<string, ToolRoute>();
        var tools = new JsonArray();
        foreach (var tool in request.Arr("tools").Objects()) AppendTool(tool, null, tools, routes);

        var model = request.Str("model") ?? "";
        var isStreaming = request.Bool("stream") ?? false;
        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = BuildMessages(request),
            ["stream"] = isStreaming,
        };
        if (isStreaming) body["stream_options"] = new JsonObject { ["include_usage"] = true };

        if (tools.Count > 0)
        {
            body["tools"] = tools;
            if (TranslateToolChoice(request["tool_choice"]) is { } choice) body["tool_choice"] = choice;
            if (request.Bool("parallel_tool_calls") == false) body["parallel_tool_calls"] = false;
        }
        foreach (var key in new[] { "temperature", "top_p" })
        {
            if (request[key] is { } value) body[key] = value.DeepClone();
        }
        if (request.Int("max_output_tokens") is { } limit) body["max_tokens"] = limit;
        if (request.Obj("reasoning").Str("effort") is { } effort && effort != "none") body["reasoning_effort"] = effort;
        if (TranslateTextFormat(request.Obj("text")) is { } format) body["response_format"] = format;

        return new TranslatedRequest { Body = body, Routes = routes, IsStreaming = isStreaming, Model = model };
    }

    private static void AppendTool(JsonObject tool, string? ns, JsonArray tools, Dictionary<string, ToolRoute> routes)
    {
        switch (tool.Str("type"))
        {
            case "function" when tool.Str("name") is { } name:
                var flat = FlatName(ns, name);
                routes[flat] = new ToolRoute(ToolRouteKind.Function, ns, name);
                var parameters = tool.Obj("parameters")?.DeepClone() ?? new JsonObject { ["type"] = "object", ["properties"] = new JsonObject() };
                tools.Add(ChatTool(flat, tool.Str("description"), parameters));
                break;
            case "namespace":
                foreach (var nested in tool.Arr("tools").Objects()) AppendTool(nested, tool.Str("name"), tools, routes);
                break;
            case "custom" when tool.Str("name") is { } customName:
                var customFlat = FlatName(ns, customName);
                routes[customFlat] = new ToolRoute(ToolRouteKind.Custom, ns, customName);
                var description = tool.Str("description") ?? "";
                if (tool.Obj("format").Str("definition") is { } definition)
                    description += $"\n\nThe input must follow this grammar:\n{definition}";
                tools.Add(ChatTool(customFlat, description, new JsonObject
                {
                    ["type"] = "object",
                    ["properties"] = new JsonObject
                    {
                        ["input"] = new JsonObject { ["type"] = "string", ["description"] = "The raw tool input." },
                    },
                    ["required"] = new JsonArray("input"),
                }));
                break;
            default:
                // web_search 这类由 OpenAI 服务端执行的工具，在 Chat 接口上没有对应物。
                break;
        }
    }

    internal static JsonObject ChatTool(string name, string? description, JsonNode parameters)
    {
        var function = new JsonObject { ["name"] = name, ["parameters"] = parameters };
        if (!string.IsNullOrEmpty(description)) function["description"] = description;
        return new JsonObject { ["type"] = "function", ["function"] = function };
    }

    /// <summary>Chat 接口的函数名限制为 64 个字母、数字、下划线或连字符。</summary>
    public static string FlatName(string? ns, string name)
    {
        var joined = ns is null ? name : $"{ns}__{name}";
        var cleaned = new string(joined.Select(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-' ? c : '_').ToArray());
        if (cleaned.Length <= 64) return cleaned;
        uint hash = 2_166_136_261;
        foreach (var value in Encoding.UTF8.GetBytes(joined)) hash = unchecked((hash ^ value) * 16_777_619);
        return $"{cleaned[..55]}_{hash:x8}";
    }

    private static JsonNode? TranslateToolChoice(JsonNode? choice)
    {
        if (choice is JsonValue value && value.TryGetValue<string>(out var text)) return text;
        if (choice is JsonObject obj && obj.Str("type") == "function" && obj.Str("name") is { } name)
        {
            return new JsonObject
            {
                ["type"] = "function",
                ["function"] = new JsonObject { ["name"] = FlatName(obj.Str("namespace"), name) },
            };
        }
        return null;
    }

    private static JsonObject? TranslateTextFormat(JsonObject? text)
    {
        var format = text.Obj("format");
        if (format.Str("type") != "json_schema") return null;
        var schema = new JsonObject();
        foreach (var key in new[] { "name", "schema", "strict" })
        {
            if (format![key] is { } value) schema[key] = value.DeepClone();
        }
        return new JsonObject { ["type"] = "json_schema", ["json_schema"] = schema };
    }

    private static JsonArray BuildMessages(JsonObject request)
    {
        var builder = new MessageBuilder();
        if (request.Str("instructions") is { Length: > 0 } instructions) builder.AppendInstruction(instructions);
        if (request.Str("input") is { } text) builder.AppendMessage("user", text);
        foreach (var item in request.Arr("input").Objects()) builder.Append(item);
        builder.Finish();
        return builder.Messages;
    }

    private sealed class MessageBuilder
    {
        public JsonArray Messages { get; } = [];
        private string? _pendingReasoning;
        private readonly List<string> _pendingImages = [];
        private bool _seenConversation;

        public void Append(JsonObject item)
        {
            var type = item.Str("type") ?? "message";
            switch (type)
            {
                case "message":
                    AppendMessageItem(item);
                    break;
                case "function_call":
                    AppendToolCall(item.Str("call_id"), FlatName(item.Str("namespace"), item.Str("name") ?? ""), item.Str("arguments") ?? "{}");
                    break;
                case "custom_tool_call":
                    var arguments = new JsonObject { ["input"] = item.Str("input") ?? "" };
                    AppendToolCall(item.Str("call_id"), FlatName(item.Str("namespace"), item.Str("name") ?? ""), BridgeJson.Serialize(arguments));
                    break;
                case "function_call_output" or "custom_tool_call_output":
                    AppendToolOutput(item.Str("call_id"), item["output"]);
                    break;
                case "reasoning":
                    if (item.Str("encrypted_content") is { } stored) RestoreReasoning(stored);
                    break;
                default:
                    AppendGenericItem(item, type);
                    break;
            }
        }

        /// <summary>其他带 call_id 的内置工具项也按工具调用处理，保证调用和结果成对。</summary>
        private void AppendGenericItem(JsonObject item, string type)
        {
            if (item.Str("call_id") is not { } callId) return;
            if (type.EndsWith("_output", StringComparison.Ordinal))
            {
                AppendToolOutput(callId, item["output"]);
            }
            else if (type.EndsWith("_call", StringComparison.Ordinal))
            {
                var name = item.Str("name") ?? type[..^"_call".Length];
                var arguments = item.Str("arguments") ?? BridgeJson.Serialize(item["action"] ?? new JsonObject());
                AppendToolCall(callId, FlatName(null, name), arguments);
            }
        }

        public void AppendInstruction(string text)
        {
            var last = Messages.Count > 0 ? Messages[^1] as JsonObject : null;
            if (!_seenConversation && last.Str("role") == "system" && last.Str("content") is { } existing)
            {
                last!["content"] = existing + "\n\n" + text;
            }
            else if (_seenConversation)
            {
                // 很多模型只接受开头的 system，对话中途的系统消息改用 user。
                FlushImages();
                Messages.Add(new JsonObject { ["role"] = "user", ["content"] = text });
            }
            else
            {
                Messages.Add(new JsonObject { ["role"] = "system", ["content"] = text });
            }
        }

        public void AppendMessage(string role, JsonNode content)
        {
            FlushImages();
            _seenConversation = true;
            var message = new JsonObject { ["role"] = role, ["content"] = content };
            if (role == "assistant" && _pendingReasoning is { } reasoning)
            {
                message["reasoning_content"] = reasoning;
                _pendingReasoning = null;
            }
            Messages.Add(message);
        }

        private void AppendMessageItem(JsonObject item)
        {
            var role = item.Str("role") ?? "user";
            var content = ChatContent(item["content"]);
            if (role is "developer" or "system")
            {
                if (content is JsonValue value && value.TryGetValue<string>(out var text) && text.Length > 0) AppendInstruction(text);
                return;
            }
            AppendMessage(role, content);
        }

        private void AppendToolCall(string? id, string name, string arguments)
        {
            FlushImages();
            _seenConversation = true;
            var call = new JsonObject
            {
                ["id"] = id ?? $"call_{BridgeJson.ShortId()}",
                ["type"] = "function",
                ["function"] = new JsonObject { ["name"] = name, ["arguments"] = arguments.Length == 0 ? "{}" : arguments },
            };
            if (Messages.Count > 0 && Messages[^1] is JsonObject last && last.Str("role") == "assistant")
            {
                var calls = last.Arr("tool_calls");
                if (calls is null) last["tool_calls"] = calls = [];
                calls.Add(call);
                return;
            }
            var message = new JsonObject { ["role"] = "assistant", ["content"] = null, ["tool_calls"] = new JsonArray(call) };
            if (_pendingReasoning is { } reasoning)
            {
                message["reasoning_content"] = reasoning;
                _pendingReasoning = null;
            }
            Messages.Add(message);
        }

        private void AppendToolOutput(string? id, JsonNode? output)
        {
            _seenConversation = true;
            var (text, images) = ToolOutput(output);
            Messages.Add(new JsonObject { ["role"] = "tool", ["tool_call_id"] = id ?? "", ["content"] = text });
            _pendingImages.AddRange(images);
        }

        private void RestoreReasoning(string stored)
        {
            if (!stored.StartsWith(ReasoningPrefix, StringComparison.Ordinal)) return;
            try
            {
                _pendingReasoning = Encoding.UTF8.GetString(Convert.FromBase64String(stored[ReasoningPrefix.Length..]));
            }
            catch (FormatException)
            {
            }
        }

        public void Finish() => FlushImages();

        /// <summary>tool 消息只能放文字，工具返回的图片放到紧跟着的 user 消息里。</summary>
        private void FlushImages()
        {
            if (_pendingImages.Count == 0) return;
            var parts = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "Images returned by the previous tool call:" });
            foreach (var url in _pendingImages) parts.Add(ImagePart(url));
            _pendingImages.Clear();
            Messages.Add(new JsonObject { ["role"] = "user", ["content"] = parts });
        }
    }

    internal static JsonObject ImagePart(string url) =>
        new() { ["type"] = "image_url", ["image_url"] = new JsonObject { ["url"] = url } };

    private static JsonNode ChatContent(JsonNode? content)
    {
        if (content is JsonValue value && value.TryGetValue<string>(out var text)) return text;
        if (content is not JsonArray parts) return "";
        var texts = new List<string>();
        var images = new List<string>();
        foreach (var part in parts.Objects())
        {
            if (part.Str("text") is { } partText) texts.Add(partText);
            else if (part.Str("type") == "input_image" && part.Str("image_url") is { } url) images.Add(url);
        }
        var joined = string.Join("\n\n", texts);
        if (images.Count == 0) return joined;
        var result = new JsonArray();
        if (joined.Length > 0) result.Add(new JsonObject { ["type"] = "text", ["text"] = joined });
        foreach (var url in images) result.Add(ImagePart(url));
        return result;
    }

    private static (string Text, List<string> Images) ToolOutput(JsonNode? output)
    {
        if (output is JsonValue value && value.TryGetValue<string>(out var text)) return (text, []);
        if (output is JsonArray parts)
        {
            var texts = new List<string>();
            var images = new List<string>();
            foreach (var part in parts.Objects())
            {
                if (part.Str("text") is { } partText) texts.Add(partText);
                else if (part.Str("image_url") is { } url) images.Add(url);
            }
            return (string.Join("\n", texts), images);
        }
        return (output is null ? "" : BridgeJson.Serialize(output), []);
    }
}

/// <summary>逐块读取 Chat 的回复，生成对应的 Responses 事件。</summary>
public sealed class ResponsesStreamWriter(string model, Dictionary<string, ToolRoute> routes) : IChatStreamConsumer
{
    private sealed class ToolCall
    {
        public required string ItemId;
        public required string CallId;
        public string Name = "";
        public string Arguments = "";
        public int? OutputIndex;
    }

    private readonly string _responseId = "resp_" + BridgeJson.ShortId();
    private readonly long _createdAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    private int _sequence;
    private int _nextOutputIndex;
    private readonly SortedDictionary<int, JsonObject> _output = [];
    private JsonObject? _usage;
    private string? _finishReason;
    private JsonObject? _failure;

    private string? _reasoningId;
    private int _reasoningIndex;
    private readonly StringBuilder _reasoningText = new();

    private string? _messageId;
    private int _messageIndex;
    private readonly StringBuilder _messageText = new();

    private readonly Dictionary<int, ToolCall> _toolCalls = [];
    private readonly List<int> _toolOrder = [];

    public JsonObject FinalObject { get; private set; } = [];
    public bool DidFail => _failure is not null;

    public List<BridgeEvent> Start() =>
    [
        Event("response.created", new JsonObject { ["response"] = ResponseObject("in_progress") }),
        Event("response.in_progress", new JsonObject { ["response"] = ResponseObject("in_progress") }),
    ];

    public List<BridgeEvent> Consume(JsonObject chunk)
    {
        var events = new List<BridgeEvent>();
        if (chunk.Obj("usage") is { } usage) _usage = usage;
        if (chunk.Arr("choices").Objects().FirstOrDefault() is not { } choice) return events;
        if (choice.Str("finish_reason") is { } reason) _finishReason = reason;
        if ((choice.Obj("delta") ?? choice.Obj("message")) is not { } delta) return events;

        if ((delta.Str("reasoning_content") ?? delta.Str("reasoning")) is { Length: > 0 } reasoning)
        {
            events.AddRange(CloseMessage());
            events.AddRange(AppendReasoning(reasoning));
        }
        if (delta.Str("content") is { Length: > 0 } content)
        {
            events.AddRange(CloseReasoning());
            events.AddRange(AppendText(content));
        }
        if (delta.Arr("tool_calls") is { Count: > 0 } calls)
        {
            events.AddRange(CloseReasoning());
            events.AddRange(CloseMessage());
            var position = 0;
            foreach (var call in calls.Objects()) events.AddRange(AppendToolCall(call, position++));
        }
        return events;
    }

    public List<BridgeEvent> Finish()
    {
        var events = CloseReasoning();
        events.AddRange(CloseMessage());
        events.AddRange(CloseToolCalls());
        if (_output.Count == 0)
        {
            events.AddRange(Fail("接口没有返回任何内容", "empty_response"));
            return events;
        }
        string? incomplete = _finishReason switch
        {
            "length" => "max_output_tokens",
            "content_filter" => "content_filter",
            _ => null,
        };
        FinalObject = ResponseObject(incomplete is null ? "completed" : "incomplete", incomplete);
        events.Add(Event(incomplete is null ? "response.completed" : "response.incomplete", new JsonObject { ["response"] = FinalObject.DeepClone() }));
        return events;
    }

    public List<BridgeEvent> Fail(string message, string code)
    {
        _failure = new JsonObject { ["code"] = code, ["message"] = message };
        FinalObject = ResponseObject("failed");
        return [Event("response.failed", new JsonObject { ["response"] = FinalObject.DeepClone() })];
    }

    private List<BridgeEvent> AppendReasoning(string text)
    {
        var events = new List<BridgeEvent>();
        if (_reasoningId is null)
        {
            _reasoningId = "rs_" + BridgeJson.ShortId();
            _reasoningIndex = _nextOutputIndex++;
            _reasoningText.Clear();
            events.Add(Event("response.output_item.added", new JsonObject
            {
                ["output_index"] = _reasoningIndex,
                ["item"] = new JsonObject { ["type"] = "reasoning", ["id"] = _reasoningId, ["summary"] = new JsonArray() },
            }));
            events.Add(Event("response.reasoning_summary_part.added", new JsonObject
            {
                ["item_id"] = _reasoningId,
                ["output_index"] = _reasoningIndex,
                ["summary_index"] = 0,
                ["part"] = new JsonObject { ["type"] = "summary_text", ["text"] = "" },
            }));
        }
        _reasoningText.Append(text);
        events.Add(Event("response.reasoning_summary_text.delta", new JsonObject
        {
            ["item_id"] = _reasoningId,
            ["output_index"] = _reasoningIndex,
            ["summary_index"] = 0,
            ["delta"] = text,
        }));
        return events;
    }

    private List<BridgeEvent> CloseReasoning()
    {
        if (_reasoningId is not { } id) return [];
        _reasoningId = null;
        var text = _reasoningText.ToString();
        var item = new JsonObject
        {
            ["type"] = "reasoning",
            ["id"] = id,
            ["summary"] = new JsonArray(new JsonObject { ["type"] = "summary_text", ["text"] = text }),
            ["encrypted_content"] = ResponsesBridge.ReasoningPrefix + Convert.ToBase64String(Encoding.UTF8.GetBytes(text)),
        };
        _output[_reasoningIndex] = item;
        return
        [
            Event("response.reasoning_summary_text.done", new JsonObject
            {
                ["item_id"] = id, ["output_index"] = _reasoningIndex, ["summary_index"] = 0, ["text"] = text,
            }),
            Event("response.reasoning_summary_part.done", new JsonObject
            {
                ["item_id"] = id,
                ["output_index"] = _reasoningIndex,
                ["summary_index"] = 0,
                ["part"] = new JsonObject { ["type"] = "summary_text", ["text"] = text },
            }),
            Event("response.output_item.done", new JsonObject { ["output_index"] = _reasoningIndex, ["item"] = item.DeepClone() }),
        ];
    }

    private List<BridgeEvent> AppendText(string text)
    {
        var events = new List<BridgeEvent>();
        if (_messageId is null)
        {
            _messageId = "msg_" + BridgeJson.ShortId();
            _messageIndex = _nextOutputIndex++;
            _messageText.Clear();
            events.Add(Event("response.output_item.added", new JsonObject
            {
                ["output_index"] = _messageIndex,
                ["item"] = new JsonObject
                {
                    ["type"] = "message", ["id"] = _messageId, ["status"] = "in_progress", ["role"] = "assistant", ["content"] = new JsonArray(),
                },
            }));
            events.Add(Event("response.content_part.added", new JsonObject
            {
                ["item_id"] = _messageId,
                ["output_index"] = _messageIndex,
                ["content_index"] = 0,
                ["part"] = new JsonObject { ["type"] = "output_text", ["text"] = "", ["annotations"] = new JsonArray() },
            }));
        }
        _messageText.Append(text);
        events.Add(Event("response.output_text.delta", new JsonObject
        {
            ["item_id"] = _messageId,
            ["output_index"] = _messageIndex,
            ["content_index"] = 0,
            ["delta"] = text,
        }));
        return events;
    }

    private List<BridgeEvent> CloseMessage()
    {
        if (_messageId is not { } id) return [];
        _messageId = null;
        var text = _messageText.ToString();
        JsonObject Part() => new() { ["type"] = "output_text", ["text"] = text, ["annotations"] = new JsonArray() };
        var item = new JsonObject
        {
            ["type"] = "message", ["id"] = id, ["status"] = "completed", ["role"] = "assistant", ["content"] = new JsonArray(Part()),
        };
        _output[_messageIndex] = item;
        return
        [
            Event("response.output_text.done", new JsonObject
            {
                ["item_id"] = id, ["output_index"] = _messageIndex, ["content_index"] = 0, ["text"] = text,
            }),
            Event("response.content_part.done", new JsonObject
            {
                ["item_id"] = id, ["output_index"] = _messageIndex, ["content_index"] = 0, ["part"] = Part(),
            }),
            Event("response.output_item.done", new JsonObject { ["output_index"] = _messageIndex, ["item"] = item.DeepClone() }),
        ];
    }

    private List<BridgeEvent> AppendToolCall(JsonObject call, int position)
    {
        var index = call.Int("index") ?? position;
        if (!_toolCalls.TryGetValue(index, out var state))
        {
            state = new ToolCall
            {
                ItemId = "fc_" + BridgeJson.ShortId(),
                CallId = call.Str("id") is { Length: > 0 } id ? id : "call_" + BridgeJson.ShortId(),
            };
            _toolCalls[index] = state;
            _toolOrder.Add(index);
        }
        var function = call.Obj("function");
        if (function.Str("name") is { } name) state.Name += name;

        var fragment = "";
        if (function.Str("arguments") is { } text) fragment = text;
        else if (function?["arguments"] is { } node) fragment = BridgeJson.Serialize(node); // 个别网关把参数直接放成 JSON 对象。
        state.Arguments += fragment;

        var events = new List<BridgeEvent>();
        if (state.OutputIndex is null && state.Name.Length > 0)
        {
            state.OutputIndex = _nextOutputIndex++;
            events.Add(Event("response.output_item.added", new JsonObject
            {
                ["output_index"] = state.OutputIndex,
                ["item"] = ToolItem(state, "in_progress", ""),
            }));
            if (state.Arguments.Length > 0 && Route(state).Kind == ToolRouteKind.Function) events.Add(ArgumentsDelta(state, state.Arguments));
        }
        else if (fragment.Length > 0 && state.OutputIndex is not null && Route(state).Kind == ToolRouteKind.Function)
        {
            events.Add(ArgumentsDelta(state, fragment));
        }
        return events;
    }

    private List<BridgeEvent> CloseToolCalls()
    {
        var events = new List<BridgeEvent>();
        foreach (var index in _toolOrder)
        {
            var state = _toolCalls[index];
            if (state.Name.Length == 0) continue;
            if (state.Arguments.Length == 0) state.Arguments = "{}";
            if (state.OutputIndex is null)
            {
                state.OutputIndex = _nextOutputIndex++;
                events.Add(Event("response.output_item.added", new JsonObject
                {
                    ["output_index"] = state.OutputIndex,
                    ["item"] = ToolItem(state, "in_progress", ""),
                }));
            }
            var item = ToolItem(state, "completed", state.Arguments);
            if (Route(state).Kind == ToolRouteKind.Function)
            {
                events.Add(Event("response.function_call_arguments.done", new JsonObject
                {
                    ["item_id"] = state.ItemId, ["output_index"] = state.OutputIndex, ["arguments"] = state.Arguments,
                }));
            }
            events.Add(Event("response.output_item.done", new JsonObject { ["output_index"] = state.OutputIndex, ["item"] = item.DeepClone() }));
            _output[state.OutputIndex.Value] = item;
        }
        _toolCalls.Clear();
        _toolOrder.Clear();
        return events;
    }

    private BridgeEvent ArgumentsDelta(ToolCall state, string delta) => Event("response.function_call_arguments.delta", new JsonObject
    {
        ["item_id"] = state.ItemId, ["output_index"] = state.OutputIndex, ["delta"] = delta,
    });

    private ToolRoute Route(ToolCall state) =>
        routes.GetValueOrDefault(state.Name) ?? new ToolRoute(ToolRouteKind.Function, null, state.Name);

    private JsonObject ToolItem(ToolCall state, string status, string arguments)
    {
        var route = Route(state);
        var item = new JsonObject { ["id"] = state.ItemId, ["call_id"] = state.CallId, ["name"] = route.Name, ["status"] = status };
        if (route.Namespace is not null) item["namespace"] = route.Namespace;
        if (route.Kind == ToolRouteKind.Function)
        {
            item["type"] = "function_call";
            item["arguments"] = arguments;
        }
        else
        {
            item["type"] = "custom_tool_call";
            string? input = null;
            try
            {
                input = (JsonNode.Parse(arguments) as JsonObject).Str("input");
            }
            catch (JsonException)
            {
            }
            item["input"] = input ?? arguments;
        }
        return item;
    }

    private BridgeEvent Event(string name, JsonObject fields)
    {
        fields["type"] = name;
        fields["sequence_number"] = _sequence++;
        return new BridgeEvent(name, fields);
    }

    private JsonObject ResponseObject(string status, string? incompleteReason = null)
    {
        var output = new JsonArray();
        foreach (var item in _output.Values) output.Add(item.DeepClone());
        return new JsonObject
        {
            ["id"] = _responseId,
            ["object"] = "response",
            ["created_at"] = _createdAt,
            ["status"] = status,
            ["model"] = model,
            ["output"] = output,
            ["usage"] = MappedUsage(),
            ["error"] = _failure?.DeepClone(),
            ["incomplete_details"] = incompleteReason is null ? null : new JsonObject { ["reason"] = incompleteReason },
            ["parallel_tool_calls"] = true,
        };
    }

    private JsonObject? MappedUsage()
    {
        if (_usage is null) return null;
        var input = _usage.Int("prompt_tokens") ?? 0;
        var output = _usage.Int("completion_tokens") ?? 0;
        return new JsonObject
        {
            ["input_tokens"] = input,
            ["input_tokens_details"] = new JsonObject { ["cached_tokens"] = _usage.Obj("prompt_tokens_details").Int("cached_tokens") ?? 0 },
            ["output_tokens"] = output,
            ["output_tokens_details"] = new JsonObject { ["reasoning_tokens"] = _usage.Obj("completion_tokens_details").Int("reasoning_tokens") ?? 0 },
            ["total_tokens"] = _usage.Int("total_tokens") ?? input + output,
        };
    }
}
