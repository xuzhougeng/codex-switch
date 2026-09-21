import Foundation
import Darwin

public struct ClashProxyStatus: Sendable {
    public let running: Bool
    public let detail: String
    public let mihomoPid: Int32?
    public let limiterPid: Int32?
}

public actor ClashProxyRuntime {
    private let store: ClashProxyStore
    public init(store: ClashProxyStore) { self.store = store }

    public func status() async throws -> ClashProxyStatus {
        let settings = try await store.load()
        let limiterPid = Self.readPid(store.limiterPidURL)
        let mihomoPid = Self.readPid(store.mihomoPidURL)
        let limiterUp = limiterPid.map(Self.alive) ?? false
        let mihomoUp = mihomoPid.map(Self.alive) ?? false
        let port = settings.httpPort
        let limiterPort = Int(store.limiterListenPort(settings)) ?? 1994
        if limiterUp && mihomoUp {
            return ClashProxyStatus(running: true, detail: "运行中  HTTP 127.0.0.1:\(port)  限流 :\(limiterPort)", mihomoPid: mihomoPid, limiterPid: limiterPid)
        }
        if limiterUp || mihomoUp {
            return ClashProxyStatus(running: false, detail: "进程在，端口未就绪。查看 clash 目录下的日志。", mihomoPid: mihomoPid, limiterPid: limiterPid)
        }
        return ClashProxyStatus(running: false, detail: "未运行", mihomoPid: nil, limiterPid: nil)
    }

    public func start(_ settings: ClashProxySettings) async throws -> ClashProxyStatus {
        try await store.save(settings)
        try await store.materialize(settings)
        if try await status().running { return try await status() }
        try await stop()
        let python = try Self.resolve(settings.pythonPath, names: ["python3", "python"])
        let mihomo = try Self.resolve(settings.mihomoPath, names: ["mihomo", "clash"])
        let limiterPid = try Self.start(python, ["-u", store.limiterPythonURL.path, "-c", store.limiterJSONURL.path],
                                        cwd: store.workDirectory, log: store.limiterLogURL)
        try "\(limiterPid)".write(to: store.limiterPidURL, atomically: true, encoding: .utf8)
        try Self.waitListen("127.0.0.1", Int(store.limiterListenPort(settings)) ?? 1994, "本机限流器")
        let mihomoPid = try Self.start(mihomo, ["-f", store.yamlURL.path], cwd: store.workDirectory, log: store.mihomoLogURL)
        try "\(mihomoPid)".write(to: store.mihomoPidURL, atomically: true, encoding: .utf8)
        try Self.waitListen("127.0.0.1", settings.httpPort, "mihomo")
        return try await status()
    }

    public func stop() async throws {
        for url in [store.mihomoPidURL, store.limiterPidURL] {
            if let pid = Self.readPid(url) { kill(pid, SIGTERM) }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func start(_ file: String, _ args: [String], cwd: URL, log: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: file)
        process.arguments = args
        process.currentDirectoryURL = cwd
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        return process.processIdentifier
    }

    private static func waitListen(_ host: String, _ port: Int, _ label: String) throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if listening(host, port) { return }
            Thread.sleep(forTimeInterval: 0.12)
        }
        throw StoreError("\(label) 未能监听 \(host):\(port)。请确认 mihomo / python 已安装。")
    }

    private static func listening(_ host: String, _ port: Int) -> Bool {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        defer { if let info { freeaddrinfo(info) } }
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let addr = info else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0
    }

    private static func resolve(_ configured: String, names: [String]) throws -> String {
        if !configured.trimmingCharacters(in: .whitespaces).isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else { throw StoreError("找不到指定的可执行文件：\(path)") }
            return path
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in path.split(separator: ":") {
            for name in names {
                let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        throw StoreError("未在 PATH 中找到 \(names[0])。请安装后重试，或填写绝对路径。")
    }

    private static func readPid(_ url: URL) -> Int32? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }
}

private extension ClashProxyStore {
    nonisolated func limiterListenPort(_ settings: ClashProxySettings) -> String {
        String(settings.limiterListen.split(separator: ":").last ?? "1994")
    }
}
