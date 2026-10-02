// swift-tools-version: 6.0
import PackageDescription

// Deliberately a separate package from the client.
//
// Vapor pulls in SwiftNIO, AsyncHTTPClient and a Postgres driver. None of that
// belongs in a Mac or iOS build, and keeping it here means `swift build` on the
// client stays fast. The shared types come in by path, so the wire format has one
// definition rather than two that drift.
let package = Package(
    name: "WellSpentServer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "WellSpentBudget", path: ".."),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.122.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.13.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.9.0"),
    ],
    targets: [
        .target(
            name: "WellSpentServerCore",
            dependencies: [
                .product(name: "WellSpentCrypto", package: "WellSpentBudget"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ]
        ),
        .executableTarget(
            name: "WellSpentServer",
            dependencies: ["WellSpentServerCore", .product(name: "Vapor", package: "vapor")]
        ),
        // Runs the real Swift client against the real server over HTTP. Lives in
        // the server package because that is the only place that can depend on
        // both sides at once.
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "WellSpentServerCore",
                .product(name: "WellSpentCrypto", package: "WellSpentBudget"),
                .product(name: "WellSpentModel", package: "WellSpentBudget"),
                .product(name: "WellSpentStore", package: "WellSpentBudget"),
                .product(name: "WellSpentSync", package: "WellSpentBudget"),
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "WellSpentServerTests",
            dependencies: [
                "WellSpentServerCore",
                .product(name: "WellSpentCrypto", package: "WellSpentBudget"),
                .product(name: "VaporTesting", package: "vapor"),
            ]
        ),
    ]
)
