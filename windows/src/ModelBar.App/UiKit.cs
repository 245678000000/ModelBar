using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using ModelBar.Core;

namespace ModelBar.App;

/// <summary>界面的基础部件。颜色都引用主题资源，跟随系统深浅色。</summary>
internal static class UiKit
{
    public const string Primary = "TextFillColorPrimaryBrush";
    public const string Secondary = "TextFillColorSecondaryBrush";
    public const string Tertiary = "TextFillColorTertiaryBrush";
    public const string Success = "SystemFillColorSuccessBrush";
    public const string Caution = "SystemFillColorCautionBrush";
    public const string Critical = "SystemFillColorCriticalBrush";

    public static TextBlock Text(string text, double size = 13, string brush = Primary, FontWeight? weight = null, bool mono = false, bool wrap = false)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        block.SetResourceReference(TextBlock.FontFamilyProperty, mono ? "MonoFont" : "UiFont");
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    public static TextBlock Icon(string glyph, double size = 13, string brush = Secondary)
    {
        var block = new TextBlock { Text = glyph, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
        block.SetResourceReference(TextBlock.FontFamilyProperty, "IconFont");
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    public static Border Module(FrameworkElement content, double radius = 12, double padding = 5)
    {
        var border = new Border
        {
            CornerRadius = new CornerRadius(radius),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(padding),
            Child = content,
        };
        border.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
        border.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
        return border;
    }

    public static StackPanel Titled(string title, FrameworkElement content)
    {
        var panel = new StackPanel();
        var label = Text(title, 11.5, Secondary, FontWeights.SemiBold);
        label.Margin = new Thickness(5, 0, 0, 5);
        panel.Children.Add(label);
        panel.Children.Add(content);
        return panel;
    }

    public static Button Button(string style, object content, Action click, string? tooltip = null, Thickness? padding = null)
    {
        var button = new Button { Content = content, ToolTip = tooltip };
        button.SetResourceReference(FrameworkElement.StyleProperty, style);
        if (padding is { } value) button.Padding = value;
        button.Click += (_, _) => click();
        if (tooltip is not null) System.Windows.Automation.AutomationProperties.SetName(button, tooltip);
        return button;
    }

    public static CheckBox Toggle(bool isOn, string name, Action<bool> changed)
    {
        var toggle = new CheckBox { IsChecked = isOn, VerticalAlignment = VerticalAlignment.Center };
        toggle.SetResourceReference(FrameworkElement.StyleProperty, "ToggleSwitch");
        System.Windows.Automation.AutomationProperties.SetName(toggle, name);
        toggle.Click += (_, _) => changed(toggle.IsChecked == true);
        return toggle;
    }

    public static Border Glyph(string name, double size = 28)
    {
        var (top, bottom) = Palette(name);
        return Tile(string.IsNullOrEmpty(name) ? "?" : name[..1].ToUpperInvariant(), top, bottom, size);
    }

    public static Border ToolTile(ToolId tool, double size = 26) => tool switch
    {
        ToolId.ClaudeCode => Tile("C", Rgb(232, 140, 102), Rgb(199, 97, 64), size),
        ToolId.Codex => Tile("</>", Rgb(82, 140, 255), Rgb(43, 87, 219), size, 0.36),
        ToolId.OpenCode => Tile("oc", Rgb(87, 87, 87), Rgb(41, 41, 41), size, 0.42),
        ToolId.Pi => Tile("π", Rgb(64, 199, 173), Rgb(20, 143, 128), size),
        ToolId.Grok => Tile("G", Rgb(51, 51, 51), Rgb(13, 13, 13), size),
        ToolId.Droid => Tile("D", Rgb(158, 128, 245), Rgb(102, 71, 204), size),
        _ => Tile("K", Rgb(250, 184, 69), Rgb(230, 128, 26), size),
    };

    private static Border Tile(string text, Color top, Color bottom, double size, double scale = 0.5)
    {
        var label = new TextBlock
        {
            Text = text,
            Foreground = Brushes.White,
            FontSize = size * scale,
            FontWeight = FontWeights.SemiBold,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        label.SetResourceReference(TextBlock.FontFamilyProperty, "UiFont");
        return new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size * 0.26),
            Background = new LinearGradientBrush(top, bottom, 90),
            Child = label,
        };
    }

    private static readonly (Color, Color)[] Palettes =
    [
        (Rgb(92, 140, 255), Rgb(51, 92, 230)),
        (Rgb(64, 199, 184), Rgb(20, 143, 143)),
        (Rgb(255, 158, 77), Rgb(237, 102, 41)),
        (Rgb(250, 115, 143), Rgb(214, 56, 102)),
        (Rgb(107, 204, 107), Rgb(46, 148, 77)),
        (Rgb(163, 143, 250), Rgb(107, 84, 214)),
        (Rgb(128, 135, 153), Rgb(77, 82, 97)),
    ];

    private static (Color, Color) Palette(string name) => Palettes[name.Sum(c => c) % Palettes.Length];

    private static Color Rgb(byte r, byte g, byte b) => Color.FromRgb(r, g, b);

    public static Grid Columns(params (FrameworkElement Element, GridLength Width)[] items)
    {
        var grid = new Grid();
        for (var index = 0; index < items.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = items[index].Width });
            Grid.SetColumn(items[index].Element, index);
            grid.Children.Add(items[index].Element);
        }
        return grid;
    }

    public static readonly GridLength Auto = GridLength.Auto;
    public static readonly GridLength Fill = new(1, GridUnitType.Star);

    /// <summary>界面重建时保住输入框的焦点。</summary>
    public static void KeepingFocus(Action rebuild)
    {
        var focused = Keyboard.FocusedElement as Control;
        rebuild();
        if (focused is TextBox or PasswordBox)
            focused.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Input, () => focused.Focus());
    }
}
