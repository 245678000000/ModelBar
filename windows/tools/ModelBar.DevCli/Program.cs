using ModelBar.Core;

// 开发用：不开界面驱动控制器，用真实 Agent 验证。只操作隔离目录。
// 用法：devcli <隔离目录> <转换程序> <命令...>
if (args.Length < 3)
{
    Console.Error.WriteLine("用法：devcli <隔离目录> <转换程序> add|tool|bridge|effort|test|status ...");
    return 2;
}
var home = args[0];
var paths = new AppPaths(home, isSandboxed: true, AppPaths.ReadEnvironment());
var keys = new SandboxFileKeyStore(paths.SandboxKeysDirectory);
var controller = new AppController(paths, keys, new BridgeManager(paths, args[1]));
await controller.StartAsync();

switch (args[2])
{
    case "add":
        await controller.AddEndpointAsync(args[3], args[4], args[5]);
        break;
    case "tool":
        await controller.SetToolAsync(Enum.Parse<ToolId>(args[3]), args[4] == "on");
        break;
    case "bridge":
        await controller.SetBridgeAsync(args[3] == "on");
        break;
    case "effort":
        await controller.SetEffortAsync(controller.ActiveEndpoint!.Id, Enum.Parse<ReasoningEffort>(args[3]));
        break;
    case "test":
        await controller.TestAsync(controller.ActiveEndpoint!.Id);
        break;
    case "status":
        break;
    default:
        Console.Error.WriteLine("未知命令");
        return 2;
}
await controller.RefreshStatusesAsync();

var active = controller.ActiveEndpoint;
Console.WriteLine($"active={active?.Name} model={active?.SelectedModel} effort={active?.Effort} bridge={controller.State.BridgeEnabled} probe={active?.Probe?.Models}/{active?.Probe?.Chat}/{active?.Probe?.Responses}/{active?.Probe?.Messages}");
foreach (var tool in Enum.GetValues<ToolId>())
{
    var status = controller.Status(tool);
    Console.WriteLine($"  {tool,-11} {status.Title} {status.Detail}");
}
return 0;
