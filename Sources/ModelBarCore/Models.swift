import Foundation

/// 推理档位。`automatic` 表示不覆盖，由接口或模型自行决定。
public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, low, medium, high, xhigh

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: "默认"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "极高"
        }
    }

    /// 写入配置和请求时使用的值，`automatic` 没有对应值。
    public var wireValue: String? { self == .automatic ? nil : rawValue }
}

public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var supportsReasoning: Bool?
    public var effortLevels: [String]?

    public init(
        id: String,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsReasoning: Bool? = nil,
        effortLevels: [String]? = nil
    ) {
        self.id = id
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.supportsReasoning = supportsReasoning
        self.effortLevels = effortLevels
    }

    /// 接口声明了可选档位时只显示声明的档位，否则显示全部。
    public var availableEfforts: [ReasoningEffort] {
        guard let levels = effortLevels, !levels.isEmpty else { return ReasoningEffort.allCases }
        return ReasoningEffort.allCases.filter { $0 == .automatic || levels.contains($0.rawValue) }
    }
}

public enum ProbeStatus: String, Codable, Sendable {
    case ok, failed, unknown
}

public struct ProbeResult: Codable, Hashable, Sendable {
    public var models: ProbeStatus
    public var chat: ProbeStatus
    public var responses: ProbeStatus
    public var messages: ProbeStatus
    public var latencyMs: Int?
    public var message: String?
    public var testedAt: Date

    public init(
        models: ProbeStatus = .unknown,
        chat: ProbeStatus = .unknown,
        responses: ProbeStatus = .unknown,
        messages: ProbeStatus = .unknown,
        latencyMs: Int? = nil,
        message: String? = nil,
        testedAt: Date = Date()
    ) {
        self.models = models
        self.chat = chat
        self.responses = responses
        self.messages = messages
        self.latencyMs = latencyMs
        self.message = message
        self.testedAt = testedAt
    }

    private enum CodingKeys: String, CodingKey {
        case models, chat, responses, messages, latencyMs, message, testedAt
    }

    /// 旧版本保存的结果没有 messages，不能因此读取失败。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent(ProbeStatus.self, forKey: .models) ?? .unknown
        chat = try container.decodeIfPresent(ProbeStatus.self, forKey: .chat) ?? .unknown
        responses = try container.decodeIfPresent(ProbeStatus.self, forKey: .responses) ?? .unknown
        messages = try container.decodeIfPresent(ProbeStatus.self, forKey: .messages) ?? .unknown
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        testedAt = try container.decodeIfPresent(Date.self, forKey: .testedAt) ?? Date()
    }
}

public struct Endpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var baseURL: String
    public var models: [ModelInfo]
    public var selectedModel: String?
    public var effort: ReasoningEffort
    public var probe: ProbeResult?
    public var hasKey: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        models: [ModelInfo] = [],
        selectedModel: String? = nil,
        effort: ReasoningEffort = .automatic,
        probe: ProbeResult? = nil,
        hasKey: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseURL = Endpoint.normalize(baseURL: baseURL)
        self.models = models
        self.selectedModel = selectedModel
        self.effort = effort
        self.probe = probe
        self.hasKey = hasKey
    }

    public var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    public var currentModel: ModelInfo? {
        guard let selectedModel else { return nil }
        return models.first { $0.id == selectedModel } ?? ModelInfo(id: selectedModel)
    }

    /// 去掉首尾空白、结尾斜杠，以及被误粘贴的具体接口路径。
    public static func normalize(baseURL raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/responses", "/models"] where value.lowercased().hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 跳过明显不是对话模型的条目，避免默认选中向量或语音模型。
    public static func defaultModel(from models: [ModelInfo]) -> String? {
        let excluded = ["embed", "whisper", "tts", "moderation", "rerank", "image", "dall-e", "audio", "transcribe", "ocr"]
        let chat = models.first { model in
            let id = model.id.lowercased()
            return !excluded.contains { id.contains($0) }
        }
        return (chat ?? models.first)?.id
    }

    public static func isValid(baseURL raw: String) -> Bool {
        guard let url = URL(string: normalize(baseURL: raw)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }
}

public enum ToolID: String, Codable, CodingKeyRepresentable, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex, opencode, pi, grok, droid, kilo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .opencode: "opencode"
        case .pi: "pi"
        case .grok: "Grok"
        case .droid: "Factory Droid"
        case .kilo: "Kilo Code"
        }
    }

    public var subtitle: String {
        switch self {
        case .claudeCode: "终端和 VS Code 扩展"
        case .codex: "终端和 Cursor / VS Code 扩展"
        case .opencode, .pi, .grok, .droid: "终端 Agent"
        case .kilo: "Cursor / VS Code 扩展"
        }
    }

    public var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "terminal.fill"
        case .pi: "function"
        case .grok: "bolt.fill"
        case .droid: "cpu.fill"
        case .kilo: "puzzlepiece.extension.fill"
        }
    }
}

extension ToolID {
    /// 这个工具用不了接口的原生协议，需要本机转换才能接入。
    public func needsConversion(_ probe: ProbeResult?) -> Bool {
        guard let probe, probe.chat != .failed else { return false }
        switch self {
        case .codex: return probe.responses == .failed
        case .claudeCode: return probe.messages == .failed
        default: return false
        }
    }
}

public struct Preset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var baseURL: String
    public var needsKey: Bool

    public static let all: [Preset] = [
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", needsKey: true),
        Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", needsKey: true),
        Preset(name: "Kimi", baseURL: "https://api.moonshot.cn/v1", needsKey: true),
        Preset(name: "智谱 GLM", baseURL: "https://open.bigmodel.cn/api/paas/v4", needsKey: true),
        Preset(name: "硅基流动", baseURL: "https://api.siliconflow.cn/v1", needsKey: true),
        Preset(name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1", needsKey: true),
        Preset(name: "Ollama", baseURL: "http://127.0.0.1:11434/v1", needsKey: false),
    ]
}
