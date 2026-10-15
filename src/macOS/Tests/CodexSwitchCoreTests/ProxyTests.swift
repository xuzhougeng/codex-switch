import XCTest
@testable import CodexSwitchCore

final class ProxyTests: XCTestCase {
    let yaml = """
      - name: 'HK 01'
        type: socks5
        server: 127.0.0.1
        port: 29001
      - name: 'US #1 / A'
        type: socks5
        server: 127.0.0.1
        port: 29002
      - name: 'Japan'
        type: socks5
        server: 127.0.0.1
        port: 29003
    """
    func testLegacySettingsKeepHomeAndNewDefaults() throws {
        let old = Data(#"{"homeServer":"home.example","httpPort":8080}"#.utf8)
        let settings = try JSONDecoder().decode(ClashProxySettings.self, from: old)
        XCTAssertTrue(settings.useHomeProxy)
        XCTAssertEqual(settings.httpPort, 8080)
        XCTAssertEqual(settings.controller, "127.0.0.1:1993")
        XCTAssertFalse(settings.proxyOtherSites)
        XCTAssertFalse(ClashProxySettings().useHomeProxy)
        XCTAssertTrue(ClashProxySettings().proxyOtherSites)
    }
    func testSubscriptionExtractsOnlyProxiesAndPreservesIndentation() throws {
        let subscription = "port: 7890\nproxies:\n" + yaml + "\nproxy-groups:\n  - name: not-a-node\n    type: select\nrules:\n  - MATCH,DIRECT"
        let extracted = try RelayImport.extractProxies(subscription)
        XCTAssertEqual(DialerProxyBuilder.extractRelayNames(extracted), ["HK 01", "US #1 / A", "Japan"])
        XCTAssertFalse(extracted.contains("proxy-groups"))
        XCTAssertEqual(extracted, yaml)
        XCTAssertThrowsError(try RelayImport.extractProxies("proxies: []\nproxy-groups:\n - name: bogus"))
    }
    func testFlowAndReorderedNames() throws {
        let text = """
        proxies:
          - {type: ss, name: "US, #1", server: example.com, options: {name: nested, list: [a, b]}}
          - type: socks5
            name: Japan
            server: example.com
            port: 1080
        proxy-groups:
          - name: ignore
        """
        XCTAssertEqual(DialerProxyBuilder.extractRelayNames(try RelayImport.extractProxies(text)), ["US, #1", "Japan"])
    }
    func testSingleHopDoesNotRequireHomeAndRoutesBrowserTraffic() throws {
        let input = DialerProxyInput(relayYaml: yaml, homeServer: "", homePort: "", selectedExit: "Japan", useHomeProxy: false, proxyOtherSites: true)
        let files = try DialerProxyBuilder.build(input)
        XCTAssertFalse(files.yaml.contains("\\/"))
        XCTAssertTrue(files.yaml.contains("allow-lan: false\nbind-address: 127.0.0.1"))
        XCTAssertFalse(files.yaml.contains("name: target-socks5"))
        XCTAssertTrue(files.yaml.contains("DOMAIN-SUFFIX,anthropic.com,exit-group"))
        XCTAssertTrue(files.yaml.contains("MATCH,exit-group"))
        let exit = files.yaml.components(separatedBy: "  - name: exit-group")[1].components(separatedBy: "  - name: hk-auto")[0]
        XCTAssertFalse(exit.contains("HK 01"))
        XCTAssertTrue(exit.contains("proxies:\n      - Japan"))
        XCTAssertTrue(files.yaml.contains("  - name: 'HK 01'\n    type: socks5"))
    }
    func testProbeContainsWholeChainButLiveConfigDoesNotExposeHomePassword() throws {
        let input = DialerProxyInput(relayYaml: yaml, homeServer: "home.example", homePort: "1080", homeUsername: "123", homePassword: "000123")
        let live = try DialerProxyBuilder.build(input)
        let probe = try DialerProxyBuilder.buildProbe(input, controller: "127.0.0.1:30000", chain: true)
        XCTAssertFalse(live.yaml.contains("000123"))
        XCTAssertTrue(probe.contains("username: \"123\"\n    password: \"000123\""))
        XCTAssertEqual(probe.components(separatedBy: "dialer-proxy:").count - 1, 3)
        XCTAssertFalse(probe.contains("socks-port:"))
        let exit = try DialerProxyBuilder.buildProbe(input, controller: "127.0.0.1:30000", chain: false)
        XCTAssertFalse(exit.contains("home.example"))
        XCTAssertFalse(exit.contains("000123"))
    }
    func testGitHubAutomaticallyFallsBackFromHongKongToSelectedExit() throws {
        for proxyOtherSites in [false, true] {
            let input = DialerProxyInput(relayYaml: yaml, homeServer: "home.example", homePort: "1080",
                                        selectedExit: "Japan", proxyOtherSites: proxyOtherSites)
            let text = try DialerProxyBuilder.build(input).yaml
            let group = text.components(separatedBy: "  - name: hk-auto\n")[1].components(separatedBy: "  - name: hk-group\n")[0]
            XCTAssertTrue(group.contains("type: fallback\n"))
            XCTAssertTrue(group.contains("url: https://github.com\n"))
            XCTAssertTrue(group.contains("interval: 300\n"))
            XCTAssertTrue(group.contains("max-failed-times: 1\n"))
            XCTAssertTrue(group.contains("proxies:\n      - \"HK 01\"\n      - exit-group\n"))
            XCTAssertFalse(group.contains("DIRECT"))
            for host in ["github.com", "githubusercontent.com", "githubassets.com", "github.io"] {
                XCTAssertTrue(text.contains("DOMAIN-SUFFIX,\(host),hk-group\n"))
            }
            let copilot = try XCTUnwrap(text.range(of: "DOMAIN,copilot-proxy.githubusercontent.com,exit-group"))
            let github = try XCTUnwrap(text.range(of: "DOMAIN-SUFFIX,githubusercontent.com,hk-group"))
            XCTAssertLessThan(copilot.lowerBound, github.lowerBound)
            XCTAssertTrue(text.contains("DOMAIN-SUFFIX,anthropic.com,target-socks5\n"))
        }
    }
    func testGitHubWithoutHongKongUsesSelectedExitInBothRoutingModes() throws {
        for proxyOtherSites in [false, true] {
            let input = DialerProxyInput(relayYaml: "- {name: Japan, type: socks5, server: 127.0.0.1, port: 29003}",
                                        homeServer: "", homePort: "", exitGroup: "custom-exit", selectedExit: "Japan",
                                        useHomeProxy: false, proxyOtherSites: proxyOtherSites)
            let text = try DialerProxyBuilder.build(input).yaml
            let group = text.components(separatedBy: "  - name: hk-auto\n")[1].components(separatedBy: "  - name: hk-group\n")[0]
            XCTAssertTrue(group.contains("proxies:\n      - custom-exit\n"))
            XCTAssertFalse(group.contains("DIRECT"))
            XCTAssertTrue(text.contains("DOMAIN-SUFFIX,githubassets.com,hk-group\n"))
            XCTAssertTrue(text.contains("MATCH,\(proxyOtherSites ? "custom-exit" : "DIRECT")\n"))
        }
    }
    func testValidationAndHongKongFilter() throws {
        var input = DialerProxyInput(relayYaml: yaml, homeServer: "home.example", homePort: "1080")
        input.controller = "0.0.0.0:1993"
        XCTAssertThrowsError(try DialerProxyBuilder.build(input))
        input.controller = "127.0.0.1:1993"; input.socksPort = input.httpPort
        XCTAssertThrowsError(try DialerProxyBuilder.build(input))
        input.socksPort = 1991; input.maxConcurrent = 0
        XCTAssertThrowsError(try DialerProxyBuilder.build(input))
        XCTAssertEqual(DialerProxyBuilder.withoutHongKong(["香港", "🇭🇰", "Hong Kong 1", "HK2", "checkpoint", "Japan"]), ["checkpoint", "Japan"])
    }
    func testSocksURLParsingAndAPIEncoding() throws {
        let parsed = try SocksEndpoint("socks5://user%40a:p%3Aa%23ss@[::1]:1080")
        XCTAssertEqual(parsed.host, "::1")
        XCTAssertEqual(parsed.username, "user@a")
        XCTAssertEqual(parsed.password, "p:a#ss")
        XCTAssertThrowsError(try SocksEndpoint("http://host:1080"))
        XCTAssertThrowsError(try SocksEndpoint("host:70000"))
        let url = try ClashAPI(controller: "127.0.0.1:1993").url(["proxies", "US / #1?", "delay"])
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:1993/proxies/US%20%2F%20%231%3F/delay")
    }
    func testSystemProxyPreservesExceptionsAndOriginalSnapshot() throws {
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "old.proxy", "HTTPPort": 8123,
                                      "SOCKSEnable": 1, "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example/pac",
                                      "ExceptionsList": ["localhost", "*.local"], "ExcludeSimpleHostnames": 1]
        let managed = SystemProxyPreferences.managedConfiguration(original: original, port: 1990)
        XCTAssertEqual(managed["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(managed["HTTPSPort"] as? Int, 1990)
        XCTAssertEqual(managed["SOCKSEnable"] as? Int, 0)
        XCTAssertEqual(managed["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertEqual(managed["ExceptionsList"] as? [String], ["localhost", "*.local"])
        let saved = try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0)
        let service = SystemProxyPreferences.Service(id: "test", configuration: saved, enabled: true)
        let restored = try JSONDecoder().decode(SystemProxyPreferences.Service.self, from: JSONEncoder().encode(service))
        XCTAssertEqual(restored.configuration, saved)
        XCTAssertEqual(original["HTTPProxy"] as? String, "old.proxy")
    }
    func testShellInstallIsIdempotentAndQuotesPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy ' test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rc = root.appendingPathComponent(".zshrc")
        try "export EXISTING=1\n".write(to: rc, atomically: true, encoding: .utf8)
        let store = ClashProxyStore(home: root)
        _ = try ProxyShell.install(store: store, userHome: root)
        _ = try ProxyShell.install(store: store, userHome: root)
        let text = try String(contentsOf: rc)
        XCTAssertTrue(text.hasPrefix("export EXISTING=1\n"))
        XCTAssertEqual(text.components(separatedBy: "# Codex Switch").count, 2)
        XCTAssertTrue(text.contains("'\\''"))
        let plist = try PropertyListSerialization.propertyList(from: ClashProxyRuntime.launchAgentData(executable: "/Applications/My App.app/Contents/MacOS/App", store: store), format: nil) as! [String: Any]
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.first, "/Applications/My App.app/Contents/MacOS/App")
    }
    func testLogTailAndConfigPermissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClashProxyStore(home: root)
        var settings = ClashProxySettings(); settings.relayYaml = yaml
        try await store.save(settings)
        _ = try await store.materialize(settings)
        for url in [store.settingsURL, store.yamlURL, store.limiterJSONURL] {
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
        try "INFO hello\nWARN timeout\nlevel=error msg=bad\n".write(to: store.serviceLogURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProxyLog.tail(store.serviceLogURL, problemsOnly: true), "WARN timeout\nlevel=error msg=bad")
    }
    func testFailedKernelDoesNotLeaveProcesses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClashProxyStore(home: root)
        let runtime = ClashProxyRuntime(store: store)
        var settings = ClashProxySettings(); settings.relayYaml = yaml; settings.mihomoPath = "/usr/bin/false"
        do { _ = try await runtime.start(settings); XCTFail("Invalid kernel accepted") } catch { }
        let state = try await runtime.status()
        XCTAssertFalse(state.running)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.servicePidURL.path))
    }
}
