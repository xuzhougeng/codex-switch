import Foundation
import CryptoKit

public enum MihomoKernel {
    public static func resolve(_ settings: ClashProxySettings, store: ClashProxyStore) throws -> String {
        try ProxyProcess.resolve(settings.mihomoPath, names: ["mihomo"], extra: [
            store.kernelDirectory.appendingPathComponent("mihomo").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo").path
        ])
    }
    public static func version(_ settings: ClashProxySettings, store: ClashProxyStore) async throws -> String {
        try await ProxyProcess.run(resolve(settings, store: store), ["-v"], timeout: 5)
    }
    public static func check(_ settings: ClashProxySettings, store: ClashProxyStore) async throws -> String {
        let files = try DialerProxyBuilder.build(store.input(settings))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let yaml = directory.appendingPathComponent("check.yaml")
        try files.yaml.write(to: yaml, atomically: true, encoding: .utf8)
        return try await ProxyProcess.run(resolve(settings, store: store), ["-d", directory.path, "-f", yaml.path, "-t"], cwd: directory)
    }
    public static func installLatest(store: ClashProxyStore) async throws -> String {
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL; let url: URL; let digest: String? }
            let tag_name: String
            let assets: [Asset]
        }
        let data = try await ProxyHTTP.download(URL(string: "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest")!, limit: 5_000_000, timeout: 30)
        let release = try JSONDecoder().decode(Release.self, from: data)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64-compatible"
        #endif
        guard let asset = release.assets.first(where: { $0.name == "mihomo-darwin-\(arch)-\(release.tag_name).gz" }),
              asset.browser_download_url.scheme == "https", asset.browser_download_url.host == "github.com", asset.url.scheme == "https", asset.url.host == "api.github.com" else {
            throw StoreError("最新版本没有适合当前 Mac 的 mihomo 内核。")
        }
        let packed = try await ProxyHTTP.download(asset.url, limit: 100_000_000, timeout: 300, accept: "application/octet-stream")
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let actual = SHA256.hash(data: packed).map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:" + actual else { throw StoreError("内核下载校验失败，未替换原文件。") }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: store.kernelDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = store.kernelDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("mihomo.gz")
        try packed.write(to: archive)
        _ = try await ProxyProcess.run("/usr/bin/gzip", ["-d", archive.path])
        let binary = temporary.appendingPathComponent("mihomo")
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let version = try await ProxyProcess.run(binary.path, ["-v"], timeout: 5)
        guard version.split(whereSeparator: \.isWhitespace).contains(Substring(release.tag_name)) else {
            throw StoreError("下载的内核版本与发布版本不一致，未替换原文件。")
        }
        let target = store.kernelDirectory.appendingPathComponent("mihomo")
        // Atomic replacement keeps the currently running executable intact until restart.
        guard rename(binary.path, target.path) == 0 else { throw StoreError("无法保存下载的内核。") }
        return version
    }
}
