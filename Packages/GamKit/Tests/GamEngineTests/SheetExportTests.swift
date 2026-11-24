import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// Plan F4: a read's table to a new Google Sheet, GamGUI #174's `core/sheet_export.py` and `todrive_args`, word for word where
/// they say something, and read from GAM 7.52.04's own source where they read GAM. The flow through ChangeCore is
/// `SheetExportsTests` (Directory); the mock's output is `MockSheetExportTests`.
@Suite("Sheet export")
struct SheetExportTests {
    static let admin = "admin@example.com"
    static let title = "example.com - List mailbox delegates"
    static let read = GamCommands.printDelegates(email: "alice@example.com")

    // MARK: the argv

    @Test func theExportIsTheReadThenTheAdminsOwnUnsharedSheet() throws {
        let write = try GamCommands.exportToSheet(Self.read, title: Self.title)
        #expect(write.action == .exportToSheet)
        #expect(write.argv == Self.read.argv + ["todrive", "tdtitle", Self.title, "tdnobrowser", "true", "tdnoemail", "true"])
        // A title is one element, whatever it says; never another Drive, a share, an alert or a notice.
        let odd = try GamCommands.exportToSheet(Self.read, title: "a; rm -rf / tduser x@evil.example")
        #expect(odd.argv.count == Self.read.argv.count + 7 && odd.argv[Self.read.argv.count + 2] == "a; rm -rf / tduser x@evil.example")
        let options = odd.argv.enumerated().filter { $0.offset != Self.read.argv.count + 2 }.map(\.element)
        #expect(Set(options).isDisjoint(with: ["tduser", "tdshare", "tdalert", "tdnotify", "tdfrom", "tdparent", "tdfileid"]))
        #expect(GamCommands.todriveArgs() == ["todrive", "tdnobrowser", "true", "tdnoemail", "true"])
    }

    static let grammarFile = Fixtures.repoRoot.appending(path: "Vendor/gam7/GamCommands.txt")

    /// A tripwire for a GAM bump: the vendored grammar still takes each todrive option the export sends. The grammar is
    /// gitignored and CI's package tests run before GAM is vendored (so no test can reach the real binary there); a bump vendors
    /// it with `bump_gam.py` and then runs this suite, which is where a changed `<ToDriveAttribute>` shows.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: grammarFile.path), "needs the vendored GAM (scripts/fetch_gam.sh)"))
    func theGrammarTakesEachOptionTheTailSends() throws {
        let grammar = try String(contentsOf: Self.grammarFile, encoding: .utf8)
        let block = try #require(grammar.components(separatedBy: "<ToDriveAttribute> ::=").dropFirst().first?
            .components(separatedBy: "\n<").first)
        for option in ["(tdtitle <String>)", "(tdnobrowser [<Boolean>])", "(tdnoemail [<Boolean>])"] {
            #expect(block.contains(option), "\(option)")
        }
    }

    /// GAM reads a keyword lowercased with every `_` dropped (getArgument, 7.52.04): each spelling is todrive to it. A read
    /// carrying one would make a Sheet with no preview, so the export refuses it, as every read path does.
    @Test func aReadThatAlreadyExportsOrDoesntPrintIsRefused() throws {
        for spelling in ["todrive", "ToDrive", "to_drive", "TODRIVE", " t_o_d_r_i_v_e "] {
            #expect(GamCommands.carriesToDrive(Self.read.argv + [spelling]), "\(spelling)")
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.exportToSheet(GamRead(Self.read.argv + [spelling]), title: "T") }
        }
        #expect(!GamCommands.carriesToDrive(["print", "users", "query", "orgUnitPath='/Sales' todrive"]), "one element, a query")
        #expect(GamCommands.asKeyword(" To_Drive ") == "todrive")
        // An entity's bare list takes todrive at its end (`_doList` reads it right after `list`); the top-level list only before
        // its entity list, never at the end (review of #199).
        #expect(GamCommands.takesToDrive(["user", "alice@example.com", "list"]))
        #expect(!GamCommands.takesToDrive(["list", "user", "alice@example.com"]))
        #expect(!GamCommands.takesToDrive(["user", "alice@example.com", "list", "data", "x"]))
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.exportToSheet(GamRead(["list", "user", "alice@example.com"]), title: "T") }
        #expect(try GamCommands.exportToSheet(GamRead(["user", "alice@example.com", "list"]), title: "T").argv
                == ["user", "alice@example.com", "list"] + GamCommands.todriveArgs(title: "T"))
        // Only a print or report read takes todrive.
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.exportToSheet(GamCommands.infoUser(email: "a@example.com"), title: "T") }
        #expect(throws: Never.self) { try GamCommands.exportToSheet(GamCommands.printUsers(), title: "T") }
    }

    /// Whether a table is offered: a catalog line that names todrive, or a curated print or report read (GamGUI's
    /// `supports_export`).
    @Test func onlyAReadGamsTodriveTakesIsOffered() {
        #expect(SheetExport.takesToDrive(syntax: "gam <UserTypeEntity> print delegates|delegate [todrive <ToDriveAttribute>*]", curated: false))
        #expect(!SheetExport.takesToDrive(syntax: "gam info user <UserItem>", curated: false))
        #expect(SheetExport.takesToDrive(syntax: "gam user <email> print delegates", curated: true))
        #expect(!SheetExport.takesToDrive(syntax: "gam user <email> print delegates", curated: false))
        #expect(!SheetExport.takesToDrive(syntax: "gam user <email> show vacation", curated: true))
    }

    // MARK: what GAM's output means

    @Test func onlyAGoogleFileLinkIsALink() {
        let cases: [(String, String)] = [
            ("Data uploaded to Drive File:\nhttps://docs.google.com/spreadsheets/d/abc/edit?usp=drivesdk\n",
             "https://docs.google.com/spreadsheets/d/abc/edit?usp=drivesdk"),
            ("WARNING: Results are too large for Google Spreadsheets. Uploading as a regular CSV file.\n"
             + "Data uploaded to Drive File:\nhttps://drive.google.com/file/d/abc/view?usp=drivesdk\n",
             "https://drive.google.com/file/d/abc/view?usp=drivesdk"),
            ("  Data uploaded to Drive File:  \n\n  https://docs.google.com/spreadsheets/d/a  \nnext\n", "https://docs.google.com/spreadsheets/d/a"),
            ("Data uploaded to Drive File:\nhttps://evil.example/spreadsheets/d/abc\n", ""),
            ("Data uploaded to Drive File:\nhttp://docs.google.com/spreadsheets/d/abc\n", ""),
            ("Data uploaded to Drive File:\nhttps://x@docs.google.com/spreadsheets/d/abc\n", ""),
            ("Data uploaded to Drive File:\njavascript:alert(1)\n", ""),
            ("Data uploaded to Drive File:\nhttps://docs.google.com:evil/spreadsheets/d/abc\n", ""),
            ("Data uploaded to Drive File:\nhttps://docs.google.com:8443/spreadsheets/d/abc\n", ""),
            ("Data uploaded to Drive File:\nhttps://docs.google.com/spreadsheets/d/a\u{7f}bc\n", ""),
            ("Data uploaded to Drive File:\nhttps://docs.google.com\\@evil.example/d/a\n", ""),
            ("Data uploaded to Drive File: https://docs.google.com/spreadsheets/d/abc\n", ""),          // GAM's is on the next line
            ("Data uploaded to Drive File:\nhttps://docs.google.com/spreadsheets/d/a b\n", ""),          // more than the link
            ("x Data uploaded to Drive File:\nhttps://docs.google.com/spreadsheets/d/abc\n", ""),       // not at a line's start
            ("delegateAddress\nboss@example.com\n", ""),
        ]
        for (text, url) in cases {
            #expect(SheetExport.sheetURL(text) == url, "\(text)")
            #expect(SheetExport.noted(stdout: text, stderr: "", owner: Self.admin) == (url.isEmpty ? [:] : ["url": url]))
            let write = try! GamCommands.exportToSheet(Self.read, title: "T")
            #expect((write.notDone(output: text) != nil) == url.isEmpty, "an exit 0 without a link is no answer")
        }
        #expect(SheetExport.isGoogleLink("HTTPS://DOCS.GOOGLE.COM/spreadsheets/d/a"))
        #expect(!SheetExport.isGoogleLink("https://docs.google.com./x") && !SheetExport.isGoogleLink("https://[::1]/x"))
    }

    /// GAM's upload lines as 7.52.04 prints them (`SheetExport`'s comment cites each), and what each says of the file.
    @Test func aFailedExportSaysWhetherAFileWasMade() {
        let cases: [(String, SheetExport.Upload?, SheetExport.Made)] = [
            ("User: \(Self.admin), Sheets API Service/App not enabled\n", .sheetsRefused, .yes),
            ("User: \(Self.admin), Sheets API - write todrive data Service/App not enabled\n", .sheetsRefused, .yes),
            ("\nERROR: User: \(Self.admin), Drive File ID: 1abc, Not Created: Requested entity was not found.\n", .finishFailed, .yes),
            ("User: \(Self.admin), Drive API v3 Service/App not enabled\n", .driveRefused, .no),
            // Printed before the create or by the outer handler after it (a Sheets call's domainPolicy): unknown.
            ("User: \(Self.admin), Drive Service/App not enabled\n", .driveOff, .unknown),
            ("\nWARNING: Insufficient permissions to perform this task\n", .notPermitted, .no),
            // files.create refused, or Google's 500 UNKNOWN, which reads the same: unknown.
            ("Drive Folder: root, Create Failed: The user's Drive storage quota has been exceeded.\n", .createFailed, .unknown),
            ("  Drive Folder: root, Create Failed: Unknown Error\n", .createFailed, .unknown),
            // userDriveServiceNotEnabledWarning's other branch, before or after the create.
            ("User: \(Self.admin), Not Created: The service is currently unavailable.\n", .notCreated, .unknown),
            // A read's own line about a folder (printDiskUsage, printEmptyDriveFolders) is no create.
            ("User: bob@example.com, Drive Folder: 1abc, Print Failed: Not Found\n", nil, .unknown),
            ("User: \(Self.admin), Drive Folder: 1abc, Print Failed: Not Found\n", nil, .unknown),
            ("Drive File: \(Self.title), Create Failed: Google reported \"Internal Error\" but the file was probably uploaded, check "
             + "that it has 3 rows\n", .probablyMade, .unknown),
            ("User: bob@example.com, Drive Service/App not enabled\n", nil, .unknown),       // the read's line, another account
            ("ERROR: something else\n", nil, .unknown),
            ("", nil, .unknown),
        ]
        for (stderr, code, made) in cases {
            #expect(SheetExport.uploadState(stderr, owner: Self.admin) == code, "\(stderr)")
            #expect(SheetExport.noted(stdout: "", stderr: stderr, owner: Self.admin) == (code.map { ["upload": $0.rawValue] } ?? [:]))
            let shown = SheetExport.outcome(ok: false, url: "", upload: code?.rawValue ?? "", owner: Self.admin,
                                            error: "GAM failed (unknown, exit=50): whatever")
            #expect(shown.made == made && !shown.said.isEmpty && shown.url.isEmpty, "\(stderr)")
            if made == .unknown { #expect(shown.said.contains("can't be told") || shown.said.contains("probably")) }
        }
        // The account a line names is compared as GAM's re.I compares it; with no admin known, any account's line counts.
        #expect(SheetExport.uploadState("User: ADMIN@Example.com, Sheets API Service/App not enabled", owner: Self.admin) == .sheetsRefused)
        #expect(SheetExport.uploadState("User: bob@example.com, Drive Service/App not enabled", owner: "") == .driveOff)
    }

    /// The upload runs after the read: the last of its lines wins, and a line the read printed about another account never
    /// stands for it.
    @Test func theUploadsOwnLastLineDecides() {
        let stderr = "User: bob@example.com, Drive Service/App not enabled\n"
            + "\nERROR: User: \(Self.admin), Drive File ID: 1abc, Not Created: Requested entity was not found.\n"
        #expect(SheetExport.uploadState(stderr, owner: Self.admin) == .finishFailed)
        let twice = "Drive Folder: root, Create Failed: quota\nUser: \(Self.admin), Sheets API Service/App not enabled\n"
        #expect(SheetExport.uploadState(twice, owner: Self.admin) == .sheetsRefused)
        // The last line naming another account can't place the file: unknown, never an earlier line of the admin's instead.
        let after = "User: \(Self.admin), Drive API v3 Service/App not enabled\nUser: bob@example.com, Drive Service/App not enabled\n"
        #expect(SheetExport.uploadState(after, owner: Self.admin) == nil)
    }

    /// The review of F4: a read's own `Drive Folder: <id>, Print Failed` line, followed by an upload that made the file and then
    /// stopped with a line nothing matches, once decided "Nothing was made" over a file that exists.
    @Test func aReadsFolderLineNeverDecidesTheUpload() {
        let stderr = "User: bob@example.com, Drive Folder: 1abc, Print Failed: Not Found\n"
            + "User: \(Self.admin), Not Created: The service is currently unavailable.\n"
        #expect(SheetExport.uploadState(stderr, owner: Self.admin) == .notCreated)
        let silent = "User: bob@example.com, Drive Folder: 1abc, Print Failed: Not Found\n"
        #expect(SheetExport.uploadState(silent, owner: Self.admin) == nil)
        #expect(SheetExport.outcome(ok: false, url: "", upload: "", owner: Self.admin).made == .unknown)
    }

    /// GAM names the admin by the Directory's primary address (GetTodriveParameters, checkUserExists): its lines match that,
    /// compared as GAM's re.I compares it, and a line naming the token's alias instead is another name, so unknown.
    @Test func theAdminIsNamedByItsPrimaryAddress() {
        let line = "User: alice@example.com, Sheets API Service/App not enabled\n"
        #expect(SheetExport.uploadState(line, owner: "alice@example.com") == .sheetsRefused)
        #expect(SheetExport.uploadState(line, owner: "a.anders@example.com") == nil)
    }

    /// `entityActionFailedWarning` after `Act.Set(Act.CREATE)`: "<entity>: <name>, Create Failed: <why>". Never ", Failed".
    @Test func theFailedLineIsTheOneGamPrints() {
        #expect(SheetExport.uploadState("Drive Folder: root, Failed: quota\n", owner: Self.admin) == nil)
        #expect(SheetExport.uploadState("Drive Folder: root, Create Failed: quota\n", owner: Self.admin) == .createFailed)
        // GAM's own line only: at a line's start, its parent `root` (no tdparent is sent), never inside another line.
        #expect(SheetExport.uploadState("Drive Folder: 1abc, Create Failed: quota\n", owner: Self.admin) == nil)
        #expect(SheetExport.uploadState("x Drive Folder: root, Create Failed: quota\n", owner: Self.admin) == nil)
    }

    @Test func aPlainCSVFileAndAnOldRecordAreSaidAsTheyAre() {
        let big = SheetExport.outcome(ok: true, url: "https://drive.google.com/file/d/abc/view?usp=drivesdk", upload: "", owner: Self.admin)
        #expect(big.said.contains("plain CSV file") && !big.said.contains("Google Sheet in"))
        let old = SheetExport.outcome(ok: true, url: "", upload: "", owner: "boss@example.com")    // a record without its link
        #expect(old.said.contains("No link was kept") && !old.said.contains("shared with nobody"))
        let made = SheetExport.outcome(ok: true, url: "https://docs.google.com/spreadsheets/d/a", upload: "", owner: "")
        #expect(made.said == "Exported to a new Google Sheet in the admin's Drive, shared with nobody." && made.made == .yes)
    }

    @Test func aLinkPrintedBeforeAFailedExitIsAMadeFile() {
        let shown = SheetExport.outcome(ok: false, url: "https://docs.google.com/spreadsheets/d/a", upload: "", owner: Self.admin,
                                        error: "GAM failed (not_found, exit=56)")
        #expect(shown.made == .yes && !shown.url.isEmpty && shown.said.contains("only its headers") && shown.said.contains("exit=56"))
    }

    @Test func theScopeCheckInWords() {
        let drive = SheetExport.driveScope, sheets = SheetExport.sheetsScope
        #expect(SheetExport.scopeState([drive: true, sheets: true]).isEmpty)
        #expect(SheetExport.scopeState(nil).contains("couldn't be checked"))           // unknown, never "allowed"
        #expect(SheetExport.scopeState([drive: true, sheets: false]).contains(sheets))
        #expect(SheetExport.scopeState([drive: false, sheets: true]).contains("can't make the file"))
        #expect(SheetExport.title(domain: "example.com", read: "List users") == "example.com - List users")
        #expect(SheetExport.title(domain: "", read: "List users") == "List users")
    }

    /// The check's answer as GamGUI reads it: a clean exit or a failed scope's 10 is an answer, its rows lowercased; any other
    /// exit, or a scope missing from the rows, is unknown.
    @Test func theScopeChecksAnswerIsReadOrUnknown() {
        func result(_ code: Int32, _ rows: [(String, String)]) -> GamResult {
            let table = rows.map { "  \($0.0)   \($0.1) (1/2)" }.joined(separator: "\n")
            return GamResult(exitCode: code, stdout: "System time status   PASS\n" + table + "\n", stderr: "",
                             stdoutTruncated: false, stderrTruncated: false)
        }
        let drive = SheetExport.driveScope, sheets = SheetExport.sheetsScope
        #expect(SheetExport.checked(result(0, [(drive, "PASS"), (sheets, "PASS")])) == [drive: true, sheets: true])
        #expect(SheetExport.checked(result(10, [(drive, "PASS"), (sheets.uppercased(), "FAIL")])) == [drive: true, sheets: false])
        #expect(SheetExport.checked(result(16, [(drive, "PASS"), (sheets, "PASS")])) == nil)
        #expect(SheetExport.checked(result(0, [(drive, "PASS")])) == nil)
    }

    @Test func theActionIsNamedAsGamGUIRecordsIt() {
        #expect(WriteAction.exportToSheet.rawValue == "export_to_sheet")
        let write = try! GamCommands.exportToSheet(Self.read, title: "T")
        #expect(write.cutsOff == nil)
        #expect(write.noted(stdout: "", stderr: "User: \(Self.admin), Drive API v3 Service/App not enabled", owner: Self.admin)
                == ["upload": "drive_refused"])
        #expect(GamCommands.addGroupMember(group: "g@example.com", member: "a@example.com").noted(stdout: "x", stderr: "", owner: "").isEmpty)
    }
}
