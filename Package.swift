// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paperplane",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Paperplane", targets: ["Paperplane"]),
        .library(name: "PaperplaneCore", targets: ["PaperplaneCore"]),
        .executable(name: "PDFKitInteropProbe", targets: ["PDFKitInteropProbe"]),
        .executable(name: "PDFKitPerformanceProbe", targets: ["PDFKitPerformanceProbe"])
    ],
    targets: [
        .executableTarget(
            name: "Paperplane",
            dependencies: ["PaperplaneCore"],
            path: "Sources/Paperplane",
            resources: [.process("Resources")]
        ),
        .target(
            name: "PaperplaneCore",
            path: "Sources/PaperplaneCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "PaperplaneCoreTests",
            dependencies: ["PaperplaneCore"],
            path: "Tests/PaperplaneCoreTests"
        ),
        .executableTarget(
            name: "PDFKitInteropProbe",
            path: "Tests/PDFKitInteropProbe"
        ),
        .executableTarget(
            name: "PDFKitPerformanceProbe",
            path: "Tests/PDFKitPerformanceProbe"
        )
    ]
)
