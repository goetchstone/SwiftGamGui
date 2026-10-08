import AppKit
import GamEngine
import Setup
import SwiftUI

@main
struct GamGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var setup = AppServices.makeSetup()

    var body: some Scene {
        WindowGroup("GamGUI") {
            ContentView(setup: setup)
                .task { await Spikes.runIfRequested(setup: setup) }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a launch with no window at all.
        .restorationBehavior(.disabled)
    }
}

struct ContentView: View {
    let setup: SetupModel

    var body: some View {
        NavigationStack {
            SetupView(model: setup)
                .navigationTitle("Setup")
                .navigationSubtitle(setup.active.map { "Connected to \($0.name)" } ?? "Not connected")
        }
        .frame(minWidth: 640, minHeight: 520)
    }
}
