namespace CodexSwitch.Core;

public readonly record struct SocksEndpoint(string Host, string? Port, string? Username, string? Password)
{
    public static bool TryParse(string raw, out SocksEndpoint parsed)
    {
        parsed = default;
        var text = (raw ?? "").Trim();
        if (text.Length == 0 || text.Contains(' ')) return false;
        if (text.StartsWith("socks5://", StringComparison.OrdinalIgnoreCase)) text = text[9..];
        else if (text.StartsWith("socks://", StringComparison.OrdinalIgnoreCase)) text = text[8..];
        string? user = null;
        string? pass = null;
        var at = text.LastIndexOf('@');
        var hostport = text;
        if (at >= 0)
        {
            var auth = text[..at];
            hostport = text[(at + 1)..];
            var split = auth.IndexOf(':');
            if (split >= 0)
            {
                user = Uri.UnescapeDataString(auth[..split]);
                pass = Uri.UnescapeDataString(auth[(split + 1)..]);
            }
            else user = Uri.UnescapeDataString(auth);
        }
        string host;
        string? port = null;
        if (hostport.StartsWith('[') && hostport.Contains(']'))
        {
            var end = hostport.IndexOf(']');
            host = hostport[1..end];
            if (end + 2 < hostport.Length && hostport[end + 1] == ':') port = hostport[(end + 2)..];
        }
        else
        {
            var colon = hostport.LastIndexOf(':');
            if (colon > 0 && int.TryParse(hostport[(colon + 1)..], out var number) && number is >= 1 and <= 65535 && !hostport[..colon].Contains(':'))
            {
                host = hostport[..colon];
                port = number.ToString();
            }
            else host = hostport;
        }
        if (host.Length == 0) return false;
        parsed = new SocksEndpoint(host, port, user, pass);
        return true;
    }
}
