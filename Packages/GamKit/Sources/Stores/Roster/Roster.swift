import GamEngine

/// A student information system's roster export read into one snapshot (plan 2026-11-11, C2.1, C2.3 and C5.1; GamGUI's
/// `core/roster.py` at 07c505d, held to `Tests/Fixtures/roster.json`).
///
/// The snapshot is one model every reader fills (schools, terms, courses, classes, people, enrolments), so nothing after
/// it knows which SIS or format it came from. `read` takes an upload (one ZIP, or loose CSV files), tells which export it
/// is by its file names, and reads OneRoster 1.1 and 1.2 CSV. Clever's CSV and a spreadsheet mapped by its columns are
/// recognised and said to come next (`Refusal.notYet`, `.needsMap`): their readers are the next slice, and plug in where
/// those are thrown.
///
/// An upload is hostile until read (SECURITY.md): nothing is extracted and no name inside it is ever a path; every size
/// is counted, never trusted; text is strict UTF-8; a package-level mistake refuses the whole package with its fix, in
/// GamGUI's words (`PackageError`), and row-level problems are kept as issues for the SIS team. A file the reader doesn't
/// use is named, never unpacked, and a row is built from the columns used alone, so the passwords some exports carry
/// are never read. Reading holds no state and writes nothing: `RosterStore` keeps a snapshot.
public enum Roster {
    // MARK: the export's files

    /// OneRoster CSV, as 1EdTech names its files. A rostering package needs the first six (and the manifest); 1.2 also
    /// needs roles.csv (its users.csv has no role: 1.2 binding, Appendix A).
    static let required = ["orgs.csv", "academicSessions.csv", "courses.csv", "classes.csv", "users.csv", "enrollments.csv"]
    static let roles = "roles.csv"
    static let optional = ["demographics.csv", "lineItems.csv", "categories.csv", "results.csv", "resources.csv",
                           "classResources.csv", "courseResources.csv", "userResources.csv", "userProfiles.csv",
                           "scoreScales.csv", "lineItemScoreScales.csv", "resultScoreScales.csv",
                           "lineItemLearningObjectiveIds.csv", "resultLearningObjectiveIds.csv"]
    static let manifest = "manifest.csv"

    /// The columns each OneRoster 1.1 file must have for this reader; others are allowed and ignored.
    static let columns: [String: [String]] = [
        "orgs.csv": ["sourcedId", "status", "name", "type"],
        "academicSessions.csv": ["sourcedId", "status", "title", "type", "startDate", "endDate"],
        "courses.csv": ["sourcedId", "status", "title", "orgSourcedId"],
        "classes.csv": ["sourcedId", "status", "title", "courseSourcedId", "schoolSourcedId", "termSourcedIds"],
        "users.csv": ["sourcedId", "status", "role", "email", "givenName", "familyName"],
        "enrollments.csv": ["sourcedId", "status", "classSourcedId", "userSourcedId", "role"],
    ]
    /// The columns each file's rows are read for: a row is built from these alone.
    static let used: [String: [String]] = [
        "orgs.csv": ["sourcedId", "status", "name"],
        "academicSessions.csv": ["sourcedId", "status", "title", "type", "startDate", "endDate"],
        "courses.csv": ["sourcedId", "status", "title", "courseCode", "orgSourcedId"],
        "classes.csv": ["sourcedId", "status", "title", "courseSourcedId", "schoolSourcedId", "termSourcedIds", "classCode",
                        "location"],
        "users.csv": ["sourcedId", "status", "role", "email", "givenName", "familyName"],
        "enrollments.csv": ["sourcedId", "status", "classSourcedId", "userSourcedId", "role", "primary"],
    ]
    /// OneRoster 1.2: users.csv lost `role` to roles.csv; every other file read keeps its 1.1 columns.
    static let columns12 = columns.merging(["users.csv": ["sourcedId", "status", "email", "givenName", "familyName"],
                                            roles: ["sourcedId", "status", "userSourcedId", "roleType", "role"]]) { $1 }
    static let used12 = used.merging(["users.csv": ["sourcedId", "status", "email", "givenName", "familyName"],
                                      roles: ["sourcedId", "status", "userSourcedId", "roleType", "role"]]) { $1 }
    /// The people a class's roster holds; others are counted, not rostered.
    static let rosteredRoles = ["teacher", "student"]

    /// An export's files: the ones it may hold, by lowercased name, and the ones no reader uses (named and checked,
    /// never unpacked: each could hold its whole cap, and some hold passwords).
    struct Layout {
        /// "OneRoster", in "isn't a OneRoster file".
        let label: String
        let known: [ExactKey: String]
        let skip: Set<String>

        func canonical(_ base: String) -> String? { known[ExactKey(PythonText.lower(base))] }
    }

    static let oneRoster = Layout(
        label: "OneRoster",
        known: Dictionary(uniqueKeysWithValues: ([manifest] + required + [roles] + optional).map { (ExactKey(PythonText.lower($0)), $0) }),
        skip: Set(optional))

    static let or11 = "That isn't OneRoster 1.1's layout: export OneRoster 1.1 CSV."
    static let or12 = "That isn't OneRoster 1.2's layout: export OneRoster 1.2 CSV."

    // MARK: what the operator picked

    /// One picked file: its name as picked (only ever matched, never a path) and its bytes.
    public struct Upload: Sendable {
        public let name: String
        public let bytes: [UInt8]

        public init(name: String, bytes: [UInt8]) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// Why an upload isn't read.
    public enum Refusal: Error, Equatable, Sendable {
        /// GamGUI's `PackageError`: what's wrong and how to fix it, in its words.
        case package(String)
        /// One CSV that isn't a known export: a spreadsheet the operator maps by its columns (GamGUI's `NeedsMap`).
        case needsMap(name: String)
        /// An export this app recognises and reads in its next version.
        case notYet(Format)

        public enum Format: String, Sendable { case clever }

        public var message: String {
            switch self {
            case .package(let words): words
            case .needsMap(let name):
                "“\(String(name.unicodeScalars.prefix(80)))” is one spreadsheet, which GAM GUI reads with a map of its columns "
                    + "in its next version. For now, export OneRoster 1.1 or 1.2 CSV: its ZIP, or every CSV file in it."
            case .notYet(.clever):
                "That's Clever's export, which GAM GUI reads in its next version. For now, export OneRoster 1.1 or 1.2 CSV: its "
                    + "ZIP, or every CSV file in it."
            }
        }
    }

    // MARK: reading

    /// What the operator picked (one ZIP, or a folder's CSV files) as a checked snapshot: GamGUI's `read_upload`.
    public static func read(_ uploads: [Upload], caps: RosterCaps = .standard) throws(Refusal) -> RosterSnapshot {
        do {
            return try readUpload(uploads, caps: caps)
        } catch let refusal as Refusal {
            throw refusal
        } catch let error as PackageError {
            throw .package(error.message)
        } catch {
            throw .package("The export couldn't be read. Choose it again.")
        }
    }

    private static let zipMagic: [[UInt8]] = [Array("PK\u{03}\u{04}".utf8), Array("PK\u{05}\u{06}".utf8)]

    private static func readUpload(_ uploads: [Upload], caps: RosterCaps) throws -> RosterSnapshot {
        if uploads.isEmpty { throw PackageError("Choose the roster export: its ZIP, or the CSV files in it.") }
        if uploads.reduce(0, { $0 + $1.bytes.count }) > caps.upload {
            throw PackageError("That's more than \(caps.upload >> 20) MB, more than a roster export should be.")
        }
        let zips = uploads.map { upload in
            zipMagic.contains(Array(upload.bytes.prefix(4))) || PythonText.lower(upload.name).utf8.reversed().starts(with: "piz.".utf8)
        }
        var archive: RosterZip?
        let kind: String
        if uploads.count == 1, zips[0] {
            let opened = try RosterZip.open(uploads[0].bytes, caps: caps)
            kind = try detect(zipNames(opened, caps: caps))
            archive = opened
        } else if zips.contains(true) {
            throw PackageError("Choose one ZIP on its own, or the CSV files without it.")
        } else {
            let names = uploads.map { base($0.name) }.filter { !ignored($0) }
            if names.count == 1, PythonText.lower(names[0]).utf8.reversed().starts(with: "vsc.".utf8) {
                // One CSV is never a whole OneRoster or Clever export, whatever it's named: a spreadsheet to map.
                throw Refusal.needsMap(name: names[0])
            }
            kind = try detect(names)
        }
        if kind == "clever" { throw Refusal.notYet(.clever) }
        if kind.isEmpty {
            throw PackageError("This isn't an export GamGUI knows. Choose a OneRoster (1.1 or 1.2) or Clever export: its ZIP, "
                               + "or every CSV file in it. Any other SIS: export one spreadsheet (a CSV) with a row per person "
                               + "in a class, and map its columns.")
        }
        var files: [String: [UInt8]]
        if let archive { files = try filesFromZip(archive, caps: caps) } else { files = try filesFromCSVs(uploads, caps: caps) }
        let manifest = try checkPackage(files, caps: caps)
        return try readOneRoster(&files, version: oneRosterVersion(manifest), caps: caps)
    }

    // MARK: the files out of an upload

    /// macOS's additions to a ZIP it makes: never ours, never read.
    static func ignored(_ name: String) -> Bool {
        let base = Array(name.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).last ?? [])
        let bytes = Array(name.utf8)
        return bytes.starts(with: "__MACOSX/".utf8) || bytes.contains("/__MACOSX/".utf8)
            || base.elementsEqual(".DS_Store".utf8) || base.starts(with: "._".utf8)
    }

    /// A picked file's base name: after its last slash or backslash.
    static func base(_ raw: String) -> String {
        let slashed = PythonText.string(raw.unicodeScalars.map { $0 == "\\" ? "/" : $0 })
        return slashed.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).last.map(PythonText.string) ?? ""
    }

    /// GamGUI's `_member_name`: a member's file name, at the root or in one enclosing folder (Finder's Compress makes
    /// one). Refuses anything that is or could become a path out, and a name that held a NUL.
    static func memberName(_ name: String, hadNUL: Bool = false) throws -> String {
        let plain = PackageError("The ZIP holds a file named “\(PythonText.string(name.unicodeScalars.prefix(80)))”, which isn't "
                                 + "a plain file name. Export the roster again.")
        let parts = name.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map(PythonText.string)
        if name.isEmpty || hadNUL || name.unicodeScalars.contains("\0") || name.unicodeScalars.contains("\\")
            || name.utf8.first == UInt8(ascii: "/") || parts[0].unicodeScalars.contains(":") {
            throw plain
        }
        if parts.dropLast().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) || [".", ".."].contains(parts.last!) {
            throw plain
        }
        if parts.count > 2 {
            throw PackageError("The CSV files are inside folders within folders. Put them at the top of the ZIP, or in one "
                               + "folder, and try again.")
        }
        return parts.last!
    }

    static func tooManyEntries(_ count: Int) -> PackageError {
        PackageError("The ZIP holds \(count) entries; a roster export holds a dozen or so. Check it's the right file.")
    }

    /// GamGUI's `zip_names`: the base names of a ZIP's files, lowercased, from its directory alone (nothing unpacked).
    static func zipNames(_ archive: RosterZip, caps: RosterCaps) throws -> [String] {
        if archive.entries.count > caps.members { throw tooManyEntries(archive.entries.count) }
        return try archive.entries.filter { !ignored($0.name) && !$0.isFolder }
            .map { PythonText.lower(try memberName($0.name, hadNUL: $0.hadNUL)) }
    }

    /// GamGUI's `files_from_zip`: the roster files in a ZIP, by their name in `layout`. An unknown file is refused, never
    /// ignored; the files no reader uses are name-checked but never unpacked.
    static func filesFromZip(_ archive: RosterZip, layout: Layout = oneRoster, caps: RosterCaps) throws -> [String: [UInt8]] {
        var files: [String: [UInt8]] = [:]
        var skipped: Set<String> = [], folders: Set<ExactKey> = []
        var total = 0
        if archive.entries.count > caps.members { throw tooManyEntries(archive.entries.count) }
        for entry in archive.entries {
            let name = entry.name
            if ignored(name) { continue }
            if entry.isFolder {           // only the one enclosing folder is allowed (checked below)
                let folder = PythonText.rstrip(name, of: [0x2F])
                _ = try memberName(folder + "/x", hadNUL: entry.hadNUL)
                folders.insert(ExactKey(folder))
                continue
            }
            let mode = (entry.externalAttributes >> 16) & 0o170000
            if entry.createSystem == 3, mode != 0, mode != 0o100000 {
                throw PackageError("“\(PythonText.string(name.unicodeScalars.prefix(80)))” in the ZIP is a link or a special file, "
                                   + "not a file. Export the roster again.")
            }
            if entry.flags & 0x1 != 0 { throw PackageError("The ZIP is password-protected. Export it without a password.") }
            let base = try memberName(name, hadNUL: entry.hadNUL)
            if name.unicodeScalars.contains("/") {
                folders.insert(ExactKey(PythonText.string(name.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)[0])))
            }
            guard let canonical = layout.canonical(base) else {
                throw PackageError("The ZIP holds “\(PythonText.string(base.unicodeScalars.prefix(80)))”, which isn't a "
                                   + "\(layout.label) file. Choose the \(layout.label) export itself.")
            }
            if files[canonical] != nil || skipped.contains(canonical) {
                throw PackageError("The ZIP holds \(canonical) twice. Export the roster again.")
            }
            if layout.skip.contains(canonical) {      // a file no reader uses: named, never unpacked
                skipped.insert(canonical)
                continue
            }
            let bomb = PackageError("\(canonical) unpacks to far more than its size in the ZIP. That isn't a normal export.")
            if entry.compressedSize != 0, Double(entry.size) / Double(entry.compressedSize) > Double(caps.ratio) { throw bomb }
            let body = try archive.unpack(
                entry, cap: caps.member,
                capped: PackageError("\(canonical) is larger than \(caps.member >> 20) MB once unpacked, more than any roster "
                                     + "file should be."),
                broken: PackageError("\(canonical) couldn't be unpacked from the ZIP. Export the roster again."))
            if entry.compressedSize != 0, Double(body.count) / Double(max(entry.compressedSize, 1)) > Double(caps.ratio) {
                throw bomb
            }
            total += body.count
            if total > caps.total {
                throw PackageError("The roster is larger than \(caps.total >> 20) MB unpacked, more than any roster should be.")
            }
            files[canonical] = body
        }
        if folders.count > 1 {
            throw PackageError("The CSV files are in more than one folder. Put them at the top of the ZIP, or in one folder.")
        }
        return files
    }

    /// GamGUI's `files_from_csvs`: the roster files picked one by one (a folder's CSVs), by their name in `layout`.
    static func filesFromCSVs(_ uploads: [Upload], layout: Layout = oneRoster, caps: RosterCaps) throws -> [String: [UInt8]] {
        var files: [String: [UInt8]] = [:]
        var total = 0
        for upload in uploads {
            let base = base(upload.name)
            if ignored(base) { continue }
            guard let canonical = layout.canonical(base) else {
                throw PackageError("“\(PythonText.string(base.unicodeScalars.prefix(80)))” isn't a \(layout.label) file. Pick "
                                   + "the CSV files from the export, or its ZIP.")
            }
            if files[canonical] != nil { throw PackageError("\(canonical) was picked twice.") }
            if layout.skip.contains(canonical) { continue }       // read already, but never parsed or kept
            total += upload.bytes.count
            if upload.bytes.count > caps.member || total > caps.total {
                throw PackageError("The files are larger than any roster should be.")
            }
            files[canonical] = upload.bytes
        }
        return files
    }

    static let onlyOneRoster = Set(([manifest] + required + [roles]).map { $0.lowercased() }).subtracting(["enrollments.csv"])
    static let cleverNames: Set<String> = ["schools.csv", "students.csv", "teachers.csv", "sections.csv"]

    /// GamGUI's `detect`: which export a set of file names is, "oneroster", "clever" or "" (unknown), by name alone.
    /// enrollments.csv is in both and decides nothing; both kinds at once is neither.
    static func detect(_ names: [String]) throws -> String {
        let lowered = Set(names.map { ExactKey(PythonText.lower($0)) })
        let oneroster = !lowered.isDisjoint(with: onlyOneRoster.map(ExactKey.init))
        let clever = !lowered.isDisjoint(with: cleverNames.map(ExactKey.init))
        if oneroster && clever {
            throw PackageError("These files mix a OneRoster export with a Clever one. Choose one export.")
        }
        return oneroster ? "oneroster" : clever ? "clever" : ""
    }

    // MARK: the package

    /// The manifest's properties (GamGUI's `_manifest`): its first 256 records, read through the same bounds as the rows.
    static func manifestProperties(_ files: [String: [UInt8]], caps: RosterCaps) throws -> [String: String] {
        guard let body = files[manifest] else {
            throw PackageError("There's no manifest.csv, so this isn't a OneRoster export. Export OneRoster 1.1 or 1.2 CSV "
                               + "from your SIS.")
        }
        if body.count > caps.manifest {
            throw PackageError("manifest.csv is far larger than a OneRoster manifest. Export the roster again.")
        }
        var reader = RosterCSV(RosterLines(name: manifest, bytes: body, caps: caps))
        var rows: [[String]] = []
        do {
            while rows.count < 256, let row = try reader.next() { rows.append(row.map(\.text)) }
        } catch let error as CSVError {
            throw PackageError("manifest.csv isn't readable CSV (\(error.message)).")
        }
        guard let first = rows.first, first.prefix(2).map({ PythonText.strip($0) }) == ["propertyName", "value"] else {
            throw PackageError("manifest.csv isn't a OneRoster manifest. Export OneRoster 1.1 or 1.2 CSV from your SIS.")
        }
        var properties: [String: String] = [:]
        for row in rows.dropFirst() where row.count >= 2 { properties[PythonText.strip(row[0])] = PythonText.strip(row[1]) }
        return properties
    }

    /// "1.1" or "1.2" (a SIS writing its revision, "1.2.1", is the same layout).
    static func oneRosterVersion(_ manifest: [String: String]) throws -> String {
        let version = manifest["oneroster.version"] ?? ""
        if version == "1.1" { return "1.1" }
        if version == "1.2" || version.utf8.starts(with: "1.2.".utf8) { return "1.2" }
        let shown = PythonText.string(version.unicodeScalars.prefix(20))
        throw PackageError("The manifest says OneRoster version “\(shown.isEmpty ? "none" : shown)”. Export OneRoster 1.1 or 1.2 CSV.")
    }

    /// GamGUI's `check_package`: refuse a package this reader can't take, with its fix.
    static func checkPackage(_ files: [String: [UInt8]], caps: RosterCaps) throws -> [String: String] {
        let manifest = try manifestProperties(files, caps: caps)
        let needed = required + (try oneRosterVersion(manifest) == "1.2" ? [roles] : [])
        for name in needed {
            let mode = PythonText.lower(manifest["file.\(name.dropLast(4))"] ?? "")
            if mode == "delta" {
                throw PackageError("This is a changes-only (delta) export: \(name) holds changes, not the whole roster. Export a "
                                   + "full (bulk) export.")
            }
            if mode == "absent" || files[name] == nil {
                throw PackageError("The export has no \(name), which a roster needs. Include it in the export (as bulk).")
            }
        }
        return manifest
    }

    // MARK: the rows into a snapshot

    /// The row's sourcedId, or nil when the row is left out (marked to be deleted, or no ID).
    private static func live(_ snap: inout RosterSnapshot.Builder, _ name: String, _ line: Int, _ row: [String: String]) -> String? {
        if lower(row["status"] ?? "") == "tobedeleted" {
            snap.issue("skipped", name, line, row["sourcedId"] ?? "")
            return nil
        }
        let id = row["sourcedId"] ?? ""
        if id.isEmpty {
            snap.issue("no_id", name, line)
            return nil
        }
        return id
    }

    /// GamGUI's `_one_address`: one plain address, printable ASCII only. A control or invisible character is refused,
    /// never dropped (dropping one could make a different, valid-looking address).
    static func isOneAddress(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard let at = scalars.firstIndex(of: "@") else { return false }
        let local = scalars[..<at], host = scalars[(at + 1)...]
        return !local.isEmpty && host.contains(".") && !host.contains("@")
            && scalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F && !"<>,;:\"'".unicodeScalars.contains($0) }
    }

    /// OneRoster 1.2's roles.csv: each user's roster roles (teacher, student), as (primary, secondary).
    private static func roles12(_ snap: inout RosterSnapshot.Builder, _ body: [UInt8], caps: RosterCaps) throws
        -> [ExactKey: (primary: Set<String>, secondary: Set<String>)] {
        var out: [ExactKey: (primary: Set<String>, secondary: Set<String>)] = [:]
        try rows(roles, body, required: columns12[roles]!, used: used12[roles]!, layout: or12, caps: caps) { line, row in
            guard live(&snap, roles, line, row) != nil else { return }
            let role = lower(row["role"] ?? "")
            guard rosteredRoles.contains(role) else { return }
            let user = ExactKey(row["userSourcedId"] ?? "")
            var found = out[user] ?? ([], [])
            if lower(row["roleType"] ?? "") == "primary" { found.primary.insert(role) } else { found.secondary.insert(role) }
            out[user] = found
        }
        return out
    }

    /// The roster role a 1.2 user is counted under: their primary role's, teacher first, else a secondary one's.
    private static func role12(_ roles: (primary: Set<String>, secondary: Set<String>)?) -> String {
        for found in [roles?.primary ?? [], roles?.secondary ?? []] {
            for role in rosteredRoles where found.contains(role) { return role }
        }
        return ""
    }

    /// GamGUI's `read_oneroster`: a checked OneRoster 1.1 or 1.2 package as a snapshot. Each file is taken out of `files`
    /// as it's read. 1.2 differs only in where a person's role is: roles.csv, not users.csv.
    static func readOneRoster(_ files: inout [String: [UInt8]], version: String, caps: RosterCaps) throws -> RosterSnapshot {
        var snap = RosterSnapshot.Builder(source: "OneRoster \(version) CSV", sample: caps.issueSample)
        let is12 = version == "1.2"
        let (columns, used, layout) = is12 ? (columns12, used12, or12) : (Self.columns, Self.used, or11)
        func each(_ name: String, _ body: (Int, [String: String]) throws -> Void) throws {
            let bytes = files.removeValue(forKey: name) ?? []
            try rows(name, bytes, required: columns[name]!, used: used[name]!, layout: layout, caps: caps, body)
        }
        try each("orgs.csv") { line, row in
            guard let id = live(&snap, "orgs.csv", line, row) else { return }
            if !snap.add(school: .init(id: id, name: row["name"] ?? "")) { snap.issue("duplicate_id", "orgs.csv", line, id) }
        }
        try each("academicSessions.csv") { line, row in
            guard let id = live(&snap, "academicSessions.csv", line, row) else { return }
            let term = RosterSnapshot.Term(id: id, title: row["title"] ?? "", kind: lower(row["type"] ?? ""),
                                           start: row["startDate"] ?? "", end: row["endDate"] ?? "")
            if !snap.add(term: term) { snap.issue("duplicate_id", "academicSessions.csv", line, id) }
        }
        try each("courses.csv") { line, row in
            guard let id = live(&snap, "courses.csv", line, row) else { return }
            if snap.hasCourse(id) {
                snap.issue("duplicate_id", "courses.csv", line, id)
                return
            }
            if (row["title"] ?? "").isEmpty { snap.issue("no_title", "courses.csv", line, id) }
            _ = snap.add(course: .init(id: id, title: row["title"] ?? "", code: row["courseCode"] ?? "",
                                       schoolID: row["orgSourcedId"] ?? ""))
        }
        try each("classes.csv") { line, row in
            guard let id = live(&snap, "classes.csv", line, row) else { return }
            if snap.hasClass(id) {
                snap.issue("duplicate_id", "classes.csv", line, id)
                return
            }
            let title = row["title"] ?? "", course = row["courseSourcedId"] ?? "", school = row["schoolSourcedId"] ?? ""
            let terms = (row["termSourcedIds"] ?? "").unicodeScalars.split(separator: ",", omittingEmptySubsequences: false)
                .map { PythonText.strip(PythonText.string($0)) }.filter { !$0.isEmpty }
            if title.isEmpty { snap.issue("no_title", "classes.csv", line, id) }
            if !snap.hasCourse(course) { snap.issue("unknown_course", "classes.csv", line, id, course) }
            if !snap.hasSchool(school) { snap.issue("unknown_school", "classes.csv", line, id, school) }
            for term in terms where !snap.hasTerm(term) { snap.issue("unknown_term", "classes.csv", line, id, term) }
            _ = snap.add(class: .init(id: id, title: title, courseID: course, schoolID: school, termIDs: terms,
                                      code: row["classCode"] ?? "", location: row["location"] ?? ""))
        }
        var emails: Set<ExactKey> = []
        var roles: [ExactKey: (primary: Set<String>, secondary: Set<String>)] =
            is12 ? try roles12(&snap, files.removeValue(forKey: Self.roles) ?? [], caps: caps) : [:]
        var allowed: [ExactKey: Set<String>] = [:]      // each person's roster roles: an enrolment must be one of them
        var unrostered: Set<ExactKey> = []              // in users.csv, but no teacher or student role
        files.removeValue(forKey: Self.roles)           // a 1.1 package may carry one: never read
        try each("users.csv") { line, row in
            guard let id = live(&snap, "users.csv", line, row) else { return }
            let key = ExactKey(id)
            let role = is12 ? role12(roles[key]) : lower(row["role"] ?? "")
            guard rosteredRoles.contains(role) else {
                snap.others += 1
                unrostered.insert(key)
                return
            }
            if snap.hasPerson(id) {
                snap.issue("duplicate_id", "users.csv", line, id)
                return
            }
            let given = row["email"] ?? ""
            if given.isEmpty {
                snap.issue("no_email", "users.csv", line, id)
                return
            }
            // Checked as given: lowercasing first turns a Kelvin sign (U+212A) into an ASCII k.
            guard isOneAddress(given) else {
                snap.issue("bad_email", "users.csv", line, id, given)
                return
            }
            let email = given.lowercased()
            guard emails.insert(ExactKey(email)).inserted else {
                snap.issue("duplicate_email", "users.csv", line, id, email)
                return
            }
            _ = snap.add(person: .init(id: id, role: role, email: email, given: row["givenName"] ?? "",
                                       family: row["familyName"] ?? ""))
            allowed[key] = is12 ? roles[key].map { $0.primary.union($0.secondary) } ?? [] : [role]
        }
        roles = [:]
        try each("enrollments.csv") { line, row in
            guard let id = live(&snap, "enrollments.csv", line, row) else { return }
            let role = lower(row["role"] ?? "")
            guard rosteredRoles.contains(role) else { return }
            let klass = row["classSourcedId"] ?? "", person = row["userSourcedId"] ?? ""
            guard snap.hasClass(klass) else {
                snap.issue("unknown_class", "enrollments.csv", line, id, klass)
                return
            }
            if unrostered.contains(ExactKey(person)) {
                let where_ = is12 ? "no teacher or student row in roles.csv" : "users.csv gives another role"
                snap.issue("role_mismatch", "enrollments.csv", line, id, "\(role) in enrollments, \(where_)")
                return
            }
            guard snap.hasPerson(person) else {
                snap.issue("unknown_person", "enrollments.csv", line, id, person)
                return
            }
            let roles = allowed[ExactKey(person)] ?? []
            guard roles.contains(role) else {
                snap.issue("role_mismatch", "enrollments.csv", line, id,
                           "\(role) in enrollments, \(roles.sorted().joined(separator: "/")) in \(is12 ? "roles" : "users")")
                return
            }
            snap.enroll(.init(classID: klass, personID: person, role: role,
                              primary: lower(row["primary"] ?? "") == "true"))
        }
        return snap.snapshot
    }
}

/// GamGUI's caps (#9), as `roster.py` sets them; a test lowers one as GamGUI's tests monkeypatch it.
public struct RosterCaps: Sendable, Equatable {
    /// The bytes picked, a ZIP or the CSVs together.
    public var upload = 200 * 1024 * 1024
    /// One file, decompressed.
    public var member = 256 * 1024 * 1024
    /// Every file, decompressed.
    public var total = 768 * 1024 * 1024
    /// A member's size over its compressed size: past it, a decompression bomb.
    public var ratio = 200
    /// Entries in a ZIP, counting the ones ignored.
    public var members = 64
    /// A ZIP's list of entries, in bytes.
    public var centralDirectory = 64 * 1024
    /// manifest.csv: a real one is under 2 KB.
    public var manifest = 64 * 1024
    /// Columns in a file's header.
    public var columns = 256
    /// One physical line, and one record, in characters.
    public var line = 2 * 1024 * 1024
    /// Rows in one file.
    public var rows = 2_000_000
    /// One field, in characters.
    public var field = 64 * 1024
    /// Rows kept per kind of issue (the Issues CSV); the count is always whole.
    public var issueSample = 1000

    public static let standard = RosterCaps()

    public init() {}
}

/// The upload can't be read as a roster: what's wrong and how to fix it, in GamGUI's words.
struct PackageError: Error, Equatable {
    let message: String

    init(_ message: String) { self.message = message }
}
