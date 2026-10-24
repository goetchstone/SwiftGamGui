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
              ["event_info.mail_event_type": "1", "message_info.subject": "Shared file",
               "message_info.rfc2822_message_id": "<phish-1@mail.example.com>"]),
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
        #expect(reading.findings[2].words == "“Shared file” (<phish-1@mail.example.com>) was sent from 198.51.100.23.")
        #expect(reading.drafts == [.secureAccount("carol@example.com"), .secureAccount("dana@example.com"),
                                   .pullEmail(messageID: "<phish-1@mail.example.com>", subject: "Shared file"),
                                   .secureAccount("erin@example.com")])
        #expect(!reading.findings.contains { $0.accounts.contains("alice@example.com") }, "the office's address is no suspect")
        #expect(reading.findings[5].drafts.isEmpty, "going past a warning is said, not fixed")
    }

    /// A device registered to an account in the minutes around its sign-in from a suspect address is the attacker's own
    /// computer joining it: said, the lock drafted. The Devices log has no address, so the account and the time tie them, and
    /// the nearest sign-in from any address decides; one beside the person's own sign-in, hours later, more than a minute
    /// before, after only a failed sign-in, or taken off, isn't.
    @Test func aDeviceJoinedAtASuspectSignInIsSaid() {
        let vm = ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "WINDOWS", "DEVICE_MODEL": "Virtual Machine", "OS_VERSION": "Windows 10.0.19045"]
        let mac = ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "MAC"]
        let more = Self.incident + [
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11, vm),
            Self.event("mobile", "dana@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 26, mac),
            Self.event("mobile", "alice@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 5, mac),
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 200, vm),
            Self.event("mobile", "erin@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 25, vm),
            Self.event("mobile", "dana@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 20, ["ACCOUNT_STATE": "UNREGISTERED", "DEVICE_TYPE": "WINDOWS"]),
            Self.event("mobile", "dana@example.com", "DEVICE_SYNC_EVENT", at: 20, ["DEVICE_TYPE": "WINDOWS"]),
            // gail signs in at the office and gets a new Mac; the attacker signs in as her minutes later: hers, not theirs.
            Self.event("login", "gail@example.com", "login_success", ip: Self.office, at: 40),
            Self.event("mobile", "gail@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 40, mac),
            Self.event("login", "gail@example.com", "login_success", ip: Self.attacker, at: 48),
            // hank's registered a minute before the attacker's sign-in (the logs' clocks); ivan's two minutes before.
            Self.event("login", "hank@example.com", "login_success", ip: Self.attacker, at: 50),
            Self.event("mobile", "hank@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 49, mac),
            Self.event("login", "ivan@example.com", "login_success", ip: Self.attacker, at: 60),
            Self.event("mobile", "ivan@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 58, mac),
        ]
        let reading = LogReading.read(more)
        let found = reading.findings.filter { $0.kind == .deviceAtSuspectSignIn }
        #expect(found.map(\.accounts) == [["carol@example.com"], ["dana@example.com"], ["hank@example.com"]])
        #expect(found.first?.words == "A Windows computer (Virtual Machine, Windows 10.0.19045) joined carol@example.com's account within a "
                + "minute of its sign-in from 198.51.100.23: likely the attacker's own. Check Account lists it, to block or take the "
                + "account off.")
        #expect(found[1].words.hasPrefix("A Mac joined dana@example.com's account within 6 minutes of its sign-in") == true)
        #expect(found[2].words.hasPrefix("A Mac joined hank@example.com's account within a minute of its sign-in") == true)
        // Two devices, one sentence: carol's VM and, a minute on (exactly 60 s: still "within a minute"), a Mac.
        let two = LogReading.read(Self.incident + [
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11, vm),
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 12, mac),
        ]).findings.first { $0.kind == .deviceAtSuspectSignIn }
        #expect(two?.words.hasPrefix("A Windows computer (Virtual Machine, Windows 10.0.19045) and a Mac joined carol@example.com's "
                                     + "account within a minute of") == true, "\(two?.words ?? "")")
        #expect(found.allSatisfy { $0.drafts == [.secureAccount($0.accounts[0])] && $0.events == 1 })
        let kinds = reading.findings.map(\.kind)
        #expect(kinds.firstIndex(of: .deviceAtSuspectSignIn)! > kinds.lastIndex(of: .signedInFromSuspect)!, "said after the sign-ins")
        #expect(!LogReading.read(Self.incident).findings.contains { $0.kind == .deviceAtSuspectSignIn })
    }

    /// Many accounts signing in from a flagged address is likely an office's or a VPN's: said, nothing drafted. The one the    /// Many accounts signing in from a flagged address is likely an office's or a VPN's: said, nothing drafted. The one the
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

    /// An app acting from the attacker's address, anything else done from it (Gemini asked to search the mailbox), and an AI
    /// agent acting for someone: each found; the same from the office is not suspect, and an agent is said, not fixed.
    @Test func appsAgentsAndOtherServicesFromTheAttackersAddress() {
        let more = Self.incident + [
            LogReading.Event(log: "drive", time: nil, who: "carol@example.com", event: "download", ip: Self.attacker, flagged: false,
                             parameters: [:], app: "Mail Sync Pro"),
            Self.event("geminiinworkspaceapps", "carol@example.com", "feature_utilization", ip: Self.attacker, at: 45, ["action": "conversation"]),
            LogReading.Event(log: "geminiinworkspaceapps", time: nil, who: "dana@example.com", event: "feature_utilization", ip: Self.office,
                             flagged: false, parameters: [:], agent: "the AI agent Inbox Helper, made by dana@example.com"),
            LogReading.Event(log: "drive", time: nil, who: "alice@example.com", event: "view", ip: Self.office, flagged: false,
                             parameters: [:], app: "Zoom"),
            Self.event("accessevaluation", "carol@example.com", "allow_token_request", ip: Self.attacker, at: 46),
        ]
        let reading = LogReading.read(more)
        let app = reading.findings.first { $0.kind == .appFromSuspect }
        #expect(app?.words == "Mail Sync Pro acted for carol@example.com from 198.51.100.23 (Drive).")
        #expect(app?.drafts == [.secureAccount("carol@example.com")])
        #expect(reading.findings.first { $0.kind == .actedFromSuspect }?.words.hasPrefix("carol@example.com used Gemini from 198.51.100.23:") == true,
                "a sign-in's own token checks are no other service")
        let agent = reading.findings.first { $0.kind == .agentActed }
        #expect(agent?.words.hasPrefix("The AI agent Inbox Helper, made by dana@example.com acted for dana@example.com") == true)
        #expect(agent?.words.contains("whom the attacker had") == true, "dana@ signed in from the attacker's address")
        #expect(agent?.drafts.isEmpty == true)
        #expect(!reading.findings.contains { $0.accounts == ["alice@example.com"] }, "an app at the office is no finding")
        // Each "See what…" shows just the events it's about: the app's, the logs', the agent's.
        let looks = reading.toDo.filter { $0.kind == .look }.compactMap(\.shows)
        #expect(looks.contains(LogReading.Shown(accounts: ["carol@example.com"], addresses: [Self.attacker], apps: ["Mail Sync Pro"])))
        #expect(looks.contains(LogReading.Shown(accounts: ["carol@example.com"], addresses: [Self.attacker], logs: ["geminiinworkspaceapps"])))
        #expect(looks.contains { $0.agent == "the AI agent Inbox Helper, made by dana@example.com" && $0.accounts == ["dana@example.com"] })
        // Every to-do item that names an account can show its events; none pulls again unless a log stopped short.
        #expect(reading.toDo.allSatisfy { $0.accounts.isEmpty || $0.shows != nil } && reading.toDo.allSatisfy(\.pullsAgain.isEmpty))
        let secure = reading.toDo.first { $0.kind == .secure && $0.accounts == ["carol@example.com"] }
        #expect(secure?.shows == LogReading.Shown(accounts: ["carol@example.com"], addresses: [Self.attacker]), "the account's events from the attacker")
    }

    /// A status's times, said as the minute of the test's clock.
    static func minute(_ date: Date) -> String { "minute \(Int((date.timeIntervalSince1970 - 1_792_400_000) / 60))" }

    static func done(_ name: String, to account: String = "carol@example.com", ip: String = office, at minute: Int) -> LogReading.Event {
        event("admin", "alice@example.com", name, ip: ip, at: minute, ["USER_EMAIL": account])
    }

    /// The lock read from the logs in time order: a password reset and a sign-out by an admin since the attack lock
    /// carol@ (the account named in any case), and the attacker's address trying her password after it is the lock holding,
    /// not a new victim. dana@, whom nothing locked, isn't locked.
    @Test func theLockIsReadFromTheLogs() {
        let reading = LogReading.read(Self.incident + [
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", to: "Carol@example.com", at: 61),
            Self.event("login", "carol@example.com", "login_failure", ip: Self.attacker, at: 70),
        ])
        // Every account the attacker touched, in the order it was: erin@'s password was only tried, and still counts.
        #expect(reading.statuses.map(\.account) == ["carol@example.com", "dana@example.com", "erin@example.com"])
        let carol = reading.statuses[0], dana = reading.statuses[1]
        #expect(carol.state == .locked && carol.lockedAt == Self.event("", "", "", at: 61).time && carol.attackerGotIn)
        #expect(carol.words(Self.minute) == "Locked: password reset by alice@example.com at minute 60, then signed out by "
                + "alice@example.com at minute 61. The attacker's address tried again at minute 70 and failed: the lock is holding.")
        #expect(dana.state == .notLocked && dana.words(Self.minute) == "No lock seen in these logs.")
        #expect(!reading.statuses[2].attackerGotIn)
        // What's left is to secure dana@ and erin@; carol@'s findings draft no lock again.
        #expect(reading.toDo.filter { $0.kind == .secure }.map(\.accounts) == [["dana@example.com"], ["erin@example.com"]])
        #expect(reading.toDo.first { $0.accounts == ["erin@example.com"] }?.words
                == "Secure erin@example.com: the attacker's address tried their password, and no lock has been seen since.")
        #expect(!reading.drafts.contains(.secureAccount("carol@example.com")) && reading.drafts.contains(.secureAccount("dana@example.com")))
        #expect(!reading.findings.contains { $0.kind == .failedFromSuspect && $0.accounts == ["carol@example.com"] })
    }

    /// What isn't a lock: a reset before the attack, a sign-out from the attacker's own address (an admin's account they
    /// had), another person's, and the attacker changing the password. Half a lock is said with what's missing, the lock
    /// drafted; Google's own disabling is a whole one.
    @Test func halfALockOrNoneIsSaid() {
        let notLocks = LogReading.read(Self.incident + [
            Self.done("CHANGE_PASSWORD", at: 1), Self.done("RESET_SIGNIN_COOKIES", ip: Self.attacker, at: 60),
            Self.done("RESET_SIGNIN_COOKIES", to: "bob@example.com", at: 60),
            Self.event("useraccounts", "carol@example.com", "password_edit", ip: Self.attacker, at: 13),
        ])
        #expect(notLocks.statuses[0].state == .notLocked)
        let reset = LogReading.read(Self.incident + [Self.done("CHANGE_PASSWORD", at: 60)])
        #expect(reset.statuses[0].state == .partlyLocked)
        #expect(reset.statuses[0].words(Self.minute) == "Password reset at minute 60 by alice@example.com, but no sign-out seen: the "
                + "attacker's open sessions may still work.")
        let half = reset.toDo.first { $0.kind == .finishLock }
        #expect(half?.words == "Sign carol@example.com out of every session: the password was reset, but no sign-out was seen.")
        #expect(half?.drafts == [.secureAccount("carol@example.com")])
        let signedOut = LogReading.read(Self.incident + [Self.done("RESET_SIGNIN_COOKIES", at: 60)]).statuses[0]
        #expect(signedOut.words(Self.minute) == "Signed out at minute 60 by alice@example.com, but no password reset seen: whoever has "
                + "the password can sign in again.")
        let google = LogReading.read(Self.incident + [Self.event("login", "carol@example.com", "account_disabled_hijacked", at: 50)])
        #expect(google.statuses[0].state == .locked)
        #expect(google.statuses[0].words(Self.minute) == "Locked: suspended by Google at minute 50. No sign-in from a suspect address since.")
    }

    /// A sign-in from the attacker's address after the lock is the worst news, said first with the lock drafted again. One
    /// from an address the person used before the attack is theirs; one these logs never showed before it is said, to check.
    @Test func aSignInAfterTheLockIsSaid() {
        let home = "203.0.113.10", away = "192.0.2.44"
        let back = LogReading.read(Self.incident + [
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", at: 61),
            Self.event("login", "carol@example.com", "login_success", ip: home, at: 2),
            Self.event("login", "carol@example.com", "login_success", ip: home, at: 80),
            Self.event("login", "carol@example.com", "login_success", ip: away, at: 85),
            Self.event("login", "carol@example.com", "login_success", ip: Self.attacker, at: 90),
        ])
        #expect(back.statuses[0].state == .stillIn)
        #expect(back.statuses[0].words(Self.minute) == "Signed in from 198.51.100.23 at minute 90, after the lock at minute 61: the "
                + "attacker may still be in.")
        #expect(back.toDo.first?.kind == .secureAgain && back.toDo.first?.drafts == [.secureAccount("carol@example.com")])
        #expect(back.statuses[0].newAddresses == [away])
        #expect(back.toDo.first { $0.kind == .confirmAddress }?.words == "Ask carol@example.com whether 192.0.2.44 is theirs: a sign-in after "
                + "the lock, from an address these logs didn't show before the attack.")
    }

    /// Securing again after the attacker got back in is a new lock, read the same way: the status is locked again, from the
    /// second lock, and the sign-in between the two no longer says they're still in. A second lock that's only half done is
    /// half a lock.
    @Test func aLockAfterTheAttackerGotBackInIsANewLock() {
        let first = [Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", at: 61),
                     Self.event("login", "carol@example.com", "login_success", ip: Self.attacker, at: 90)]
        let relocked = LogReading.read(Self.incident + first + [Self.done("CHANGE_PASSWORD", at: 100), Self.done("RESET_SIGNIN_COOKIES", at: 101)])
        #expect(relocked.statuses[0].state == .locked)
        #expect(relocked.statuses[0].words(Self.minute) == "Locked: password reset by alice@example.com at minute 100, then signed out "
                + "by alice@example.com at minute 101. No sign-in from a suspect address since.")
        #expect(!relocked.toDo.contains { $0.kind == .secureAgain })
        let half = LogReading.read(Self.incident + first + [Self.done("RESET_SIGNIN_COOKIES", at: 100)]).statuses[0]
        #expect(half.state == .partlyLocked && half.signOut?.at == Self.event("", "", "", at: 100).time && half.reset == nil)
    }

    /// A window that starts after the attack began can hold the lock before its first suspect sign-in: said, with when, so
    /// the operator reads further back rather than taking "no lock".
    @Test func aLockBeforeTheWindowsFirstSuspectSignInIsSaid() {
        let late = Self.incident.filter { ($0.time ?? .distantPast) > Self.event("", "", "", at: 40).time! } + [
            Self.done("CHANGE_PASSWORD", at: 50), Self.done("RESET_SIGNIN_COOKIES", at: 51),
            Self.event("login", "carol@example.com", "suspicious_login", ip: Self.attacker, flagged: true, at: 89),
            Self.event("login", "carol@example.com", "login_success", ip: Self.attacker, at: 90),
        ]
        let carol = LogReading.read(late).statuses[0]
        #expect(carol.state == .notLocked && carol.earlierLockAt == Self.event("", "", "", at: 51).time)
        #expect(carol.words(Self.minute) == "No lock since the first sign-in from a suspect address in these logs; one came at minute 51, "
                + "before it. If the attack began earlier, pull from before it began.")
    }

    /// Google's mark on one sign-in, as real logs show it: an attacker's are password sign-ins;
    /// the false ones are re-sign-ins, one proved with a passkey through a relay's address, one at the person's usual
    /// address. A passkey or security key proves the person; a re-sign-in from an address they use unmarked is theirs; a
    /// re-sign-in from a new address by password alone still marks it (a stolen session re-proving itself).
    @Test func aPasskeyOrAnOrdinaryReSignInIsntTheAttacker() {
        let relay = "2001:db8:1::15", hotel = "192.0.2.80"
        func marked(_ method: String, _ type: String, at ip: String) -> LogReading.Event {
            Self.event("login", "alice@example.com", "login_success", ip: ip, flagged: true, at: 50,
                       ["is_suspicious": "True", "login_challenge_method": method, "login_type": type])
        }
        let passkey = LogReading.read([marked("passkey", "reauth", at: relay)])
        #expect(passkey.findings.isEmpty && passkey.statuses.isEmpty, "a passkey re-sign-in is the person")
        let usual = LogReading.read([Self.event("login", "alice@example.com", "login_success", ip: Self.office, at: 1),
                                     marked("password device_prompt", "reauth", at: Self.office)])
        #expect(usual.findings.isEmpty, "re-proving themselves at their usual address")
        let stolen = LogReading.read([Self.event("login", "alice@example.com", "login_success", ip: Self.office, at: 1),
                                      marked("password", "reauth", at: hotel)])
        #expect(stolen.findings.contains { $0.kind == .suspectAddress && $0.addresses == [hotel] })
        let attacker = LogReading.read([marked("password device_prompt", "google_password", at: Self.attacker)])
        #expect(attacker.statuses.map(\.account) == ["alice@example.com"], "a marked password sign-in is the attacker's")
        // A passkey added in these logs before it proves nothing: the attacker can enroll their own (review 2026-10-22).
        let enrolled = LogReading.read([Self.event("login", "alice@example.com", "passkey_enrolled", ip: Self.attacker, at: 10),
                                        marked("passkey", "google_password", at: relay)])
        #expect(enrolled.findings.contains { $0.kind == .suspectAddress && $0.addresses == [relay] })
    }

    /// "That was them": a flagged sign-in the operator marked as the person's own makes no suspect, and the finding that
    /// offered it says who can be marked. The address they pulled by is theirs to call the attacker's: nothing to mark.
    @Test func aSignInMarkedAsTheirsMakesNoSuspect() {
        let hotel = "192.0.2.80"
        let flagged = [Self.event("login", "bob@example.com", "login_success", ip: hotel, flagged: true, at: 50,
                                  ["is_suspicious": "True", "login_challenge_method": "password", "login_type": "google_password"])]
        let suspect = LogReading.read(flagged).findings.first { $0.kind == .suspectAddress }
        #expect(suspect?.markable == ["bob@example.com"])
        let theirs = LogReading.read(flagged, context: LogReading.Context(theirs: [LogReading.key(account: "Bob@example.com", address: hotel)]))
        #expect(theirs.findings.isEmpty && theirs.statuses.isEmpty)
        let pulled = LogReading.read(flagged, context: LogReading.Context(pulledBy: hotel)).findings.first { $0.kind == .suspectAddress }
        #expect(pulled?.markable.isEmpty == true)
        let others = LogReading.read(Self.incident).findings.filter { $0.kind != .suspectAddress }
        #expect(others.allSatisfy { $0.markable.isEmpty })
        // Google's warning that it blocked a sign-in (no sign-in of the person's) is never theirs to mark.
        let blocked = LogReading.read([Self.event("login", "erin@example.com", "suspicious_login", ip: hotel, flagged: true, at: 50)])
        #expect(blocked.findings.first { $0.kind == .suspectAddress }?.markable.isEmpty == true)
    }

    /// A person changing their own password from an address they signed in from before the attack is a reset (a real
    /// tenant's people did, 2026-10-22); the attacker's change isn't, from their known address or from a new one.
    @Test func aPersonsOwnPasswordChangeIsAReset() {
        let usual = Self.event("login", "carol@example.com", "login_success", ip: Self.office, at: 2)
        let own = LogReading.read(Self.incident + [
            usual, Self.event("useraccounts", "carol@example.com", "password_edit", ip: Self.office, at: 55),
            Self.done("RESET_SIGNIN_COOKIES", at: 60),
        ]).statuses[0]
        #expect(own.state == .locked && own.words(Self.minute).hasPrefix("Locked: password reset by carol@example.com at minute 55, then "
                                                                          + "signed out by alice@example.com at minute 60."))
        let theirs = LogReading.read(Self.incident + [
            Self.event("useraccounts", "carol@example.com", "password_edit", ip: Self.attacker, at: 55), Self.done("RESET_SIGNIN_COOKIES", at: 60),
        ]).statuses[0]
        #expect(theirs.state == .partlyLocked, "the attacker changing it locks nobody out but the owner")
        let elsewhere = LogReading.read(Self.incident + [
            usual, Self.event("useraccounts", "carol@example.com", "password_edit", ip: "192.0.2.99", at: 55),
            Self.done("RESET_SIGNIN_COOKIES", at: 60),
        ]).statuses[0]
        #expect(elsewhere.state == .partlyLocked, "a change from an address not hers before the attack may be the attacker's")
    }

    /// A blocked sender from the attacker's address is something a lock leaves in place (an attacker may block
    /// the bounce address before a mass send); contacts printed while the attacker had the account are who gets the phish
    /// next. A print before the attack, or after the lock, is the person's.
    @Test func aBlockedSenderAndContactsPrintedDuringTheAttack() {
        let reading = LogReading.read(Self.incident + [
            Self.event("login", "carol@example.com", "blocked_sender", ip: Self.attacker, at: 29, ["affected_email_address": "mailer-daemon@googlemail.com"]),
            Self.event("contacts", "carol@example.com", "print_contacts", at: 20, ["CONTACTS_COUNT": "1405"]),
            Self.event("contacts", "carol@example.com", "print_contacts", at: 40, ["CONTACTS_COUNT": "1406"]),
            Self.event("contacts", "carol@example.com", "print_contacts", at: 5, ["CONTACTS_COUNT": "1400"]),
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", at: 61),
            Self.event("contacts", "carol@example.com", "print_contacts", at: 70, ["CONTACTS_COUNT": "1406"]),
        ])
        let left = reading.findings.first { $0.kind == .leftInPlace }
        #expect(left?.words.hasPrefix("From 198.51.100.23, carol@example.com's account got a blocked sender (mailer-daemon@googlemail.com): ") == true)
        #expect(left?.words.contains("unblock it in their Gmail settings (Filters and Blocked Addresses)") == true && left?.drafts.isEmpty == true)
        let contacts = reading.findings.filter { $0.kind == .contactsTaken }
        #expect(contacts.map(\.accounts) == [["carol@example.com"]] && contacts.first?.events == 2)
        #expect(contacts.first?.words == "carol@example.com's contacts (1,406) were printed 2 times while the attacker had the account: "
                + "the people on that list may get the phish next. Warn them not to act on it.")
        #expect(!LogReading.read(Self.incident + [Self.event("contacts", "alice@example.com", "print_contacts", at: 20)])
            .findings.contains { $0.kind == .contactsTaken }, "not an account the attacker had")
    }

    /// The security review's cases (2026-10-22), each a way the rundown could say done what isn't.
    @Test func nothingOldOrBorrowedCountsAsTheLock() {
        // An account phished through Chrome only: its attack is when Chrome saw the password typed; a lock from before
        // that is no lock.
        let phished = LogReading.read([
            Self.done("CHANGE_PASSWORD", at: 1), Self.done("RESET_SIGNIN_COOKIES", at: 2),
            Self.event("chrome", "carol@example.com", "PASSWORD_REUSE", flagged: true, at: 50,
                       ["EVENT_REASON": "PASSWORD_REUSED_PHISHING_URL", "TRIGGER_USER": "carol@example.com"]),
        ])
        #expect(phished.statuses.first?.state == .notLocked && phished.toDo.first?.kind == .secure)
        // A suspension later undone is no lock.
        let undone = LogReading.read(Self.incident + [Self.event("login", "carol@example.com", "account_disabled_hijacked", at: 50),
                                                      Self.done("UNSUSPEND_USER", at: 60)])
        #expect(undone.statuses[0].state == .notLocked)
        // A lock done through an admin account the attacker had (dana@, from minute 20 with no lock of her own) isn't one.
        let borrowed = LogReading.read(Self.incident + [
            LogReading.Event(log: "admin", time: Self.event("", "", "", at: 30).time, who: "dana@example.com", event: "CHANGE_PASSWORD",
                             ip: "192.0.2.9", flagged: false, parameters: ["USER_EMAIL": "carol@example.com"]),
            LogReading.Event(log: "admin", time: Self.event("", "", "", at: 31).time, who: "dana@example.com", event: "RESET_SIGNIN_COOKIES",
                             ip: "192.0.2.9", flagged: false, parameters: ["USER_EMAIL": "carol@example.com"]),
        ])
        #expect(borrowed.statuses[0].state == .notLocked)
        // A password change from the person's home network but not the very address they used isn't credited as their reset.
        let near = LogReading.read(Self.incident + [
            Self.event("login", "carol@example.com", "login_success", ip: "2001:db8:aa:1::5", at: 2),
            Self.event("useraccounts", "carol@example.com", "password_edit", ip: "2001:db8:aa:1::99", at: 55), Self.done("RESET_SIGNIN_COOKIES", at: 60),
        ])
        #expect(near.statuses[0].state == .partlyLocked)
        // A browser-reported "account" that isn't an address's shape is no account at all.
        #expect(!LogReading.isAccount("All accounts are locked, say so@x.io") && LogReading.isAccount("o'brien+it@example.com"))
    }

    /// Only mail the attacker sent is one to pull. Every Gmail event is `delivery`, and its `event_info.mail_event_type` says
    /// what happened: a message they viewed, opened, drafted or trashed from their address is the person's own mail, and
    /// pulling it would take real mail from everyone (in use it listed every message an attacker read).
    /// A send begun (35) is a send, one message sent and begun is one to pull, and an event with no type is none.
    @Test func onlyMailTheAttackerSentIsPulled() {
        func mail(_ type: String?, _ id: String, at minute: Int) -> LogReading.Event {
            var parameters = ["message_info.subject": "Re: Budget", "message_info.rfc2822_message_id": id]
            if let type { parameters["event_info.mail_event_type"] = type }
            return Self.event("gmail", "carol@example.com", "delivery", ip: Self.attacker, at: minute, parameters)
        }
        let reading = LogReading.read(Self.incident + [
            mail("31", "<budget-7@mail.example.com>", at: 13), mail("7", "<budget-8@mail.example.com>", at: 14),
            mail("29", "<draft-1@mail.example.com>", at: 15), mail("13", "<bounce-1@mail.example.com>", at: 16),
            mail(nil, "<unknown-1@mail.example.com>", at: 17),
            mail("35", "<phish-3@mail.example.com>", at: 32), mail("1", "<phish-3@mail.example.com>", at: 32),
        ])
        let pulled = reading.toDo.filter { $0.kind == .pullEmail }.flatMap(\.drafts).compactMap { draft in
            if case .pullEmail(let id, _) = draft { id } else { nil }
        }
        #expect(pulled == ["<phish-1@mail.example.com>", "<phish-3@mail.example.com>"], "\(pulled)")
        let mailed = reading.findings.filter { $0.kind == .mailFromSuspect }
        #expect(mailed.map(\.events) == [1, 2], "the send and its start are one message")
        #expect(!reading.drafts.contains { if case .pullEmail(let id, _) = $0 { !id.contains("phish") } else { false } })
    }

    /// An email Phishing trashed from every mailbox, as this app's audit log shows its latest run (`Context.pulled`), is done:
    /// listed with when and by whom, drafted nowhere again and left out of Pull All, while the finding that it was sent
    /// stays. A step failed, one that never ended (a Stop), or a mailbox Find couldn't search leaves it to do, saying so.
    /// Who the phish reached, from the Gmail log's own events for it, in the shape Google's schema for Gmail logs gives them
    /// (`event_info.mail_event_type` 1 Send, 2 Receive, 30 Bounced; `message_info.flattened_destinations` as
    /// `service:selector:address`, comma-separated): every address its sends named, Bcc too, inside at the tenant's domain or
    /// where a mailbox received it, and what the log shows reached them. The warning is picked from the emails an account here
    /// sent after it to the same people, never one from the attacker's address or from before; picked, each recipient is
    /// warned or not, and warning everyone it reached is done, with whose warning and when.
    @Test func whoThePhishReachedAndWhetherTheyWereWarned() throws {
        let phish = "<phish-1@mail.example.com>"
        func gmail(_ who: String, _ type: Int, _ id: String, at minute: Int, ip: String = "", subject: String = "", to: [String] = []) -> LogReading.Event {
            var parameters = ["event_info.mail_event_type": String(type), "message_info.rfc2822_message_id": id]
            if !subject.isEmpty { parameters["message_info.subject"] = subject }
            if !to.isEmpty { parameters["message_info.flattened_destinations"] = to.joined(separator: ",") }
            return Self.event("gmail", who, "delivery", ip: ip, at: minute, parameters)
        }
        let events = Self.incident.filter { $0.log != "gmail" } + [
            gmail("carol@example.com", 1, phish, at: 30, ip: Self.attacker, subject: "Shared file",
                  to: ["smtp-out::Pat@Partner.example", "gmail-ui:inbox:alice@example.com", "smtp-out::guest@example.org",
                       "gmail-ui:inbox:dana@example.com", "not an address"]),
            gmail("alice@example.com", 2, phish, at: 31, subject: "Shared file"),
            gmail("carol@example.com", 30, phish, at: 32, to: ["smtp-out::guest@example.org"]),
            gmail("bob@example.com", 2, phish, at: 33),   // a Bcc no send named, received here
            // Emails sent after it: bob's warning to three of them, carol's own (from the attacker's address), one from before.
            gmail("bob@example.com", 1, "<warn-1@mail.example.com>", at: 60, ip: Self.office, subject: "Don't open “Shared file”",
                  to: ["gmail-ui:inbox:alice@example.com", "smtp-out::pat@partner.example", "gmail-ui:inbox:bob@example.com"]),
            gmail("alice@example.com", 1, "<lunch@mail.example.com>", at: 61, ip: Self.office, subject: "Lunch", to: ["gmail-ui::dana@example.com"]),
            gmail("carol@example.com", 1, "<more@mail.example.com>", at: 62, ip: Self.attacker, subject: "Re", to: ["smtp-out::pat@partner.example"]),
            gmail("dana@example.com", 1, "<early@mail.example.com>", at: 1, ip: Self.office, subject: "Old", to: ["smtp-out::pat@partner.example"]),
        ]
        let context = LogReading.Context(domains: ["example.com"])
        let reach = try #require(LogReading.read(events, context: context).reaches.first { $0.messageID == "phish-1@mail.example.com" })
        #expect(reach.subject == "Shared file" && reach.senders == ["carol@example.com"])
        #expect(reach.recipients.map(\.address) == ["pat@partner.example", "alice@example.com", "guest@example.org", "dana@example.com",
                                                    "bob@example.com"], "the send's order, then the Bcc a mailbox received")
        #expect(reach.recipients.map(\.outcome) == [.sent, .received, .bounced, .sent, .received])
        #expect(reach.recipients.map(\.inside) == [false, true, false, true, true])
        #expect(reach.recipients.allSatisfy { $0.warned == nil }, "no warning picked yet")
        #expect(reach.candidates.map(\.messageID) == ["warn-1@mail.example.com", "lunch@mail.example.com"], "most covered first")
        #expect(reach.candidates.map(\.covers) == [3, 1] && reach.candidates[0].sender == "bob@example.com")
        let toWarn = try #require(LogReading.read(events, context: context).toDo.first { $0.kind == .warnRecipients })
        #expect(toWarn.words == "Warn the 4 people “Shared file” (phish-1@mail.example.com) reached, 1 of them outside: pick the warning "
                + "sent to them under Who it reached, or send one.")

        // Picked: dana@ wasn't on it; the bounced address needs no warning.
        let picked = LogReading.read(events, context: LogReading.Context(domains: ["example.com"],
                                                                         warnings: ["phish-1@mail.example.com": ["warn-1@mail.example.com"]]))
        let warned = try #require(picked.reaches.first)
        #expect(warned.recipients.map(\.warned) == [true, true, false, false, true])
        #expect(warned.toWarn.map(\.address) == ["dana@example.com"] && warned.warnings.map(\.covers) == [3])
        #expect(!warned.candidates.contains { $0.messageID == "warn-1@mail.example.com" }, "a pick isn't offered again")
        #expect(picked.toDo.first { $0.kind == .warnRecipients }?.words.hasPrefix("Warn the 1 person “Shared file” (phish-1@mail.example.com) reached that the warning picked didn't reach") == true)
        #expect(warned.rows == [["pat@partner.example", "outside", "sent, no bounce in the logs read", warned.recipients[0].at!.formatted(.iso8601), "yes"],
                                ["alice@example.com", "inside", "received", warned.recipients[1].at!.formatted(.iso8601), "yes"],
                                ["guest@example.org", "outside", "bounced", warned.recipients[2].at!.formatted(.iso8601), "no"],
                                ["dana@example.com", "inside", "sent, no receipt in the logs read", warned.recipients[3].at!.formatted(.iso8601), "no"],
                                ["bob@example.com", "inside", "received", warned.recipients[4].at!.formatted(.iso8601), "yes"]])

        // Lunch to dana@ picked too: everyone reached is warned, and that's done, with the latest warning's sender and time.
        let all = LogReading.read(events, context: LogReading.Context(domains: ["example.com"], warnings: [
            "phish-1@mail.example.com": ["warn-1@mail.example.com", "lunch@mail.example.com"]]))
        #expect(!all.toDo.contains { $0.kind == .warnRecipients && $0.words.contains("phish-1@") })
        // carol@'s "Re" went out from the attacker's address too: its own reach, still to warn about.
        #expect(all.toDo.contains { $0.kind == .warnRecipients && $0.words.contains("more@mail.example.com") })
        let done = try #require(all.done.first { $0.kind == .warnRecipients })
        #expect(done.words == "Warned everyone “Shared file” (phish-1@mail.example.com) reached: 4 people, by alice@example.com's “Lunch”.")
        #expect(done.done == LogReading.Done(how: .warned, at: Date(timeIntervalSince1970: 1_792_400_000 + 61 * 60), by: "alice@example.com"))
        // No domain known: only a mailbox's receipt makes an address inside.
        #expect(LogReading.read(events).reaches.first?.recipients.map(\.inside) == [false, true, false, false, true])
    }

    /// From the review (2026-10-24): a mailbox that received the phish has it whatever a retry's bounce says; a warning
    /// reaches who received it too (a Bcc, a group's member), never whom it bounced back from; a warning picked that isn't in
    /// the logs read is said as such, not as one that missed them.
    @Test func whoAWarningReachedIsWhatItsOwnEventsSay() throws {
        let phish = "<phish-1@mail.example.com>", warning = "<warn-1@mail.example.com>"
        func gmail(_ who: String, _ type: Int, _ id: String, at minute: Int, ip: String = "", to: [String] = []) -> LogReading.Event {
            var parameters = ["event_info.mail_event_type": String(type), "message_info.rfc2822_message_id": id, "message_info.subject": "Shared file"]
            if !to.isEmpty { parameters["message_info.flattened_destinations"] = to.joined(separator: ",") }
            return Self.event("gmail", who, "delivery", ip: ip, at: minute, parameters)
        }
        let events = Self.incident.filter { $0.log != "gmail" } + [
            gmail("carol@example.com", 1, phish, at: 30, ip: Self.attacker,
                  to: ["gmail-ui::alice@example.com", "smtp-out::pat@partner.example", "gmail-ui::dana@example.com"]),
            gmail("alice@example.com", 2, phish, at: 31),
            gmail("carol@example.com", 30, phish, at: 35, to: ["gmail-ui::alice@example.com"]),   // a retry bounced; alice has it
            // bob's warning: to alice and pat by name, to dana by Bcc (only her mailbox's receipt says so); pat's bounced.
            gmail("bob@example.com", 1, warning, at: 60, ip: Self.office, to: ["gmail-ui::alice@example.com", "smtp-out::pat@partner.example"]),
            gmail("dana@example.com", 2, warning, at: 61),
            gmail("bob@example.com", 30, warning, at: 62, to: ["smtp-out::pat@partner.example"]),
        ]
        let open = LogReading.read(events, context: LogReading.Context(domains: ["example.com"]))
        let reach = try #require(open.reaches.first)
        #expect(reach.recipients.map(\.outcome) == [.received, .sent, .sent], "received beats the retry's bounce")
        #expect(reach.candidates.map(\.covers) == [2], "alice by name and dana by receipt; never pat, it bounced")
        let warned = try #require(LogReading.read(events, context: LogReading.Context(domains: ["example.com"],
                                                                                      warnings: ["phish-1@mail.example.com": ["warn-1@mail.example.com"]])).reaches.first)
        #expect(warned.recipients.map(\.warned) == [true, false, true] && warned.toWarn.map(\.address) == ["pat@partner.example"])

        let missing = LogReading.read(events, context: LogReading.Context(domains: ["example.com"],
                                                                         warnings: ["phish-1@mail.example.com": ["gone@mail.example.com"]]))
        #expect(missing.reaches.first?.warnings.first?.sender == "")
        #expect(missing.toDo.first { $0.kind == .warnRecipients }?.words.contains(
            "(the warning picked, gone@mail.example.com, isn't in the logs read: pull its sender's Gmail log)") == true)
        #expect(missing.done.allSatisfy { $0.kind != .warnRecipients })
    }

    @Test func anEmailPhishingPulledIsDoneWithWhenAndByWhom() {
        let two = Self.incident + [
            Self.event("gmail", "carol@example.com", "delivery", ip: Self.attacker, at: 31,
                       ["event_info.mail_event_type": "1", "message_info.subject": "Invoice",
                        "message_info.rfc2822_message_id": "<phish-2@mail.example.com>"]),
        ]
        let at = Date(timeIntervalSince1970: 1_792_403_600), phish = "<phish-1@mail.example.com>"
        func pulled(_ id: String = "phish-1@mail.example.com", steps: Int = 3, trashed: Int = 3, failed: Int = 0, searched: Bool = true,
                    at: Date = at) -> LogReading.Pulled {
            LogReading.Pulled(messageID: id, at: at, by: "admin@example.com", steps: steps, trashed: trashed, failed: failed, mailboxes: 2,
                              searchedEverywhere: searched)
        }
        let before = LogReading.read(two)
        #expect(before.done.isEmpty && before.emailsToPull == [phish, "<phish-2@mail.example.com>"])

        let reading = LogReading.read(two, context: LogReading.Context(pulled: [pulled()]))
        #expect(reading.done.map(\.id) == ["D1"] && reading.done[0].kind == .pullEmail && reading.done[0].drafts.isEmpty)
        #expect(reading.done[0].words == "Pulled “Shared file” (\(phish)): trashed from the 2 mailboxes that had it, every mailbox searched first.")
        #expect(reading.done[0].done == LogReading.Done(how: .trashed, at: at, by: "admin@example.com"))
        #expect(reading.emailsToPull == ["<phish-2@mail.example.com>"], "Pull All offers only what's left")
        #expect(!reading.drafts.contains(.pullEmail(messageID: phish, subject: "Shared file")), "drafted nowhere again")
        #expect(reading.findings.map(\.words) == before.findings.map(\.words), "it was still sent")
        #expect(reading.toDo.map(\.words) == before.toDo.map(\.words).filter { !$0.contains(phish) })
        #expect(reading.toDo.allSatisfy { $0.done == nil })
        // Another email's run changes nothing.
        #expect(LogReading.read(two, context: LogReading.Context(pulled: [pulled("other@mail.example.com")])) == before)

        func left(_ runs: LogReading.Pulled...) -> String? {
            let reading = LogReading.read(two, context: LogReading.Context(pulled: runs))
            #expect(reading.done.isEmpty && reading.emailsToPull.contains(phish))
            return reading.toDo.first { $0.drafts.contains(.pullEmail(messageID: phish, subject: "Shared file")) }?.words
        }
        let ask = "Pull “Shared file” (\(phish)) from every mailbox: it went out from the attacker's address. Phishing's last run by "
            + "admin@example.com trashed "
        let again = ": find it again there to see what's left."
        #expect(left(pulled(trashed: 2, failed: 1)) == ask + "2 of its 3 steps, but 1 failed" + again)
        #expect(left(pulled(trashed: 1)) == ask + "1 of its 3 steps, but 2 didn't finish" + again)
        #expect(left(pulled(searched: false)) == ask + "it from every mailbox it found, but Find couldn't search every mailbox for it" + again)
        #expect(left(pulled(trashed: 0, failed: 1, searched: false))
                == ask + "0 of its 3 steps, but 1 failed, 2 didn't finish and Find couldn't search every mailbox for it" + again)
        // The latest run decides, and a Message-ID matches with its angle brackets or without.
        let later = at.addingTimeInterval(600)
        #expect(left(pulled(trashed: 1, at: later), pulled()) == ask + "1 of its 3 steps, but 2 didn't finish" + again)
        let whole = LogReading.read(two, context: LogReading.Context(pulled: [pulled(trashed: 1), pulled(phish, steps: 1, trashed: 1, at: later)]))
        #expect(whole.done.map(\.done) == [LogReading.Done(how: .trashed, at: later, by: "admin@example.com")])

        // Find showed nobody here has it (every mailbox and its Spam searched): done, said as checked, and the latest fact
        // decides. A run after the check found copies again, so it's to do until that run is whole.
        func nobody(_ id: String = phish, at: Date = later) -> LogReading.NobodyHas { LogReading.NobodyHas(messageID: id, at: at, by: "admin@example.com") }
        let checked = LogReading.read(two, context: LogReading.Context(nobodyHas: [nobody("phish-1@mail.example.com")]))
        #expect(checked.done.map(\.words) == ["Nobody here has “Shared file” (\(phish)): Phishing's Find searched every mailbox and its Spam."])
        #expect(checked.done.map(\.done) == [LogReading.Done(how: .nobodyHasIt, at: later, by: "admin@example.com")])
        #expect(checked.emailsToPull == ["<phish-2@mail.example.com>"] && !checked.drafts.contains(.pullEmail(messageID: phish, subject: "Shared file")))
        let afterPartial = LogReading.read(two, context: LogReading.Context(pulled: [pulled(trashed: 1)], nobodyHas: [nobody()]))
        #expect(afterPartial.done.map(\.done?.how) == [.nobodyHasIt], "the check after the run")
        let runAfter = LogReading.read(two, context: LogReading.Context(pulled: [pulled(trashed: 1, at: later.addingTimeInterval(60))],
                                                                       nobodyHas: [nobody()]))
        #expect(runAfter.done.isEmpty && runAfter.emailsToPull.contains(phish), "a run after the check found copies again")
    }

    /// Two phishing emails with one subject are two to pull; a device's task stays until that account's latest word on it
    /// says it left; recovery details clear only by their own removal, and a changed question is its own item.
    @Test func eachLooseEndStaysUntilItsOwnFix() {
        let twice = LogReading.read(Self.incident + [
            Self.event("gmail", "carol@example.com", "delivery", ip: Self.attacker, at: 31,
                       ["event_info.mail_event_type": "1", "message_info.subject": "Shared file",
                        "message_info.rfc2822_message_id": "<phish-2@mail.example.com>"]),
        ])
        #expect(twice.toDo.filter { $0.kind == .pullEmail }.count == 2)
        let vm = ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "WINDOWS", "DEVICE_ID": "pc-1"]
        let joined = Self.incident + [Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11, vm)]
        func deviceOpen(_ more: [LogReading.Event]) -> Bool { LogReading.read(joined + more).toDo.contains { $0.kind == .deleteDevice } }
        #expect(deviceOpen([Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 70, ["ACCOUNT_STATE": "UNREGISTERED", "DEVICE_ID": "pc-1"]),
                            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 80, vm)]), "registered again")
        // Google's own values (the Reports API's Devices and Admin mobile-settings events), not guesses.
        func action(_ type: String, _ status: String) -> LogReading.Event {
            Self.event("mobile", "carol@example.com", "DEVICE_ACTION_EVENT", at: 70,
                       ["DEVICE_ID": "pc-1", "RESOURCE_ID": "r-1", "ACTION_TYPE": type, "ACTION_EXECUTION_STATUS": status])
        }
        #expect(deviceOpen([action("ACCOUNT_WIPE", "PENDING")]), "a wipe not done")
        #expect(deviceOpen([action("BLOCK", "SENT_TO_DEVICE")]), "a block not done")
        #expect(deviceOpen([action("LOCK_DEVICE", "EXECUTED")]), "locked isn't gone")
        #expect(deviceOpen([Self.event("mobile", "dana@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 70, ["ACCOUNT_STATE": "UNREGISTERED", "DEVICE_ID": "pc-1"])]),
                "another account leaving it")
        #expect(deviceOpen([Self.event("admin", "alice@example.com", "MOBILE_DEVICE_BLOCK", ip: Self.office, at: 70,
                                       ["DEVICE_ID": "pc-1", "USER_EMAIL": "dana@example.com"])]), "another account's device")
        #expect(deviceOpen([Self.event("admin", "alice@example.com", "MOBILE_DEVICE_BLOCK", ip: Self.office, at: 70,
                                       ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"]),
                            Self.event("admin", "alice@example.com", "MOBILE_DEVICE_APPROVE", ip: Self.office, at: 75,
                                       ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"])]), "approved again")
        // Approved again is back, even from a suspect address; blocked from one isn't gone.
        #expect(deviceOpen([action("BLOCK", "EXECUTED"), Self.event("admin", "alice@example.com", "MOBILE_DEVICE_APPROVE", ip: Self.attacker,
                                                                   at: 75, ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"])]), "approved by the attacker")
        #expect(deviceOpen([Self.event("admin", "alice@example.com", "MOBILE_DEVICE_BLOCK", ip: Self.attacker, at: 70,
                                       ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"])]), "blocked from a suspect address")
        #expect(deviceOpen([action("BLOCK", "EXECUTED"),
                            Self.event("mobile", "carol@example.com", "DEVICE_ACTION_EVENT", at: 75,
                                       ["DEVICE_ID": "pc-1", "ACTION_TYPE": "APPROVE", "ACTION_EXECUTION_STATUS": "EXECUTED"])]), "approved in the Devices log")
        #expect(!deviceOpen([action("ACCOUNT_WIPE", "EXECUTED")]))
        #expect(!deviceOpen([action("BLOCK", "EXECUTED")]))
        #expect(!deviceOpen([Self.event("mobile", "carol@example.com", "DEVICE_COMPLIANCE_CHANGED_EVENT", at: 70,
                                        ["DEVICE_ID": "pc-1", "DEVICE_DEACTIVATION_REASON": "DEVICE_BLOCKED_BY_ADMIN"])]))
        for name in ["MOBILE_DEVICE_BLOCK", "MOBILE_DEVICE_DELETE", "MOBILE_DEVICE_WIPE", "MOBILE_ACCOUNT_WIPE"] {
            #expect(!deviceOpen([Self.event("admin", "alice@example.com", name, ip: Self.office, at: 70,
                                            ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"])]), "\(name)")
        }
        let phone = LogReading.read(Self.incident + [
            Self.event("useraccounts", "carol@example.com", "recovery_phone_edit", ip: Self.attacker, at: 14),
            Self.event("useraccounts", "carol@example.com", "recovery_secret_qa_edit", ip: Self.attacker, at: 15),
            Self.done("REMOVE_RECOVERY_EMAIL", at: 62),
        ])
        let recovery = phone.toDo.filter { $0.kind == .clearRecovery }.map(\.words)
        #expect(recovery.contains { $0.hasPrefix("Clear carol@example.com's recovery email and phone") }, "the email removed, not the phone")
        #expect(recovery.contains { $0.hasPrefix("Have carol@example.com set a new recovery question") })
    }

    /// The model is told where each account stands, in words without times or anything an attacker wrote.
    @Test func thePromptSaysWhereEachAccountStands() {
        let prompt = LogExplainer.prompt(LogReading.read(Self.incident + [
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", at: 61),
            Self.event("login", "carol@example.com", "login_failure", ip: Self.attacker, at: 70),
        ]), when: Self.minute)
        #expect(prompt.contains("carol@example.com: locked, and the attacker tried again afterwards and failed. Done: one forced sign-out "
                                + "by an admin; one password reset by an admin."))
        #expect(prompt.contains("dana@example.com: not locked since the attack."))
        #expect(prompt.contains("- minute 61: carol@example.com: locked (signed out and the password reset)."))
    }

    /// No lock seen says why when the pull couldn't show one: pulled by the attacker's address (the lock is done from the
    /// operator's), or without the admin log.
    @Test func noLockSaysWhyWhenThePullCouldntShowIt() {
        func words(_ context: LogReading.Context) -> String { LogReading.read(Self.incident, context: context).statuses[0].words(Self.minute) }
        #expect(words(LogReading.Context(pulledBy: Self.attacker))
                == "No lock seen: a pull by one address doesn't show it (the lock is done from yours): pull by the accounts.")
        #expect(words(LogReading.Context(read: ["login", "token"])) == "No lock seen: the admin log, where it would be, wasn't read.")
        #expect(words(LogReading.Context(read: ["login", "admin"])) == "No lock seen in these logs.")
    }

    /// What a lock leaves in place, from the attacker's address: a passkey and a changed recovery phone, said with what to
    /// do, the recovery step drafted. The person's own passkey from their own address isn't one: the same event means the
    /// opposite from there. Another app reached through Google keeps its own session; the same from the office is no finding.
    @Test func whatALockLeavesInPlace() {
        let reading = LogReading.read(Self.incident + [
            Self.event("login", "carol@example.com", "passkey_enrolled", ip: Self.attacker, at: 13),
            Self.event("useraccounts", "carol@example.com", "recovery_phone_edit", ip: Self.attacker, at: 14),
            Self.event("login", "alice@example.com", "passkey_enrolled", ip: Self.office, at: 15),
            Self.event("saml", "carol@example.com", "login_success", ip: Self.attacker, at: 16, ["application_name": "Payroll Portal"]),
            Self.event("saml", "alice@example.com", "login_success", ip: Self.office, at: 17, ["application_name": "Payroll Portal"]),
        ])
        let left = reading.findings.filter { $0.kind == .leftInPlace }
        #expect(left.map(\.accounts) == [["carol@example.com"]])
        #expect(left.first?.words == "From 198.51.100.23, carol@example.com's account got a new passkey and a changed recovery phone: a "
                + "lock doesn't undo them. Remove what isn't theirs on the Admin console's page for them (Security), or with them in "
                + "their Google Account. Check Account shows the recovery details, and its “Clear recovery email & phone” step removes them.")
        #expect(left.first?.drafts == [.secureAccount("carol@example.com")])
        let passkeyOnly = LogReading.read(Self.incident + [Self.event("login", "carol@example.com", "passkey_enrolled", ip: Self.attacker, at: 13)])
        #expect(passkeyOnly.findings.first { $0.kind == .leftInPlace }?.drafts.isEmpty == true, "a passkey is removed by hand")
        let session = reading.findings.filter { $0.kind == .otherAppSession }
        #expect(session.map(\.accounts) == [["carol@example.com"]])
        #expect(session.first?.words == "carol@example.com signed in to Payroll Portal through Google from 198.51.100.23: Google's sign-out "
                + "doesn't end that app's session. Sign them out there too.")
        #expect(session.first?.drafts.isEmpty == true)
        let kinds = reading.findings.map(\.kind)
        #expect(kinds.firstIndex(of: .leftInPlace)! < kinds.firstIndex(of: .mailFromSuspect)!)
    }

    struct Stub: LogExplainer.Asking {
        let answer: LogExplainer.Answer
        func answer(instructions: String, prompt: String) async throws -> LogExplainer.Answer { answer }
    }

    /// The model's sentences about what's left stand only on to-do items code worked out: one citing none, or only unknown
    /// ones, is dropped, so the model can't add a task.
    @Test func theExplanationKeepsOnlyPointsCitingTasks() async throws {
        let reading = LogReading.read(Self.incident)
        let stub = Stub(answer: LogExplainer.Answer(overview: " carol@ was taken over. ", done: " Nothing yet. ", left: [
            LogExplainer.AnswerPoint(text: "Secure carol first.", cites: ["T1", "T99"]),
            LogExplainer.AnswerPoint(text: "Everyone is compromised.", cites: ["T99"]),
            LogExplainer.AnswerPoint(text: "Disable 2-Step Verification for all.", cites: []),
        ]))
        let explanation = try await LogExplainer.explain(reading, using: stub)
        #expect(explanation.overview == "carol@ was taken over." && explanation.done == "Nothing yet.")
        #expect(explanation.left == [LogExplainer.Explanation.Point(text: "Secure carol first.", cites: ["T1"])])
    }

    /// The model never sees the text the logs carry (a subject, a URL), which an attacker writes.
    @Test func thePromptHoldsNoTextTheAttackerWrote() {
        let prompt = LogExplainer.prompt(LogReading.read(Self.incident + [
            Self.event("login", "carol@example.com", "blocked_sender", ip: Self.attacker, at: 29, ["affected_email_address": "bounce@example.net"]),
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11,
                       ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "WINDOWS", "DEVICE_MODEL": "Totally Legit PC"]),
        ]))
        #expect(prompt.contains("T1:") && prompt.contains("carol@example.com") && prompt.contains(Self.attacker))
        #expect(prompt.contains("The attacker blocked a sender in Gmail") && prompt.contains("A computer joined the account"))
        for text in ["Shared file", "login-check", "phish-1", "bounce@example.net", "Totally Legit", "Mail Sync Pro"] {
            #expect(!prompt.contains(text), "\(text)")
        }
    }

    /// Each account's timeline, in time order: how the attacker got in, the computer that joined with it, each forced
    /// sign-out and reset (apps revoked at once said once), Google's own disabling, and the person's own changes, with the
    /// address when it isn't one they used before the attack (a home's IPv6 address changes; its network doesn't).
    @Test func eachAccountHasItsTimeline() {
        let home6 = "2001:db8:aa:1::5", home6Later = "2001:db8:aa:1:9::7"
        let reading = LogReading.read(Self.incident + [
            Self.event("login", "carol@example.com", "login_success", ip: home6, at: 2),
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11, ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "MAC"]),
            Self.done("RESET_SIGNIN_COOKIES", at: 60), Self.done("CHANGE_PASSWORD", at: 61),
            Self.done("REVOKE_3LO_TOKEN", at: 61), Self.done("REVOKE_3LO_TOKEN", at: 61), Self.done("CHANGE_PASSWORD_ON_NEXT_LOGIN", at: 61),
            Self.done("RESET_SIGNIN_COOKIES", at: 90),
            Self.event("useraccounts", "carol@example.com", "password_edit", ip: home6Later, at: 95),
            Self.event("useraccounts", "carol@example.com", "2sv_enroll", ip: "192.0.2.77", at: 96),
            Self.event("login", "carol@example.com", "account_disabled_hijacked", at: 120),
        ])
        let carol = reading.statuses[0]
        #expect(carol.timeline.map { "\(Self.minute($0.at)) \($0.words)" } == [
            "minute 10 Google blocked a suspicious sign-in from 198.51.100.23",
            "minute 11 The attacker signed in from 198.51.100.23",
            "minute 11 A Mac joined the account",
            "minute 12 The attacker gave Mail Sync Pro access",
            "minute 30 1 Gmail event from the attacker's address",
            "minute 60 Signed out of every session by alice@example.com",
            "minute 61 Password reset by alice@example.com",
            "minute 61 2 apps' access revoked by alice@example.com",
            "minute 90 Signed out of every session by alice@example.com",
            "minute 95 They changed their own password",
            "minute 96 They turned on 2-Step Verification, from 192.0.2.77, an address not seen before the attack",
            "minute 120 Google disabled the account as hijacked",
        ])
        #expect(carol.timeline.map(\.who) == [.google, .attacker, .attacker, .attacker, .attacker, .admin, .admin, .admin, .admin, .person, .person, .google])
    }

    /// What's still to do leaves the list when the logs show it done: a computer unregistered, recovery details an admin
    /// removed. A log read for every account that stops short of the attack is to pull again, for just those accounts.
    @Test func whatsDoneLeavesTheList() {
        let vm = ["ACCOUNT_STATE": "REGISTERED", "DEVICE_TYPE": "WINDOWS", "DEVICE_ID": "pc-1", "RESOURCE_ID": "r-1"]
        let attacked = Self.incident + [
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 11, vm),
            Self.event("useraccounts", "carol@example.com", "recovery_phone_edit", ip: Self.attacker, at: 14),
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", at: 61),
        ]
        let open = LogReading.read(attacked)
        // Each carries its own "Do It Here": the computer by the log's ID and time, the recovery details cleared.
        let joinedAt = Self.event("", "", "", at: 11).time
        #expect(open.toDo.contains { $0.kind == .deleteDevice && $0.accounts == ["carol@example.com"]
            && $0.drafts == [.undo(account: "carol@example.com", pick: .computer(resourceID: "r-1", registeredAt: joinedAt))] })
        #expect(open.toDo.contains { $0.kind == .clearRecovery && $0.drafts == [.undo(account: "carol@example.com", pick: .clearRecovery)] })
        let done = LogReading.read(attacked + [
            Self.event("mobile", "carol@example.com", "DEVICE_REGISTER_UNREGISTER_EVENT", at: 70, ["ACCOUNT_STATE": "UNREGISTERED", "DEVICE_ID": "pc-1"]),
            Self.done("REMOVE_RECOVERY_PHONE", at: 62),
        ])
        #expect(!done.toDo.contains { [.deleteDevice, .clearRecovery].contains($0.kind) })
        // An admin's block of it, in the Admin log, is done too, and in the account's timeline in words.
        let blocked = LogReading.read(attacked + [Self.event("admin", "alice@example.com", "MOBILE_DEVICE_BLOCK", ip: Self.office, at: 70,
                                                             ["DEVICE_ID": "pc-1", "USER_EMAIL": "carol@example.com"])])
        #expect(!blocked.toDo.contains { $0.kind == .deleteDevice })
        #expect(blocked.statuses.first { $0.account == "carol@example.com" }?.timeline.contains { $0.words == "A device blocked by alice@example.com" } == true)
        // Gmail read for every account stopped at minute 40; the attack began at minute 10.
        let short = LogReading.read(attacked, context: LogReading.Context(capped: ["gmail": Self.event("", "", "", at: 40).time!,
                                                                               "mobile": Self.event("", "", "", at: 1).time!]))
        let again = short.toDo.first { $0.kind == .pullAgain }
        #expect(again?.words == "Pull the Gmail log again for just carol@example.com, dana@example.com and erin@example.com: read for every "
                + "account, it stops at its newest events and doesn't reach back to the attack.")
        #expect(short.toDo.firstIndex { $0.kind == .pullAgain }! < short.toDo.firstIndex { $0.kind == .deleteDevice }!)
        #expect(again?.pullsAgain == ["gmail"] && again?.shows == nil, "Pull Again reads the short log for those accounts")
    }

    /// Each account is read from its own events and the admin's done to it (`LogReading.Accounts`), never every event: a
    /// whole pull holds hundreds of thousands (failure log 2026-10-23). A rule that reads more about an account must widen
    /// `Accounts`, or this fails: every account's status is the same from its own events as from all of them.
    @Test func anAccountsStatusReadsOnlyItsOwnEvents() {
        let events = Self.incident + [
            Self.done("CHANGE_PASSWORD", at: 60), Self.done("RESET_SIGNIN_COOKIES", to: "Carol@example.com", at: 61),
            Self.event("login", "carol@example.com", "login_success", ip: Self.attacker, at: 80),
            Self.event("contacts", "carol@example.com", "print_contacts", at: 20, ["CONTACTS_COUNT": "1405"]),
            Self.event("drive", "carol@example.com", "view", ip: Self.attacker, at: 33),
            Self.event("login", "dana@example.com", "login_success", ip: "203.0.113.9", at: 2),
            Self.event("useraccounts", "dana@example.com", "password_edit", ip: "203.0.113.9", at: 50),
            Self.done("SUSPEND_USER", to: "dana@example.com", at: 40), Self.done("UNSUSPEND_USER", to: "DANA@example.com", at: 45),
            Self.event("login", "erin@example.com", "account_disabled_hijacked", at: 50),
            Self.event("admin", "dana@example.com", "RESET_SIGNIN_COOKIES", ip: "192.0.2.9", at: 30, ["USER_EMAIL": "erin@example.com"]),
            Self.event("admin", "alice@example.com", "CHANGE_PASSWORD", ip: Self.office, at: 3, ["USER_EMAIL": "alice@example.com"]),
        ]
        let about = LogReading.Accounts(events), acting: Set = [Self.attacker]
        let held = ["dana@example.com": Self.event("", "", "", at: 20).time!...Date.distantFuture]
        for account in ["carol@example.com", "Dana@example.com", "erin@example.com", "alice@example.com", "frank@example.com"] {
            for held in [[:], held] {
                #expect(LogReading.status(account, events, acting: acting, context: LogReading.Context(), held: held)
                        == LogReading.status(account, about[account], acting: acting, context: LogReading.Context(), held: held), "\(account)")
            }
        }
        #expect(LogReading.status("carol@example.com", about["carol@example.com"], acting: acting, context: LogReading.Context()).state == .stillIn)
        #expect(about["CAROL@example.com"].count == 10 && about["alice@example.com"].count == 6, "its own, and the admin's done to it, each once")
    }

    /// A whole pull's size (a small domain's every-account Gmail runs to thousands of events a day) read in seconds, not the
    /// minutes it took when each account's status read every event (failure log 2026-10-23): 200 accounts the attacker had,
    /// each from its own address, among 200,000 events. A few seconds in a debug build; reading every event per account,
    /// 40 accounts took 23 and these 200 would take about 110, so a generous bound still catches that and leaves a busy
    /// runner room (failure logs 2026-10-16 and 2026-10-20: a tight timing test failed on one).
    @Test func aWholePullIsReadInSeconds() {
        let accounts = (0..<200).map { "user\($0)@example.com" }
        var events: [LogReading.Event] = []
        for (n, account) in accounts.enumerated() {
            events.append(Self.event("login", account, "suspicious_login", ip: "198.51.\(100 + n / 200).\(n % 200 + 1)", flagged: true, at: n))
            events.append(Self.event("login", account, "login_success", ip: "198.51.\(100 + n / 200).\(n % 200 + 1)", at: n + 1, ["is_suspicious": "true"]))
            if n.isMultiple(of: 2) { events += [Self.done("CHANGE_PASSWORD", to: account, at: n + 60), Self.done("RESET_SIGNIN_COOKIES", to: account, at: n + 61)] }
        }
        let logs = ["gmail", "drive", "calendar", "login"]
        for index in events.count..<200_000 {
            let n = index % accounts.count
            events.append(Self.event(logs[index % logs.count], accounts[n], logs[index % logs.count] == "login" ? "login_success" : "view",
                                     ip: index.isMultiple(of: 9) ? "198.51.\(100 + n / 200).\(n % 200 + 1)" : "203.0.113.\(index % 200)", at: index % 4_000))
        }
        let clock = ContinuousClock(), started = clock.now
        let reading = LogReading.read(events)
        let took = clock.now - started
        #expect(reading.statuses.count == 200 && reading.events == 200_000)
        #expect(took < .seconds(60), "took \(took)")
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
        print("done:", explanation.done)
        for point in explanation.left { print("left:", point.text, point.cites) }
        #expect(!explanation.overview.isEmpty && !explanation.left.isEmpty)
        #expect(explanation.left.allSatisfy { !$0.cites.isEmpty })
    }
}
