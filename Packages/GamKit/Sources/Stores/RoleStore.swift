import Foundation
import GamEngine

/// The onboarding roles and welcome emails (onboarding plan O2): `onboarding.json` in the folder it's given, with
/// GamGUI's key names, `{"version": 1, "roles": {name: {"steps", "signature", "org_unit", "groups", "calendars",
/// "welcome"}}, "welcomes": {name: {"subject", "body"}}}`. This app's own; GamGUI's file is only read, when the
/// operator copies from it. GamGUI's `RunbookStore` in what it keeps and refuses (`Onboarding.savable`,
/// `welcomeName`; held to `onboarding.json`'s `store` cases) and its seed on first use. Native where GamGUI could
/// lose roles, as the signature templates are (`SignatureStore.load`, `writeFile`): read by descriptor, written
/// atomically `0600` in a `0700` folder, a file this format can't read moved aside and reported, never replaced,
/// and replacing a role asked first. One store for every domain, as in GamGUI.
public struct RoleStore: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case rule(Onboarding.RoleProblem)
        /// The role is saved already: saving over it needs `replacing: true`, which the screen asks first.
        case exists(String)
        /// Another welcome email has the name (case aside): saving over it needs `replacing: true`, asked first.
        case welcomeExists(String)
        /// The file couldn't be read, moved aside or saved, in the signature store's words.
        case file(SignatureStore.Problem)
        /// GamGUI has no roles file, or it couldn't be read; nothing was copied.
        case gamGUI(GamGUIRoles.Problem)

        public var message: String {
            switch self {
            case .rule(let problem): problem.message
            case .exists(let name): "There's already a role named \u{201C}\(name)\u{201D}."
            case .welcomeExists(let name): "There's already a welcome email named \u{201C}\(name)\u{201D}."
            case .file(let problem): problem.message.replacingOccurrences(of: "templates", with: "roles")
            case .gamGUI(let problem): problem.message
            }
        }
    }

    /// What a copy from GamGUI did, each list in name order. Identical entries are skipped unsaid.
    public struct CopyReport: Equatable, Sendable {
        /// Roles this store lacked, now saved.
        public var copied: [String] = []
        /// Roles GamGUI has with other contents: this store's were kept.
        public var kept: [String] = []
        /// Roles this store wouldn't save (a group that isn't one address, a list past its bound), with why.
        public var refused: [String] = []
        /// Welcome emails copied, and those kept as this store has them.
        public var copiedWelcomes: [String] = []
        public var keptWelcomes: [String] = []
    }

    public static let fileName = "onboarding.json"
    public static let format = 1

    public let root: URL
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// In name order (code points), as GamGUI's `roles()`.
    public private(set) var roles: [RoleTemplate]
    /// Default and the others; `welcomeNames` gives GamGUI's order.
    private var welcomes: [(name: String, email: WelcomeEmail)]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The roles saved in `root`, or GamGUI's seed when there's no file yet (nothing is written until a save). A
    /// file that isn't this format's (corrupt, another format, a role this store wouldn't save, a link, too large)
    /// is moved aside first and named in `quarantined`. Throws, opening nothing, when it can't be read or moved aside.
    public init(root: URL, now: Date = Date()) throws(Problem) {
        self.root = root
        let loaded: (value: Contents?, quarantined: URL?)
        do { loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.contents(in:)) } catch {
            throw .file(error)
        }
        let contents = loaded.value ?? Self.seed
        roles = contents.roles
        welcomes = contents.welcomes
        quarantined = loaded.quarantined
    }

    public var roleNames: [String] { roles.map(\.name) }

    public func role(_ name: String) -> RoleTemplate? {
        roles.first { $0.name.utf8.elementsEqual(name.utf8) }
    }

    /// GamGUI's `welcome_names`: Default first, then the rest by name.
    public var welcomeNames: [String] {
        [Onboarding.defaultWelcome] + Self.sorted(welcomes.map(\.name).filter { !$0.utf8.elementsEqual(Onboarding.defaultWelcome.utf8) })
    }

    public func welcome(_ name: String) -> WelcomeEmail? {
        let name = name.isEmpty ? Onboarding.defaultWelcome : name
        return welcomes.first { $0.name.utf8.elementsEqual(name.utf8) }?.email
    }

    /// The roles that name `template` as their signature, in name order: what deleting that template would leave
    /// without a signature.
    public func roles(usingSignature template: String) -> [String] {
        roles.filter { $0.signature.utf8.elementsEqual(template.utf8) }.map(\.name)
    }

    /// Saves `role` as `Onboarding.savable` makes it and returns what was saved. A name already saved throws
    /// `.exists` unless `replacing`. `renaming`, the role's name before an edit, goes in the same write: a rename
    /// never leaves both, or neither.
    @discardableResult
    public mutating func save(_ role: RoleTemplate, replacing: Bool = false, renaming previous: String? = nil) throws(Problem) -> RoleTemplate {
        let saved: RoleTemplate
        do { saved = try Onboarding.savable(role, welcomes: welcomes.map(\.name)) } catch { throw .rule(error) }
        let renamed = previous.map { !$0.utf8.elementsEqual(saved.name.utf8) } ?? false
        guard replacing || (previous != nil && !renamed) || self.role(saved.name) == nil else { throw .exists(saved.name) }
        var changed = roles.filter { !$0.name.utf8.elementsEqual(saved.name.utf8) }
        if let previous, renamed { changed.removeAll { $0.name.utf8.elementsEqual(previous.utf8) } }
        changed.append(saved)
        try write(roles: changed, welcomes: welcomes)
        return saved
    }

    /// Removes the role `name`; a name not saved changes nothing.
    public mutating func delete(_ name: String) throws(Problem) {
        guard role(name) != nil else { return }
        try write(roles: roles.filter { !$0.name.utf8.elementsEqual(name.utf8) }, welcomes: welcomes)
    }

    /// GamGUI's `set_welcome`: saved under `Onboarding.welcomeName` (a name differing only by case is the existing
    /// one), the subject stripped, the body as typed. Returns the name it was saved under. Saving over another welcome
    /// email throws `.welcomeExists` unless `replacing` (GamGUI replaced without asking). `renaming`, its name before
    /// an edit, moves it: the roles that send it send it under its new name, in the same write. Default isn't renamed:
    /// it's what a role without a choice sends.
    @discardableResult
    public mutating func saveWelcome(_ email: WelcomeEmail, as name: String, replacing: Bool = false,
                                     renaming previous: String? = nil) throws(Problem) -> String {
        let saved: String
        do { saved = try Onboarding.welcomeName(name, existing: welcomes.map(\.name)) } catch { throw .rule(error) }
        let renamed = previous.map { !$0.utf8.elementsEqual(saved.utf8) } ?? false
        if let previous, renamed, previous.utf8.elementsEqual(Onboarding.defaultWelcome.utf8) { throw .rule(.defaultWelcomeStays) }
        guard replacing || (previous != nil && !renamed) || welcome(saved) == nil else { throw .welcomeExists(saved) }
        var changed = welcomes.filter { !$0.name.utf8.elementsEqual(saved.utf8) }
        var changedRoles = roles
        if let previous, renamed {
            changed.removeAll { $0.name.utf8.elementsEqual(previous.utf8) }
            let stored = saved.utf8.elementsEqual(Onboarding.defaultWelcome.utf8) ? "" : saved
            changedRoles = roles.map { role in
                guard role.welcome.utf8.elementsEqual(previous.utf8) else { return role }
                return RoleTemplate(name: role.name, steps: role.steps, signature: role.signature, orgUnit: role.orgUnit,
                                    groups: role.groups, calendars: role.calendars, welcome: stored)
            }
        }
        changed.append((saved, WelcomeEmail(subject: PythonText.strip(email.subject), body: email.body)))
        try write(roles: changedRoles, welcomes: changed)
        return saved
    }

    /// The roles that send the welcome email `name` (a role without a choice sends Default), in name order.
    public func roles(usingWelcome name: String) -> [String] {
        roles.filter { $0.welcomeName.utf8.elementsEqual(name.utf8) }.map(\.name)
    }

    /// GamGUI's `delete_welcome`: Default stays, and one a role still picks is refused, naming the roles.
    public mutating func deleteWelcome(_ name: String) throws(Problem) {
        guard !name.utf8.elementsEqual(Onboarding.defaultWelcome.utf8) else { throw .rule(.defaultWelcomeStays) }
        let using = roles.filter { $0.welcome.utf8.elementsEqual(name.utf8) }.map(\.name)
        guard using.isEmpty else { throw .rule(.welcomeInUse(name, roles: using)) }
        guard welcome(name) != nil else { return }
        try write(roles: roles, welcomes: welcomes.filter { !$0.name.utf8.elementsEqual(name.utf8) })
    }

    /// Copies in GamGUI's roles and welcome emails (`file`, its `onboarding.json`, read by descriptor as
    /// `GamGUIRoles` reads it, migrating its older forms) when the operator asks. Welcome emails first, so a role can
    /// name one. A name this store lacks is copied as this store would save it; one with other contents keeps this
    /// store's and is reported; a role this store wouldn't save is refused and said. One write, only when something
    /// was copied.
    public mutating func copy(fromGamGUI file: URL) throws(Problem) -> CopyReport {
        let theirs: GamGUIRoleFile
        do { theirs = try GamGUIRoles.read(file) } catch { throw .gamGUI(error) }
        var report = CopyReport(), newWelcomes = welcomes, newRoles = roles
        for (name, email) in theirs.welcomes {
            let email = WelcomeEmail(subject: PythonText.strip(email.subject), body: email.body)
            if let mine = newWelcomes.first(where: { $0.name.utf8.elementsEqual(name.utf8) }) {
                if mine.email != email { report.keptWelcomes.append(name) }
            } else {
                newWelcomes.append((name, email))
                report.copiedWelcomes.append(name)
            }
        }
        for role in theirs.roles {
            let saved: RoleTemplate
            do { saved = try Onboarding.savable(role, welcomes: newWelcomes.map(\.name)) } catch {
                report.refused.append("\(role.name): \(error.message)")
                continue
            }
            if let mine = newRoles.first(where: { $0.name.utf8.elementsEqual(saved.name.utf8) }) {
                if mine != saved { report.kept.append(saved.name) }
            } else {
                newRoles.append(saved)
                report.copied.append(saved.name)
            }
        }
        if !report.copied.isEmpty || !report.copiedWelcomes.isEmpty { try write(roles: newRoles, welcomes: newWelcomes) }
        return CopyReport(copied: Self.sorted(report.copied), kept: Self.sorted(report.kept), refused: report.refused,
                          copiedWelcomes: Self.sorted(report.copiedWelcomes), keptWelcomes: Self.sorted(report.keptWelcomes))
    }

    // MARK: the file

    struct Contents {
        var roles: [RoleTemplate]
        var welcomes: [(name: String, email: WelcomeEmail)]
    }

    /// GamGUI's `_DEFAULT`: its starter role and the Default welcome email.
    static var seed: Contents {
        Contents(roles: [RoleTemplate(name: "Salesperson", steps: ["Set up the CRM login", "Order a laptop",
                                                                   "Add to the team channel", "Add to the sales group"])],
                 welcomes: [(Onboarding.defaultWelcome, Onboarding.seedWelcome)])
    }

    static func sorted(_ names: [String]) -> [String] {
        names.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// The roles and welcome emails in this format's file, or nil for anything else: every role exactly as this store
    /// saves it (`Onboarding.savable` gives it back unchanged), every welcome a subject and body, Default among them.
    static func contents(in bytes: [UInt8]) -> Contents? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              file["version"]?.int == format, let roleValues = file["roles"]?.object, let welcomeValues = file["welcomes"]?.object,
              file.object?.count == 3
        else { return nil }
        var welcomes: [(name: String, email: WelcomeEmail)] = []
        for (name, value) in welcomeValues {
            guard let email = value.object, email.count == 2, let subject = email["subject"]?.string, let body = email["body"]?.string,
                  !PythonText.strip(name).isEmpty, PythonText.strip(name).utf8.elementsEqual(name.utf8)
            else { return nil }
            welcomes.append((name, WelcomeEmail(subject: subject, body: body)))
        }
        guard welcomes.contains(where: { $0.name.utf8.elementsEqual(Onboarding.defaultWelcome.utf8) }) else { return nil }
        var roles: [RoleTemplate] = []
        for (name, value) in roleValues {
            guard let role = value.object, role.count == 6, let steps = strings(role["steps"]),
                  let signature = role["signature"]?.string, let orgUnit = role["org_unit"]?.string,
                  let groups = strings(role["groups"]), let calendars = strings(role["calendars"]),
                  let welcome = role["welcome"]?.string
            else { return nil }
            let stored = RoleTemplate(name: name, steps: steps, signature: signature, orgUnit: orgUnit, groups: groups,
                                      calendars: calendars, welcome: welcome)
            guard let saved = try? Onboarding.savable(stored, welcomes: welcomes.map(\.name)), saved == stored else { return nil }
            roles.append(stored)
        }
        return Contents(roles: sorted(roles), welcomes: welcomes)
    }

    private static func sorted(_ roles: [RoleTemplate]) -> [RoleTemplate] {
        roles.sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) }
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard let items = value?.array else { return nil }
        let out = items.compactMap(\.string)
        return out.count == items.count ? out : nil
    }

    /// Writes the whole file, then takes it as the store's: a failed write changes nothing.
    private mutating func write(roles changed: [RoleTemplate], welcomes changedWelcomes: [(name: String, email: WelcomeEmail)]) throws(Problem) {
        var roleObject = JSONObject()
        for role in Self.sorted(changed) {
            roleObject[role.name] = .object([
                "steps": .array(role.steps.map(JSONValue.string)), "signature": .string(role.signature),
                "org_unit": .string(role.orgUnit), "groups": .array(role.groups.map(JSONValue.string)),
                "calendars": .array(role.calendars.map(JSONValue.string)), "welcome": .string(role.welcome),
            ])
        }
        var welcomeObject = JSONObject()
        for (name, email) in changedWelcomes {
            welcomeObject[name] = .object(["subject": .string(email.subject), "body": .string(email.body)])
        }
        let file = JSONValue.object(["version": .number(String(Self.format)), "roles": .object(roleObject),
                                     "welcomes": .object(welcomeObject)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root,
                                         interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw .file(problem)
        } catch {
            throw .file(.notSaved(EIO))
        }
        roles = Self.sorted(changed)
        welcomes = changedWelcomes
    }
}
