import Foundation
import Darwin

/// The unauthenticated controller and limiter only listen on this Mac.
public struct LocalEndpoint: Sendable {
    public let port: Int
    public init(_ value: String) throws {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2, ["127.0.0.1", "localhost"].contains(String(parts[0])),
              let port = Int(parts[1]), (1...65535).contains(port) else {
            throw StoreError("监听地址请使用 127.0.0.1:端口（1–65535）。")
        }
        self.port = port
    }
}

public enum RelayImport {
    public static func extractProxies(_ text: String) throws -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .newlines.union(CharacterSet(charactersIn: "\u{feff}")))
        let lines = normalized.components(separatedBy: "\n")
        if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("proxies:") && $0.trimmingCharacters(in: .whitespaces) != "proxies:" }) {
            throw StoreError("订阅需要非空的 proxies 节点列表。")
        }
        let start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "proxies:" }
        if start == nil && lines.contains(where: { $0.hasPrefix("proxy-groups:") || $0.hasPrefix("proxy-providers:") }) {
            throw StoreError("订阅需要直接包含 proxies 列表。")
        }
        var body: [String] = []
        for line in start.map({ Array(lines.dropFirst($0 + 1)) }) ?? lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { continue }
            if start != nil, let first = line.first, !first.isWhitespace, first != "-" { break }
            body.append(line)
        }
        let result = body.joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !DialerProxyBuilder.extractRelayNames(result).isEmpty else {
            throw StoreError("没有读到节点。请使用直接包含 proxies 列表的 Clash YAML 订阅。")
        }
        return result
    }

    public static func fromURL(_ value: String) async throws -> String {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw StoreError("订阅需要 http 或 https 地址。")
        }
        let data = try await ProxyHTTP.download(url, limit: 2_000_000, timeout: 20)
        guard let text = String(data: data, encoding: .utf8) else { throw StoreError("订阅不是 UTF-8 文本。") }
        return try extractProxies(text)
    }
}

public struct SocksEndpoint: Sendable {
    public let host: String
    public let port: String?
    public let username: String?
    public let password: String?
    public init(_ raw: String) throws {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Providers also commonly supply host:port:username:password. Preserve ':' in the password.
        if !text.contains("://"), !text.hasPrefix("[") {
            let parts = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 4, let port = Int(parts[1]), (1...65535).contains(port) {
                var imported = URLComponents()
                imported.scheme = "socks5"; imported.host = parts[0]; imported.port = port
                imported.user = parts[2]; imported.password = parts[3]
                guard let value = imported.string else { throw StoreError("SOCKS5 地址格式无效。") }
                text = value
            }
        }
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace }),
              let url = URLComponents(string: text.contains("://") ? text : "socks5://" + text),
              ["socks", "socks5", "socks5h"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil,
              url.port == nil || (1...65535).contains(url.port!) else {
            throw StoreError("请粘贴 socks5://用户:密码@服务器:端口，或 服务器:端口:用户:密码。")
        }
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        self.port = url.port.map(String.init)
        username = url.user; password = url.password
    }
}

enum ProxyHTTP {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config)
    }
    static func download(_ url: URL, limit: Int, timeout: TimeInterval, accept: String? = nil) async throws -> Data {
        let session = session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("codex-switch", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StoreError("下载失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard response.expectedContentLength <= limit else { throw StoreError("下载内容超过大小限制。") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw StoreError("下载内容超过大小限制。") }
            data.append(byte)
        }
        return data
    }
}

/// File-backed output avoids filling a pipe while waiting for a child process.
enum ProxyProcess {
    static func environment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !["http_proxy", "https_proxy", "all_proxy"].contains($0.key.lowercased()) }
    }
    static func launch(_ file: String, _ args: [String], cwd: URL, log: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: file)
        process.arguments = args
        process.environment = environment()
        process.currentDirectoryURL = cwd
        if !FileManager.default.fileExists(atPath: log.path) {
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
    static func run(_ file: String, _ args: [String], cwd: URL? = nil, timeout: TimeInterval = 20) async throws -> String {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let process = try launch(file, args, cwd: cwd ?? log.deletingLastPathComponent(), log: log)
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw StoreError("命令执行超时：\(URL(fileURLWithPath: file).lastPathComponent)") }
                try await Task.sleep(for: .milliseconds(80))
            }
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else { throw StoreError(text.isEmpty ? "命令执行失败（\(process.terminationStatus)）。" : text) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await terminate(process)
            throw error
        }
    }
    static func terminate(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 {
            if !process.isRunning { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
    static func resolve(_ configured: String, names: [String], extra: [String] = []) throws -> String {
        let configured = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw StoreError("找不到可执行文件：\(path)") }
            return path
        }
        for path in extra where FileManager.default.isExecutableFile(atPath: path) { return path }
        let folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":") + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        for folder in folders where !folder.isEmpty {
            for name in names {
                let path = URL(fileURLWithPath: folder).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        throw StoreError("找不到 \(names[0])。请安装或填写绝对路径。")
    }
    static func readPID(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }
    static func owns(_ pid: Int32, marker: String) async -> Bool {
        guard let args = try? await run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 2) else { return false }
        return args.contains(marker)
    }
    static func listening(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StoreError("无法分配测速端口。") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                guard bind(fd, ptr, size) == 0 else { return Int32(-1) }
                return getsockname(fd, ptr, &size)
            }
        }
        guard result == 0 else { throw StoreError("无法分配测速端口。") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

public enum ProxyLog {
    private static let problemPattern = try! NSRegularExpression(pattern: #"(?i)\b(warn(ing)?|error|fatal)\b"#)
    public static func tail(_ url: URL, problemsOnly: Bool = false) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "暂无日志。" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 131_072 ? size - 131_072 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        let filtered = problemsOnly ? lines.filter {
            problemPattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        } : lines
        let text = filtered.suffix(300).joined(separator: "\n")
        return text.isEmpty ? "暂无匹配日志。" : text
    }
}
