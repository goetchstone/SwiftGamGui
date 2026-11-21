import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's answers to the audit runs' reads (plan F3), each as GAM 7.52.04 answers it, and each way GAM fails or
/// passes over something without a word, which the runs must read as unknown, never as none.
@Suite("Mock audit-run reads")
struct MockAuditRunTests {
    let mock = GamRunner(binary: Fixtures.mockGam)

    /// One call, with GAM's first-run banner dropped from stdout; `state` names the mock's state markers to make.
    private func run(_ argv: [String], state: [String] = []) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let config = try Fixtures.placeholderConfigDirectory()
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mock-state-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: folder)
        }
        for marker in state {
            let url = folder.appending(path: marker)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let environment = Fixtures.mockEnvironment.merging(state.isEmpty ? [:] : ["GAM_MOCK_STATE": folder.path]) { $1 }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let data = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        return (result.exitCode, data, result.stderr)
    }

    static let licenseTitles = "userId,productId,productDisplay,skuId,skuDisplay"

    /// `print licenses`: every seat, GAM's titles and display names; a suspended account's seats and a seat on an address the
    /// directory doesn't hold are there to be found.
    @Test func everySeatIsListed() async throws {
        let read = try await run(["print", "licenses"])
        #expect(read.exitCode == 0)
        let rows = GamOutput.records(read.stdout)
        #expect(read.stdout.hasPrefix(Self.licenseTitles + "\n"))
        #expect(rows.count == 7)
        #expect(rows.filter { $0["userId"] == .string("bob@example.com") }.count == 2)
        #expect(rows.contains { $0["userId"] == .string("left@example.com") })
        #expect(rows.allSatisfy { $0["skuDisplay"]?.string?.isEmpty == false })
    }

    /// GAM passes over a product Google refuses without a word or a code: titles alone, or one product gone, exit 0. Without
    /// the License Manager scope it exits 15 before any read.
    @Test func aRefusedProductIsPassedOverAndANoScopeTokenExits15() async throws {
        let silent = try await run(["print", "licenses"], state: ["licenses_silent"])
        #expect(silent.exitCode == 0 && GamOutput.records(silent.stdout).isEmpty && silent.stderr.isEmpty)
        #expect(silent.stdout.hasPrefix(Self.licenseTitles))
        let partial = try await run(["print", "licenses"], state: ["licenses_partial"])
        #expect(partial.exitCode == 0 && partial.stderr.isEmpty)
        #expect(GamOutput.records(partial.stdout).count == 6)
        #expect(!partial.stdout.contains("Google-Vault"))
        let refused = try await run(["print", "licenses"], state: ["nolicensing"])
        #expect(refused.exitCode == 15 && refused.stderr.contains("License Manager API"))
        #expect(GamOutput.records(refused.stdout).isEmpty)
    }

    /// Only the bare command is modelled: the app names no product or SKU.
    @Test func anotherShapeIsNotModelled() async throws {
        for argv in [["print", "licenses", "countsonly"], ["print", "licenses", "products", "Google-Apps"]] {
            let read = try await run(argv)
            #expect(read.exitCode == 2 && read.stderr.contains("isn't modelled"), "\(argv)")
        }
    }

    /// A directory read Google refused part way: the rows GAM had and exit 50, never the whole directory.
    @Test func aDirectoryThatStopsShortWritesWhatItHadAndExits50() async throws {
        let argv = ["print", "users", "fields", GamCommands.cacheFields.joined(separator: ","), "formatjson"]
        let whole = try await run(argv)
        #expect(whole.exitCode == 0 && GamOutput.records(whole.stdout).count == 5)
        let short = try await run(argv, state: ["directory_fails"])
        #expect(short.exitCode == 50 && short.stderr.contains("Print Failed"))
        #expect(GamOutput.records(short.stdout).count == 1)
    }

    /// The directory names when each account was made, as GAM prints a time (formatLocalTime): the inactive run's "new
    /// account" flag reads it, so the mock never leaves every account's creation unknown.
    @Test func everyAccountSaysWhenItWasMade() async throws {
        let read = try await run(["print", "users", "fields", GamCommands.cacheFields.joined(separator: ","), "formatjson"])
        for user in GamOutput.records(read.stdout) {
            let made = try #require(user["creationTime"]?.string)
            #expect(made.count == 20 && made.hasSuffix("Z") && made.dropFirst(10).hasPrefix("T"), "\(made)")
        }
    }
}
