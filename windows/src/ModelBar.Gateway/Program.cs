using System.Diagnostics;
using ModelBar.Core;
using ModelBar.Gateway;

string? Option(string name)
{
    var index = Array.IndexOf(args, name);
    return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
}

// 工具通过这个命令读取 Key 文件。原样输出，不带换行。
if (Option("--print-file") is { } printFile)
{
    try
    {
        using var output = Console.OpenStandardOutput();
        var bytes = File.ReadAllBytes(printFile);
        output.Write(bytes);
        return 0;
    }
    catch (Exception error) when (error is IOException or UnauthorizedAccessException)
    {
        Console.Error.WriteLine(error.Message);
        return 1;
    }
}

if (Option("--config") is not { } configFile)
{
    Console.Error.WriteLine("用法：ModelBarGateway --config <配置文件> [--log <日志文件>] [--supervise]");
    return 2;
}
var logFile = Option("--log");

// 守护模式：转换服务退出后自动拉起。没有 launchd 这样的系统服务，所以自己做。
if (args.Contains("--supervise"))
{
    while (true)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--config");
        start.ArgumentList.Add(configFile);
        if (logFile is not null)
        {
            start.ArgumentList.Add("--log");
            start.ArgumentList.Add(logFile);
        }
        using (var child = Process.Start(start)!) child.WaitForExit();
        Thread.Sleep(2_000);
    }
}

BridgeLog.Configure(logFile);
try
{
    var config = BridgeConfig.Load(configFile);
    await new BridgeServer(configFile, config.Port).RunAsync();
    return 0;
}
catch (Exception error) when (error is ConfigException or IOException or System.Net.Sockets.SocketException or System.Text.Json.JsonException)
{
    BridgeLog.Write($"无法启动：{error.Message}");
    return 1;
}
