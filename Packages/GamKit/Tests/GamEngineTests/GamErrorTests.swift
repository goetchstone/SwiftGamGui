import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for failed runs (invariant 11): every case in `Tests/Fixtures/gam_errors.json`,
/// generated from frozen GamGUI's `GAMError.from_run`, gets the same kind, kinds, message, masked
/// output, masked argv and named scopes. Compared as bytes. The fixture is never edited to pass.
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
