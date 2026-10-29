// swift-tools-version: 6.0
// The Linux desktop app. Its screens are drawn with SwiftCrossUI on GTK 4.
// Everything below the screens is the package one folder up, the same code
// the Mac app runs: the data, the requests to the server, the actions, and
// each screen's rules and words (`Sources/WellSpentAppCore/Screens/`).
//
// Build and run on Linux:  swift run --package-path Linux
import PackageDescription

let package = Package(
    name: "WellSpentLinux",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Named, because a local package is otherwise named after its folder,
        // which differs from checkout to checkout.
        .package(name: "WellSpentBudget", path: ".."),
        .package(name: "WarTable", path: "../Extensions/WarTable"),
        .package(url: "https://github.com/stackotter/swift-cross-ui.git", exact: "0.10.0"),
    ],
    targets: [
        .systemLibrary(name: "CLibsecret", pkgConfig: "libsecret-1"),
        .systemLibrary(name: "CGtk4", pkgConfig: "gtk4"),
        // The bundled fonts are handed to fontconfig at start, so the style
        // sheet can name them without installing anything on the computer.
        .systemLibrary(name: "CFontconfig", pkgConfig: "fontconfig"),
        // Thin C wrappers for what Swift cannot call directly: libsecret's
        // variadic keyring calls, the GTK clipboard, and the native shell.
        .target(name: "WellSpentLinuxNative", dependencies: ["CLibsecret", "CGtk4", "CFontconfig"]),
        .executableTarget(
            name: "WellSpentLinux",
            dependencies: [
                "CGtk4",
                "WellSpentLinuxNative",
                .product(name: "WarTableCore", package: "WarTable"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
                // GTK directly: the "default backend" product also pulls in a
                // Windows-only piece that does not build on Linux.
                .product(name: "GtkBackend", package: "swift-cross-ui"),
                .product(name: "WellSpentAppCore", package: "WellSpentBudget"),
                .product(name: "WellSpentKeyStore", package: "WellSpentBudget"),
                .product(name: "WellSpentModel", package: "WellSpentBudget"),
                .product(name: "WellSpentStore", package: "WellSpentBudget"),
                .product(name: "WellSpentSync", package: "WellSpentBudget"),
                .product(name: "WellSpentCrypto", package: "WellSpentBudget"),
            ],
            // "live" or "staging", written by the packaging step. Only the exact
            // word "live" is live, as on the Mac.
            resources: [
                .copy("Resources/environment"),
                // The look (Design/App_Makeover) and the two fonts it names.
                .copy("Resources/app_style.css"),
                .copy("Resources/Fonts"),
            ]
        ),
        .testTarget(name: "WellSpentLinuxTests", dependencies: ["WellSpentLinux"]),
    ]
)
