using System.Text;
using Mila.Windows.Interop;

internal static class TerminalFrameSmoke
{
    internal static void Run()
    {
        byte[] frame = Encoding.UTF8.GetBytes("""{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[[{"text":"ok","foreground":null,"background":null,"bold":false,"italic":false,"underline":false,"inverse":false}],[]],"images":[{"x":0,"y":0,"width":2,"height":1,"pixels":[16711680,65280]}]}""");
        MilaTerminalFrame? decoded = MilaTerminalFrame.Decode(frame);
        Program.Require(decoded is { Images.Count: 1 } && decoded.Images[0].Pixels.SequenceEqual([0xff0000u, 0x00ff00u]), "terminal frame validates bounded image pixels");
        byte[] oversized = Encoding.UTF8.GetBytes("""{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":2,"height":1,"pixels":[16711680]}]}""");
        Program.Require(MilaTerminalFrame.Decode(oversized) is null, "terminal frame refuses malformed image extent");
        byte[] huge = Encoding.UTF8.GetBytes("""{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[{"x":0,"y":0,"width":1025,"height":1,"pixels":[] }]}""");
        Program.Require(MilaTerminalFrame.Decode(huge) is null, "terminal frame refuses oversized image dimensions");
        byte[] nullImage = Encoding.UTF8.GetBytes("""{"version":1,"columns":8,"rows":2,"cursor_column":0,"cursor_row":0,"lines":[],"images":[null]}""");
        Program.Require(MilaTerminalFrame.Decode(nullImage) is null, "terminal frame refuses null image entries");
        string pixels = string.Join(",", Enumerable.Repeat("0", 1024 * 513));
        string image = "{\"x\":0,\"y\":0,\"width\":1024,\"height\":513,\"pixels\":[" + pixels + "]}";
        byte[] aggregate = Encoding.UTF8.GetBytes("{\"version\":1,\"columns\":8,\"rows\":2,\"cursor_column\":0,\"cursor_row\":0,\"lines\":[],\"images\":[" + image + "," + image + "]}");
        Program.Require(MilaTerminalFrame.Decode(aggregate) is null, "terminal frame refuses the combined image pixel budget");
    }
}
