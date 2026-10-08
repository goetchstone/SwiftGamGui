@testable import ChangeCore
import Foundation
import TestSupport
import Testing

/// GamGUI parity for the guard (invariant 11): `Tests/Fixtures/guard.json` holds GamGUI's
/// `guard.evaluate`, `enforce` and `alias_deletes` over seeded change sets and confirmations.
@Suite("Guard")
struct GuardTests {
    struct Spec: Decodable {
        let target: String
        let risk: Int
        let argv: [String]?
    }

    enum Field: Decodable {
        case one(String), many([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { self = .one(text) } else { self = .many(try container.decode([String].self)) }
        }

        var text: String { if case .one(let text) = self { text } else { "" } }
        var list: [String] { switch self { case .one(let text): [text]; case .many(let texts): texts } }
    }

    struct Decision: Decodable {
        let max_risk: Int, affected: [String], requires_confirmation: Bool, requires_typed_confirmation: Bool
        let over_hard_cap: Bool, summary: String, warnings: [String], requires_typed_count: Bool, typed_emails: [String]
    }

    struct Case: Decodable {
        let changes: [Spec]
        let form: [String: Field]
        let confirm_step: Bool
        let typed_count_above: Int?
        let decision: Decision
        let refusal: String?
    }

    struct Alias: Decodable {
        let resolved: [[String?]]
        let problems: [String]
    }

    struct Constants: Decodable {
        let DEFAULT_BULK_THRESHOLD: Int, DEFAULT_HARD_CAP: Int, COUNT_CONFIRM_ABOVE: Int, TYPED_WORD: String
    }

    struct Document: Decodable {
        let constants: Constants
        let cases: [Case]
        let aliases: [Alias]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.guardJSON))

    static func bytes(_ texts: [String]) -> [[UInt8]] { texts.map { Array($0.utf8) } }

    /// GamGUI's posted form as a native confirmation: the Confirm click is the field being exactly "1".
    static func confirmation(_ form: [String: Field]) -> OperatorConfirmation {
        OperatorConfirmation(confirmed: form["confirmed"]?.text.utf8.elementsEqual("1".utf8) ?? false,
                     typedWord: form["confirm"]?.text ?? "", typedCount: form["confirm_count"]?.text ?? "",
                     typedAddresses: form["confirm_email"]?.list ?? [])
    }

    @Test func theThresholdsAreGamGUIs() {
        #expect(Guard.bulkThreshold == document.constants.DEFAULT_BULK_THRESHOLD)
        #expect(Guard.hardCap == document.constants.DEFAULT_HARD_CAP)
        #expect(Guard.countConfirmAbove == document.constants.COUNT_CONFIRM_ABOVE)
        #expect(Guard.typedWord == document.constants.TYPED_WORD)
    }

    @Test func everyDecisionAndRefusalIsGamGUIs() {
        for (number, item) in document.cases.enumerated() {
            let changes = item.changes.map { Change(target: $0.target, summary: "x", risk: Risk(rawValue: $0.risk)!, argv: $0.argv) }
            let decision = Guard.evaluate(changes, typedCountAbove: item.typed_count_above), want = item.decision
            #expect(decision.maxRisk.rawValue == want.max_risk, "case \(number)")
            #expect(Self.bytes(decision.affected) == Self.bytes(want.affected), "case \(number)")
            #expect(decision.requiresConfirmation == want.requires_confirmation, "case \(number)")
            #expect(decision.requiresTypedConfirmation == want.requires_typed_confirmation, "case \(number)")
            #expect(decision.overHardCap == want.over_hard_cap && decision.requiresTypedCount == want.requires_typed_count, "case \(number)")
            #expect(Self.bytes([decision.summary] + decision.warnings) == Self.bytes([want.summary] + want.warnings), "case \(number)")
            #expect(Self.bytes(decision.typedAddresses) == Self.bytes(want.typed_emails), "case \(number)")
            let refusal = Guard.refusal(changes, Self.confirmation(item.form), confirmStep: item.confirm_step,
                                        typedCountAbove: item.typed_count_above)
            #expect(refusal.map { Array($0.utf8) } == item.refusal.map { Array($0.utf8) }, "case \(number): \(item.form)")
        }
        #expect(document.cases.count >= 700)
        #expect(document.cases.contains { $0.refusal == nil } && document.cases.contains { $0.refusal != nil })
    }

    @Test func aliasesAreRefusedAsGamGUIRefusesThem() {
        for item in document.aliases {
            let resolved = item.resolved.map { (address: $0[0] ?? "", primary: $0[1]) }
            #expect(Self.bytes(Guard.aliasDeletes(resolved)) == Self.bytes(item.problems), "\(item.resolved)")
        }
    }
}
