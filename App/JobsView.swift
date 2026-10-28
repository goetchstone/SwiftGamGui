import Jobs
import SwiftUI

/// The jobs tray (GamGUI's plan U5) in every window's toolbar: how many runs are going, and on a click every run since launch,
/// running first, each with where it stands, its newest steps and its failures in words, and Stop. Reads the board only; Stop
/// asks the executor to stop after the step in flight, which always finishes and is audited (`JobBoard`).
struct JobsButton: View {
    let board: JobBoard
    @State private var open = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let running = board.running
        Button { open.toggle() } label: {
            Label(running == 0 ? "Jobs" : "\(running) Running", systemImage: running == 0 ? "checklist" : "arrow.triangle.2.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .help(running == 0 ? "The changes run since GAM GUI started" : "\(running) change\(running == 1 ? " is" : "s are") running: see where each stands")
        .accessibilityLabel(running == 0 ? "Jobs" : "Jobs: \(running) running")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            JobsTray(board: board).frame(width: 440, height: 480)
        }
        // A run that ends is said from the window in front: by the board's counter, so a step redraws nothing here.
        .onChange(of: board.finishedCount) {
            if appearsActive, let job = board.lastFinished {
                AccessibilityNotification.Announcement("Finished: \(job.title). \(job.status)").post()
            }
        }
    }
}

/// The tray's list: at most `JobBoard.trayRows`, running first, each opening to its steps.
struct JobsTray: View {
    let board: JobBoard
    @State private var stopping: Job?

    var body: some View {
        let tray = board.tray
        VStack(alignment: .leading, spacing: 0) {
            Text("Jobs").font(.headline).accessibilityAddTraits(.isHeader).padding([.horizontal, .top])
            if tray.rows.isEmpty {
                ContentUnavailableView("Nothing Has Run", systemImage: "checklist",
                                       description: Text("A change you confirm is listed here while it runs and after it ends."))
            } else {
                List(tray.rows) { job in
                    JobRow(job: job) { stopping = job }
                }
                .listStyle(.inset)
                if tray.more > 0 {
                    Text("And \(tray.more) older not listed.").font(.callout).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            Text("Every change is in Audit too. To try again what failed or didn't run, use the screen that ran it: its preview "
                 + "shows what's left.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding()
        }
        .confirmationDialog(stopping.map { "Stop \($0.title)?" } ?? "", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            presenting: stopping) { job in
            Button("Stop After This Step", role: .destructive) { Task { await board.stop(job.id) } }
            Button("Keep Running", role: .cancel) {}
        } message: { _ in
            Text("The step running now finishes. The steps after it won't run: the run may be left part done, so check its screen.")
        }
    }
}

/// One run: its name, where it stands in words and a bar (never color alone), Stop while it runs, and its steps.
private struct JobRow: View {
    let job: Job
    let stop: () -> Void

    private var symbol: String {
        guard job.finished else { return "arrow.triangle.2.circlepath" }
        return job.failedTotal > 0 ? "exclamationmark.triangle.fill" : job.notRun + job.waiting > 0 ? "pause.circle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title).fontWeight(.semibold)
                        Text(job.status).font(.callout).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: symbol).symbolRenderingMode(.multicolor)
                }
                .accessibilityElement(children: .combine)
                Spacer()
                if !job.finished {
                    Button("Stop…", action: stop)
                        .disabled(job.stopping)
                        .accessibilityLabel("Stop \(job.title)")
                        .accessibilityHint("Asks first. The step running finishes; the rest don't run.")
                }
            }
            if !job.finished, job.total > 0 {
                ProgressView(value: Double(job.done), total: Double(job.total))
                    .accessibilityLabel("\(job.done) of \(job.total) steps done")
            }
            if !job.recent.isEmpty || !job.failed.isEmpty {
                DisclosureGroup("Steps") {
                    VStack(alignment: .leading, spacing: 4) {
                        if !job.failed.isEmpty {
                            Text("Failed").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                            ForEach(Array(job.failed.enumerated()), id: \.offset) { _, step in StepLine(step: step) }
                            if job.more > 0 { Text("And \(job.more) more.").foregroundStyle(.secondary) }
                        }
                        Text(job.done > job.recent.count ? "The newest \(job.recent.count)" : "Each step").fontWeight(.semibold)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(Array(job.recent.enumerated()), id: \.offset) { _, step in StepLine(step: step) }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// A step: what it was, how it ended in words, and why when it didn't succeed.
private struct StepLine: View {
    let step: Job.Step

    private var ended: String {
        switch step.outcome {
        case .succeeded: "Done"
        case .failed: "Failed"
        case .notRun: "Not run"
        case .waiting: "Waiting for Google"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(ended): \(step.item)")
            if !step.detail.isEmpty { Text(step.detail).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
