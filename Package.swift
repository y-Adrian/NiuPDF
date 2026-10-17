// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paperplane",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Paperplane", targets: ["Paperplane"]),
        .executable(name: "PDFKitInteropProbe", targets: ["PDFKitInteropProbe"]),
        .executable(name: "PDFKitPerformanceProbe", targets: ["PDFKitPerformanceProbe"])
    ],
    targets: [
        .executableTarget(
            name: "Paperplane",
            path: "Sources/Paperplane"
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
