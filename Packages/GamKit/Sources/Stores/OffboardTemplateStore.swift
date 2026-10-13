import Foundation
import GamEngine

/// The saved offboarding templates: `offboarding-templates.json` in the folder it's given, holding
/// `{"version": 2, "default": name, "templates": {name: {"leave_out": [step], "add": [step], "subject": s,
/// "message": m, "days": n, "invitee": e}}}`. Version 1, written before templates could add steps, has no `add`
/// and reads as adding none; the next save writes version 2 (an older build then moves the file aside, as it
/// does any format it doesn't know). Native: GamGUI has none. `Offboarding.starterTemplates` on first use, with
/// "Hand-over" the default; nothing is written until a save. The file is handled as the signature templates'
/// is (`SignatureStore.load` and `writeFile`): read by descriptor, a file this format can't read moved aside
/// and reported, never replaced, and written atomically, `0600` in a `0700` folder. Its names follow the
/// signature templates' rules and compare by their exact text. A template is saved only when it could run:
/// the lock is never left out, and the reminder and invitee pass the form's own checks.
public struct OffboardTemplateStore: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        case nameRequired, nameTooLong
        /// The name is saved already: saving over it needs `replacing: true`, which the screen asks first.
        case exists(String)
        /// No template has that name.
        case notFound(String)
        /// The template couldn't run as it stands (`Offboarding.Template.problem`).
        case invalid(String)
        /// The file couldn't be read, moved aside or saved, in the signature store's words.
        case file(SignatureStore.Problem)

        public var message: String {
            switch self {
            case .nameRequired: "Template name is required."
            case .nameTooLong: "Template name must be \(SignatureStore.maxNameLength) characters or fewer."
            case .exists(let name): "There's already a template named “\(name)”."
            case .notFound(let name): "There's no template named “\(name)”."
            case .invalid(let problem): problem
            case .file(let problem): problem.message
            }
        }
    }

    public static let fileName = "offboarding-templates.json"
    public static let format = 2

    public let root: URL
    /// Where opening moved an unreadable file, for the screen to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// The template the form opens on, when there is one.
    public private(set) var defaultName: String?
    /// Name and template, in `names` order.
    private var saved: [(name: String, template: Offboarding.Template)]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The templates saved in `root`, or the starters when there's no file yet. A file that isn't this format's
    /// templates (corrupt, another format, a template that couldn't run, a link, too large) is moved aside first
    /// and named in `quarantined`. Throws, opening nothing, when the file can't be read or moved aside.
    public init(root: URL, now: Date = Date()) throws(Problem) {
        self.root = root
        let loaded: (value: (Contents)?, quarantined: URL?)
        do { loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.contents(in:)) } catch {
            throw .file(error)
        }
        let contents = loaded.value ?? Contents(saved: Self.sorted(Offboarding.starterTemplates), defaultName: Offboarding.starterDefault)
        saved = contents.saved
        defaultName = contents.defaultName
        quarantined = loaded.quarantined
    }

    /// The names in code-point order, as the signature templates' are.
    public var names: [String] { saved.map(\.name) }

    public func template(_ name: String) -> Offboarding.Template? {
        saved.first { $0.name.utf8.elementsEqual(name.utf8) }?.template
    }

    /// Saves `template` under `name` stripped, and returns that name. A name already saved throws `.exists` unless
    /// `replacing`; a template that couldn't run throws `.invalid`.
    @discardableResult
    public mutating func save(_ name: String, _ template: Offboarding.Template, replacing: Bool = false) throws(Problem) -> String {
        let name = try Self.checked(name)
        if let problem = template.problem { throw .invalid(problem) }
        guard replacing || self.template(name) == nil else { throw .exists(name) }
        var changed = saved.filter { !$0.name.utf8.elementsEqual(name.utf8) }
        changed.append((name, template))
        try write(Self.sorted(changed), defaultName: defaultName)
        return name
    }

    /// Removes `name`, and the default with it when it was the default; a name not saved changes nothing.
    public mutating func delete(_ name: String) throws(Problem) {
        guard template(name) != nil else { return }
        let isDefault = defaultName.map { $0.utf8.elementsEqual(name.utf8) } ?? false
        try write(saved.filter { !$0.name.utf8.elementsEqual(name.utf8) }, defaultName: isDefault ? nil : defaultName)
    }

    /// The template the form opens on; nil for none.
    public mutating func setDefault(_ name: String?) throws(Problem) {
        if let name, template(name) == nil { throw .notFound(name) }
        try write(saved, defaultName: name)
    }

    // MARK: rules

    private static func checked(_ name: String) throws(Problem) -> String {
        do { return try SignatureStore.checked(name) } catch {
            throw error == .nameTooLong ? .nameTooLong : .nameRequired
        }
    }

    private static func sorted(_ saved: [(name: String, template: Offboarding.Template)])
        -> [(name: String, template: Offboarding.Template)]
    {
        saved.sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) }
    }

    // MARK: the file

    struct Contents {
        var saved: [(name: String, template: Offboarding.Template)]
        var defaultName: String?
    }

    /// The templates in this format's file, or nil for anything else: every template must be one the form could
    /// run, under a name the store would save, and the default must name one of them.
    static func contents(in bytes: [UInt8]) -> Contents? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text),
              let version = file["version"]?.int, version == 1 || version == format, let templates = file["templates"]?.object
        else { return nil }
        var saved: [(name: String, template: Offboarding.Template)] = []
        for (name, value) in templates {
            guard (try? checked(name))?.utf8.elementsEqual(name.utf8) == true, let template = template(value, version: version),
                  template.problem == nil
            else { return nil }
            saved.append((name, template))
        }
        let defaultName: String?
        switch file["default"] {
        case nil, .null?: defaultName = nil
        case .string(let name)?:
            guard saved.contains(where: { $0.name.utf8.elementsEqual(name.utf8) }) else { return nil }
            defaultName = name
        default: return nil
        }
        return Contents(saved: sorted(saved), defaultName: defaultName)
    }

    /// One template as `version` writes it: exactly its keys, each step once.
    private static func template(_ value: JSONValue, version: Int) -> Offboarding.Template? {
        guard let object = value.object, object.count == (version == 1 ? 5 : 6), let leftOut = steps(object["leave_out"]),
              let added = version == 1 ? [] : steps(object["add"]),
              let subject = object["subject"]?.string, let message = object["message"]?.string,
              let days = object["days"]?.int, let invitee = object["invitee"]?.string
        else { return nil }
        return Offboarding.Template(leftOut: leftOut, added: added, subject: subject, message: message, days: days, invitee: invitee)
    }

    /// A list of step keys, each known and once.
    private static func steps(_ value: JSONValue?) -> Set<Offboarding.Step>? {
        guard let keys = value?.array else { return nil }
        var steps: Set<Offboarding.Step> = []
        for key in keys {
            guard let raw = key.string, let step = Offboarding.Step(rawValue: raw), !steps.contains(step) else { return nil }
            steps.insert(step)
        }
        return steps
    }

    /// Writes the whole file, then takes it as the store's: a failed write changes nothing.
    private mutating func write(_ changed: [(name: String, template: Offboarding.Template)], defaultName: String?) throws(Problem) {
        var templates = JSONObject()
        for (name, template) in changed {
            templates[name] = .object([
                // In run order, so the file reads as the routine does.
                "leave_out": .array(Offboarding.Step.allCases.filter(template.leftOut.contains).map { .string($0.rawValue) }),
                "add": .array(Offboarding.Step.allCases.filter(template.added.contains).map { .string($0.rawValue) }),
                "subject": .string(template.subject), "message": .string(template.message),
                "days": .number(String(template.days)), "invitee": .string(template.invitee),
            ])
        }
        let file = JSONValue.object(["version": .number(String(Self.format)), "default": defaultName.map(JSONValue.string) ?? .null,
                                     "templates": .object(templates)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root,
                                         interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw .file(problem)
        } catch {
            throw .file(.notSaved(EIO))
        }
        saved = changed
        self.defaultName = defaultName
    }
}
