using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ModelBar.Core;

/// <summary>把 Claude Code 发来的 Anthropic Messages 请求翻译成 Chat Completions。</summary>
public static class AnthropicBridge
{
    /// <summary>下一轮带回 thinking 块时用它识别来源，推理内容本身就在块里。</summary>
    internal const string ThinkingSignature = "modelbar";
    /// <summary>很多 Chat 接口会拒绝超过模型上限的 max_tokens，而 Claude Code 默认发很大的值。太大时不传，由接口决定。</summary>
    internal const int LargestForwardedMaxTokens = 8_192;

    public static TranslatedRequest Translate(JsonObject request, string? defaultEffort = null)
    {
        var routes = new Dictionary<string, ToolRoute>();
        var tools = new JsonArray();
        foreach (var tool in request.Arr("tools").Objects())
        {
            // 没有 input_schema 的是 web_search 这类服务端工具，Chat 接口上没有对应物。
            if (tool.Str("name") is not { } name || tool.Obj("input_schema") is not { } schema) continue;
            var flat = ResponsesBridge.FlatName(null, name);
            routes[flat] = new ToolRoute(ToolRouteKind.Function, null, name);
            tools.Add(ResponsesBridge.ChatTool(flat, tool.Str("description"), schema.DeepClone()));
        }

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
            if (TranslateToolChoice(request.Obj("tool_choice")) is { } choice) body["tool_choice"] = choice;
        }
        if (request.Int("max_tokens") is { } limit && limit <= LargestForwardedMaxTokens) body["max_tokens"] = limit;
        foreach (var key in new[] { "temperature", "top_p" })
        {
            if (request[key] is { } value) body[key] = value.DeepClone();
        }
        if (request.Arr("stop_sequences") is { Count: > 0 } stop) body["stop"] = stop.DeepClone();
        if ((Effort(request) ?? defaultEffort) is { } effort) body["reasoning_effort"] = effort;

        return new TranslatedRequest { Body = body, Routes = routes, IsStreaming = isStreaming, Model = model };
    }

    private static string? Effort(JsonObject request)
    {
        if (request.Obj("output_config").Str("effort") is { } effort) return effort == "max" ? "xhigh" : effort;
        var thinking = request.Obj("thinking");
        if (thinking.Str("type") != "enabled" || thinking.Int("budget_tokens") is not { } budget) return null;
        return budget <= 4_096 ? "low" : budget <= 16_000 ? "medium" : "high";
    }

    private static JsonNode? TranslateToolChoice(JsonObject? choice) => choice.Str("type") switch
    {
        "auto" => "auto",
        "any" => "required",
        "none" => "none",
        "tool" when choice.Str("name") is { } name => new JsonObject
        {
            ["type"] = "function",
            ["function"] = new JsonObject { ["name"] = ResponsesBridge.FlatName(null, name) },
        },
        _ => null,
    };

    private static JsonArray BuildMessages(JsonObject request)
    {
        var messages = new JsonArray();
        if (SystemText(request["system"]) is { Length: > 0 } system)
            messages.Add(new JsonObject { ["role"] = "system", ["content"] = system });
        foreach (var message in request.Arr("messages").Objects())
        {
            var blocks = NormalizedBlocks(message["content"]);
            if (message.Str("role") == "assistant") messages.Add(AssistantMessage(blocks));
            else AppendUserMessage(blocks, messages);
        }
        return messages;
    }

    private static string? SystemText(JsonNode? system)
    {
        if (system is JsonValue value && value.TryGetValue<string>(out var text)) return text;
        return system is JsonArray blocks ? string.Join("\n\n", blocks.Objects().Select(b => b.Str("text")).OfType<string>()) : null;
    }

    private static List<JsonObject> NormalizedBlocks(JsonNode? content)
    {
        if (content is JsonValue value && value.TryGetValue<string>(out var text))
            return [new JsonObject { ["type"] = "text", ["text"] = text }];
        return (content as JsonArray).Objects().ToList();
    }

    private static JsonObject AssistantMessage(List<JsonObject> blocks)
    {
        var texts = new List<string>();
        var calls = new JsonArray();
        string? reasoning = null;
        foreach (var block in blocks)
        {
            switch (block.Str("type"))
            {
                case "text" when block.Str("text") is { } text:
                    texts.Add(text);
                    break;
                case "tool_use":
                    calls.Add(new JsonObject
                    {
                        ["id"] = block.Str("id") ?? "",
                        ["type"] = "function",
                        ["function"] = new JsonObject
                        {
                            ["name"] = ResponsesBridge.FlatName(null, block.Str("name") ?? ""),
                            ["arguments"] = BridgeJson.Serialize(block["input"] ?? new JsonObject()),
                        },
                    });
                    break;
                case "thinking" when block.Str("signature") == ThinkingSignature:
                    reasoning = block.Str("thinking");
                    break;
            }
        }
        var message = new JsonObject
        {
            ["role"] = "assistant",
            ["content"] = texts.Count == 0 ? null : string.Join("\n\n", texts),
        };
        if (calls.Count > 0) message["tool_calls"] = calls;
        if (reasoning is not null) message["reasoning_content"] = reasoning;
        return message;
    }

    /// <summary>工具结果要紧跟在 assistant 后面，所以先放 tool 消息，再放用户的文字和图片。</summary>
    private static void AppendUserMessage(List<JsonObject> blocks, JsonArray messages)
    {
        var parts = new List<JsonObject>();
        var toolImages = new List<string>();
        foreach (var block in blocks)
        {
            switch (block.Str("type"))
            {
                case "tool_result":
                    var (text, images) = ToolResult(block);
                    messages.Add(new JsonObject { ["role"] = "tool", ["tool_call_id"] = block.Str("tool_use_id") ?? "", ["content"] = text });
                    toolImages.AddRange(images);
                    break;
                case "text" when block.Str("text") is { } value:
                    parts.Add(new JsonObject { ["type"] = "text", ["text"] = value });
                    break;
                case "image" when ImageUrl(block) is { } url:
                    parts.Add(ResponsesBridge.ImagePart(url));
                    break;
            }
        }
        if (toolImages.Count > 0)
        {
            var imageParts = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = "Images returned by the previous tool call:" });
            foreach (var url in toolImages) imageParts.Add(ResponsesBridge.ImagePart(url));
            messages.Add(new JsonObject { ["role"] = "user", ["content"] = imageParts });
        }
        if (parts.Count == 0) return;
        if (parts.All(p => p.Str("type") == "text"))
        {
            messages.Add(new JsonObject { ["role"] = "user", ["content"] = string.Join("\n\n", parts.Select(p => p.Str("text"))) });
        }
        else
        {
            var content = new JsonArray();
            foreach (var part in parts) content.Add(part);
            messages.Add(new JsonObject { ["role"] = "user", ["content"] = content });
        }
    }

    private static (string Text, List<string> Images) ToolResult(JsonObject block)
    {
        var images = new List<string>();
        string text;
        if (block.Str("content") is { } direct)
        {
            text = direct;
        }
        else
        {
            var pieces = new List<string>();
            foreach (var part in block.Arr("content").Objects())
            {
                if (part.Str("text") is { } value) pieces.Add(value);
                else if (part.Str("type") == "image" && ImageUrl(part) is { } url) images.Add(url);
            }
            text = string.Join("\n", pieces);
        }
        if (block.Bool("is_error") == true) text = "Error: " + text;
        return (text, images);
    }

    private static string? ImageUrl(JsonObject block)
    {
        var source = block.Obj("source");
        if (source.Str("url") is { } url) return url;
        return source.Str("data") is { } data ? $"data:{source.Str("media_type") ?? "image/png"};base64,{data}" : null;
    }
}

/// <summary>Anthropic 的内容块不能交叉，所以工具调用先攒齐，最后一次性发出。</summary>
public sealed class AnthropicStreamWriter(string model, Dictionary<string, ToolRoute> routes) : IChatStreamConsumer
{
    private sealed class ToolCall
    {
        public required string Id;
        public string Name = "";
        public string Arguments = "";
    }

    private enum OpenBlock { None, Thinking, Text }

    private readonly string _messageId = "msg_" + BridgeJson.ShortId();
    private int _nextIndex;
    private OpenBlock _open;
    private int _openIndex;
    private readonly List<JsonObject> _content = [];
    private readonly StringBuilder _currentText = new();
    private readonly Dictionary<int, ToolCall> _calls = [];
    private readonly List<int> _callOrder = [];
    private JsonObject? _usage;
    private string? _finishReason;

    public JsonObject FinalObject { get; private set; } = [];
    public bool DidFail { get; private set; }

    public List<BridgeEvent> Start() =>
    [
        Event("message_start", new JsonObject
        {
            ["message"] = new JsonObject
            {
                ["id"] = _messageId,
                ["type"] = "message",
                ["role"] = "assistant",
                ["model"] = model,
                ["content"] = new JsonArray(),
                ["stop_reason"] = null,
                ["stop_sequence"] = null,
                ["usage"] = new JsonObject { ["input_tokens"] = 0, ["output_tokens"] = 0 },
            },
        }),
    ];

    public List<BridgeEvent> Consume(JsonObject chunk)
    {
        if (chunk.Obj("usage") is { } usage) _usage = usage;
        if (chunk.Arr("choices").Objects().FirstOrDefault() is not { } choice) return [];
        if (choice.Str("finish_reason") is { } reason) _finishReason = reason;
        if ((choice.Obj("delta") ?? choice.Obj("message")) is not { } delta) return [];

        var events = new List<BridgeEvent>();
        if ((delta.Str("reasoning_content") ?? delta.Str("reasoning")) is { Length: > 0 } reasoning)
            events.AddRange(AppendDelta(reasoning, OpenBlock.Thinking));
        if (delta.Str("content") is { Length: > 0 } text)
            events.AddRange(AppendDelta(text, OpenBlock.Text));
        var position = 0;
        foreach (var call in delta.Arr("tool_calls").Objects()) CollectToolCall(call, position++);
        return events;
    }

    public List<BridgeEvent> Finish()
    {
        var events = CloseBlock();
        events.AddRange(EmitToolCalls());
        if (_content.Count == 0)
        {
            events.AddRange(Fail("接口没有返回任何内容", "empty_response"));
            return events;
        }
        var input = _usage.Int("prompt_tokens") ?? 0;
        var output = _usage.Int("completion_tokens") ?? 0;
        var stopReason = MappedStopReason();
        events.Add(Event("message_delta", new JsonObject
        {
            ["delta"] = new JsonObject { ["stop_reason"] = stopReason, ["stop_sequence"] = null },
            ["usage"] = new JsonObject { ["input_tokens"] = input, ["output_tokens"] = output },
        }));
        events.Add(Event("message_stop", []));
        var content = new JsonArray();
        foreach (var block in _content) content.Add(block.DeepClone());
        FinalObject = new JsonObject
        {
            ["id"] = _messageId,
            ["type"] = "message",
            ["role"] = "assistant",
            ["model"] = model,
            ["content"] = content,
            ["stop_reason"] = stopReason,
            ["stop_sequence"] = null,
            ["usage"] = new JsonObject { ["input_tokens"] = input, ["output_tokens"] = output },
        };
        return events;
    }

    public List<BridgeEvent> Fail(string message, string code)
    {
        DidFail = true;
        FinalObject = new JsonObject { ["type"] = "error", ["error"] = new JsonObject { ["type"] = "api_error", ["message"] = message } };
        return [Event("error", new JsonObject { ["error"] = new JsonObject { ["type"] = "api_error", ["message"] = message } })];
    }

    private string MappedStopReason()
    {
        if (_content.Any(block => block.Str("type") == "tool_use")) return "tool_use";
        return _finishReason switch
        {
            "length" => "max_tokens",
            "content_filter" => "refusal",
            _ => "end_turn",
        };
    }

    private List<BridgeEvent> AppendDelta(string text, OpenBlock kind)
    {
        var events = new List<BridgeEvent>();
        if (_open != kind)
        {
            events.AddRange(CloseBlock());
            _open = kind;
            _openIndex = _nextIndex++;
            _currentText.Clear();
            JsonObject block = kind == OpenBlock.Thinking
                ? new JsonObject { ["type"] = "thinking", ["thinking"] = "", ["signature"] = "" }
                : new JsonObject { ["type"] = "text", ["text"] = "" };
            events.Add(Event("content_block_start", new JsonObject { ["index"] = _openIndex, ["content_block"] = block }));
        }
        _currentText.Append(text);
        JsonObject delta = kind == OpenBlock.Thinking
            ? new JsonObject { ["type"] = "thinking_delta", ["thinking"] = text }
            : new JsonObject { ["type"] = "text_delta", ["text"] = text };
        events.Add(Event("content_block_delta", new JsonObject { ["index"] = _openIndex, ["delta"] = delta }));
        return events;
    }

    private List<BridgeEvent> CloseBlock()
    {
        if (_open == OpenBlock.None) return [];
        var events = new List<BridgeEvent>();
        if (_open == OpenBlock.Thinking)
        {
            events.Add(Event("content_block_delta", new JsonObject
            {
                ["index"] = _openIndex,
                ["delta"] = new JsonObject { ["type"] = "signature_delta", ["signature"] = AnthropicBridge.ThinkingSignature },
            }));
            _content.Add(new JsonObject { ["type"] = "thinking", ["thinking"] = _currentText.ToString(), ["signature"] = AnthropicBridge.ThinkingSignature });
        }
        else
        {
            _content.Add(new JsonObject { ["type"] = "text", ["text"] = _currentText.ToString() });
        }
        events.Add(Event("content_block_stop", new JsonObject { ["index"] = _openIndex }));
        _open = OpenBlock.None;
        return events;
    }

    private void CollectToolCall(JsonObject call, int position)
    {
        var index = call.Int("index") ?? position;
        if (!_calls.TryGetValue(index, out var state))
        {
            state = new ToolCall { Id = call.Str("id") is { Length: > 0 } id ? id : "toolu_" + BridgeJson.ShortId() };
            _calls[index] = state;
            _callOrder.Add(index);
        }
        var function = call.Obj("function");
        if (function.Str("name") is { } name) state.Name += name;
        if (function.Str("arguments") is { } text) state.Arguments += text;
        else if (function?["arguments"] is { } node) state.Arguments += BridgeJson.Serialize(node);
    }

    private List<BridgeEvent> EmitToolCalls()
    {
        var events = new List<BridgeEvent>();
        foreach (var index in _callOrder)
        {
            var call = _calls[index];
            if (call.Name.Length == 0) continue;
            var name = routes.GetValueOrDefault(call.Name)?.Name ?? call.Name;
            var arguments = call.Arguments.Length == 0 ? "{}" : call.Arguments;
            JsonObject input;
            try
            {
                input = JsonNode.Parse(arguments) as JsonObject ?? [];
            }
            catch (JsonException)
            {
                input = [];
            }
            var blockIndex = _nextIndex++;
            events.Add(Event("content_block_start", new JsonObject
            {
                ["index"] = blockIndex,
                ["content_block"] = new JsonObject { ["type"] = "tool_use", ["id"] = call.Id, ["name"] = name, ["input"] = new JsonObject() },
            }));
            events.Add(Event("content_block_delta", new JsonObject
            {
                ["index"] = blockIndex,
                ["delta"] = new JsonObject { ["type"] = "input_json_delta", ["partial_json"] = arguments },
            }));
            events.Add(Event("content_block_stop", new JsonObject { ["index"] = blockIndex }));
            _content.Add(new JsonObject { ["type"] = "tool_use", ["id"] = call.Id, ["name"] = name, ["input"] = input });
        }
        _calls.Clear();
        _callOrder.Clear();
        return events;
    }

    private static BridgeEvent Event(string name, JsonObject fields)
    {
        fields["type"] = name;
        return new BridgeEvent(name, fields);
    }
}
