#if DEVSNAPSHOT
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ModelBar.Core;

namespace ModelBar.App;

/// <summary>开发用：把各界面渲染成图片，让没有 Windows 的开发机也能检查效果。</summary>
internal static class DevSnapshot
{
    public static async Task RunAsync(string directory, AppController controller, PanelWindow panel, SettingsWindow settings)
    {
        Directory.CreateDirectory(directory);
        panel.KeepOpen = true;
        foreach (var (theme, label) in new[] { (ThemeMode.Light, "light"), (ThemeMode.Dark, "dark") })
        {
            Application.Current.ThemeMode = theme;
            await Pause();

            panel.ShowPanel(new System.Drawing.Point(1200, 800));
            await Pause();
            Save(panel, directory, $"panel-{label}");
            panel.Hide();

            settings.ShowPage(controller.State.ActiveEndpointId);
            await Pause();
            Save(settings, directory, $"settings-endpoint-{label}");
            settings.Select(SettingsWindow.ToolsPage);
            await Pause();
            Save(settings, directory, $"settings-tools-{label}");
            settings.Select(SettingsWindow.GeneralPage);
            await Pause();
            Save(settings, directory, $"settings-general-{label}");
            settings.Hide();

            var dialog = new AddEndpointDialog(controller, _ => { });
            dialog.Show();
            await Pause();
            Save(dialog, directory, $"add-endpoint-{label}");
            dialog.Close();
        }
    }

    private static async Task Pause() => await Task.Delay(800);

    /// <summary>直接渲染窗口的根元素。VisualBrush 按内容边界缩放，会丢掉边距，看不准。</summary>
    private static void Save(Window window, string directory, string name)
    {
        var scale = VisualTreeHelper.GetDpi(window);
        var root = (FrameworkElement)VisualTreeHelper.GetChild(window, 0);
        root.UpdateLayout();
        var width = Math.Max(1, (int)(root.ActualWidth * 2 * scale.DpiScaleX));
        var height = Math.Max(1, (int)(root.ActualHeight * 2 * scale.DpiScaleY));
        var bitmap = new RenderTargetBitmap(width, height, 192 * scale.DpiScaleX, 192 * scale.DpiScaleY, PixelFormats.Pbgra32);
        bitmap.Render(root);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(directory, name + ".png"));
        encoder.Save(file);
    }
}
#endif
