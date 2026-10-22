import Foundation
import FoundationModels

/// The on-device model's explanation of a reading (docs/plans/2026-10-19-on-device-log-reader.md, R2): a short overview,
/// points that each cite the findings they're about, and checks to make, in words. The model is given the findings'
/// kinds, accounts, addresses and counts only, never the text the logs carry (a subject, a URL), which an attacker
/// writes; it never drafts a fix: the drafts are the reading's, made by code. A point citing no finding it was given is
/// dropped. On-device only (`SystemLanguageModel`): nothing leaves the Mac.
public enum LogExplainer {
    /// What the model wrote, its points kept only where they cite findings that exist.
    public struct Explanation: Sendable, Equatable {
        public struct Point: Sendable, Equatable {
            public let text: String
            public let cites: [String]
        }
        public let overview: String
        public let points: [Point]
        public let checks: [String]
    }

    /// The answer's shape, which guided generation holds the model to.
    @Generable
    public struct Answer: Sendable, Equatable {
        @Guide(description: "Two or three plain sentences: what happened, as the findings show it.")
        public var overview: String
        @Guide(description: "The findings that matter most, each explained in one sentence.", .maximumCount(8))
        public var points: [AnswerPoint]
        @Guide(description: "What the administrator should check next, each in a short sentence, in words, never a command.",
               .maximumCount(5))
        public var nextChecks: [String]

        public init(overview: String, points: [AnswerPoint], nextChecks: [String]) {
            self.overview = overview
            self.points = points
            self.nextChecks = nextChecks
        }
    }

    @Generable
    public struct AnswerPoint: Sendable, Equatable {
        @Guide(description: "One sentence about the findings cited.")
        public var text: String
        @Guide(description: "The IDs of the findings this sentence is about, such as F1.")
        public var cites: [String]

        public init(text: String, cites: [String]) {
            self.text = text
            self.cites = cites
        }
    }

    /// Asks a model for an answer: the on-device model, or a stand-in where there is none (tests, CI).
    public protocol Asking: Sendable {
        func answer(instructions: String, prompt: String) async throws -> Answer
    }

    /// The system's on-device model.
    public struct OnDevice: Asking {
        public init() {}

        public func answer(instructions: String, prompt: String) async throws -> Answer {
            let session = LanguageModelSession(model: .default, instructions: instructions)
            return try await session.respond(to: prompt, generating: Answer.self, options: GenerationOptions(temperature: 0.2)).content
        }
    }

    /// Whether the on-device model can answer now, and if not, why, in words.
    public static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.deviceNotEligible): "This Mac can't run Apple's on-device model."
        case .unavailable(.appleIntelligenceNotEnabled): "Apple Intelligence is off: turn it on in System Settings to have the logs explained."
        case .unavailable(.modelNotReady): "The on-device model is still being set up (downloading). Try again in a while."
        case .unavailable: "The on-device model isn't available."
        }
    }

    /// The model's standing instructions.
    static let instructions = """
        You explain the findings of a security log review to an IT administrator, in plain English. The findings were \
        found by rules in code; use only them, and never invent an account, an address, an event or a fix. Each point \
        cites the IDs of the findings it is about. Suggest checks in words; never write a command. Fixes are already \
        drafted for the administrator to review: say which finding each is for, nothing more.
        """

    /// What each kind of finding means, for the model.
    static func meaning(_ kind: LogReading.Finding.Kind) -> String {
        switch kind {
        case .signedInFromSuspect: "these accounts signed in (to Google or another app through it), granted an app or changed "
            + "settings from a suspect address"
        case .exportedFromSuspect: "these accounts' data was exported with Google Takeout from a suspect address"
        case .appFromSuspect: "an app acted for these accounts from a suspect address"
        case .actedFromSuspect: "these accounts used other Google services (Gemini, Drive, Contacts…) from a suspect address"
        case .agentActed: "an AI agent acted on these people's behalf"
        case .chatFromSuspect: "these accounts posted Chat messages from a suspect address"
        case .mailFromSuspect: "an email went through Gmail from a suspect address (its subject is shown to the administrator)"
        case .passwordOnPhishingSite: "Chrome saw these accounts' passwords typed on a phishing site"
        case .failedFromSuspect: "a suspect address tried these accounts' passwords and failed: they may have typed them into a fake page"
        case .afterLock: "a suspect address was active after the account was locked"
        case .pastPhishingWarning: "these people went past Chrome's phishing warning"
        case .passwordOnOtherSite: "Chrome saw these accounts' passwords used on another website"
        case .breachedPassword: "Chrome found one of these people's passwords in a data breach"
        case .sharedAddress: "many accounts signed in from a flagged address, which may be an office's or a VPN's"
        case .suspectAddress: "an address Google flagged, or the one the administrator named"
        }
    }

    /// The prompt: each finding's ID, meaning, accounts, addresses, count and drafted fixes. Never its words, which can
    /// hold a subject or URL an attacker wrote.
    static func prompt(_ reading: LogReading.Reading) -> String {
        var lines = ["Findings from \(reading.events) log events:"]
        for finding in reading.findings.prefix(30) {
            var line = "\(finding.id): \(meaning(finding.kind))."
            if !finding.accounts.isEmpty { line += " Accounts: " + finding.accounts.prefix(10).joined(separator: ", ") + "." }
            if !finding.addresses.isEmpty { line += " Addresses: " + finding.addresses.prefix(5).joined(separator: ", ") + "." }
            line += " Events: \(finding.events)."
            let fixes = finding.drafts.map { draft -> String in
                switch draft {
                case .secureAccount(let person): "secure \(person)"
                case .pullEmail: "pull that email from every mailbox"
                }
            }
            if !fixes.isEmpty { line += " Drafted fix: " + fixes.joined(separator: "; ") + "." }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The model's explanation of `reading`, each point kept only if it cites findings that exist (citing unknown ones
    /// dropped from it), and every text trimmed.
    public static func explain(_ reading: LogReading.Reading, using model: some Asking = OnDevice()) async throws -> Explanation {
        let answer = try await model.answer(instructions: instructions, prompt: prompt(reading))
        let known = Set(reading.findings.map(\.id))
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let points = answer.points.compactMap { point -> Explanation.Point? in
            let cites = point.cites.map(trimmed).filter(known.contains)
            guard !cites.isEmpty, !trimmed(point.text).isEmpty else { return nil }
            return Explanation.Point(text: trimmed(point.text), cites: cites)
        }
        return Explanation(overview: trimmed(answer.overview), points: points, checks: answer.nextChecks.map(trimmed).filter { !$0.isEmpty })
    }
}
