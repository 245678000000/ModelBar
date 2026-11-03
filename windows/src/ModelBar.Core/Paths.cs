namespace ModelBar.Core;

/// <summary>所有文件路径的唯一来源。把 home 指向临时目录即可完全隔离真实配置。</summary>
public sealed class AppPaths
{
    private readonly IReadOnlyDictionary<string, string> _environment;

    public string Home { get; }
    public bool IsSandboxed { get; }
    public string Support { get; }

    public AppPaths(string home, bool isSandboxed = true, IReadOnlyDictionary<string, string>? environment = null)
    {
        Home = home;
        IsSandboxed = isSandboxed;
        _environment = environment ?? new Dictionary<string, string>();
        var roaming = !isSandboxed && _environment.TryGetValue("APPDATA", out var appData) && appData.Length > 0
            ? appData
            : Path.Combine(home, "AppData", "Roaming");
        Support = Path.Combine(roaming, "ModelBar");
    }

    public static AppPaths Current()
    {
        var environment = ReadEnvironment();
        return environment.TryGetValue("MODELBAR_HOME", out var sandbox) && sandbox.Length > 0
            ? new AppPaths(sandbox, true, environment)
            : new AppPaths(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), false, environment);
    }

    /// <summary>不区分大小写。类 Unix 系统上可能同时有 no_proxy 和 NO_PROXY，后读到的覆盖先读到的。</summary>
    public static Dictionary<string, string> ReadEnvironment()
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
        {
            result[(string)entry.Key] = (string?)entry.Value ?? "";
        }
        return result;
    }

    public string StateFile => Path.Combine(Support, "state.json");
    public string KeysDirectory => Path.Combine(Support, "keys");
    public string BackupsDirectory => Path.Combine(Support, "backups");
    public string LogsDirectory => Path.Combine(Support, "logs");
    public string SandboxKeysDirectory => Path.Combine(Support, "sandbox-keys");
    public string KeyFile(Guid id) => Path.Combine(KeysDirectory, $"{id:D}.key");

    public string BridgeConfig => Path.Combine(Support, "bridge.json");
    public string BridgeToken => Path.Combine(KeysDirectory, "bridge.token");
    public string BridgeLog => Path.Combine(LogsDirectory, "bridge.log");
    public string BridgePidFile => Path.Combine(Support, "bridge.pid");
    public string InstalledGateway => Path.Combine(Support, "bin", OperatingSystem.IsWindows() ? "ModelBarGateway.exe" : "ModelBarGateway");

    public string OpenCodeDirectory => Path.Combine(Home, ".config", "opencode");
    public string KiloDirectory => Path.Combine(Home, ".config", "kilo");
    public string CodexDirectory => Path.Combine(Home, ".codex");
    public string CodexConfig => Path.Combine(CodexDirectory, "config.toml");
    public string ClaudeSettings => Path.Combine(Home, ".claude", "settings.json");
    public string PiDirectory => Path.Combine(Home, ".pi", "agent");
    public string GrokConfig => Path.Combine(Home, ".grok", "config.toml");
    public string DroidSettings => Path.Combine(Home, ".factory", "settings.json");

    public IEnumerable<string> ExtensionRoots =>
    [
        Path.Combine(Home, ".cursor", "extensions"),
        Path.Combine(Home, ".vscode", "extensions"),
    ];

    /// <summary>优先使用已存在的配置文件，避免新建一个优先级不明确的文件。</summary>
    public static string JsonConfig(string directory, string baseName)
    {
        var jsonc = Path.Combine(directory, baseName + ".jsonc");
        var json = Path.Combine(directory, baseName + ".json");
        return File.Exists(jsonc) ? jsonc : json;
    }

    public string? FindBinary(string name)
    {
        var directories = new List<string>
        {
            Path.Combine(Home, ".opencode", "bin"),
            Path.Combine(Home, ".grok", "bin"),
            Path.Combine(Home, ".local", "bin"),
            Path.Combine(Home, ".npm-global", "bin"),
            Path.Combine(Home, ".npm-global"),
            Path.Combine(Home, ".bun", "bin"),
            Path.Combine(Home, ".cargo", "bin"),
        };
        if (_environment.TryGetValue("APPDATA", out var appData) && appData.Length > 0 && !IsSandboxed)
            directories.Add(Path.Combine(appData, "npm"));
        // 隔离运行时默认不查 PATH，否则会把真实安装的工具当成隔离目录里的。自动测试可以显式打开。
        if ((!IsSandboxed || _environment.ContainsKey("MODELBAR_SANDBOX_USE_PATH")) && _environment.TryGetValue("PATH", out var path))
            directories.AddRange(path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));

        string[] suffixes = OperatingSystem.IsWindows() ? [".exe", ".cmd", ".bat"] : [""];
        foreach (var directory in directories)
        {
            foreach (var suffix in suffixes)
            {
                var candidate = Path.Combine(directory, name + suffix);
                if (File.Exists(candidate)) return candidate;
            }
        }
        return null;
    }
}
