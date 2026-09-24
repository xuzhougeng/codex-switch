using System.Text;
using System.Text.RegularExpressions;

namespace CodexSwitch.Core;

public sealed record LogEntry(string Time, string Level, string Message);

// Turns service.log / limiter.log ("HH:mm:ss LEVEL msg") and mihomo.log (logfmt) into rows for display.
public static class LogTail
{
    private static readonly Regex Ours = new(@"^(\d\d:\d\d:\d\d) ([A-Z]+) ?(.*)$");
    private static readonly Regex Kernel = new(@"^time=""[^""]*T(\d\d:\d\d:\d\d)[^""]*"" level=(\w+) msg=""(.*)""$");

    // Only the end of the file: mihomo logs every connection, so the logs grow without bound.
    public static List<string> ReadLines(string path, int maxBytes = 256 * 1024)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var cut = file.Length > maxBytes;
        if (cut) file.Seek(-maxBytes, SeekOrigin.End);
        using var reader = new StreamReader(file, Encoding.UTF8);
        if (cut) reader.ReadLine();
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return lines;
    }

    // A line with no timestamp continues the entry above it (multi-line errors in service.log).
    public static List<LogEntry> Parse(IEnumerable<string> lines)
    {
        var entries = new List<LogEntry>();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd();
            if (line.Length == 0) continue;
            var kernel = Kernel.Match(line);
            var ours = Ours.Match(line);
            if (kernel.Success)
                entries.Add(new(kernel.Groups[1].Value, Level(kernel.Groups[2].Value), Regex.Replace(kernel.Groups[3].Value, @"\\([""\\])", "$1")));
            else if (ours.Success)
                entries.Add(new(ours.Groups[1].Value, Level(ours.Groups[2].Value), ours.Groups[3].Value));
            else if (entries.Count > 0)
                entries[^1] = entries[^1] with { Message = entries[^1].Message + "\n" + line };
            else
                entries.Add(new("", "", line));
        }
        return entries;
    }

    private static string Level(string level) => level.ToUpperInvariant() switch
    {
        "WARNING" => "WARN",
        "FATAL" or "PANIC" => "ERROR",
        var other => other
    };
}
