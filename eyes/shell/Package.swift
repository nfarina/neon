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
    ],
    targets: [
        .executableTarget(
            name: "NeonShell",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/NeonShell"
        )
    ]
)
