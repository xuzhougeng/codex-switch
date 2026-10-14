import XCTest
@testable import CodexSwitchCore

final class SocksProfileTests: XCTestCase {
    func testImportReplacesCredentialsAndDefaultsPort() throws {
        var profile = SocksProxyProfile(name: "Home", server: "old.example", port: "9000", username: "old", password: "old")
        try profile.importAddress(" socks5h://user%40name:p%3Aa%23ss@[::1]:1080 \n")
        XCTAssertEqual(profile.server, "::1")
        XCTAssertEqual(profile.username, "user@name")
        XCTAssertEqual(profile.password, "p:a#ss")
        XCTAssertEqual(try profile.validated().endpoint, "[::1]:1080")
        try profile.importAddress("proxy.example.com")
        XCTAssertEqual(profile.port, "1080")
        XCTAssertEqual(profile.username, "")
        XCTAssertEqual(profile.password, "")
        XCTAssertEqual(profile.name, "Home")
    }
    func testProviderFormatPreservesLiteralPassword() throws {
        let parsed = try SocksEndpoint("proxy.example.com:8080:000123:p:a#ss@tail")
        XCTAssertEqual(parsed.host, "proxy.example.com")
        XCTAssertEqual(parsed.port, "8080")
        XCTAssertEqual(parsed.username, "000123")
        XCTAssertEqual(parsed.password, "p:a#ss@tail")
        XCTAssertThrowsError(try SocksEndpoint("https://proxy.example.com:1080"))
        XCTAssertThrowsError(try SocksEndpoint("proxy.example.com:99999:user:password"))
    }
    func testValidationAndNormalization() throws {
        var profile = SocksProxyProfile(name: " Home ", server: " [2001:db8::1] ", port: " 01080 ")
        let normalized = try profile.validated()
        XCTAssertEqual(normalized.name, "Home")
        XCTAssertEqual(normalized.server, "2001:db8::1")
        XCTAssertEqual(normalized.port, "1080")
        for invalid in ["", "0", "65536", "1080.0", "abc"] {
            profile.port = invalid
            XCTAssertThrowsError(try profile.validated())
        }
        profile.port = "1080"
        profile.server = "socks5://host"
        XCTAssertThrowsError(try profile.validated())
        profile.server = "proxy.example.com"; profile.username = "user"
        XCTAssertThrowsError(try profile.validated())
        profile.password = "000123"
        XCTAssertEqual(try profile.validated().password, "000123")
    }
    func testLegacyConfigurationMigratesWithoutChangingRouting() throws {
        let data = Data(#"{"homeServer":"old.example","homePort":"9000","homeUsername":"user","homePassword":"pass","useHomeProxy":false}"#.utf8)
        let old = try JSONDecoder().decode(ClashProxySettings.self, from: data)
        XCTAssertEqual(old.socksProfiles.count, 1)
        XCTAssertEqual(old.selectedSocksProfile?.server, "old.example")
        XCTAssertEqual(old.selectedSocksProfile?.password, "pass")
        XCTAssertFalse(old.useHomeProxy)
        let reloaded = try JSONDecoder().decode(ClashProxySettings.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(reloaded, old)
    }
    func testEditingSwitchingAndDeletingProfilesKeepRuntimeFieldsConsistent() throws {
        var settings = ClashProxySettings()
        var first = SocksProxyProfile(name: "A", server: "a.example", username: "a", password: "aaa")
        let second = SocksProxyProfile(name: "B", server: "b.example", port: "8080")
        try settings.upsertSocksProfile(first, select: true)
        try settings.upsertSocksProfile(second, select: false)
        XCTAssertEqual(settings.homeServer, "a.example")
        first.password = "new"
        try settings.upsertSocksProfile(first, select: false)
        XCTAssertEqual(settings.homePassword, "new")
        try settings.selectSocksProfile(second.id)
        XCTAssertEqual(settings.homeServer, "b.example")
        XCTAssertEqual(settings.homePort, "8080")
        XCTAssertEqual(settings.homeUsername, "")
        XCTAssertEqual(settings.homePassword, "")
        settings.removeSocksProfile(second.id)
        XCTAssertEqual(settings.socksProfiles.count, 1)
        XCTAssertNil(settings.selectedSocksProfileID)
        XCTAssertFalse(settings.useHomeProxy)
        XCTAssertEqual(settings.homeServer, "")
    }
    func testRestartComparisonIgnoresNamesAndInactiveCredentials() throws {
        var settings = ClashProxySettings()
        let disabled = SocksRuntimeConfiguration(settings)
        settings.homePassword = "inactive"
        XCTAssertEqual(disabled, SocksRuntimeConfiguration(settings))
        var profile = SocksProxyProfile(name: "A", server: "a.example", username: "a", password: "aaa")
        try settings.upsertSocksProfile(profile, select: true)
        let active = SocksRuntimeConfiguration(settings)
        profile.name = "Renamed"
        try settings.upsertSocksProfile(profile, select: false)
        XCTAssertEqual(active, SocksRuntimeConfiguration(settings))
        profile.password = "changed"
        try settings.upsertSocksProfile(profile, select: false)
        XCTAssertNotEqual(active, SocksRuntimeConfiguration(settings))
    }
}
