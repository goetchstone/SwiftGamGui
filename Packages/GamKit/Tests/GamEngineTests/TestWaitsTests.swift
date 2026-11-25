import Foundation
import Testing
import TestSupport

/// A test that waits for something waits through `yieldWhile`, bounded and failing at its limit, never on a sleep or a yield of
/// its own. Six fixes in November were one failure: a test that waited on time or without end (failure log 2026-11-13 busy
/// runner, 11-14 mid-call and pool lock, 11-21 lock timer, 11-24 unbounded waits), and the sweep that fixed the last one missed
/// eight loops spelled with `Task.sleep` instead. A pause that isn't a wait (time for something that must not happen, a task
/// cancelled at once) says so on its line: `// not a wait: <why>`.
struct TestWaitsTests {
    static let pauses = ["sleep", "yield"].map { "Task." + $0 + "(" }

    @Test func everyWaitInATestIsBounded() throws {
        let files = try WriteRouteTests.swiftFiles(in: "Packages/GamKit/Tests")
        #expect(files.count > 50, "the scan must see the tests")
        let unmarked = files.flatMap { file in
            file.lines.filter { line in Self.pauses.contains(where: line.contains) && !line.contains("// not a wait: ") }
                .map { "\(file.path): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        #expect(unmarked.isEmpty, "wait with `yieldWhile`, or say why it isn't a wait:\n\(unmarked.joined(separator: "\n"))")
    }
}
