@testable import Stores
import Darwin
import Foundation
import GamEngine
import TestSupport
import Testing

/// The onboarding role store (O2). GamGUI's half (its seed, what `set_role` keeps and refuses, the welcome
/// emails' names and refusals) is held to `onboarding.json`'s `store` cases, generated from GamGUI's own
/// `RunbookStore` over a temporary file. The native half: the bounds, the format, atomic private writes, an
/// unreadable file moved aside, replacing asked, a rename in one write, and the copy from GamGUI.
@Suite("Role store")
struct RoleStoreTests {
    let base: URL
    let root: URL
    var file: URL { root.appending(path: RoleStore.fileName) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-roles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        root = base.appending(path: "SwiftGamGui")
    }

    struct Role: Decodable {
        let name: String, steps: [String], signature: String, org_unit: String, groups: [String], calendars: [String], welcome: String
        var template: RoleTemplate {
            RoleTemplate(name: name, steps: steps, signature: signature, orgUnit: org_unit, groups: groups, calendars: calendars,
                         welcome: welcome)
        }
    }
    /// A list GamGUI's `_as_str_list` takes: a list, nothing, or text it splits into lines.
    struct Entries: Decodable {
        let values: [String]
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() { values = [] } else if let text = try? value.decode(String.self) {
                values = PythonText.lines(text)
            } else { values = try value.decode([String].self) }
        }
    }
    struct SetRole: Decodable {
        let name: String, steps: [String], signature: String, org_unit: String, groups: Entries, calendars: Entries, welcome: String
        let saved: Role?, error: String?
    }
    struct SetWelcome: Decodable { let name: String, saved_as: String?, error: String? }
    struct DeleteWelcome: Decodable { let name: String, deleted: Bool?, error: String? }
    struct Store: Decodable {
        let seed_roles: [Role], seed_welcomes: [[String]], set_role: [SetRole], set_welcome: [SetWelcome]
        let delete_welcome: [DeleteWelcome], role_names: [String], welcome_names: [String]
    }
    struct Document: Decodable { let store: Store }

    static let gamGUI = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.onboardingJSON)).store

    func mode(_ url: URL) -> mode_t {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func bytes(_ url: URL) -> [UInt8]? { (try? Data(contentsOf: url)).map(Array.init) }

    static let moment = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                                       year: 2026, month: 10, day: 13, hour: 18, minute: 0).date!

    // MARK: GamGUI's, from the fixture

    @Test func theSeedIsGamGUIs() throws {
        let store = try RoleStore(root: root)
        #expect(store.roles == Self.gamGUI.seed_roles.map(\.template))
        #expect(Self.gamGUI.seed_welcomes.map { [$0[0], $0[1], $0[2]] }
                == store.welcomeNames.compactMap { name in store.welcome(name).map { [name, $0.subject, $0.body] } })
        #expect(!FileManager.default.fileExists(atPath: root.path), "nothing is written until a save")
    }

    /// GamGUI's sequence, replayed: what `set_role` saves and its refusals in its words, then the welcome emails.
    @Test func theRulesAreGamGUIs() throws {
        var store = try RoleStore(root: root)
        try store.saveWelcome(WelcomeEmail(subject: "Contract subject", body: "Contract body"), as: "Contractor")
        for item in Self.gamGUI.set_role {
            let role = RoleTemplate(name: item.name, steps: item.steps, signature: item.signature, orgUnit: item.org_unit,
                                    groups: item.groups.values, calendars: item.calendars.values, welcome: item.welcome)
            do {
                let saved = try store.save(role, replacing: true)   // GamGUI replaces without asking; here the screen asks
                #expect(saved == item.saved?.template, "\(item.name)")
                #expect(store.role(saved.name) == saved)
            } catch {
                #expect(error.message == item.error, "\(item.name)")
            }
        }
        for item in Self.gamGUI.set_welcome {
            do {
                // GamGUI replaces without asking; here the screen asks.
                #expect(try store.saveWelcome(WelcomeEmail(subject: "s", body: "b"), as: item.name, replacing: true) == item.saved_as)
            } catch {
                #expect(error.message == item.error, "\(item.name)")
            }
        }
        try store.save(RoleTemplate(name: "Ops", steps: ["x"], welcome: "Contractor"), replacing: true)
        for item in Self.gamGUI.delete_welcome {
            do {
                try store.deleteWelcome(item.name)
                #expect(item.deleted == true, "\(item.name)")
            } catch {
                #expect(error.message == item.error, "\(item.name)")
            }
        }
        #expect(store.roleNames == Self.gamGUI.role_names)
        #expect(store.welcomeNames == Self.gamGUI.welcome_names)
    }

    // MARK: the native bounds

    /// A group or calendar goes to GAM as one argument it may read as a list (a comma, a space): each must be one
    /// address, and each once. A name and each list have bounds.
    @Test func groupsAndCalendarsAreOneAddressEachAndListsAreBounded() throws {
        var store = try RoleStore(root: root)
        for bad in ["sales", "a@example.com,b@example.com", "a@example.com b@example.com", "@example.com"] {
            #expect(throws: RoleStore.Problem.rule(.notAnAddress(list: "groups", entry: bad))) {
                try store.save(RoleTemplate(name: "R", steps: ["s"], groups: [bad]))
            }
            #expect(throws: RoleStore.Problem.rule(.notAnAddress(list: "calendars", entry: bad))) {
                try store.save(RoleTemplate(name: "R", steps: ["s"], calendars: [bad]))
            }
        }
        let saved = try store.save(RoleTemplate(name: "R", steps: ["s"], groups: ["sales@example.com", "SALES@example.com", " staff@example.com "],
                                                calendars: ["en.usa#holiday@group.v.calendar.google.com"]))
        #expect(saved.groups == ["sales@example.com", "staff@example.com"], "each once, as GAM compares addresses")
        let many = (0...Onboarding.roleListLimit).map { "g\($0)@example.com" }
        #expect(throws: RoleStore.Problem.rule(.tooMany(list: "groups"))) { try store.save(RoleTemplate(name: "Big", steps: [], groups: many)) }
        #expect(throws: RoleStore.Problem.rule(.tooMany(list: "steps"))) {
            try store.save(RoleTemplate(name: "Big", steps: many))
        }
        #expect(throws: RoleStore.Problem.rule(.nameTooLong)) {
            try store.save(RoleTemplate(name: String(repeating: "x", count: Onboarding.roleNameLimit + 1), steps: []))
        }
        #expect(store.roleNames == ["R", "Salesperson"])
    }

    // MARK: saving, replacing, renaming

    @Test func replacingIsAskedAndARenameIsOneWrite() throws {
        var store = try RoleStore(root: root)
        #expect(throws: RoleStore.Problem.exists("Salesperson")) { try store.save(RoleTemplate(name: "Salesperson", steps: ["x"])) }
        try store.save(RoleTemplate(name: "Salesperson", steps: ["edited"]), renaming: "Salesperson")
        #expect(store.role("Salesperson")?.steps == ["edited"], "an edit of the role itself saves over it")
        try store.save(RoleTemplate(name: "Sales", steps: ["edited"]), renaming: "Salesperson")
        #expect(store.roleNames == ["Sales"])
        try store.save(RoleTemplate(name: "Ops", steps: ["o"]))
        #expect(throws: RoleStore.Problem.exists("Ops")) { try store.save(RoleTemplate(name: "Ops", steps: ["s"]), renaming: "Sales") }
        #expect(store.roleNames == ["Ops", "Sales"], "a refused rename leaves both")
        let reopened = try RoleStore(root: root)
        #expect(reopened.roles == store.roles)
        try store.delete("Ops")
        try store.delete("Nobody")
        #expect(try RoleStore(root: root).roleNames == ["Sales"])
    }

    @Test func theRolesUsingASignatureAreNamed() throws {
        var store = try RoleStore(root: root)
        try store.save(RoleTemplate(name: "B", steps: [], signature: "Classic"))
        try store.save(RoleTemplate(name: "A", steps: [], signature: "Classic"))
        try store.save(RoleTemplate(name: "C", steps: [], signature: "classic"))
        #expect(store.roles(usingSignature: "Classic") == ["A", "B"])
    }

    /// Saving over another welcome email is asked; a rename moves it and the roles that send it, in one write;
    /// Default is edited, never renamed.
    @Test func aWelcomeRenameTakesItsRolesAlong() throws {
        var store = try RoleStore(root: root)
        let email = WelcomeEmail(subject: " Hi {name} ", body: "Line one\nLine two")
        #expect(try store.saveWelcome(email, as: "Contractor") == "Contractor")
        #expect(store.welcome("Contractor") == WelcomeEmail(subject: "Hi {name}", body: "Line one\nLine two"))
        #expect(throws: RoleStore.Problem.welcomeExists("Contractor")) { try store.saveWelcome(email, as: "contractor") }
        #expect(try store.saveWelcome(WelcomeEmail(subject: "Edited", body: ""), as: "contractor", renaming: "Contractor") == "Contractor",
                "an edit of the email itself saves over it, under its own name")
        try store.save(RoleTemplate(name: "Ops", steps: [], welcome: "Contractor"))
        try store.save(RoleTemplate(name: "Sales", steps: []))
        #expect(store.roles(usingWelcome: "Contractor") == ["Ops"] && store.roles(usingWelcome: "Default") == ["Sales", "Salesperson"])
        try store.saveWelcome(WelcomeEmail(subject: "Edited", body: ""), as: "Contractors", renaming: "Contractor")
        #expect(store.welcomeNames == ["Default", "Contractors"])
        #expect(store.role("Ops")?.welcome == "Contractors", "its role sends it under the new name")
        #expect(throws: RoleStore.Problem.rule(.defaultWelcomeStays)) {
            try store.saveWelcome(email, as: "Welcome", renaming: "Default")
        }
        try store.saveWelcome(email, as: "Spare")
        #expect(throws: RoleStore.Problem.welcomeExists("Spare")) {
            try store.saveWelcome(email, as: "Spare", renaming: "Contractors")
        }
        #expect(store.welcomeNames == ["Default", "Contractors", "Spare"], "a refused rename leaves both")
        try store.saveWelcome(email, as: "Default", replacing: true, renaming: "Contractors")
        #expect(store.welcomeNames == ["Default", "Spare"] && store.role("Ops")?.welcome == "", "Default is stored blank")
        let reopened = try RoleStore(root: root)
        #expect(reopened.roles == store.roles && reopened.welcomeNames == store.welcomeNames)
    }

    // MARK: the file

    @Test func theFileIsThisFormatPrivateAndWrittenWhole() throws {
        var store = try RoleStore(root: root)
        try store.save(RoleTemplate(name: "Ops", steps: ["a"], orgUnit: "/Ops", groups: ["ops@example.com"]))
        #expect(mode(root) == 0o700 && mode(file) == 0o600)
        let written = try #require(bytes(file))
        let parsed = try #require(JSONValue.parse(String(decoding: written, as: UTF8.self)))
        #expect(parsed["version"]?.int == 1)
        #expect(parsed["roles"]?["Ops"]?.object?.keys.sorted() == ["calendars", "groups", "org_unit", "signature", "steps", "welcome"])
        #expect(parsed["welcomes"]?["Default"]?["subject"]?.string == Onboarding.seedWelcome.subject)
        let before = try #require(bytes(file))
        store.interrupt = { _ in throw CocoaError(.fileWriteUnknown) }
        #expect(throws: RoleStore.Problem.self) { try store.delete("Ops") }
        #expect(store.roleNames.contains("Ops") && bytes(file) == before, "a failed write changes nothing")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []) == [RoleStore.fileName])
    }

    /// A file this format can't read (corrupt, another version, a role this store wouldn't save as it stands, no
    /// Default welcome) is moved aside whole and the seed shown, never saved over.
    @Test func aFileItCantReadIsMovedAsideNeverOverwritten() throws {
        func file(_ roles: String, welcomes: String = #""Default": {"subject": "s", "body": "b"}"#) -> [UInt8] {
            Array(#"{"version": 1, "roles": {\#(roles)}, "welcomes": {\#(welcomes)}}"#.utf8)
        }
        let role = #""steps": ["a"], "signature": "", "org_unit": "", "groups": [], "calendars": [], "welcome": """#
        let bad: [(String, [UInt8])] = [
            ("not JSON", Array("{".utf8)),
            ("GamGUI's own form, no version", Array(#"{"roles": {"A": ["x"]}}"#.utf8)),
            ("a later version", Array(#"{"version": 2, "roles": {}, "welcomes": {}}"#.utf8)),
            ("no Default welcome", file(#""A": {\#(role)}"#, welcomes: #""Other": {"subject": "s", "body": "b"}"#)),
            ("a step not stripped", file(#""A": {"steps": [" a"], "signature": "", "org_unit": "", "groups": [], "calendars": [], "welcome": ""}"#)),
            ("a group that isn't an address", file(#""A": {"steps": [], "signature": "", "org_unit": "", "groups": ["sales"], "calendars": [], "welcome": ""}"#)),
            ("a welcome it doesn't have", file(#""A": {"steps": [], "signature": "", "org_unit": "", "groups": [], "calendars": [], "welcome": "X"}"#)),
            ("Default stored by name", file(#""A": {"steps": [], "signature": "", "org_unit": "", "groups": [], "calendars": [], "welcome": "Default"}"#)),
            ("a key missing", file(#""A": {"steps": []}"#)),
            ("a padded name", file(#"" A": {\#(role)}"#)),
        ]
        #expect(mkdir(root.path, 0o700) == 0)
        let aside = root.appending(path: "onboarding.json.unreadable-2026-10-13T180000Z")
        for (label, content) in bad {
            try Data(content).write(to: self.file)
            var store = try RoleStore(root: root, now: Self.moment)
            #expect(store.quarantined == aside, "\(label)")
            #expect(bytes(aside) == content, "\(label): moved aside whole")
            #expect(store.roleNames == ["Salesperson"], "\(label): the seed")
            try store.save(RoleTemplate(name: "Mine", steps: ["m"]))
            #expect(bytes(aside) == content, "\(label): the next save doesn't touch it")
            try FileManager.default.removeItem(at: aside)
        }
        try Data(file(#""A": {\#(role)}"#)).write(to: self.file)
        let good = try RoleStore(root: root, now: Self.moment)
        #expect(good.quarantined == nil && good.roleNames == ["A"])
    }

    @Test func aFileItCantOpenIsNeverReplaced() throws {
        #expect(mkdir(root.path, 0o700) == 0)
        try Data(#"{"version": 1, "roles": {}, "welcomes": {}}"#.utf8).write(to: file)
        #expect(chmod(file.path, 0o000) == 0)
        defer { chmod(file.path, 0o600) }
        #expect(throws: RoleStore.Problem.file(.unreadable(EACCES))) { try RoleStore(root: root) }
    }

    // MARK: copying GamGUI's

    /// The one-time copy: GamGUI's file read as GamGUI reads it (its older forms migrated), welcome emails first; a
    /// name this store lacks copied, one with other contents kept and said, one this store wouldn't save refused
    /// with why. A second copy changes nothing.
    @Test func copyTakesWhatThisStoreLacksAndSaysTheRest() throws {
        let gamgui = base.appending(path: "GamGUI")
        try FileManager.default.createDirectory(at: gamgui, withIntermediateDirectories: true)
        let theirs = gamgui.appending(path: "onboarding.json")
        try Data("""
            {"roles": {"Salesperson": ["Their own steps"], "Warehouse": ["Issue a badge", "  "],
                       "Desk": {"steps": ["a"], "groups": "desk@example.com\\nfront@example.com", "welcome": "Desk welcome"},
                       "Broken": {"steps": ["a"], "groups": ["not an address"]}},
             "welcomes": {"Default": {"subject": "Other", "body": "b"}, "Desk welcome": {"subject": " Hi ", "body": "x"}}}
            """.utf8).write(to: theirs)
        var store = try RoleStore(root: root)
        let report = try store.copy(fromGamGUI: theirs)
        #expect(report.copied == ["Desk", "Warehouse"])
        #expect(report.kept == ["Salesperson"])
        #expect(report.refused == ["Broken: \u{201C}not an address\u{201D} isn't one address: each of a role's groups is a single address, like sales@example.com."])
        #expect(report.copiedWelcomes == ["Desk welcome"] && report.keptWelcomes == ["Default"])
        #expect(store.role("Warehouse")?.steps == ["Issue a badge"])
        #expect(store.role("Desk")?.groups == ["desk@example.com", "front@example.com"] && store.role("Desk")?.welcome == "Desk welcome")
        #expect(store.welcome("Desk welcome")?.subject == "Hi")
        let written = bytes(file)
        let again = try store.copy(fromGamGUI: theirs)
        #expect(again.copied.isEmpty && again.copiedWelcomes.isEmpty && bytes(file) == written, "nothing new, nothing written")
        #expect(throws: RoleStore.Problem.gamGUI(.noFile)) { try store.copy(fromGamGUI: base.appending(path: "Nowhere/onboarding.json")) }
    }
}
