// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NeonShell",
    platforms: [.macOS(.v14)],
    dependencies: [
        // ONNX Runtime for the openWakeWord pipeline (melspectrogram ->
        // embedding -> wake model), all tiny CPU models.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
                 from: "1.19.2"),
        // Software updates for a machine on a kitchen wall. Pinned rather than
        // floating: Sparkle ships signed XPC services that build.sh copies into
        // the bundle by hand, and a minor bump that renames a nested component
        // would break the copy rather than the compile.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "NeonShell",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/NeonShell",
            // Sparkle is a real framework rather than a static library, so the
            // executable has to know to look beside itself for it once it is
            // inside Neon.app. Without this the app dies at launch with a dyld
            // error and no window ever appears.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath",
                              "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
