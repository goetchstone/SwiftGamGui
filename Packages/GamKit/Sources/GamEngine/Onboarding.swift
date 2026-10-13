import Foundation
import Vault

/// Onboarding's pure core: GamGUI's `core/onboarding.py`, ported to the letter where its words or decisions
/// reach the operator or GAM. Held to `Tests/Fixtures/onboarding.json` (generated from frozen GamGUI by
/// `scripts/gen_fixtures.py`) by `OnboardingTests`.
public enum Onboarding {
    // MARK: one hire

    /// GamGUI's `split_name`: explicit first and last names win; otherwise the display name splits at its
    /// first run of whitespace (Python's `str.split()`), and a single word has no surname (GamGUI's fix:
    /// "Ada" once became "Ada Ada").
    public static func splitName(name: String, first: String, last: String) -> (first: String, last: String) {
        let first = PythonText.strip(first), last = PythonText.strip(last)
        guard first.isEmpty, last.isEmpty, !PythonText.strip(name).isEmpty else { return (first, last) }
        let words = Self.words(name)
        return (words[0], words.dropFirst().joined(separator: " "))
    }

    /// Python's `str.split()`: the runs of text between runs of `str.isspace()` characters.
    static func words(_ text: String) -> [String] {
        text.unicodeScalars.split(whereSeparator: PythonText.isSpace).map { PythonText.string($0) }
    }

    /// The checklist's title (`provision_hire`): "Onboard <name, else email, else "new hire"> — <role>",
    /// with the name and email stripped as GamGUI strips them.
    public static func checklistTitle(name: String, email: String, role: String) -> String {
        let name = PythonText.strip(name), email = PythonText.strip(email)
        return "Onboard \(name.isEmpty ? (email.isEmpty ? "new hire" : email) : name) \u{2014} \(role)"
    }

    /// GamGUI's `_signature_html`: the role's template rendered for the new hire as GAM will know them (an
    /// address and a name, nothing else yet), or nil when there is no template or its body is empty.
    public static func signatureHTML(template body: String?, email: String, first: String, last: String) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let record: GamOutput.Record = ["primaryEmail": .string(email),
                                        "name": .object(["givenName": .string(first), "familyName": .string(last)])]
        return Signature.render(body, for: GamUser(record: record))
    }

    /// What the card says the org unit is: the role's, or `/` (GamGUI's `cfg.org_unit or "/"`).
    public static func shownOrgUnit(_ orgUnit: String) -> String { orgUnit.isEmpty ? "/" : orgUnit }

    // MARK: words for GAM's create refusals (design doc D7)

    /// The create's refusal in words, for the two onboarding meets, or nil: GAM's `Create Failed: Duplicate`
    /// (an account, an alias or a group has the address; `duplicateAliasGroupUserWarning`, exit 57) and
    /// `Create Failed: Invalid Organizational Unit` (exit 50). GAM's own line stays the detail.
    public static func createRefusal(_ message: String, email: String, orgUnit: String) -> String? {
        if message.contains("Create Failed: Duplicate") { return "An account, alias or group already uses \(email)." }
        if message.contains("Create Failed: Invalid Organizational Unit") {
            return "The role\u{2019}s org unit \u{201C}\(absoluteOrgUnit(orgUnit))\u{201D} doesn\u{2019}t exist in Google."
        }
        return nil
    }

    /// The org unit GAM looked for: `getOrgUnitItem` strips the argument and reads `root` as `/`, then
    /// `makeOrgUnitPathAbsolute` (gam/__init__.py 1631-1643, 1677-1685).
    public static func absoluteOrgUnit(_ path: String) -> String {
        var path = PythonText.strip(path)
        if path == "root" { path = "/" }
        if path == "/" || path.hasPrefix("id:") { return path }
        if path.hasPrefix("uid:") { return String(path.dropFirst()) }
        if path.hasPrefix("/") { return path.hasSuffix("/") ? String(path.dropLast()) : path }
        return "/" + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }

    // MARK: a new account's wait

    /// GamGUI's `NEW_ACCOUNT_WAITS`: about seven minutes in all, in few enough tries that an account Google
    /// is slow with leaves a handful of failed attempts in the audit log, not dozens.
    public static let newAccountWaits: [Duration] = [20, 40, 60, 120, 180].map { .seconds($0) }

    public static let notReadyReason = "Google still hadn't finished setting up the new account. Try again later \u{2014} the "
        + "signature from the person's page, a calendar from Calendars. If it keeps failing, a "
        + "delegation scope is missing or the service is off for the account's org unit."
    public static let stoppedReason = "Stopped before Google was ready: do it from the person's page or Calendars."

    /// A step waiting for Google, as GamGUI names its parked steps.
    public enum Waiting: Sendable, Equatable {
        case signature(template: String, email: String)
        case calendar(String, email: String)
        case taskList(assignee: String)

        /// GamGUI's `step_label`.
        public var label: String {
            switch self {
            case .signature(let template, let email): "Signature \u{201C}\(template)\u{201D} for \(email)"
            case .calendar(let id, let email): "Calendar \(id) for \(email)"
            case .taskList(let assignee): "Task list for \(assignee)"
            }
        }
    }

    /// GamGUI's `waiting_note`: "waiting for Google: signature, 2 calendars, task list".
    public static func waitingNote(_ steps: [Waiting]) -> String {
        let calendars = steps.count { if case .calendar = $0 { true } else { false } }
        var parts: [String] = []
        if steps.contains(where: { if case .signature = $0 { true } else { false } }) { parts.append("signature") }
        if calendars > 0 { parts.append("\(calendars) calendar\(calendars == 1 ? "" : "s")") }
        if steps.contains(where: { if case .taskList = $0 { true } else { false } }) { parts.append("task list") }
        return "waiting for Google: " + parts.joined(separator: ", ")
    }

    // MARK: the welcome email (W)

    /// GamGUI's `WELCOME_VARS`: the `{tokens}` a welcome email understands.
    public static let welcomeVariables = ["name", "role", "email", "manager"]

    /// GamGUI's `welcome_context`.
    public static func welcomeContext(name: String, email: String, role: String, manager: String) -> [String: String] {
        ["name": name, "email": email, "role": role, "manager": manager]
    }

    /// GamGUI's `render`: each `{word}` (Python's Unicode `\w`, one or more) that's one of `welcomeVariables`
    /// becomes its value (blank when the context lacks it); anything else stays as written. One pass: a value that
    /// holds a `{token}` is inserted as it is, never expanded again. By scalar, as Python indexes.
    public static func render(_ template: String, _ context: [String: String]) -> String {
        let scalars = Array(template.unicodeScalars)
        var out = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            if scalars[index] == "{" {
                var end = index + 1
                while end < scalars.count, PythonText.isWord(scalars[end]) { end += 1 }
                if end > index + 1, end < scalars.count, scalars[end] == "}" {
                    let word = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                    if welcomeVariables.contains(where: { $0.utf8.elementsEqual(word.utf8) }) {
                        out.append(contentsOf: (context[word] ?? "").unicodeScalars)
                    } else {
                        out.append(contentsOf: scalars[index...end])
                    }
                    index = end + 1
                    continue
                }
            }
            out.append(scalars[index])
            index += 1
        }
        return String(out)
    }

    // MARK: GamGUI's role file

    public static let defaultWelcome = "Default"
    /// GamGUI's seeded Default welcome email (`_DEFAULT`), which its load adds when a file has none.
    public static let seedWelcome = WelcomeEmail(
        subject: "Welcome to the team, {name}!",
        body: "Hi {name},\n\nWelcome aboard as our new {role}. Your account is {email} \u{2014} "
            + "your manager {manager} will help you get set up.\n\nGlad to have you here.")

    /// GamGUI's `RunbookStore._load` and `roles()` over its `onboarding.json`: the roles in name order, each
    /// migrated by `_as_role` (the old list of steps, keys added later), and the welcome emails by
    /// `_as_welcome` (an older file's single `welcome` becomes Default). Nil where GamGUI's load fails and
    /// falls back to its seed: the native reader reports that instead of pretending the file was empty.
    /// One departure: a list or object where text belongs is refused, where Python would take its `repr`.
    public static func roleFile(_ text: String) -> GamGUIRoleFile? {
        guard let file = JSONValue.parse(text)?.object else { return nil }
        let roleValues: JSONObject
        switch file["roles"] {
        case nil: roleValues = [:]
        case .object(let roles)?: roleValues = roles
        default: return nil
        }
        var roles: [RoleTemplate] = []
        for (name, value) in roleValues {
            guard let role = role(name, value) else { return nil }
            roles.append(role)
        }
        var welcomeValues = file["welcomes"]?.object ?? [:]
        if case .object? = file["welcome"], welcomeValues[defaultWelcome] == nil { welcomeValues[defaultWelcome] = file["welcome"] }
        var welcomes: [(name: String, email: WelcomeEmail)] = []
        for (name, value) in welcomeValues {
            guard let email = welcome(value) else { return nil }
            welcomes.append((name, email))
        }
        if !welcomes.contains(where: { $0.name.utf8.elementsEqual(defaultWelcome.utf8) }) {
            welcomes.append((defaultWelcome, seedWelcome))
        }
        return GamGUIRoleFile(roles: roles.sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) },
                              welcomes: welcomes)
    }

    /// `_as_role`: a list is the old form (steps only); an object takes its keys, a missing one blank; anything
    /// else is a role with nothing in it. Nil where Python raises (steps it can't iterate, a list of groups
    /// that isn't one).
    static func role(_ name: String, _ value: JSONValue) -> RoleTemplate? {
        switch value {
        case .array(let items):
            guard let steps = strings(items) else { return nil }
            return RoleTemplate(name: name, steps: steps)
        case .object(let role):
            guard let steps = iterated(role["steps"] ?? .array([])).flatMap(strings),
                  let signature = text(role["signature"]), let orgUnit = text(role["org_unit"]),
                  let groups = stringList(role["groups"]), let calendars = stringList(role["calendars"]),
                  let welcome = text(role["welcome"])
            else { return nil }
            return RoleTemplate(name: name, steps: steps, signature: signature, orgUnit: orgUnit, groups: groups,
                                calendars: calendars, welcome: welcome)
        default:
            return RoleTemplate(name: name, steps: [])
        }
    }

    /// `_as_welcome`: an object's subject and body, anything else blank.
    static func welcome(_ value: JSONValue) -> WelcomeEmail? {
        guard case .object(let email) = value else { return WelcomeEmail(subject: "", body: "") }
        guard let subject = text(email["subject"]), let body = text(email["body"]) else { return nil }
        return WelcomeEmail(subject: subject, body: body)
    }

    /// `str(value.get(key, "") or "")`.
    static func text(_ value: JSONValue?) -> String? {
        guard let value, value.truthy else { return "" }
        return pythonStr(value)
    }

    /// `_as_str_list`: nothing is empty, text is its lines, and each entry is `str(s).strip()`, the blank
    /// ones dropped.
    static func stringList(_ value: JSONValue?) -> [String]? {
        let items: [JSONValue]
        switch value {
        case nil, .null?: return []
        case .string(let text)?: items = PythonText.lines(text).map(JSONValue.string)
        case let value?:
            guard let iterated = iterated(value) else { return nil }
            items = iterated
        }
        return strings(items)?.map { PythonText.strip($0) }.filter { !$0.isEmpty }
    }

    /// What Python's `for s in value` visits: a list's items, an object's keys, a string's characters; nil
    /// (a `TypeError`) for anything else.
    static func iterated(_ value: JSONValue) -> [JSONValue]? {
        switch value {
        case .array(let items): items
        case .object(let object): object.keys.map(JSONValue.string)
        case .string(let text): text.unicodeScalars.map { .string(String($0)) }
        default: nil
        }
    }

    /// `[str(s) for s in items]`.
    static func strings(_ items: [JSONValue]) -> [String]? {
        var out: [String] = []
        for item in items {
            guard let text = pythonStr(item) else { return nil }
            out.append(text)
        }
        return out
    }

    /// Python's `str()` of a scalar (`None`, `True`, `100.0` for `1E2`); nil for a list or object.
    static func pythonStr(_ value: JSONValue) -> String? {
        switch value {
        case .array, .object: nil
        default: Fields.text(value)
        }
    }
}

// MARK: the role store's rules (O2)

extension Onboarding {
    /// Why a role or a welcome email can't be saved, in GamGUI's words where it has them.
    public enum RoleProblem: Error, Equatable, Sendable {
        case nameRequired, nameTooLong
        /// GamGUI's: a role names a welcome email the store doesn't have (exact text).
        case noSuchWelcome(String)
        /// Native: a group or calendar entry that isn't one address.
        case notAnAddress(list: String, entry: String)
        /// Native: past `roleListLimit`.
        case tooMany(list: String)
        case welcomeNameRequired
        case defaultWelcomeStays
        /// GamGUI's: a welcome email a role still picks, with those roles.
        case welcomeInUse(String, roles: [String])

        public var message: String {
            switch self {
            case .nameRequired: "Role name is required."
            case .nameTooLong: "A role name is at most \(Onboarding.roleNameLimit) characters."
            case .noSuchWelcome(let name): "There is no welcome email named \u{201C}\(name)\u{201D}."
            case .notAnAddress(let list, let entry):
                "\u{201C}\(entry)\u{201D} isn't one address: each of a role's \(list) is a single address, like sales@example.com."
            case .tooMany(let list): "A role holds at most \(Onboarding.roleListLimit) \(list)."
            case .welcomeNameRequired: "A welcome email needs a name."
            case .defaultWelcomeStays: "The Default welcome email can be edited but not deleted."
            case .welcomeInUse(let name, let roles):
                "\u{201C}\(name)\u{201D} is the welcome email of \(roles.joined(separator: ", ")): pick another for "
                    + "\(roles.count == 1 ? "that role" : "those roles") first."
            }
        }
    }

    /// A role's name, at most this many code points (the template stores' rule).
    public static let roleNameLimit = 60
    /// A role's steps, groups or calendars, each at most this many: far past a real role, and a hire's preview stays
    /// well under the guard's two hundred targets.
    public static let roleListLimit = 100

    /// A role as the store saves it. GamGUI's `set_role`: the name, signature, org unit and welcome stripped, blank
    /// steps dropped and the others stripped, groups and calendars as `_as_str_list` makes them, "Default" stored as
    /// blank, and a welcome email the store has. Then the native bounds: a group or calendar is one address (GAM
    /// reads a comma or a space in one argument as more than one), each once (compared as GAM compares addresses),
    /// a name of at most `roleNameLimit`, and no list past `roleListLimit`. `welcomes` are the store's names.
    public static func savable(_ role: RoleTemplate, welcomes: [String]) throws(RoleProblem) -> RoleTemplate {
        let name = PythonText.strip(role.name)
        guard !name.isEmpty else { throw .nameRequired }
        var welcome = PythonText.strip(role.welcome)
        if welcome.utf8.elementsEqual(defaultWelcome.utf8) { welcome = "" }
        if !welcome.isEmpty, !welcomes.contains(where: { $0.utf8.elementsEqual(welcome.utf8) }) {
            throw .noSuchWelcome(welcome)
        }
        guard name.unicodeScalars.count <= roleNameLimit else { throw .nameTooLong }
        let steps = role.steps.map { PythonText.strip($0) }.filter { !$0.isEmpty }
        guard steps.count <= roleListLimit else { throw .tooMany(list: "steps") }
        func addresses(_ entries: [String], _ list: String) throws(RoleProblem) -> [String] {
            var out: [String] = [], seen: Set<String> = []
            for entry in entries.map({ PythonText.strip($0) }) where !entry.isEmpty {
                guard Address.looksLikeEmail(entry) else { throw .notAnAddress(list: list, entry: entry) }
                if seen.insert(PythonText.lower(entry)).inserted { out.append(entry) }
            }
            guard out.count <= roleListLimit else { throw .tooMany(list: list) }
            return out
        }
        return RoleTemplate(name: name, steps: steps, signature: PythonText.strip(role.signature),
                            orgUnit: PythonText.strip(role.orgUnit), groups: try addresses(role.groups, "groups"),
                            calendars: try addresses(role.calendars, "calendars"), welcome: welcome)
    }

    /// GamGUI's `set_welcome` naming: stripped, required, and an existing name that differs only by case is saved
    /// over rather than added beside it. Returns the name it's saved under.
    public static func welcomeName(_ name: String, existing: [String]) throws(RoleProblem) -> String {
        let name = PythonText.strip(name)
        guard !name.isEmpty else { throw .welcomeNameRequired }
        return existing.first { PythonText.lower($0).utf8.elementsEqual(PythonText.lower(name).utf8) } ?? name
    }
}

/// A role as GamGUI stores it: the checklist's steps, and what a new hire in it gets.
public struct RoleTemplate: Sendable, Equatable {
    public let name: String
    public let steps: [String]
    /// A saved signature template's name; blank for none.
    public let signature: String
    /// The org unit an account is created in; blank for the domain's root.
    public let orgUnit: String
    /// Groups the new hire joins as a member.
    public let groups: [String]
    /// Calendar ids the new hire is subscribed to.
    public let calendars: [String]
    /// The welcome email's name; blank is Default.
    public let welcome: String

    public init(name: String, steps: [String], signature: String = "", orgUnit: String = "", groups: [String] = [],
                calendars: [String] = [], welcome: String = "") {
        self.name = name
        self.steps = steps
        self.signature = signature
        self.orgUnit = orgUnit
        self.groups = groups
        self.calendars = calendars
        self.welcome = welcome
    }

    public var welcomeName: String { welcome.isEmpty ? Onboarding.defaultWelcome : welcome }
}

public struct WelcomeEmail: Sendable, Equatable {
    public let subject: String
    public let body: String

    public init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }
}

/// GamGUI's `onboarding.json` as its load reads it.
public struct GamGUIRoleFile: Sendable {
    /// In name order (code points).
    public let roles: [RoleTemplate]
    /// In the file's order, Default added last when it had none.
    public let welcomes: [(name: String, email: WelcomeEmail)]
}

/// One new hire, as the Onboard form gives them.
public struct Hire: Sendable, Equatable {
    public var name: String
    public var email: String
    public var manager: String
    /// Who gets the checklist; blank is the new hire.
    public var assignee: String
    public var createAccount: Bool
    public var first: String
    public var last: String
    /// GamGUI's `send_welcome`: the role's welcome email goes to the hire's address, last.
    public var sendWelcome: Bool

    public init(name: String = "", email: String = "", manager: String = "", assignee: String = "", createAccount: Bool = false,
                first: String = "", last: String = "", sendWelcome: Bool = false) {
        self.name = name
        self.email = email
        self.manager = manager
        self.assignee = assignee
        self.createAccount = createAccount
        self.first = first
        self.last = last
        self.sendWelcome = sendWelcome
    }
}

// MARK: the temporary password (design doc D4)

/// A new account's one-time password: GamGUI's `generate_temp_password`, three groups of four from 56
/// symbols without `0 O 1 l I` (about 69.7 bits), read off a printed card and typed once; the account is
/// created with `changepassword on`. It never prints, dumps or reflects. Its text reaches exactly two
/// places: the one argv element `createUser(…)` builds, and the sign-in card (`shownOnTheSheet`, which a
/// source scan allows only in `App/OnboardCredentialSheet.swift`). A Swift `String` can't be zeroed, so the
/// holder's bounded lifetime is the control.
public struct TemporaryPassword: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    public static let defaultGroups = 3
    public static let defaultSize = 4

    /// For `WriteStep(…secrets:)`: masked by value in what the operator and the audit see.
    public let secret: Secret

    private init(_ text: String) {
        secret = Secret(Data(text.utf8))
    }

    /// Each symbol drawn uniformly (`randomElement(using:)`); the system generator is a CSPRNG. Tests pass a
    /// seeded one.
    public static func generate<G: RandomNumberGenerator>(groups: Int = defaultGroups, size: Int = defaultSize,
                                                          using generator: inout G) -> TemporaryPassword {
        let symbols = Array(alphabet.unicodeScalars)
        let parts = (0..<groups).map { _ in
            PythonText.string((0..<size).map { _ in symbols.randomElement(using: &generator)! })
        }
        return TemporaryPassword(parts.joined(separator: "-"))
    }

    public static func generate(groups: Int = defaultGroups, size: Int = defaultSize) -> TemporaryPassword {
        var system = SystemRandomNumberGenerator()
        return generate(groups: groups, size: size, using: &system)
    }

    private var text: String { String(decoding: secret.bytes, as: UTF8.self) }

    /// The text, for the sign-in card and nothing else.
    public var shownOnTheSheet: String { text }

    /// GamGUI's create for a new hire: `create_user(…, change_password=True, org_unit=cfg.org_unit or None)`,
    /// through the builder, with this password as its one element.
    package func createUser(email: String, firstName: String, lastName: String, orgUnit: String) -> GamWrite {
        GamCommands.createUser(email: email, firstName: firstName, lastName: lastName, password: text, changePassword: true,
                               orgUnit: orgUnit)
    }

    public var description: String { "<temporary password>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension GamError {
    /// GamGUI's `not_ready_yet`: how GAM reports an account Google hasn't finished setting up. Live,
    /// 2026-09-30, a signature set 1 s after the create failed "Requested client not authorized" and a
    /// calendar subscribe 7 s after it "Calendar Service/App not enabled"; both worked minutes later. Ask
    /// it only about an account the same run just created: on an existing user the same words mean a
    /// missing delegation scope or a service turned off. Over `message`, as GamGUI reads `str(exc)`, its
    /// pattern case-insensitive as `re.I` reads it.
    public var saysNewAccountNotReady: Bool {
        kind == .serviceNotEnabled || Folded(message).has("requested client not authorized")
    }
}
