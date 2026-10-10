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
        .executable(name: "Glint", targets: ["GlintApp"]),
        .executable(name: "glint-eval", targets: ["GlintEval"]),
        .executable(name: "glint-license", targets: ["GlintLicenseTool"]),
        .library(name: "GlintCore", targets: ["GlintCore"]),
    ],
    targets: [
        // MARK: Libraries

        .target(name: "GlintCore", swiftSettings: strictSettings),
        .target(name: "GlintExtractors", dependencies: ["GlintCore"], swiftSettings: strictSettings),
        .target(name: "GlintEmbedding", dependencies: ["GlintCore"], swiftSettings: strictSettings),
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
                "GlintIndexer", "GlintLicensing", "GlintTelemetry", "GlintUI",
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "GlintEval",
            dependencies: ["GlintCore", "GlintExtractors", "GlintEmbedding", "GlintStore", "GlintSearch", "GlintIndexer"],
            swiftSettings: strictSettings
        ),
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
            dependencies: ["GlintEmbedding", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintStoreTests",
            dependencies: ["GlintStore", "GlintTestSupport"],
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
        .testTarget(name: "GlintLicensingTests", dependencies: ["GlintLicensing"], swiftSettings: strictSettings),
        .testTarget(name: "GlintTelemetryTests", dependencies: ["GlintTelemetry"], swiftSettings: strictSettings),
        .testTarget(
            name: "GlintUITests",
            dependencies: ["GlintUI", "GlintSearch", "GlintLicensing", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "GlintPerformanceTests",
            dependencies: ["GlintSearch", "GlintStore", "GlintEmbedding", "GlintTestSupport"],
            swiftSettings: strictSettings
        ),
    ]
)
