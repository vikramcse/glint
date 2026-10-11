// swift-tools-version: 6.0
// Glint — on-device multimodal search for Mac.
//
// Module graph (dependencies point inward toward GlintCore). `scripts/check_imports.sh`
// enforces the same graph on source imports, so a sideways import fails CI.

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "Glint",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // The signed app bundle is built from Glint.xcodeproj (project.yml); this product keeps
        // the app code compiling under `swift build`.
        .executable(name: "glint-app", targets: ["GlintApp"]),
        .executable(name: "glint-eval", targets: ["GlintEval"]),
        .executable(name: "glint-license", targets: ["GlintLicenseTool"]),
        .executable(name: "glint-mcp", targets: ["GlintMCPTool"]),
        .library(name: "GlintCore", targets: ["GlintCore"]),
        // Everything the Xcode app target (Glint.xcodeproj, generated from project.yml) links.
        .library(
            name: "GlintKit",
            targets: [
                "GlintCore", "GlintExtractors", "GlintEmbedding", "GlintStore", "GlintSearch", "GlintIndexer",
                "GlintLicensing", "GlintTelemetry", "GlintUI", "GlintLocalAPI",
            ]),
        .library(name: "GlintMCP", targets: ["GlintMCP"]),
    ],
    dependencies: [
        // On-device model runtime (Apple). See docs/adr/0006-mlx-and-embeddinggemma-2.md.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        // Hugging Face tokenizers (tokenizer.json), so token ids match the reference exactly.
        .package(url: "https://github.com/huggingface/swift-transformers", .upToNextMinor(from: "1.3.5")),
        // In-app updates (ADR 0007). Linked only by the app target.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // MARK: Libraries

        .target(name: "GlintCore", swiftSettings: strictSettings),
        .target(name: "GlintExtractors", dependencies: ["GlintCore"], swiftSettings: strictSettings),
        .target(
            name: "GlintEmbedding",
            dependencies: [
                "GlintCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "GlintStore",
            dependencies: ["GlintCore"],
            swiftSettings: strictSettings,
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "GlintSearch", dependencies: ["GlintCore", "GlintStore"], swiftSettings: strictSettings),
        .target(
            name: "GlintIndexer",
            dependencies: ["GlintCore", "GlintExtractors", "GlintEmbedding", "GlintStore"],
            swiftSettings: strictSettings
        ),
        .target(name: "GlintLicensing", dependencies: ["GlintCore"], swiftSettings: strictSettings),
        .target(name: "GlintTelemetry", dependencies: ["GlintCore"], swiftSettings: strictSettings),
        .target(name: "GlintLocalAPI", dependencies: ["GlintCore", "GlintSearch"], swiftSettings: strictSettings),
        // Self-contained: speaks HTTP to the app, so the glint-mcp binary stays small.
        .target(name: "GlintMCP", swiftSettings: strictSettings),
        .target(
            name: "GlintUI",
            dependencies: ["GlintCore", "GlintSearch", "GlintLicensing"],
            swiftSettings: strictSettings
        ),

        // MARK: Executables

        .executableTarget(
            name: "GlintApp",
            dependencies: [
                "GlintCore", "GlintExtractors", "GlintEmbedding", "GlintStore", "GlintSearch",
                "GlintIndexer", "GlintLicensing", "GlintTelemetry", "GlintUI", "GlintLocalAPI",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            swiftSettings: strictSettings,
            // Sparkle.framework is embedded in Glint.app/Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "GlintEval",
            dependencies: [
                "GlintCore", "GlintExtractors", "GlintEmbedding", "GlintStore", "GlintSearch", "GlintIndexer", "GlintTestSupport",
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(name: "GlintMCPTool", dependencies: ["GlintMCP"], swiftSettings: strictSettings),
        .executableTarget(
            name: "GlintLicenseTool",
            dependencies: ["GlintCore", "GlintLicensing"],
            swiftSettings: strictSettings
        ),

        // MARK: Tests

        .target(
            name: "GlintTestSupport",
            dependencies: ["GlintCore"],
            path: "Tests/GlintTestSupport",
            swiftSettings: strictSettings
        ),
        .testTarget(name: "GlintCoreTests", dependencies: ["GlintCore"], swiftSettings: strictSettings),
        .testTarget(
            name: "GlintExtractorsTests",
            dependencies: ["GlintExtractors", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintEmbeddingTests",
            dependencies: [
                "GlintEmbedding", "GlintTestSupport",
                // Reference for the compact tokenizer's parity test.
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            exclude: ["Fixtures"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintStoreTests",
            dependencies: ["GlintStore", "GlintTestSupport"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintSearchTests",
            dependencies: ["GlintSearch", "GlintStore", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintIndexerTests",
            dependencies: [
                "GlintIndexer", "GlintSearch", "GlintStore", "GlintExtractors", "GlintEmbedding", "GlintTestSupport",
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintLocalAPITests",
            dependencies: ["GlintLocalAPI", "GlintMCP", "GlintSearch", "GlintStore", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "GlintMCPTests", dependencies: ["GlintMCP"], swiftSettings: strictSettings),
        .testTarget(
            name: "GlintLicensingTests",
            dependencies: ["GlintLicensing"],
            resources: [.copy("Fixtures")],
            swiftSettings: strictSettings
        ),
        .testTarget(name: "GlintTelemetryTests", dependencies: ["GlintTelemetry"], swiftSettings: strictSettings),
        .testTarget(
            name: "GlintUITests",
            dependencies: ["GlintUI", "GlintSearch", "GlintStore", "GlintLicensing", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintPerformanceTests",
            dependencies: [
                "GlintSearch", "GlintStore", "GlintEmbedding", "GlintTestSupport", "GlintIndexer", "GlintExtractors",
            ],
            swiftSettings: strictSettings
        ),
    ]
)
