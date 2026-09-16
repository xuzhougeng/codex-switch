import Foundation
import Darwin

public enum BrowserLogin {
    public static func findCLI() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent("codex") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static func run(store: AccountStore) async throws {
        guard let cli = findCLI() else { throw StoreError("未找到 Codex CLI。请先安装 CLI，再点击登录新账号。") }
        let staging = store.directory.appendingPathComponent(".login-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = cli
        process.arguments = ["-c", "cli_auth_credentials_store='file'", "login"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = staging.path
        // GUI apps launched by Finder do not inherit a shell's PATH (npm CLI needs node).
        environment["PATH"] = [cli.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        defer { try? FileManager.default.removeItem(at: staging) }
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(600)
            while process.isRunning {
                try Task.checkCancellation()
                if Date() >= deadline { throw StoreError("等待登录超时，原账号已保留。") }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            try Task.checkCancellation()
            let auth = staging.appendingPathComponent("auth.json")
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: auth.path) else {
                throw StoreError("登录未完成，原账号已保留。请重试并在浏览器完成登录。")
            }
            try await store.importLogin(Data(contentsOf: auth))
        } catch {
            if process.isRunning {
                process.terminate()
                // Bound cancellation even if the owned CLI ignores SIGTERM.
                for _ in 0..<20 {
                    if !process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            throw error
        }
    }
}
