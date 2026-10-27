import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// A report's columns worked out once for its every row (`ActivityLogs.Columns`, 2026-10-27: each row sorted its own, which
/// was most of a Gmail read's time in a Debug build). Held to the parser as it was, kept here as `reference`: the same
/// parameters, in the same order, for every row of every log the mock reports and for rows made to reach each case.
@Suite("Activity log columns")
struct ActivityColumnsTests {
    /// The parser as it was before 2026-10-27: everything worked out again for each row.
    static func reference(_ record: GamOutput.Record) -> [ActivityLogs.Parameter] {
        var names: [String: String] = [:]
        for (key, value) in record where key.hasPrefix("parameters.") && key.hasSuffix(".name") {
            names[String(key.dropLast(5))] = Fields.text(value)
        }
        let keys = Set(record.keys)
        func isCount(_ key: String) -> Bool { keys.contains(key + ".0") }
        func padded(_ key: String) -> String {
            key.split(separator: ".").map { part in
                part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && part.count < 9
                    ? String(repeating: "0", count: 9 - part.count) + part : String(part)
            }.joined(separator: ".")
        }
        let ordered = record.members.filter { !$0.key.hasPrefix("parameters.") }
            + record.members.filter { $0.key.hasPrefix("parameters.") }.sorted { padded($0.key) < padded($1.key) }
        var out: [ActivityLogs.Parameter] = []
        for (key, value) in ordered where !isCount(key) {
            let text = Fields.text(Fields.truthy(value))
            guard !text.isEmpty, !ActivityLogs.activityColumns.contains(key) else { continue }
            guard key.hasPrefix("parameters.") else {
                out.append(ActivityLogs.Parameter(name: key, value: text))
                continue
            }
            let parts = key.split(separator: ".").map(String.init)
            guard let at = parts.lastIndex(where: { ["value", "intValue", "boolValue", "multiValue"].contains($0) }),
                  !(parts[at] == "multiValue" && at == parts.count - 1)
            else { continue }
            var chain: [String] = []
            for end in stride(from: 2, through: at, by: 1) {
                if let name = names[parts[..<end].joined(separator: ".")] { chain.append(name) }
            }
            guard !chain.isEmpty else { continue }
            let name = chain.joined(separator: ".")
            if let last = out.last, last.name == name, parts[at] == "multiValue" {
                out[out.count - 1] = ActivityLogs.Parameter(name: name, value: last.value + " " + text)
            } else {
                out.append(ActivityLogs.Parameter(name: name, value: text))
            }
        }
        var seen: Set<String> = []
        return out.filter { seen.insert($0.name + "\u{0}" + $0.value).inserted }
    }

    /// A Gmail-shaped header as GAM flattens it, with more than ten nested parameters (so text order and numeric order
    /// differ: `parameter.10` sorts before `parameter.2` as text), a list (`multiValue`) with its count column, a boolean, a
    /// parameter named twice, simple columns, and the activity's own columns.
    static let wideHeader: [String] = {
        var header = ["name", "actor.callerType", "actor.email", "id.time", "id.uniqueQualifier", "ipAddress", "parameters", "type",
                      "is_suspicious", "login_type"]
        for top in [1, 0, 2] {
            header += ["parameters.\(top).messageValue.parameter", "parameters.\(top).name"]
            for nested in (0..<12).reversed() {
                header += ["parameters.\(top).messageValue.parameter.\(nested).name",
                           "parameters.\(top).messageValue.parameter.\(nested).\(nested % 3 == 0 ? "intValue" : nested % 3 == 1 ? "value" : "boolValue")"]
            }
        }
        header += ["parameters.3.name", "parameters.3.multiValue", "parameters.3.multiValue.0", "parameters.3.multiValue.1",
                   "parameters.3.multiValue.10", "parameters.3.multiValue.2", "parameters.4.name", "parameters.4.value", "parameters.5.value"]
        return header
    }()

    static func wideRecord(_ row: Int, blank: Set<String> = []) -> GamOutput.Record {
        var record = GamOutput.Record()
        for key in wideHeader {
            let value: JSONValue
            if blank.contains(key) {
                value = .null
            } else if key.hasSuffix(".name") {
                let parts = key.split(separator: ".")
                value = .string(parts.count > 3 ? "field_\(parts[1])_\(parts[4])" : ["0": "event_info", "1": "message_info", "2": "extra",
                                                                                      "3": "destinations", "4": "type"][String(parts[1])] ?? "x")
            } else if key == "parameters.3.multiValue" {
                value = .string("4")
            } else {
                value = .string(key == "parameters.4.value" ? "email" : key == "type" ? "email" : "\(key)=\(row)")
            }
            record[key] = value
        }
        return record
    }

    /// Every row of every log the mock reports reads as it did.
    @Test func everyMockReportReadsAsBefore() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Fixtures.mockGamData, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("report_") && $0.pathExtension == "csv" }
        #expect(files.count >= 10, "the scan must see the mock's reports")
        var rows = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let records = GamOutput.records(text)
            let read = ActivityLogs.rows(text, application: .login)
            #expect(read.count == records.count)
            for (record, row) in zip(records, read) {
                #expect(row.parameters == Self.reference(record), "\(file.lastPathComponent)")
                rows += 1
            }
        }
        #expect(rows > 50)
    }

    /// Rows made to reach each case read as they did: numeric order past ten, a list joined, its count column left out, a
    /// boolean, empty cells (a parameter's name among them), the activity's own columns never a parameter.
    @Test func wideRowsReadAsBefore() throws {
        let columns = ActivityLogs.Columns(Self.wideHeader)
        let blanks: [Set<String>] = [[], ["parameters.1.messageValue.parameter.10.name", "parameters.3.multiValue.1", "login_type"],
                                     ["parameters.0.name", "parameters.4.value"], Set(Self.wideHeader.filter { $0.hasSuffix(".value") })]
        for (row, blank) in blanks.enumerated() {
            let record = Self.wideRecord(row, blank: blank)
            #expect(columns.fit(record))
            #expect(columns.parameters(record) == Self.reference(record), "row \(row)")
        }
        let said = columns.parameters(Self.wideRecord(0))
        #expect(said.prefix(3).map(\.name) == ["type", "is_suspicious", "login_type"], "the simple columns first, in GAM's order")
        #expect(said.contains { $0.name == "destinations" && $0.value.hasSuffix("multiValue.2=0 parameters.3.multiValue.10=0") },
                "a list's values joined in numeric order")
        let nested = said.filter { $0.name.hasPrefix("message_info.") }.map(\.name)
        #expect(nested.prefix(3) == ["message_info.field_1_0", "message_info.field_1_1", "message_info.field_1_2"]
                && nested.last == "message_info.field_1_11", "numeric order, not text order")
        #expect(!said.contains { ActivityLogs.activityColumns.contains($0.name) || $0.name.hasPrefix("parameters") })
    }

    /// One plan for a CSV's rows; JSON records whose columns differ each get their own, never another's.
    @Test func rowsWithOtherColumnsGetTheirOwn() throws {
        let json = """
        {"name": "login_success", "id.time": "2026-10-19T14:00:00Z", "actor.email": "carol@example.com", "parameters.0.name": "login_type", "parameters.0.value": "google_password"}
        {"name": "login_failure", "id.time": "2026-10-19T14:05:00Z", "actor.email": "carol@example.com", "parameters.1.name": "login_type", "parameters.1.value": "saml", "parameters.0.name": "login_failure_type", "parameters.0.value": "login_failure_invalid_password"}
        """
        let rows = ActivityLogs.rows(json, application: .login)
        let records = GamOutput.records(json)
        #expect(rows.count == 2)
        #expect(rows.map(\.parameters) == records.map(Self.reference))
        #expect(rows[1].parameters.map(\.name) == ["login_failure_type", "login_type"])
        #expect(!ActivityLogs.Columns(records[0].keys).fit(records[1]))
    }

    /// Wide rows parse in a fraction of the time they took (the operator's Debug build spent 6 to 8 s on a Gmail read of
    /// 1,000). Measured in the thread's CPU time, by the plan against the parser as it was, on the same 100 rows.
    @Test func wideRowsParseFasterThanBefore() throws {
        let records = (0..<100).map { Self.wideRecord($0) }
        func cpu(_ work: () -> Void) -> Double {
            var start = timespec(), end = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
            work()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
            return Double(end.tv_sec - start.tv_sec) + Double(end.tv_nsec - start.tv_nsec) / 1e9
        }
        var before = 0, after = 0
        let old = cpu { for record in records { before += Self.reference(record).count } }
        let columns = ActivityLogs.Columns(Self.wideHeader)
        let new = cpu { for record in records { after += columns.parameters(record).count } }
        #expect(before == after)
        print("100 wide rows: \(old) s as before, \(new) s by their columns")
        #expect(new * 5 < old, "\(new) s against \(old) s")
    }
}
