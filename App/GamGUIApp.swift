import AppKit
import Directory
import GamEngine
import Setup
import SwiftUI

@main
struct GamGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = AppServices.make()

    var body: some Scene {
        WindowGroup("GamGUI") {
            ContentView(services: services)
                .task { await Spikes.runIfRequested(services: services) }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a launch with no window at all.
        .restorationBehavior(.disabled)
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case home = "Home"
    case users = "Users"
    case setup = "Setup"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .users: "person.2"
        case .setup: "key"
        }
    }

    /// The screen a launch opens on: Home, or in debug builds `SWIFTGAMGUI_SCREEN` (for snapshots).
    static var initial: Screen {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SCREEN"],
           let screen = allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { return screen }
        #endif
        return .home
    }
}

/// The widths the window is built from. On macOS 27, when a person's page opens, SwiftUI adds the
/// inspector's width (and the floating sidebar's, a second time) to the list's minimum without raising
/// the window's: in a window narrower than that sum, AppKit loops until it raises NSGenericException
/// (failure-log 2026-10-10). So the sidebar and the inspector are bounded, and the smallest window holds
/// both at their widest with `Spikes.spareWidth` to spare; the screenshot runs check it.
enum ColumnWidths {
    static let sidebar = (min: 150.0, ideal: 170.0, max: 190.0)
    static let inspector = (min: 320.0, ideal: 360.0, max: 400.0)
    static let windowMin = 920.0
}

struct ContentView: View {
    let services: AppServices
    @State private var screen: Screen? = Screen.initial
    @State private var gamVersion: String?

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: ColumnWidths.sidebar.min, ideal: ColumnWidths.sidebar.ideal,
                                            max: ColumnWidths.sidebar.max)
        } detail: {
            switch screen ?? .home {
            case .home:
                HomeView(setup: services.setup, directory: services.directory, gamVersion: gamVersion,
                         hasGam: services.gam != nil, executor: services.executor, auditURL: services.auditURL) { screen = .setup }
                    .navigationTitle("Home")
            case .users:
                UsersView(setup: services.setup, directory: services.directory, changes: services.userChanges,
                          access: services.userAccess)
                    .navigationTitle("Users")
            case .setup:
                SetupView(model: services.setup)
                    .navigationTitle("Setup")
            }
        }
        .navigationSubtitle(services.setup.active.map { "Connected to \($0.name)" } ?? "Not connected")
        .frame(minWidth: ColumnWidths.windowMin, minHeight: 520)
        .task {
            // Local and credential-free.
            if let gam = services.gam {
                gamVersion = await GamVersion.running(gam.runner, runtimeDirectory: gam.runtimeDirectory)
            }
        }
        .task {
            // The domain connected last time is checked again (one Touch ID), and connecting loads the
            // directory: no trip to Setup on every launch. Never during a spike or a snapshot.
            guard !Spikes.isRequested else { return }
            await services.setup.reconnect()
        }
    }
}
