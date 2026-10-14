import Foundation

public struct ProxyConnections: Decodable, Equatable, Sendable {
    public struct Connection: Decodable, Identifiable, Equatable, Sendable {
        public struct Metadata: Decodable, Equatable, Sendable {
            public let host: String?
            public let destinationIP: String?
            public let network: String?
        }
        public let id: String
        public let metadata: Metadata
        public let upload: Int64?
        public let download: Int64?
        public let chains: [String]?
        public var destination: String { metadata.host.flatMap { $0.isEmpty ? nil : $0 } ?? metadata.destinationIP ?? "未知" }
    }
    public let uploadTotal: Int64
    public let downloadTotal: Int64
    public let connections: [Connection]?
}

public struct ClashAPI: Sendable {
    private static let session = ProxyHTTP.session()
    public struct Group: Decodable, Equatable, Sendable {
        public let now: String?
        public let all: [String]?
    }
    public let controller: String
    public init(controller: String) { self.controller = controller }
    func url(_ path: [String], query: [URLQueryItem] = []) throws -> URL {
        let endpoint = try LocalEndpoint(controller)
        var components = URLComponents()
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = endpoint.port
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        components.percentEncodedPath = "/" + path.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw StoreError("控制地址无效。") }
        return url
    }
    private func request(_ path: [String], method: String = "GET", body: Data? = nil,
                         query: [URLQueryItem] = [], timeout: TimeInterval = 3) async throws -> Data {
        var request = URLRequest(url: try url(path, query: query), timeoutInterval: timeout)
        request.httpMethod = method; request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await Self.session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw StoreError("mihomo 控制请求失败：HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
    public func group(_ name: String) async throws -> Group {
        try JSONDecoder().decode(Group.self, from: await request(["proxies", name]))
    }
    public func select(group: String, name: String) async throws {
        _ = try await request(["proxies", group], method: "PUT", body: JSONEncoder().encode(["name": name]))
    }
    public func connections() async throws -> ProxyConnections {
        try JSONDecoder().decode(ProxyConnections.self, from: await request(["connections"]))
    }
    public func delay(name: String, target: String, timeoutMs: Int = 5000) async throws -> Int {
        do {
            struct Delay: Decodable { let delay: Int }
            let data = try await request(["proxies", name, "delay"], query: [
                URLQueryItem(name: "timeout", value: String(timeoutMs)), URLQueryItem(name: "url", value: target)
            ], timeout: Double(timeoutMs) / 1000 + 1)
            return try JSONDecoder().decode(Delay.self, from: data).delay
        } catch {
            try Task.checkCancellation()
            return -1
        }
    }
}

public enum ProxyRoute: String, Sendable, CaseIterable { case relay, exit }

public enum ProxyProbe {
    /// A separate kernel and cache ensure measuring a node never switches live traffic.
    public static func run(store: ClashProxyStore, settings: ClashProxySettings, route: ProxyRoute,
                           only: String? = nil, progress: @escaping @Sendable (String, Int) async -> Void) async throws -> [String: Int] {
        let all = DialerProxyBuilder.extractRelayNames(settings.relayYaml)
        let candidates = route == .relay ? all : DialerProxyBuilder.withoutHongKong(all)
        let names = only.map { candidates.contains($0) ? [$0] : [] } ?? candidates
        guard !names.isEmpty else { throw StoreError(route == .exit ? "订阅中没有非香港节点。" : "订阅中没有节点。") }
        let kernel = try MihomoKernel.resolve(settings, store: store)
        let controller = "127.0.0.1:\(try ProxyProcess.freePort())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let yaml = directory.appendingPathComponent("probe.yaml")
        try DialerProxyBuilder.buildProbe(store.input(settings), controller: controller, chain: route == .relay)
            .write(to: yaml, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: yaml.path)
        let process = try ProxyProcess.launch(kernel, ["-d", directory.path, "-f", yaml.path], cwd: directory, log: directory.appendingPathComponent("probe.log"))
        let api = ClashAPI(controller: controller)
        let map = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($0.element, route == .relay ? DialerProxyBuilder.probeName($0.offset) : $0.element) })
        do {
            let deadline = Date().addingTimeInterval(12)
            while true {
                try Task.checkCancellation()
                guard process.isRunning else { throw StoreError("测速内核启动失败：\n" + ProxyLog.tail(directory.appendingPathComponent("probe.log"))) }
                do { _ = try await api.group(map[names.last!]!); break }
                catch {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw StoreError("测速内核没有就绪。请检查节点 YAML 和内核。") }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let target = route == .relay ? "http://www.gstatic.com/generate_204" : DialerProxyBuilder.exitTestURL
            let results = try await withThrowingTaskGroup(of: (String, Int).self) { group in
                var iterator = names.makeIterator()
                func submit(_ name: String) {
                    group.addTask { (name, try await api.delay(name: map[name]!, target: target)) }
                }
                for _ in 0..<min(4, names.count) { submit(iterator.next()!) }
                var delays: [String: Int] = [:]
                while let (name, delay) = try await group.next() {
                    delays[name] = delay
                    await progress(name, delay)
                    if let next = iterator.next() { submit(next) }
                }
                return delays
            }
            await ProxyProcess.terminate(process)
            return results
        } catch {
            await ProxyProcess.terminate(process)
            throw error
        }
    }
}
