// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GatewaySwitch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "GatewaySwitch"
        )
    ]
)
