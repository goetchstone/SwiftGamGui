import Foundation
import GamEngine
import Testing
@testable import Assist

/// The connected apps' summary worded by the model (`AppsExplainer`): it is given counts and kinds only, and a sentence with
/// a number the counts don't hold is dropped.
@Suite("Apps explainer")
struct AppsExplainerTests {
    /// The strict mock's apps, as counted (`everyAccountsConnectedAppsAreRead`).
    static let facts = AppsExplainer.Facts(apps: 5, people: 3, ai: 2, aiPeople: 1, broad: 1, aiBroad: 0, onePerson: 3, onePersonAI: 2,
                                           onePersonBroad: 1, areas: [.mail: 1])

    /// Its kinds of access are GamEngine's, by raw value: the screen maps one to the other.
    @Test func theKindsAreGamEnginesKinds() {
        #expect(ConnectedApps.Area.allCases.map(\.rawValue) == AppsExplainer.Area.allCases.map(\.rawValue))
    }

    /// The prompt says the counts and kinds: it has nothing else to say, so never an app's name.
    @Test func thePromptHoldsCountsOnly() {
        #expect(AppsExplainer.prompt(Self.facts) == """
            Every account's connected apps, counted by code (suspended accounts left out):
            5 apps are connected, granted by 3 people in all.
            2 apps have names that look like an AI assistant's or agent's, granted by 1 person in all. None of them has broad access.
            1 app has broad access: 1 to all of Gmail or reading and changing mail.
            3 apps were granted by just one person each: 2 with a name like an AI's and 1 with broad access.
            """)
    }

    struct Stub: AppsExplainer.Asking {
        let answer: AppsExplainer.Answer
        func answer(instructions: String, prompt: String) async throws -> AppsExplainer.Answer { answer }
    }

    /// A sentence holding a number the facts don't, in digits or words, is dropped: the model words the counts, it never
    /// makes one.
    @Test func aMiscountIsDropped() async throws {
        let stub = Stub(answer: AppsExplainer.Answer(sentences: [
            " 5 apps are connected by 3 people. ", "7 of them can read all mail.", "Two look like AI tools, used by one person.",
            "Nine have admin access.", " "]))
        #expect(try await AppsExplainer.explain(Self.facts, using: stub)
                == "5 apps are connected by 3 people. Two look like AI tools, used by one person.")
    }
}

/// The real on-device model, by hand on a Mac that has it (`SWIFTGAMGUI_MODEL=1 swift test --filter OnDeviceAppsModel`): CI has
/// none, and a model's answer isn't a fixed output to hold a test to.
@Suite("On-device apps model", .enabled(if: ProcessInfo.processInfo.environment["SWIFTGAMGUI_MODEL"] == "1" && AppsExplainer.unavailable == nil))
struct OnDeviceAppsModelTests {
    @Test(arguments: [
        AppsExplainerTests.facts,
        AppsExplainer.Facts(apps: 5, people: 4, ai: 2, aiPeople: 2, broad: 3, aiBroad: 1, onePerson: 3, onePersonAI: 2, onePersonBroad: 2,
                            areas: [.mail: 1, .forwarding: 1, .drive: 1, .admin: 1]),
        AppsExplainer.Facts(apps: 48, people: 30, ai: 6, aiPeople: 9, broad: 7, aiBroad: 2, onePerson: 21, onePersonAI: 4, onePersonBroad: 3,
                            areas: [.mail: 4, .forwarding: 1, .drive: 3, .admin: 1, .cloud: 1]),
    ])
    func theModelWordsTheCounts(_ facts: AppsExplainer.Facts) async throws {
        let overview = try await AppsExplainer.explain(facts)
        print("overview:", overview)
        #expect(!overview.isEmpty)
    }
}
