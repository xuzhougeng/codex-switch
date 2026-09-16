import XCTest
@testable import CodexSwitchCore

final class AccountStoreTests: XCTestCase {
    func auth(_ email: String, refresh: String = "original") throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": email, "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: ["tokens": ["id_token": "test.\(payload).not-real", "access_token": "synthetic-only", "account_id": email], "last_refresh": refresh])
    }
    func testSwitchPreservesRefreshAndRemoveKeepsCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(home: root)
        try await store.importLogin(auth("first@example.com"))
        try await store.importLogin(auth("second@example.com"))
        let refreshed = try auth("second@example.com", refresh: "refreshed")
        try refreshed.write(to: root.appendingPathComponent("auth.json"))
        try await store.switchAccount("first@example.com")
        let first = try await store.read()
        XCTAssertEqual(first.current?.email, "first@example.com")
        try await store.switchAccount("second@example.com")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("auth.json")), refreshed)
        try await store.remove("second@example.com")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("auth.json")), refreshed)
        try await store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("auth.json").path))
        let cleared = try await store.read()
        XCTAssertTrue(cleared.accounts.contains { $0.email == "second@example.com" })
    }
    func testFailedImportAndCorruptIndexDoNotOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(home: root)
        let original = try auth("first@example.com")
        try await store.importLogin(original)
        do { try await store.importLogin(Data("{}".utf8)); XCTFail("Invalid auth accepted") } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("auth.json")), original)
        let index = root.appendingPathComponent("codex-switch/accounts.json")
        try Data("invalid".utf8).write(to: index)
        do { _ = try await store.read(); XCTFail("Corrupt index accepted") } catch { }
        XCTAssertEqual(try String(contentsOf: index), "invalid")
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("auth.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
}
