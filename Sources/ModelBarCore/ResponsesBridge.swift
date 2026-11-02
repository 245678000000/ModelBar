import Foundation

/// 把 Codex 发来的 Responses 请求翻译成 Chat Completions，并把 Chat 的流式回复翻译回去。
public struct ToolRoute: Equatable, Sendable {
    public enum Kind: Sendable { case function, custom }
    public var kind: Kind
    public var namespace: String?
    public var name: String

    public init(kind: Kind, namespace: String?, name: String) {
        self.kind = kind
        self.namespace = namespace
        self.name = name
    }
}

public struct TranslatedRequest {
    public var body: [String: Any]
    public var routes: [String: ToolRoute]
    public var isStreaming: Bool
    public var model: String
}

public enum ResponsesBridge {
    /// 上游的推理内容存进 encrypted_content，下一轮 Codex 原样带回时再还原。
    static let reasoningPrefix = "modelbar:"

    public static func translate(_ request: [String: Any]) -> TranslatedRequest {
        var routes: [String: ToolRoute] = [:]
        var tools: [[String: Any]] = []
        for tool in request["tools"] as? [[String: Any]] ?? [] {
            appendTool(tool, namespace: nil, tools: &tools, routes: &routes)
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
            if request["parallel_tool_calls"] as? Bool == false { body["parallel_tool_calls"] = false }
        }
        for key in ["temperature", "top_p"] {
            if let value = request[key], !(value is NSNull) { body[key] = value }
        }
        if let limit = request["max_output_tokens"] as? Int { body["max_tokens"] = limit }
        if let effort = (request["reasoning"] as? [String: Any])?["effort"] as? String, effort != "none" {
            body["reasoning_effort"] = effort
        }
        if let format = translateTextFormat(request["text"]) { body["response_format"] = format }

        return TranslatedRequest(body: body, routes: routes, isStreaming: isStreaming, model: model)
    }

    // MARK: 工具

    private static func appendTool(
        _ tool: [String: Any],
        namespace: String?,
        tools: inout [[String: Any]],
        routes: inout [String: ToolRoute]
    ) {
        switch tool["type"] as? String {
        case "function":
            guard let name = tool["name"] as? String else { return }
            let flat = flatName(namespace: namespace, name: name)
            routes[flat] = ToolRoute(kind: .function, namespace: namespace, name: name)
            let parameters = tool["parameters"] as? [String: Any]
                ?? ["type": "object", "properties": [String: Any]()]
            tools.append(chatTool(name: flat, description: tool["description"] as? String, parameters: parameters))
        case "namespace":
            let inner = tool["name"] as? String
            for nested in tool["tools"] as? [[String: Any]] ?? [] {
                appendTool(nested, namespace: inner, tools: &tools, routes: &routes)
            }
        case "custom":
            guard let name = tool["name"] as? String else { return }
            let flat = flatName(namespace: namespace, name: name)
            routes[flat] = ToolRoute(kind: .custom, namespace: namespace, name: name)
            var description = tool["description"] as? String ?? ""
            if let definition = (tool["format"] as? [String: Any])?["definition"] as? String {
                description += "\n\nThe input must follow this grammar:\n\(definition)"
            }
            let parameters: [String: Any] = [
                "type": "object",
                "properties": ["input": ["type": "string", "description": "The raw tool input."]],
                "required": ["input"],
            ]
            tools.append(chatTool(name: flat, description: description, parameters: parameters))
        default:
            // web_search 这类由 OpenAI 服务端执行的工具，在 Chat 接口上没有对应物。
            break
        }
    }

    private static func chatTool(name: String, description: String?, parameters: [String: Any]) -> [String: Any] {
        var function: [String: Any] = ["name": name, "parameters": parameters]
        if let description, !description.isEmpty { function["description"] = description }
        return ["type": "function", "function": function]
    }

    /// Chat 接口的函数名限制为 64 个字母、数字、下划线或连字符。
    static func flatName(namespace: String?, name: String) -> String {
        let joined = namespace.map { "\($0)__\(name)" } ?? name
        let cleaned = String(joined.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
        guard cleaned.count > 64 else { return cleaned }
        var hash: UInt32 = 2_166_136_261
        for byte in joined.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return String(cleaned.prefix(55)) + "_" + String(format: "%08x", hash)
    }

    private static func translateToolChoice(_ choice: Any?) -> Any? {
        if let choice = choice as? String { return choice }
        if let choice = choice as? [String: Any],
           choice["type"] as? String == "function",
           let name = choice["name"] as? String {
            return ["type": "function", "function": ["name": flatName(namespace: choice["namespace"] as? String, name: name)]]
        }
        return nil
    }

    private static func translateTextFormat(_ text: Any?) -> Any? {
        guard let format = (text as? [String: Any])?["format"] as? [String: Any],
              format["type"] as? String == "json_schema" else { return nil }
        var schema: [String: Any] = [:]
        for key in ["name", "schema", "strict"] {
            if let value = format[key] { schema[key] = value }
        }
        return ["type": "json_schema", "json_schema": schema]
    }

    // MARK: 消息

    private static func buildMessages(_ request: [String: Any]) -> [[String: Any]] {
        var builder = MessageBuilder()
        if let instructions = request["instructions"] as? String, !instructions.isEmpty {
            builder.appendInstruction(instructions)
        }
        if let text = request["input"] as? String {
            builder.appendMessage(role: "user", content: text)
        }
        for item in request["input"] as? [[String: Any]] ?? [] {
            builder.append(item)
        }
        builder.finish()
        return builder.messages
    }

    private struct MessageBuilder {
        var messages: [[String: Any]] = []
        private var pendingReasoning: String?
        private var pendingImages: [String] = []
        private var seenConversation = false

        mutating func append(_ item: [String: Any]) {
            let type = item["type"] as? String ?? "message"
            switch type {
            case "message":
                appendMessageItem(item)
            case "function_call":
                let name = ResponsesBridge.flatName(namespace: item["namespace"] as? String, name: item["name"] as? String ?? "")
                appendToolCall(id: item["call_id"] as? String, name: name, arguments: item["arguments"] as? String ?? "{}")
            case "custom_tool_call":
                let name = ResponsesBridge.flatName(namespace: item["namespace"] as? String, name: item["name"] as? String ?? "")
                let arguments = ResponsesBridge.jsonString(["input": item["input"] as? String ?? ""])
                appendToolCall(id: item["call_id"] as? String, name: name, arguments: arguments)
            case "function_call_output", "custom_tool_call_output":
                appendToolOutput(id: item["call_id"] as? String, output: item["output"])
            case "reasoning":
                if let stored = item["encrypted_content"] as? String { restoreReasoning(stored) }
            default:
                appendGenericItem(item, type: type)
            }
        }

        /// 其他带 call_id 的内置工具项也按工具调用处理，保证调用和结果成对。
        private mutating func appendGenericItem(_ item: [String: Any], type: String) {
            guard let callID = item["call_id"] as? String else { return }
            if type.hasSuffix("_output") {
                appendToolOutput(id: callID, output: item["output"])
            } else if type.hasSuffix("_call") {
                let name = item["name"] as? String ?? String(type.dropLast("_call".count))
                let arguments = item["arguments"] as? String
                    ?? ResponsesBridge.jsonString(item["action"] ?? [String: Any]())
                appendToolCall(id: callID, name: ResponsesBridge.flatName(namespace: nil, name: name), arguments: arguments)
            }
        }

        mutating func appendInstruction(_ text: String) {
            if !seenConversation, let last = messages.indices.last, messages[last]["role"] as? String == "system",
               let existing = messages[last]["content"] as? String {
                messages[last]["content"] = existing + "\n\n" + text
            } else if seenConversation {
                // 很多模型只接受开头的 system，对话中途的系统消息改用 user。
                flushImages()
                messages.append(["role": "user", "content": text])
            } else {
                messages.append(["role": "system", "content": text])
            }
        }

        mutating func appendMessage(role: String, content: Any) {
            flushImages()
            seenConversation = true
            var message: [String: Any] = ["role": role, "content": content]
            if role == "assistant", let reasoning = pendingReasoning {
                message["reasoning_content"] = reasoning
                pendingReasoning = nil
            }
            messages.append(message)
        }

        private mutating func appendMessageItem(_ item: [String: Any]) {
            let role = item["role"] as? String ?? "user"
            let content = ResponsesBridge.chatContent(item["content"])
            if role == "developer" || role == "system" {
                if let text = content as? String, !text.isEmpty { appendInstruction(text) }
                return
            }
            appendMessage(role: role, content: content)
        }

        private mutating func appendToolCall(id: String?, name: String, arguments: String) {
            flushImages()
            seenConversation = true
            let call: [String: Any] = [
                "id": id ?? "call_\(UUID().uuidString.prefix(8))",
                "type": "function",
                "function": ["name": name, "arguments": arguments.isEmpty ? "{}" : arguments],
            ]
            if let last = messages.indices.last, messages[last]["role"] as? String == "assistant" {
                var calls = messages[last]["tool_calls"] as? [[String: Any]] ?? []
                calls.append(call)
                messages[last]["tool_calls"] = calls
                return
            }
            var message: [String: Any] = ["role": "assistant", "content": NSNull(), "tool_calls": [call]]
            if let reasoning = pendingReasoning {
                message["reasoning_content"] = reasoning
                pendingReasoning = nil
            }
            messages.append(message)
        }

        private mutating func appendToolOutput(id: String?, output: Any?) {
            seenConversation = true
            let (text, images) = ResponsesBridge.toolOutput(output)
            messages.append(["role": "tool", "tool_call_id": id ?? "", "content": text])
            pendingImages += images
        }

        private mutating func restoreReasoning(_ stored: String) {
            guard stored.hasPrefix(ResponsesBridge.reasoningPrefix),
                  let data = Data(base64Encoded: String(stored.dropFirst(ResponsesBridge.reasoningPrefix.count))),
                  let text = String(data: data, encoding: .utf8) else { return }
            pendingReasoning = text
        }

        mutating func finish() {
            flushImages()
        }

        /// tool 消息只能放文字，工具返回的图片放到紧跟着的 user 消息里。
        private mutating func flushImages() {
            guard !pendingImages.isEmpty else { return }
            var parts: [[String: Any]] = [["type": "text", "text": "Images returned by the previous tool call:"]]
            parts += pendingImages.map { ["type": "image_url", "image_url": ["url": $0]] }
            pendingImages = []
            messages.append(["role": "user", "content": parts])
        }
    }

    static func chatContent(_ content: Any?) -> Any {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        var texts: [String] = []
        var images: [String] = []
        for part in parts {
            if let text = part["text"] as? String {
                texts.append(text)
            } else if part["type"] as? String == "input_image", let url = part["image_url"] as? String {
                images.append(url)
            }
        }
        let joined = texts.joined(separator: "\n\n")
        guard !images.isEmpty else { return joined }
        var result: [[String: Any]] = joined.isEmpty ? [] : [["type": "text", "text": joined]]
        result += images.map { ["type": "image_url", "image_url": ["url": $0]] }
        return result
    }

    static func toolOutput(_ output: Any?) -> (String, [String]) {
        if let text = output as? String { return (text, []) }
        if let parts = output as? [[String: Any]] {
            var texts: [String] = []
            var images: [String] = []
            for part in parts {
                if let text = part["text"] as? String {
                    texts.append(text)
                } else if let url = part["image_url"] as? String {
                    images.append(url)
                }
            }
            return (texts.joined(separator: "\n"), images)
        }
        return (output.map { jsonString($0) } ?? "", [])
    }

    static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

// MARK: - 流式回复

public struct BridgeEvent {
    public var name: String
    public var payload: [String: Any]

    public var sseData: Data {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        var data = Data("event: \(name)\ndata: ".utf8)
        data.append(json)
        data.append(Data("\n\n".utf8))
        return data
    }
}

/// 转换服务读取 Chat 回复时用的统一接口，Responses 和 Anthropic 各有一种实现。
public protocol ChatStreamConsumer: AnyObject {
    var finalObject: [String: Any] { get }
    var didFail: Bool { get }
    func start() -> [BridgeEvent]
    func consume(_ chunk: [String: Any]) -> [BridgeEvent]
    func consumeCompletion(_ completion: [String: Any]) -> [BridgeEvent]
    func finish() -> [BridgeEvent]
    func fail(message: String, code: String) -> [BridgeEvent]
}

/// 逐块读取 Chat 的回复，生成对应的 Responses 事件。
public final class ResponsesStreamWriter: ChatStreamConsumer {
    private struct ToolCall {
        var itemID: String
        var callID: String
        var name = ""
        var arguments = ""
        var outputIndex: Int?
    }

    private let responseID = "resp_" + ResponsesStreamWriter.shortID()
    private let createdAt = Int(Date().timeIntervalSince1970)
    private let model: String
    private let routes: [String: ToolRoute]

    private var sequence = 0
    private var nextOutputIndex = 0
    private var output: [Int: [String: Any]] = [:]
    private var usage: [String: Any]?
    private var finishReason: String?
    private var failure: [String: Any]?

    private var reasoningID: String?
    private var reasoningIndex = 0
    private var reasoningText = ""

    private var messageID: String?
    private var messageIndex = 0
    private var messageText = ""

    private var toolCalls: [Int: ToolCall] = [:]
    private var toolOrder: [Int] = []

    public private(set) var response: [String: Any] = [:]
    public var finalObject: [String: Any] { response }
    public var didFail: Bool { failure != nil }

    public init(model: String, routes: [String: ToolRoute]) {
        self.model = model
        self.routes = routes
    }

    private static func shortID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
    }

    public func start() -> [BridgeEvent] {
        let snapshot = responseObject(status: "in_progress")
        return [
            event("response.created", ["response": snapshot]),
            event("response.in_progress", ["response": snapshot]),
        ]
    }

    public func consume(_ chunk: [String: Any]) -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        if let usage = chunk["usage"] as? [String: Any] { self.usage = usage }
        guard let choice = (chunk["choices"] as? [[String: Any]])?.first else { return events }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = (choice["delta"] ?? choice["message"]) as? [String: Any] else { return events }

        if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !reasoning.isEmpty {
            events += closeMessage()
            events += appendReasoning(reasoning)
        }
        if let content = delta["content"] as? String, !content.isEmpty {
            events += closeReasoning()
            events += appendText(content)
        }
        if let calls = delta["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            events += closeReasoning()
            events += closeMessage()
            for (position, call) in calls.enumerated() {
                events += appendToolCall(call, position: position)
            }
        }
        return events
    }

    /// 接口忽略 stream: true、直接返回完整 JSON 时，转成一次性的数据块处理。
    public func consumeCompletion(_ completion: [String: Any]) -> [BridgeEvent] {
        consume(completion)
    }

    public func finish() -> [BridgeEvent] {
        var events = closeReasoning()
        events += closeMessage()
        events += closeToolCalls()
        if output.isEmpty {
            return events + fail(message: "接口没有返回任何内容", code: "empty_response")
        }
        let incompleteReason: String? = switch finishReason {
        case "length": "max_output_tokens"
        case "content_filter": "content_filter"
        default: nil
        }
        response = responseObject(status: incompleteReason == nil ? "completed" : "incomplete", incompleteReason: incompleteReason)
        events.append(event(incompleteReason == nil ? "response.completed" : "response.incomplete", ["response": response]))
        return events
    }

    public func fail(message: String, code: String) -> [BridgeEvent] {
        failure = ["code": code, "message": message]
        response = responseObject(status: "failed")
        return [event("response.failed", ["response": response])]
    }

    // MARK: 推理内容

    private func appendReasoning(_ text: String) -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        if reasoningID == nil {
            let id = "rs_" + Self.shortID()
            reasoningID = id
            reasoningIndex = allocateIndex()
            reasoningText = ""
            events.append(event("response.output_item.added", [
                "output_index": reasoningIndex,
                "item": ["type": "reasoning", "id": id, "summary": [Any]()],
            ]))
            events.append(event("response.reasoning_summary_part.added", [
                "item_id": id,
                "output_index": reasoningIndex,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": ""],
            ]))
        }
        reasoningText += text
        events.append(event("response.reasoning_summary_text.delta", [
            "item_id": reasoningID ?? "",
            "output_index": reasoningIndex,
            "summary_index": 0,
            "delta": text,
        ]))
        return events
    }

    private func closeReasoning() -> [BridgeEvent] {
        guard let id = reasoningID else { return [] }
        reasoningID = nil
        let stored = ResponsesBridge.reasoningPrefix + Data(reasoningText.utf8).base64EncodedString()
        let item: [String: Any] = [
            "type": "reasoning",
            "id": id,
            "summary": [["type": "summary_text", "text": reasoningText]],
            "encrypted_content": stored,
        ]
        output[reasoningIndex] = item
        return [
            event("response.reasoning_summary_text.done", [
                "item_id": id, "output_index": reasoningIndex, "summary_index": 0, "text": reasoningText,
            ]),
            event("response.reasoning_summary_part.done", [
                "item_id": id,
                "output_index": reasoningIndex,
                "summary_index": 0,
                "part": ["type": "summary_text", "text": reasoningText],
            ]),
            event("response.output_item.done", ["output_index": reasoningIndex, "item": item]),
        ]
    }

    // MARK: 文本

    private func appendText(_ text: String) -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        if messageID == nil {
            let id = "msg_" + Self.shortID()
            messageID = id
            messageIndex = allocateIndex()
            messageText = ""
            events.append(event("response.output_item.added", [
                "output_index": messageIndex,
                "item": ["type": "message", "id": id, "status": "in_progress", "role": "assistant", "content": [Any]()],
            ]))
            events.append(event("response.content_part.added", [
                "item_id": id,
                "output_index": messageIndex,
                "content_index": 0,
                "part": ["type": "output_text", "text": "", "annotations": [Any]()],
            ]))
        }
        messageText += text
        events.append(event("response.output_text.delta", [
            "item_id": messageID ?? "",
            "output_index": messageIndex,
            "content_index": 0,
            "delta": text,
        ]))
        return events
    }

    private func closeMessage() -> [BridgeEvent] {
        guard let id = messageID else { return [] }
        messageID = nil
        let part: [String: Any] = ["type": "output_text", "text": messageText, "annotations": [Any]()]
        let item: [String: Any] = ["type": "message", "id": id, "status": "completed", "role": "assistant", "content": [part]]
        output[messageIndex] = item
        return [
            event("response.output_text.done", [
                "item_id": id, "output_index": messageIndex, "content_index": 0, "text": messageText,
            ]),
            event("response.content_part.done", [
                "item_id": id, "output_index": messageIndex, "content_index": 0, "part": part,
            ]),
            event("response.output_item.done", ["output_index": messageIndex, "item": item]),
        ]
    }

    // MARK: 工具调用

    private func appendToolCall(_ call: [String: Any], position: Int) -> [BridgeEvent] {
        let index = call["index"] as? Int ?? position
        if toolCalls[index] == nil {
            toolCalls[index] = ToolCall(
                itemID: "fc_" + Self.shortID(),
                callID: (call["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "call_" + Self.shortID()
            )
            toolOrder.append(index)
        }
        guard var state = toolCalls[index] else { return [] }
        let function = call["function"] as? [String: Any]
        if let name = function?["name"] as? String { state.name += name }

        var fragment = ""
        if let text = function?["arguments"] as? String {
            fragment = text
        } else if let object = function?["arguments"], !(object is NSNull) {
            // 个别网关把参数直接放成 JSON 对象。
            fragment = ResponsesBridge.jsonString(object)
        }
        state.arguments += fragment

        var events: [BridgeEvent] = []
        if state.outputIndex == nil, !state.name.isEmpty {
            let outputIndex = allocateIndex()
            state.outputIndex = outputIndex
            events.append(event("response.output_item.added", [
                "output_index": outputIndex,
                "item": toolItem(state, status: "in_progress", arguments: ""),
            ]))
            if !state.arguments.isEmpty, route(for: state).kind == .function {
                events.append(argumentsDelta(state, delta: state.arguments))
            }
        } else if !fragment.isEmpty, state.outputIndex != nil, route(for: state).kind == .function {
            events.append(argumentsDelta(state, delta: fragment))
        }
        toolCalls[index] = state
        return events
    }

    private func closeToolCalls() -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for index in toolOrder {
            guard var state = toolCalls[index], !state.name.isEmpty else { continue }
            if state.arguments.isEmpty { state.arguments = "{}" }
            let outputIndex: Int
            if let existing = state.outputIndex {
                outputIndex = existing
            } else {
                outputIndex = allocateIndex()
                state.outputIndex = outputIndex
                events.append(event("response.output_item.added", [
                    "output_index": outputIndex,
                    "item": toolItem(state, status: "in_progress", arguments: ""),
                ]))
            }
            let item = toolItem(state, status: "completed", arguments: state.arguments)
            if route(for: state).kind == .function {
                events.append(event("response.function_call_arguments.done", [
                    "item_id": state.itemID, "output_index": outputIndex, "arguments": state.arguments,
                ]))
            }
            events.append(event("response.output_item.done", ["output_index": outputIndex, "item": item]))
            output[outputIndex] = item
        }
        toolCalls = [:]
        toolOrder = []
        return events
    }

    private func argumentsDelta(_ state: ToolCall, delta: String) -> BridgeEvent {
        event("response.function_call_arguments.delta", [
            "item_id": state.itemID, "output_index": state.outputIndex ?? 0, "delta": delta,
        ])
    }

    private func route(for state: ToolCall) -> ToolRoute {
        routes[state.name] ?? ToolRoute(kind: .function, namespace: nil, name: state.name)
    }

    private func toolItem(_ state: ToolCall, status: String, arguments: String) -> [String: Any] {
        let route = route(for: state)
        var item: [String: Any] = ["id": state.itemID, "call_id": state.callID, "name": route.name, "status": status]
        if let namespace = route.namespace { item["namespace"] = namespace }
        switch route.kind {
        case .function:
            item["type"] = "function_call"
            item["arguments"] = arguments
        case .custom:
            item["type"] = "custom_tool_call"
            let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any]
            item["input"] = parsed?["input"] as? String ?? arguments
        }
        return item
    }

    // MARK: 公共

    private func allocateIndex() -> Int {
        defer { nextOutputIndex += 1 }
        return nextOutputIndex
    }

    private func event(_ name: String, _ fields: [String: Any]) -> BridgeEvent {
        var payload = fields
        payload["type"] = name
        payload["sequence_number"] = sequence
        sequence += 1
        return BridgeEvent(name: name, payload: payload)
    }

    private func responseObject(status: String, incompleteReason: String? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": responseID,
            "object": "response",
            "created_at": createdAt,
            "status": status,
            "model": model,
            "output": output.keys.sorted().compactMap { output[$0] },
            "usage": mappedUsage() ?? NSNull(),
            "error": failure ?? NSNull(),
            "incomplete_details": incompleteReason.map { ["reason": $0] as Any } ?? NSNull(),
        ]
        object["parallel_tool_calls"] = true
        return object
    }

    private func mappedUsage() -> [String: Any]? {
        guard let usage else { return nil }
        let input = usage["prompt_tokens"] as? Int ?? 0
        let outputTokens = usage["completion_tokens"] as? Int ?? 0
        let cached = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? 0
        let reasoning = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int ?? 0
        return [
            "input_tokens": input,
            "input_tokens_details": ["cached_tokens": cached],
            "output_tokens": outputTokens,
            "output_tokens_details": ["reasoning_tokens": reasoning],
            "total_tokens": usage["total_tokens"] as? Int ?? input + outputTokens,
        ]
    }
}
