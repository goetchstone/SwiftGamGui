import Foundation
import Testing
import GamEngine
import TestSupport

/// Invariant 11: every Swift builder emits exactly the argv GamGUI's live-proven builder emits, for
/// every case in `Tests/Fixtures/argv.json` (generated from frozen GamGUI by `scripts/gen_fixtures.py`).
/// A builder is added to `implemented` when it is ported; the fixture is never edited to pass.
@Suite("Golden argv")
struct GoldenArgvTests {
    enum Value: Decodable, Equatable, Sendable {
        case string(String), bool(Bool), strings([String]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
            else if let string = try? container.decode(String.self) { self = .string(string) }
            else { self = .strings(try container.decode([String].self)) }
        }
    }

    struct Case: Decodable {
        let builder: String
        let kwargs: [String: Value]
        let argv: [String]?
        let error: String?
    }

    struct Document: Decodable {
        let builders: [String]
        let cases: [Case]
    }

    enum Missing: Error { case argument(String) }

    static func string(_ kwargs: [String: Value], _ key: String) throws -> String {
        guard case .string(let value) = kwargs[key] else { throw Missing.argument(key) }
        return value
    }

    static func strings(_ kwargs: [String: Value], _ key: String) throws -> [String] {
        guard case .strings(let value) = kwargs[key] else { throw Missing.argument(key) }
        return value
    }

    /// Ported builders, by GamGUI's name.
    static let implemented: [String: @Sendable ([String: Value]) throws -> [String]] = [
        "version": { _ in GamCommands.version() },
        "check_svcacct": { try GamCommands.checkServiceAccount(admin: string($0, "admin"), scopes: strings($0, "scopes")) },
    ]

    let document: Document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.argvJSON))

    @Test func everyPortedBuilderMatchesGamGUIOnEveryCase() throws {
        #expect(Set(Self.implemented.keys).isSubset(of: Set(document.builders)))
        var checked = 0
        for item in document.cases {
            guard let build = Self.implemented[item.builder] else { continue }
            if let expected = item.argv {
                #expect(try build(item.kwargs) == expected, "\(item.builder) \(item.kwargs)")
            } else {
                #expect(throws: (any Error).self, "\(item.builder) should refuse \(item.kwargs)") { try build(item.kwargs) }
            }
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test func checkServiceAccountRefusesNoScopesAsGamGUIDoes() {
        #expect(throws: GamCommands.Invalid.self) { try GamCommands.checkServiceAccount(admin: "a@example.com", scopes: []) }
    }
}
