import XCTest
import Combine
import CodexSwitchCore
@testable import CodexSwitch

final class ProxyModelTests: XCTestCase {
    @MainActor
    func testLatestSubscriptionSearchAndRouteWin() async {
        let model = ProxyModel(store: ClashProxyStore(home: FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-switch-model-\(UUID().uuidString)")))
        let ready = expectation(description: "Latest subscription and search are displayed")
        let observation = model.$visibleNodes.filter { $0 == ["US A", "US B"] }.prefix(1).sink { _ in ready.fulfill() }
        model.settings.relayYaml = (0..<2_000).map { "- name: Old \($0)" }.joined(separator: "\n")
        model.search = "Old"
        model.settings.relayYaml = "- name: HK 01\n- name: US A\n- name: Japan\n- name: US B"
        model.route = .relay
        model.search = "Japan"
        model.route = .exit
        model.search = "US"
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertEqual(model.names, ["HK 01", "US A", "Japan", "US B"])
        XCTAssertEqual(model.visibleNodes, ["US A", "US B"])
        observation.cancel()

        let sorted = expectation(description: "Delay changes update the cached list")
        let sortedObservation = model.$visibleNodes.filter { $0 == ["US B", "US A"] }.prefix(1).sink { _ in sorted.fulfill() }
        model.delays[.exit] = ["US A": -1, "US B": 30]
        await fulfillment(of: [sorted], timeout: 3)
        sortedObservation.cancel()

        let cleared = expectation(description: "Replacing the subscription removes stale nodes")
        let clearObservation = model.$visibleNodes.filter { $0.isEmpty }.prefix(1).sink { _ in cleared.fulfill() }
        model.settings.relayYaml = ""
        await fulfillment(of: [cleared], timeout: 3)
        XCTAssertTrue(model.names.isEmpty)
        clearObservation.cancel()
    }

    @MainActor
    func testSocksProfileSavesAndInvalidDataDoesNotReplaceIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("socks-model-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClashProxyStore(home: root)
        let model = ProxyModel(store: store)
        let profile = SocksProxyProfile(name: "Home", server: "proxy.example.com")
        try await model.saveSocksProfile(profile, select: true)
        let saved = try await store.load()
        XCTAssertEqual(saved.selectedSocksProfile, profile)
        XCTAssertTrue(model.settings.useHomeProxy)
        var invalid = profile; invalid.port = "0"
        do { try await model.saveSocksProfile(invalid, select: false); XCTFail("Invalid profile saved") } catch { }
        let retained = try await store.load()
        XCTAssertEqual(retained, saved)
        XCTAssertEqual(model.settings.selectedSocksProfile, profile)
    }

    @MainActor
    func testSocksTestFailureAndEditedCredentialsInvalidateResult() async {
        let model = ProxyModel(store: ClashProxyStore(home: FileManager.default.temporaryDirectory
            .appendingPathComponent("socks-test-\(UUID().uuidString)")))
        let profile = SocksProxyProfile(name: "Home", server: "proxy.example.com")
        let failed = expectation(description: "Missing relay is reported without making a network request")
        let observation = model.$socksTests.filter { records in
            if case .failure = records[profile.id]?.outcome { return true }
            return false
        }.prefix(1).sink { _ in failed.fulfill() }
        model.testSocksProfile(profile)
        await fulfillment(of: [failed], timeout: 3)
        if case .failure(let message) = model.socksTest(for: profile) { XCTAssertTrue(message.contains("中转节点")) }
        else { XCTFail("Failure not shown") }
        var edited = profile; edited.server = "changed.example"
        XCTAssertNil(model.socksTest(for: edited))
        XCTAssertNil(model.settings.selectedSocksProfile)
        observation.cancel()
        await model.finishBeforeQuit()
    }
}
