// swift-tools-version: 6.2
// GamKit: everything below the SwiftUI layer. The app target sits outside this package, so a
// `package`-access symbol (ChangeCore's execution ticket, the Runner's write path) is invisible to
// views and App Intents by construction.

import PackageDescription

let package = Package(
    name: "GamKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "GamEngine", targets: ["GamEngine"]),
        .library(name: "ChangeCore", targets: ["ChangeCore"]),
        .library(name: "Vault", targets: ["Vault"]),
        .library(name: "Catalog", targets: ["Catalog"]),
        .library(name: "Jobs", targets: ["Jobs"]),
        .library(name: "Stores", targets: ["Stores"]),
        .library(name: "Assist", targets: ["Assist"]),
        .library(name: "Setup", targets: ["Setup"]),
    ],
    targets: [
        .target(name: "GamEngine", dependencies: ["Vault"]),
        .target(name: "ChangeCore", dependencies: ["GamEngine"]),
        .target(name: "Vault"),
        .target(name: "Catalog"),
        .target(name: "Jobs"),
        .target(name: "Stores"),
        .target(name: "Assist"),
        .target(name: "Setup", dependencies: ["GamEngine", "Vault"]),
        .target(name: "TestSupport", dependencies: ["GamEngine", "Vault"]),
        .testTarget(name: "GamEngineTests", dependencies: ["GamEngine", "Vault", "TestSupport"]),
        .testTarget(name: "VaultTests", dependencies: ["Vault"]),
        .testTarget(name: "SetupTests", dependencies: ["Setup", "GamEngine", "Vault", "TestSupport"]),
        .testTarget(name: "SpikeTests"),
    ]
)
