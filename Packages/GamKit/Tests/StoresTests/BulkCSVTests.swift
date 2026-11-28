import GamEngine
@testable import Stores
import Testing

/// Change many people from a CSV (roadmap 4.6): GamGUI's `tests/test_bulk_csv.py` cases for `parse`, `plan`, `before_csv` and
/// `update_profile`, in its words. A blank cell leaves a value alone; organizations and phones go back whole, as read.
@Suite("Bulk CSV")
struct BulkCSVTests {
    static let alice = "alice@example.com"

    private func parse(_ text: String) -> BulkCSV.Parsed { BulkCSV.parse(Array(text.utf8)) }

    static func user(_ email: String = alice, orgs: JSONValue? = nil, phones: JSONValue? = nil, ou: String = "/Staff",
                     aliases: [String] = []) -> GamUser {
        var record: GamOutput.Record = ["primaryEmail": .string(email), "orgUnitPath": .string(ou),
                                        "aliases": .array(aliases.map(JSONValue.string))]
        if let orgs { record["organizations"] = orgs }
        if let phones { record["phones"] = phones }
        return GamUser(record: record)
    }

    /// A record in the order written, as GAM prints one.
    static func object(_ fields: KeyValuePairs<String, JSONValue>) -> JSONValue {
        var record = JSONObject()
        for (key, value) in fields { record[key] = value }
        return .object(record)
    }

    // MARK: reading the file

    @Test func aByteOrderMarkIsDroppedAndAnythingButUTF8Refused() throws {
        #expect(try BulkCSV.decode(Array("\u{FEFF}email,title\n".utf8)).get() == Array("email,title\n".utf8))
        guard case .failure(let refusal) = BulkCSV.decode(Array("email,title\na@example.com,Caf".utf8) + [0xE9, 0x0A]) else {
            Issue.record("latin-1 read")
            return
        }
        #expect(refusal.message.contains("CSV UTF-8"))
    }

    @Test func headersAreReadLooselyAndUnusedColumnsAreSaid() {
        let parsed = parse("Email,Name,Title,Org Unit,Work Phone,Location\nalice@example.com,Alice,Head,/Staff,555,HQ\n")
        #expect(parsed.rows.first?.values == ["title": "Head", "org_unit": "/Staff", "phone": "555"])
        #expect(parsed.notes.contains { $0.contains("`location`") && $0.contains("Admin console") })
        #expect(parsed.notes.contains { $0.contains("`name`") })
    }

    @Test func excelsSemicolonsAreRead() {
        #expect(parse("email;department\nalice@example.com;Sales\n").rows.first?.values == ["department": "Sales"])
    }

    @Test func aBlankCellLeavesTheValueAlone() {
        let parsed = parse("email,title,department\nalice@example.com,,Sales\nbob@example.com,,\n")
        #expect(parsed.rows.map(\.values) == [["department": "Sales"]])
        #expect(parsed.notes.contains { $0.contains("set nothing") })
    }

    @Test func thisAppsFormulaGuardIsUndoneAndAFormulaRefused() {
        let parsed = parse("email,phone,title\nalice@example.com,'+1 555 0100,'-Lead\nbob@example.com,=A1+1,\n")
        #expect(parsed.rows.first?.values == ["phone": "+1 555 0100", "title": "-Lead"])
        #expect(parsed.errors.contains { $0.contains("bob@example.com") && $0.contains("formula") })
    }

    @Test(arguments: [
        ("name,title\nAlice,Head\n", "needs an `email` column"),
        ("email,name\nalice@example.com,Alice\n", "none of title"),
        ("email,title\nalice@example.com,Head\nALICE@example.com,Lead\n", "is on line 2 too"),
        ("email,title\nnot-an-address,Head\n", "isn't an email address"),
        ("email,title,Title\nalice@example.com,Head,Lead\n", "more than one `title` column"),
        ("email,title\nalice@example.com,\"Head\nof IT\"\n", "more than one line"),
        ("email,title\n" + String(repeating: "a@example.com,T\n", count: BulkCSV.maxRows + 1), "Split it"),
    ])
    func whatCantBeReadAsAskedIsRefusedByItsLine(text: String, said: String) {
        #expect(parse(text).errors.contains { $0.contains(said) })
    }

    // MARK: the whole list goes back

    @Test func everyOrganizationGoesBackAsReadWithOnlyTheChange() throws {
        let orgs: JSONValue = .array([
            Self.object(["title": .string("Analyst"), "department": .string("Ops"), "costCenter": .string("CC-9"), "location": .string("HQ"),
                         "primary": .bool(true), "type": .string("work")]),
            Self.object(["name": .string("Board"), "title": .string("Advisor"), "customType": .string("volunteer")]),
        ])
        let (changes, errors, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["title": "Lead Analyst"])],
                                                directory: [Self.user(orgs: orgs)], units: [])
        #expect(errors.isEmpty)
        #expect(try changes.first?.writes().map(\.argv) == [["update", "user", Self.alice,
            "organization", "type", "work", "title", "Lead Analyst", "department", "Ops", "costcenter", "CC-9", "location", "HQ", "primary",
            "organization", "customtype", "volunteer", "name", "Board", "title", "Advisor", "notprimary"]])
    }

    @Test(arguments: [
        JSONValue.array([object(["title": .string("A"), "jobDescription": .string("x"), "primary": .bool(true)])]),  // a field GAM wouldn't send back
        .array([object(["title": .string("A"), "type": .string("partner")])]),                                      // a type GAM doesn't keep
        .array([object(["title": .string("A"), "fullTimeEquivalent": .bool(true), "primary": .bool(true)])]),      // true isn't a number
        .string("not a list"),
    ])
    func anOrganizationGamCouldntSendBackRefusesThePerson(orgs: JSONValue) {
        let (_, errors, _) = BulkCSV.plan([BulkCSV.Row(line: 3, email: Self.alice, values: ["department": "Sales"])],
                                          directory: [Self.user(orgs: orgs)], units: [])
        #expect(errors.first?.contains("isn't changed") == true)
    }

    @Test func theBuilderRefusesWhatGamWouldChangeOrDrop() {
        for orgs in [[GamCommands.Organization(fields: [("title", "A")], primary: true), GamCommands.Organization(fields: [("title", "B")], primary: true)],
                     [GamCommands.Organization(fields: [("title", "")])],
                     [GamCommands.Organization(fields: [("title", "A")], type: "partner")]] {
            #expect(throws: GamCommands.Invalid.self) { try GamCommands.updateProfile(email: Self.alice, organizations: orgs) }
        }
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.updateProfile(email: Self.alice) }
    }

    @Test func aPhoneSendsEveryOtherPhoneBackAndTheListsGoInOneWrite() throws {
        let phones: JSONValue = .array([Self.object(["type": .string("mobile"), "value": .string("555 0001"), "primary": .bool(true)]),
                                        Self.object(["type": .string("home"), "value": .string("555 0002")])])
        let (changes, _, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["phone": "555 0100", "department": "Sales"])],
                                           directory: [Self.user(orgs: .array([Self.object(["title": .string("T"), "primary": .bool(true)])]),
                                                                 phones: phones)], units: [])
        #expect(try changes.first?.writes().map(\.argv) == [["update", "user", Self.alice, "organization", "title", "T", "department", "Sales",
            "primary", "phone", "type", "mobile", "value", "555 0100", "primary", "phone", "type", "home", "value", "555 0002", "notprimary"]])
    }

    @Test func aPhoneWhosePrimaryIsntTrueOrFalseRefusesThePerson() {
        let phones: JSONValue = .array([Self.object(["value": .string("1"), "primary": .string("false")])])
        let (_, errors, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["phone": "555"])],
                                          directory: [Self.user(phones: phones)], units: [])
        #expect(errors.first?.contains("which of this person's phones is the primary") == true)
    }

    @Test func someoneWithNoOrganizationGetsOnePrimary() {
        let (changes, _, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["title": "Head"])],
                                           directory: [Self.user()], units: [])
        #expect(changes.first?.organizations == [GamCommands.Organization(fields: [("title", "Head")], primary: true)])
    }

    @Test func anUnknownPersonAnAliasAndAnUnknownUnitAreRefusedAndTheSameLeftAlone() {
        let rows = [BulkCSV.Row(line: 2, email: "nobody@example.com", values: ["title": "X"]),
                    BulkCSV.Row(line: 3, email: "a.anders@example.com", values: ["title": "X"]),
                    BulkCSV.Row(line: 4, email: Self.alice, values: ["org_unit": "/Nowhere"]),
                    BulkCSV.Row(line: 5, email: "bob@example.com", values: ["org_unit": "/Staff"])]
        let directory = [Self.user(aliases: ["a.anders@example.com"]), Self.user("bob@example.com")]
        let (changes, errors, unchanged) = BulkCSV.plan(rows, directory: directory, units: ["/", "/Staff"])
        #expect(changes.isEmpty && unchanged == 1 && errors.count == 3)
        #expect(errors.count == 3 && errors[0].contains("isn't an account here") && errors[1].contains("is an alias of alice@example.com")
                && errors[2].contains("/Nowhere"))
    }

    @Test func theBeforeFileReadsBackAsTheUndo() {
        let (changes, _, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["phone": "555 0100", "title": "Head"])],
                                           directory: [Self.user(orgs: .array([Self.object(["title": .string("=SUM Lead"), "primary": .bool(true)])]),
                                                                 phones: .array([Self.object(["value": .string("+1 555 0001"), "primary": .bool(true)])]))],
                                           units: [])
        // Each value guarded on the way out, read as text on the way in.
        let undo = BulkCSV.parse(BulkCSV.beforeCSV(changes))
        #expect(undo.errors.isEmpty && undo.rows.first?.values == ["title": "=SUM Lead", "phone": "+1 555 0001"])
        let (blank, _, _) = BulkCSV.plan([BulkCSV.Row(line: 2, email: Self.alice, values: ["department": "Sales"])],
                                         directory: [Self.user()], units: [])
        #expect(BulkCSV.blanksBefore(blank) == 1)
    }

    /// The run compares each person by what their lists hold, not how GAM printed them.
    @Test func theHeldShapeIgnoresHowGamPrintedTheLists() {
        let a: GamOutput.Record = ["primaryEmail": .string(Self.alice), "orgUnitPath": .string("/Staff"),
                                   "organizations": .array([Self.object(["title": .string("T"), "primary": .bool(true)])])]
        var b = a
        b["organizations"] = .array([Self.object(["primary": .bool(true), "title": .string("T"), "department": .string("")])])
        #expect(BulkProfile.held(a) == BulkProfile.held(b))
        b["orgUnitPath"] = .string("/")
        #expect(BulkProfile.held(a) != BulkProfile.held(b))
        var c = a
        c["organizations"] = .array([Self.object(["title": .string("T"), "primary": .bool(true)]), Self.object(["title": .string("Board")])])
        #expect(BulkProfile.held(a) != BulkProfile.held(c), "an organization added elsewhere is a change")
    }
}
