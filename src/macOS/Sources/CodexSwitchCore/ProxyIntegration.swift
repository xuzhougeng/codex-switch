import Foundation

public enum ProxyShell {
    public static func script(settingsURL: URL) -> String {
        """
        # Managed by Codex Switch. Re-source this file after updating it.
        _codex_switch_run() {
          local port
          port=$(/usr/bin/sed -n 's/.*"httpPort"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' \(quote(settingsURL.path)) | /usr/bin/head -n 1)
          case "$port" in ''|*[!0-9]*) echo '请先在 Codex Switch 保存代理配置。' >&2; return 1 ;; esac
          /usr/bin/nc -z -w 1 127.0.0.1 "$port" || { echo '请先在 Codex Switch 启动代理。' >&2; return 1; }
          env http_proxy="http://127.0.0.1:$port" https_proxy="http://127.0.0.1:$port" HTTP_PROXY="http://127.0.0.1:$port" HTTPS_PROXY="http://127.0.0.1:$port" "$@"
        }
        codex() { _codex_switch_run codex "$@"; }
        claude() { _codex_switch_run claude "$@"; }
        gemini() { _codex_switch_run gemini "$@"; }
        """ + "\n"
    }
    public static func install(store: ClashProxyStore, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let fm = FileManager.default
        let target = store.directory.appendingPathComponent("shell.sh")
        try fm.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try script(settingsURL: store.settingsURL).write(to: target, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let line = "source " + quote(target.path)
        for name in [".zshrc", ".bashrc", ".bash_profile"] {
            let url = userHome.appendingPathComponent(name)
            let exists = fm.fileExists(atPath: url.path)
            let previous = exists ? try String(contentsOf: url, encoding: .utf8) : ""
            if previous.components(separatedBy: "\n").contains(line) { continue }
            if exists {
                let backup = url.appendingPathExtension("codex-switch-backup-" + UUID().uuidString)
                try fm.copyItem(at: url, to: backup)
            }
            // Append through the file handle to preserve existing permissions and symlinks.
            if !exists { fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n# Codex Switch\n" + line + "\n").utf8))
        }
        return "已安装 Shell 命令。新开终端即可使用，当前终端执行：\n" + line
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Save and restore the whole proxy dictionary, including PAC, SOCKS and exception lists.
/// SystemConfiguration commits all services together, avoiding partially applied networksetup commands.
public actor MacSystemProxy {
    private let store: ClashProxyStore
    private let executable: String
    public init(store: ClashProxyStore, executable: String = CommandLine.arguments[0]) {
        self.store = store; self.executable = URL(fileURLWithPath: executable).standardizedFileURL.path
    }
    private var snapshotURL: URL { store.directory.appendingPathComponent("system-proxy-backup.json") }
    public var hasBackup: Bool { FileManager.default.fileExists(atPath: snapshotURL.path) }
    public func isEnabled(port: Int) -> Bool {
        guard hasBackup, let services = try? SystemProxyPreferences.read(), !services.isEmpty else { return false }
        return services.allSatisfy { service in
            guard let data = service.configuration,
                  let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
            return (config["HTTPEnable"] as? Int) == 1 && (config["HTTPSEnable"] as? Int) == 1
                && (config["HTTPProxy"] as? String) == "127.0.0.1" && (config["HTTPSProxy"] as? String) == "127.0.0.1"
                && (config["HTTPPort"] as? Int) == port && (config["HTTPSPort"] as? Int) == port
        }
    }
    private func authorize(action: String, port: Int = 0) async throws {
        let command = [executable, "--system-proxy", action, "--snapshot", snapshotURL.path, "--owner", String(getuid()), "--port", String(port)]
            .map(ProxyShell.quote).joined(separator: " ")
        let literal = "\"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        _ = try await ProxyProcess.run("/usr/bin/osascript", ["-e", "do shell script " + literal + " with administrator privileges"], timeout: 180)
    }
    public func enable(port: Int) async throws {
        guard (1...65535).contains(port), ProxyProcess.listening(port) else { throw StoreError("请先启动代理，再开启系统代理。") }
        if !hasBackup {
            let original = try SystemProxyPreferences.read()
            guard !original.isEmpty else { throw StoreError("没有可用的网络服务。") }
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(original).write(to: snapshotURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        }
        try await authorize(action: "enable", port: port)
    }
    public func disable() async throws {
        guard hasBackup else { return }
        try await authorize(action: "restore")
        try FileManager.default.removeItem(at: snapshotURL)
    }
}
