import Foundation
import Testing
@testable import ModelBarCore

@Suite struct EndpointLogoTests {
    @Test(arguments: [
        ("qoder", "qoder"),
        ("kiro", "kiro"),
        ("antigravity", "antigravity"),
        ("grok", "grok"),
        ("书生", "internlm"),
        ("千问办公", "qwen"),
        ("通义", "qwen"),
        ("ChatGPT", "openai"),
        ("Claude", "claude"),
        ("DeepSeek 官方", "deepseek"),
        ("月之暗面", "kimi"),
        ("智谱 GLM", "zhipu"),
        ("豆包", "doubao"),
        ("硅基流动", "siliconcloud"),
    ])
    func matchesByNameIgnoringCase(name: String, logo: String) {
        #expect(EndpointLogo.match(name: name) == logo)
        #expect(EndpointLogo.match(name: name.uppercased()) == logo)
    }

    @Test func nameWinsOverHostBecauseManyEndpointsShareAProxy() {
        #expect(EndpointLogo.match(name: "千问办公", host: "kiro.example.com") == "qwen")
        #expect(EndpointLogo.match(name: "grok", host: "api.openai.com") == "grok")
    }

    @Test func proxyHostContainingABrandNameDoesNotCount() {
        #expect(EndpointLogo.match(name: "备用", host: "kiro.example.com") == nil)
        #expect(EndpointLogo.match(name: "备用", host: "grok.example.com") == nil)
    }

    @Test(arguments: [
        ("discovery-api.intern-ai.org.cn", "internlm"),
        ("api.openai.com", "openai"),
        ("api.x.ai", "grok"),
        ("OPEN.BIGMODEL.CN", "zhipu"),
        ("dashscope.aliyuncs.com", "qwen"),
    ])
    func fallsBackToKnownHosts(host: String, logo: String) {
        #expect(EndpointLogo.match(name: "我的接口", host: host) == logo)
    }

    @Test func hostMustMatchAWholeDomain() {
        #expect(EndpointLogo.match(name: "我的接口", host: "notopenai.com") == nil)
        #expect(EndpointLogo.match(name: "我的接口", host: "openai.com.example.org") == nil)
    }

    @Test func earliestBrandInTheNameWins() {
        #expect(EndpointLogo.match(name: "claude 走 kiro") == "claude")
        #expect(EndpointLogo.match(name: "kiro 里的 claude") == "kiro")
    }

    @Test func endpointsWithoutABrandHaveNoLogo() {
        #expect(EndpointLogo.match(name: "交大", host: "models.sjtu.edu.cn") == nil)
        #expect(EndpointLogo.match(name: "") == nil)
    }

    /// 打包脚本从这个目录复制图标，少一个文件就会静默退回文字图标。
    @Test func everyLogoHasAnImageAndEveryImageIsUsed() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "assets/logos", directoryHint: .isDirectory)
        let images = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".png") }
            .map { String($0.dropLast(4)) }
        #expect(Set(images) == Set(EndpointLogo.allLogos))
    }
}

@Suite struct EndpointGlyphColorsTests {
    @Test func colorStaysInRangeAndIsStable() {
        for name in ["", "交大", "kiro", "一个很长很长的接口名字"] {
            let index = EndpointGlyphColors.index(for: name)
            #expect((0..<EndpointGlyphColors.count).contains(index))
            #expect(index == EndpointGlyphColors.index(for: name))
        }
        // 固定值：换算法会让所有接口变色，要有意才能改。
        #expect(EndpointGlyphColors.index(for: "kiro") == 6)
    }

    @Test func assignsDifferentColorsWhileThereAreEnough() {
        let names = (0..<EndpointGlyphColors.count).map { "接口 \($0)" }
        #expect(Set(EndpointGlyphColors.assign(names)).count == names.count)
    }

    @Test func sameNameStillGetsDifferentColors() {
        let colors = EndpointGlyphColors.assign(["交大", "交大"])
        #expect(colors[0] != colors[1])
    }

    @Test func firstEndpointKeepsItsOwnColor() {
        #expect(EndpointGlyphColors.assign(["交大", "书生"])[0] == EndpointGlyphColors.index(for: "交大"))
    }

    @Test func moreEndpointsThanColorsStillWorks() {
        let names = (0..<30).map { "接口 \($0)" }
        let colors = EndpointGlyphColors.assign(names)
        #expect(colors.count == names.count)
        #expect(colors.allSatisfy { (0..<EndpointGlyphColors.count).contains($0) })
    }
}
