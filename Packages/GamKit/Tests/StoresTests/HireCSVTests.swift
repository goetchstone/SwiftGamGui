import GamEngine
@testable import Stores
import Testing

/// Hires from a CSV, read: GamGUI's `tests/test_onboarding.py` cases for `parse_hire_csv`, in its words.
@Suite("Hire CSV")
struct HireCSVTests {
    private func parse(_ text: String) -> (rows: [HireCSV.Row], errors: [String]) { HireCSV.parse(Array(text.utf8)) }

    /// `test_parse_hire_csv`: the template reads whole; headers in any case; blank rows skipped; each row checked.
    @Test func theTemplateAndEachRowsRules() {
        let template = parse(HireCSV.template)
        #expect(template.rows.count == 2 && template.errors.isEmpty)
        #expect(template.rows[0].hire.createAccount && template.rows[0].hire.notify == "jordan.personal@example.net")
        #expect(template.rows[1].hire.notify == "" && !template.rows[1].hire.sendWelcome)
        #expect(template.rows[0].role == "Salesperson" && template.rows[0].hire.first == "Jordan" && template.rows[0].line == 2)
        let mixed = parse("ROLE,Email\nSales,a@x.com\n\n,b@x.com\nSales,\n")
        #expect(mixed.rows.map(\.hire.email) == ["a@x.com"])
        #expect(mixed.errors == ["Row 4: missing role.", "Row 5: needs an email or an assignee."])
        #expect(parse("name,email\nx,y@x.com\n").errors == ["The CSV needs a 'role' column \u{2014} that's what picks the template."])
        #expect(parse("").errors == ["The CSV has no header row."])
    }

    /// `test_parse_hire_csv_flags_duplicate_emails`: any case.
    @Test func aDuplicateEmailIsRefused() {
        let read = parse("role,email\nSales,a@x.com\nSales,A@X.com\nSales,b@x.com\n")
        #expect(read.rows.map(\.hire.email) == ["a@x.com", "b@x.com"])
        #expect(read.errors == ["Row 3: duplicate email A@X.com (first on row 2)."])
    }

    /// `test_parse_hire_csv_rejects_invalid_email_targets`: a comma would be GAM's list separator.
    @Test func anInvalidAddressIsRefused() {
        let read = parse("role,email\nSales,oauthuser\nSales,@example.com\nSales,ok@example.com\nSales,\"a,b@example.com\"\n")
        #expect(read.rows.map(\.hire.email) == ["ok@example.com"])
        #expect(read.errors.count == 3 && read.errors.allSatisfy { $0.contains("is not a valid email address") })
    }

    /// `test_parse_hire_csv_refuses_an_unreadable_file_instead_of_raising`, and the 1 MB cap: refused whole.
    @Test func anUnreadableOrOversizedFileIsRefusedWhole() {
        let long = parse("role,email,name\nSales,a@x.com,ok\nSales,b@x.com," + String(repeating: "x", count: 140_000) + "\n")
        #expect(long.rows.isEmpty && long.errors.count == 1)
        #expect(long.errors[0].hasPrefix("Row 3: couldn't read the CSV") && long.errors[0].contains("Nothing was imported"))
        let big = parse("role,email\n" + String(repeating: "Sales,a@x.com\n", count: 80_000))
        #expect(big.rows.isEmpty && big.errors.first?.contains("over 1 MB") == true)
        #expect(HireCSV.parse([0x72, 0x6F, 0x6C, 0x65, 0x0A, 0xFF]).errors == ["That file isn't UTF-8 text. Save it as CSV UTF-8 and choose it again."])
    }

    /// `test_bulk_preview_accepts_excel_utf8_bom`, and Excel's CRLF line ends.
    @Test func excelsByteOrderMarkAndLineEndsRead() {
        let read = HireCSV.parse([0xEF, 0xBB, 0xBF] + Array("role,email\r\nSales,a@x.com\r\n".utf8))
        #expect(read.rows.map(\.role) == ["Sales"] && read.errors.isEmpty)
    }

    /// GamGUI's `_truthy`.
    @Test func truthyIsGamGUIs() {
        for yes in ["1", "true", "YES", " y ", "x", "On"] { #expect(HireCSV.truthy(yes), "\(yes)") }
        for no in ["", "0", "no", "false", "maybe"] { #expect(!HireCSV.truthy(no), "\(no)") }
    }
}
