using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Mila.Windows.Interop;
using Windows.UI;
using Windows.UI.Text;
using System.Runtime.InteropServices.WindowsRuntime;
namespace Mila.Windows;

internal static class MilaTerminalView
{
    /// <summary>
    /// @cc [owner:ghuntley,label:security;terminal] windows-terminal-display-only
    /// Render only the bounded Rust screen projection as literal text, styles and
    /// opaque RGB bitmaps. Terminal content never becomes markup, links, resource
    /// paths or diagnostics; images are created from validated pixels in memory.
    /// </summary>
    internal static void Render(RichTextBlock view, Canvas images, MilaTerminalFrame? frame, string fallback)
    {
        view.Blocks.Clear();
        view.TextHighlighters.Clear();
        images.Children.Clear();
        Paragraph paragraph = new() { Margin = new Microsoft.UI.Xaml.Thickness(0) };
        view.Blocks.Add(paragraph);
        if (frame is null) { paragraph.Inlines.Add(new Run { Text = fallback }); return; }
        int offset = 0;
        bool first = true;
        foreach (List<MilaTerminalSpan> line in frame.Lines)
        {
            if (!first) { paragraph.Inlines.Add(new LineBreak()); offset++; }
            first = false;
            foreach (MilaTerminalSpan span in line)
            {
                uint? foreground = span.Inverse ? span.Background ?? 0x181818u : span.Foreground;
                uint? background = span.Inverse ? span.Foreground ?? 0xebebebu : span.Background;
                Run run = new() { Text = span.Text, FontWeight = span.Bold ? FontWeights.Bold : FontWeights.Normal,
                    FontStyle = span.Italic ? FontStyle.Italic : FontStyle.Normal,
                    TextDecorations = span.Underline ? TextDecorations.Underline : TextDecorations.None };
                if (foreground is uint fg) run.Foreground = Brush(fg);
                paragraph.Inlines.Add(run);
                if (background is uint bg && span.Text.Length > 0)
                {
                    TextHighlighter highlight = new() { Background = Brush(bg), Foreground = Brush(foreground ?? 0xebebebu) };
                    highlight.Ranges.Add(new TextRange { StartIndex = offset, Length = span.Text.Length });
                    view.TextHighlighters.Add(highlight);
                }
                offset += span.Text.Length;
            }
        }
        images.Width = Math.Max(1, frame.Columns * 8);
        images.Height = Math.Max(1, frame.Rows * 16);
        foreach (MilaTerminalImage image in frame.Images)
        {
            WriteableBitmap bitmap = Bitmap(image);
            Image control = new() { Source = bitmap, Width = image.Width, Height = image.Height, Stretch = Stretch.None };
            Canvas.SetLeft(control, image.X);
            Canvas.SetTop(control, image.Y);
            images.Children.Add(control);
        }
    }
    private static SolidColorBrush Brush(uint rgb) => new(Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));

    private static WriteableBitmap Bitmap(MilaTerminalImage image)
    {
        WriteableBitmap bitmap = new(image.Width, image.Height);
        using Stream stream = bitmap.PixelBuffer.AsStream();
        Span<byte> bytes = stackalloc byte[4];
        foreach (uint pixel in image.Pixels)
        {
            bytes[0] = (byte)pixel;
            bytes[1] = (byte)(pixel >> 8);
            bytes[2] = (byte)(pixel >> 16);
            bytes[3] = byte.MaxValue;
            stream.Write(bytes);
        }
        bitmap.Invalidate();
        return bitmap;
    }
}
