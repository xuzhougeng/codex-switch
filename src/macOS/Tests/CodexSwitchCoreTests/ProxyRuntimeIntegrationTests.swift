import XCTest
@testable import CodexSwitchCore

/// Opt-in real-kernel tests. Every process and config belongs to a temporary directory;
/// no system proxy, login item, real subscription, or user account is modified.
final class ProxyRuntimeIntegrationTests: XCTestCase {
    private func fixture() throws -> (ClashProxyStore, ClashProxyRuntime, ClashProxySettings) {
        let env = ProcessInfo.processInfo.environment
        guard let kernel = env["CODEX_SWITCH_TEST_KERNEL"], let executable = env["CODEX_SWITCH_TEST_APP"] else {
            throw XCTSkip("Set CODEX_SWITCH_TEST_KERNEL and CODEX_SWITCH_TEST_APP for real-kernel integration tests.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-switch-integration-\(UUID().uuidString)")
        let store = ClashProxyStore(home: root)
        let runtime = ClashProxyRuntime(store: store, executable: executable, userHome: root)
        var settings = ClashProxySettings()
        var ports = Set<Int>()
        while ports.count < 4 { ports.insert(try ProxyProcess.freePort()) }
        let allocated = Array(ports)
        settings.httpPort = allocated[0]; settings.socksPort = allocated[1]
        settings.controller = "127.0.0.1:\(allocated[2])"; settings.limiterListen = "127.0.0.1:\(allocated[3])"
        settings.mihomoPath = kernel
        settings.relayYaml = """
          - {name: 'US / #1', type: socks5, server: 127.0.0.1, port: 1}
          - name: Japan
            type: socks5
            server: 127.0.0.1
            port: 1
        """
        settings.selectedRelay = "Japan"; settings.selectedExit = "US / #1"
        return (store, runtime, settings)
    }
    func testKernelStartLiveSwitchRestartAndStop() async throws {
        let (store, runtime, settings) = try fixture()
        do {
            let started = try await runtime.start(settings)
            XCTAssertTrue(started.running)
            let api = ClashAPI(controller: settings.controller)
            let initial = try await api.group(settings.exitGroup)
            XCTAssertEqual(initial.now, "US / #1")
            _ = try await runtime.select(settings, name: "Japan", route: .exit)
            let switched = try await api.group(settings.exitGroup)
            XCTAssertEqual(switched.now, "Japan")
            let reader = ProxyStatusReader(runtime: runtime, system: MacSystemProxy(store: store), store: store)
            let snapshot = try await reader.read()
            XCTAssertTrue(snapshot.state.running)
            XCTAssertEqual(snapshot.liveExit, "Japan")
            XCTAssertNotNil(snapshot.connections)
            // Saved selections override mihomo's cache on restart.
            let restarted = try await runtime.restart(settings)
            XCTAssertTrue(restarted.running)
            let afterRestart = try await api.group(settings.exitGroup)
            XCTAssertEqual(afterRestart.now, "US / #1")
            var invalid = settings; invalid.mihomoPath = "/usr/bin/false"
            do { _ = try await runtime.restart(invalid); XCTFail("Invalid kernel accepted") } catch { }
            let retained = try await runtime.status()
            XCTAssertTrue(retained.running)
            try await runtime.stop()
            let stopped = try await runtime.status()
            XCTAssertFalse(stopped.running)
            let stoppedSnapshot = try await reader.read()
            XCTAssertFalse(stoppedSnapshot.state.running)
            XCTAssertNil(stoppedSnapshot.connections)
            XCTAssertEqual(stoppedSnapshot.liveExit, "")
            XCTAssertFalse(ProxyProcess.listening(settings.httpPort))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.servicePidURL.path))
            try FileManager.default.removeItem(at: store.home)
        } catch {
            try? await runtime.stop()
            try? FileManager.default.removeItem(at: store.home)
            throw error
        }
    }
    func testRulesApplyWithoutRestartAndInvalidDraftKeepsRunningRules() async throws {
        let (store, runtime, base) = try fixture()
        do {
            let started = try await runtime.start(base)
            var settings = base
            settings.routing.customRules = [RoutingRule(value: "example.com", target: .reject)]
            _ = try await runtime.applyRules(settings)
            let applied = try await runtime.status()
            XCTAssertEqual(applied.mihomoPid, started.mihomoPid)
            let active = try await runtime.runningSettings()
            XCTAssertEqual(active.routing, settings.routing)
            let api = ClashAPI(controller: settings.controller)
            let (data, _) = try await ProxyHTTP.session().data(from: api.url(["rules"]))
            let rules = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["rules"] as? [[String: Any]])
            XCTAssertEqual(rules.first?["payload"] as? String, "example.com")
            XCTAssertEqual(rules.first?["proxy"] as? String, "REJECT")
            _ = try await runtime.select(settings, name: "Japan", route: .development)
            let manual = try await api.group(DialerProxyBuilder.developmentGroup)
            XCTAssertEqual(manual.now, "Japan")
            _ = try await runtime.select(settings, name: DialerProxyBuilder.developmentAutomaticGroup, route: .development)
            let automatic = try await api.group(DialerProxyBuilder.developmentGroup)
            XCTAssertEqual(automatic.now, DialerProxyBuilder.developmentAutomaticGroup)
            settings.routing.customRules[0].value = "invalid\nrule"
            do { _ = try await runtime.applyRules(settings); XCTFail("Invalid draft was applied") } catch { }
            let retained = try await runtime.runningSettings()
            XCTAssertEqual(retained.routing, active.routing)
            let saved = try await store.load()
            XCTAssertEqual(saved.routing, active.routing)
            let final = try await runtime.status()
            XCTAssertTrue(final.running)
            XCTAssertEqual(final.mihomoPid, started.mihomoPid)
            try await runtime.stop()
            try FileManager.default.removeItem(at: store.home)
        } catch {
            try? await runtime.stop()
            try? FileManager.default.removeItem(at: store.home)
            throw error
        }
    }

    func testHomeLimiterAndIsolatedProbes() async throws {
        let (store, runtime, base) = try fixture()
        var settings = base
        settings.useHomeProxy = true; settings.homeServer = "127.0.0.1"; settings.homePort = "1"
        settings.homeUsername = "123"; settings.homePassword = "000123"
        do {
            let started = try await runtime.start(settings)
            XCTAssertTrue(started.running)
            XCTAssertNotNil(started.limiterPid)
            for route in ProxyRoute.allCases {
                let results = try await ProxyProbe.run(store: store, settings: settings, route: route) { _, _ in }
                XCTAssertEqual(results.count, 2)
                XCTAssertTrue(results.values.allSatisfy { $0 == -1 })
                let after = try await runtime.status()
                XCTAssertEqual(after.mihomoPid, started.mihomoPid)
                let selection = try await ClashAPI(controller: settings.controller).group(settings.exitGroup)
                XCTAssertEqual(selection.now, "US / #1")
            }
            let task = Task { try await ProxyProbe.run(store: store, settings: settings, route: .relay) { _, _ in } }
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancelled probe completed") } catch is CancellationError { }
            try await runtime.stop()
            XCTAssertFalse(ProxyProcess.listening(try LocalEndpoint(settings.limiterListen).port))
            try FileManager.default.removeItem(at: store.home)
        } catch {
            try? await runtime.stop()
            try? FileManager.default.removeItem(at: store.home)
            throw error
        }
    }

    func testGitHubFallbackSkipsFailedNodesAndServesBrowserAssets() async throws {
        let (store, _, base) = try fixture()
        try FileManager.default.createDirectory(at: store.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let portsURL = store.home.appendingPathComponent("mock-ports.json")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "mock-socks", withExtension: "py"))
        let server = try ProxyProcess.launch(ProxyProcess.resolve("", names: ["python3"]), [script.path, portsURL.path],
                                            cwd: store.home, log: store.home.appendingPathComponent("mock.log"))
        var kernel: Process?
        do {
            var ports: [String: Int] = [:]
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: portsURL), let value = try? JSONDecoder().decode([String: Int].self, from: data) {
                    ports = value; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let webPort = try XCTUnwrap(ports["web"])
            let failed = "- {name: HK-broken, type: socks5, server: 127.0.0.1, port: 1}\n"
            let healthy = "- {name: HK-healthy, type: socks5, server: 127.0.0.1, port: \(webPort)}\n"
            let exit = "- {name: Japan, type: socks5, server: 127.0.0.1, port: \(webPort)}\n"
            let cases = [(failed + healthy + exit, "HK-healthy"), (failed + exit, "exit-group"), (exit, "exit-group")]
            for (index, scenario) in cases.enumerated() {
                let directory = store.home.appendingPathComponent("case-\(index)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var settings = base
                settings.relayYaml = scenario.0; settings.selectedExit = "Japan"; settings.proxyOtherSites = false
                // Use the same GitHub host over plain HTTP so the local fixture needs no TLS certificate.
                let yaml = try DialerProxyBuilder.build(store.input(settings)).yaml
                    .replacingOccurrences(of: "url: https://github.com", with: "url: http://github.com")
                let config = directory.appendingPathComponent("test.yaml")
                try yaml.write(to: config, atomically: true, encoding: .utf8)
                let process = try ProxyProcess.launch(settings.mihomoPath, ["-d", directory.path, "-f", config.path],
                                                     cwd: directory, log: directory.appendingPathComponent("mihomo.log"))
                kernel = process
                let api = ClashAPI(controller: settings.controller)
                var selected: String?
                for _ in 0..<100 {
                    selected = try? await api.group(DialerProxyBuilder.developmentAutomaticGroup).now
                    if selected == scenario.1 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(selected, scenario.1)
                let selection = try await api.group(DialerProxyBuilder.developmentGroup)
                XCTAssertEqual(selection.now, DialerProxyBuilder.developmentAutomaticGroup)
                for host in ["github.com", "github.githubassets.com"] {
                    let response = try await ProxyProcess.run("/usr/bin/curl", ["--noproxy", "", "--proxy",
                        "http://127.0.0.1:\(settings.httpPort)", "--max-time", "3", "--fail", "--silent", "--show-error", "http://\(host)/"])
                    XCTAssertEqual(response, "mock github")
                }
                await ProxyProcess.terminate(process)
                kernel = nil
            }
            await ProxyProcess.terminate(server)
            try FileManager.default.removeItem(at: store.home)
        } catch {
            if let kernel { await ProxyProcess.terminate(kernel) }
            await ProxyProcess.terminate(server)
            try? FileManager.default.removeItem(at: store.home)
            throw error
        }
    }

    func testSOCKSChainSuccessAndIncorrectPassword() async throws {
        let (store, _, base) = try fixture()
        try FileManager.default.createDirectory(at: store.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let portsURL = store.home.appendingPathComponent("mock-ports.json")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "mock-socks", withExtension: "py"))
        let python = try ProxyProcess.resolve("", names: ["python3"])
        let server = try ProxyProcess.launch(python, [script.path, portsURL.path], cwd: store.home,
                                            log: store.home.appendingPathComponent("mock.log"))
        do {
            var ports: [String: Int] = [:]
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: portsURL), let value = try? JSONDecoder().decode([String: Int].self, from: data) {
                    ports = value; break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            let relayPort = try XCTUnwrap(ports["relay"]), homePort = try XCTUnwrap(ports["home"])
            var settings = base
            settings.relayYaml = "- {name: MockRelay, type: socks5, server: 127.0.0.1, port: \(relayPort)}"
            settings.selectedRelay = "MockRelay"
            var profile = SocksProxyProfile(name: "Mock", server: "127.0.0.1", port: String(homePort),
                                             username: "test-user", password: "test-password")
            try settings.upsertSocksProfile(profile, select: true)
            let success = try await ProxyProbe.run(store: store, settings: settings, route: .relay, only: "MockRelay") { _, _ in }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(success["MockRelay"]), 0)
            profile.password = "incorrect"
            try settings.upsertSocksProfile(profile, select: true)
            let failed = try await ProxyProbe.run(store: store, settings: settings, route: .relay, only: "MockRelay") { _, _ in }
            XCTAssertEqual(failed["MockRelay"], -1)
            await ProxyProcess.terminate(server)
            try FileManager.default.removeItem(at: store.home)
        } catch {
            await ProxyProcess.terminate(server)
            try? FileManager.default.removeItem(at: store.home)
            throw error
        }
    }
}
