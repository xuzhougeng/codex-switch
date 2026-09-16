// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwitch",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CodexSwitch", targets: ["CodexSwitch"])],
    targets: [
        .target(name: "CodexSwitchCore"),
        .executableTarget(name: "CodexSwitch", dependencies: ["CodexSwitchCore"]),
        .testTarget(name: "CodexSwitchCoreTests", dependencies: ["CodexSwitchCore"])
    ]
)
