using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace ModelBar.Core;

public static class BridgeInfo
{
    /// <summary>转换服务和应用的协议版本。应用更新后如果版本不同，会重启服务。</summary>
    public const int Version = 1;
    public const int DefaultPort = 47631;
    public const int SandboxPort = 48631;
    public const int PortSearchRange = 20;
}

/// <summary>转换服务启动时和每次请求时读取，切换接口不需要重启服务。</summary>
public sealed record BridgeConfig(int Port, string TokenFile, string UpstreamBaseUrl, string? UpstreamKeyFile, string? DefaultEffort = null)
{
    public static BridgeConfig Load(string file)
    {
        var root = JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? throw new ConfigException("转换服务配置无效");
        return new BridgeConfig(
            root.Int("port") ?? BridgeInfo.DefaultPort,
            root.Str("tokenFile") ?? "",
            root.Str("upstreamBaseURL") ?? "",
            root.Str("upstreamKeyFile"),
            root.Str("defaultEffort"));
    }

    public byte[] Encode() => Encoding.UTF8.GetBytes(new JsonObject
    {
        ["port"] = Port,
        ["tokenFile"] = TokenFile,
        ["upstreamBaseURL"] = UpstreamBaseUrl,
        ["upstreamKeyFile"] = UpstreamKeyFile,
        ["defaultEffort"] = DefaultEffort,
    }.ToJsonString(JsonConfigFile.WriteOptions));
}

public interface IBridgeServiceControl
{
    void Install(string executable, string configFile, string logFile);
    void Restart();
    void Uninstall();
}

/// <summary>
/// 启动带守护进程的转换服务：崩溃后自动拉起，登录时由注册表启动项拉起，不需要管理员权限。
/// ModelBar 退出后服务继续运行。
/// </summary>
public sealed class DetachedProcessControl(AppPaths paths) : IBridgeServiceControl
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "ModelBarBridge";
    private string? _executable;
    private string? _configFile;
    private string? _logFile;

    public void Install(string executable, string configFile, string logFile)
    {
        (_executable, _configFile, _logFile) = (executable, configFile, logFile);
        SetAutostart($"\"{executable}\" --supervise --config \"{configFile}\" --log \"{logFile}\"");
        if (RunningProcess() is not null) return;
        Start();
    }

    public void Restart()
    {
        Stop();
        Start();
    }

    public void Uninstall()
    {
        Stop();
        SetAutostart(null);
        File.Delete(paths.BridgePidFile);
    }

    private void Start()
    {
        if (_executable is null) throw new ConfigException("转换服务还没有安装");
        Directory.CreateDirectory(Path.GetDirectoryName(_logFile!)!);
        // 重定向输出，服务才不会继承并一直占着启动者的控制台。它的日志写在文件里。
        var start = new ProcessStartInfo(_executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var argument in new[] { "--supervise", "--config", _configFile!, "--log", _logFile! }) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new ConfigException("无法启动本机转换服务");
        File.WriteAllText(paths.BridgePidFile, process.Id.ToString());
    }

    private void Stop()
    {
        if (RunningProcess() is not { } process) return;
        using (process)
        {
            try
            {
                process.Kill(entireProcessTree: true);
                process.WaitForExit(5_000);
            }
            catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
            {
            }
        }
    }

    private Process? RunningProcess()
    {
        if (!File.Exists(paths.BridgePidFile) || !int.TryParse(File.ReadAllText(paths.BridgePidFile), out var pid)) return null;
        try
        {
            var process = Process.GetProcessById(pid);
            // pid 可能已经被别的程序复用。
            if (!process.HasExited && process.ProcessName.Contains("ModelBarGateway", StringComparison.OrdinalIgnoreCase)) return process;
            process.Dispose();
        }
        catch (ArgumentException)
        {
        }
        return null;
    }

    private void SetAutostart(string? command)
    {
        if (!OperatingSystem.IsWindows() || paths.IsSandboxed) return;
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (command is null) key.DeleteValue(RunValue, throwOnMissingValue: false);
        else key.SetValue(RunValue, command);
    }
}

public sealed class BridgeManager
{
    private readonly AppPaths _paths;
    private readonly string? _sourceExecutable;
    private readonly IBridgeServiceControl _control;
    private readonly Func<int, int?> _health;
    private readonly Func<int, bool> _isPortFree;

    /// <param name="sourceExecutable">随应用分发的转换程序。为 null 时不复制，直接用已安装的那份。</param>
    public BridgeManager(
        AppPaths paths,
        string? sourceExecutable,
        IBridgeServiceControl? control = null,
        Func<int, int?>? health = null,
        Func<int, bool>? isPortFree = null)
    {
        _paths = paths;
        _sourceExecutable = sourceExecutable;
        _control = control ?? new DetachedProcessControl(paths);
        _health = health ?? LiveHealth;
        _isPortFree = isPortFree ?? CanBind;
    }

    public string Executable => _paths.InstalledGateway;

    /// <summary>
    /// 把转换程序复制到固定位置。工具配置里写的是这个路径，解压目录移动后也不会失效。
    /// Windows 不能覆盖运行中的程序，所以需要时先停掉服务。
    /// </summary>
    public void EnsureInstalled()
    {
        if (_sourceExecutable is null || !File.Exists(_sourceExecutable)) return;
        var target = _paths.InstalledGateway;
        var source = new FileInfo(_sourceExecutable);
        var current = new FileInfo(target);
        if (current.Exists && current.Length == source.Length && current.LastWriteTimeUtc == source.LastWriteTimeUtc) return;

        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        var wasRunning = File.Exists(_paths.BridgeConfig) && _health(BridgeConfig.Load(_paths.BridgeConfig).Port) is not null;
        if (wasRunning) _control.Uninstall();
        File.Copy(_sourceExecutable, target, overwrite: true);
        File.SetLastWriteTimeUtc(target, source.LastWriteTimeUtc);
    }

    /// <summary>写好配置并确保服务在运行。重复调用是安全的。</summary>
    public BridgeTarget Prepare(Endpoint endpoint, string? keyFile)
    {
        EnsureInstalled();
        if (!File.Exists(Executable)) throw new ConfigException("找不到本机转换程序，请重新安装 ModelBar");
        var token = EnsureToken();
        BridgeConfig? previous = null;
        try
        {
            if (File.Exists(_paths.BridgeConfig)) previous = BridgeConfig.Load(_paths.BridgeConfig);
        }
        catch (Exception error) when (error is ConfigException or IOException or System.Text.Json.JsonException)
        {
        }
        var port = ChoosePort(previous);
        var config = new BridgeConfig(port, token, endpoint.BaseUrl, keyFile, endpoint.Effort.WireValue());
        if (config != previous) FileSupport.WritePrivate(_paths.BridgeConfig, config.Encode());

        _control.Install(Executable, _paths.BridgeConfig, _paths.BridgeLog);
        if (previous is not null && previous.Port != port) _control.Restart();

        var version = WaitForService(port);
        if (version != BridgeInfo.Version)
        {
            // 应用更新后服务还是旧版本，或者服务没有响应。
            _control.Restart();
            version = WaitForService(port);
        }
        if (version != BridgeInfo.Version) throw new ConfigException("本机转换服务没有响应，可以在“工具同步”里查看日志");
        return new BridgeTarget($"http://127.0.0.1:{port}/v1", token);
    }

    public BridgeTarget? Target()
    {
        if (!File.Exists(_paths.BridgeConfig)) return null;
        var config = BridgeConfig.Load(_paths.BridgeConfig);
        return new BridgeTarget($"http://127.0.0.1:{config.Port}/v1", config.TokenFile);
    }

    public bool IsHealthy() =>
        File.Exists(_paths.BridgeConfig) && _health(BridgeConfig.Load(_paths.BridgeConfig).Port) == BridgeInfo.Version;

    public void Stop()
    {
        if (!File.Exists(_paths.BridgeConfig) && !File.Exists(_paths.BridgePidFile)) return;
        _control.Uninstall();
        File.Delete(_paths.BridgeConfig);
        File.Delete(_paths.BridgeToken);
    }

    private int? WaitForService(int port)
    {
        for (var attempt = 0; attempt < 25; attempt++)
        {
            if (_health(port) is { } version) return version;
            if (attempt < 24) Thread.Sleep(200);
        }
        return null;
    }

    private int ChoosePort(BridgeConfig? previous)
    {
        if (previous is not null && (_health(previous.Port) is not null || _isPortFree(previous.Port))) return previous.Port;
        // 隔离运行用另一段端口，避免占用真实服务可能要用的端口。
        var first = _paths.IsSandboxed ? BridgeInfo.SandboxPort : BridgeInfo.DefaultPort;
        for (var offset = 0; offset < BridgeInfo.PortSearchRange; offset++)
        {
            if (_isPortFree(first + offset)) return first + offset;
        }
        throw new ConfigException("找不到可用的本机端口");
    }

    private string EnsureToken()
    {
        var file = _paths.BridgeToken;
        if (File.Exists(file) && new FileInfo(file).Length > 0) return file;
        var token = "mb-" + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32));
        FileSupport.WritePrivate(file, Encoding.UTF8.GetBytes(token));
        return file;
    }

    public static int? LiveHealth(int port)
    {
        try
        {
            using var handler = new SocketsHttpHandler { UseProxy = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(1.5) };
            var text = client.GetStringAsync($"http://127.0.0.1:{port}/health").GetAwaiter().GetResult();
            return (JsonNode.Parse(text) as JsonObject).Int("version");
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            return null;
        }
    }

    public static bool CanBind(int port)
    {
        try
        {
            var listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            listener.Stop();
            return true;
        }
        catch (SocketException)
        {
            return false;
        }
    }
}
