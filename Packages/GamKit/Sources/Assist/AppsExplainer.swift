import Foundation
import FoundationModels

/// The on-device model's wording of every account's connected apps (Reports): counts and kinds code made, never an app's
/// name or what it asked for, which the app's maker (or an attacker) wrote. Nothing here can hold that text: the facts are
/// numbers and `Area`s. The model words; it doesn't count, decide or advise: it writes a few sentences, and one holding a
/// number the facts don't, in digits or words, is dropped. On-device only (`SystemLanguageModel`): nothing leaves the Mac.
public enum AppsExplainer {
    /// A kind of broad access (GamEngine's `ConnectedApps.Area`, by its raw value).
    public enum Area: String, Sendable, CaseIterable {
        case mail, forwarding, drive, admin, cloud

        var words: String {
            switch self {
            case .mail: "all of Gmail or reading and changing mail"
            case .forwarding: "Gmail forwarding and delegates"
            case .drive: "all of Drive"
            case .admin: "admin access"
            case .cloud: "Google Cloud"
            }
        }
    }

    /// What every account's apps add up to (GamEngine's `ConnectedApps.Summary`): counts only. Not the most people who
    /// granted one app, which the model read as other things ("two of them had broad access").
    public struct Facts: Sendable, Equatable {
        public let apps, people, ai, aiPeople, broad, aiBroad, onePerson, onePersonAI, onePersonBroad: Int
        public let areas: [Area: Int]

        public init(apps: Int, people: Int, ai: Int, aiPeople: Int, broad: Int, aiBroad: Int, onePerson: Int, onePersonAI: Int,
                    onePersonBroad: Int, areas: [Area: Int]) {
            (self.apps, self.people, self.ai, self.aiPeople, self.broad, self.aiBroad) = (apps, people, ai, aiPeople, broad, aiBroad)
            (self.onePerson, self.onePersonAI, self.onePersonBroad, self.areas) = (onePerson, onePersonAI, onePersonBroad, areas)
        }

        /// Every number the prompt gives: the only ones the model's sentences may hold.
        var numbers: Set<Int> {
            Set([apps, people, ai, aiPeople, broad, aiBroad, onePerson, onePersonAI, onePersonBroad] + areas.values)
        }
    }

    /// The answer's shape, which guided generation holds the model to: a few sentences, each checked on its own.
    @Generable
    public struct Answer: Sendable, Equatable {
        @Guide(description: "Two or three short, plain sentences: what the counts say about the apps people have connected.",
               .maximumCount(3))
        public var sentences: [String]

        public init(sentences: [String]) {
            self.sentences = sentences
        }
    }

    /// Asks a model for an answer: the on-device model, or a stand-in where there is none (tests, CI).
    public protocol Asking: Sendable {
        func answer(instructions: String, prompt: String) async throws -> Answer
    }

    /// The system's on-device model, its answer capped: unbounded, it once wrote until its context was full.
    public struct OnDevice: Asking {
        public init() {}

        public func answer(instructions: String, prompt: String) async throws -> Answer {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return try await session.respond(to: prompt, generating: Answer.self,
                                             options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 400)).content
        }
    }

    /// Whether the on-device model can answer now, and if not, why, in words.
    public static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off: turn it on in System Settings to have the summary explained."
        case .unavailable(.modelNotReady): "The on-device model is still being set up (downloading). Try again in a while."
        case .unavailable: "The on-device model isn't available."
        }
    }

    /// The model's standing instructions.
    static let instructions = """
        You explain to an IT administrator, in plain English, what the apps their organization's people have connected to \
        their Google accounts add up to. The counts were made by code and are given as sentences; reword them, keeping each \
        number with the group it is about, and add nothing. You aren't told the apps' names, so never name or guess one. \
        Write every number in digits, and only numbers you were given. An app is counted as AI because its name looks like \
        an AI assistant's or agent's. Say only the kinds of broad access you were given, as they were given. Never call an \
        app safe or malicious, never advise, and never write a command.
        """

    /// The prompt: the counts and kinds as whole sentences, never a name or a scope. Each sentence says one thing about one
    /// group, with a zero said as none: given bare counts ("People who granted one of those: 1", "0 of them with broad
    /// access"), the model tied them to the wrong group.
    static func prompt(_ facts: Facts) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var lines = ["\(count(facts.apps, "app is", "apps are")) connected, granted by \(count(facts.people, "person", "people")) in all."]
        if facts.ai == 0 {
            lines.append("No app's name looks like an AI assistant's or agent's.")
        } else {
            lines.append("\(count(facts.ai, "app has a name", "apps have names")) that look like an AI assistant's or agent's, granted "
                         + "by \(count(facts.aiPeople, "person", "people")) in all. "
                         + (facts.aiBroad == 0 ? "None of them has broad access." : "\(facts.aiBroad) of them \(facts.aiBroad == 1 ? "has" : "have") broad access."))
        }
        lines.append(facts.broad == 0 ? "No app has broad access."
                     : "\(count(facts.broad, "app has", "apps have")) broad access: "
                        + Area.allCases.compactMap { area in facts.areas[area].map { "\($0) to \(area.words)" } }.joined(separator: ", ") + ".")
        if facts.onePerson > 0 {
            let among = [facts.onePersonAI > 0 ? "\(facts.onePersonAI) with a name like an AI's" : nil,
                         facts.onePersonBroad > 0 ? "\(facts.onePersonBroad) with broad access" : nil].compactMap { $0 }
            lines.append("\(count(facts.onePerson, "app was", "apps were")) granted by just one person each"
                         + (among.isEmpty ? "." : ": " + among.joined(separator: " and ") + "."))
        }
        return "Every account's connected apps, counted by code (suspended accounts left out):\n" + lines.joined(separator: "\n")
    }

    /// Numbers the model may write as words, for the check that it wrote only the facts'.
    static let numberWords = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                              "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                              "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "single": 1, "both": 2]

    /// The model's wording of `facts`: its sentences, each kept only if every number in it, in digits or words, is one of the
    /// facts' (a miscount is dropped, never shown), trimmed and joined.
    public static func explain(_ facts: Facts, using model: some Asking = OnDevice()) async throws -> String {
        let answer = try await model.answer(instructions: instructions, prompt: prompt(facts))
        let known = facts.numbers
        func holds(_ text: String) -> Bool {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).compactMap { numberWords[String($0)] }
            return text.matches(of: /\d+/).allSatisfy { Int($0.output).map(known.contains) ?? false } && words.allSatisfy(known.contains)
        }
        return answer.sentences.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && holds($0) }
            .joined(separator: " ")
    }
}
