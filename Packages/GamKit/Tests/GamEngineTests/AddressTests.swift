import Foundation
import GamEngine
import TestSupport
import Testing

/// GamGUI's `looks_like_email`, held to its own answers in `Tests/Fixtures/setup.json`: Python's `strip`
/// and `\s`, commas, a bare name, `@domain`, empty labels.
@Suite("Address")
struct AddressTests {
    struct Check: Decodable { let value: String; let ok: Bool }
    struct Document: Decodable { let looks_like_email: [Check] }

    @Test func looksLikeEmailIsGamGUIs() throws {
        let checks = try JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.setupJSON)).looks_like_email
        #expect(checks.count > 40)
        #expect(checks.contains { $0.ok } && checks.contains { !$0.ok })
        for check in checks {
            #expect(Address.looksLikeEmail(check.value) == check.ok, "\(Array(check.value.unicodeScalars.map(\.value)))")
        }
    }
}
