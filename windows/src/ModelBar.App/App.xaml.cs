using System.IO;
using System.Windows;
using ModelBar.Core;

namespace ModelBar.App;

public partial class App : Application
{
    private const string MutexName = @"Local\ModelBarSingleInstance";
    private const string ShowEventName = @"Local\ModelBarShowPanel";

    private Mutex? _mutex;
    private EventWaitHandle? _showEvent;
    private AppController? _controller;
    private PanelWindow? _panel;
    private SettingsWindow? _settings;
    private System.Windows.Forms.NotifyIcon? _tray;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var paths = AppPaths.Current();

        if (!paths.IsSandboxed)
        {
            _mutex = new Mutex(initiallyOwned: true, MutexName, out var isFirst);
            _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
            if (!isFirst)
            {
                // 已经在运行：托盘图标可能被收进了隐藏区，让正在运行的实例弹出面板。
                _showEvent.Set();
                Shutdown();
                return;
            }
            WatchShowRequests();
        }

        var source = Path.Combine(AppContext.BaseDirectory, "ModelBarGateway.exe");
        IKeyStore keys = paths.IsSandboxed ? new SandboxFileKeyStore(paths.SandboxKeysDirectory) : new CredentialManagerStore();
        _controller = new AppController(paths, keys, new BridgeManager(paths, source));

        _settings = new SettingsWindow(_controller);
        _panel = new PanelWindow(_controller, page => _settings.ShowPage(page), () => _settings.ShowAddEndpoint(), Quit);
        _tray = MakeTray();
        _controller.Changed += UpdateTrayText;

#if DEVSNAPSHOT
        if (Array.IndexOf(e.Args, "--dev-snapshot") is >= 0 and var index)
        {
            await _controller.StartAsync();
            await DevSnapshot.RunAsync(e.Args[index + 1], _controller, _panel, _settings);
            Quit();
            return;
        }
#endif

        await _controller.StartAsync();
        UpdateTrayText();
        if (_controller.State.Endpoints.Count == 0) _settings.ShowAddEndpoint();
    }

    private void WatchShowRequests()
    {
        var thread = new Thread(() =>
        {
            while (_showEvent!.WaitOne())
            {
                Dispatcher.BeginInvoke(() => _panel?.ShowPanel(System.Windows.Forms.Cursor.Position));
            }
        })
        { IsBackground = true };
        thread.Start();
    }

    private System.Windows.Forms.NotifyIcon MakeTray()
    {
        using var stream = typeof(App).Assembly.GetManifestResourceStream("ModelBar.ico")!;
        var tray = new System.Windows.Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize),
            Text = "ModelBar",
            Visible = true,
        };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add("设置…", null, (_, _) => _settings?.ShowPage(null));
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("退出 ModelBar", null, (_, _) => Quit());
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (_, e) =>
        {
            if (e.Button != System.Windows.Forms.MouseButtons.Left || _panel is null) return;
            // 点托盘图标会先让面板失去焦点而收起，不能紧接着又弹出来。
            if (_panel.IsVisible) _panel.HidePanel();
            else if ((DateTime.UtcNow - _panel.LastHidden).TotalMilliseconds > 250) _panel.ShowPanel(System.Windows.Forms.Cursor.Position);
        };
        return tray;
    }

    private void UpdateTrayText()
    {
        if (_tray is null || _controller is null) return;
        var model = _controller.ActiveEndpoint?.SelectedModel;
        var text = model is null ? "ModelBar" : $"ModelBar · {model}";
        // NotifyIcon 的提示文字最长 127 个字符。
        _tray.Text = text.Length > 120 ? text[..120] : text;
    }

    private void Quit()
    {
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _mutex?.Dispose();
        _showEvent?.Dispose();
        base.OnExit(e);
    }
}
