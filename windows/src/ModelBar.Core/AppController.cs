namespace ModelBar.Core;

public sealed record Notice(bool IsError, string Text);

/// <summary>界面的全部行为都在这里，不依赖任何界面框架，方便测试。</summary>
public sealed class AppController
{
    private readonly StateStore _store;
    private readonly EndpointClient _client = new();
    private int _generation;
    private CancellationTokenSource? _noticeTimer;

    public AppPaths Paths { get; }
    public IKeyStore KeyStore { get; }
    public SyncEngine Engine { get; }
    public AppState State { get; }
    public Dictionary<ToolId, ToolState> Statuses { get; private set; } = [];
    public bool IsSyncing { get; private set; }
    public HashSet<Guid> Testing { get; } = [];
    public HashSet<Guid> LoadingModels { get; } = [];
    public Notice? Notice { get; private set; }

    /// <summary>状态变化时触发，总是在创建控制器的线程上。</summary>
    public event Action? Changed;

    public AppController(AppPaths paths, IKeyStore keyStore, BridgeManager bridge)
    {
        Paths = paths;
        KeyStore = keyStore;
        Engine = new SyncEngine(paths, keyStore, bridge);
        _store = new StateStore(paths.StateFile);
        try
        {
            State = _store.Load();
        }
        catch (Exception error) when (error is System.Text.Json.JsonException or IOException)
        {
            State = new AppState();
            var kept = _store.Quarantine();
            Notice = new Notice(true, $"无法读取保存的设置，原文件已另存为 {(kept is null ? "（另存失败）" : Path.GetFileName(kept))}");
        }
    }

    /// <summary>应用更新后转换服务可能还是旧版本，同步时会自动重启它。</summary>
    public Task StartAsync() => State.NeedsBridge ? SyncAsync() : RefreshStatusesAsync();

    // 查询

    public Endpoint? ActiveEndpoint => State.ActiveEndpoint;
    public Endpoint? Find(Guid id) => State.Endpoints.FirstOrDefault(e => e.Id == id);
    public ToolState Status(ToolId tool) => Statuses.GetValueOrDefault(tool) ?? new ToolState.Disabled();
    public bool IsEnabled(ToolId tool) => State.EnabledTools.Contains(tool);
    public string ConfigPath(ToolId tool) => ToolCatalog.Adapter(tool).ConfigFile(Paths);

    public bool CanOfferBridge(ToolId tool) =>
        !State.BridgeEnabled && IsEnabled(tool) && tool.NeedsConversion(ActiveEndpoint?.Probe);

    public bool CanOfferAnyBridge => !State.BridgeEnabled && State.ToolsNeedingConversion.Count > 0;
    public bool IsBridged(ToolId tool) => State.BridgeEnabled && IsEnabled(tool) && tool.NeedsConversion(ActiveEndpoint?.Probe);
    public bool IsBridgeActive => State.NeedsBridge;

    // 切换

    public Task ActivateAsync(Guid id)
    {
        if (State.ActiveEndpointId == id) return Task.CompletedTask;
        State.ActiveEndpointId = id;
        // 没测试过的接口先确认协议，避免把不兼容的配置写给工具。
        if (Find(id) is { } endpoint && (endpoint.Models.Count == 0 || endpoint.Probe is null))
        {
            Persist();
            return TestAsync(id);
        }
        return SyncAsync();
    }

    public Task SelectModelAsync(Guid id, string model)
    {
        if (Find(id) is not { } endpoint) return Task.CompletedTask;
        endpoint.SelectedModel = model;
        if (endpoint.CurrentModel is { } current && !current.AvailableEfforts.Contains(endpoint.Effort))
            endpoint.Effort = ReasoningEffort.Automatic;
        Persist();
        return SyncIfActiveAsync(id);
    }

    public Task AddManualModelAsync(Guid id, string raw)
    {
        var model = raw.Trim();
        if (model.Length == 0 || Find(id) is not { } endpoint) return Task.CompletedTask;
        if (endpoint.Models.All(m => m.Id != model)) endpoint.Models.Insert(0, new ModelInfo { Id = model });
        endpoint.SelectedModel = model;
        Persist();
        return SyncIfActiveAsync(id);
    }

    public Task SetEffortAsync(Guid id, ReasoningEffort effort)
    {
        if (Find(id) is not { } endpoint) return Task.CompletedTask;
        endpoint.Effort = effort;
        Persist();
        return SyncIfActiveAsync(id);
    }

    public Task SetToolAsync(ToolId tool, bool enabled)
    {
        if (enabled)
        {
            if (State.EnabledTools.Contains(tool)) return Task.CompletedTask;
            State.EnabledTools.Add(tool);
            // 没有 Anthropic 测试结果时，打开 Claude Code 要补测。
            if (tool == ToolId.ClaudeCode && ActiveEndpoint is { Probe.Messages: ProbeStatus.Unknown } active)
            {
                Persist();
                return TestAsync(active.Id);
            }
            return SyncAsync();
        }
        State.EnabledTools.Remove(tool);
        Persist();
        return DisableAsync(tool);
    }

    public Task ResyncAsync() => SyncAsync();

    public async Task SetBridgeAsync(bool enabled)
    {
        if (State.BridgeEnabled == enabled) return;
        var bridged = State.ToolsNeedingConversion;
        State.BridgeEnabled = enabled;
        if (enabled)
        {
            await SyncAsync();
            return;
        }
        Persist();
        // 这些工具可能正连着转换服务，要先恢复它们原来的配置。
        foreach (var tool in bridged) await DisableAsync(tool);
    }

    // 接口管理

    public async Task<Guid> AddEndpointAsync(string name, string baseUrl, string key)
    {
        var endpoint = new Endpoint { Name = name.Trim(), BaseUrl = Endpoint.Normalize(baseUrl) };
        var trimmed = key.Trim();
        if (trimmed.Length > 0)
        {
            KeyStore.SetKey(endpoint.Id, trimmed);
            endpoint.HasKey = true;
        }
        State.Endpoints.Add(endpoint);
        State.ActiveEndpointId ??= endpoint.Id;
        Persist();
        await TestAsync(endpoint.Id);
        return endpoint.Id;
    }

    /// <summary>key 为 null 表示不修改已保存的密钥。</summary>
    public Task UpdateEndpointAsync(Guid id, string name, string baseUrl, string? key)
    {
        if (Find(id) is not { } endpoint) return Task.CompletedTask;
        var normalized = Endpoint.Normalize(baseUrl);
        var urlChanged = normalized != endpoint.BaseUrl;
        if (key is not null)
        {
            var trimmed = key.Trim();
            KeyStore.SetKey(id, trimmed);
            // 删掉旧的副本，下次同步时写入新 Key。
            File.Delete(Paths.KeyFile(id));
            endpoint.HasKey = trimmed.Length > 0;
        }
        endpoint.Name = name.Trim();
        endpoint.BaseUrl = normalized;
        Persist();
        if (urlChanged || key is not null)
        {
            endpoint.Probe = null;
            return TestAsync(id);
        }
        return SyncIfActiveAsync(id);
    }

    public async Task DeleteEndpointAsync(Guid id)
    {
        KeyStore.SetKey(id, null);
        State.Endpoints.RemoveAll(e => e.Id == id);
        if (State.ActiveEndpointId != id)
        {
            Persist();
            return;
        }
        State.ActiveEndpointId = State.Endpoints.FirstOrDefault()?.Id;
        if (State.ActiveEndpointId is not null)
        {
            await SyncAsync();
            return;
        }
        // 没有接口可用时把工具还原，避免它们继续指向已删除的接口。
        var tools = State.EnabledTools.ToList();
        State.EnabledTools.Clear();
        Persist();
        foreach (var tool in tools) await DisableAsync(tool);
    }

    public string? ReadKey(Guid id)
    {
        try
        {
            return KeyStore.GetKey(id);
        }
        catch (ConfigException error)
        {
            Show(true, error.Message);
            return null;
        }
    }

    public async Task TestAsync(Guid id)
    {
        if (Find(id) is not { } endpoint || !Testing.Add(id)) return;
        Raise();
        var key = ReadKey(id);
        var requested = endpoint.SelectedModel;
        var (result, models) = await _client.ProbeAsync(endpoint.BaseUrl, key, requested);
        Testing.Remove(id);

        if (models.Count > 0)
        {
            var manual = endpoint.Models.Where(m => m.Id == endpoint.SelectedModel && models.All(n => n.Id != m.Id)).ToList();
            endpoint.Models = [.. manual, .. models];
        }
        endpoint.Probe = result;
        endpoint.SelectedModel ??= Endpoint.DefaultModel(endpoint.Models);
        Persist();
        await SyncIfActiveAsync(id);
    }

    public async Task RefreshModelsAsync(Guid id)
    {
        if (Find(id) is not { } endpoint || !LoadingModels.Add(id)) return;
        Raise();
        try
        {
            var models = await _client.FetchModelsAsync(endpoint.BaseUrl, ReadKey(id));
            var kept = endpoint.Models.Where(m => m.Id == endpoint.SelectedModel && models.All(n => n.Id != m.Id)).ToList();
            endpoint.Models = [.. kept, .. models];
            endpoint.SelectedModel ??= Endpoint.DefaultModel(endpoint.Models);
            Persist();
            await SyncIfActiveAsync(id);
        }
        catch (Exception error) when (error is ConfigException or HttpRequestException or TaskCanceledException)
        {
            Show(true, error.Message);
        }
        finally
        {
            LoadingModels.Remove(id);
            Raise();
        }
    }

    // 工具

    public async Task RefreshStatusesAsync()
    {
        var snapshot = State.Clone();
        Statuses = await Task.Run(() => Engine.CurrentStatuses(snapshot));
        Raise();
    }

    public void Show(bool isError, string text)
    {
        Notice = new Notice(isError, text);
        Raise();
        _noticeTimer?.Cancel();
        var timer = _noticeTimer = new CancellationTokenSource();
        _ = HideNoticeAsync(TimeSpan.FromSeconds(isError ? 7 : 3), timer.Token);
    }

    private async Task HideNoticeAsync(TimeSpan delay, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, token);
            Notice = null;
            Raise();
        }
        catch (TaskCanceledException)
        {
        }
    }

    // 内部

    private Task SyncIfActiveAsync(Guid id) => State.ActiveEndpointId == id ? SyncAsync() : RefreshStatusesAsync();

    private async Task SyncAsync()
    {
        Persist();
        var generation = ++_generation;
        IsSyncing = true;
        Raise();
        var snapshot = State.Clone();
        var report = await Task.Run(() => Engine.Sync(snapshot));
        Apply(report, generation);
    }

    private async Task DisableAsync(ToolId tool)
    {
        var snapshot = State.Clone();
        var report = await Task.Run(() => Engine.Disable(tool, snapshot));
        Apply(report, ++_generation);
        var cleanup = await Task.Run(() => Engine.Sync(State.Clone()));
        Apply(cleanup, _generation);
    }

    private void Apply(SyncReport report, int generation)
    {
        foreach (var (tool, originals) in report.Originals) State.Originals[tool] = originals;
        foreach (var tool in report.RemovedOriginals) State.Originals.Remove(tool);
        if (report.Originals.Count > 0 || report.RemovedOriginals.Count > 0) Persist();

        if (generation != _generation) return;
        foreach (var (tool, status) in report.Statuses) Statuses[tool] = status;
        IsSyncing = false;
        if (report.Statuses.Values.OfType<ToolState.Failed>().FirstOrDefault() is { } failure) Show(true, failure.Reason);
        else if (report.Notes.FirstOrDefault() is { } note) Show(false, note);
        Raise();
    }

    private void Persist()
    {
        try
        {
            _store.Save(State);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            Show(true, $"无法保存设置：{error.Message}");
        }
    }

    private void Raise() => Changed?.Invoke();
}
