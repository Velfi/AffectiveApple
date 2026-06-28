// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LlmTester",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "LlmTester", targets: ["LlmTester"]),
        .library(name: "LlmTesterReport", targets: ["LlmTesterReport"]),
    ],
    targets: [
        .executableTarget(
            name: "LlmTester",
            dependencies: ["LlmTesterReport"],
            path: "Sources",
            exclude: [
                "LlmTesterLib",
            ],
            sources: [
                "AffectiveHostLLM",
                "LlmTesterCLI",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .target(
            name: "LlmTesterReport",
            path: "Sources/LlmTesterLib"
        ),
        .testTarget(
            name: "LlmTesterTests",
            dependencies: ["LlmTesterReport"],
            path: "Tests/LlmTesterTests"
        ),
    ]
)
