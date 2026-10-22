import Foundation
import Testing
@testable import Assist

/// The log reader (docs/plans/2026-10-19-on-device-log-reader.md): each rule with a case that fires and one that must
/// not, the drafts it points to, and the model's explanation held to the findings it was given.
@Suite("Log reading")
struct LogReadingTests {
    static let attacker = "198.51.100.23", office = "203.0.113.50"

    static func event(_ log: String, _ who: String, _ name: String, ip: String = "", flagged: Bool = false, at minute: Int = 0,
                      _ parameters: [String: String] = [:]) -> LogReading.Event {
        LogReading.Event(log: log, time: Date(timeIntervalSince1970: 1_792_400_000 + Double(minute) * 60), who: who, event: name, ip: ip,
                         flagged: flagged, parameters: parameters)
    }

    /// carol@ taken over from the attacker's address, dana@ signed in from it too, erin@'s password tried from it; alice@
    /// at the office. The phish went out from the attacker's address; Chrome saw carol@ type her password on it and dana@
    /// go past its warning.
    static let incident: [LogReading.Event] = [
        event("login", "carol@example.com", "suspicious_login", ip: attacker, flagged: true, at: 10),
        event("login", "carol@example.com", "login_success", ip: attacker, flagged: true, at: 11),
        event("token", "carol@example.com", "authorize", ip: attacker, at: 12, ["app_name": "Mail Sync Pro"]),
        event("login", "dana@example.com", "login_success", ip: attacker, at: 20),
        event("login", "erin@example.com", "login_failure", ip: attacker, at: 25),
        event("login", "alice@example.com", "login_success", ip: office, at: 5),
        event("gmail", "carol@example.com", "delivery", ip: attacker, at: 30,
              ["message_info.subject": "Shared file", "message_info.rfc2822_message_id": "<phish-1@mail.example.com>"]),
        event("chrome", "carol@example.com", "PASSWORD_REUSE", flagged: true, at: 8,
              ["EVENT_REASON": "PASSWORD_REUSED_PHISHING_URL", "TRIGGER_USER": "carol@example.com",
               "URL": "https://login-check.example.net/signin"]),
        event("chrome", "dana@example.com", "UNSAFE_SITE_VISIT", flagged: true, at: 9,
              ["EVENT_RESULT": "BYPASSED", "URL": "https://login-check.example.net/view"]),
    ]

    @Test func anIncidentReadsAsItsFindingsMostSeriousFirst() {
        let reading = LogReading.read(Self.incident)
        #expect(reading.findings.map(\.kind) == [.signedInFromSuspect, .signedInFromSuspect, .mailFromSuspect, .passwordOnPhishingSite,
                                                 .failedFromSuspect, .pastPhishingWarning, .suspectAddress])
        #expect(reading.findings.map(\.id) == ["F1", "F2", "F3", "F4", "F5", "F6", "F7"])
        #expect(reading.findings[0].words == "carol@example.com signed in to Google and granted an app access from 198.51.100.23.")
        #expect(reading.findings[2].words == "“Shared file” (<phish-1@mail.example.com>) went through Gmail from 198.51.100.23.")
        #expect(reading.drafts == [.secureAccount("carol@example.com"), .secureAccount("dana@example.com"),
                                   .pullEmail(messageID: "<phish-1@mail.example.com>", subject: "Shared file"),
                                   .secureAccount("erin@example.com")])
        #expect(!reading.findings.contains { $0.accounts.contains("alice@example.com") }, "the office's address is no suspect")
        #expect(reading.findings[5].drafts.isEmpty, "going past a warning is said, not fixed")
    }

    /// Many accounts signing in from a flagged address is likely an office's or a VPN's: said, nothing drafted. The one the
    /// operator pulled by is theirs to call the attacker's.
    @Test func aSharedAddressDraftsNothingUnlessTheOperatorNamedIt() {
        let everyone = (1...11).map { Self.event("login", "user\($0)@example.com", "login_success", ip: Self.office, at: $0) }
        let flagged = everyone + [Self.event("login", "user1@example.com", "suspicious_login", ip: Self.office, flagged: true)]
        let reading = LogReading.read(flagged)
        #expect(reading.findings.map(\.kind) == [.sharedAddress] && reading.drafts.isEmpty)
        let named = LogReading.read(flagged, context: LogReading.Context(pulledBy: Self.office))
        #expect(named.drafts.count == 11)
    }

    /// A person's own failed challenge at the office is flagged, but isn't Google calling a sign-in someone else's: the
    /// office's address stays no suspect, and its mistyped passwords draft nothing.
    @Test func aWeakFlagMakesNoSuspect() {
        let office = [Self.event("login", "bob@example.com", "login_challenge", ip: Self.office, flagged: true),
                      Self.event("login", "bob@example.com", "login_failure", ip: Self.office),
                      Self.event("login", "alice@example.com", "login_success", ip: Self.office)]
        #expect(LogReading.read(office).findings.isEmpty)
    }

    @Test func aLongSubjectIsCutInItsButton() {
        let title = LogReading.Draft.pullEmail(messageID: "<x@example.com>", subject: String(repeating: "Urgent ", count: 20)).title
        #expect(title.count < 80 && title.contains("…"))
    }

    /// No sign-in Google called suspicious and no address named: nothing is suspect, whatever the volume.
    @Test func nothingFlaggedIsNothingFound() {
        let quiet = Self.incident.map { LogReading.Event(log: $0.log, time: $0.time, who: $0.who, event: $0.event, ip: $0.ip, flagged: false,
                                                          parameters: $0.parameters) }.filter { $0.log != "chrome" && $0.event != "suspicious_login" }
        #expect(LogReading.read(quiet).findings.isEmpty)
    }

    /// A Chrome event that names only the computer's login ("carol") is no account: nothing is drafted for it.
    @Test func aComputerLoginNameIsNoAccount() {
        let reading = LogReading.read([Self.event("chrome", "carol", "PASSWORD_REUSE", ["EVENT_REASON": "PASSWORD_REUSED_PHISHING_URL"])])
        #expect(reading.findings.isEmpty)
    }

    /// The other ways an attacker uses an account: another app through Google (SAML), a Takeout export, Chat. Each from the
    /// attacker's address is found; the same from the office is not.
    @Test func samlTakeoutAndChatFromTheAttackersAddress() {
        let more = Self.incident + [
            Self.event("saml", "dana@example.com", "login_success", ip: Self.attacker, at: 40, ["application_name": "Payroll Portal"]),
            Self.event("takeout", "carol@example.com", "STARTED_USER_TAKEOUT", ip: Self.attacker, at: 41, ["PRODUCTS_REQUESTED": "Mail"]),
            Self.event("chat", "carol@example.com", "message_posted", ip: Self.attacker, at: 42),
            Self.event("takeout", "alice@example.com", "STARTED_USER_TAKEOUT", ip: Self.office, at: 43),
            Self.event("chat", "alice@example.com", "message_posted", ip: Self.office, at: 44),
        ]
        let reading = LogReading.read(more)
        #expect(reading.findings.first { $0.accounts == ["dana@example.com"] && $0.kind == .signedInFromSuspect }?.words
                == "dana@example.com signed in to Google and reached another app through Google (SAML) from 198.51.100.23.")
        let exported = reading.findings.filter { $0.kind == .exportedFromSuspect }
        #expect(exported.map(\.accounts) == [["carol@example.com"]] && exported.first?.drafts == [.secureAccount("carol@example.com")])
        #expect(exported.first?.words.contains("(Mail)") == true)
        #expect(reading.findings.filter { $0.kind == .chatFromSuspect }.map(\.accounts) == [["carol@example.com"]])
        #expect(!reading.findings.contains { $0.accounts.contains("alice@example.com") })
    }

    @Test func activityAfterTheLockIsSaid() {
        let locked = Date(timeIntervalSince1970: 1_792_400_000 + 15 * 60)
        let reading = LogReading.read(Self.incident, context: LogReading.Context(lockedAt: locked))
        let after = reading.findings.first { $0.kind == .afterLock }
        #expect(after?.events == 3 && after?.accounts == ["dana@example.com", "erin@example.com", "carol@example.com"])
        #expect(LogReading.read(Self.incident, context: LogReading.Context(lockedAt: .distantFuture)).findings.allSatisfy { $0.kind != .afterLock })
    }

    struct Stub: LogExplainer.Asking {
        let answer: LogExplainer.Answer
        func answer(instructions: String, prompt: String) async throws -> LogExplainer.Answer { answer }
    }

    /// The model's points stand only on findings it was given: one citing none, or only unknown ones, is dropped.
    @Test func theExplanationKeepsOnlyPointsCitingFindings() async throws {
        let reading = LogReading.read(Self.incident)
        let stub = Stub(answer: LogExplainer.Answer(overview: " carol@ was taken over. ", points: [
            LogExplainer.AnswerPoint(text: "carol signed in from the attacker.", cites: ["F1", "F99"]),
            LogExplainer.AnswerPoint(text: "Everyone is compromised.", cites: ["F99"]),
            LogExplainer.AnswerPoint(text: "Disable 2-Step Verification for all.", cites: []),
        ], nextChecks: ["Check dana's sent mail.", " "]))
        let explanation = try await LogExplainer.explain(reading, using: stub)
        #expect(explanation.overview == "carol@ was taken over.")
        #expect(explanation.points == [LogExplainer.Explanation.Point(text: "carol signed in from the attacker.", cites: ["F1"])])
        #expect(explanation.checks == ["Check dana's sent mail."])
    }

    /// The model never sees the text the logs carry (a subject, a URL), which an attacker writes.
    @Test func thePromptHoldsNoTextTheAttackerWrote() {
        let prompt = LogExplainer.prompt(LogReading.read(Self.incident))
        #expect(prompt.contains("F1:") && prompt.contains("carol@example.com") && prompt.contains(Self.attacker))
        #expect(!prompt.contains("Shared file") && !prompt.contains("login-check") && !prompt.contains("phish-1"))
    }
}

/// The real on-device model, by hand on a Mac that has it (`SWIFTGAMGUI_MODEL=1 swift test --filter OnDeviceModel`): CI has
/// none, and a model's answer isn't a fixed output to hold a test to. It checks the answer's shape and its citations.
@Suite("On-device model", .enabled(if: ProcessInfo.processInfo.environment["SWIFTGAMGUI_MODEL"] == "1" && LogExplainer.unavailable == nil))
struct OnDeviceModelTests {
    @Test func theModelExplainsTheIncidentCitingItsFindings() async throws {
        let reading = LogReading.read(LogReadingTests.incident)
        let explanation = try await LogExplainer.explain(reading)
        print("overview:", explanation.overview)
        for point in explanation.points { print("point:", point.text, point.cites) }
        for check in explanation.checks { print("check:", check) }
        #expect(!explanation.overview.isEmpty && !explanation.points.isEmpty)
        #expect(explanation.points.allSatisfy { !$0.cites.isEmpty })
    }
}
