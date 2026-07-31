// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NeonShell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NeonShell", path: "Sources/NeonShell")
    ]
)
