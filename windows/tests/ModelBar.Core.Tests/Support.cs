using System.Text.Json.Nodes;

namespace ModelBar.Core.Tests;

internal static class Support
{
    public static AppPaths MakeHome()
    {
        var path = Path.Combine(Path.GetTempPath(), $"modelbar tests {Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return new AppPaths(path);
    }

    public static void Write(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, text);
    }

    public static JsonObject Read(string path) => (JsonObject)JsonNode.Parse(File.ReadAllText(path))!;

    public static JsonObject Json(string text) => (JsonObject)JsonNode.Parse(text)!;

    public static void InstallBinary(AppPaths paths, params string[] names)
    {
        foreach (var name in names)
        {
            var file = Path.Combine(paths.Home, ".local", "bin", name + (OperatingSystem.IsWindows() ? ".exe" : ""));
            Write(file, "");
        }
    }

    public static SyncContext Context(AppPaths paths, ReasoningEffort effort = ReasoningEffort.High, ProbeResult? probe = null, BridgeTarget? bridge = null)
    {
        var endpoint = new Endpoint
        {
            Name = "Test \"API\"",
            BaseUrl = "https://api.example.com/v1",
            Models =
            [
                new ModelInfo { Id = "m1", ContextLength = 64_000, MaxOutputTokens = 4_096, SupportsReasoning = true, EffortLevels = ["low", "high"] },
                new ModelInfo { Id = "m2" },
            ],
            SelectedModel = "m1",
            Effort = effort,
            Probe = probe,
        };
        var keyFile = paths.KeyFile(endpoint.Id);
        FileSupport.WritePrivate(keyFile, "sk-secret-value"u8.ToArray());
        return new SyncContext
        {
            Endpoint = endpoint,
            Model = endpoint.CurrentModel!,
            KeyFile = keyFile,
            Paths = paths,
            Backups = new BackupStore(paths.BackupsDirectory),
            Helper = new CredentialHelper(paths.InstalledGateway),
            Bridge = bridge,
        };
    }

    public static bool SameJson(JsonNode a, JsonNode b) => JsonNode.DeepEquals(a, b);
}

internal sealed class FakeControl : IBridgeServiceControl
{
    public int Installs, Restarts, Uninstalls;
    public void Install(string executable, string configFile, string logFile) => Installs++;
    public void Restart() => Restarts++;
    public void Uninstall() => Uninstalls++;
}
