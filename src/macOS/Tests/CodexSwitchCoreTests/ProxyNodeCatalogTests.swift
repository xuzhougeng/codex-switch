import XCTest
@testable import CodexSwitchCore

final class ProxyNodeCatalogTests: XCTestCase {
    func testStableOrderFilteringAndFailedDelays() {
        let catalog = ProxyNodeCatalog(yaml: ["HK 01", "Japan", "US A", "US B", "Canada", "Japan"]
            .map { "- name: '\($0)'" }.joined(separator: "\n"))
        XCTAssertEqual(catalog.names, ["HK 01", "Japan", "US A", "US B", "Canada"])
        XCTAssertEqual(catalog.candidates(for: .exit), ["Japan", "US A", "US B", "Canada"])
        XCTAssertEqual(catalog.candidates(for: .development), catalog.names)
        XCTAssertEqual(catalog.visibleNodes(route: .relay, search: "", delays: [:]), catalog.names)
        let delays = ["Japan": -1, "US A": 20, "US B": 20, "Canada": 0]
        XCTAssertEqual(catalog.visibleNodes(route: .exit, search: "", delays: delays), ["Canada", "US A", "US B", "Japan"])
        XCTAssertEqual(catalog.visibleNodes(route: .exit, search: "us", delays: delays), ["US A", "US B"])
        XCTAssertEqual(catalog.visibleNodes(route: .exit, search: "missing", delays: delays), [])
    }

    func testLargeCatalogInteractiveUpdates() {
        let catalog = ProxyNodeCatalog(yaml: (0..<1_000).map {
            "- {name: 'US Node \($0)', type: socks5, server: 127.0.0.1, port: 1}"
        }.joined(separator: "\n"))
        let delays = Dictionary(uniqueKeysWithValues: catalog.names.enumerated().map { ($0.element, 1_000 - $0.offset) })
        XCTAssertEqual(catalog.visibleNodes(route: .exit, search: "", delays: delays).first, "US Node 999")
        // Interactive work excludes subscription parsing and reuses the same catalog.
        measure {
            for query in ["", "node", "99", "US", "999"] {
                XCTAssertFalse(catalog.visibleNodes(route: .exit, search: query, delays: delays).isEmpty)
            }
        }
    }
}
