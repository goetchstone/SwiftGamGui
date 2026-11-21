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
        .library(name: "Jobs", targets: ["Jobs"]),
        .library(name: "Stores", targets: ["Stores"]),
        .library(name: "Assist", targets: ["Assist"]),
        .library(name: "Setup", targets: ["Setup"]),
        .library(name: "Directory", targets: ["Directory"]),
    ],
    targets: [
        .target(name: "GamEngine", dependencies: ["Vault"]),
        .target(name: "ChangeCore", dependencies: ["GamEngine", "Vault", "Jobs"]),
        .target(name: "Vault"),
        .target(name: "Jobs"),
        // ChangeCore for the protocol its signature backups implement (`SignatureKeeper`): only the executor keeps into them.
        .target(name: "Stores", dependencies: ["GamEngine", "ChangeCore", "Vault"]),
        .target(name: "Assist"),
        .target(name: "Setup", dependencies: ["GamEngine", "Vault"]),
        // Jobs for what a domain switch would stop (`SwitchStops`): the tray's runs, read only.
        .target(name: "Directory", dependencies: ["Setup", "GamEngine", "Vault", "ChangeCore", "Stores", "Jobs"]),
        .target(name: "TestSupport", dependencies: ["GamEngine", "Vault"]),
        .testTarget(name: "GamEngineTests", dependencies: ["GamEngine", "Vault", "TestSupport"]),
        .testTarget(name: "VaultTests", dependencies: ["Vault"]),
        .testTarget(name: "ChangeCoreTests", dependencies: ["ChangeCore", "GamEngine", "Vault", "Jobs", "TestSupport"]),
        .testTarget(name: "SetupTests", dependencies: ["Setup", "GamEngine", "Vault", "TestSupport"]),
        .testTarget(name: "DirectoryStoreTests", dependencies: ["Directory", "Setup", "GamEngine", "Vault", "ChangeCore", "Stores", "Jobs", "TestSupport"]),
        .testTarget(name: "StoresTests", dependencies: ["Stores", "GamEngine", "ChangeCore", "Vault", "TestSupport"]),
        .testTarget(name: "AssistTests", dependencies: ["Assist", "GamEngine", "TestSupport"]),
        .testTarget(name: "SpikeTests"),
    ]
)
