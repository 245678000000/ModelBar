namespace ModelBar.Core;

public abstract record ToolState
{
    public sealed record NotInstalled : ToolState;
    public sealed record Disabled : ToolState;
    public sealed record NoSelection : ToolState;
    public sealed record Synced : ToolState;
    public sealed record Stale : ToolState;
    public sealed record Incompatible(string Reason) : ToolState;
    public sealed record Failed(string Reason) : ToolState;

    public string Title => this switch
    {
        NotInstalled => "未安装",
        Disabled => "未启用",
        NoSelection => "请先选择模型",
        Synced => "已同步",
        Stale => "配置被改动过",
        Incompatible => "接口不兼容",
        _ => "同步失败",
    };

    public string? Detail => this switch
    {
        Incompatible state => state.Reason,
        Failed state => state.Reason,
        _ => null,
    };
}

public sealed class SyncReport
{
    public Dictionary<ToolId, ToolState> Statuses { get; } = [];
    public Dictionary<ToolId, Dictionary<string, string>> Originals { get; } = [];
    public List<ToolId> RemovedOriginals { get; } = [];
    public List<string> Notes { get; } = [];
}

/// <summary>所有配置写入都经过这里，保证不会有两次同步同时改同一个文件。</summary>
public sealed class SyncEngine
{
    private readonly object _gate = new();
    private readonly AppPaths _paths;
    private readonly IKeyStore _keyStore;
    private readonly IReadOnlyList<IToolAdapter> _adapters;
    private readonly BackupStore _backups;
    private readonly BridgeManager _bridge;

    public SyncEngine(AppPaths paths, IKeyStore keyStore, BridgeManager bridge, IReadOnlyList<IToolAdapter>? adapters = null)
    {
        _paths = paths;
        _keyStore = keyStore;
        _bridge = bridge;
        _adapters = adapters ?? ToolCatalog.Adapters;
        _backups = new BackupStore(paths.BackupsDirectory);
    }

    /// <summary>把当前接口写入所有已启用的工具。</summary>
    public SyncReport Sync(AppState state)
    {
        lock (_gate)
        {
            var report = new SyncReport();
            var enabled = _adapters.Where(a => state.EnabledTools.Contains(a.Id)).ToList();
            if (enabled.Count == 0)
            {
                _bridge.Stop();
                RemoveKeyFiles(null);
                Merge(CurrentStatusesLocked(state), report);
                return report;
            }

            var context = MakeContext(state, report);
            if (context is null)
            {
                if (report.Statuses.Count == 0)
                {
                    foreach (var adapter in enabled) report.Statuses[adapter.Id] = new ToolState.NoSelection();
                }
                Merge(CurrentStatusesLocked(state), report);
                return report;
            }

            var keepsOldEndpoint = false;
            BridgeTarget? target = null;
            string? bridgeFailure = null;
            try
            {
                _bridge.EnsureInstalled();
                if (state.NeedsBridge) target = _bridge.Prepare(context.Endpoint, context.KeyFile);
            }
            catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException)
            {
                bridgeFailure = error.Message;
            }

            foreach (var adapter in enabled)
            {
                if (!adapter.IsInstalled(_paths))
                {
                    report.Statuses[adapter.Id] = new ToolState.NotInstalled();
                    continue;
                }
                if (adapter.Incompatibility(context.Endpoint, state.BridgeEnabled) is { } reason)
                {
                    report.Statuses[adapter.Id] = new ToolState.Incompatible(reason);
                    keepsOldEndpoint = true;
                    continue;
                }
                var toolContext = context.WithBridge(null);
                if (state.BridgeEnabled && adapter.Id.NeedsConversion(context.Endpoint.Probe))
                {
                    if (bridgeFailure is not null)
                    {
                        report.Statuses[adapter.Id] = new ToolState.Failed(bridgeFailure);
                        keepsOldEndpoint = true;
                        continue;
                    }
                    toolContext = context.WithBridge(target);
                }
                try
                {
                    if (adapter.IsApplied(toolContext))
                    {
                        report.Statuses[adapter.Id] = new ToolState.Synced();
                        continue;
                    }
                    if (adapter.Apply(toolContext) is { } originals) report.Originals[adapter.Id] = originals;
                    report.Statuses[adapter.Id] = new ToolState.Synced();
                    if (adapter.Reload(_paths) is { } note) report.Notes.Add(note);
                }
                catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException)
                {
                    report.Statuses[adapter.Id] = new ToolState.Failed(error.Message);
                    keepsOldEndpoint = true;
                }
            }

            // 没写入成功的工具还指向上一个接口，它的 Key 文件要留着，转换服务也要继续运行。
            if (!keepsOldEndpoint)
            {
                RemoveKeyFiles(context.KeyFile);
                if (!state.NeedsBridge) _bridge.Stop();
            }
            Merge(CurrentStatusesLocked(state), report);
            return report;
        }
    }

    /// <summary>停用工具并还原它原来的配置。</summary>
    public SyncReport Disable(ToolId tool, AppState state)
    {
        lock (_gate)
        {
            var report = new SyncReport();
            var adapter = _adapters.FirstOrDefault(a => a.Id == tool);
            if (adapter is null) return report;
            try
            {
                adapter.Restore(_paths, _backups, state.Originals.GetValueOrDefault(tool) ?? []);
                report.RemovedOriginals.Add(tool);
                report.Statuses[tool] = adapter.IsInstalled(_paths) ? new ToolState.Disabled() : new ToolState.NotInstalled();
                var remaining = state.Clone();
                remaining.EnabledTools.Remove(tool);
                if (!remaining.NeedsBridge) _bridge.Stop();
                if (adapter.Reload(_paths) is { } note) report.Notes.Add(note);
            }
            catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException)
            {
                report.Statuses[tool] = new ToolState.Failed(error.Message);
            }
            return report;
        }
    }

    public Dictionary<ToolId, ToolState> CurrentStatuses(AppState state)
    {
        lock (_gate) return CurrentStatusesLocked(state);
    }

    private Dictionary<ToolId, ToolState> CurrentStatusesLocked(AppState state)
    {
        var result = new Dictionary<ToolId, ToolState>();
        var context = ReadOnlyContext(state);
        foreach (var adapter in _adapters)
        {
            if (!adapter.IsInstalled(_paths))
            {
                result[adapter.Id] = new ToolState.NotInstalled();
                continue;
            }
            if (!state.EnabledTools.Contains(adapter.Id))
            {
                result[adapter.Id] = new ToolState.Disabled();
                continue;
            }
            if (context is null)
            {
                result[adapter.Id] = new ToolState.NoSelection();
                continue;
            }
            if (adapter.Incompatibility(context.Endpoint, state.BridgeEnabled) is { } reason)
            {
                result[adapter.Id] = new ToolState.Incompatible(reason);
                continue;
            }
            var toolContext = context.WithBridge(null);
            if (state.BridgeEnabled && adapter.Id.NeedsConversion(context.Endpoint.Probe))
            {
                toolContext = context.WithBridge(_bridge.Target());
                if (!_bridge.IsHealthy())
                {
                    result[adapter.Id] = new ToolState.Failed("本机转换服务没有运行，点“重新同步”可以重启");
                    continue;
                }
            }
            result[adapter.Id] = adapter.IsApplied(toolContext) ? new ToolState.Synced() : new ToolState.Stale();
        }
        return result;
    }

    private static void Merge(Dictionary<ToolId, ToolState> statuses, SyncReport report)
    {
        foreach (var (tool, status) in statuses) report.Statuses.TryAdd(tool, status);
    }

    private SyncContext? ReadOnlyContext(AppState state)
    {
        if (state.ActiveEndpoint is not { } endpoint || endpoint.CurrentModel is not { } model) return null;
        return new SyncContext { Endpoint = endpoint, Model = model, Paths = _paths, Backups = _backups, Helper = new CredentialHelper(_bridge.Executable) };
    }

    private SyncContext? MakeContext(AppState state, SyncReport report)
    {
        if (state.ActiveEndpoint is not { } endpoint || endpoint.CurrentModel is not { } model) return null;
        try
        {
            string? keyFile = null;
            var file = _paths.KeyFile(endpoint.Id);
            if (File.Exists(file) && new FileInfo(file).Length > 0)
            {
                keyFile = file;
            }
            else if (_keyStore.GetKey(endpoint.Id) is { Length: > 0 } key)
            {
                FileSupport.WritePrivate(file, System.Text.Encoding.UTF8.GetBytes(key));
                keyFile = file;
            }
            return new SyncContext { Endpoint = endpoint, Model = model, KeyFile = keyFile, Paths = _paths, Backups = _backups, Helper = new CredentialHelper(_bridge.Executable) };
        }
        catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException)
        {
            foreach (var tool in state.EnabledTools) report.Statuses[tool] = new ToolState.Failed(error.Message);
            return null;
        }
    }

    private void RemoveKeyFiles(string? keep)
    {
        if (!Directory.Exists(_paths.KeysDirectory)) return;
        foreach (var file in Directory.GetFiles(_paths.KeysDirectory, "*.key"))
        {
            if (!string.Equals(file, keep, StringComparison.OrdinalIgnoreCase)) File.Delete(file);
        }
    }
}
