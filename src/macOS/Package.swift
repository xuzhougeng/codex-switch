// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexSwitch", targets: ["CodexSwitch"])],
    targets: [
        .target(name: "CodexSwitchCore", resources: [.copy("Resources/socks-limiter.py")]),
        .executableTarget(name: "CodexSwitch", dependencies: ["CodexSwitchCore"]),
        .testTarget(name: "CodexSwitchCoreTests", dependencies: ["CodexSwitchCore"], resources: [.copy("Fixtures/mock-socks.py"), .copy("Fixtures/connections.json")]),
        .testTarget(name: "CodexSwitchTests", dependencies: ["CodexSwitch", "CodexSwitchCore"])
    ]
)
