import XCTest
@testable import CodexSwitchCore

final class ProxyLogTests: XCTestCase {
    func testEntriesParseKernelAndServiceLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch-log-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = [
            #"time="2026-10-14T08:15:30.123456+08:00" level=info msg="[TCP] 127.0.0.1:52311 --> api.openai.com:443 match DomainSuffix openai.com using AI工具""#,
            #"time="2026-10-14T08:15:31.000000+08:00" level=warning msg="\"quoted\" and \\ backslash""#,
            "08:15:32 INFO service started",
            "continuation line",
            #"time="2026-10-14T08:15:33.000000+08:00" level=error msg="dial failed""#
        ].joined(separator: "\n")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let entries = ProxyLog.entries(url)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].time, "08:15:30")
        XCTAssertEqual(entries[0].level, "INFO")
        // The loopback client prefix is display noise; the routing answer stays.
        XCTAssertEqual(entries[0].message, "[TCP] api.openai.com:443 match DomainSuffix openai.com using AI工具")
        XCTAssertEqual(entries[1].level, "WARN")
        XCTAssertEqual(entries[1].message, #""quoted" and \ backslash"#)
        XCTAssertEqual(entries[2].time, "08:15:32")
        XCTAssertEqual(entries[2].message, "service started\ncontinuation line")
        XCTAssertEqual(entries[3].level, "ERROR")
        XCTAssertEqual(entries[3].message, "dial failed")
    }

    func testEntriesMissingFileIsEmpty() {
        XCTAssertTrue(ProxyLog.entries(URL(fileURLWithPath: "/nonexistent/codex-switch.log")).isEmpty)
    }
}
