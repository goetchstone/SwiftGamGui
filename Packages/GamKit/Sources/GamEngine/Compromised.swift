import Foundation

/// The response to a compromised account (docs/plans/2026-10-19-compromised-account.md): the person stays employed, so
/// there is no manager and no hand-over. Offboarding's lock (its builders and its words), then the attacker's changes
/// the operator picked from a read-only check of the account: filters deleted, delegates and send-as addresses
/// removed. A pure core, as `Offboarding` is: each step one `GamWrite` from `GamCommands`, and the reads' records in
/// words. Text is handled by Unicode scalar, as Python does.
public enum Compromised {
    /// The steps, in run order. A delegate or send-as address removed is one step each.
    public enum Step: String, CaseIterable, Sendable {
        case password
        case clearRecovery = "clear_recovery"
        case revoke, forward, filters, delegate
        case sendAs = "send_as"
        case drafts
        case imapOff = "imap_off"
        case popOff = "pop_off"

        /// The step as the form and the run name it; offboarding's words for the steps the two share.
        public var name: String {
            switch self {
            case .password: Offboarding.Step.password.name
            case .clearRecovery: Offboarding.Step.clearRecovery.name
            case .revoke: Offboarding.Step.revoke.name
            case .forward: Offboarding.Step.forward.name
            case .filters: "Delete the picked filters"
            case .delegate: "Remove a delegate"
            case .sendAs: "Remove a send-as address"
            case .drafts: "Delete the drafts"
            case .imapOff: Offboarding.Step.imapOff.name
            case .popOff: Offboarding.Step.popOff.name
            }
        }

        /// The steps a switch turns on or off; the others run whenever they have something to act on.
        public static let switchable: [Step] = [.clearRecovery, .imapOff, .popOff]
        /// The lock as asked (2026-10-19): IMAP and POP off. Clearing recovery is a loss when the values are the
        /// person's own, so it waits for the operator to look.
        public static let onByDefault: Set<Step> = [.imapOff, .popOff]

        /// What a switched step is for, said beside its switch.
        public var note: String? {
            switch self {
            case .clearRecovery: "Removes both, so an attacker's recovery phone or address can't take the account back through "
                + "“Forgot password?”. The old values aren't kept: the person adds their own again."
            case .imapOff: "No mail app can download their mail over IMAP. The reset and the sign-out already cut off the ones "
                + "signed in; the person can turn IMAP back on in Gmail's settings."
            case .popOff: "No mail app can download their mail over POP. Nothing in Gmail is deleted; the person can turn POP "
                + "back on in Gmail's settings."
            default: nil
            }
        }
    }

    /// The fields Check Account reads with `info user`: who the person is, whether they're locked or an admin, their
    /// 2-Step Verification and their recovery details (`USER_FIELDS_CHOICE_MAP`'s names; grammar 5780-5810).
    public static let accountFields = ["primaryEmail", "name", "suspended", "isAdmin", "isDelegatedAdmin", "isEnrolledIn2Sv",
                                       "isEnforcedIn2Sv", "recoveryEmail", "recoveryPhone"]

    // MARK: the steps

    /// One step: what it's called and does, and the one write it runs. Every step but the reset needs the reset to have
    /// succeeded, when it runs (offboarding's rule).
    public struct Planned: Sendable {
        public let key: Step
        public let label: String
        public let summary: String
        public let write: GamWrite
    }

    /// Every step in run order, for `user` (the account's primary address): the reset and the three lock steps always,
    /// the switched ones in `switchedOn`, and one removal per picked item. `filters` are the filters to delete, as the
    /// check read them; `delegates` and `sendAs` the addresses to remove. `recovery` is what the check read, said in the
    /// clear-recovery step's words. Throws when a pick can't be one argv element (`GamCommands.Invalid`).
    public static func steps(user: String, switchedOn: Set<Step>, filters: [Filter] = [], delegates: [String] = [],
                             sendAs: [String] = [], drafts: [Draft] = [],
                             recovery: (email: String, phone: String) = ("", "")) throws -> [Planned] {
        guard switchedOn.isSubset(of: Step.switchable) else {
            throw GamCommands.Invalid.argument("only \(Step.switchable.map(\.rawValue).joined(separator: ", ")) are switched")
        }
        guard delegates.allSatisfy(GamCommands.isOneAddress) else {
            throw GamCommands.Invalid.argument("each delegate to remove is one email address")
        }
        let was = [recovery.email.isEmpty ? nil : "email \(recovery.email)", recovery.phone.isEmpty ? nil : "phone \(recovery.phone)"]
            .compactMap(\.self)
        var steps: [Planned] = [
            Planned(key: .password, label: Step.password.name,
                    summary: "Set \(user)'s password to a random one nobody is shown, so the attacker's copy stops working. "
                        + "The person can't sign in until you give them a new one (Admin console → Reset password)",
                    write: GamCommands.resetPassword(email: user)),
        ]
        if switchedOn.contains(.clearRecovery) {
            steps.append(Planned(key: .clearRecovery, label: Step.clearRecovery.name,
                                 summary: "Remove \(user)'s recovery email and recovery phone"
                                    + (was.isEmpty ? "" : " (now \(was.joined(separator: " and ")))")
                                    + ", so “Forgot password?” can't send a code to an attacker's. The old values aren't kept",
                                 write: GamCommands.clearRecovery(email: user)))
        }
        steps += [
            Planned(key: .revoke, label: Step.revoke.name,
                    summary: "Sign \(user) out of every web and device session, delete their app passwords, invalidate their "
                        + "2-Step Verification backup codes and revoke every connected app's access (OAuth tokens). They sign in "
                        + "again and re-grant the apps they use; 2-Step Verification itself is left on",
                    write: GamCommands.deprovisionUser(email: user)),
            Planned(key: .forward, label: Step.forward.name,
                    summary: "Turn off automatic forwarding of \(user)'s incoming mail (harmless if it's already off)",
                    write: GamCommands.forwardOff(email: user)),
        ]
        if !filters.isEmpty {
            steps.append(Planned(key: .filters, label: "Delete \(filters.count) filter\(filters.count == 1 ? "" : "s")",
                                 summary: "Delete \(user)'s Gmail filter\(filters.count == 1 ? "" : "s") "
                                    + filters.map { "“\($0.words)”" }.joined(separator: "; ") + ". The whole filter goes",
                                 write: try GamCommands.deleteFilters(email: user, filterIDs: filters.map(\.id))))
        }
        for delegate in delegates {
            steps.append(Planned(key: .delegate, label: "Remove the delegate \(delegate)",
                                 summary: "Take \(delegate)'s access to \(user)'s mailbox away",
                                 write: GamCommands.removeDelegate(email: user, delegate: delegate)))
        }
        for address in sendAs {
            steps.append(Planned(key: .sendAs, label: "Remove the send-as address \(address)",
                                 summary: "Take \(address) off \(user)'s “Send mail as” list, so mail can't be sent from it as them",
                                 write: try GamCommands.deleteSendAs(email: user, address: address)))
        }
        if !drafts.isEmpty {
            let subjects = drafts.map(\.subject).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let named = subjects.prefix(3).map { "“\($0.isEmpty ? "(no subject)" : $0)”" }.joined(separator: ", ")
                + (subjects.count > 3 ? " and \(subjects.count - 3) other subjects" : "")
            steps.append(Planned(key: .drafts, label: "Delete \(drafts.count) draft\(drafts.count == 1 ? "" : "s")",
                                 summary: "Delete \(drafts.count) of \(user)'s drafts (\(named)) for good, as Gmail's Discard does, so "
                                    + "nobody signed in to the account can send them. They can't be restored",
                                 write: try GamCommands.deleteMessages(email: user, ids: drafts.map(\.id))))
        }
        if switchedOn.contains(.imapOff) {
            steps.append(Planned(key: .imapOff, label: Step.imapOff.name,
                                 summary: "Turn off IMAP for \(user): no mail app can download their mail over IMAP. Their other IMAP "
                                    + "settings go back to Gmail's defaults; their mail is unchanged",
                                 write: GamCommands.imapOff(email: user)))
        }
        if switchedOn.contains(.popOff) {
            steps.append(Planned(key: .popOff, label: Step.popOff.name,
                                 summary: "Turn off POP for \(user): no mail app can download their mail over POP. Nothing in Gmail "
                                    + "is deleted",
                                 write: GamCommands.popOff(email: user)))
        }
        return steps
    }

    /// "Securing carol@example.com — 6 steps", or how many of them run when some are ticked as already done.
    public static func header(user: String, runs: Int, total: Int) -> String {
        runs == total ? "Securing \(user) — \(total) step\(total == 1 ? "" : "s")"
            : "Securing \(user) — \(runs) of \(total) steps (\(total - runs) ticked as already done)"
    }

    /// What a failure stops: offboarding's rule, everything needs the reset when it runs.
    public static func whatStopsWhat(resetRuns: Bool) -> String {
        resetRuns ? "If “\(Step.password.name)” fails, nothing after it runs. If any other step fails, it is reported as failed "
            + "and the rest still run."
            : "If a step fails, it is reported as failed and the rest still run."
    }

    // MARK: the reads, in words

    /// One Gmail filter (`print filters labelidsonly formatjson`): what mail it matches and what it does with it.
    public struct Filter: Sendable, Equatable, Identifiable {
        public let id: String
        /// "from billing@vendor.example", "subject invoice", "has an attachment".
        public let matches: [String]
        /// "forwards it to x@example.org", "deletes it (to Trash)", "archives it (skips the inbox)".
        public let does: [String]
        /// What an attacker's filter does to hide replies or take mail: forward, delete, spam, archive, mark read.
        public let hidesOrForwards: Bool

        public init(record: GamOutput.Record) {
            id = Fields.text(Fields.first(record, "id"))
            let criteria = record["criteria"]?.object ?? [:], action = record["action"]?.object ?? [:]
            var matches: [String] = []
            for key in ["from", "to", "subject", "query", "negatedQuery"] {
                let value = Fields.text(Fields.first(criteria, key))
                guard !value.isEmpty else { continue }
                matches.append(key == "query" ? "mail matching “\(value)”" : key == "negatedQuery" ? "not matching “\(value)”"
                               : "\(key) \(value)")
            }
            if Fields.flag(criteria["hasAttachment"]) { matches.append("has an attachment") }
            if let size = Fields.first(criteria, "size").map(Fields.text), !size.isEmpty {
                matches.append("\(Fields.text(criteria["sizeComparison"]) == "smaller" ? "smaller" : "larger") than \(size) bytes")
            }
            if Fields.flag(criteria["excludeChats"]) { matches.append("not chats") }
            self.matches = matches.isEmpty ? ["every message"] : matches
            var does: [String] = [], hides = false
            let forward = Fields.text(Fields.first(action, "forward"))
            if !forward.isEmpty {
                does.append("forwards it to \(forward)")
                hides = true
            }
            for label in Fields.list(action["addLabelIds"]) {
                switch label {
                case "TRASH": does.append("deletes it (to Trash)"); hides = true
                case "SPAM": does.append("sends it to Spam"); hides = true
                case "STARRED": does.append("stars it")
                case "IMPORTANT": does.append("marks it important")
                default: does.append(label.hasPrefix("CATEGORY_") ? "files it under \(label.dropFirst(9).lowercased())"
                                     : "adds the label \(label)")
                }
            }
            for label in Fields.list(action["removeLabelIds"]) {
                switch label {
                case "INBOX": does.append("archives it (skips the inbox)"); hides = true
                case "UNREAD": does.append("marks it read"); hides = true
                case "SPAM": does.append("never sends it to Spam")
                case "IMPORTANT": does.append("never marks it important")
                default: does.append("removes the label \(label)")
                }
            }
            self.does = does.isEmpty ? ["does nothing Gmail shows"] : does
            hidesOrForwards = hides
        }

        /// "From billing@vendor.example: forwards it to x@example.org, archives it (skips the inbox)".
        public var words: String {
            let when = matches.joined(separator: ", ")
            return when.prefix(1).uppercased() + when.dropFirst() + ": " + does.joined(separator: ", ")
        }
    }

    /// Auto-forwarding (`print forward`): on or off, and while on, where to and what happens to the kept copy.
    public struct Forwarding: Sendable, Equatable {
        public let enabled: Bool
        public let to: String
        public let disposition: String

        public init(enabled: Bool, to: String = "", disposition: String = "") {
            self.enabled = enabled
            self.to = to
            self.disposition = disposition
        }

        /// The person's row; none (Gmail off for them prints the titles alone) reads as nil.
        public init?(records: [GamOutput.Record]) {
            guard let row = records.first else { return nil }
            self.init(enabled: Fields.flag(row["forwardEnabled"]), to: Fields.text(Fields.first(row, "forwardTo")),
                      disposition: Fields.text(Fields.first(row, "disposition")))
        }

        public var words: String {
            guard enabled else { return "Off" }
            let kept = switch disposition {
            case "leaveInInbox": "a copy stays in the inbox"
            case "archive": "the copy is archived"
            case "trash": "the copy is deleted"
            case "markRead": "the copy is marked read"
            default: disposition
            }
            return "On: every message goes to \(to)" + (kept.isEmpty ? "" : ", and \(kept)")
        }
    }

    /// One forwarding address (`print forwardingaddresses`): an address forwarding may send to, and whether its owner
    /// accepted (an accepted one lets forwarding be turned back on to it without a new code).
    public struct ForwardingAddress: Sendable, Equatable, Identifiable {
        public let address: String
        public let status: String
        public var id: String { address }

        public init(record: GamOutput.Record) {
            address = Fields.text(Fields.first(record, "forwardingEmail"))
            status = Fields.text(Fields.first(record, "verificationStatus"))
        }
    }

    /// One "Send mail as" address (`print sendas verifyonly`).
    public struct SendAs: Sendable, Equatable, Identifiable {
        public let address: String
        public let name: String
        public let isPrimary: Bool
        public let isDefault: Bool
        public let replyTo: String
        /// Empty for the primary and the domain's own aliases; `accepted` or `pending` for another address.
        public let status: String
        public let hasSignature: Bool
        public var id: String { address }

        public init(record: GamOutput.Record) {
            address = Fields.text(Fields.first(record, "sendAsEmail"))
            name = Fields.text(Fields.first(record, "displayName"))
            isPrimary = Fields.flag(record["isPrimary"])
            isDefault = Fields.flag(record["isDefault"])
            replyTo = Fields.text(Fields.first(record, "replyToAddress"))
            status = Fields.text(Fields.first(record, "verificationStatus"))
            hasSignature = Fields.flag(record["signature"])
        }

        public var words: String {
            var parts = [name.isEmpty ? address : "\(name) <\(address)>"]
            if isPrimary { parts.append("their own address") }
            if isDefault { parts.append("sent from by default") }
            if !replyTo.isEmpty { parts.append("replies go to \(replyTo)") }
            if !status.isEmpty { parts.append("verification \(status)") }
            if hasSignature { parts.append("has a signature") }
            return parts.joined(separator: " · ")
        }
    }

    /// One admin role assignment (`print admins user`): the role, and where it applies.
    public struct AdminRole: Sendable, Equatable, Identifiable {
        public let id: String
        public let role: String
        public let scope: String

        public init(record: GamOutput.Record) {
            id = Fields.text(Fields.first(record, "roleAssignmentId"))
            let name = Fields.text(Fields.first(record, "role", "roleId"))
            role = name == "_SEED_ADMIN_ROLE" ? "Super Admin" : name   // the system role's name, as the Admin console says it
            let orgUnit = Fields.text(Fields.first(record, "orgUnit"))
            scope = Fields.text(Fields.first(record, "scopeType")) == "ORG_UNIT" ? "the org unit \(orgUnit)" : "the whole domain"
        }

        public var words: String { "\(role), for \(scope)" }
    }

    /// The account as `info user … fields accountFields` has it: the facts the panel shows.
    public struct Account: Sendable, Equatable {
        public let primaryEmail: String
        public let fullName: String
        public let suspended: Bool
        public let isAdmin: Bool
        public let isDelegatedAdmin: Bool
        public let enrolledIn2SV: Bool
        public let enforcedIn2SV: Bool
        public let recoveryEmail: String
        public let recoveryPhone: String

        public init(_ user: GamUser) {
            primaryEmail = user.primaryEmail
            fullName = user.fullName
            suspended = user.suspended
            isAdmin = user.isAdmin
            isDelegatedAdmin = user.isDelegatedAdmin
            enrolledIn2SV = user.isEnrolledIn2SV
            enforcedIn2SV = Fields.flag(user.record["isEnforcedIn2Sv"])
            recoveryEmail = user.recoveryEmail
            recoveryPhone = Fields.text(Fields.truthy(Fields.first(user.record, "recoveryPhone")))
        }
    }

    /// What the check found worth saying, before the lists: each a sentence, in the order to deal with them. `nil` for a
    /// read that failed (said beside its list, not here).
    public static func findings(account: Account, forwarding: Forwarding?, filters: [Filter]?, delegates: [String]?,
                                sendAs: [SendAs]?, roles: [AdminRole]?, drafts: [Draft]? = nil) -> [String] {
        var said: [String] = []
        let user = account.primaryEmail
        if account.suspended { said.append("\(user) is suspended: nobody can sign in to it until it's restored.") }
        if let forwarding, forwarding.enabled {
            said.append("Forwarding is on, to \(forwarding.to): every message goes there. “\(Step.forward.name)” turns it off.")
        }
        if let filters {
            let hiding = filters.filter(\.hidesOrForwards)
            if !hiding.isEmpty {
                said.append("\(hiding.count) filter\(hiding.count == 1 ? " forwards, deletes, archives or marks" : "s forward, delete, archive or mark") "
                    + "mail read: an attacker's filter hides the replies to what they sent. Tick each that isn't \(user)'s own.")
            }
        }
        if let delegates, !delegates.isEmpty {
            said.append("\(delegates.count == 1 ? "1 person" : "\(delegates.count) people") can read \(user)'s mail as a delegate: "
                + "remove any \(user) didn't add.")
        }
        if let others = sendAs?.filter({ !$0.isPrimary }), !others.isEmpty {
            said.append("\(user) can send as \(others.count) other address\(others.count == 1 ? "" : "es"): remove any they didn't add.")
        }
        if let drafts, !drafts.isEmpty {
            said.append("\(user) has \(drafts.count == Draft.cap ? "at least \(Draft.cap)" : "\(drafts.count)") draft\(drafts.count == 1 ? "" : "s"): "
                + "an attacker's leftover drafts can still be sent by anyone signed in. Delete them, all or by subject.")
        }
        let recovery = [account.recoveryEmail.isEmpty ? nil : "email \(account.recoveryEmail)",
                        account.recoveryPhone.isEmpty ? nil : "phone \(account.recoveryPhone)"].compactMap(\.self)
        if !recovery.isEmpty {
            said.append("Recovery \(recovery.joined(separator: " and ")): check with \(user) that \(recovery.count == 1 ? "it's" : "they're") "
                + "theirs. An attacker's would let them take the account back through “Forgot password?”: if not, switch on "
                + "“\(Step.clearRecovery.name)”.")
        }
        if !account.enrolledIn2SV {
            said.append("2-Step Verification is off for \(user): once they sign in again, have them turn it on, or enforce it for "
                + "their org unit in the Admin console.")
        }
        if account.isAdmin {
            said.append("\(user) is a super admin: an attacker could have changed anything in the domain. Check the Admin console's "
                + "audit log.")
        } else if account.isDelegatedAdmin || !(roles ?? []).isEmpty {
            said.append("\(user) holds an admin role: check the Admin console's audit log for what it was used for.")
        }
        return said
    }

    // MARK: drafts

    /// One draft as `GamCommands.listMessages` lists it: its ID, Gmail's own time and the subject.
    public struct Draft: Sendable, Equatable, Identifiable {
        public let id: String
        public let date: String
        public let when: Date?
        public let subject: String
        public let labels: [String]

        /// The most a check lists: an attacker's session can leave thousands.
        public static let cap = 5_000
        /// The listing and the delete: thousands take minutes (Gmail's per-user quota), the runner's default two.
        public static let timeout: Duration = .seconds(600)

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { record[key]?.string ?? "" }
            id = text("id")
            date = text("Date")
            when = try? Date(date, strategy: .iso8601)
            subject = text("Subject")
            labels = MessageRecipients.words(text("Labels"))
        }

        /// A finished listing's messages: none is GAM's NO_ENTITIES_FOUND_RC (60). Throws the `GamError` when the read failed
        /// and `MessageCopies.Incomplete` when GAM's output passed the runner's cap.
        public static func list(_ result: GamResult, argv: [String]) throws -> [Draft] {
            guard result.exitCode == 0 || result.exitCode == 60 else {
                throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
            }
            guard !result.stdoutTruncated else {
                throw MessageCopies.Incomplete(reason: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so the list wasn't all read.")
            }
            return GamOutput.records(result.stdout).map(Draft.init(record:))
        }
    }

    /// The drafts whose subject holds `text`, case and surrounding spaces aside: "select all whose subject matches".
    public static func drafts(_ drafts: [Draft], subjectMatching text: String) -> [Draft] {
        let needle = PythonText.lower(PythonText.strip(text))
        guard !needle.isEmpty else { return [] }
        return drafts.filter { PythonText.lower($0.subject).contains(needle) }
    }
}
