namespace CodexSwitch.Core;

public static class RelayImport
{
    public static string ExtractProxies(string text)
    {
        var normalized = (text ?? "").Replace("\r\n", "\n").Trim().TrimStart('\uFEFF');
        if (normalized.Length == 0) throw new InvalidOperationException("没有读到中转节点。");
        var lines = normalized.Split('\n');
        var start = -1;
        for (var i = 0; i < lines.Length; i++)
        {
            if (lines[i].Trim() is "proxies:" or "proxies: []") { start = i + 1; break; }
        }
        var body = start < 0 ? normalized : SliceUntilNextKey(lines, start);
        body = StripFullLineComments(body).Trim('\r', '\n');
        if (DialerProxyBuilder.ExtractRelayNames(body).Count == 0)
            throw new InvalidOperationException("没有读到中转节点。订阅需要直接包含 proxies 列表。");
        return body;
    }

    public static async Task<string> FromUrlAsync(string url, CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate((url ?? "").Trim(), UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            throw new InvalidOperationException("订阅需要 http 或 https 地址。");
        using var handler = new HttpClientHandler { UseProxy = false };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        using var response = await http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        while (true)
        {
            var n = await stream.ReadAsync(chunk, cancellationToken);
            if (n == 0) break;
            if (buffer.Length + n > 2_000_000) throw new InvalidOperationException("订阅内容超过 2MB。");
            buffer.Write(chunk, 0, n);
        }
        return ExtractProxies(System.Text.Encoding.UTF8.GetString(buffer.ToArray()));
    }

    private static string SliceUntilNextKey(string[] lines, int start)
    {
        var body = new List<string>();
        for (var i = start; i < lines.Length; i++)
        {
            var line = lines[i];
            if (line.Length > 0 && !char.IsWhiteSpace(line[0]) && !line.StartsWith('#') && !line.StartsWith('-')) break;
            body.Add(line);
        }
        return string.Join('\n', body);
    }

    private static string StripFullLineComments(string text)
    {
        var kept = text.Split('\n').Where(line => !line.TrimStart().StartsWith('#'));
        return string.Join('\n', kept);
    }
}
