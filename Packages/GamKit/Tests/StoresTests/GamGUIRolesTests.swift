@testable import Stores
import Darwin
import Foundation
import GamEngine
import TestSupport
import Testing

/// GamGUI's onboarding roles, read and never written (design doc D5): its own file, by descriptor as
/// invariant 5 reads credentials (no link, no FIFO, a regular file under the cap), migrated as GamGUI's
/// load migrates it (the migration itself is held to the fixture by `OnboardingTests`), and a file GamGUI
/// couldn't read is reported, never replaced by its seed.
@Suite("GamGUI roles")
struct GamGUIRolesTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-roles-\(UUID().uuidString)/GamGUI")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(_ text: String, named name: String = "onboarding.json") throws -> URL {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func listing() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() ?? [] }

    /// GamGUI's test_role_config_persists_and_migrates, test_role_groups_calendars_persist_and_migrate and
    /// test_an_older_store_s_single_welcome_becomes_default_unchanged, over files GamGUI wrote.
    @Test func readsAndMigratesGamGUIsFile() throws {
        let saved = try file(#"""
            {"roles": {"Sales": {"steps": ["Do a thing"], "signature": "Classic", "org_unit": "/Sales",
              "groups": ["sales@example.com"], "calendars": ["cal@x"], "welcome": ""},
             "Legacy": ["Step A", "Step B"],
             "Old": {"steps": ["s"], "signature": "", "org_unit": "/O"}},
             "welcome": {"subject": "Hi {name}", "body": "Old body"}}
            """#)
        let roles = try GamGUIRoles.read(saved)
        #expect(roles.roles.map(\.name) == ["Legacy", "Old", "Sales"])
        #expect(roles.roles[2] == RoleTemplate(name: "Sales", steps: ["Do a thing"], signature: "Classic", orgUnit: "/Sales",
                                               groups: ["sales@example.com"], calendars: ["cal@x"]))
        #expect(roles.roles[0] == RoleTemplate(name: "Legacy", steps: ["Step A", "Step B"]))
        #expect(roles.roles[1].groups == [] && roles.roles[1].calendars == [] && roles.roles[1].orgUnit == "/O")
        #expect(roles.welcomes.map(\.name) == ["Default"])
        #expect(roles.welcomes.first?.email == WelcomeEmail(subject: "Hi {name}", body: "Old body"))
        #expect(roles.roles[2].welcomeName == "Default")
    }

    @Test func refusesALinkFIFOOrOversizeFile() throws {
        let real = try file(#"{"roles": {"Sales": ["x"]}}"#, named: "real.json")
        let link = folder.appending(path: "onboarding.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: GamGUIRoles.Problem.refused(.link)) { try GamGUIRoles.read(link) }

        let fifo = folder.appending(path: "fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: GamGUIRoles.Problem.refused(.notAFile)) { try GamGUIRoles.read(fifo) }
        #expect(throws: GamGUIRoles.Problem.refused(.notAFile)) { try GamGUIRoles.read(folder) }

        let large = try file(#"{"roles": {"A": [""# + String(repeating: "x", count: SignatureStore.sizeCap) + #""]}}"#, named: "large.json")
        #expect(throws: GamGUIRoles.Problem.refused(.tooLarge)) { try GamGUIRoles.read(large) }
        #expect(throws: GamGUIRoles.Problem.noFile) { try GamGUIRoles.read(folder.appending(path: "missing.json")) }
        #expect(throws: GamGUIRoles.Problem.noFile) {
            try GamGUIRoles.read(folder.appending(path: "no-such-folder/onboarding.json"))
        }
    }

    /// GamGUI shows its starter role over a file it can't read; here that's said, and the file is left as
    /// it was, with nothing written beside it.
    @Test func anUnreadableFileIsReportedNotSeeded() throws {
        for text in ["{not json", "[]", #"{"roles": []}"#, #"{"roles": {"A": {"steps": null}}}"#, ""] {
            let url = try file(text)
            #expect(throws: GamGUIRoles.Problem.unreadable) { try GamGUIRoles.read(url) }
            #expect(try Data(contentsOf: url) == Data(text.utf8))
        }
        #expect(listing() == ["onboarding.json"])
        #expect(GamGUIRoles.Problem.unreadable.message.contains("GamGUI"))
        #expect(GamGUIRoles.Problem.noFile.message.contains("Role templates"))
    }

    /// Reading is all it does: no default location (the app builds GamGUI's path at run time), and no write.
    @Test func neverTouchesRealAppData() throws {
        let source = try String(contentsOf: Self.source, encoding: .utf8)
        #expect(!source.contains("applicationSupportDirectory"), "no default path to the operator's data")
        for write in ["O_WRONLY", "O_RDWR", "O_CREAT", "write(", "rename", "unlink", "FileManager"] {
            #expect(!source.contains(write), "\(write): the reader never writes")
        }
        let url = try file(#"{"roles": {"Sales": ["x"]}}"#)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = try GamGUIRoles.read(url)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == before)
        #expect(listing() == ["onboarding.json"])
    }

    /// The demo's roles (GamGUI's format, in `Tests/Fixtures/demo`, copied to a temporary folder at a demo launch) read.
    @Test func theDemoRolesRead() throws {
        let roles = try GamGUIRoles.read(Fixtures.directory.appending(path: "demo/onboarding.json"))
        #expect(roles.roles.map(\.name) == ["Salesperson", "Warehouse"])
        #expect(roles.roles[0].signature == "Classic" && roles.roles[1].steps.count == 3)
    }

    static var source: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Stores/GamGUIRoles.swift")
    }
}
