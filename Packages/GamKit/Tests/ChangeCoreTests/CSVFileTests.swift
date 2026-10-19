@testable import ChangeCore
import Foundation
import Testing

/// A list the operator saves (the Phishing screen's copies and recipients): the audit export's dialect and its
/// `csv_safe`, written private and whole.
@Suite("CSV file")
struct CSVFileTests {
    @Test func aSavedListIsPrivateWholeAndInert() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-csv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appending(path: "list.csv")
        try CSVFile.write(header: ["address", "where"], rows: [["=HYPERLINK(\"x\")", "outside"], ["a@example.com", "in, side"],
                                                               ["+1", "-2"], ["@sum", "\tx"]], to: destination)
        let text = try String(contentsOf: destination, encoding: .utf8)
        // A formula lead gets a quote first; a cell with a quote or a comma is quoted, its quotes doubled; CRLF ends a row.
        #expect(text == "address,where\r\n\"'=HYPERLINK(\"\"x\"\")\",outside\r\na@example.com,\"in, side\"\r\n'+1,'-2\r\n'@sum,'\tx\r\n")
        let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["list.csv"], "no partial file left")
        // A destination that can't be written leaves nothing behind.
        #expect(throws: (any Error).self) {
            try CSVFile.write(header: ["a"], rows: [], to: folder.appending(path: "missing/list.csv"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["list.csv"])
    }
}
