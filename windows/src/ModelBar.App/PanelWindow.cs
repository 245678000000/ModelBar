using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using ModelBar.Core;
using static ModelBar.App.UiKit;

namespace ModelBar.App;

/// <summary>点托盘图标弹出的面板。点到别处就收起。</summary>
internal sealed class PanelWindow : Window
{
    private const double PanelWidth = 348;
    private readonly AppController _controller;
    private readonly Action<Guid?> _openSettings;
    private readonly Action _openAddEndpoint;
    private readonly Action _quit;
    private readonly StackPanel _root = new() { Margin = new Thickness(12, 10, 12, 10) };
    private readonly TextBox _search = new() { FontSize = 12, Margin = new Thickness(2, 2, 2, 4) };
    private readonly StackPanel _modelRows = new();
    private bool _modelsOpen;
    private System.Drawing.Point _anchor;

    public DateTime LastHidden { get; private set; }
    public bool KeepOpen { get; set; }

    public PanelWindow(AppController controller, Action<Guid?> openSettings, Action openAddEndpoint, Action quit)
    {
        _controller = controller;
        _openSettings = openSettings;
        _openAddEndpoint = openAddEndpoint;
        _quit = quit;

        Title = "ModelBar";
        Width = PanelWidth;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = true;
        SetResourceReference(BackgroundProperty, "SolidBackgroundFillColorBaseBrush");
        Content = _root;

        // 只刷新列表，不动输入框本身，否则会打断中文输入法的组字。
        _search.TextChanged += (_, _) => FillModelRows();
        controller.Changed += () => KeepingFocus(Rebuild);
        Deactivated += (_, _) => HidePanel();
        KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape) HidePanel();
        };
        SizeChanged += (_, _) => Reposition();
        SourceInitialized += (_, _) => ApplyWindowStyle();
        Rebuild();
    }

    public void ShowPanel(System.Drawing.Point anchor)
    {
        _anchor = anchor;
        _ = _controller.RefreshStatusesAsync();
        Rebuild();
        Show();
        Reposition();
        Activate();
    }

    public void HidePanel()
    {
        if (KeepOpen || !IsVisible) return;
        LastHidden = DateTime.UtcNow;
        Hide();
    }

    /// <summary>贴着托盘放：任务栏在下面就往上弹，在上面就往下弹。</summary>
    private void Reposition()
    {
        if (!IsVisible) return;
        var screen = System.Windows.Forms.Screen.FromPoint(_anchor);
        var work = screen.WorkingArea;
        var scale = VisualTreeHelper.GetDpi(this).DpiScaleX;
        var width = ActualWidth * scale;
        var height = ActualHeight * scale;
        const double gap = 8;
        var x = Math.Min(Math.Max(_anchor.X - width / 2, work.Left + gap * scale), work.Right - width - gap * scale);
        var y = _anchor.Y < work.Top + work.Height / 2 ? work.Top + gap * scale : work.Bottom - height - gap * scale;
        Left = x / scale;
        Top = y / scale;
    }

    private void Rebuild()
    {
        _root.Children.Clear();
        _root.Children.Add(Header());
        if (_controller.State.Endpoints.Count == 0)
        {
            _root.Children.Add(EmptyState());
        }
        else
        {
            Add(EndpointsModule());
            if (_controller.ActiveEndpoint is { } active) Add(ModelModule(active));
            Add(ToolsModule());
        }
        if (_controller.Notice is { } notice) Add(NoticeView(notice));
        Add(Footer());
    }

    private void Add(FrameworkElement element)
    {
        element.Margin = new Thickness(0, 10, 0, 0);
        _root.Children.Add(element);
    }

    private FrameworkElement Header()
    {
        var title = Text("ModelBar", 14, Primary, FontWeights.SemiBold);
        title.Margin = new Thickness(5, 0, 0, 0);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (_controller.ActiveEndpoint is { } active)
        {
            var testing = _controller.Testing.Contains(active.Id);
            FrameworkElement glyph = testing ? new ProgressBar { IsIndeterminate = true, Width = 16, Height = 3 } : Icon("");
            buttons.Children.Add(UiKit.Button("IconButton", glyph, () => Run(_controller.TestAsync(active.Id)), "测试当前接口"));
        }
        buttons.Children.Add(UiKit.Button("IconButton", Icon(""), () => _openSettings(null), "打开设置"));
        return Columns((title, Fill), (buttons, Auto));
    }

    private FrameworkElement EmptyState()
    {
        var panel = new StackPanel { Margin = new Thickness(0, 22, 0, 22), HorizontalAlignment = HorizontalAlignment.Center };
        var title = Text("还没有接口", 14, Primary, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        var hint = Text("添加一个 API 接口后，就能一键同步到各个工具。", 12, Secondary);
        hint.Margin = new Thickness(0, 6, 0, 12);
        var add = new Button { Content = "添加接口", HorizontalAlignment = HorizontalAlignment.Center, Padding = new Thickness(16, 6, 16, 6) };
        add.Click += (_, _) => _openAddEndpoint();
        panel.Children.Add(title);
        panel.Children.Add(hint);
        panel.Children.Add(add);
        return panel;
    }

    private FrameworkElement EndpointsModule()
    {
        var rows = new StackPanel();
        foreach (var endpoint in _controller.State.Endpoints) rows.Children.Add(EndpointRow(endpoint));
        var plus = Icon("", 12);
        plus.Width = 28;
        plus.TextAlignment = TextAlignment.Center;
        var label = Text("添加接口", 12.5, Secondary);
        label.Margin = new Thickness(10, 0, 0, 0);
        rows.Children.Add(UiKit.Button("RowButton", Columns((plus, Auto), (label, Fill)), _openAddEndpoint, padding: new Thickness(6, 4, 6, 4)));
        return Titled("接口", Module(rows));
    }

    private FrameworkElement EndpointRow(Endpoint endpoint)
    {
        var isActive = endpoint.Id == _controller.State.ActiveEndpointId;
        var names = new StackPanel { Margin = new Thickness(10, 0, 6, 0) };
        names.Children.Add(Text(endpoint.Name, 12.5, Primary, FontWeights.Medium));
        names.Children.Add(Text(endpoint.Host, 11, Secondary));

        var trailing = new StackPanel { Orientation = Orientation.Horizontal };
        if (_controller.Testing.Contains(endpoint.Id))
        {
            trailing.Children.Add(new ProgressBar { IsIndeterminate = true, Width = 18, Height = 3 });
        }
        else if (isActive)
        {
            if (endpoint.Probe?.LatencyMs is { } latency)
            {
                var label = Text($"{latency} ms", 11, Secondary);
                label.Margin = new Thickness(0, 0, 6, 0);
                trailing.Children.Add(label);
            }
            trailing.Children.Add(endpoint.Probe?.Models == ProbeStatus.Failed ? Icon("", 12, Caution) : Icon("", 12, "AccentTextFillColorPrimaryBrush"));
        }
        return UiKit.Button(
            isActive ? "RowButtonSelected" : "RowButton",
            Columns((Glyph(endpoint.Name), Auto), (names, Fill), (trailing, Auto)),
            () => Run(_controller.ActivateAsync(endpoint.Id)),
            padding: new Thickness(6, 4, 6, 4));
    }

    private FrameworkElement ModelModule(Endpoint endpoint)
    {
        var rows = new StackPanel();
        var current = endpoint.CurrentModel;
        var name = endpoint.SelectedModel is { } selected
            ? Text(selected, 12.5, Primary, FontWeights.Medium, mono: true)
            : Text(endpoint.Models.Count == 0 ? "还没有模型" : "选择模型", 12.5, Secondary);
        var size = Text(current?.ContextLabel ?? "", 11, Secondary);
        size.Margin = new Thickness(6, 0, 8, 0);
        var chevron = Icon(_modelsOpen ? "" : "", 10);
        rows.Children.Add(UiKit.Button("RowButton", Columns((name, Fill), (size, Auto), (chevron, Auto)), () =>
        {
            _modelsOpen = !_modelsOpen;
            _search.Text = "";
            Rebuild();
            if (_modelsOpen) _search.Focus();
        }, "选择模型", new Thickness(8, 7, 8, 7)));

        if (_modelsOpen) rows.Children.Add(ModelList(endpoint));
        else rows.Children.Add(EffortRow(endpoint, current));
        return Titled("模型", Module(rows));
    }

    private FrameworkElement ModelList(Endpoint endpoint)
    {
        var panel = new StackPanel();
        if (_search.Parent is Panel owner) owner.Children.Remove(_search);
        panel.Children.Add(_search);
        if (endpoint.Models.Count == 0)
        {
            panel.Children.Add(Text("这个接口没有返回模型列表，可以在设置里手动添加。", 11.5, Secondary, wrap: true));
            return panel;
        }
        FillModelRows();
        if (_modelRows.Parent is ScrollViewer viewer) viewer.Content = null;
        panel.Children.Add(new ScrollViewer { Content = _modelRows, MaxHeight = 190, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        return panel;
    }

    private void FillModelRows()
    {
        _modelRows.Children.Clear();
        if (_controller.ActiveEndpoint is not { } endpoint) return;
        var query = _search.Text.Trim();
        foreach (var model in endpoint.Models.Where(m => m.Id.Contains(query, StringComparison.OrdinalIgnoreCase)))
        {
            var label = Text(model.ContextLabel ?? "", 11, Secondary);
            label.Margin = new Thickness(6, 0, 6, 0);
            var check = Icon(model.Id == endpoint.SelectedModel ? "" : "", 10, "AccentTextFillColorPrimaryBrush");
            check.Width = 12;
            _modelRows.Children.Add(UiKit.Button("RowButton", Columns((Text(model.Id, 12, Primary, FontWeights.Medium, mono: true), Fill), (label, Auto), (check, Auto)), () =>
            {
                _modelsOpen = false;
                Run(_controller.SelectModelAsync(endpoint.Id, model.Id));
            }, padding: new Thickness(8, 5, 8, 5)));
        }
    }

    private FrameworkElement EffortRow(Endpoint endpoint, ModelInfo? current)
    {
        var levels = current?.AvailableEfforts ?? Enum.GetValues<ReasoningEffort>();
        var unsupported = current?.SupportsReasoning == false;
        var segments = new UniformGrid { Rows = 1, Columns = levels.Count, Width = 200 };
        foreach (var level in levels)
        {
            var isSelected = level == endpoint.Effort || (level == ReasoningEffort.Automatic && !levels.Contains(endpoint.Effort));
            var label = new TextBlock { Text = level.Title(), FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center };
            var button = UiKit.Button(isSelected ? "SegmentButtonSelected" : "SegmentButton", label, () => Run(_controller.SetEffortAsync(endpoint.Id, level)));
            button.IsEnabled = !unsupported && current is not null;
            segments.Children.Add(button);
        }
        var track = new Border { CornerRadius = new CornerRadius(7), Padding = new Thickness(2), Child = segments };
        track.SetResourceReference(Border.BackgroundProperty, "SubtleFillColorSecondaryBrush");
        var row = Columns((Text("推理档位", 12, unsupported ? Tertiary : Secondary), Fill), (track, Auto));
        row.Margin = new Thickness(8, 3, 6, 5);
        return row;
    }

    private FrameworkElement ToolsModule()
    {
        var rows = new StackPanel();
        var hidden = 0;
        foreach (var tool in Enum.GetValues<ToolId>())
        {
            if (_controller.Status(tool) is ToolState.NotInstalled && !_controller.IsEnabled(tool))
            {
                hidden++;
                continue;
            }
            rows.Children.Add(ToolRow(tool));
        }
        if (hidden > 0)
        {
            var link = UiKit.Button("LinkButton", Text($"还有 {hidden} 个工具未安装", 11, "AccentTextFillColorPrimaryBrush"), () => _openSettings(SettingsWindow.ToolsPage));
            link.Margin = new Thickness(8, 4, 8, 3);
            rows.Children.Add(link);
        }
        return Titled("同步到", Module(rows));
    }

    private FrameworkElement ToolRow(ToolId tool)
    {
        var state = _controller.Status(tool);
        var info = new StackPanel { Margin = new Thickness(10, 0, 6, 0) };
        info.Children.Add(Text(tool.Title(), 12.5, Primary, FontWeights.Medium));
        if (state is ToolState.Disabled)
        {
            info.Children.Add(Text(tool.Subtitle(), 11, Secondary));
        }
        else
        {
            var text = _controller.IsBridged(tool) && state is ToolState.Synced ? "已同步 · 本机转换" : state.Detail ?? state.Title;
            info.Children.Add(Text(text, 11, StatusBrush(state), wrap: true));
            if (_controller.CanOfferBridge(tool))
            {
                info.Children.Add(UiKit.Button("LinkButton", Text("开启本机转换", 11, "AccentTextFillColorPrimaryBrush", FontWeights.SemiBold), () => Run(_controller.SetBridgeAsync(true))));
            }
        }

        FrameworkElement control = state switch
        {
            ToolState.NotInstalled => SmallButton("安装", () => _openSettings(SettingsWindow.ToolsPage)),
            ToolState.Stale => SmallButton("修复", () => Run(_controller.ResyncAsync())),
            _ => Toggle(_controller.IsEnabled(tool), tool.Title(), on => Run(_controller.SetToolAsync(tool, on))),
        };
        var row = Columns((ToolTile(tool), Auto), (info, Fill), (control, Auto));
        row.Margin = new Thickness(6, 3, 6, 3);
        return row;
    }

    private static Button SmallButton(string text, Action click)
    {
        var button = new Button { Content = text, FontSize = 11.5, Padding = new Thickness(10, 2, 10, 3), VerticalAlignment = VerticalAlignment.Center };
        button.Click += (_, _) => click();
        return button;
    }

    public static string StatusBrush(ToolState state) => state switch
    {
        ToolState.Synced => Success,
        ToolState.Stale or ToolState.Incompatible => Caution,
        ToolState.Failed => Critical,
        _ => Secondary,
    };

    private static FrameworkElement NoticeView(Notice notice)
    {
        var icon = Icon(notice.IsError ? "" : "", 12, notice.IsError ? Critical : Success);
        var text = Text(notice.Text, 11.5, Primary, wrap: true);
        text.Margin = new Thickness(6, 0, 0, 0);
        return Module(Columns((icon, Auto), (text, Fill)), 8, 8);
    }

    private FrameworkElement Footer()
    {
        var hint = Text("退出后，工具仍按当前配置运行", 11, Tertiary);
        hint.Margin = new Thickness(5, 0, 0, 0);
        var quit = UiKit.Button("LinkButton", Text("退出", 12, Secondary, FontWeights.Medium), _quit);
        quit.Margin = new Thickness(0, 0, 5, 0);
        return Columns((hint, Fill), (quit, Auto));
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

    /// <summary>Windows 11 上的圆角和阴影。旧系统不支持时调用会失败，忽略即可。</summary>
    private void ApplyWindowStyle()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var preference = 2; // DWMWCP_ROUND
        _ = DwmSetWindowAttribute(handle, 33, ref preference, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
}
