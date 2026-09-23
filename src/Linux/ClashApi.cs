using System.Net;
using System.Text;
using System.Text.Json;

namespace CodexSwitch.Linux;

static class ClashApi
{
    public static async Task<(string Now, IReadOnlyList<string> All)> GroupAsync(string controller, string group, CancellationToken cancellationToken)
    {
        using var doc = await GetAsync(controller, "/proxies/" + Uri.EscapeDataString(group), cancellationToken);
        var root = doc.RootElement;
        var now = root.TryGetProperty("now", out var current) ? current.GetString() ?? "" : "";
        var all = new List<string>();
        if (root.TryGetProperty("all", out var items) && items.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in items.EnumerateArray())
            {
                var name = item.GetString();
                if (!string.IsNullOrWhiteSpace(name)) all.Add(name);
            }
        }
        return (now, all);
    }

    public static async Task<int> DelayAsync(string controller, string name, int timeoutMs, CancellationToken cancellationToken)
    {
        var test = Uri.EscapeDataString("http://www.gstatic.com/generate_204");
        var path = "/proxies/" + Uri.EscapeDataString(name) + "/delay?timeout=" + timeoutMs.ToString() + "&url=" + test;
        try
        {
            using var doc = await GetAsync(controller, path, cancellationToken);
            return doc.RootElement.TryGetProperty("delay", out var delay) && delay.TryGetInt32(out var ms) ? ms : -1;
        }
        catch (Exception ex) when (ex is HttpRequestException or InvalidOperationException or TaskCanceledException or JsonException)
        {
            return -1;
        }
    }

    public static async Task SelectAsync(string controller, string group, string name, CancellationToken cancellationToken)
    {
        using var http = Client();
        var body = new StringContent(JsonSerializer.Serialize(new Dictionary<string, string> { ["name"] = name }), Encoding.UTF8, "application/json");
        using var response = await http.PutAsync(Base(controller) + "/proxies/" + Uri.EscapeDataString(group), body, cancellationToken);
        if (response.StatusCode == HttpStatusCode.NoContent || response.IsSuccessStatusCode) return;
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        throw new InvalidOperationException("切换第一跳失败：" + (string.IsNullOrWhiteSpace(text) ? response.StatusCode.ToString() : text));
    }

    public static async Task<(long Up, long Down, int Count)> TrafficAsync(string controller, CancellationToken cancellationToken)
    {
        using var doc = await GetAsync(controller, "/connections", cancellationToken);
        var root = doc.RootElement;
        static long Total(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.TryGetInt64(out var n) ? n : 0;
        var count = root.TryGetProperty("connections", out var items) && items.ValueKind == JsonValueKind.Array ? items.GetArrayLength() : 0;
        return (Total(root, "uploadTotal"), Total(root, "downloadTotal"), count);
    }

    public static async Task<string> ConnectionsAsync(string controller, CancellationToken cancellationToken)
    {
        using var doc = await GetAsync(controller, "/connections", cancellationToken);
        var root = doc.RootElement;
        if (!root.TryGetProperty("connections", out var items) || items.ValueKind != JsonValueKind.Array)
            return "当前没有活动连接。";
        var hosts = new Dictionary<string, int>(StringComparer.Ordinal);
        foreach (var item in items.EnumerateArray())
        {
            if (!item.TryGetProperty("metadata", out var meta)) continue;
            var host = meta.TryGetProperty("host", out var h) ? h.GetString() : null;
            if (string.IsNullOrWhiteSpace(host) && meta.TryGetProperty("destinationIP", out var ip)) host = ip.GetString();
            if (string.IsNullOrWhiteSpace(host)) host = "?";
            hosts[host] = hosts.GetValueOrDefault(host) + 1;
        }
        if (hosts.Count == 0) return "当前没有活动连接。";
        var lines = hosts.OrderByDescending(pair => pair.Value).Take(8).Select(pair => pair.Key + "  " + pair.Value);
        return items.GetArrayLength() + " 条连接\n" + string.Join('\n', lines);
    }

    private static async Task<JsonDocument> GetAsync(string controller, string path, CancellationToken cancellationToken)
    {
        using var http = Client();
        using var response = await http.GetAsync(Base(controller) + path, cancellationToken);
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException("外部控制没有响应：" + response.StatusCode);
        return JsonDocument.Parse(text);
    }

    private static HttpClient Client()
    {
        var http = new HttpClient(new HttpClientHandler { UseProxy = false }) { Timeout = TimeSpan.FromSeconds(3) };
        return http;
    }

    private static string Base(string controller)
    {
        var text = (controller ?? "").Trim().TrimEnd('/');
        if (text.Length == 0) throw new InvalidOperationException("没有外部控制地址。");
        return text.Contains("://", StringComparison.Ordinal) ? text : "http://" + text;
    }
}
