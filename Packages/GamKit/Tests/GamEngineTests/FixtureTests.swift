import Foundation
import Testing
import GamEngine
import TestSupport

/// The parity fixtures and the pin agree with each other: the Swift `test_pinned_version_consistent`.
@Suite("Fixtures and pin")
struct FixtureTests {
    struct ArgvDoc: Decodable {
        struct Source: Decodable {
            let gam_version: String
            let gamgui_commit: String
        }

        struct Case: Decodable {
            let builder: String
            let argv: [String]?
            let error: String?
        }

        let source: Source
        let builders: [String]
        let cases: [Case]
    }

    struct ExitCodesDoc: Decodable {
        let build_rc: [String: Int]
        let gamgui: [String: AnyCodable]

        struct AnyCodable: Decodable {
            let int: Int?
            init(from decoder: Decoder) throws {
                int = try? decoder.singleValueContainer().decode(Int.self)
            }
        }
    }

    struct CatalogDoc: Decodable {
        let version: String
        let commands: [Command]

        struct Command: Decodable {
            let id: String
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    @Test func goldenArgvCoversEveryGamGUIBuilder() throws {
        let doc = try decode(ArgvDoc.self, Fixtures.argvJSON)
        #expect(doc.source.gam_version == GamVersion.expected)
        #expect(doc.builders.count == 59)
        let covered = Set(doc.cases.map(\.builder))
        #expect(covered == Set(doc.builders))
        for item in doc.cases {
            #expect((item.argv == nil) != (item.error == nil), "\(item.builder): exactly one of argv/error")
        }
    }

    @Test func exitCodesComeFromTheVendoredBuild() throws {
        let doc = try decode(ExitCodesDoc.self, Fixtures.exitCodesJSON)
        #expect(doc.build_rc["UNKNOWN_ERROR_RC"] == 1)
        for name in ["SCOPES_NOT_AUTHORIZED_RC", "OAUTH2SERVICE_JSON_REQUIRED_RC"] {
            #expect(doc.gamgui[name]?.int == doc.build_rc[name], "\(name) differs from the build's table")
        }
    }

    @Test func catalogIsStampedWithThePinnedVersion() throws {
        let doc = try decode(CatalogDoc.self, Fixtures.catalogJSON)
        #expect(doc.version == GamVersion.expected)
        #expect(!doc.commands.isEmpty)
    }

    @Test func fetchScriptAndMockAgreeWithThePin() throws {
        let fetch = try String(contentsOf: Fixtures.fetchScript, encoding: .utf8)
        #expect(fetch.contains("TAG=\"v\(GamVersion.expected)\""))
        let mock = try String(contentsOf: Fixtures.mockGam, encoding: .utf8)
        #expect(mock.contains("echo \"GAM \(GamVersion.expected) - mock\""))
    }
}
