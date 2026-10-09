import Foundation
import Testing
import TestSupport

/// Invariant 2's structural half, as a source scan (the native port of GamGUI's
/// `test_write_routes_guarded.py`; its bare-confirm, edited-form and replay cases arrive with ChangeCore's
/// executor). Access levels close most routes to a credentialed `gam` at compile time; this closes the
/// ones the compiler can't see: another process start, another source of commands, another caller of
/// the raw runner.
@Suite("Write routes")
struct WriteRouteTests {
    static let root = Fixtures.repoRoot

    /// Every Swift file under `directory`, as (path relative to the repo, code lines without comments).
    static func swiftFiles(in directory: String) throws -> [(path: String, lines: [String])] {
        let base = root.appending(path: directory)
        let paths = try #require(FileManager.default.subpathsOfDirectory(atPath: base.path) as [String]?)
        return try paths.filter { $0.hasSuffix(".swift") }.sorted().map { path in
            let text = try String(contentsOf: base.appending(path: path), encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            return ("\(directory)/\(path)", code)
        }
    }

    static func files(in directory: String, matching needles: [String]) throws -> Set<String> {
        Set(try swiftFiles(in: directory).filter { file in
            file.lines.contains { line in needles.contains { line.contains($0) } }
        }.map(\.path))
    }

    static let processStarts = ["posix_spawn", "Process(", "Process.run", "NSTask", "execv", "execl", "popen(",
                                "system(", "fork(", "NSUserUnixTask", "NSAppleScript"]

    @Test func onlyGamRunnerStartsAProcess() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: Self.processStarts)
                == ["Packages/GamKit/Sources/GamEngine/GamRunner.swift"])
        #expect(try Self.files(in: "App", matching: Self.processStarts).isEmpty)
    }

    @Test func onlyTheBuildersMintCommands() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["GamRead(", "GamWrite("])
                == ["Packages/GamKit/Sources/GamEngine/GamCommands.swift"])
        #expect(try Self.files(in: "App", matching: ["GamRead(", "GamWrite("]).isEmpty)
    }

    /// `GamRunner.run(_:configDirectory:…)` takes any argv: only the authenticated runner (credentials)
    /// and the version probe (no credentials) call it.
    @Test func onlyTheRunnersCallTheRawRunner() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["configDirectory: config.url"])
                == ["Packages/GamKit/Sources/GamEngine/AuthenticatedRunner.swift",
                    "Packages/GamKit/Sources/GamEngine/GamVersion.swift"])
    }

    /// The app reaches GamKit only through its public API: `@testable` would reopen every route.
    @Test func theAppNeverImportsGamKitTestably() throws {
        #expect(try Self.files(in: "App", matching: ["@testable"]).isEmpty)
    }

    /// The scan must see the code it guards, or every check above passes vacuously.
    @Test func theScanSeesTheRunnerAndTheApp() throws {
        let sources = try Self.swiftFiles(in: "Packages/GamKit/Sources")
        #expect(sources.contains { $0.path.hasSuffix("GamEngine/GamRunner.swift") && $0.lines.contains { $0.contains("posix_spawn(") } })
        #expect(try Self.swiftFiles(in: "App").count > 5)
    }
}
