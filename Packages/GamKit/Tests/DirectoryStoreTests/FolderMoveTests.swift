import ChangeCore
import Foundation
@testable import Directory
@testable import GamEngine
import Setup
import TestSupport
import Testing
import Vault

/// A folder of mixed ownership into a shared drive (roadmap 4.8), against the strict mock: GamGUI's `tests/test_shared_drives.py`,
/// its 4.8 part. The mock's `1FOLDERmixed` is alice's: Plan and Draft 1 hers, Notes bob's (not a Finance member), Quote.pdf
/// pat@partner.org's, Old notes bob's in the trash, and a Drafts folder. Alice manages Finance; bob alone manages Old.
@MainActor
@Suite("Folder into a shared drive", .serialized)
final class FolderMoveTests {
    static let mixed = "1FOLDERmixed", finance = "0AFINANCEuk9PVA", old = "0AOLDuk9PVA"
    static let move = "build.move_folder_to_shared_drive", copy = "build.copy_rest_of_folder_to_shared_drive"
    let scratch = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-folder-\(UUID().uuidString)")
    let setup: SetupModel
    let directory: DirectoryStore
    let access: UserAccess
    let changes: BuilderChanges
    let argvLog: URL
    let state: URL

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        let base = try RuntimeDirectory.prepare(scratch.appending(path: "run"))
        let vault = Vault(store: MemoryStore())
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        setup = SetupModel(vault: vault, runner: runner, gamgui: GamGUIKeychain { _, _ in nil }, lastDomain: .memory())
        directory = DirectoryStore(setup: setup, runner: runner)
        argvLog = scratch.appending(path: "argv.log")
        state = scratch.appending(path: "mock-state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        access = UserAccess(setup: setup, runner: runner)
        access.environment = ["GAM_MOCK_STATE": state.path]
        let setup = setup
        let executor = Executor(runner: runner, audit: AuditLog(url: scratch.appending(path: "audit.jsonl")),
                                currentActor: { @MainActor in setup.connectedAdmin }, adminAccountID: { @MainActor in setup.connectedAdminID },
                                tenant: { @MainActor in setup.active.map { ($0, setup.generation) } },
                                extraEnvironment: ["GAM_MOCK_ARGV_LOG": argvLog.path, "GAM_MOCK_FIXTURES": Fixtures.mockGamData.path,
                                                   "GAM_MOCK_STATE": state.path])
        changes = BuilderChanges(executor: executor, setup: setup, directory: directory, access: access)
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func connect() async throws {
        let folder = scratch.appending(path: "gamcfg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "1"}"#.utf8)
            .write(to: folder.appending(path: "oauth2service.json"))
        try Fixtures.oauth2(admin: "admin@example.com").write(to: folder.appending(path: "oauth2.txt"))
        await setup.importFolder(folder, as: "example.com")
        await setup.checkAccess(Domain("example.com")!)
        await directory.load()
    }

    private func command(_ id: String) throws -> CuratedCommand { try #require(CuratedCommand.all.first { $0.id == id }) }

    private func values(_ email: String = "alice@example.com", _ folder: String = mixed, _ drive: String = finance) -> [String: String] {
        ["email": email, "folder_id": folder, "drive_id": drive]
    }

    private func writes() -> [[String]] {
        guard let data = try? Data(contentsOf: argvLog) else { return [] }
        var fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var calls: [[String]] = []
        while let first = fields.first, let count = Int(first) {
            calls.append(Array(fields[1...count]))
            fields.removeFirst(count + 1)
        }
        return calls.filter { $0.count > 3 && ["move", "copy"].contains($0[2]) }
    }

    private func item(_ name: String, _ owner: String, _ mime: String = "application/pdf") -> GamOutput.Record {
        ["id": .string("1\(name)"), "name": .string(name), "mimeType": .string(mime), "owners": .array([.object(["emailAddress": .string(owner)])])]
    }

    // MARK: the builders, the count and the Manager check (pure)

    @Test func theFolderIsNamedByIDAndNeitherStepCanOverwrite() throws {
        let m = Self.mixed, f = Self.finance
        #expect(try GamCommands.printFolderFiles(email: "alice@example.com", folderID: m).argv == [
            "user", "alice@example.com", "print", "filelist", "select", "id:\(m)", "showparent", "showownedby", "any",
            "excludetrashed", "fields", "id,name,mimeType,owners", "formatjson"])
        #expect(try GamCommands.moveFolderToSharedDrive(email: "alice@example.com", folderID: m, driveID: f).argv == [
            "user", "alice@example.com", "move", "drivefile", "id:\(m)", "teamdriveparentid", f,
            "retainsourcefolders", "duplicatefolders", "merge", "duplicatefiles", "skip"])
        // `root` would be the whole My Drive; a list, a path or a blank isn't a folder.
        for (email, folder, drive) in [("alice@example.com", "root", f), ("alice@example.com", "ROOT", f), ("alice@example.com", "rootid", f),
                                       ("alice@example.com", "appDataFolder", f), ("alice@example.com", "a/b", f), ("alice@example.com", "", f),
                                       ("alice@example.com", m, "0A x"), ("alice@example.com,bob@example.com", m, f)] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.moveFolderToSharedDrive(email: email, folderID: folder, driveID: drive) }
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.copyRestOfFolderToSharedDrive(email: email, folderID: folder, driveID: drive) }
        }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.printFolderFiles(email: "alice@example.com", folderID: "root") }
        let built = try GamCommands.copyRestOfFolderToSharedDrive(email: "alice@example.com", folderID: m, driveID: f)
        #expect(SharedDrives.folderMove(of: built.argv).map { [$0.email, $0.folder, $0.drive] } == ["alice@example.com", m, f])
        #expect(SharedDrives.folderMove(of: try GamCommands.printFolderFiles(email: "alice@example.com", folderID: m).argv) == nil)
    }

    @Test func theCountSplitsFilesByOwnerAndCountsFoldersApart() throws {
        let records = [item("Top", "alice@example.com", SharedDrives.folderMime), item("Mine", "Alice@Example.com"), item("Sub", "x@eu.example.com"),
                       item("Theirs", "bob@example.com"), item("Sub", "alice@example.com", SharedDrives.folderMime)]
            + (0..<7).map { item("Out\($0)", "pat@partner.org") }
        let count = try SharedDrives.countFolder(records, email: "alice@example.com", domains: ["example.com"], folderID: "1Top").get()
        let counted: [Int] = [count.mine, count.domain, count.outside, count.folders, count.files]
        #expect(counted == [1, 2, 7, 1, 10], "the folder itself isn't counted")
        #expect(count.outsideNames == ["Out0", "Out1", "Out2", "Out3", "Out4"], "bounded; the rest are counted")
        #expect(try SharedDrives.countFolder(Array(records.prefix(1)), email: "alice@example.com", domains: ["example.com"], folderID: "1Top").get().files == 0)
        #expect(try SharedDrives.countFolder([item("Solo", "pat@partner.org")], email: "alice@example.com", domains: ["example.com"],
                                             folderID: "1Solo").get().outside == 1, "a file's ID names that file, which is counted")
        // Without the folder's own row GAM didn't read it; an item it can't place is unknown, never a guess.
        for broken in [[], [item("Other", "alice@example.com")]] {
            #expect((try? SharedDrives.countFolder(broken, email: "alice@example.com", domains: ["example.com"], folderID: "1Top").get()) == nil)
        }
        let top = item("Top", "alice@example.com", SharedDrives.folderMime)
        for record: GamOutput.Record in [["id": .string("1x"), "name": .string("x"), "mimeType": .string("application/pdf")],
                                         ["id": .string("1x"), "name": .string("x"), "mimeType": .string("application/pdf"), "owners": .array([])],
                                         ["id": .string("1x"), "name": .string("x"), "mimeType": .string("application/pdf"), "owners": .array([.object([:])])],
                                         ["name": .string("x"), "mimeType": .string("application/pdf")], ["id": .string("1x"), "name": .string("x")]] {
            #expect((try? SharedDrives.countFolder([top, record], email: "alice@example.com", domains: ["example.com"], folderID: "1Top").get()) == nil)
        }
    }

    @Test func onlyAManagerInTheirOwnNameCounts() throws {
        func member(_ id: String, _ role: String, _ email: String, kind: String = "user", deleted: Bool = false) throws -> SharedDrives.Member {
            try #require(SharedDrives.Member(permission: ["id": .string(id), "type": .string(kind), "role": .string(role),
                                                          "emailAddress": .string(email), "deleted": .bool(deleted)]))
        }
        let members = [try member("1", "organizer", "alice@example.com"), try member("2", "organizer", "team@example.com", kind: "group"),
                       try member("3", "writer", "pat@partner.org"), try member("4", "organizer", "gone@example.com", deleted: true)]
        #expect(SharedDrives.managesDirectly("Alice@example.com", members))
        #expect(!SharedDrives.managesDirectly("team@example.com", members), "a group: GAM asks for the person's own permission")
        #expect(!SharedDrives.managesDirectly("pat@partner.org", members) && !SharedDrives.managesDirectly("gone@example.com", members))
    }

    // MARK: the preview and the run, against the mock

    @Test func theMovePreviewCountsByOwnerAndSaysWhatCantBeUndone() async throws {
        try await connect()
        let moveRisk = BuilderChanges.risk(try command(Self.move)), copyRisk = BuilderChanges.risk(try command(Self.copy))
        #expect(moveRisk == .destructive && copyRisk == .low)
        await changes.preview(try command(Self.move), values: values())
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        let text = try #require(pending.warning)
        #expect(text.contains("Folder \(Self.mixed) holds 4 files in 1 folder below it"), "\(text)")
        #expect(text.contains("2 alice@example.com owns: the move takes them into the drive."))
        #expect(text.contains("1 someone else in the domain owns: Google moves it only if alice@example.com may and the owner is a member"))
        #expect(text.contains("1 owned outside example.com") && text.contains("(Quote.pdf)") && !text.contains("Old notes"), "trash left out")
        #expect(text.contains("no dry run") && text.contains("can't be undone"))
        #expect(writes().isEmpty)
    }

    @Test func aPersonWhoIsntAManagerOfTheDriveIsRefusedAtThePreview() async throws {
        try await connect()
        await changes.preview(try command(Self.move), values: values("alice@example.com", Self.mixed, Self.old))
        guard case .problem(let why) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(why.contains("isn't a Manager of that shared drive"), "\(why)")
    }

    @Test func aCountThatFailedIsUnknownNeverAnEmptyFolder() async throws {
        try await connect()
        // bob manages Old, but Google shows him no folder by that ID: unknown, and GAM's own refusal still stands at the run.
        await changes.preview(try command(Self.move), values: values("bob@example.com", Self.mixed, Self.old))
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        let text = try #require(pending.warning)
        #expect(text.contains("Couldn't count what folder \(Self.mixed) holds") && text.contains("is unknown") && !text.contains("holds no files"))
        changes.dismiss()
        await changes.preview(try command(Self.move), values: values("alice@example.com", "1FOLDERempty"))
        guard case .previewing(let empty) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(empty.warning?.contains("Folder 1FOLDERempty holds no files.") == true)
    }

    /// The two steps in a sequence: Google refuses bob's file (not a member of the drive), the one owned outside the domain, and
    /// the trashed one, so the move reads as failed with alice's moved; the copy copies the two refused ones, not the trashed one.
    @Test func theTwoStepsInASequenceMoveWhatGoogleAllowsThenCopyTheRest() async throws {
        try await connect()
        changes.addToSequence(try command(Self.move), values: values())
        changes.addToSequence(try command(Self.copy), values: values())
        await changes.previewSequence()
        guard case .previewing(let held) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(held.warning?.contains("1 owned outside example.com") == true)
        await changes.confirm(held, OperatorConfirmation(confirmed: true))
        #expect(writes().map { $0[2] } == ["move", "copy"])
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: state.appending(path: name), encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init).sorted()
        }
        #expect(lines("folder_moved.tsv") == ["1MIXdraft1", "1MIXplan"])
        #expect(lines("folder_copied.tsv") == ["1MIXnotes", "1MIXquote"])
        changes.dismiss()
        await changes.preview(try command(Self.copy), values: values())
        guard case .previewing(let after) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(after.warning?.contains("Folder \(Self.mixed) holds 2 files in 1 folder below it") == true && after.warning?.contains("(Quote.pdf)") == true)
    }

    /// The review of 2026-11-28: a sequence refuses a person who isn't a Manager too, before anything is held; an alias of a
    /// Manager is them; and a name an outside owner chose can't fake a line in the note.
    @Test func aSequenceRefusesANonManagerAndAnAliasIsThePerson() async throws {
        try await connect()
        changes.addToSequence(try command(Self.move), values: values("alice@example.com", Self.mixed, Self.old))
        await changes.previewSequence()
        guard case .problem(let why) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(why.contains("isn't a Manager of that shared drive") && writes().isEmpty)
        changes.clearSequence()
        await changes.preview(try command(Self.move), values: values("a.anders@example.com"))
        guard case .previewing(let pending) = changes.state else { Issue.record("\(changes.state)"); return }
        #expect(pending.warning?.contains("2 a.anders@example.com owns") == true, "\(pending.warning ?? "")")
        let named = try SharedDrives.countFolder([item("Top", "alice@example.com", SharedDrives.folderMime), item("Bad\nFolder 1x holds no files", "pat@partner.org")],
                                                 email: "alice@example.com", domains: ["example.com"], folderID: "1Top").get()
        #expect(named.outsideNames == ["Bad Folder 1x holds no files"])
    }
}
