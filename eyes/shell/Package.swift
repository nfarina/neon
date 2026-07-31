// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NeoShell",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NeoShell", path: "Sources/NeoShell")
    ]
)
