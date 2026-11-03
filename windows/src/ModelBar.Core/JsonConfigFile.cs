using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ModelBar.Core;

/// <summary>读写 JSON 配置：解析失败时绝不覆盖，写入前先备份。</summary>
public static class JsonConfigFile
{
    private static readonly JsonDocumentOptions ReadOptions = new()
    {
        CommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
    };

    public static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static JsonObject Load(string file)
    {
        if (!File.Exists(file)) return [];
        // ReadAllText 会处理 Windows 工具写入的 BOM。
        var text = File.ReadAllText(file);
        if (string.IsNullOrWhiteSpace(text)) return [];
        try
        {
            return JsonNode.Parse(text, documentOptions: ReadOptions) as JsonObject
                ?? throw new ConfigException($"{Path.GetFileName(file)} 无法解析，未作任何修改");
        }
        catch (JsonException)
        {
            throw new ConfigException($"{Path.GetFileName(file)} 无法解析，未作任何修改");
        }
    }

    public static void Save(JsonObject root, string file, BackupStore backups, string label)
    {
        backups.Backup(file, label);
        FileSupport.WriteAtomically(file, Encoding.UTF8.GetBytes(root.ToJsonString(WriteOptions) + "\n"));
    }
}

public static class JsonExtensions
{
    public static string? Str(this JsonObject? obj, string key) =>
        obj?[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;

    public static JsonObject? Obj(this JsonObject? obj, string key) => obj?[key] as JsonObject;

    public static JsonArray? Arr(this JsonObject? obj, string key) => obj?[key] as JsonArray;

    public static int? Int(this JsonObject? obj, string key)
    {
        if (obj?[key] is not JsonValue value) return null;
        if (value.TryGetValue<int>(out var number)) return number;
        if (value.TryGetValue<double>(out var real)) return (int)real;
        return value.TryGetValue<string>(out var text) && int.TryParse(text, out var parsed) ? parsed : null;
    }

    public static bool? Bool(this JsonObject? obj, string key) =>
        obj?[key] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;

    public static IEnumerable<JsonObject> Objects(this JsonArray? array) => array?.OfType<JsonObject>() ?? [];
}
