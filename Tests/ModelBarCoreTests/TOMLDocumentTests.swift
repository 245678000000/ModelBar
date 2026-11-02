import Foundation
import Testing
@testable import ModelBarCore

@Suite struct TOMLDocumentTests {
    static let sample = """
    # top comment
    model = "gpt-6.1-sol"
    model_reasoning_effort = "xhigh"
    notify = [
      "/path/with [brackets]/client",
      "turn-ended"
    ]
    service_tier = "priority"

    # comment for the OpenAI table
    [model_providers.OpenAI]
    name = "OpenAI"
    base_url = "https://example.com/v1"

    [model_providers.magpie]
    http_headers = { "x-a" = "b" }
    wire_api = "responses"

    [[hooks]]
    text = \"\"\"
    [not.a.table]
    model = "nope"
    \"\"\"

    """

    @Test func readsTopLevelAndTableValues() {
        let document = TOMLDocument(text: Self.sample)
        #expect(document.string(forKey: "model") == "gpt-6.1-sol")
        #expect(document.string(forKey: "base_url", inTable: "model_providers.OpenAI") == "https://example.com/v1")
        #expect(document.string(forKey: "wire_api", inTable: "model_providers.magpie") == "responses")
        #expect(document.rawValue(forKey: "notify")?.contains("turn-ended") == true)
    }

    @Test func multilineStringContentIsNotTreatedAsTable() {
        let document = TOMLDocument(text: Self.sample)
        #expect(!document.hasTable("not.a.table"))
    }

    @Test func insertsNewKeyBeforeFirstTable() {
        var document = TOMLDocument(text: Self.sample)
        document.setTopLevel("model_provider", rawValue: "\"modelbar\"")
        let lines = document.lines
        let inserted = lines.firstIndex(of: "model_provider = \"modelbar\"")!
        let firstTable = lines.firstIndex { $0.hasPrefix("[model_providers") }!
        #expect(inserted < firstTable)
        #expect(lines[inserted - 1] == "service_tier = \"priority\"")
    }

    @Test func insertsIntoFileThatStartsWithTable() {
        var document = TOMLDocument(text: "# about a\n[a]\nb = 1\n")
        document.setTopLevel("model", rawValue: "\"m\"")
        #expect(document.text == "model = \"m\"\n# about a\n[a]\nb = 1\n")
    }

    @Test func replacesAndRemovesKeysWithoutTouchingOthers() {
        var document = TOMLDocument(text: Self.sample)
        document.setTopLevel("model", rawValue: "\"other\"")
        document.setTopLevel("model_reasoning_effort", rawValue: nil)
        #expect(document.string(forKey: "model") == "other")
        #expect(document.rawValue(forKey: "model_reasoning_effort") == nil)
        #expect(document.string(forKey: "service_tier") == "priority")
        #expect(document.string(forKey: "name", inTable: "model_providers.OpenAI") == "OpenAI")
    }

    @Test func removingMultilineValueRemovesAllItsLines() {
        var document = TOMLDocument(text: Self.sample)
        document.setTopLevel("notify", rawValue: nil)
        #expect(!document.text.contains("turn-ended"))
        #expect(document.string(forKey: "service_tier") == "priority")
    }

    @Test func removeTableKeepsCommentOfNextTable() {
        var document = TOMLDocument(text: "[x]\na = 1\n\n# about y\n[y]\nb = 2\n")
        document.removeTable("x")
        #expect(document.text.contains("# about y\n[y]"))
        #expect(!document.hasTable("x"))
    }

    @Test func removeTableAlsoRemovesSubtablesAndMarker() {
        var document = TOMLDocument(text: "a = 1\n\n# marker\n[p.m]\nb = 2\n\n[p.m.auth]\nc = 3\n")
        document.removeTable("p.m", marker: "# marker")
        #expect(document.text == "a = 1\n")
    }

    @Test func doesNotRemoveTableWithSharedPrefix() {
        var document = TOMLDocument(text: "[p.m]\na = 1\n\n[p.mx]\nb = 2\n")
        document.removeTable("p.m")
        #expect(document.hasTable("p.mx"))
        #expect(!document.hasTable("p.m"))
    }

    @Test func quotingRoundTrips() {
        for value in ["plain", "with \"quote\"", "back\\slash", "/a b/c.key", "模型 · 名称"] {
            #expect(TOMLDocument.parseString(TOMLDocument.quote(value)) == value)
        }
    }
}
