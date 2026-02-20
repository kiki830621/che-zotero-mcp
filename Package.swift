// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheZoteroMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CheZoteroMCPCore",
            targets: ["CheZoteroMCPCore"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.10.2")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMinor(from: "0.30.6")),
    ],
    targets: [
        // Core library containing ZoteroReader, EmbeddingManager, and server logic
        .target(
            name: "CheZoteroMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/CheZoteroMCPCore"
        ),
        // Executable entry point
        .executableTarget(
            name: "CheZoteroMCP",
            dependencies: ["CheZoteroMCPCore"],
            path: "Sources/CheZoteroMCP"
        ),
        // Unit tests
        .testTarget(
            name: "CheZoteroMCPTests",
            dependencies: ["CheZoteroMCPCore"],
            path: "Tests/CheZoteroMCPTests"
        )
    ]
)
