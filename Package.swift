// swift-tools-version: 6.0
import PackageDescription

// Platform floor is set by HPKE, which is macOS 14 / iOS 17.
// Verified against the local SDK: CryptoKit.swiftinterface marks
// `public enum HPKE` as @available(iOS 17.0, macOS 14.0, ...).
//
// The server is a separate package under Server/, so Vapor and its NIO dependency
// tree never slow down a client build.
let package = Package(
    name: "WellSpentBudget",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WellSpentCrypto", targets: ["WellSpentCrypto"]),
        .library(name: "WellSpentKeyStore", targets: ["WellSpentKeyStore"]),
        .library(name: "WellSpentModel", targets: ["WellSpentModel"]),
        .library(name: "WellSpentStore", targets: ["WellSpentStore"]),
        .library(name: "WellSpentSync", targets: ["WellSpentSync"]),
        .library(name: "WellSpentImport", targets: ["WellSpentImport"]),
        .library(name: "WellSpentAppCore", targets: ["WellSpentAppCore"]),
    ],
    dependencies: [
        // `import Crypto` re-exports CryptoKit on Apple platforms and uses
        // swift-crypto's own implementation on Linux. One call site, both platforms.
        // A range, not `from:`, so the server package can resolve a version its
        // Postgres driver also accepts. 4.5 has HPKE and CryptoExtras, so nothing
        // here depends on 5.
        .package(url: "https://github.com/apple/swift-crypto.git", "4.5.0" ..< "6.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        // Inspects a live SwiftUI hierarchy in process. XCUITest would need an
        // Xcode project, a real .app bundle and xcodebuild, none of which a
        // SwiftPM package has.
        // Pinned below 0.10.4: that release declares .visionOS(.v2) under
        // swift-tools-version 5.9, which this toolchain's PackageDescription
        // rejects outright with "'v2' is unavailable".
        .package(url: "https://github.com/nalexn/ViewInspector.git", "0.10.0" ..< "0.10.4"),
    ],
    targets: [
        .target(
            name: "WellSpentCrypto",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ],
            resources: [.process("Resources")]
        ),
        .target(
            name: "WellSpentKeyStore",
            dependencies: [
                "WellSpentCrypto",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "WellSpentModel",
            dependencies: ["WellSpentCrypto", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "WellSpentStore",
            dependencies: [
                "WellSpentModel",
                "WellSpentCrypto",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "WellSpentImport",
            dependencies: [
                "WellSpentModel",
                "WellSpentCrypto",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "WellSpentSync",
            dependencies: ["WellSpentStore", "WellSpentModel", "WellSpentCrypto", "WellSpentKeyStore"]
        ),

        // The app's logic, split out of the executable so it can be tested and
        // measured. An executable target is never linked into a test binary, so
        // anything left in WellSpentApp is invisible to both.
        .target(
            name: "WellSpentAppCore",
            dependencies: ["WellSpentStore", "WellSpentModel", "WellSpentCrypto",
                           "WellSpentImport", "WellSpentSync", "WellSpentKeyStore"]
        ),
        // The SwiftUI shell: views and the AppKit entry point. Deliberately thin,
        // because nothing in here can be unit tested without a UI harness.
        .executableTarget(
            name: "WellSpentApp",
            dependencies: ["WellSpentAppCore"],
            // Built from Design/AppIcon/AppIcon.svg by `make icon`.
            resources: [.copy("Resources/AppIcon.icns")]
        ),

        .testTarget(name: "WellSpentCryptoTests", dependencies: ["WellSpentCrypto"]),
        .testTarget(name: "WellSpentKeyStoreTests", dependencies: ["WellSpentKeyStore"]),
        .testTarget(name: "WellSpentStoreTests", dependencies: ["WellSpentStore"]),
        .testTarget(name: "WellSpentSyncTests", dependencies: ["WellSpentSync"]),
        .testTarget(name: "WellSpentImportTests", dependencies: ["WellSpentImport"]),
        .testTarget(
            name: "WellSpentAppCoreTests",
            dependencies: ["WellSpentAppCore", .product(name: "ViewInspector", package: "ViewInspector")]
        ),
    ]
)
