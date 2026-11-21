import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// The strict mock's `todrive` (plan F4), as GAM 7.52.04's `CSVPrintFile.GetTodriveParameters` and `writeCSVToDrive` do it, read
/// to the end of the function: the read runs, its CSV is uploaded and never printed, the link is printed instead, and each way
/// the upload stops says so in GAM's own words, with the file made or not as GAM leaves it. GamGUI's mock (#174) was the lead,
/// GAM's source the oracle. Nothing here has run against a real tenant: the first live export waits on the operator's yes.
@Suite("Mock Sheet export")
struct MockSheetExportTests {
    let mock = GamRunner(binary: Fixtures.mockGam)
    static let admin = "admin@example.com"
    static let title = "example.com - List mailbox delegates"
    static let delegates = ["user", "alice@example.com", "print", "delegates"]
    static let tail = GamCommands.todriveArgs(title: title)
    /// Only the new file's link, as GAM prints it (`printKeyValueList`), and nothing else.
    static func isLink(_ stdout: String) -> Bool {
        stdout.wholeMatch(of: /Data uploaded to Drive File:\nhttps:\/\/docs\.google\.com\/spreadsheets\/d\/1MockSheet\d+\/edit\?usp=drivesdk\n/) != nil
    }

    struct Ran {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// The files the upload made: (title, rows), from GAM_MOCK_STATE/drive_files.
        let made: [(title: String, rows: Int)]
    }

    /// One call as the admin, with GAM's first-run banner dropped from stdout; `state` names the mock's state markers to make,
    /// and `missing` the delegated scopes the simulated tenant hasn't authorized (GAM_MOCK_STATE/dwd_missing).
    private func run(_ argv: [String], state: [String] = [], missing: [String] = [], admin: String = MockSheetExportTests.admin) async throws -> Ran {
        let config = try Fixtures.placeholderConfigDirectory()
        try Fixtures.oauth2(admin: admin).write(to: config.appending(path: "oauth2.txt"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-mock-state-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: config)
            try? FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for marker in state {
            let url = folder.appending(path: marker)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        if !missing.isEmpty { try Data(missing.map { $0 + "\n" }.joined().utf8).write(to: folder.appending(path: "dwd_missing")) }
        let environment = Fixtures.mockEnvironment.merging(["GAM_MOCK_STATE": folder.path]) { $1 }
        let result = try await mock.runRaw(argv, configDirectory: config, extraEnvironment: environment)
        let stdout = result.stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains(config.lastPathComponent) }.joined(separator: "\n")
        let files = (try? String(contentsOf: folder.appending(path: "drive_files"), encoding: .utf8)) ?? ""
        let made = files.split(separator: "\n").map { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return (String(fields[1]), Int(fields[2]) ?? -1)
        }
        return Ran(exitCode: result.exitCode, stdout: stdout, stderr: result.stderr, made: made)
    }

    @Test func theReadIsUploadedAndOnlyTheLinkPrinted() async throws {
        let plain = try await run(Self.delegates)
        let export = try await run(Self.delegates + Self.tail)
        #expect(export.exitCode == 0 && Self.isLink(export.stdout), "\(export.stdout)")
        #expect(!export.stdout.contains("delegateAddress"), "the CSV goes to Drive, never to stdout")
        #expect(export.made.map(\.title) == [Self.title])
        #expect(export.made.map(\.rows) == [GamOutput.records(plain.stdout).count])
    }

    /// GAM's Drive token refused (`userServiceNotEnabledWarning`, API.DRIVE3's name): 73, nothing made.
    @Test func withoutDriveNothingIsMade() async throws {
        let export = try await run(Self.delegates + Self.tail, missing: [SheetExportScopes.drive])
        #expect(export.exitCode == 73 && export.stdout.isEmpty)
        #expect(export.stderr.contains("User: \(Self.admin), Drive API v3 Service/App not enabled"))
        #expect(export.made.isEmpty)
    }

    /// The Sheets step comes after the file is made: 73, the file there, no link.
    @Test func withoutSheetsTheFileIsMadeAndNoLinkPrinted() async throws {
        let export = try await run(Self.delegates + Self.tail, missing: [SheetExportScopes.sheets])
        #expect(export.exitCode == 73 && export.stdout.isEmpty)
        #expect(export.stderr.contains("User: \(Self.admin), Sheets API Service/App not enabled"))
        #expect(export.made.count == 1)
    }

    /// `files.create` refused (a full Drive): `entityActionFailedWarning` after `Act.Set(Act.CREATE)`, never ", Failed".
    @Test func aFullDriveMakesNothing() async throws {
        let export = try await run(Self.delegates + Self.tail, state: ["drive_full"])
        #expect(export.exitCode == 50 && export.stdout.isEmpty && export.made.isEmpty)
        #expect(export.stderr.contains("Drive Folder: root, Create Failed: "))
    }

    /// A Sheets call refused once its token is had: `todriveCSVErrorExit`, 50, the file made.
    @Test func aSheetsStepRefusedAfterTheCreateLeavesTheFile() async throws {
        let export = try await run(Self.delegates + Self.tail, state: ["sheets_fail"])
        #expect(export.exitCode == 50 && export.stdout.isEmpty && export.made.count == 1)
        #expect(export.stderr.contains("ERROR: User: \(Self.admin), Drive File ID: 1MockSheet"))
        #expect(export.stderr.contains(", Not Created: "))
    }

    /// printShowDelegates at 7.52.04: the account's token is refused (a soft error: rc 50, `continue`), the loop ends, and
    /// `writeCSVfile` writes the titles. Plain, that's the header on stdout; exported, a Sheet holding only its headers, its
    /// link, exit 50.
    @Test func aReadOfAnAccountThatIsntThereUploadsItsHeaders() async throws {
        let missing = ["user", "missing@example.com", "print", "delegates"]
        let plain = try await run(missing)
        #expect(plain.exitCode == 50 && plain.stdout.trimmingCharacters(in: .newlines) == "User,delegateAddress,delegationStatus")
        let export = try await run(missing + Self.tail)
        #expect(export.exitCode == 50 && Self.isLink(export.stdout) && export.stderr.contains("invalid_grant"))
        #expect(export.made.map(\.rows) == [0])
    }

    /// A warning the read itself set (Gmail off for the person: 73, the titles written) stands, and the upload happens all the
    /// same: the link and exit 73.
    @Test func aWarningExitAfterTheTableStillUploadsIt() async throws {
        let export = try await run(Self.delegates + Self.tail, state: ["nogmail/alice@example.com"])
        #expect(export.exitCode == 73 && Self.isLink(export.stdout))
        #expect(export.stderr.contains("User: alice@example.com, Gmail Service/App not enabled"))
        #expect(export.made.map(\.rows) == [0])
    }

    /// A read GAM refused before writing its table writes nothing, so nothing is uploaded: its own exit, no file.
    @Test func aReadThatStopsBeforeItsTableUploadsNothing() async throws {
        let export = try await run(["print", "users"] + Self.tail)
        #expect(export.exitCode == 2 && export.stdout.isEmpty && export.made.isEmpty)
    }

    /// Only the tail the app sends: GAM would take each of these, so a mock that took them too would hide a builder that drifted.
    @Test func onlyTheTailTheAppSendsIsTaken() async throws {
        for tail in [["todrive"], ["todrive", "tduser", "boss@example.com", "tdnobrowser", "true", "tdnoemail", "true"],
                     ["todrive", "tdnobrowser", "true", "tdnoemail", "true", "tdshare", "x@example.com", "reader"],
                     ["todrive", "tdnoemail", "true", "tdnobrowser", "true"],
                     ["todrive", "tdtitle", "T", "tdnobrowser", "false", "tdnoemail", "true"],
                     ["todrive", "tdtitle"]] {
            let export = try await run(Self.delegates + tail)
            #expect(export.exitCode == 2 && export.stderr.contains("ERROR: ") && export.made.isEmpty, "\(tail)")
        }
        // An empty title is GAM's to take (minLen=0): GAM then names the file itself.
        let untitled = try await run(Self.delegates + GamCommands.todriveArgs())
        #expect(untitled.exitCode == 0 && untitled.made.count == 1)
        // Only a print or report read takes it.
        let info = try await run(["info", "user", "alice@example.com"] + Self.tail)
        #expect(info.exitCode == 2 && info.stderr.contains("Invalid argument: todrive") && info.made.isEmpty)
    }

    /// GAM names the admin by checkUserExists' primaryEmail (GetTodriveParameters): a token naming an alias has its account's
    /// primary address in every upload line, and one naming no account is a usage error before anything runs.
    @Test func theUploadNamesTheAdminByItsPrimaryAddress() async throws {
        let alias = try await run(Self.delegates + Self.tail, missing: [SheetExportScopes.sheets], admin: "a.anders@example.com")
        #expect(alias.exitCode == 73 && alias.stderr.contains("User: alice@example.com, Sheets API Service/App not enabled"))
        let nobody = try await run(Self.delegates + Self.tail, admin: "nobody@example.com")
        #expect(nobody.exitCode == 2 && nobody.stderr.contains("Item: todrive_user, Value: nobody@example.com, Not Found") && nobody.made.isEmpty)
    }

    /// The scope check and the upload read the same tenant: a scope it hasn't authorized FAILs in the check and refuses the upload.
    @Test func theScopeCheckAndTheUploadAgree() async throws {
        let read = try GamCommands.checkServiceAccount(admin: Self.admin, scopes: [SheetExportScopes.drive, SheetExportScopes.sheets])
        let check = try await run(read.argv, missing: [SheetExportScopes.sheets])
        #expect(check.exitCode == 10)
        #expect(check.stdout.contains(/auth\/drive +PASS/) && check.stdout.contains(/auth\/spreadsheets +FAIL/))
        let both = try await run(read.argv)
        #expect(both.exitCode == 0 && !both.stdout.contains("FAIL"))
    }
}

/// The two delegated scopes, written out here so the mock's tests stand on their own.
enum SheetExportScopes {
    static let drive = "https://www.googleapis.com/auth/drive"
    static let sheets = "https://www.googleapis.com/auth/spreadsheets"
}
