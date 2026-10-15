import XCTest
@testable import CodexSwitchCore

final class ConnectionTrackerTests: XCTestCase {
    private func connection(_ id: String, host: String, up: Int64, down: Int64, chains: [String],
                            rule: String = "DomainSuffix", payload: String = "openai.com",
                            network: String = "tcp", process: String? = nil) -> ProxyConnections.Connection {
        ProxyConnections.Connection(
            id: id,
            metadata: .init(host: host.isEmpty ? nil : host, destinationIP: host.isEmpty ? "1.1.1.1" : nil,
                            network: network, type: nil, sourceIP: nil, sourcePort: nil,
                            destinationPort: "443", process: process, processPath: nil),
            upload: up, download: down, chains: chains, rule: rule, rulePayload: payload, start: nil)
    }

    private func snapshot(_ items: [ProxyConnections.Connection], up: Int64 = 0, down: Int64 = 0) -> ProxyConnections {
        ProxyConnections(uploadTotal: up, downloadTotal: down, connections: items)
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testRatesAndRowsFollowSuccessiveSnapshots() {
        var tracker = ConnectionTracker()
        let first = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 1000, down: 5000, chains: ["AI工具", "US / #1"], process: "codex")], up: 2000, down: 10_000), at: base)
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertEqual(first.rows[0].rateUp, 0)
        XCTAssertEqual(first.rows[0].exit, "US / #1")
        XCTAssertEqual(first.rows[0].process, "codex")
        XCTAssertEqual(first.rows[0].rule, "DomainSuffix openai.com")
        XCTAssertTrue(first.rows[0].isDirect == false)

        let second = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 2000, down: 15_000, chains: ["AI工具", "US / #1"])], up: 3000, down: 20_000), at: base.addingTimeInterval(1))
        XCTAssertEqual(second.rateUp, 1000)
        XCTAssertEqual(second.rateDown, 10_000)
        XCTAssertEqual(second.rows[0].rateUp, 1000)
        XCTAssertEqual(second.rows[0].rateDown, 10_000)
        XCTAssertEqual(second.rows[0].age, 1, accuracy: 0.001)
    }

    func testClosedConnectionIsFinalizedExactlyOnce() {
        var tracker = ConnectionTracker()
        _ = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 2000, down: 15_000, chains: ["AI工具", "US / #1"])]), at: base)
        let closed = tracker.ingest(snapshot([]), at: base.addingTimeInterval(1))
        XCTAssertEqual(closed.rows.count, 0)
        XCTAssertEqual(closed.sessionUp, 2000)
        XCTAssertEqual(closed.sessionDown, 15_000)
        XCTAssertEqual(closed.byHost.first?.host, "api.openai.com")
        XCTAssertEqual(closed.byHost.first?.opened, 1)
        XCTAssertEqual(closed.byHost.first?.active, 0)

        // A later empty snapshot must not count the finished bytes again.
        let again = tracker.ingest(snapshot([]), at: base.addingTimeInterval(2))
        XCTAssertEqual(again.sessionUp, 2000)
        XCTAssertEqual(again.sessionDown, 15_000)
        XCTAssertEqual(again.byHost.first?.opened, 1)
    }

    func testHostAndExitAggregation() {
        var tracker = ConnectionTracker()
        let snapshot = snapshot([
            connection("a", host: "api.openai.com", up: 100, down: 900, chains: ["AI工具", "节点一"]),
            connection("b", host: "api.openai.com", up: 10, down: 90, chains: ["AI工具", "节点二"]),
            connection("c", host: "192.168.1.10", up: 1, down: 9, chains: ["DIRECT"], rule: "IP-CIDR", payload: "192.168.0.0/16")
        ])
        let traffic = tracker.ingest(snapshot, at: base)
        let openai = traffic.byHost.first { $0.host == "api.openai.com" }
        XCTAssertEqual(openai?.opened, 2)
        XCTAssertEqual(openai?.active, 2)
        XCTAssertEqual(openai?.upload, 110)
        XCTAssertEqual(openai?.download, 990)
        XCTAssertEqual(Set(openai?.exits ?? []), ["节点一", "节点二"])
        XCTAssertEqual(openai?.rule, "DomainSuffix openai.com")

        let direct = traffic.byExit.first { $0.exit == "DIRECT" }
        XCTAssertEqual(direct?.opened, 1)
        XCTAssertEqual(direct?.download, 9)
        XCTAssertEqual(direct?.hosts, ["192.168.1.10"])
        // Exit rows rank by cumulative traffic: 节点一 1000 > 节点二 100 > DIRECT 10.
        XCTAssertEqual(traffic.byExit.map(\.exit), ["节点一", "节点二", "DIRECT"])
    }

    func testKernelRestartKeepsSessionTotals() {
        var tracker = ConnectionTracker()
        _ = tracker.ingest(snapshot([connection("old", host: "api.openai.com", up: 2000, down: 15_000, chains: ["AI工具", "US / #1"])], up: 2500, down: 16_000), at: base)
        // Restart: every id is new and the kernel counters reset to smaller values.
        let after = tracker.ingest(snapshot([connection("new", host: "github.com", up: 5, down: 50, chains: ["开发出口", "HK-1"])], up: 10, down: 100), at: base.addingTimeInterval(2))
        XCTAssertEqual(after.rateUp, 0)
        XCTAssertEqual(after.rateDown, 0)
        XCTAssertEqual(after.sessionUp, 2005)
        XCTAssertEqual(after.sessionDown, 15_050)
        XCTAssertEqual(after.byHost.count, 2)
    }

    func testMarkStoppedFinalizesRowsAndKeepsHistory() {
        var tracker = ConnectionTracker()
        _ = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 2000, down: 15_000, chains: ["AI工具", "US / #1"])]), at: base)
        tracker.markStopped()
        let traffic = tracker.snapshot()
        XCTAssertEqual(traffic.rows.count, 0)
        XCTAssertEqual(traffic.rateUp, 0)
        XCTAssertEqual(traffic.sessionDown, 15_000)
        XCTAssertEqual(traffic.byHost.first?.active, 0)
    }

    func testClearResetsEverything() {
        var tracker = ConnectionTracker()
        _ = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 2000, down: 15_000, chains: ["AI工具", "US / #1"])]), at: base)
        tracker.clear()
        let traffic = tracker.ingest(snapshot([], up: 10, down: 10), at: base.addingTimeInterval(1))
        XCTAssertEqual(traffic.sessionUp, 0)
        XCTAssertTrue(traffic.byHost.isEmpty)
    }

    func testHostRefinementAfterDNSDoesNotDoubleCount() {
        var tracker = ConnectionTracker()
        // First poll: only an IP is known. Second poll: the host resolved.
        _ = tracker.ingest(snapshot([connection("a", host: "", up: 10, down: 10, chains: ["AI工具", "US / #1"])]), at: base)
        let refined = tracker.ingest(snapshot([connection("a", host: "api.openai.com", up: 20, down: 20, chains: ["AI工具", "US / #1"])]), at: base.addingTimeInterval(1))
        XCTAssertEqual(refined.byHost.count, 1)
        XCTAssertEqual(refined.byHost.first?.host, "api.openai.com")
        XCTAssertEqual(refined.byHost.first?.opened, 1)
        XCTAssertEqual(refined.sessionUp, 20)
    }

    func testDecodeConnectionsFixture() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "connections", withExtension: "json", subdirectory: "Fixtures")
                                ?? Bundle.module.url(forResource: "connections", withExtension: "json"))
        let decoded = try JSONDecoder().decode(ProxyConnections.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.uploadTotal, 131_072)
        let items = try XCTUnwrap(decoded.connections)
        XCTAssertEqual(items.count, 2)
        let proxied = items[0]
        XCTAssertEqual(proxied.destination, "api.openai.com")
        XCTAssertEqual(proxied.exit, "US / #1")
        XCTAssertEqual(proxied.rule, "DomainSuffix")
        XCTAssertEqual(proxied.rulePayload, "openai.com")
        XCTAssertEqual(proxied.metadata.process, "codex")
        XCTAssertEqual(proxied.metadata.destinationPort, "443")
        XCTAssertEqual(proxied.start, "2026-10-14T08:15:30.123456+08:00")
        XCTAssertTrue(proxied.isDirect == false)
        let direct = items[1]
        XCTAssertEqual(direct.destination, "192.168.1.10")
        XCTAssertTrue(direct.isDirect)
        XCTAssertEqual((direct.metadata.network ?? "").uppercased(), "UDP")
    }
}
