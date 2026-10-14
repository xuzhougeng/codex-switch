import Foundation
import SystemConfiguration
import Darwin

public enum SystemProxyPreferences {
    struct Service: Codable {
        let id: String
        let configuration: Data?
        let enabled: Bool
    }
    static func preferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "Codex Switch" as CFString, nil) else { throw StoreError("无法读取系统网络配置。") }
        return preferences
    }
    static func read() throws -> [Service] {
        let prefs = try preferences()
        guard let set = SCNetworkSetCopyCurrent(prefs), let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw StoreError("无法读取当前网络位置。")
        }
        return try services.filter { SCNetworkServiceGetEnabled($0) }.compactMap { service in
            guard let id = SCNetworkServiceGetServiceID(service),
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return nil }
            let config = SCNetworkProtocolGetConfiguration(proto)
            let data = try config.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
            return Service(id: id as String, configuration: data, enabled: SCNetworkProtocolGetEnabled(proto))
        }
    }
    static func managedConfiguration(original: [String: Any], port: Int) -> [String: Any] {
        var result: [String: Any] = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
            "SOCKSEnable": 0, "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        for key in ["ExceptionsList", "ExcludeSimpleHostnames"] { result[key] = original[key] }
        return result
    }
    /// Runs only through the user-approved administrator prompt; never launches the UI as root.
    public static func runHelper(arguments: [String]) throws {
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        guard geteuid() == 0, let action = value("--system-proxy"), ["enable", "restore"].contains(action),
              let path = value("--snapshot"), let owner = value("--owner").flatMap(UInt32.init), owner > 0,
              let port = value("--port").flatMap(Int.init), action == "restore" || (1...65535).contains(port) else {
            throw StoreError("系统代理操作参数无效或尚未授权。")
        }
        // Open without following a symlink; read and validate the same file descriptor.
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw StoreError("无法读取系统代理恢复文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & 0o077 == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_size < 1_000_000 else { throw StoreError("系统代理恢复文件权限无效。") }
        let services = try JSONDecoder().decode([Service].self, from: handle.readToEnd() ?? Data())
        guard !services.isEmpty else { throw StoreError("系统代理恢复文件为空。") }
        let prefs = try preferences()
        guard SCPreferencesLock(prefs, true) else { throw StoreError("无法锁定系统网络设置。") }
        defer { SCPreferencesUnlock(prefs) }
        for entry in services {
            // A service may have been removed since the snapshot was saved.
            guard let service = SCNetworkServiceCopy(prefs, entry.id as CFString),
                  let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            let original = try entry.configuration.map { try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? nil
            let config = action == "enable" ? managedConfiguration(original: original ?? [:], port: port) : original
            guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary?),
                  SCNetworkProtocolSetEnabled(proto, action == "enable" || entry.enabled) else { throw StoreError("无法更新系统代理设置。") }
        }
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
            throw StoreError("系统代理设置未完全应用，请点击恢复系统代理后重试。")
        }
    }
}
