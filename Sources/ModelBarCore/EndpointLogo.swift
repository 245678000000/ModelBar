import Foundation

/// 按接口名和域名找对应的官方图标，图标文件在应用的 Resources/Logos 里。
public enum EndpointLogo {
    private struct Brand {
        let logo: String
        let names: [String]
        var hosts: [String] = []
    }

    private static let brands = [
        Brand(logo: "qoder", names: ["qoder"]),
        Brand(logo: "kiro", names: ["kiro"]),
        Brand(logo: "antigravity", names: ["antigravity"]),
        Brand(logo: "grok", names: ["grok"], hosts: ["x.ai"]),
        Brand(logo: "internlm", names: ["书生", "internlm"], hosts: ["intern-ai.org.cn"]),
        Brand(logo: "qwen", names: ["千问", "通义", "qwen", "tongyi"], hosts: ["dashscope.aliyuncs.com"]),
        Brand(logo: "openai", names: ["openai", "chatgpt", "gpt"], hosts: ["openai.com"]),
        Brand(logo: "claude", names: ["claude", "anthropic"], hosts: ["anthropic.com"]),
        Brand(logo: "deepseek", names: ["deepseek"], hosts: ["deepseek.com"]),
        Brand(logo: "gemini", names: ["gemini"], hosts: ["generativelanguage.googleapis.com"]),
        Brand(logo: "kimi", names: ["kimi", "moonshot", "月之暗面"], hosts: ["moonshot.cn", "moonshot.ai"]),
        Brand(logo: "zhipu", names: ["智谱", "zhipu", "glm"], hosts: ["bigmodel.cn"]),
        Brand(logo: "minimax", names: ["minimax"], hosts: ["minimax.chat", "minimaxi.com"]),
        Brand(logo: "doubao", names: ["豆包", "doubao"], hosts: ["volces.com"]),
        Brand(logo: "openrouter", names: ["openrouter"], hosts: ["openrouter.ai"]),
        Brand(logo: "siliconcloud", names: ["硅基", "siliconflow", "siliconcloud"], hosts: ["siliconflow.cn", "siliconflow.com"]),
    ]

    public static var allLogos: [String] { brands.map(\.logo) }

    /// 名字优先，因为很多接口走同一个代理域名。名字里有多个品牌时取最靠前的。
    public static func match(name: String, host: String? = nil) -> String? {
        var best: (logo: String, position: String.Index)?
        for brand in brands {
            for keyword in brand.names {
                guard let range = name.range(of: keyword, options: .caseInsensitive) else { continue }
                if best.map({ range.lowerBound < $0.position }) ?? true {
                    best = (brand.logo, range.lowerBound)
                }
            }
        }
        if let best { return best.logo }
        guard let host = host?.lowercased() else { return nil }
        return brands.first { brand in
            brand.hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
        }?.logo
    }
}

/// 没有官方图标的接口用文字图标，颜色由名称决定。
public enum EndpointGlyphColors {
    public static let count = 12

    /// FNV-1a。不用 hashValue，它每次启动都会变。
    public static func index(for name: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for scalar in name.unicodeScalars {
            hash = (hash ^ scalar.value) &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }

    /// 按列表顺序分配，撞色时顺延到下一个没用过的颜色，接口比颜色还多时才允许重复。
    public static func assign(_ names: [String]) -> [Int] {
        var used = Set<Int>()
        return names.map { name in
            if used.count == count { used.removeAll() }
            var index = Self.index(for: name)
            while used.contains(index) {
                index = (index + 1) % count
            }
            used.insert(index)
            return index
        }
    }
}
