import XCTest
@testable import CodexSwitchCore

final class RoutingRulesTests: XCTestCase {
    private var input: DialerProxyInput {
        DialerProxyInput(relayYaml: "- {name: Japan, type: socks5, server: 127.0.0.1, port: 1}",
                        homeServer: "home.example", homePort: "1080", useHomeProxy: true)
    }
    func testLegacyMigrationAndNewRoutingRoundTrip() throws {
        let old = try JSONDecoder().decode(ClashProxySettings.self, from: Data(#"{"proxyOtherSites":true,"homeServer":"home.example"}"#.utf8))
        XCTAssertEqual(old.routing, RoutingConfiguration())
        XCTAssertEqual(old.selectedDevelopment, "")
        XCTAssertEqual(old.routing.preset(proxyOtherSites: old.proxyOtherSites), .allProxy)
        var changed = old
        changed.routing.customRules = [RoutingRule(kind: .processPath, value: "/Applications/My App.app/Contents/MacOS/App", target: .direct)]
        changed.selectedDevelopment = "Japan"
        let restored = try JSONDecoder().decode(ClashProxySettings.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(restored, changed)
    }
    func testPresetsPreserveCustomRulesAndProduceExpectedPolicies() throws {
        var value = input
        let custom = RoutingRule(value: "example.com", target: .reject)
        value.routing.customRules = [custom]
        for preset in RoutingPreset.allCases {
            var routing = value.routing, others = value.proxyOtherSites
            routing.apply(preset, proxyOtherSites: &others)
            value.routing = routing; value.proxyOtherSites = others
            XCTAssertEqual(routing.customRules, [custom])
            XCTAssertEqual(routing.preset(proxyOtherSites: others), preset)
            let yaml = try DialerProxyBuilder.build(value).yaml
            XCTAssertTrue(yaml.contains("DOMAIN-SUFFIX,github.com,\(preset == .aiOnly ? "DIRECT" : "hk-group")\n"))
            XCTAssertTrue(yaml.contains("MATCH,\(preset == .allProxy ? "exit-group" : "DIRECT")\n"))
        }
    }
    func testCustomPrecedenceAndHomeLoopProtection() throws {
        var value = input
        value.routing.customRules = [RoutingRule(value: "github.com", target: .direct),
                                     RoutingRule(value: "disabled.example", target: .reject, noResolve: false)]
        value.routing.customRules[1].enabled = false
        let yaml = try DialerProxyBuilder.build(value).yaml
        let loop = try XCTUnwrap(yaml.range(of: "DOMAIN,home.example,relay-group"))
        let custom = try XCTUnwrap(yaml.range(of: "DOMAIN-SUFFIX,github.com,DIRECT"))
        let builtin = try XCTUnwrap(yaml.range(of: "DOMAIN-SUFFIX,github.com,hk-group"))
        XCTAssertLessThan(loop.lowerBound, custom.lowerBound)
        XCTAssertLessThan(custom.lowerBound, builtin.lowerBound)
        XCTAssertFalse(yaml.contains("disabled.example"))
        XCTAssertTrue(yaml.contains("  - \"DOMAIN-SUFFIX,github.com,DIRECT\""))
    }
    func testClashImportAndValidation() throws {
        let text = """
        rules:
          # Ordered overrides
          - DOMAIN-SUFFIX,example.com,DIRECT
          - "IP-CIDR,192.168.0.0/16,exit-group,no-resolve"
          - PROCESS-NAME,My App,hk-group
          - NETWORK,tcp,REJECT
        """
        let rules = try RoutingRule.importClash(text, input: input)
        XCTAssertEqual(rules.map(\.target), [.direct, .ai, .development, .reject])
        XCTAssertTrue(rules[1].noResolve)
        XCTAssertEqual(rules[3].value, "TCP")
        for bad in ["MATCH,DIRECT", "DOMAIN-SUFFIX,example.com,missing", "DOMAIN-SUFFIX,example.com,DIRECT,no-resolve",
                    "IP-CIDR,999.0.0.0/32,DIRECT", "IP-CIDR6,::1/129,DIRECT", "DST-PORT,99999,DIRECT", "NETWORK,ICMP,DIRECT"] {
            XCTAssertThrowsError(try RoutingRule.importClash(bad, input: input), bad)
        }
        XCTAssertThrowsError(try RoutingRule(kind: .suffix, value: "example.com\nrules:", target: .direct).validated())
        XCTAssertThrowsError(try RoutingRule(kind: .port, value: "9000-8000").validated())
        _ = try RoutingRule(kind: .ipv6, value: "2001:db8::/32", noResolve: true).validated()
    }
    func testResidentialRulesNeedEnabledHomeButBuiltinCanFallBack() throws {
        var value = input
        value.useHomeProxy = false
        let yaml = try DialerProxyBuilder.build(value).yaml
        XCTAssertTrue(yaml.contains("DOMAIN-SUFFIX,claude.ai,exit-group"))
        value.routing.customRules = [RoutingRule(value: "example.com", target: .residential)]
        XCTAssertThrowsError(try DialerProxyBuilder.build(value))
        value.routing.customRules[0].enabled = false
        _ = try DialerProxyBuilder.build(value)
    }
}
