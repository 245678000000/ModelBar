import Foundation

public enum EndpointClientError: LocalizedError {
    case invalidURL
    case http(Int, String?)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "接口地址无效"
        case .http(401, _), .http(403, _): "API Key 被拒绝（HTTP 401/403）"
        case .http(404, _): "地址不对：/models 返回 404，请确认是否需要带 /v1"
        case .http(let code, let message): "接口返回 HTTP \(code)" + (message.map { "：\($0)" } ?? "")
        case .malformed: "接口返回的内容不是模型列表"
        }
    }
}

public struct EndpointClient: Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: configuration)
    }

    public func fetchModels(baseURL: String, key: String?) async throws -> [ModelInfo] {
        let request = try makeRequest(baseURL: baseURL, path: "models", key: key)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw EndpointClientError.http(status, Self.errorMessage(in: data))
        }
        guard let models = ModelListParser.parse(data), !models.isEmpty else {
            throw EndpointClientError.malformed
        }
        return models
    }

    /// 依次测试模型列表、Chat、Responses 和 Anthropic。后三项各发一条极短的真实请求。
    public func probe(baseURL: String, key: String?, model: String?) async -> (ProbeResult, [ModelInfo]) {
        var result = ProbeResult()
        var models: [ModelInfo] = []

        let started = Date()
        do {
            models = try await fetchModels(baseURL: baseURL, key: key)
            result.models = .ok
            result.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        } catch {
            result.models = .failed
            result.message = error.localizedDescription
        }

        guard let model = model ?? models.first?.id else { return (result, models) }

        async let chat = postProbe(
            baseURL: baseURL,
            path: "chat/completions",
            key: key,
            body: [
                "model": model,
                "messages": [["role": "user", "content": "ping"]],
                "max_tokens": 1,
                "stream": false,
            ]
        )
        async let responses = postProbe(
            baseURL: baseURL,
            path: "responses",
            key: key,
            body: ["model": model, "input": "ping", "max_output_tokens": 16, "stream": false]
        )
        async let anthropic = postProbe(
            baseURL: baseURL,
            path: "messages",
            key: key,
            body: ["model": model, "max_tokens": 1, "messages": [["role": "user", "content": "ping"]]],
            extraHeaders: ["anthropic-version": "2023-06-01", "x-api-key": key ?? ""]
        )
        let (chatOutcome, responsesOutcome, anthropicOutcome) = await (chat, responses, anthropic)
        result.chat = chatOutcome.status
        result.responses = responsesOutcome.status
        result.messages = anthropicOutcome.status
        if result.message == nil, chatOutcome.status == .failed, responsesOutcome.status == .failed {
            result.message = chatOutcome.message ?? responsesOutcome.message
        }
        return (result, models)
    }

    private func postProbe(
        baseURL: String,
        path: String,
        key: String?,
        body: [String: Any],
        extraHeaders: [String: String] = [:]
    ) async -> (status: ProbeStatus, message: String?) {
        do {
            var request = try makeRequest(baseURL: baseURL, path: path, key: key)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (name, value) in extraHeaders where !value.isEmpty { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.classify(status: status, data: data)
        } catch {
            return (.failed, error.localizedDescription)
        }
    }

    /// 判断路由是否存在。参数被拒（400/422）或限流（429）都说明接口本身是通的。
    static func classify(status: Int, data: Data) -> (status: ProbeStatus, message: String?) {
        let message = errorMessage(in: data)
        switch status {
        case 200..<300:
            return (.ok, nil)
        case 400, 422, 429:
            let lowered = message?.lowercased() ?? ""
            let unsupported = ["not support", "unsupported", "不支持", "unknown url", "invalid url", "no route"]
            return unsupported.contains { lowered.contains($0) } ? (.failed, message) : (.ok, message)
        case 401, 403:
            return (.failed, "API Key 被拒绝（HTTP \(status)）")
        default:
            return (.failed, message ?? "HTTP \(status)")
        }
    }

    private func makeRequest(baseURL: String, path: String, key: String?) throws -> URLRequest {
        guard Endpoint.isValid(baseURL: baseURL),
              let url = URL(string: Endpoint.normalize(baseURL: baseURL) + "/" + path) else {
            throw EndpointClientError.invalidURL
        }
        var request = URLRequest(url: url)
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        return object["message"] as? String
    }
}

/// 不同网关的 /models 字段各不相同，这里统一成一种结构。
public enum ModelListParser {
    public static func parse(_ data: Data) -> [ModelInfo]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let items: [[String: Any]]?
        if let dictionary = object as? [String: Any] {
            items = (dictionary["data"] ?? dictionary["models"] ?? dictionary["result"]) as? [[String: Any]]
        } else {
            items = object as? [[String: Any]]
        }
        return items?.compactMap(parseModel)
    }

    private static func parseModel(_ item: [String: Any]) -> ModelInfo? {
        guard let id = (item["id"] ?? item["model"] ?? item["name"]) as? String, !id.isEmpty else { return nil }
        let capabilities = item["capabilities"] as? [String: Any]
        let topProvider = item["top_provider"] as? [String: Any]
        let parameters = item["supported_parameters"] as? [String]

        let context = int(item, ["context_length", "context_window", "max_context_tokens", "input_token_limit", "max_input_tokens"])
            ?? int(capabilities, ["context_length", "context_window"])
            ?? int(topProvider, ["context_length"])
        let output = int(item, ["max_output_tokens", "max_completion_tokens", "output_token_limit"])
            ?? int(capabilities, ["max_output_tokens"])
            ?? int(topProvider, ["max_completion_tokens"])

        let levels = ((item["effort"] as? [String: Any])?["supported_levels"] as? [String])
            ?? (capabilities?["reasoning_effort"] as? [String])
            ?? (item["supported_reasoning_efforts"] as? [String])
            ?? (item["reasoning_effort"] as? [String])

        var reasoning = (item["supports_reasoning"] as? Bool) ?? (capabilities?["supports_reasoning"] as? Bool)
        if reasoning == nil, let parameters {
            reasoning = parameters.contains("reasoning") || parameters.contains("reasoning_effort")
        }
        if reasoning == nil, levels?.isEmpty == false { reasoning = true }

        return ModelInfo(
            id: id,
            contextLength: context,
            maxOutputTokens: output,
            supportsReasoning: reasoning,
            effortLevels: levels
        )
    }

    private static func int(_ dictionary: [String: Any]?, _ keys: [String]) -> Int? {
        guard let dictionary else { return nil }
        for key in keys {
            if let value = dictionary[key] as? Int, value > 0 { return value }
            if let value = dictionary[key] as? Double, value > 0 { return Int(value) }
            if let value = dictionary[key] as? String, let parsed = Int(value), parsed > 0 { return parsed }
        }
        return nil
    }
}
