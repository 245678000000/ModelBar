using System.Text;
using System.Text.Json.Nodes;
using static ModelBar.Core.Tests.Support;

namespace ModelBar.Core.Tests;

public class ResponsesRequestTests
{
    private static JsonArray Messages(TranslatedRequest t) => t.Body.Arr("messages")!;
    private static List<string?> Roles(JsonArray list) => list.Objects().Select(m => m.Str("role")).ToList();

    [Fact]
    public void MergesLeadingDeveloperMessages()
    {
        var t = ResponsesBridge.Translate(Json("""
            {"model":"m","stream":true,"input":[
              {"type":"message","role":"developer","content":[{"type":"input_text","text":"a"}]},
              {"type":"message","role":"developer","content":[{"type":"input_text","text":"b"},{"type":"input_text","text":"c"}]},
              {"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}
            ]}
            """));
        var list = Messages(t);
        Assert.Equal(["system", "user"], Roles(list));
        Assert.Equal("a\n\nb\n\nc", ((JsonObject)list[0]!).Str("content"));
        Assert.True(t.IsStreaming);
        Assert.True(t.Body.Obj("stream_options").Bool("include_usage"));
    }

    [Fact]
    public void InstructionsAndMidConversationDeveloper()
    {
        var list = Messages(ResponsesBridge.Translate(Json("""
            {"model":"m","instructions":"rules","input":[
              {"type":"message","role":"user","content":"hi"},
              {"type":"message","role":"developer","content":[{"type":"input_text","text":"later"}]}
            ]}
            """)));
        Assert.Equal(["system", "user", "user"], Roles(list));
    }

    [Fact]
    public void MapsParameters()
    {
        var body = ResponsesBridge.Translate(Json("""
            {"model":"m","input":[],"reasoning":{"effort":"high","summary":"auto"},"max_output_tokens":16,"temperature":0.2,
             "store":false,"include":["x"],"prompt_cache_key":"k","client_metadata":{},
             "text":{"format":{"type":"json_schema","name":"n","schema":{"type":"object"},"strict":true}}}
            """)).Body;
        Assert.Equal("high", body.Str("reasoning_effort"));
        Assert.Equal(16, body.Int("max_tokens"));
        Assert.Equal(0.2, body["temperature"]!.GetValue<double>());
        foreach (var key in new[] { "reasoning", "store", "include", "prompt_cache_key", "client_metadata" }) Assert.False(body.ContainsKey(key));
        Assert.Equal("n", body.Obj("response_format").Obj("json_schema").Str("name"));
        Assert.False(ResponsesBridge.Translate(Json("""{"model":"m","input":[],"reasoning":{"effort":"none"}}""")).Body.ContainsKey("reasoning_effort"));
    }

    [Fact]
    public void FlattensToolsAndDropsHostedOnes()
    {
        var t = ResponsesBridge.Translate(Json("""
            {"model":"m","input":[],"tool_choice":"auto","parallel_tool_calls":true,"tools":[
              {"type":"function","name":"exec_command","description":"run","strict":false,"parameters":{"type":"object"}},
              {"type":"namespace","name":"multi_agent_v1","tools":[{"type":"function","name":"close_agent","parameters":{"type":"object"}}]},
              {"type":"custom","name":"apply_patch","description":"patch","format":{"type":"grammar","definition":"G"}},
              {"type":"web_search","external_web_access":false}
            ]}
            """));
        var names = t.Body.Arr("tools").Objects().Select(x => x.Obj("function").Str("name")).ToList();
        Assert.Equal(["exec_command", "multi_agent_v1__close_agent", "apply_patch"], names);
        Assert.Equal(new ToolRoute(ToolRouteKind.Function, "multi_agent_v1", "close_agent"), t.Routes["multi_agent_v1__close_agent"]);
        Assert.Equal(ToolRouteKind.Custom, t.Routes["apply_patch"].Kind);
        Assert.False(t.Body.ContainsKey("parallel_tool_calls"));
    }

    [Fact]
    public void LongToolNamesStayValidAndStable()
    {
        var name = new string('x', 90);
        var first = ResponsesBridge.FlatName("ns", name);
        Assert.True(first.Length <= 64);
        Assert.Equal(first, ResponsesBridge.FlatName("ns", name));
        Assert.NotEqual(first, ResponsesBridge.FlatName("other", name));
        Assert.Equal("a_b_c", ResponsesBridge.FlatName(null, "a.b c"));
    }

    [Fact]
    public void RebuildsToolHistoryWithParallelCalls()
    {
        var list = Messages(ResponsesBridge.Translate(Json("""
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
            """)));
        Assert.Equal(["user", "assistant", "tool", "tool", "user"], Roles(list));
        var calls = ((JsonObject)list[1]!).Arr("tool_calls")!;
        Assert.Equal(2, calls.Count);
        Assert.Equal("ns__tool", ((JsonObject)calls[1]!).Obj("function").Str("name"));
        Assert.Equal("{}", ((JsonObject)calls[1]!).Obj("function").Str("arguments"));
        Assert.Equal("out2", ((JsonObject)list[3]!).Str("content"));
    }

    [Fact]
    public void ToolImagesFollowAllToolResults()
    {
        var list = Messages(ResponsesBridge.Translate(Json("""
            {"model":"m","input":[
              {"type":"function_call","call_id":"a","name":"view_image","arguments":"{}"},
              {"type":"function_call","call_id":"b","name":"t","arguments":"{}"},
              {"type":"function_call_output","call_id":"a","output":[{"type":"input_image","image_url":"data:x"}]},
              {"type":"function_call_output","call_id":"b","output":"text"}
            ]}
            """)));
        Assert.Equal(["assistant", "tool", "tool", "user"], Roles(list));
        Assert.Contains("data:x", list[3]!.ToJsonString());
    }
}

public class ResponsesStreamTests
{
    private static JsonObject Chunk(JsonObject delta, string? finish = null)
    {
        var choice = new JsonObject { ["index"] = 0, ["delta"] = delta };
        if (finish is not null) choice["finish_reason"] = finish;
        return new JsonObject { ["choices"] = new JsonArray(choice) };
    }

    [Fact]
    public void TextStreamProducesOrderedEvents()
    {
        var writer = new ResponsesStreamWriter("m", []);
        var events = writer.Start();
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "He" })));
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "llo" }, "stop")));
        events.AddRange(writer.Consume(Json("""{"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5,"prompt_tokens_details":{"cached_tokens":2},"completion_tokens_details":{"reasoning_tokens":1}}}""")));
        events.AddRange(writer.Finish());
        Assert.Equal(
            ["response.created", "response.in_progress", "response.output_item.added", "response.content_part.added",
             "response.output_text.delta", "response.output_text.delta", "response.output_text.done", "response.content_part.done",
             "response.output_item.done", "response.completed"],
            events.Select(e => e.Name));
        var usage = writer.FinalObject.Obj("usage");
        Assert.Equal(3, usage.Int("input_tokens"));
        Assert.Equal(2, usage.Obj("input_tokens_details").Int("cached_tokens"));
        Assert.Equal(1, usage.Obj("output_tokens_details").Int("reasoning_tokens"));
        Assert.Contains("Hello", writer.FinalObject.Arr("output")!.ToJsonString());
    }

    [Fact]
    public void ToolCallFragmentsAreAssembled()
    {
        var writer = new ResponsesStreamWriter("m", new() { ["ns__tool"] = new ToolRoute(ToolRouteKind.Function, "ns", "tool") });
        var events = writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"ns__tool","arguments":""}}]}""")));
        events.AddRange(writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"function":{"arguments":"{\"a\""}}]}"""))));
        events.AddRange(writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"function":{"arguments":":1}"}}]}"""))));
        events.AddRange(writer.Consume(Chunk(Json("""{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"plain","arguments":"{}"}}]}"""))));
        events.AddRange(writer.Finish());
        var done = events.Where(e => e.Name == "response.output_item.done").Select(e => e.Payload.Obj("item")).ToList();
        Assert.Equal(2, done.Count);
        Assert.Equal("function_call", done[0].Str("type"));
        Assert.Equal("tool", done[0].Str("name"));
        Assert.Equal("ns", done[0].Str("namespace"));
        Assert.Equal("{\"a\":1}", done[0].Str("arguments"));
        Assert.Null(done[1].Str("namespace"));
    }

    [Fact]
    public void CustomToolReturnsRawInput()
    {
        var writer = new ResponsesStreamWriter("m", new() { ["apply_patch"] = new ToolRoute(ToolRouteKind.Custom, null, "apply_patch") });
        var events = writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"id":"c","function":{"name":"apply_patch","arguments":"{\"input\":\"PATCH\"}"}}]}""")));
        events.AddRange(writer.Finish());
        var item = events.First(e => e.Name == "response.output_item.done").Payload.Obj("item");
        Assert.Equal("custom_tool_call", item.Str("type"));
        Assert.Equal("PATCH", item.Str("input"));
    }

    [Fact]
    public void HandlesMissingIdsAndObjectArguments()
    {
        var writer = new ResponsesStreamWriter("m", []);
        var events = writer.Consume(Chunk(Json("""{"tool_calls":[{"function":{"name":"t","arguments":{"k":"v"}}}]}""")));
        events.AddRange(writer.Finish());
        var item = events.First(e => e.Name == "response.output_item.done").Payload.Obj("item");
        Assert.StartsWith("call_", item.Str("call_id"));
        Assert.Equal("{\"k\":\"v\"}", item.Str("arguments"));
    }

    [Fact]
    public void ReasoningRoundTripsThroughEncryptedContent()
    {
        var writer = new ResponsesStreamWriter("m", []);
        var events = writer.Consume(Chunk(new JsonObject { ["reasoning_content"] = "想一" }));
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["reasoning_content"] = "想" })));
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "答案" })));
        events.AddRange(writer.Finish());
        var items = events.Where(e => e.Name == "response.output_item.done").Select(e => e.Payload.Obj("item")).ToList();
        Assert.Equal(["reasoning", "message"], items.Select(i => i.Str("type")));

        var request = new JsonObject
        {
            ["model"] = "m",
            ["input"] = new JsonArray(
                new JsonObject { ["type"] = "message", ["role"] = "user", ["content"] = "q" },
                new JsonObject { ["type"] = "reasoning", ["encrypted_content"] = items[0].Str("encrypted_content") },
                new JsonObject { ["type"] = "message", ["role"] = "assistant", ["content"] = "答案" }),
        };
        Assert.Equal("想一想", ((JsonObject)ResponsesBridge.Translate(request).Body.Arr("messages")![1]!).Str("reasoning_content"));
    }

    [Fact]
    public void FinishStates()
    {
        var length = new ResponsesStreamWriter("m", []);
        length.Consume(Chunk(new JsonObject { ["content"] = "x" }, "length"));
        Assert.Equal("response.incomplete", length.Finish()[^1].Name);
        Assert.Equal("max_output_tokens", length.FinalObject.Obj("incomplete_details").Str("reason"));

        var empty = new ResponsesStreamWriter("m", []);
        Assert.Equal("response.failed", empty.Finish()[^1].Name);
        Assert.True(empty.DidFail);
    }

    [Fact]
    public void EventsEncodeAsServerSentEvents()
    {
        var text = Encoding.UTF8.GetString(new ResponsesStreamWriter("m", []).Start()[0].SseData());
        Assert.StartsWith("event: response.created\ndata: {", text);
        Assert.EndsWith("\n\n", text);
    }
}

public class AnthropicTests
{
    private static JsonObject Chunk(JsonObject delta, string? finish = null)
    {
        var choice = new JsonObject { ["index"] = 0, ["delta"] = delta };
        if (finish is not null) choice["finish_reason"] = finish;
        return new JsonObject { ["choices"] = new JsonArray(choice) };
    }

    [Fact]
    public void TranslatesSystemMessagesToolsAndParameters()
    {
        var body = AnthropicBridge.Translate(Json("""
            {"model":"lite","max_tokens":1024,"stream":true,"temperature":0.5,"stop_sequences":["END"],
             "system":[{"type":"text","text":"rules","cache_control":{"type":"ephemeral"}},{"type":"text","text":"more"}],
             "tools":[{"name":"Bash","description":"run","input_schema":{"type":"object"}},{"type":"web_search_20250305","name":"web_search"}],
             "tool_choice":{"type":"any"},
             "messages":[{"role":"user","content":"hi"},
               {"role":"assistant","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]},
               {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"file"}]},{"type":"text","text":"next"}]}]}
            """)).Body;
        var list = body.Arr("messages")!;
        Assert.Equal(["system", "user", "assistant", "tool", "user"], list.Objects().Select(m => m.Str("role")));
        Assert.Equal("rules\n\nmore", ((JsonObject)list[0]!).Str("content"));
        var call = (JsonObject)((JsonObject)list[2]!).Arr("tool_calls")![0]!;
        Assert.Equal("t1", call.Str("id"));
        Assert.Equal("ls", Json(call.Obj("function").Str("arguments")!).Str("command"));
        Assert.Equal("file", ((JsonObject)list[3]!).Str("content"));
        Assert.Single(body.Arr("tools")!);
        Assert.Equal("required", body.Str("tool_choice"));
        Assert.Equal(1024, body.Int("max_tokens"));
        Assert.Equal("END", body.Arr("stop")![0]!.GetValue<string>());
    }

    [Fact]
    public void LargeMaxTokensIsDropped() =>
        Assert.False(AnthropicBridge.Translate(Json("""{"model":"m","max_tokens":64000,"messages":[]}""")).Body.ContainsKey("max_tokens"));

    [Fact]
    public void EffortComesFromRequestThenDefault()
    {
        Assert.Equal("xhigh", AnthropicBridge.Translate(Json("""{"model":"m","messages":[],"output_config":{"effort":"max"}}"""), "low").Body.Str("reasoning_effort"));
        Assert.Equal("low", AnthropicBridge.Translate(Json("""{"model":"m","messages":[],"thinking":{"type":"enabled","budget_tokens":2000}}""")).Body.Str("reasoning_effort"));
        Assert.Equal("medium", AnthropicBridge.Translate(Json("""{"model":"m","messages":[]}"""), "medium").Body.Str("reasoning_effort"));
        Assert.Null(AnthropicBridge.Translate(Json("""{"model":"m","messages":[]}""")).Body.Str("reasoning_effort"));
    }

    [Fact]
    public void ImagesAndErrorsInToolResults()
    {
        var list = AnthropicBridge.Translate(Json("""
            {"model":"m","messages":[
              {"role":"assistant","content":[{"type":"tool_use","id":"a","name":"Read","input":{}}]},
              {"role":"user","content":[
                {"type":"tool_result","tool_use_id":"a","is_error":true,"content":[{"type":"text","text":"boom"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA"}}]},
                {"type":"image","source":{"type":"url","url":"https://x/y.png"}}
              ]}
            ]}
            """)).Body.Arr("messages")!;
        Assert.Equal(["assistant", "tool", "user", "user"], list.Objects().Select(m => m.Str("role")));
        Assert.Equal("Error: boom", ((JsonObject)list[1]!).Str("content"));
        Assert.Contains("data:image/png;base64,AA", list[2]!.ToJsonString());
        Assert.Contains("https://x/y.png", list[3]!.ToJsonString());
    }

    [Fact]
    public void OnlyOurOwnThinkingIsSentBack()
    {
        JsonObject First(string signature) => (JsonObject)AnthropicBridge.Translate(Json($$"""
            {"model":"m","messages":[{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"{{signature}}"},{"type":"text","text":"x"}]}]}
            """)).Body.Arr("messages")![0]!;
        Assert.Equal("hmm", First("modelbar").Str("reasoning_content"));
        Assert.Null(First("abc").Str("reasoning_content"));
    }

    [Fact]
    public void TextStreamFollowsEventOrder()
    {
        var writer = new AnthropicStreamWriter("m", []);
        var events = writer.Start();
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "He" })));
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "llo" }, "stop")));
        events.AddRange(writer.Consume(Json("""{"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}""")));
        events.AddRange(writer.Finish());
        Assert.Equal(
            ["message_start", "content_block_start", "content_block_delta", "content_block_delta", "content_block_stop", "message_delta", "message_stop"],
            events.Select(e => e.Name));
        Assert.Equal("end_turn", events[5].Payload.Obj("delta").Str("stop_reason"));
        Assert.Equal(7, events[5].Payload.Obj("usage").Int("input_tokens"));
    }

    [Fact]
    public void ThinkingTextAndToolsBecomeSeparateBlocks()
    {
        var writer = new AnthropicStreamWriter("m", new() { ["Bash"] = new ToolRoute(ToolRouteKind.Function, null, "Bash") });
        var events = writer.Consume(Chunk(new JsonObject { ["reasoning_content"] = "think" }));
        events.AddRange(writer.Consume(Chunk(new JsonObject { ["content"] = "run" })));
        events.AddRange(writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"id":"c1","function":{"name":"Bash","arguments":"{\"command\":"}}]}"""))));
        events.AddRange(writer.Consume(Chunk(Json("""{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]}"""), "tool_calls")));
        events.AddRange(writer.Finish());
        var starts = events.Where(e => e.Name == "content_block_start").Select(e => e.Payload.Obj("content_block")).ToList();
        Assert.Equal(["thinking", "text", "tool_use"], starts.Select(b => b.Str("type")));
        Assert.Contains(events, e => e.Payload.Obj("delta").Str("signature") == "modelbar");
        Assert.Equal("tool_use", events.First(e => e.Name == "message_delta").Payload.Obj("delta").Str("stop_reason"));
        Assert.Contains("\"ls\"", writer.FinalObject.Arr("content")!.ToJsonString());
    }

    [Fact]
    public void MapsLengthAndEmpty()
    {
        var length = new AnthropicStreamWriter("m", []);
        length.Consume(Chunk(new JsonObject { ["content"] = "x" }, "length"));
        Assert.Equal("max_tokens", length.Finish().First(e => e.Name == "message_delta").Payload.Obj("delta").Str("stop_reason"));
        var empty = new AnthropicStreamWriter("m", []);
        Assert.Equal("error", empty.Finish()[^1].Name);
        Assert.True(empty.DidFail);
    }
}
