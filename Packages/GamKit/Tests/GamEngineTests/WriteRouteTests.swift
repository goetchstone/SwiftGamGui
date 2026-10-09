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

    static func files(in directory: String, matching needles: [String], orWord word: String? = nil) throws -> Set<String> {
        Set(try swiftFiles(in: directory).filter { file in
            file.lines.contains { line in
                needles.contains { line.contains($0) } || word.map { line.contains(try! Regex("\\b\($0)\\b")) } == true
            }
        }.map(\.path))
    }

    /// Any use of Foundation's `Process` type, however spelled (`Process()`, `: Process = .init()`,
    /// `Process.launchedProcess`), plus the lower-level and indirect ways to start a program.
    static let processWord = "Process"
    static let processStarts = ["posix_spawn", "NSTask", "execv", "execl", "popen(", "system(", "fork(", "dlopen(",
                                "dlsym(", "NSUserUnixTask", "NSUserScriptTask", "NSUserAppleScriptTask",
                                "NSUserAutomatorTask", "NSAppleScript", "OSAScript", "OSAKit", "LSOpen",
                                "openApplication", "launchApplication", "SMAppService", "NSXPCConnection", "xpc_"]
    /// Reinterpreting memory would forge a `GamRead` from a write's argv.
    static let memoryCasts = ["unsafeBitCast", "unsafeDowncast", "withMemoryRebound", "assumingMemoryBound",
                              "bindMemory", "unsafeAddress"]

    @Test func onlyGamRunnerStartsAProcess() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: Self.processStarts, orWord: Self.processWord)
                == ["Packages/GamKit/Sources/GamEngine/GamRunner.swift"])
        #expect(try Self.files(in: "App", matching: Self.processStarts, orWord: Self.processWord).isEmpty)
    }

    @Test func onlyTheBuildersMintCommands() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["GamRead(", "GamWrite("])
                == ["Packages/GamKit/Sources/GamEngine/GamCommands.swift"])
        #expect(try Self.files(in: "App", matching: ["GamRead(", "GamWrite("]).isEmpty)
    }

    /// `GamRunner.runRaw` takes any argv, and without a config directory GAM falls back to `~/.gam`
    /// (the operator's own GAM, if any). Only the authenticated runner (credentials) and the version probe
    /// (an empty config) call it, and only they make a config directory.
    @Test func onlyTheRunnersCallTheRawRunner() throws {
        let runners: Set = ["Packages/GamKit/Sources/GamEngine/AuthenticatedRunner.swift",
                            "Packages/GamKit/Sources/GamEngine/GamVersion.swift"]
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["runRaw("])
                == runners.union(["Packages/GamKit/Sources/GamEngine/GamRunner.swift"]))
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["materialize("])
                == runners.union(["Packages/GamKit/Sources/GamEngine/EphemeralConfig.swift"]))
    }

    @Test func theAppNeverReinterpretsMemory() throws {
        #expect(try Self.files(in: "App", matching: Self.memoryCasts).isEmpty)
    }

    /// Invariant 2: the runner's write entry takes a `WriteTicket`, and only ChangeCore's executor makes
    /// one, after a held preview passed every check. A ticket anywhere else is a second write path.
    @Test func onlyTheExecutorMintsAWriteTicket() throws {
        #expect(try Self.files(in: "Packages/GamKit/Sources", matching: ["WriteTicket("])
                == ["Packages/GamKit/Sources/ChangeCore/ChangeCore.swift"])
        #expect(try Self.files(in: "App", matching: ["WriteTicket"]).isEmpty)
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
