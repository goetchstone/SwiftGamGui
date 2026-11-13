import Foundation
import GamEngine

/// Saved column maps, by name (GamGUI's `core/roster_maps.py`, plan 2026-11-11 C5.3): a school's SIS exports the same
/// spreadsheet every term, so its map is chosen once.
///
/// `roster-maps.json` in the folder it's given (the app's folder, beside the offboarding templates), holding
/// `{"version": 1, "maps": {name: {"class_id": column, …, "teacher_words": [word], "student_words": [word]}}}`, GamGUI's
/// format. A map holds column names and role words only, never a row of the spreadsheet: no student data reaches this
/// file. It is handled as the offboarding templates' file is (`SignatureStore.load` and `writeFile`): read by descriptor,
/// one this format can't read moved aside whole and reported, never saved over, and written atomically, `0600` in a
/// `0700` folder. Names follow GamGUI's rules: at most 60 characters, printable, at most 50 maps, and saving under a name
/// kept already in another case replaces it.
public struct RosterMapStore: Sendable {
    public static let fileName = "roster-maps.json"
    public static let format = 1
    public static let nameCap = 60
    public static let mapsCap = 50

    public enum Problem: Error, Equatable, Sendable {
        /// A name that can't be kept, or a 51st map, in GamGUI's words.
        case refused(String)
        /// The file couldn't be read, moved aside or saved, in the signature store's words.
        case file(SignatureStore.Problem)

        public var message: String {
            switch self {
            case .refused(let words): words
            case .file(.unreadable(let code)): "Couldn't read the saved maps: \(SignatureStore.Problem.reason(code))."
            case .file(.notMovedAside(let code)):
                "The saved maps can't be read, and couldn't be moved aside to keep them: \(SignatureStore.Problem.reason(code))."
            case .file(.notSaved(let code)): "Couldn't save the map: \(SignatureStore.Problem.reason(code)). Nothing was changed."
            case .file(.tooLarge): "The saved maps would pass \(SignatureStore.sizeCap >> 20) MB. Delete some before saving more."
            case .file(let problem): problem.message
            }
        }
    }

    public let root: URL
    /// Where opening moved an unreadable file, for the map step to say so; nil when nothing was moved.
    public private(set) var quarantined: URL?
    /// Name and map, in `names` order.
    private var saved: [(name: String, map: RosterColumnMap)]
    /// Tests only: called with the new file when half a save is written; a throw is a failed write.
    var interrupt: (@Sendable (URL) throws -> Void)?

    /// The maps saved in `root`, or none when there's no file yet. A file that isn't this format's maps is moved aside
    /// first and named in `quarantined`. Throws, opening nothing, when the file can't be read or moved aside.
    public init(root: URL, now: Date = Date()) throws(Problem) {
        self.root = root
        let loaded: (value: [(name: String, map: RosterColumnMap)]?, quarantined: URL?)
        do { loaded = try SignatureStore.load(Self.fileName, from: root, now: now, parse: Self.maps(in:)) } catch {
            throw .file(error)
        }
        saved = Self.sorted(loaded.value ?? [])
        quarantined = loaded.quarantined
    }

    /// The names, ignoring case (`sorted(key=str.lower)`, a stable sort).
    public var names: [String] { saved.map(\.name) }

    /// The map saved under `name` (stripped), by its exact text.
    public func map(_ name: String) -> RosterColumnMap? {
        let name = PythonText.strip(name)
        return saved.first { $0.name.utf8.elementsEqual(name.utf8) }?.map
    }

    /// Saves `map` under `name` stripped, and returns that name. A name kept already in any case is replaced; a name that
    /// can't be kept, or a 51st map, throws `.refused` with GamGUI's words.
    @discardableResult
    public mutating func save(_ name: String, _ map: RosterColumnMap) throws(Problem) -> String {
        let name = PythonText.strip(name)
        if let problem = Self.nameProblem(name) { throw .refused(problem) }
        let lowered = PythonText.lower(name)
        let same = saved.filter { PythonText.lower($0.name).utf8.elementsEqual(lowered.utf8) }
        if same.isEmpty, saved.count >= Self.mapsCap {
            throw .refused("There are \(Self.mapsCap) saved maps already. Delete one you no longer use first.")
        }
        var changed = saved.filter { !PythonText.lower($0.name).utf8.elementsEqual(lowered.utf8) }
        changed.append((name, RosterColumnMap(json: .object(map.json))))      // stored as it will read back
        try write(Self.sorted(changed))
        return name
    }

    /// Removes the map saved under `name` (stripped); a name not saved changes nothing.
    public mutating func delete(_ name: String) throws(Problem) {
        let name = PythonText.strip(name)
        guard map(name) != nil else { return }
        try write(saved.filter { !$0.name.utf8.elementsEqual(name.utf8) })
    }

    // MARK: rules

    /// GamGUI's `_name_problem`, for a name already stripped: why it can't be kept, or nil.
    public static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Give the map a name." }
        if name.unicodeScalars.count > nameCap { return "A map's name is at most \(nameCap) characters." }
        if !PythonText.strip(name).utf8.elementsEqual(name.utf8) || !name.unicodeScalars.allSatisfy(isPrintable) {
            return "A map's name can't hold a control or invisible character."
        }
        return nil
    }

    /// Python's `str.isprintable()` for one character: not a control, format, surrogate, private-use or unassigned
    /// character (in Python's Unicode version), nor a separator other than the ASCII space.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        guard PythonText.knownToPython(scalar) else { return false }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    private static func sorted(_ saved: [(name: String, map: RosterColumnMap)]) -> [(name: String, map: RosterColumnMap)] {
        // Stable, by the lowercased name's code points, as Python's `sorted(key=str.lower)`.
        saved.enumerated().sorted { a, b in
            let (x, y) = (PythonText.lower(a.element.name), PythonText.lower(b.element.name))
            if x.unicodeScalars.elementsEqual(y.unicodeScalars) { return a.offset < b.offset }
            return x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars)
        }.map(\.element)
    }

    // MARK: the file

    /// The maps in this format's file, or nil for anything else: the version, a `maps` object of at most `mapsCap`, each
    /// under a name the store would keep and each an object (whose fields are read as `RosterColumnMap(json:)` reads them,
    /// never refusing).
    static func maps(in bytes: [UInt8]) -> [(name: String, map: RosterColumnMap)]? {
        guard let text = String(validating: bytes, as: UTF8.self), let file = JSONValue.parse(text), file.object != nil,
              file["version"]?.int == format, let maps = file["maps"]?.object, maps.count <= mapsCap
        else { return nil }
        var out: [(name: String, map: RosterColumnMap)] = []
        for (name, value) in maps {
            guard nameProblem(name) == nil, value.object != nil else { return nil }
            out.append((name, RosterColumnMap(json: value)))
        }
        return out
    }

    /// Writes the whole file, then takes it as the store's: a failed write changes nothing.
    private mutating func write(_ changed: [(name: String, map: RosterColumnMap)]) throws(Problem) {
        var maps = JSONObject()
        for (name, map) in changed { maps[name] = .object(map.json) }
        let file = JSONValue.object(["version": .number(String(Self.format)), "maps": .object(maps)])
        do {
            try SignatureStore.writeFile(Array((JSONValue.dumps(file) + "\n").utf8), named: Self.fileName, in: root,
                                         interrupt: interrupt)
        } catch let problem as SignatureStore.Problem {
            throw .file(problem)
        } catch {
            throw .file(.notSaved(EIO))
        }
        saved = changed
    }
}
