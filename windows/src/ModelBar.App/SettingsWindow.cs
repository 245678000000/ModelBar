using System.Diagnostics;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using ModelBar.Core;
using static ModelBar.App.UiKit;

namespace ModelBar.App;

internal sealed class SettingsWindow : Window
{
    public static readonly Guid ToolsPage = new("00000000-0000-0000-0000-000000000001");
    public static readonly Guid GeneralPage = new("00000000-0000-0000-0000-000000000002");
    public static readonly Guid AboutPage = new("00000000-0000-0000-0000-000000000003");

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "ModelBar";

    private readonly AppController _controller;
    private readonly StackPanel _navigation = new() { Margin = new Thickness(10) };
    private readonly StackPanel _detail = new() { Margin = new Thickness(24, 20, 24, 24), MaxWidth = 720 };
    private Guid? _page;

    private Guid? _editing;
    private readonly TextBox _name = new();
    private readonly TextBox _url = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") };
    private readonly PasswordBox _key = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") };
    private readonly TextBox _revealedKey = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") };
    private readonly TextBox _manualModel = new();
    private readonly TextBox _modelSearch = new();
    private readonly ContentControl _keyHost = new() { IsTabStop = false };
    private readonly Button _eye;
    private readonly TextBlock _keyHint = Note("已保存在凭据管理器，输入新值可替换。");
    private readonly Grid _saveRow;
    private readonly Button _save;
    private readonly TextBlock _saveHint = Note("请填写名称和以 http:// 或 https:// 开头的地址");
    private readonly FrameworkElement _connection;
    private readonly StackPanel _modelRows = new();
    private bool _isRevealed;
    private bool _keyEdited;
    private bool _loading;

    public SettingsWindow(AppController controller)
    {
        _controller = controller;
        Title = "ModelBar";
        Width = 880;
        Height = 640;
        MinWidth = 720;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var navigation = new Border { Width = 220, Child = new ScrollViewer { Content = _navigation, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } };
        var detail = new ScrollViewer { Content = _detail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Content = Columns((navigation, Auto), (detail, Fill));
        SetResourceReference(BackgroundProperty, "SolidBackgroundFillColorBaseBrush");

        _eye = UiKit.Button("IconButton", Icon("\uE7B3", 14), ToggleReveal, "显示或隐藏密钥");
        _eye.Margin = new Thickness(6, 0, 0, 0);
        _save = Plain("保存", Save, accent: true);
        var revert = Plain("还原", () =>
        {
            _editing = null;
            Rebuild();
        });
        revert.Margin = new Thickness(0, 0, 8, 0);
        _saveRow = Columns((_saveHint, Fill), (revert, Auto), (_save, Auto));
        // 这张卡片只建一次。输入时不重建它，否则会打断中文输入法的组字。
        _connection = Titled("连接", Card(
            Labeled("名称", _name),
            Labeled("Base URL", _url),
            Labeled("API Key", Columns((_keyHost, Fill), (_eye, Auto))),
            _keyHint,
            _saveRow));

        _name.TextChanged += (_, _) => UpdateConnection();
        _url.TextChanged += (_, _) => UpdateConnection();
        _revealedKey.TextChanged += (_, _) => KeyChanged(_revealedKey.Text);
        _key.PasswordChanged += (_, _) => KeyChanged(_key.Password);
        _modelSearch.TextChanged += (_, _) => FillModelRows();

        controller.Changed += () => KeepingFocus(Rebuild);
        Closing += (_, e) =>
        {
            // 窗口只是隐藏，下次打开保留当前页面。
            e.Cancel = true;
            Hide();
        };
        Rebuild();
    }

    public void ShowPage(Guid? page)
    {
        _page = page ?? _page ?? _controller.State.ActiveEndpointId ?? _controller.State.Endpoints.FirstOrDefault()?.Id ?? ToolsPage;
        Rebuild();
        Show();
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }

    public void ShowAddEndpoint()
    {
        ShowPage(null);
        var dialog = new AddEndpointDialog(_controller, id =>
        {
            _page = id;
            Rebuild();
        }) { Owner = this };
        dialog.ShowDialog();
    }

    public void Select(Guid page)
    {
        _page = page;
        Rebuild();
    }

    private void Rebuild()
    {
        BuildNavigation();
        _detail.Children.Clear();
        if (_page is { } page)
        {
            if (page == ToolsPage) BuildTools();
            else if (page == GeneralPage) BuildGeneral();
            else if (page == AboutPage) BuildAbout();
            else if (_controller.Find(page) is { } endpoint) BuildEndpoint(endpoint);
            else if (_controller.State.Endpoints.FirstOrDefault() is { } first)
            {
                _page = first.Id;
                BuildEndpoint(first);
            }
            else
            {
                _page = ToolsPage;
                BuildTools();
            }
        }
        if (_controller.Notice is { } notice)
        {
            var icon = Icon(notice.IsError ? "" : "", 12, notice.IsError ? Critical : Success);
            var text = Text(notice.Text, 12, Primary, wrap: true);
            text.Margin = new Thickness(6, 0, 0, 0);
            var view = Module(Columns((icon, Auto), (text, Fill)), 8, 8);
            view.Margin = new Thickness(0, 12, 0, 0);
            _detail.Children.Add(view);
        }
    }

    private void BuildNavigation()
    {
        _navigation.Children.Clear();
        _navigation.Children.Add(NavigationHeader("接口"));
        foreach (var endpoint in _controller.State.Endpoints)
        {
            var name = Text(endpoint.Name, 13);
            name.Margin = new Thickness(8, 0, 4, 0);
            var check = Icon(endpoint.Id == _controller.State.ActiveEndpointId ? "" : "", 10);
            _navigation.Children.Add(NavigationRow(endpoint.Id, Columns((Glyph(endpoint.Name, 20), Auto), (name, Fill), (check, Auto))));
        }
        var plus = Icon("", 12);
        plus.Width = 20;
        plus.TextAlignment = TextAlignment.Center;
        var add = Text("添加接口", 13, Secondary);
        add.Margin = new Thickness(8, 0, 4, 0);
        _navigation.Children.Add(UiKit.Button("RowButton", Columns((plus, Auto), (add, Fill)), ShowAddEndpoint, padding: new Thickness(8, 7, 8, 7)));

        _navigation.Children.Add(NavigationHeader("应用"));
        _navigation.Children.Add(NavigationRow(ToolsPage, IconRow("", "工具同步")));
        _navigation.Children.Add(NavigationRow(GeneralPage, IconRow("", "通用")));
        _navigation.Children.Add(NavigationRow(AboutPage, IconRow("", "关于")));
    }

    private static FrameworkElement IconRow(string glyph, string title)
    {
        var icon = Icon(glyph, 14);
        icon.Width = 20;
        icon.TextAlignment = TextAlignment.Center;
        var text = Text(title, 13);
        text.Margin = new Thickness(8, 0, 4, 0);
        return Columns((icon, Auto), (text, Fill));
    }

    private static TextBlock NavigationHeader(string title)
    {
        var header = Text(title, 11.5, Secondary, FontWeights.SemiBold);
        header.Margin = new Thickness(8, 12, 0, 6);
        return header;
    }

    private FrameworkElement NavigationRow(Guid page, FrameworkElement content) =>
        UiKit.Button(_page == page ? "RowButtonSelected" : "RowButton", content, () => Select(page), padding: new Thickness(8, 7, 8, 7));

    private void AddSection(string? title, FrameworkElement content)
    {
        var section = title is null ? content : Titled(title, content);
        section.Margin = new Thickness(0, 0, 0, 18);
        _detail.Children.Add(section);
    }

    private static FrameworkElement Card(params FrameworkElement[] rows)
    {
        var panel = new StackPanel();
        for (var index = 0; index < rows.Length; index++)
        {
            rows[index].Margin = new Thickness(0, index == 0 ? 0 : 10, 0, 0);
            panel.Children.Add(rows[index]);
        }
        return Module(panel, 10, 14);
    }

    private static FrameworkElement Labeled(string label, FrameworkElement control)
    {
        var title = Text(label, 13);
        title.Width = 110;
        return Columns((title, Auto), (control, Fill));
    }

    private static TextBlock Note(string text, string brush = Secondary) => Text(text, 12, brush, wrap: true);

    private static Button Plain(string text, Action click, bool accent = false)
    {
        var button = new Button { Content = text, Padding = new Thickness(12, 4, 12, 5), VerticalAlignment = VerticalAlignment.Center };
        if (accent) button.SetResourceReference(StyleProperty, "AccentButtonStyle");
        button.Click += (_, _) => click();
        return button;
    }

    // 接口详情

    private void BuildEndpoint(Endpoint endpoint)
    {
        if (_editing != endpoint.Id) LoadFields(endpoint);

        var isActive = endpoint.Id == _controller.State.ActiveEndpointId;
        var names = new StackPanel { Margin = new Thickness(14, 0, 8, 0) };
        names.Children.Add(Text(endpoint.Name, 20, Primary, FontWeights.SemiBold));
        names.Children.Add(Text(endpoint.Host, 12.5, Secondary));
        FrameworkElement status = isActive
            ? Text("使用中", 13, Success, FontWeights.Medium)
            : Plain("设为当前", () => Run(_controller.ActivateAsync(endpoint.Id)), accent: true);
        AddSection(null, Card(Columns((Glyph(endpoint.Name, 48), Auto), (names, Fill), (status, Auto))));

        UpdateConnection();
        AddPersistentSection(_connection);

        var probe = endpoint.Probe;
        var probeRows = new List<FrameworkElement>
        {
            ProbeRow("模型列表", "GET /models", probe?.Models),
            ProbeRow("Chat Completions", "opencode、pi、Grok、Droid、Kilo Code 使用", probe?.Chat),
            ProbeRow("Responses", "Codex CLI 需要", probe?.Responses),
            ProbeRow("Anthropic", "Claude Code 需要", probe?.Messages),
        };
        if (probe?.Message is { } message) probeRows.Add(Note(message));
        var testButton = _controller.Testing.Contains(endpoint.Id)
            ? (FrameworkElement)new ProgressBar { IsIndeterminate = true, Width = 80, Height = 3 }
            : Plain("重新测试", () => Run(_controller.TestAsync(endpoint.Id)));
        var latency = Text(probe?.LatencyMs is { } ms ? $"{ms} ms" : "", 12, Secondary);
        latency.Margin = new Thickness(0, 0, 10, 0);
        probeRows.Add(Columns((Note("测试会发送三条极短的真实请求，可能产生极少量费用。"), Fill), (latency, Auto), (testButton, Auto)));
        AddSection("连接测试", Card(probeRows.ToArray()));

        AddSection($"模型（{endpoint.Models.Count}）", ModelsCard(endpoint));
        AddSection("推理档位", EffortCard(endpoint));
        AddSection("用在其他工具里", CopyCard(endpoint));

        var delete = Plain("删除这个接口", () => Delete(endpoint));
        delete.HorizontalAlignment = HorizontalAlignment.Left;
        delete.SetResourceReference(ForegroundProperty, Critical);
        AddSection(null, delete);
    }

    private void AddPersistentSection(FrameworkElement section)
    {
        section.Margin = new Thickness(0, 0, 0, 18);
        _detail.Children.Add(section);
    }

    /// <summary>重建时把输入框从旧容器上摘下来，才能放进新容器。</summary>
    private static T Detached<T>(T element) where T : FrameworkElement
    {
        if (element.Parent is Panel panel) panel.Children.Remove(element);
        return element;
    }

    private void UpdateConnection()
    {
        if (_loading || _editing is not { } id || _controller.Find(id) is not { } endpoint) return;
        var wanted = (FrameworkElement)(_isRevealed ? _revealedKey : _key);
        if (!ReferenceEquals(_keyHost.Content, wanted)) _keyHost.Content = wanted;
        _eye.Visibility = endpoint.HasKey ? Visibility.Visible : Visibility.Collapsed;
        _keyHint.Visibility = !_isRevealed && endpoint.HasKey && !_keyEdited ? Visibility.Visible : Visibility.Collapsed;
        var valid = _name.Text.Trim().Length > 0 && Endpoint.IsValidBaseUrl(_url.Text);
        _saveRow.Visibility = IsDirty(endpoint) ? Visibility.Visible : Visibility.Collapsed;
        _save.IsEnabled = valid;
        _saveHint.Visibility = valid ? Visibility.Hidden : Visibility.Visible;
    }

    private static FrameworkElement ProbeRow(string title, string caption, ProbeStatus? status)
    {
        var icon = status switch
        {
            ProbeStatus.Ok => Icon("", 13, Success),
            ProbeStatus.Failed => Icon("", 13, Critical),
            _ => Icon("", 13, Tertiary),
        };
        icon.Width = 20;
        var name = Text(title, 13);
        name.Margin = new Thickness(6, 0, 8, 0);
        return Columns((icon, Auto), (name, Fill), (Text(caption, 12, Secondary), Auto));
    }

    private FrameworkElement ModelsCard(Endpoint endpoint)
    {
        var rows = new List<FrameworkElement>();
        if (endpoint.Models.Count > 6) rows.Add(Labeled("搜索", Detached(_modelSearch)));
        if (endpoint.Models.Count > 0)
        {
            FillModelRows();
            if (_modelRows.Parent is ScrollViewer viewer) viewer.Content = null;
            rows.Add(new ScrollViewer { Content = _modelRows, MaxHeight = 230, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        }
        var add = Plain("添加", () =>
        {
            var value = _manualModel.Text;
            _manualModel.Text = "";
            Run(_controller.AddManualModelAsync(endpoint.Id, value));
        });
        add.Margin = new Thickness(8, 0, 0, 0);
        rows.Add(Labeled("手动添加", Columns((Detached(_manualModel), Fill), (add, Auto))));
        var refresh = _controller.LoadingModels.Contains(endpoint.Id)
            ? (FrameworkElement)new ProgressBar { IsIndeterminate = true, Width = 80, Height = 3 }
            : Plain("刷新列表", () => Run(_controller.RefreshModelsAsync(endpoint.Id)));
        refresh.HorizontalAlignment = HorizontalAlignment.Left;
        rows.Add(refresh);
        return Card(rows.ToArray());
    }

    private void FillModelRows()
    {
        _modelRows.Children.Clear();
        if (_editing is not { } id || _controller.Find(id) is not { } endpoint) return;
        var query = _modelSearch.Text.Trim();
        foreach (var model in endpoint.Models.Where(m => m.Id.Contains(query, StringComparison.OrdinalIgnoreCase)))
        {
            var selected = model.Id == endpoint.SelectedModel;
            var mark = Icon(selected ? "\uE73E" : "", 11, "AccentTextFillColorPrimaryBrush");
            mark.Width = 18;
            var size = Text(model.ContextLabel ?? "", 11.5, Secondary);
            _modelRows.Children.Add(UiKit.Button(selected ? "RowButtonSelected" : "RowButton",
                Columns((mark, Auto), (Text(model.Id, 12.5, Primary, FontWeights.Medium, mono: true), Fill), (size, Auto)),
                () => Run(_controller.SelectModelAsync(id, model.Id)), padding: new Thickness(8, 5, 8, 5)));
        }
    }

    private FrameworkElement EffortCard(Endpoint endpoint)
    {
        var current = endpoint.CurrentModel;
        var levels = current?.AvailableEfforts ?? Enum.GetValues<ReasoningEffort>();
        var unsupported = current?.SupportsReasoning == false;
        var segments = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Columns = levels.Count };
        foreach (var level in levels)
        {
            var label = new TextBlock { Text = level.Title(), FontSize = 13, HorizontalAlignment = HorizontalAlignment.Center };
            var button = UiKit.Button(level == endpoint.Effort ? "SegmentButtonSelected" : "SegmentButton", label, () => Run(_controller.SetEffortAsync(endpoint.Id, level)));
            button.IsEnabled = !unsupported && current is not null;
            segments.Children.Add(button);
        }
        var track = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(2), Child = segments };
        track.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush");
        return Card(track, Note(unsupported ? "接口声明这个模型不支持推理档位。" : "作为 reasoning_effort 发给接口。接口是否遵守取决于服务商。"));
    }

    private FrameworkElement CopyCard(Endpoint endpoint)
    {
        var rows = new List<FrameworkElement> { CopyRow("Base URL", endpoint.BaseUrl, () => endpoint.BaseUrl) };
        if (endpoint.SelectedModel is { } model) rows.Add(CopyRow("模型名", model, () => model));
        if (endpoint.HasKey) rows.Add(CopyRow("API Key", "••••••••", () => _controller.ReadKey(endpoint.Id)));
        rows.Add(Note("Cline 等扩展：提供商选 OpenAI Compatible，再填入这几项。"));
        return Card(rows.ToArray());
    }

    private FrameworkElement CopyRow(string title, string value, Func<string?> read)
    {
        var label = Text(title, 13);
        label.Width = 110;
        var button = UiKit.Button("IconButton", Icon("", 13), () =>
        {
            if (read() is { } text)
            {
                Clipboard.SetText(text);
                _controller.Show(false, $"已拷贝{title}");
            }
        }, $"拷贝{title}");
        return Columns((label, Auto), (Text(value, 12, Secondary, mono: true), Fill), (button, Auto));
    }

    private void LoadFields(Endpoint endpoint)
    {
        _loading = true;
        _editing = endpoint.Id;
        _name.Text = endpoint.Name;
        _url.Text = endpoint.BaseUrl;
        _key.Password = "";
        _revealedKey.Text = "";
        _modelSearch.Text = "";
        _isRevealed = false;
        _keyEdited = false;
        _loading = false;
    }

    private void KeyChanged(string value)
    {
        if (_loading) return;
        _keyEdited = value.Length > 0;
        UpdateConnection();
    }

    private bool IsDirty(Endpoint endpoint) =>
        _name.Text != endpoint.Name || Endpoint.Normalize(_url.Text) != endpoint.BaseUrl || _keyEdited;

    private void ToggleReveal()
    {
        if (_editing is not { } id) return;
        _loading = true;
        if (_isRevealed)
        {
            _isRevealed = false;
            _revealedKey.Text = "";
            if (!_keyEdited) _key.Password = "";
        }
        else
        {
            _revealedKey.Text = _keyEdited ? _key.Password : _controller.ReadKey(id) ?? "";
            _isRevealed = true;
        }
        _loading = false;
        UpdateConnection();
    }

    private void Save()
    {
        if (_editing is not { } id) return;
        string? newKey = null;
        if (_keyEdited) newKey = _isRevealed ? _revealedKey.Text : _key.Password;
        var (name, url) = (_name.Text, _url.Text);
        _editing = null;
        Run(_controller.UpdateEndpointAsync(id, name, url, newKey));
    }

    private void Delete(Endpoint endpoint)
    {
        var answer = MessageBox.Show(this, $"删除“{endpoint.Name}”？\n密钥会一起从凭据管理器移除。如果它正在使用，工具会切到下一个接口。", "ModelBar", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.OK) return;
        _page = null;
        Run(_controller.DeleteEndpointAsync(endpoint.Id));
        _page = _controller.State.Endpoints.FirstOrDefault(e => e.Id != endpoint.Id)?.Id ?? ToolsPage;
    }

    // 工具同步

    private void BuildTools()
    {
        if (_controller.State.BridgeEnabled || _controller.CanOfferAnyBridge)
        {
            var text = new StackPanel { Margin = new Thickness(0, 0, 12, 0) };
            text.Children.Add(Text("本机转换", 13.5, Primary, FontWeights.Medium));
            var note = Note("让 Codex 和 Claude Code 也能用只有 Chat 协议的接口。会运行一个只监听本机的后台服务，ModelBar 退出后继续运行，不再需要时自动移除。联网搜索这类依赖官方服务端的功能不可用。");
            note.Margin = new Thickness(0, 3, 0, 0);
            text.Children.Add(note);
            var rows = new List<FrameworkElement> { Columns((text, Fill), (Toggle(_controller.State.BridgeEnabled, "本机转换", on => Run(_controller.SetBridgeAsync(on))), Auto)) };
            if (_controller.IsBridgeActive)
                rows.Add(Columns((Note("日志记录请求状态和上游的报错，不记录密钥和请求内容"), Fill), (Plain("查看日志", () => Reveal(_controller.Paths.BridgeLog)), Auto)));
            AddSection(null, Card(rows.ToArray()));
        }

        foreach (var tool in Enum.GetValues<ToolId>()) AddSection(null, ToolCard(tool));

        var backups = Columns((Note("每次修改配置前都会自动备份"), Fill), (Plain("打开备份", () => Reveal(_controller.Paths.BackupsDirectory)), Auto));
        AddSection("安全", Card(
            Note("Key 保存在 Windows 凭据管理器。为了让工具在 ModelBar 退出后仍能读取，当前接口的 Key 会另存一份只有你的账户能读的文件，切换接口或停用全部工具时自动删除。工具的配置文件里只写这个文件的路径，不写 Key 本身（Factory Droid 除外）。"),
            backups));
    }

    private FrameworkElement ToolCard(ToolId tool)
    {
        var state = _controller.Status(tool);
        var names = new StackPanel { Margin = new Thickness(12, 0, 8, 0) };
        names.Children.Add(Text(tool.Title(), 14, Primary, FontWeights.SemiBold));
        names.Children.Add(Text(tool.Subtitle(), 12, Secondary));
        var statusText = _controller.IsBridged(tool) && state is ToolState.Synced ? "已同步 · 本机转换" : state.Title;
        var status = Text(statusText, 12, PanelWindow.StatusBrush(state));
        status.Margin = new Thickness(0, 0, 12, 0);
        FrameworkElement control = state is ToolState.NotInstalled
            ? new Border()
            : Toggle(_controller.IsEnabled(tool), tool.Title(), on => Run(_controller.SetToolAsync(tool, on)));

        var rows = new List<FrameworkElement> { Columns((ToolTile(tool, 34), Auto), (names, Fill), (status, Auto), (control, Auto)) };
        if (state.Detail is { } detail) rows.Add(Note(detail, PanelWindow.StatusBrush(state)));
        if (state is ToolState.Stale or ToolState.Failed)
        {
            var hint = state is ToolState.Stale ? "配置文件被手动改过，和 ModelBar 的设置不一致。" : "";
            rows.Add(Columns((Note(hint), Fill), (Plain("重新同步", () => Run(_controller.ResyncAsync())), Auto)));
        }
        rows.Add(Note(ToolNote(tool)));
        if (state is ToolState.NotInstalled && InstallCommand(tool) is { } command)
        {
            var box = new TextBox { Text = command, IsReadOnly = true, FontSize = 12 };
            rows.Add(Labeled("安装命令", box));
        }
        if (tool == ToolId.Kilo && !KiloExtension.IsInstalled(_controller.Paths) && KiloExtension.CursorCli(_controller.Paths) is not null)
        {
            var install = Plain("安装到 Cursor", () => InstallKilo());
            install.HorizontalAlignment = HorizontalAlignment.Left;
            rows.Add(install);
        }
        var path = _controller.ConfigPath(tool);
        var shown = path.Replace(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "~", StringComparison.OrdinalIgnoreCase);
        rows.Add(Columns((Text(shown, 12, Secondary, mono: true), Fill), (Plain("在资源管理器中显示", () => Reveal(path)), Auto)));
        return Card(rows.ToArray());
    }

    private static string ToolNote(ToolId tool) => tool switch
    {
        ToolId.ClaudeCode => "Claude Code 只支持 Anthropic 协议。接口不支持时，开启本机转换才能使用。打开后，新开的 Claude Code 会话和 VS Code 扩展都会走这个接口，已经在运行的会话不受影响。",
        ToolId.Codex => "Codex 只支持 Responses API。接口不支持时，开启本机转换才能使用。Cursor 和 VS Code 里的 Codex 扩展读的也是这份配置。",
        ToolId.OpenCode => "切换时如果后台服务正在运行，会自动重启让新配置生效，进行中的会话可能被打断。",
        ToolId.Pi => "默认模型会切到这个接口，也可以在 pi 里随时换回你其他的模型。",
        ToolId.Grok => "Grok 不支持给自定义模型设置推理档位，所以这里的档位对它不起作用。",
        ToolId.Droid => "需要先登录 Factory 账号。Droid 只接受明文 Key，所以 Key 会写进它的配置文件（只有你的账户能读），关闭开关时移除。",
        _ => "在 Cursor 或 VS Code 的侧边栏使用，有自己的对话面板。切换后如未生效，请重载编辑器窗口。",
    };

    private static string? InstallCommand(ToolId tool) => tool switch
    {
        ToolId.OpenCode => "npm install -g opencode-ai",
        ToolId.Codex => "npm install -g @openai/codex",
        ToolId.ClaudeCode => "npm install -g @anthropic-ai/claude-code",
        ToolId.Pi => "npm install -g @earendil-works/pi-coding-agent",
        _ => null,
    };

    private void InstallKilo()
    {
        _controller.Show(false, "正在安装 Kilo Code…");
        var paths = _controller.Paths;
        Run(Install());

        async Task Install()
        {
            await Task.Run(() => KiloExtension.InstallIntoCursor(paths));
            _controller.Show(false, "Kilo Code 已安装到 Cursor，重启 Cursor 后生效");
            await _controller.RefreshStatusesAsync();
        }
    }

    // 通用

    private void BuildGeneral()
    {
        var autostart = Columns((Text("开机时自动启动", 13), Fill), (Toggle(IsAutostartEnabled(), "开机时自动启动", SetAutostart), Auto));
        AddSection(null, Card(autostart));
        AddSection("数据", Card(Columns((Text("设置和备份", 13), Fill), (Plain("在资源管理器中显示", () => Reveal(_controller.Paths.Support)), Auto))));
        var quit = Plain("退出 ModelBar", () => Application.Current.Shutdown());
        quit.HorizontalAlignment = HorizontalAlignment.Left;
        AddSection(null, Card(quit, Note("退出后不占用后台资源（开启本机转换时，转换服务除外），已同步的工具会继续按当前配置运行。")));
    }

    private bool IsAutostartEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue(RunValue) is not null;
    }

    private void SetAutostart(bool enabled)
    {
        if (_controller.Paths.IsSandboxed) return;
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(RunValue, $"\"{Environment.ProcessPath}\"");
        else key.DeleteValue(RunValue, throwOnMissingValue: false);
    }

    // 关于

    private void BuildAbout()
    {
        var version = Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "开发版";
        var panel = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 60, 0, 0) };
        var title = Text("ModelBar", 26, Primary, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var line = Text($"版本 {version}", 12.5, Secondary);
        line.HorizontalAlignment = HorizontalAlignment.Center;
        line.Margin = new Thickness(0, 4, 0, 14);
        var about = Note("在托盘统一管理你的 API 接口，一键同步到官方支持自定义接口的工具。\n不修改 Cursor 或任何工具的程序文件，只写它们公开的配置文件。");
        about.TextAlignment = TextAlignment.Center;
        panel.Children.Add(title);
        panel.Children.Add(line);
        panel.Children.Add(about);
        _detail.Children.Add(panel);
    }

    private static void Reveal(string path)
    {
        var target = path;
        while (!File.Exists(target) && !Directory.Exists(target))
        {
            var parent = Path.GetDirectoryName(target);
            if (parent is null) return;
            target = parent;
        }
        Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = false, Arguments = File.Exists(target) ? $"/select,\"{target}\"" : $"\"{target}\"" });
    }

    private void Run(Task task) => _ = Guarded(task);

    private async Task Guarded(Task task)
    {
        try
        {
            await task;
        }
        catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException or HttpRequestException)
        {
            _controller.Show(true, error.Message);
        }
    }
}

internal sealed class AddEndpointDialog : Window
{
    private readonly AppController _controller;
    private readonly Action<Guid> _added;
    private readonly TextBox _name = new();
    private readonly TextBox _url = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") };
    private readonly PasswordBox _key = new() { FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") };
    private readonly Button _add = new() { Content = "添加", IsDefault = true, Padding = new Thickness(18, 5, 18, 6), IsEnabled = false };
    private readonly TextBlock _error = Text("", 12, Critical, wrap: true);

    public AddEndpointDialog(AppController controller, Action<Guid> added)
    {
        _controller = controller;
        _added = added;
        Title = "添加接口";
        Width = 500;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        SetResourceReference(BackgroundProperty, "SolidBackgroundFillColorBaseBrush");

        var root = new StackPanel { Margin = new Thickness(22) };
        root.Children.Add(Text("添加接口", 20, Primary, FontWeights.SemiBold));

        var presets = new System.Windows.Controls.Primitives.UniformGrid { Columns = 4, Margin = new Thickness(-4, 12, -4, 8) };
        foreach (var preset in Preset.All)
        {
            presets.Children.Add(PresetChip(Glyph(preset.Name, 26), preset.Name, () =>
            {
                _name.Text = preset.Name;
                _url.Text = preset.BaseUrl;
                (preset.NeedsKey ? (Control)_key : _name).Focus();
            }));
        }
        presets.Children.Add(PresetChip(Icon("", 18), "自定义", () =>
        {
            _name.Text = "";
            _url.Text = "";
            _name.Focus();
        }));
        root.Children.Add(presets);

        root.Children.Add(Field("名称", _name));
        root.Children.Add(Field("Base URL", _url));
        root.Children.Add(Field("API Key", _key));
        var note = Text("密钥保存在 Windows 凭据管理器。添加后会自动拉取模型并测试连接。本地接口可以不填。", 12, Secondary, wrap: true);
        note.Margin = new Thickness(0, 8, 0, 8);
        root.Children.Add(note);
        root.Children.Add(_error);

        var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(18, 5, 18, 6), Margin = new Thickness(0, 0, 8, 0) };
        _add.SetResourceReference(StyleProperty, "AccentButtonStyle");
        _add.Click += (_, _) => Add();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0) };
        buttons.Children.Add(cancel);
        buttons.Children.Add(_add);
        root.Children.Add(buttons);
        Content = root;

        _name.TextChanged += (_, _) => Validate();
        _url.TextChanged += (_, _) => Validate();
        Loaded += (_, _) => _name.Focus();
    }

    private static FrameworkElement PresetChip(FrameworkElement glyph, string name, Action click)
    {
        var content = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.Height = 26;
        content.Children.Add(glyph);
        var label = Text(name, 12);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        label.Margin = new Thickness(0, 5, 0, 0);
        content.Children.Add(label);
        var button = UiKit.Button("RowButton", content, click, padding: new Thickness(4, 8, 4, 8));
        button.HorizontalContentAlignment = HorizontalAlignment.Center;
        var card = Module(button, 8, 0);
        card.Margin = new Thickness(4);
        return card;
    }

    private static FrameworkElement Field(string label, FrameworkElement control)
    {
        var title = Text(label, 13);
        title.Width = 80;
        var row = Columns((title, Auto), (control, Fill));
        row.Margin = new Thickness(0, 6, 0, 0);
        return row;
    }

    private void Validate() => _add.IsEnabled = _name.Text.Trim().Length > 0 && Endpoint.IsValidBaseUrl(_url.Text);

    private async void Add()
    {
        try
        {
            var task = _controller.AddEndpointAsync(_name.Text, _url.Text, _key.Password);
            var id = _controller.State.Endpoints[^1].Id;
            _added(id);
            Close();
            await task;
        }
        catch (Exception error) when (error is ConfigException or IOException or UnauthorizedAccessException or HttpRequestException)
        {
            if (IsVisible) _error.Text = error.Message;
            else _controller.Show(true, error.Message);
        }
    }
}
