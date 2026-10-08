import AppKit
import SwiftUI
import Testing

/// Phase 1 spike: the agent sees native UI only as images. Render a view, attach it, export it from
/// the test run (`swift test --attachments-path <dir>`), and read the PNG back.
@Suite("Snapshot pipeline spike")
struct SnapshotSpikeTests {
    @MainActor
    @Test func aSwiftUIViewRendersToAnAttachedImage() throws {
        let view = VStack(alignment: .leading, spacing: 8) {
            Text("GamGUI").font(.largeTitle.bold())
            Text("Snapshot pipeline spike").foregroundStyle(.secondary)
            HStack {
                Button("Preview") {}
                Button("Confirm") {}.buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 360, height: 180, alignment: .topLeading)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        Attachment.record(image, named: "snapshot-spike.png")
    }
}
