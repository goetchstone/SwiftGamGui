import Foundation
@testable import GamEngine
import TestSupport
import Testing
import Vault

/// GamGUI's onboarding core (`core/onboarding.py`), held byte for byte to `Tests/Fixtures/onboarding.json`,
/// which `scripts/gen_fixtures.py` generates from frozen GamGUI without touching the operator's stores.
@Suite("Onboarding")
struct OnboardingTests {
    struct Password: Decodable { let alphabet: String, groups: Int, size: Int }
    struct Split: Decodable { let name: String, first: String, last: String, split: [String] }
    struct Label: Decodable {
        struct Step: Decodable { let what: String, email: String, name: String?, calendar: String? }
        let step: Step, label: String
    }
    struct Note: Decodable { let steps: [String], note: String }
    struct NotReady: Decodable {
        struct Extra: Decodable { let exit_code: Int32?, stderr: String, not_ready: Bool }
        let gam_error_cases: Int, not_ready_indices: [Int], extra: [Extra]
    }
    struct SignatureCase: Decodable { let template: String, email: String, first: String, last: String, html: String? }
    struct Provision: Decodable {
        struct Role: Decodable {
            let name: String, steps: [String], signature: String, org_unit: String, groups: [String], calendars: [String]
        }
        struct HireRow: Decodable {
            let name: String, email: String, assignee: String, create_account: Bool, first: String, last: String
        }
        let role: Role, hire: HireRow, create_ok: Bool, calls: [[String]], credential_org_unit: String?
    }
    struct Load: Decodable {
        struct Role: Decodable {
            let name: String, steps: [String], signature: String, org_unit: String, groups: [String], calendars: [String]
            let welcome: String
        }
        let text: String?, hex: String?, unreadable: Bool?, roles: [Role]?, welcomes: [[String]]?
    }
    struct Document: Decodable {
        let password: Password, split_name: [Split], waits: [Int], not_ready_reason: String, stopped_reason: String
        let step_label: [Label], waiting_note: [Note], not_ready: NotReady, signature_html: [SignatureCase]
        let provision: [Provision], load: [Load]
    }
    struct ErrorCase: Decodable { let exit_code: Int32?, stderr: String }
    struct Errors: Decodable { let cases: [ErrorCase] }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.directory.appending(path: "onboarding.json")))

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }
    private func bytes(_ texts: [String]) -> [[UInt8]] { texts.map(bytes) }

    /// A seeded generator, so a test's passwords are the same every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// GamGUI's test_temp_password_shape_and_alphabet: three groups of four from GamGUI's alphabet, none of
    /// `0O1lI`, configurable, and effectively unique.
    @Test func temporaryPasswordShapeAndAlphabet() {
        #expect(bytes(TemporaryPassword.alphabet) == bytes(document.password.alphabet))
        #expect(TemporaryPassword.defaultGroups == document.password.groups && TemporaryPassword.defaultSize == document.password.size)
        #expect(TemporaryPassword.alphabet.unicodeScalars.count == 56)
        #expect(!TemporaryPassword.alphabet.contains { "0O1lI".contains($0) })
        let text = TemporaryPassword.generate().shownOnTheSheet
        let groups = text.split(separator: "-", omittingEmptySubsequences: false)
        #expect(groups.count == 3 && groups.allSatisfy { $0.count == 4 }, "\(groups.count) groups")
        #expect(text.allSatisfy { $0 == "-" || TemporaryPassword.alphabet.contains($0) })
        #expect(TemporaryPassword.generate(groups: 4, size: 5).shownOnTheSheet.filter { $0 != "-" }.count == 20)
        #expect(Set((0..<200).map { _ in TemporaryPassword.generate().shownOnTheSheet }).count == 200)
        var a = Seeded(state: 7), b = Seeded(state: 7)
        #expect(TemporaryPassword.generate(using: &a).shownOnTheSheet == TemporaryPassword.generate(using: &b).shownOnTheSheet,
                "a seeded generator decides it")
        // Every symbol is reached: drawn uniformly over the whole alphabet.
        var seeded = Seeded(state: 1)
        let drawn = Set((0..<400).flatMap { _ in TemporaryPassword.generate(using: &seeded).shownOnTheSheet.unicodeScalars })
        #expect(drawn.subtracting(["-"]) == Set(TemporaryPassword.alphabet.unicodeScalars))
    }

    /// It prints, interpolates, dumps and reflects as nothing (invariant 4).
    @Test func aTemporaryPasswordNeverPrints() {
        let password = TemporaryPassword.generate()
        let text = password.shownOnTheSheet
        var dumped = ""
        dump(password, to: &dumped)
        for shown in [String(describing: password), String(reflecting: password), "\(password)", dumped,
                      String(describing: Mirror(reflecting: password).children.map(\.value))] {
            #expect(!shown.contains(text), "\(shown)")
        }
        #expect(Mirror(reflecting: password).children.isEmpty)
        // The create puts it in exactly one argv element, through the builder; the step masks it by value.
        let write = password.createUser(email: "new@example.com", firstName: "Ada", lastName: "Byte", orgUnit: "/Sales")
        #expect(write.argv == GamCommands.createUser(email: "new@example.com", firstName: "Ada", lastName: "Byte", password: text,
                                                     changePassword: true, orgUnit: "/Sales").argv)
        #expect(write.argv.count { $0 == text } == 1)
        #expect(password.secret == Secret(Data(text.utf8)))
    }

    /// GamGUI's split_name, and test_split_name_single_word_has_no_fabricated_surname.
    @Test func splitNameIsGamGUIs() {
        #expect(document.split_name.count > 60)
        for item in document.split_name {
            let split = Onboarding.splitName(name: item.name, first: item.first, last: item.last)
            #expect(bytes([split.first, split.last]) == bytes(item.split), "\(item.name.debugDescription)")
        }
        #expect(Onboarding.splitName(name: "Ada", first: "", last: "") == ("Ada", ""))
        #expect(Onboarding.splitName(name: "Ada Byte", first: "", last: "") == ("Ada", "Byte"))
    }

    /// The checklist's title, as provision_hire passes it to its task-list create.
    @Test func checklistTitleIsGamGUIs() {
        var seen = 0
        for item in document.provision {
            guard let list = item.calls.first(where: { $0.count > 3 && $0[3] == "tasklist" }) else { continue }
            let title = Onboarding.checklistTitle(name: item.hire.name, email: item.hire.email, role: item.role.name)
            #expect(bytes(title) == bytes(list[5]), "\(item.hire.name) / \(item.hire.email)")
            seen += 1
        }
        #expect(seen > 20)
        let titles = document.provision.flatMap(\.calls).filter { $0.count > 5 && $0[3] == "tasklist" }.map { $0[5] }
        #expect(titles.contains("Onboard new hire \u{2014} Sales"))
    }

    /// GamGUI's not_ready_yet over every stderr its classifier is held to, and the live lines.
    @Test func newAccountNotReadyIsGamGUIs() throws {
        let corpus = try JSONDecoder().decode(Errors.self, from: Data(contentsOf: Fixtures.gamErrorsJSON)).cases
        #expect(corpus.count == document.not_ready.gam_error_cases, "the two fixtures come from one run")
        let ready = Set(document.not_ready.not_ready_indices)
        #expect(!ready.isEmpty && ready.count < corpus.count)
        for (index, item) in corpus.enumerated() {
            #expect(GamError(exitCode: item.exit_code, stderr: item.stderr).saysNewAccountNotReady == ready.contains(index),
                    "\(item.stderr.debugDescription)")
        }
        for item in document.not_ready.extra {
            #expect(GamError(exitCode: item.exit_code, stderr: item.stderr).saysNewAccountNotReady == item.not_ready,
                    "\(item.stderr.debugDescription)")
        }
    }

    /// GamGUI's _signature_html: the role's template rendered for the new hire, nil when missing or empty.
    @Test func onboardingSignatureIsGamGUIs() {
        let templates = Dictionary(uniqueKeysWithValues: Signature.seeds.map { ($0.name, $0.body) })
            .merging(["Empty": "", "Optional": "[[{title}]]", "Tokens": "{first}|{last}|{name}|{email}|{ou}|{phone}"]) { $1 }
        #expect(document.signature_html.count > 40)
        for item in document.signature_html {
            let html = Onboarding.signatureHTML(template: templates[item.template], email: item.email, first: item.first,
                                                last: item.last)
            #expect(html.map(bytes) == item.html.map(bytes), "\(item.template) for \(item.email)")
        }
    }

    @Test func theWaitAndItsWordsAreGamGUIs() {
        #expect(Onboarding.newAccountWaits == document.waits.map { .seconds($0) })
        #expect(bytes(Onboarding.notReadyReason) == bytes(document.not_ready_reason))
        #expect(bytes(Onboarding.stoppedReason) == bytes(document.stopped_reason))
        func waiting(_ step: Label.Step) -> Onboarding.Waiting {
            switch step.what {
            case "signature": .signature(template: step.name ?? "", email: step.email)
            case "calendar": .calendar(step.calendar ?? "", email: step.email)
            default: .taskList(assignee: step.email)
            }
        }
        for item in document.step_label {
            #expect(bytes(waiting(item.step).label) == bytes(item.label))
        }
        for item in document.waiting_note {
            let steps: [Onboarding.Waiting] = item.steps.map {
                switch $0 {
                case "signature": .signature(template: "Classic", email: "a@example.com")
                case "calendar": .calendar("c", email: "a@example.com")
                default: .taskList(assignee: "a@example.com")
                }
            }
            #expect(bytes(Onboarding.waitingNote(steps)) == bytes(item.note), "\(item.steps)")
        }
    }

    /// GamGUI's RunbookStore load over crafted files: the old forms migrated, odd types read as Python
    /// reads them, and what it couldn't read reported (GamGUI fell back to its seed).
    @Test func theRoleFileLoadsAsGamGUILoadsIt() {
        #expect(document.load.contains { $0.unreadable == true } && document.load.contains { $0.roles != nil })
        for item in document.load {
            let text: String
            if let hex = item.hex {
                let data = Data(stride(from: 0, to: hex.count, by: 2).map {
                    UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
                })
                guard let decoded = String(validating: data, as: UTF8.self) else { #expect(item.unreadable == true); continue }
                text = decoded
            } else {
                text = item.text ?? ""
            }
            let file = Onboarding.roleFile(text)
            guard let roles = item.roles, let welcomes = item.welcomes else {
                #expect(file == nil, "\(text.debugDescription) is unreadable")
                continue
            }
            guard let file else { Issue.record("\(text.debugDescription) should read"); continue }
            #expect(file.roles.map { bytes($0.name) } == roles.map { bytes($0.name) }, "\(text.debugDescription)")
            for (mine, theirs) in zip(file.roles, roles) {
                #expect(bytes(mine.steps) == bytes(theirs.steps), "\(theirs.name)")
                #expect(bytes([mine.signature, mine.orgUnit, mine.welcome]) == bytes([theirs.signature, theirs.org_unit, theirs.welcome]))
                #expect(bytes(mine.groups) == bytes(theirs.groups) && bytes(mine.calendars) == bytes(theirs.calendars), "\(theirs.name)")
            }
            #expect(file.welcomes.map { bytes([$0.name, $0.email.subject, $0.email.body]) } == welcomes.map(bytes), "\(text.debugDescription)")
        }
    }

    /// D7: GAM's duplicate and missing-org-unit refusals in words; the org unit as GAM looked for it.
    struct RenderDocument: Decodable {
        struct Render: Decodable {
            struct Case: Decodable { let template: String, out: String }
            let context: [String: String], vars: [String], cases: [Case]
        }
        let render: Render
    }

    /// GamGUI's `render` (W): each `{word}` that's one of the welcome's tokens, in one pass, others as written,
    /// held to its output over curated and seeded templates.
    @Test func renderIsGamGUIs() throws {
        let fixture = try JSONDecoder().decode(RenderDocument.self, from: Data(contentsOf: Fixtures.onboardingJSON)).render
        #expect(Onboarding.welcomeVariables == fixture.vars)
        #expect(fixture.cases.count > 300)
        for item in fixture.cases {
            #expect(Array(Onboarding.render(item.template, fixture.context).unicodeScalars) == Array(item.out.unicodeScalars),
                    "\(item.template.debugDescription)")
        }
    }

    @Test func createRefusalsAreSaidInWords() {
        let duplicate = "GAM failed (unknown, exit=57): User: jordan@example.com, Create Failed: Duplicate, User: jordan@example.com"
        #expect(Onboarding.createRefusal(duplicate, email: "jordan@example.com", orgUnit: "")
                == "An account, alias or group already uses jordan@example.com.")
        let orgUnit = "GAM failed (unknown, exit=50): ERROR: User: jordan@example.com, Create Failed: Invalid Organizational Unit"
        #expect(Onboarding.createRefusal(orgUnit, email: "jordan@example.com", orgUnit: "Warehouse/Night/")
                == "The role\u{2019}s org unit \u{201C}/Warehouse/Night\u{201D} doesn\u{2019}t exist in Google.")
        #expect(Onboarding.createRefusal("GAM failed (license_limit, exit=50): …", email: "a@example.com", orgUnit: "") == nil)
        for (path, absolute) in [("Sales", "/Sales"), ("/Sales", "/Sales"), ("/Sales/", "/Sales"), ("Sales/", "/Sales"), ("root", "/"),
                                 ("/", "/"), ("  Sales  ", "/Sales"), ("id:03ph8a2z", "id:03ph8a2z"), ("uid:x", "id:x")] {
            #expect(Onboarding.absoluteOrgUnit(path) == absolute, "\(path)")
        }
        #expect(Onboarding.shownOrgUnit("") == "/" && Onboarding.shownOrgUnit("/Sales") == "/Sales")
    }
}
