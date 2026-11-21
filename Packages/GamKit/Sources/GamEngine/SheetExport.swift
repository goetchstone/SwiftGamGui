import Foundation

/// A read's table exported to a new Google Sheet (plan F4, GamGUI #174's `core/sheet_export.py`): what GAM needs, what it
/// prints, and what that means in words.
///
/// Read from GAM's own source at the pin (7.52.04: `CSVPrintFile.GetTodriveParameters` and `writeCSVfile`'s
/// `writeCSVToDrive`, to the end of the function). GAM starts each call from a fresh gam.cfg, so `todrive_clientaccess` is
/// false and every Drive and Sheets call is made by the SERVICE ACCOUNT acting as the admin (`buildGAPIServiceObject`): the
/// admin token's scopes never matter to an export. While reading the arguments GAM checks the admin exists (a Directory read);
/// the read then runs as it would without `todrive`, and instead of printing its CSV, GAM:
///
/// 1. makes the file in the admin's Drive with `files.create` (the CSV, converted to a Sheet): the delegated Drive scope.
///    Its Drive token refused, it writes `User: <admin>, Drive API v3 Service/App not enabled` to stderr and exits 73
///    (SERVICE_NOT_APPLICABLE_RC), returning before the create: nothing made. `files.create` refused as `forbidden` or
///    `insufficientPermissions` reads `WARNING: Insufficient permissions to perform this task` (67; only the upload prints it,
///    and no later call raises either to that handler): nothing made. `files.create` failing as `fileNotFound`, `unknownError`
///    or `storageQuotaExceeded` reads `Drive Folder: root, Create Failed: <why>` (50: `entityActionFailedWarning` after
///    `Act.Set(Act.CREATE)`, and `Act.Failed()` is `"<action> Failed"`; never another parent, since no `tdparent` is sent):
///    an `unknownError` is Google's HTTP 500 with status UNKNOWN, which GAM's own source doesn't show left nothing behind (its
///    INTERNAL twin is "the file was probably uploaded"), so this line is said as unknown. Google's internal error on the
///    create itself reads `Drive File: <name>, Create Failed: Google reported "…" but the file was probably uploaded, check that
///    it has N rows` (50): unknown.
/// 2. finishes it as a Sheet through the Sheets API (`spreadsheets.get` and `batchUpdate`, naming the tab): the delegated
///    Sheets scope. Refused, the file is ALREADY made, but GAM returns before printing its link: `User: <admin>, Sheets API
///    Service/App not enabled`, exit 73. A Sheets call that fails once the token is had is `todriveCSVErrorExit`:
///    `ERROR: User: <admin>, Drive File ID: <id>, Not Created: <why>` (50), the file made. But `serviceNotAvailable`,
///    `authError` and `domainPolicy` (SHEETS_ACCESS_THROW_REASONS, glgapi.py:290) pass the inner handlers and reach the outer
///    one (`userDriveServiceNotEnabledWarning`), which prints `User: <admin>, Drive Service/App not enabled` (a message naming
///    "Drive apps" or "Active session is invalid") or `User: <admin>, Not Created: <why>` (51), the same lines `files.create`
///    itself prints for those three reasons before anything is made: both are said as unknown.
/// 3. prints `Data uploaded to Drive File:` and the file's `webViewLink` on the next line, on stdout. The exit is 0, or a
///    warning code the read itself set: GAM uploads the table it has all the same (`setSysExitRC` keeps the last code set). A
///    per-account read that couldn't get a token for an account (`handleOAuthTokenError`, a soft error: rc 50, `continue`)
///    still writes its CSV, so a read of an account that doesn't exist uploads a Sheet holding only its headers, prints its
///    link, and exits 50.
///
/// A result too large for a Sheet is uploaded as a plain CSV file after a `WARNING` line on stdout (its link is a
/// drive.google.com one). No rows is still uploaded (`todrive_upload_nodata` defaults true).
///
/// What became of the file is read from the upload's OWN lines (`uploadState`: the link, and the lines above, naming the
/// admin or the file), never from GAM's one-line error summary, which can be a line the read printed about another account
/// (GamGUI failure-log 2026-11-21, "the export's outcome read GAM's summary line"). "Nothing was made" is said only where
/// GAM's source shows no file exists at that point: a line that can come before or after `files.create`, or from the read
/// itself, is unknown (review of F4, 2026-11-21). Deviations from GamGUI's `UPLOAD_LINES`, which have the same gaps: Drive off,
/// Create Failed and Not Created are unknown, Create Failed is GAM's own line only (`Drive Folder: root` at a line's start),
/// and the last line naming another account than GAM's name for the admin is unknown, never skipped for an earlier one.
/// One residue: a read acting through the admin's own Drive can print the upload's Drive-refused line itself; that line
/// stands for the upload only if the upload then stopped with no line at all (a Sheets token refused without a word right
/// after the Drive one worked), which GAM's source allows but nothing here can tell apart.
public enum SheetExport {
    public static let driveScope = "https://www.googleapis.com/auth/drive"
    public static let sheetsScope = "https://www.googleapis.com/auth/spreadsheets"
    /// The two delegated scopes an export needs, with what each does for it, in the order GAM uses them.
    public static let scopes: [(scope: String, purpose: String)] = [
        (driveScope, "Drive: GAM makes the file in the admin's Drive"),
        (sheetsScope, "Sheets: GAM finishes it as a Sheet and prints its link"),
    ]

    /// The words GAM prints before the link (`Msg.DATA_UPLOADED_TO_DRIVE_FILE`).
    public static let uploadedLine = "Data uploaded to Drive File:"

    /// The hosts a Drive file's `webViewLink` is on: a Sheet's docs.google.com/spreadsheets/d/…, a plain CSV's
    /// drive.google.com/file/d/….
    static let linkHosts: Set<String> = ["docs.google.com", "drive.google.com"]

    /// A Drive file's link as Google gives it: https, on docs.google.com or drive.google.com, with no port, no user info and no
    /// control character or space (a browser strips or splits on those). Anything else is shown as text, never as a link,
    /// whatever printed it. Stricter than GamGUI's `is_google_link` where they differ (an empty port, `[`), never looser.
    public static func isGoogleLink(_ url: String) -> Bool {
        let scalars = Array(url.unicodeScalars)
        guard !scalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else { return false }
        let scheme = Array("https://".unicodeScalars)
        guard scalars.count > scheme.count,
              String(String.UnicodeScalarView(scalars[..<scheme.count])).lowercased() == "https://" else { return false }
        let authority = scalars[scheme.count...].prefix { !"/?#".unicodeScalars.contains($0) }
        guard !authority.contains(where: { "@:[]\\".unicodeScalars.contains($0) }) else { return false }
        return linkHosts.contains(String(String.UnicodeScalarView(authority)).lowercased())
    }

    /// The link GAM printed for the file it made (the line after `Data uploaded to Drive File:`), or "" when it printed none or
    /// something that isn't a Google file link. GamGUI's `^\s*Data uploaded to Drive File:\s*\n\s*(\S+)\s*$`, line by line.
    public static func sheetURL(_ stdout: String) -> String {
        let text = Array(stdout.unicodeScalars), header = Array(uploadedLine.unicodeScalars), n = text.count
        func space(_ index: Int) -> Bool { PythonText.whitespace.contains(text[index].value) }
        var at = 0
        while at + header.count <= n {
            defer { at += 1 }
            guard text[at..<(at + header.count)].elementsEqual(header) else { continue }
            // `^\s*`: only whitespace back to the start of a line.
            var start = at
            while start > 0, space(start - 1), text[start - 1] != "\n" { start -= 1 }
            guard start == 0 || text[start - 1] == "\n" else { continue }
            // `\s*\n\s*`: whitespace holding a line break, then the link, `(\S+)`.
            var from = at + header.count, broke = false
            while from < n, space(from) {
                broke = broke || text[from] == "\n"
                from += 1
            }
            guard broke, from < n else { continue }
            var end = from
            while end < n, !space(end) { end += 1 }
            // `\s*$`: nothing but whitespace after it on its line.
            var rest = end
            while rest < n, space(rest), text[rest] != "\n" { rest += 1 }
            guard rest == n || text[rest] == "\n" else { continue }
            let url = String(String.UnicodeScalarView(text[from..<end]))
            return isGoogleLink(url) ? url : ""
        }
        return ""
    }

    /// Which of the upload's own failure lines GAM printed. Each code is what the record keeps in `extra.upload`.
    public enum Upload: String, Sendable, CaseIterable {
        case sheetsRefused = "sheets_refused"
        case driveRefused = "drive_refused"
        case driveOff = "drive_off"
        case notPermitted = "not_permitted"
        case probablyMade = "probably_made"
        case createFailed = "create_failed"
        case finishFailed = "finish_failed"
        /// `User: <admin>, Not Created: <why>`: the outer handler's `entityActionNotPerformedWarning`, before or after the create.
        case notCreated = "not_created"
    }

    /// Which of the upload's own failure lines GAM printed (GamGUI's `UPLOAD_LINES`, each read as GamGUI's `re.I` reads it): the
    /// last one (the upload runs after the read; on a tie the one listed first), or nil for none. `owner` is GAM's name for the
    /// admin, the Directory's primary address (`GetTodriveParameters` replaces the token's address with `checkUserExists`'s
    /// `primaryEmail`). When the last line names another account it can't place the file, whether it's the read's or the
    /// admin's under another name: nil, unknown, never an earlier line instead (a deviation: GamGUI skips it). With no owner
    /// known, any account's line counts, as GamGUI's.
    public static func uploadState(_ stderr: String, owner: String) -> Upload? {
        var found: (at: String.Index, code: Upload, who: Substring?)?
        func consider(_ code: Upload, _ at: String.Index, who: Substring? = nil) {
            if found.map({ at > $0.at }) ?? true { found = (at, code, who) }
        }
        for match in stderr.matches(of: /User: ([^,\n]+), Sheets API[^,\n]*Service\/App not enabled/.ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.sheetsRefused, match.range.lowerBound, who: match.output.1) }
        for match in stderr.matches(of: /User: ([^,\n]+), Drive API v3[^,\n]*Service\/App not enabled/.ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.driveRefused, match.range.lowerBound, who: match.output.1) }
        for match in stderr.matches(of: /User: ([^,\n]+), Drive Service\/App not enabled/.ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.driveOff, match.range.lowerBound, who: match.output.1) }
        for match in stderr.matches(of: /Insufficient permissions to perform this task/.ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.notPermitted, match.range.lowerBound) }
        for match in stderr.matches(of: /Drive File: [^\n]*, \w+ Failed: Google reported [^\n]*the file was probably uploaded/
            .ignoresCase().matchingSemantics(.unicodeScalar)) { consider(.probablyMade, match.range.lowerBound) }
        // GAM's own line, at a line's start, its parent always `root` (no `tdparent` is sent): a read's `User: <x>, Drive Folder:
        // <id>, Print Failed: …` (printDiskUsage, printEmptyDriveFolders) is no create.
        for match in stderr.matches(of: /^\s*Drive Folder: root, Create Failed:/.anchorsMatchLineEndings().ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.createFailed, match.range.lowerBound) }
        for match in stderr.matches(of: /User: ([^,\n]+), Drive File ID: [^,\n]+, Not \w+/.ignoresCase()
            .matchingSemantics(.unicodeScalar)) { consider(.finishFailed, match.range.lowerBound, who: match.output.1) }
        for match in stderr.matches(of: /User: ([^,\n]+), Not Created:/.ignoresCase().matchingSemantics(.unicodeScalar)) {
            consider(.notCreated, match.range.lowerBound, who: match.output.1)
        }
        guard let found else { return nil }
        if let who = found.who, !owner.isEmpty, who.lowercased() != owner.lowercased() { return nil }
        return found.code
    }

    /// What an export's record keeps from GAM's output: the file's link when GAM printed one (`url`), else which of the upload's
    /// own failure lines it printed (`upload`). Never the output itself.
    public static func noted(stdout: String, stderr: String, owner: String) -> [String: String] {
        let url = sheetURL(stdout)
        if !url.isEmpty { return ["url": url] }
        return uploadState(stderr, owner: owner).map { ["upload": $0.rawValue] } ?? [:]
    }

    /// An exit 0 that printed no link is no answer: whether a file was made can't be told (invariant 10).
    public static let noLink = "GAM finished without printing the file's link, so whether a Sheet was made can't be told. "
        + "Look in the admin's Drive before exporting again."

    /// The new file's name: the domain and the read, as GAM names one without `tdtitle` (`<domain> - <list>`).
    public static func title(domain: String, read: String) -> String {
        domain.isEmpty ? read : "\(domain) - \(read)"
    }

    /// The scope check's answer, from `check serviceaccount scopes <drive>,<spreadsheets>` (GamGUI's `sheet_export_scopes`):
    /// each scope and whether the service account may use it for the admin, or nil when it couldn't be told (another exit than
    /// 0 or a failed scope's 10, or a row missing), which is never "allowed" (invariant 10).
    public static func checked(_ result: GamResult) -> [String: Bool]? {
        guard result.exitCode == 0 || result.exitCode == GamExitCode.scopesNotAuthorized else { return nil }
        var rows: [String: Bool] = [:]
        for row in AccessCheck.rows(in: result.stdout) { rows[PythonText.lower(row.label)] = row.passed }
        var checked: [String: Bool] = [:]
        for (scope, _) in scopes {
            guard let allowed = rows[scope] else { return nil }
            checked[scope] = allowed
        }
        return checked
    }

    /// The scope check, in words, for the preview: "" when both are allowed; what's missing otherwise; or that it couldn't be
    /// told (`checked` nil). An unknown is said as unknown, never read as allowed.
    public static func scopeState(_ checked: [String: Bool]?) -> String {
        guard let checked else {
            return "Whether the service account may use Drive and Sheets for the admin couldn't be checked, so GAM may stop part way: "
                + "with Drive refused nothing is made, with Sheets refused the file is made and its link isn't printed."
        }
        let missing = scopes.map(\.scope).filter { checked[$0] != true }
        if missing.isEmpty { return "" }
        if missing == [sheetsScope] {
            return "The service account isn't allowed Google Sheets (\(sheetsScope)) for the admin. GAM would make the file in the "
                + "admin's Drive, then stop before finishing it as a Sheet or printing its link."
        }
        return "The service account isn't allowed \(missing.joined(separator: " or ")) for the admin, so GAM can't make the file."
    }

    /// Whether a file was made.
    public enum Made: String, Sendable {
        case yes, no, unknown
    }

    /// What an export did, for its result: the link (when GAM printed one), whether a file was made, and what happened and what
    /// to do, in words.
    public struct Outcome: Sendable, Equatable {
        public let url: String
        public let made: Made
        public let said: String
        public let todo: String

        public init(url: String, made: Made, said: String, todo: String = "") {
            self.url = url
            self.made = made
            self.said = said
            self.todo = todo
        }
    }

    static let addScope = "Authorize it in the Admin console's Domain-Wide Delegation (Setup's link has every scope GamGUI uses), "
        + "then export again."

    /// Reads an export's result (GamGUI's `outcome`, word for word): `ok` is the write's, `url` and `upload` what its record
    /// kept from the upload's own lines (`noted`), `error` GAM's summary, said only as why a made Sheet may be short. Only a
    /// printed link or one of the upload's lines places the file; anything else is unknown (invariant 10).
    public static func outcome(ok: Bool, url: String, upload: String, owner: String, error: String = "") -> Outcome {
        let who = owner.isEmpty ? "the admin" : owner
        if ok, !url.isEmpty, !url.contains("/spreadsheets/") {   // too large for a Sheet: GAM uploaded the CSV as a plain file
            return Outcome(url: url, made: .yes, said: "Exported to a new file in \(who)'s Drive, shared with nobody: a plain CSV "
                           + "file, since the result was too large for a Google Sheet.")
        }
        if ok {
            return Outcome(url: url, made: .yes, said: url.isEmpty
                           ? "Exported to \(who)'s Drive. No link was kept: the export was made before its link was recorded."
                           : "Exported to a new Google Sheet in \(who)'s Drive, shared with nobody.")
        }
        if !url.isEmpty {   // the upload printed its link; the read itself had reported a problem, which set the exit code
            let said = "GAM made the Sheet in \(who)'s Drive, but the read reported a problem, so the Sheet may hold only some rows, "
                + "or only its headers."
            return Outcome(url: url, made: .yes, said: said + (error.isEmpty ? "" : " GAM said: \(error)"),
                           todo: "Check it against what you expected, or export again once the read works.")
        }
        switch Upload(rawValue: upload) {
        case .sheetsRefused?:
            return Outcome(url: "", made: .yes, said: "GAM made the file in \(who)'s Drive, then stopped before finishing it as a "
                           + "Sheet or printing its link: the service account isn't allowed Google Sheets (\(sheetsScope)).",
                           todo: "Find the file in that Drive by its name. " + addScope)
        case .finishFailed?:
            return Outcome(url: "", made: .yes, said: "GAM made the file in \(who)'s Drive, then Google refused to finish it as a "
                           + "Sheet, so no link was printed.", todo: "Find the file in that Drive by its name, and see GAM's line below.")
        case .driveRefused?:
            return Outcome(url: "", made: .no, said: "Nothing was made: the service account isn't allowed Drive (\(driveScope)) for "
                           + "\(who).", todo: addScope)
        case .driveOff?:
            // Printed for a refusal before the create or for the Sheets step after it (the outer handler): unknown.
            return Outcome(url: "", made: .unknown, said: "Google said Drive is turned off for \(who). GAM may have stopped before "
                           + "making the file or after, so whether a file was made can't be told.",
                           todo: "Look in \(who)'s Drive before exporting again. If Drive is off for the admin, turn it on for its "
                               + "organizational unit in the Admin console first.")
        case .notPermitted?:
            return Outcome(url: "", made: .no, said: "Nothing was made: Google refused to create a file in \(who)'s Drive.",
                           todo: "Check that the admin's Drive accepts new files, then export again.")
        case .createFailed?:
            // A full Drive or a missing folder made nothing, but Google's 500 UNKNOWN reads the same: unknown.
            return Outcome(url: "", made: .unknown, said: "Google refused or failed the file's create in \(who)'s Drive (it may be "
                           + "full), so whether a file was made can't be told.",
                           todo: "Look in \(who)'s Drive before exporting again, and see GAM's line below.")
        case .notCreated?:
            return Outcome(url: "", made: .unknown, said: "Google stopped the export, before the file was made or after, so whether a "
                           + "file was made can't be told.", todo: "Look in \(who)'s Drive before exporting again, and see GAM's line below.")
        case .probablyMade?:
            return Outcome(url: "", made: .unknown, said: "Google reported an error, but says the file was probably made.",
                           todo: "Look in \(who)'s Drive before exporting again.")
        case nil:
            return Outcome(url: "", made: .unknown, said: "The export failed, and whether a file was made can't be told.",
                           todo: "Look in \(who)'s Drive before exporting again.")
        }
    }

    /// Whether a catalog read can go to a Sheet: GAM's command takes `todrive` (GamGUI's `supports_export`). A catalog command's
    /// grammar line names `todrive` when GAM's command takes it; GamGUI's curated reads each point at a `print` or `report`
    /// command that does. This app's catalog holds each command's first grammar line only (GamGUI's joins the rest, #132), so a
    /// command whose `todrive` sits on a later line isn't offered here: the narrower side.
    public static func takesToDrive(syntax: String, curated: Bool) -> Bool {
        if syntax.contains("todrive") { return true }
        let words = syntax.split(whereSeparator: \.isWhitespace)
        return curated && (words.contains("print") || words.contains("report"))
    }
}
