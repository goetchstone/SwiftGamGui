import Foundation
@testable import Directory
import GamEngine
import TestSupport
import Testing

/// GamGUI parity for the directory reports (invariant 11): `Tests/Fixtures/reports.json` holds GamGUI's
/// `build_reports` over the mock's users and seeded variants at a fixed time.
@Suite("Directory reports")
struct DirectoryReportTests {
    struct Report: Decodable {
        let key: String, title: String, description: String, members: [String]
    }

    struct Document: Decodable {
        let now: String
        let inactive_days: Int
        let records: [RecordText]
        let reports: [Report]
    }

    /// A user record as plain JSON in the fixture, read through `JSONValue`.
    struct RecordText: Decodable {
        let value: GamOutput.Record

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(Raw.self)
            guard case .object(let record) = raw.value else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object"))
            }
            value = record
        }
    }

    struct Raw: Decodable {
        let value: JSONValue

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = .null }
            else if let flag = try? container.decode(Bool.self) { value = .bool(flag) }
            else if let number = try? container.decode(Int.self) { value = .number(String(number)) }
            else if let text = try? container.decode(String.self) { value = .string(text) }
            else if let items = try? container.decode([Raw].self) { value = .array(items.map(\.value)) }
            else {
                var object = JSONObject()
                for (key, raw) in try container.decode([String: Raw].self) { object[key] = raw.value }
                value = .object(object)
            }
        }
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.reportsJSON))

    @Test func theReportsAreGamGUIs() throws {
        let now = try #require(ISOTime.parse(document.now))
        let users = document.records.map { GamUser(record: $0.value) }
        let reports = DirectoryReport.build(users, now: now, inactiveDays: document.inactive_days)
        #expect(reports.map(\.key) == document.reports.map(\.key))
        for (report, want) in zip(reports, document.reports) {
            #expect(report.title == want.title && report.description == want.description, "\(want.key)")
            #expect(report.users.map(\.primaryEmail) == want.members, "\(want.key)")
        }
    }

    @Test func loginTimesReadAsPythonReadsThem() {
        let epoch = { (text: String) in ISOTime.parse(text)?.timeIntervalSince1970 }
        #expect(epoch("1970-01-01T00:00:00.000Z") == 0)
        #expect(epoch("2026-10-08T12:00:00Z") == 1_791_460_800)
        #expect(epoch("2026-10-08T14:00:00+02:00") == 1_791_460_800)
        #expect(epoch("2026-10-08 12:00:00") == 1_791_460_800)
        #expect(epoch("2026-10-08") == 1_791_417_600)
        #expect(epoch(" 2026-10-08T12:00:00.5Z ") == 1_791_460_800.5)
        for refused in ["Never", "", "2026-02-30", "2026-13-01", "2026-10-08T24:00:00", "2026-10-08T12:00:00 extra", "not a date"] {
            #expect(ISOTime.parse(refused) == nil, "\(refused)")
        }
    }
}
