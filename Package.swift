// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Paperplane",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Paperplane", targets: ["Paperplane"])
    ],
    targets: [
        .executableTarget(
            name: "Paperplane",
            path: "Sources/Paperplane"
        )
    ]
)
