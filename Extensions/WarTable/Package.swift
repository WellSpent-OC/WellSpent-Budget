// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription
let package = Package(name: "WarTable", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WarTableCore", targets: ["WarTableCore"])],
    targets: [.target(name: "WarTableCore")])
