import Foundation

/// 把 Claude Code 发来的 Anthropic Messages 请求翻译成 Chat Completions，并把回复翻译回去。
public enum AnthropicBridge {
    /// 下一轮带回 thinking 块时用它识别来源，推理内容本身就在块里。
    static let thinkingSignature = "modelbar"
    /// 很多 Chat 接口会拒绝超过模型上限的 max_tokens，而 Claude Code 默认发很大的值。太大时不传，由接口决定。
    static let largestForwardedMaxTokens = 8_192

    public static func translate(_ request: [String: Any], defaultEffort: String? = nil) -> TranslatedRequest {
        var routes: [String: ToolRoute] = [:]
        var tools: [[String: Any]] = []
        for tool in request["tools"] as? [[String: Any]] ?? [] {
            // 没有 input_schema 的是 web_search 这类服务端工具，Chat 接口上没有对应物。
            guard let name = tool["name"] as? String, let schema = tool["input_schema"] as? [String: Any] else { continue }
            let flat = ResponsesBridge.flatName(namespace: nil, name: name)
            routes[flat] = ToolRoute(kind: .function, namespace: nil, name: name)
            var function: [String: Any] = ["name": flat, "parameters": schema]
            if let description = tool["description"] as? String, !description.isEmpty { function["description"] = description }
            tools.append(["type": "function", "function": function])
        }

        let model = request["model"] as? String ?? ""
        let isStreaming = request["stream"] as? Bool ?? false
        var body: [String: Any] = [
            "model": model,
            "messages": buildMessages(request),
            "stream": isStreaming,
        ]
        if isStreaming { body["stream_options"] = ["include_usage": true] }
        if !tools.isEmpty {
            body["tools"] = tools
            if let choice = translateToolChoice(request["tool_choice"]) { body["tool_choice"] = choice }
        }
        if let limit = request["max_tokens"] as? Int, limit <= largestForwardedMaxTokens { body["max_tokens"] = limit }
        for key in ["temperature", "top_p"] {
            if let value = request[key], !(value is NSNull) { body[key] = value }
        }
        if let stop = request["stop_sequences"] as? [String], !stop.isEmpty { body["stop"] = stop }
        if let effort = effort(from: request) ?? defaultEffort { body["reasoning_effort"] = effort }

        return TranslatedRequest(body: body, routes: routes, isStreaming: isStreaming, model: model)
    }

    private static func effort(from request: [String: Any]) -> String? {
        if let effort = (request["output_config"] as? [String: Any])?["effort"] as? String {
            return effort == "max" ? "xhigh" : effort
        }
        guard let thinking = request["thinking"] as? [String: Any],
              thinking["type"] as? String == "enabled",
              let budget = thinking["budget_tokens"] as? Int else { return nil }
        if budget <= 4_096 { return "low" }
        return budget <= 16_000 ? "medium" : "high"
    }

    private static func translateToolChoice(_ choice: Any?) -> Any? {
        guard let choice = choice as? [String: Any] else { return nil }
        switch choice["type"] as? String {
        case "auto": return "auto"
        case "any": return "required"
        case "none": return "none"
        case "tool":
            guard let name = choice["name"] as? String else { return nil }
            return ["type": "function", "function": ["name": ResponsesBridge.flatName(namespace: nil, name: name)]]
        default: return nil
        }
    }

    // MARK: 消息

    private static func buildMessages(_ request: [String: Any]) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        if let system = systemText(request["system"]), !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        for message in request["messages"] as? [[String: Any]] ?? [] {
            let blocks = normalizedBlocks(message["content"])
            if message["role"] as? String == "assistant" {
                messages.append(assistantMessage(blocks))
            } else {
                appendUserMessage(blocks, to: &messages)
            }
        }
        return messages
    }

    private static func systemText(_ system: Any?) -> String? {
        if let text = system as? String { return text }
        guard let blocks = system as? [[String: Any]] else { return nil }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
    }

    private static func normalizedBlocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return [["type": "text", "text": text]] }
        return content as? [[String: Any]] ?? []
    }

    private static func assistantMessage(_ blocks: [[String: Any]]) -> [String: Any] {
        var texts: [String] = []
        var calls: [[String: Any]] = []
        var reasoning: String?
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String { texts.append(text) }
            case "tool_use":
                let name = ResponsesBridge.flatName(namespace: nil, name: block["name"] as? String ?? "")
                calls.append([
                    "id": block["id"] as? String ?? "",
                    "type": "function",
                    "function": ["name": name, "arguments": ResponsesBridge.jsonString(block["input"] ?? [String: Any]())],
                ])
            case "thinking":
                if block["signature"] as? String == thinkingSignature { reasoning = block["thinking"] as? String }
            default:
                break
            }
        }
        var message: [String: Any] = ["role": "assistant"]
        message["content"] = texts.isEmpty ? NSNull() : texts.joined(separator: "\n\n")
        if !calls.isEmpty { message["tool_calls"] = calls }
        if let reasoning { message["reasoning_content"] = reasoning }
        return message
    }

    /// 工具结果要紧跟在 assistant 后面，所以先放 tool 消息，再放用户的文字和图片。
    private static func appendUserMessage(_ blocks: [[String: Any]], to messages: inout [[String: Any]]) {
        var parts: [[String: Any]] = []
        var toolImages: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                let (text, images) = toolResult(block)
                messages.append(["role": "tool", "tool_call_id": block["tool_use_id"] as? String ?? "", "content": text])
                toolImages += images
            case "text":
                if let text = block["text"] as? String { parts.append(["type": "text", "text": text]) }
            case "image":
                if let url = imageURL(block) { parts.append(["type": "image_url", "image_url": ["url": url]]) }
            default:
                break
            }
        }
        if !toolImages.isEmpty {
            var imageParts: [[String: Any]] = [["type": "text", "text": "Images returned by the previous tool call:"]]
            imageParts += toolImages.map { ["type": "image_url", "image_url": ["url": $0]] }
            messages.append(["role": "user", "content": imageParts])
        }
        guard !parts.isEmpty else { return }
        if parts.allSatisfy({ $0["type"] as? String == "text" }) {
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            messages.append(["role": "user", "content": text])
        } else {
            messages.append(["role": "user", "content": parts])
        }
    }

    private static func toolResult(_ block: [String: Any]) -> (String, [String]) {
        var text = ""
        var images: [String] = []
        if let content = block["content"] as? String {
            text = content
        } else {
            var pieces: [String] = []
            for part in block["content"] as? [[String: Any]] ?? [] {
                if let value = part["text"] as? String {
                    pieces.append(value)
                } else if part["type"] as? String == "image", let url = imageURL(part) {
                    images.append(url)
                }
            }
            text = pieces.joined(separator: "\n")
        }
        if block["is_error"] as? Bool == true { text = "Error: " + text }
        return (text, images)
    }

    private static func imageURL(_ block: [String: Any]) -> String? {
        guard let source = block["source"] as? [String: Any] else { return nil }
        if let url = source["url"] as? String { return url }
        guard let data = source["data"] as? String else { return nil }
        return "data:\(source["media_type"] as? String ?? "image/png");base64,\(data)"
    }
}

// MARK: - 流式回复

/// Anthropic 的内容块不能交叉，所以工具调用先攒齐，最后一次性发出。
public final class AnthropicStreamWriter: ChatStreamConsumer {
    private struct ToolCall {
        var id: String
        var name = ""
        var arguments = ""
    }

    private enum OpenBlock { case none, thinking, text }

    private let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    private let model: String
    private let routes: [String: ToolRoute]

    private var nextIndex = 0
    private var open = OpenBlock.none
    private var openIndex = 0
    private var content: [[String: Any]] = []
    private var currentText = ""
    private var calls: [Int: ToolCall] = [:]
    private var callOrder: [Int] = []
    private var usage: [String: Any]?
    private var finishReason: String?

    public private(set) var finalObject: [String: Any] = [:]
    public private(set) var didFail = false

    public init(model: String, routes: [String: ToolRoute]) {
        self.model = model
        self.routes = routes
    }

    public func start() -> [BridgeEvent] {
        [event("message_start", ["message": [
            "id": messageID,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [Any](),
            "stop_reason": NSNull(),
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": 0, "output_tokens": 0],
        ]])]
    }

    public func consume(_ chunk: [String: Any]) -> [BridgeEvent] {
        if let usage = chunk["usage"] as? [String: Any] { self.usage = usage }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return [] }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = (choice["delta"] ?? choice["message"]) as? [String: Any] else { return [] }

        var events: [BridgeEvent] = []
        if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
            events += appendDelta(reasoning, kind: .thinking)
        }
        if let text = delta["content"] as? String, !text.isEmpty {
            events += appendDelta(text, kind: .text)
        }
        for (position, call) in (delta["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            collectToolCall(call, position: position)
        }
        return events
    }

    public func consumeCompletion(_ completion: [String: Any]) -> [BridgeEvent] {
        consume(completion)
    }

    public func finish() -> [BridgeEvent] {
        var events = closeBlock()
        events += emitToolCalls()
        guard !content.isEmpty else {
            return events + fail(message: "接口没有返回任何内容", code: "empty_response")
        }
        let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage?["completion_tokens"] as? Int ?? 0
        let stopReason = mappedStopReason()
        events.append(event("message_delta", [
            "delta": ["stop_reason": stopReason, "stop_sequence": NSNull()],
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
        ]))
        events.append(event("message_stop", [:]))
        finalObject = [
            "id": messageID,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": content,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens],
        ]
        return events
    }

    public func fail(message: String, code: String) -> [BridgeEvent] {
        didFail = true
        let error: [String: Any] = ["type": "api_error", "message": message]
        finalObject = ["type": "error", "error": error]
        return [event("error", ["error": error])]
    }

    private func mappedStopReason() -> String {
        if !callOrder.isEmpty || content.contains(where: { $0["type"] as? String == "tool_use" }) { return "tool_use" }
        switch finishReason {
        case "length": return "max_tokens"
        case "content_filter": return "refusal"
        default: return "end_turn"
        }
    }

    // MARK: 文本和推理

    private func appendDelta(_ text: String, kind: OpenBlock) -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        if open != kind {
            events += closeBlock()
            open = kind
            openIndex = allocateIndex()
            currentText = ""
            let block: [String: Any] = kind == .thinking
                ? ["type": "thinking", "thinking": "", "signature": ""]
                : ["type": "text", "text": ""]
            events.append(event("content_block_start", ["index": openIndex, "content_block": block]))
        }
        currentText += text
        let delta: [String: Any] = kind == .thinking
            ? ["type": "thinking_delta", "thinking": text]
            : ["type": "text_delta", "text": text]
        events.append(event("content_block_delta", ["index": openIndex, "delta": delta]))
        return events
    }

    private func closeBlock() -> [BridgeEvent] {
        guard open != .none else { return [] }
        var events: [BridgeEvent] = []
        if open == .thinking {
            let signature = AnthropicBridge.thinkingSignature
            events.append(event("content_block_delta", ["index": openIndex, "delta": ["type": "signature_delta", "signature": signature]]))
            content.append(["type": "thinking", "thinking": currentText, "signature": signature])
        } else {
            content.append(["type": "text", "text": currentText])
        }
        events.append(event("content_block_stop", ["index": openIndex]))
        open = .none
        return events
    }

    // MARK: 工具调用

    private func collectToolCall(_ call: [String: Any], position: Int) {
        let index = call["index"] as? Int ?? position
        if calls[index] == nil {
            let id = (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            calls[index] = ToolCall(id: id ?? "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
            callOrder.append(index)
        }
        let function = call["function"] as? [String: Any]
        if let name = function?["name"] as? String { calls[index]?.name += name }
        if let text = function?["arguments"] as? String {
            calls[index]?.arguments += text
        } else if let object = function?["arguments"], !(object is NSNull) {
            calls[index]?.arguments += ResponsesBridge.jsonString(object)
        }
    }

    private func emitToolCalls() -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for index in callOrder {
            guard let call = calls[index], !call.name.isEmpty else { continue }
            let name = routes[call.name]?.name ?? call.name
            let arguments = call.arguments.isEmpty ? "{}" : call.arguments
            let input = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
            let blockIndex = allocateIndex()
            events.append(event("content_block_start", ["index": blockIndex, "content_block": [
                "type": "tool_use", "id": call.id, "name": name, "input": [String: Any](),
            ]]))
            events.append(event("content_block_delta", ["index": blockIndex, "delta": [
                "type": "input_json_delta", "partial_json": arguments,
            ]]))
            events.append(event("content_block_stop", ["index": blockIndex]))
            content.append(["type": "tool_use", "id": call.id, "name": name, "input": input])
        }
        calls = [:]
        callOrder = []
        return events
    }

    private func allocateIndex() -> Int {
        defer { nextIndex += 1 }
        return nextIndex
    }

    private func event(_ name: String, _ fields: [String: Any]) -> BridgeEvent {
        var payload = fields
        payload["type"] = name
        return BridgeEvent(name: name, payload: payload)
    }
}
