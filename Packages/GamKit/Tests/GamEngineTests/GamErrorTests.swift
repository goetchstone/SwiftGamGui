import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for failed runs (invariant 11): every case in `Tests/Fixtures/gam_errors.json`,
/// generated from GamGUI's `GAMError.from_run`, gets the same kind, kinds, message, masked output, masked
/// argv and named scopes. Compared as bytes. The fixture is never edited to pass. It is generated with
/// GamGUI's progress rule widened to GAM's own progress lines (`gen_fixtures.py`'s `gam_progress`); a case
/// frozen GamGUI reads differently also holds its reading (`gamgui`), the deviation held narrow below.
@Suite("GAM errors")
struct GamErrorTests {
    struct Case: Decodable {
        let exit_code: Int32?
        let stderr: String
        let argv: [String]?
        let stdout: String
        let kind: String
        let kinds: [String]
        let message: String
        let scrubbed_stderr: String
        let scrubbed_stdout: String
        let redacted_argv: [String]?
        let remediation_suffix: String
        let gamgui: Frozen?
    }

    /// How frozen GamGUI reads a case, where it differs.
    struct Frozen: Decodable {
        let kind: String
        let kinds: [String]
        let message: String
        let remediation_suffix: String
    }

    struct Constants: Decodable {
        let unicode_version: String
        let IGNORECASE_FOLDS: [[Int]]
        let WORD: [[UInt32]]
        let DECIMAL: [[UInt32]]
        let UNASSIGNED: [[UInt32]]
        let LINE_BREAKS: [UInt32]
        let SENSITIVE_KEYS: [String]
        let SEVERITY: [String]
        let ACCOUNT_WIDE: [String]
    }

    struct Document: Decodable {
        let constants: Constants
        let cases: [Case]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.gamErrorsJSON))

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func everyCaseReadsAsGamGUIReadsIt() {
        for item in document.cases {
            let error = GamError(exitCode: item.exit_code, stderr: item.stderr, argv: item.argv, stdout: item.stdout)
            let label = "\(item.exit_code.map(String.init) ?? "nil") \(item.stderr.debugDescription)"
            #expect(error.kind.rawValue == item.kind, "kind: \(label)")
            #expect(error.kinds.map(\.rawValue).sorted() == item.kinds, "kinds: \(label)")
            #expect(Self.bytes(error.message) == Self.bytes(item.message), "message: \(label)")
            #expect(Self.bytes(error.stderr) == Self.bytes(item.scrubbed_stderr), "stderr: \(label)")
            #expect(Self.bytes(error.stdout) == Self.bytes(item.scrubbed_stdout), "stdout: \(label)")
            #expect(error.argv?.map(Self.bytes) == item.redacted_argv?.map(Self.bytes), "argv: \(label)")
            #expect(Self.bytes(error.remediation) == Self.bytes(error.kind.remediation + item.remediation_suffix),
                    "remediation: \(label)")
        }
        #expect(document.cases.count > 1500)
    }

    /// GAM's per-entity progress line that frozen GamGUI's `_PROGRESS_LINE` ("Getting all " or "Got <n> ")
    /// misses: "Getting Reports for all users", "Getting Group sales@… (1/3)".
    static func gamGUIMisses(_ line: String) -> Bool {
        line.unicodeScalars.starts(with: "Getting ".unicodeScalars) && !line.unicodeScalars.starts(with: "Getting all ".unicodeScalars)
    }

    /// The one deliberate difference from frozen GamGUI (failure-log 2026-10-13, "GAM's progress read as an
    /// error"): it reads GAM's per-entity "Getting …" lines as unknown failures. Each listed case has such a
    /// line, GamGUI's reading counts it unknown and differs from ours, and the list is a small share.
    @Test func theDeviationsFromGamGUIAreOnlyItsMissedProgressLines() {
        var deviations = 0
        for item in document.cases {
            guard let frozen = item.gamgui else { continue }
            deviations += 1
            let label = item.stderr.debugDescription
            #expect(PythonText.lines(item.stderr).map { PythonText.strip($0) }.contains(where: Self.gamGUIMisses), "\(label)")
            #expect(frozen.kinds.contains("unknown"), "GamGUI read the progress line as unknown: \(label)")
            #expect(frozen.kind != item.kind || frozen.kinds != item.kinds || Self.bytes(frozen.message) != Self.bytes(item.message)
                    || Self.bytes(frozen.remediation_suffix) != Self.bytes(item.remediation_suffix), "\(label)")
        }
        #expect(deviations > 0 && deviations < document.cases.count / 10)
    }

    /// Each shape GAM's progress printers write (`gam/__init__.py:2681-2722`, the page counts :2736-2763),
    /// with the per-entity counter where they print one. None is an error line.
    static let progress = [
        "Getting all Users, may take some time on a large Google Workspace Account...",
        "Got 3 Groups",
        "Getting all Users in the Organizational Unit for /Sales, may take some time on a large Organizational Unit... (2/4)",
        "Got 12 Users in the Organizational Unit for /Sales",
        "Getting Group sales@example.com (1/3)",
        "Getting Reports for all users",
        "Getting Access Tokens for alice@example.com",
        "Getting Calendars for carol@example.com (2/4)",
        "Got 3 Reports for all users on 2026-06-16...",
        "Got 1 Group: sales@example.com - sales@example.com",
    ]

    @Test(arguments: progress)
    func eachProgressShapeIsProgress(line: String) {
        #expect(GamError.isProgress(line))
        let error = GamError(exitCode: 1, stderr: line + "\n")
        #expect(error.kind == .unknown && error.kinds == [.unknown] && Self.bytes(error.message) == Self.bytes("GAM failed (unknown, exit=1)"),
                "nothing reported: \(error.message)")
    }

    /// A real failure after a progress line keeps its own kind, remediation and message. Read as frozen
    /// GamGUI reads it, the progress line was an unknown failure that outranked each of these.
    @Test(arguments: [
        ("Getting Calendars for carol@example.com (2/4)\nUser: carol@example.com, Calendar Service/App not enabled (2/4)\n",
         GamError.Kind.serviceNotEnabled, "User: carol@example.com, Calendar Service/App not enabled (2/4)"),
        ("Getting Group sales@example.com (1/3)\nUser: bob@example.com, Service not applicable/Does not exist\n",
         .notFound, "User: bob@example.com, Service not applicable/Does not exist"),
        ("Getting Reports for all users\n\nERROR: Customer ID: my_customer, Domain: example.com, User: admin@example.com, Access Forbidden\n",
         .permissionDenied, "ERROR: Customer ID: my_customer, Domain: example.com, User: admin@example.com, Access Forbidden"),
        ("Getting Access Tokens for alice@example.com\nUser: alice@example.com, Gmail Service/App not enabled\n",
         .serviceNotEnabled, "User: alice@example.com, Gmail Service/App not enabled"),
    ])
    func aRealFailureAfterProgressKeepsItsKind(stderr: String, kind: GamError.Kind, line: String) {
        let error = GamError(exitCode: 50, stderr: stderr)
        #expect(error.kind == kind)
        #expect(error.kinds == [kind])
        #expect(Self.bytes(error.message) == Self.bytes("GAM failed (\(kind.rawValue), exit=50): \(line)"))
    }

    /// Only GAM's own words at the line's start are progress: an entity line that mentions getting, a
    /// lowercase or shouted "getting", a count that isn't a number.
    @Test(arguments: [
        "User: alice@example.com, Getting Reports for all users",
        "ERROR: Getting Reports for all users failed",
        "getting Reports for all users",
        "GETTING Reports for all users",
        "Gettings for all users",
        "Getting",
        "Got Users",
        "Got 5Users",
        "got 5 Users",
        "Gotten 5 Users",
    ])
    func lookalikesAreNotProgress(line: String) {
        #expect(!GamError.isProgress(line))
        #expect(Self.bytes(GamError(exitCode: 1, stderr: line).message) == Self.bytes("GAM failed (unknown, exit=1): \(line)"))
    }

    @Test func theOrderAndSetsAreGamGUIs() {
        let constants = document.constants
        #expect(GamError.Kind.bySeverity.map(\.rawValue) == constants.SEVERITY)
        #expect(Set(GamError.Kind.allCases.map(\.rawValue)) == Set(constants.SEVERITY))
        #expect(GamError.Kind.allCases.filter(\.isAccountWide).map(\.rawValue).sorted() == constants.ACCOUNT_WIDE)
        #expect(ArgvRedaction.sensitiveKeys.sorted() == constants.SENSITIVE_KEYS)
        #expect(Set(constants.LINE_BREAKS) == PythonText.lineBreaks)
        let folds = Dictionary(uniqueKeysWithValues: constants.IGNORECASE_FOLDS.map { (UInt32($0[0]), $0[1]) })
        #expect(folds.keys.sorted() == PythonText.foldsToASCII.keys.sorted())
        for (point, letter) in PythonText.foldsToASCII {
            #expect(folds[point].map { String(UnicodeScalar(UInt8($0))) } == String(letter), "U+\(String(point, radix: 16))")
        }
    }

    /// `\w` and `\d` scalar by scalar, over every code point, including those Swift's newer Unicode
    /// assigns and Python's doesn't (PR #5's review: one let a password past the scrub).
    @Test func wordAndDigitAreRes() {
        let version = document.constants.unicode_version.split(separator: ".").compactMap { Int($0) }
        #expect(version.prefix(2).elementsEqual([PythonText.unicodeVersion.major, PythonText.unicodeVersion.minor]))
        func contains(_ ranges: [[UInt32]], _ point: UInt32) -> Bool {
            var low = 0, high = ranges.count - 1
            while low <= high {
                let middle = (low + high) / 2
                if point < ranges[middle][0] { high = middle - 1 }
                else if point > ranges[middle][1] { low = middle + 1 }
                else { return true }
            }
            return false
        }
        let constants = document.constants
        var wordMismatches: [UInt32] = [], digitMismatches: [UInt32] = []
        for point in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(point) else { continue }
            if PythonText.isWord(scalar) != contains(constants.WORD, point) { wordMismatches.append(point) }
            if PythonText.isDecimal(scalar) != contains(constants.DECIMAL, point) { digitMismatches.append(point) }
        }
        #expect(wordMismatches.isEmpty, "\\w differs at \(wordMismatches.prefix(10).map { String($0, radix: 16) })")
        #expect(digitMismatches.isEmpty, "\\d differs at \(digitMismatches.prefix(10).map { String($0, radix: 16) })")
    }

    @Test func stdoutNeverReachesTheMessageOrADump() {
        let error = GamError(exitCode: 10, stderr: "ERROR: 403: insufficient authentication scopes",
                             stdout: "directory-data-7f3a")
        var dumped = ""
        dump(error, to: &dumped)
        for shown in [error.message, "\(error)", String(reflecting: error), dumped] {
            #expect(!shown.contains("directory-data-7f3a"))
        }
        #expect(error.stdout == "directory-data-7f3a", "kept for the caller that reads it")
    }
}
