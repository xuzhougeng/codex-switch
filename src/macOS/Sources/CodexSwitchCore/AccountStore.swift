import Foundation
import Darwin

public struct Account: Identifiable, Equatable, Sendable {
    public let id: String
    public let email: String
    public let plan: String
    public let accountID: String
    public var isCurrent = false
    public var subtitle: String { plan + (isCurrent ? " · 当前使用中" : " · 已保存到本机") }
}

public struct StoreState: Sendable {
    public let current: Account?
    public let accounts: [Account]
}

public struct StoreError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public actor AccountStore {
    public nonisolated let home: URL
    public nonisolated var directory: URL { home.appendingPathComponent("codex-switch", isDirectory: true) }
    private var authURL: URL { home.appendingPathComponent("auth.json") }
    private var indexURL: URL { directory.appendingPathComponent("accounts.json") }
    private let fm = FileManager.default

    public init(home: URL? = nil) {
        self.home = home ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent(".native.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw StoreError("无法打开账号存储。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw StoreError("另一个账号操作正在进行，请稍后刷新。") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError("账号文件格式无效，请从备份恢复后重试。")
        }
        return value
    }

    public static func parseAuth(_ data: Data) throws -> Account {
        guard let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any], let jwt = tokens["id_token"] as? String,
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw StoreError("无法读取 ChatGPT 登录信息。请使用 Codex CLI 登录，并使用文件凭据存储。")
        }
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw StoreError("登录令牌格式无效。") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let email = claims["email"] as? String, !email.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw StoreError("无法从登录信息解析邮箱。")
        }
        let extra = claims["https://api.openai.com/auth"] as? [String: Any]
        return Account(id: email, email: email, plan: extra?["chatgpt_plan_type"] as? String ?? "unknown",
                       accountID: tokens["account_id"] as? String ?? "", isCurrent: true)
    }

    private func row(_ key: String, _ value: Any) throws -> Account {
        guard let value = value as? [String: Any] else { throw StoreError("账号索引包含无效记录。") }
        return Account(id: key, email: value["email"] as? String ?? key, plan: value["plan"] as? String ?? "unknown",
                       accountID: value["account_id"] as? String ?? "")
    }
    private func same(_ a: Account, _ b: Account) -> Bool {
        a.email.lowercased() == b.email.lowercased() && (a.accountID.isEmpty || b.accountID.isEmpty || a.accountID == b.accountID)
    }
    private func current() throws -> Account? {
        fm.fileExists(atPath: authURL.path) ? try Self.parseAuth(Data(contentsOf: authURL)) : nil
    }
    private func metadata(_ a: Account, _ data: Data) throws -> [String: Any] {
        ["email": a.email, "plan": a.plan, "account_id": a.accountID,
         "last_refresh": try object(data)["last_refresh"] ?? "",
         "saved_at": ISO8601DateFormatter().string(from: Date()), "legacy_names": [String]()]
    }
    private func load() throws -> [String: Any] {
        if fm.fileExists(atPath: indexURL.path) { return try object(Data(contentsOf: indexURL)) }
        let legacy = home.appendingPathComponent("codex-switch-app/config/accounts.json")
        if fm.fileExists(atPath: legacy.path) { return try object(Data(contentsOf: legacy)) }
        var index: [String: Any] = [:]
        for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where folder.lastPathComponent.contains("@") {
            let file = folder.appendingPathComponent("auth.json")
            if fm.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                index[folder.lastPathComponent] = try metadata(Self.parseAuth(data), data)
            }
        }
        return index
    }

    public func read() throws -> StoreState {
        try locked {
            let active = try current()
            let accounts = try load().map { key, value -> Account in
                var a = try row(key, value)
                a.isCurrent = active.map { same(a, $0) } ?? false
                return a
            }.sorted { a, b in a.isCurrent != b.isCurrent ? a.isCurrent : a.email < b.email }
            return StoreState(current: active, accounts: accounts)
        }
    }

    private func accountDirectory(_ name: String) throws -> URL {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let safe = name.unicodeScalars.map { invalid.contains($0) ? "_" : String($0) }.joined()
        guard !safe.isEmpty, !safe.hasPrefix("."), !safe.hasSuffix("."), !safe.hasSuffix(" "),
              safe.lowercased() != "backups" else { throw StoreError("账号目录名称无效。") }
        let path = directory.appendingPathComponent(safe, isDirectory: true)
        if fm.fileExists(atPath: path.path), (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw StoreError("账号目录不能是符号链接。")
        }
        return path
    }

    private func snapshot(_ key: String, _ value: Any) throws -> URL {
        guard let value = value as? [String: Any] else { throw StoreError("账号索引包含无效记录。") }
        let names = [key, value["email"] as? String ?? key] + (value["legacy_names"] as? [String] ?? [])
        for name in names where !name.isEmpty {
            let path = try accountDirectory(name).appendingPathComponent("auth.json")
            if fm.fileExists(atPath: path.path) { return path }
        }
        throw StoreError("已保存的登录文件不存在，请重新登录该账号。")
    }

    private func atomic(_ data: Data, to path: URL) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = path.deletingLastPathComponent().appendingPathComponent(".tmp-" + UUID().uuidString)
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw StoreError("无法创建登录文件。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: temp) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, path.path) == 0 else { throw StoreError("无法更新登录文件，请检查目录权限。") }
    }
    private func writeIndex(_ index: [String: Any]) throws { try atomic(JSONSerialization.data(withJSONObject: index, options: [.sortedKeys]), to: indexURL) }

    private func save(_ index: inout [String: Any], _ data: Data) throws {
        let account = try Self.parseAuth(data)
        var key = account.email
        for (k, value) in index { if try same(row(k, value), account) { key = k; break } }
        if let existing = index[key], try !same(row(key, existing), account) {
            throw StoreError("同一邮箱存在不同工作区的登录，请先移除旧快照再保存。")
        }
        var value = try metadata(account, data)
        if let old = index[key] as? [String: Any] { value["legacy_names"] = old["legacy_names"] ?? [String]() }
        try atomic(data, to: accountDirectory(key).appendingPathComponent("auth.json"))
        index[key] = value
        try writeIndex(index)
    }
    public func saveCurrent() throws {
        try locked {
            guard fm.fileExists(atPath: authURL.path) else { throw StoreError("未找到文件登录，请先登录新账号。") }
            var index = try load()
            try save(&index, Data(contentsOf: authURL))
        }
    }
    private func preserve(_ index: inout [String: Any]) throws {
        if fm.fileExists(atPath: authURL.path) { try save(&index, Data(contentsOf: authURL)) }
    }
    private func backup(_ reason: String) throws {
        if fm.fileExists(atPath: authURL.path) {
            try atomic(Data(contentsOf: authURL), to: directory.appendingPathComponent("backups/auth-\(UUID().uuidString)-\(reason).json"))
        }
    }
    public func switchAccount(_ key: String) throws {
        try locked {
            var index = try load()
            guard let value = index[key] else { throw StoreError("未找到账号，请刷新。") }
            let data = try Data(contentsOf: snapshot(key, value))
            let target = try Self.parseAuth(data)
            guard try same(target, row(key, value)) else { throw StoreError("登录快照与账号索引不一致，请重新保存。") }
            if let active = try current(), same(active, target) { return }
            try preserve(&index)
            try backup("switch")
            try atomic(data, to: authURL)
        }
    }
    public func importLogin(_ data: Data) throws {
        _ = try Self.parseAuth(data)
        try locked {
            var index = try load()
            try preserve(&index)
            try backup("login")
            try save(&index, data)
            try atomic(data, to: authURL)
        }
    }
    public func clear() throws {
        try locked {
            var index = try load()
            try preserve(&index)
            try backup("clear")
            if fm.fileExists(atPath: authURL.path) { try fm.removeItem(at: authURL) }
        }
    }
    public func remove(_ key: String) throws {
        try locked {
            var index = try load()
            guard let value = index[key] else { throw StoreError("未找到账号，请刷新。") }
            if let file = try? snapshot(key, value) {
                try atomic(Data(contentsOf: file), to: directory.appendingPathComponent("backups/removed-\(UUID().uuidString).json"))
                try fm.removeItem(at: file)
            }
            index.removeValue(forKey: key)
            try writeIndex(index)
        }
    }
}
