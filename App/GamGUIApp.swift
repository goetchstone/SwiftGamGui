import AppKit
import GamEngine
import SwiftUI

@main
struct GamGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("GamGUI") {
            PlaceholderView()
                .task { await Spikes.runIfRequested() }
        }
    }
}

struct PlaceholderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GamGUI").font(.largeTitle.bold())
            Text("Native GamGUI — phase 1 scaffold. Nothing here talks to Google yet.")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(minWidth: 480, minHeight: 240, alignment: .topLeading)
    }
}
