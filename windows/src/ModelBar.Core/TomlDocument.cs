using System.Text;

namespace ModelBar.Core;

/// <summary>按行编辑 TOML，只改目标键，其余内容（注释、顺序、格式）原样保留。</summary>
public sealed class TomlDocument
{
    private enum Kind { Blank, Comment, Header, KeyValue, Continuation }

    private readonly record struct Line(Kind Kind, string? Name, string? Table);

    private readonly List<string> _lines;
    private readonly bool _hadTrailingNewline;
    private readonly string _newline;

    public TomlDocument(string text)
    {
        _hadTrailingNewline = text.Length == 0 || text.EndsWith('\n');
        // Windows 工具常写 CRLF，统一处理后再按原样写回。
        _newline = text.Contains("\r\n") ? "\r\n" : "\n";
        var parts = text.Replace("\r\n", "\n").Split('\n').ToList();
        if (parts.Count > 0 && parts[^1].Length == 0) parts.RemoveAt(parts.Count - 1);
        _lines = parts;
    }

    public string Text => _lines.Count == 0 ? "" : string.Join(_newline, _lines) + (_hadTrailingNewline ? _newline : "");

    // 读取

    public string? RawValue(string key, string? table = null)
    {
        var range = KeyRange(key, table);
        if (range is not var (start, end)) return null;
        var joined = string.Join("\n", _lines.Skip(start).Take(end - start));
        var equals = joined.IndexOf('=');
        return equals < 0 ? null : StripTrailingComment(joined[(equals + 1)..]).Trim();
    }

    public string? GetString(string key, string? table = null) => RawValue(key, table) is { } raw ? ParseString(raw) : null;

    public bool HasTable(string name) => Scan().Any(line => line.Kind == Kind.Header && line.Name == name);

    // 修改

    /// <summary>rawValue 为 null 时删除该键。</summary>
    public void SetTopLevel(string key, string? rawValue)
    {
        if (KeyRange(key, null) is var (start, end))
        {
            _lines.RemoveRange(start, end - start);
            if (rawValue is not null) _lines.Insert(start, $"{key} = {rawValue}");
            return;
        }
        if (rawValue is not null) _lines.Insert(TopLevelInsertionIndex(), $"{key} = {rawValue}");
    }

    /// <summary>改表里的键。rawValue 为 null 时删除该键，表因此变空时连表头一起删除。</summary>
    public void Set(string key, string? rawValue, string table)
    {
        if (KeyRange(key, table) is var (start, end))
        {
            _lines.RemoveRange(start, end - start);
            if (rawValue is not null) _lines.Insert(start, $"{key} = {rawValue}");
            else RemoveTableIfEmpty(table);
            return;
        }
        if (rawValue is null) return;
        var info = Scan();
        var header = info.FindIndex(line => line.Kind == Kind.Header && line.Name == table);
        if (header < 0)
        {
            AppendBlock([$"[{table}]", $"{key} = {rawValue}"]);
            return;
        }
        var insertion = header + 1;
        for (var index = header + 1; index < info.Count && info[index].Kind != Kind.Header; index++)
        {
            if (info[index].Kind is Kind.KeyValue or Kind.Continuation) insertion = index + 1;
        }
        _lines.Insert(insertion, $"{key} = {rawValue}");
    }

    /// <summary>删除 [name] 和所有 [name.*] 表，以及紧贴在前面的 marker 注释。</summary>
    public void RemoveTable(string name, string? marker = null)
    {
        while (true)
        {
            var info = Scan();
            var start = info.FindIndex(line => line.Kind == Kind.Header && (line.Name == name || line.Name!.StartsWith(name + ".", StringComparison.Ordinal)));
            if (start < 0) break;

            var end = _lines.Count;
            for (var index = start + 1; index < info.Count; index++)
            {
                if (info[index].Kind == Kind.Header)
                {
                    end = index;
                    break;
                }
            }
            // 下一个表头上方紧贴的注释属于下一个表。
            if (end < _lines.Count)
            {
                while (end - 1 > start && info[end - 1].Kind == Kind.Comment) end--;
            }
            var lower = start;
            if (marker is not null && lower > 0 && _lines[lower - 1].Trim() == marker) lower--;
            _lines.RemoveRange(lower, end - lower);

            // 删除时一并去掉块前的空行，避免反复启停累积空行。
            if (lower > 0 && lower <= _lines.Count && _lines[lower - 1].Trim().Length == 0)
            {
                var followedByContent = lower < _lines.Count && _lines[lower].Trim().Length > 0;
                if (!followedByContent) _lines.RemoveAt(lower - 1);
            }
        }
        while (_lines.Count > 1 && _lines[^1].Trim().Length == 0 && _lines[^2].Trim().Length == 0)
        {
            _lines.RemoveAt(_lines.Count - 1);
        }
    }

    public void AppendBlock(IEnumerable<string> block)
    {
        if (_lines.Count > 0 && _lines[^1].Trim().Length > 0) _lines.Add("");
        _lines.AddRange(block);
    }

    private void RemoveTableIfEmpty(string table)
    {
        var info = Scan();
        var header = info.FindIndex(line => line.Kind == Kind.Header && line.Name == table);
        if (header < 0) return;
        var end = header + 1;
        while (end < info.Count && info[end].Kind != Kind.Header)
        {
            if (info[end].Kind != Kind.Blank) return;
            end++;
        }
        _lines.RemoveRange(header, end - header);
        while (_lines.Count > 0 && _lines[^1].Trim().Length == 0) _lines.RemoveAt(_lines.Count - 1);
    }

    // 值编码

    public static string Quote(string value)
    {
        var result = new StringBuilder("\"");
        foreach (var character in value)
        {
            switch (character)
            {
                case '"': result.Append("\\\""); break;
                case '\\': result.Append("\\\\"); break;
                case '\n': result.Append("\\n"); break;
                case '\r': result.Append("\\r"); break;
                case '\t': result.Append("\\t"); break;
                default:
                    if (character < 0x20 || character == 0x7F) result.Append($"\\u{(int)character:X4}");
                    else result.Append(character);
                    break;
            }
        }
        return result.Append('"').ToString();
    }

    public static string? ParseString(string raw)
    {
        var value = raw.Trim();
        if (value.Length < 2 || value[0] != value[^1]) return null;
        var inner = value[1..^1];
        if (value[0] == '\'') return inner;
        if (value[0] != '"') return null;
        var result = new StringBuilder();
        for (var index = 0; index < inner.Length; index++)
        {
            var character = inner[index];
            if (character != '\\' || index + 1 >= inner.Length)
            {
                result.Append(character);
                continue;
            }
            var next = inner[++index];
            result.Append(next switch
            {
                'n' => "\n",
                't' => "\t",
                'r' => "\r",
                '"' => "\"",
                '\\' => "\\",
                _ => "\\" + next,
            });
        }
        return result.ToString();
    }

    // 扫描

    private (int Start, int End)? KeyRange(string key, string? table)
    {
        var info = Scan();
        for (var index = 0; index < info.Count; index++)
        {
            if (info[index].Kind != Kind.KeyValue || info[index].Name != key || info[index].Table != table) continue;
            var end = index + 1;
            while (end < info.Count && info[end].Kind == Kind.Continuation) end++;
            return (index, end);
        }
        return null;
    }

    private int TopLevelInsertionIndex()
    {
        var info = Scan();
        int? lastTopLevelEnd = null;
        int? firstHeader = null;
        for (var index = 0; index < info.Count; index++)
        {
            if (info[index].Kind == Kind.Header)
            {
                firstHeader = index;
                break;
            }
            if (info[index].Kind is Kind.KeyValue or Kind.Continuation) lastTopLevelEnd = index + 1;
        }
        if (lastTopLevelEnd is { } end) return end;
        if (firstHeader is not { } position) return _lines.Count;
        while (position > 0 && info[position - 1].Kind == Kind.Comment) position--;
        return position;
    }

    private List<Line> Scan()
    {
        var result = new List<Line>(_lines.Count);
        var state = new ValueState();
        string? table = null;
        foreach (var line in _lines)
        {
            if (state.IsOpen)
            {
                state.Consume(line);
                result.Add(new Line(Kind.Continuation, null, table));
                continue;
            }
            var trimmed = line.Trim();
            if (trimmed.Length == 0)
            {
                result.Add(new Line(Kind.Blank, null, table));
            }
            else if (trimmed[0] == '#')
            {
                result.Add(new Line(Kind.Comment, null, table));
            }
            else if (trimmed[0] == '[')
            {
                table = HeaderName(trimmed);
                result.Add(new Line(Kind.Header, table, table));
            }
            else
            {
                var equals = FirstEquals(line);
                if (equals >= 0)
                {
                    state.Consume(line[(equals + 1)..]);
                    result.Add(new Line(Kind.KeyValue, UnquoteKey(line[..equals].Trim()), table));
                }
                else
                {
                    result.Add(new Line(Kind.Continuation, null, table));
                }
            }
        }
        return result;
    }

    private static string HeaderName(string trimmed) => StripTrailingComment(trimmed).Trim().Trim('[', ']').Trim();

    private static string UnquoteKey(string key) =>
        key.Length >= 2 && key[0] == key[^1] && key[0] is '"' or '\'' ? key[1..^1] : key;

    private static int FirstEquals(string line)
    {
        char? quote = null;
        for (var index = 0; index < line.Length; index++)
        {
            var character = line[index];
            if (quote is not null)
            {
                if (character == quote) quote = null;
            }
            else if (character is '"' or '\'')
            {
                quote = character;
            }
            else if (character == '=')
            {
                return index;
            }
        }
        return -1;
    }

    private static string StripTrailingComment(string value)
    {
        char? quote = null;
        var escaped = false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (quote is not null)
            {
                if (escaped) escaped = false;
                else if (character == '\\' && quote == '"') escaped = true;
                else if (character == quote) quote = null;
            }
            else if (character is '"' or '\'')
            {
                quote = character;
            }
            else if (character == '#')
            {
                return value[..index];
            }
        }
        return value;
    }

    /// <summary>跟踪多行数组、内联表和多行字符串，判断一个值是否延续到下一行。</summary>
    private sealed class ValueState
    {
        private int _depth;
        private string? _multiline;

        public bool IsOpen => _depth > 0 || _multiline is not null;

        public void Consume(string text)
        {
            var index = 0;
            while (index < text.Length)
            {
                if (_multiline is not null)
                {
                    var close = text.IndexOf(_multiline, index, StringComparison.Ordinal);
                    if (close < 0) return;
                    index = close + 3;
                    _multiline = null;
                    continue;
                }
                if (string.CompareOrdinal(text, index, "\"\"\"", 0, 3) == 0 || string.CompareOrdinal(text, index, "'''", 0, 3) == 0)
                {
                    _multiline = text.Substring(index, 3);
                    index += 3;
                    continue;
                }
                var character = text[index++];
                switch (character)
                {
                    case '#':
                        return;
                    case '[' or '{':
                        _depth++;
                        break;
                    case ']' or '}':
                        _depth = Math.Max(0, _depth - 1);
                        break;
                    case '"':
                        var escaped = false;
                        while (index < text.Length)
                        {
                            var inner = text[index++];
                            if (escaped) escaped = false;
                            else if (inner == '\\') escaped = true;
                            else if (inner == '"') break;
                        }
                        break;
                    case '\'':
                        while (index < text.Length && text[index++] != '\'') { }
                        break;
                }
            }
        }
    }
}
