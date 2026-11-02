import Foundation

/// 按行编辑 TOML，只改目标键，其余内容（注释、顺序、格式）原样保留。
public struct TOMLDocument {
    private enum Kind: Equatable {
        case blank
        case comment
        case header(String)
        case keyValue(String)
        case continuation
    }

    private struct Line {
        var kind: Kind
        var table: String?
    }

    public private(set) var lines: [String]
    private let hadTrailingNewline: Bool

    public init(text: String) {
        hadTrailingNewline = text.isEmpty || text.hasSuffix("\n")
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        lines = parts
    }

    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
    }

    // MARK: 读取

    public func rawValue(forKey key: String, inTable table: String? = nil) -> String? {
        guard let range = keyRange(key, table: table) else { return nil }
        let joined = lines[range].joined(separator: "\n")
        guard let equals = joined.firstIndex(of: "=") else { return nil }
        return Self.stripTrailingComment(String(joined[joined.index(after: equals)...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func string(forKey key: String, inTable table: String? = nil) -> String? {
        rawValue(forKey: key, inTable: table).flatMap(Self.parseString)
    }

    public func hasTable(_ name: String) -> Bool {
        scan().contains { $0.kind == .header(name) }
    }

    // MARK: 修改

    /// `rawValue` 为 nil 时删除该键。
    public mutating func setTopLevel(_ key: String, rawValue: String?) {
        if let range = keyRange(key, table: nil) {
            if let rawValue {
                lines.replaceSubrange(range, with: ["\(key) = \(rawValue)"])
            } else {
                lines.removeSubrange(range)
            }
            return
        }
        guard let rawValue else { return }
        lines.insert("\(key) = \(rawValue)", at: topLevelInsertionIndex())
    }

    /// 删除 `[name]` 和所有 `[name.*]` 表，以及紧贴在前面的 `marker` 注释。
    public mutating func removeTable(_ name: String, marker: String? = nil) {
        while let start = firstTableIndex(matching: name) {
            let info = scan()
            var end = lines.count
            for index in (start + 1)..<max(start + 1, lines.count) where isHeader(info[index].kind) {
                end = index
                break
            }
            // 下一个表头上方紧贴的注释属于下一个表。
            if end < lines.count {
                while end - 1 > start, info[end - 1].kind == .comment { end -= 1 }
            }
            var lower = start
            if let marker, lower > 0, lines[lower - 1].trimmingCharacters(in: .whitespaces) == marker {
                lower -= 1
            }
            lines.removeSubrange(lower..<end)
            // 删除时一并去掉块前的空行，避免反复启停累积空行。
            if lower > 0, lower <= lines.count, lines[lower - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                let followedByContent = lower < lines.count
                    && !lines[lower].trimmingCharacters(in: .whitespaces).isEmpty
                if !followedByContent {
                    lines.remove(at: lower - 1)
                }
            }
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 {
            let previous = lines[lines.count - 2].trimmingCharacters(in: .whitespaces)
            guard previous.isEmpty else { break }
            lines.removeLast()
            _ = last
        }
    }

    public mutating func appendBlock(_ block: [String]) {
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("")
        }
        lines.append(contentsOf: block)
    }

    // MARK: 值编码

    public static func quote(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    public static func parseString(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2, let first = value.first, first == value.last else { return nil }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner }
        guard first == "\"" else { return nil }
        var result = ""
        var iterator = inner.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "\"": result.append("\"")
            case "\\": result.append("\\")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }

    // MARK: 扫描

    private func isHeader(_ kind: Kind) -> Bool {
        if case .header = kind { return true }
        return false
    }

    private func firstTableIndex(matching name: String) -> Int? {
        for (index, line) in scan().enumerated() {
            if case .header(let header) = line.kind, header == name || header.hasPrefix(name + ".") {
                return index
            }
        }
        return nil
    }

    private func keyRange(_ key: String, table: String?) -> Range<Int>? {
        let info = scan()
        for (index, line) in info.enumerated() where line.kind == .keyValue(key) && line.table == table {
            var end = index + 1
            while end < info.count, info[end].kind == .continuation { end += 1 }
            return index..<end
        }
        return nil
    }

    private func topLevelInsertionIndex() -> Int {
        let info = scan()
        var lastTopLevelEnd: Int?
        var firstHeader: Int?
        for (index, line) in info.enumerated() {
            if isHeader(line.kind) {
                firstHeader = index
                break
            }
            if case .keyValue = line.kind { lastTopLevelEnd = index + 1 }
            if line.kind == .continuation { lastTopLevelEnd = index + 1 }
        }
        if let lastTopLevelEnd { return lastTopLevelEnd }
        guard var index = firstHeader else { return lines.count }
        while index > 0, info[index - 1].kind == .comment { index -= 1 }
        return index
    }

    private func scan() -> [Line] {
        var result: [Line] = []
        result.reserveCapacity(lines.count)
        var state = ValueState()
        var table: String?
        for line in lines {
            if state.isOpen {
                state.consume(line[...])
                result.append(Line(kind: .continuation, table: table))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(Line(kind: .blank, table: table))
            } else if trimmed.hasPrefix("#") {
                result.append(Line(kind: .comment, table: table))
            } else if trimmed.hasPrefix("[") {
                let name = Self.headerName(trimmed)
                table = name
                result.append(Line(kind: .header(name), table: name))
            } else if let equals = Self.firstEquals(in: line) {
                let key = Self.unquoteKey(String(line[..<equals]).trimmingCharacters(in: .whitespaces))
                state.consume(line[line.index(after: equals)...])
                result.append(Line(kind: .keyValue(key), table: table))
            } else {
                result.append(Line(kind: .continuation, table: table))
            }
        }
        return result
    }

    private static func headerName(_ trimmed: String) -> String {
        var value = stripTrailingComment(trimmed).trimmingCharacters(in: .whitespaces)
        while value.hasPrefix("[") { value.removeFirst() }
        while value.hasSuffix("]") { value.removeLast() }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoteKey(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == key.last, first == "\"" || first == "'" else {
            return key
        }
        return String(key.dropFirst().dropLast())
    }

    private static func firstEquals(in line: String) -> String.Index? {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "=" {
                return index
            }
        }
        return nil
    }

    private static func stripTrailingComment(_ value: String) -> String {
        var quote: Character?
        var escaped = false
        for index in value.indices {
            let character = value[index]
            if let open = quote {
                if escaped {
                    escaped = false
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(value[..<index])
            }
        }
        return value
    }

    /// 跟踪多行数组、内联表和多行字符串，判断一个值是否延续到下一行。
    private struct ValueState {
        private var depth = 0
        private var multiline: String?

        var isOpen: Bool { depth > 0 || multiline != nil }

        mutating func consume(_ text: Substring) {
            var rest = text
            while !rest.isEmpty {
                if let delimiter = multiline {
                    guard let range = rest.range(of: delimiter) else { return }
                    rest = rest[range.upperBound...]
                    multiline = nil
                    continue
                }
                if rest.hasPrefix("\"\"\"") || rest.hasPrefix("'''") {
                    multiline = String(rest.prefix(3))
                    rest = rest.dropFirst(3)
                    continue
                }
                let character = rest.removeFirst()
                switch character {
                case "#":
                    return
                case "[", "{":
                    depth += 1
                case "]", "}":
                    depth = max(0, depth - 1)
                case "\"":
                    var escaped = false
                    while !rest.isEmpty {
                        let inner = rest.removeFirst()
                        if escaped { escaped = false; continue }
                        if inner == "\\" { escaped = true; continue }
                        if inner == "\"" { break }
                    }
                case "'":
                    while !rest.isEmpty, rest.removeFirst() != "'" {}
                default:
                    break
                }
            }
        }
    }
}
