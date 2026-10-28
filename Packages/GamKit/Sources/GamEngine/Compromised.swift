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
        /// Right after the reset (review 2026-10-23): one comes due while the run goes on, and once sent, its ID may be the Sent copy.
        case scheduled
        case clearRecovery = "clear_recovery"
        case revoke, forward, filters, delegate
        case sendAs = "send_as"
        case autoReply = "auto_reply"
        case computer
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
            case .autoReply: "Turn off the auto-reply"
            case .computer: "Block or remove a computer"
            case .scheduled: "Delete the scheduled emails"
            case .drafts: "Delete the drafts"
            case .imapOff: Offboarding.Step.imapOff.name
            case .popOff: Offboarding.Step.popOff.name
            }
        }

        /// The steps a switch turns on or off; the others run whenever they have something to act on.
        /// Every step but the picks, in run order: each one a switch, so any of them can run alone (the operator,
        /// 2026-10-21: "have ways to do things on an individual basis").
        public static let switchable: [Step] = [.password, .clearRecovery, .revoke, .forward, .imapOff, .popOff]
        /// The lock as asked (2026-10-19): the reset, the sign-out, forwarding off, IMAP and POP off. Clearing recovery is a
        /// loss when the values are the person's own, so it waits for the operator to look.
        public static let onByDefault: Set<Step> = [.password, .revoke, .forward, .imapOff, .popOff]

        /// What a switched step is for, said beside its switch.
        public var note: String? {
            switch self {
            case .password: "Sets a random password nobody is shown, so the attacker's copy stops working; you give the person a "
                + "new one afterwards. Off when you already reset it in the Admin console. While it runs, every other step "
                + "waits for it to succeed."
            case .revoke: "Ends every session and revokes app passwords and connected apps: the person signs in again and "
                + "re-grants the apps they use."
            case .forward: "Stops automatic forwarding of their mail (harmless if it's already off)."
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
    /// 2-Step Verification and their recovery details (`USER_FIELDS_CHOICE_MAP`'s names; grammar 5790-5820).
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

    /// Every step in run order, for `user` (the account's primary address): the switched ones in `switchedOn`, and one
    /// removal per picked item. Any of them alone is a plan. `filters` are the filters to delete, as the
    /// check read them; `delegates` and `sendAs` the addresses to remove; `scheduled` the scheduled sends to delete, each
    /// one Gmail labels scheduled. `recovery` is what the check read, said in the clear-recovery step's words. Throws when
    /// a pick can't be one argv element (`GamCommands.Invalid`).
    public static func steps(user: String, switchedOn: Set<Step>, filters: [Filter] = [], delegates: [String] = [],
                             sendAs: [String] = [], autoReplyOff: Bool = false, computers: [(Computer, ComputerAction)] = [],
                             scheduled: [MailboxSearch.Message] = [], drafts: [Draft] = [],
                             recovery: (email: String, phone: String) = ("", "")) throws -> [Planned] {
        guard switchedOn.isSubset(of: Step.switchable) else {
            throw GamCommands.Invalid.argument("only \(Step.switchable.map(\.rawValue).joined(separator: ", ")) are switched")
        }
        guard delegates.allSatisfy(GamCommands.isOneAddress) else {
            throw GamCommands.Invalid.argument("each delegate to remove is one email address")
        }
        // Whatever the search returned, only a message Gmail itself labels scheduled is deleted as one.
        guard scheduled.allSatisfy(ScheduledSend.isScheduled) else {
            throw GamCommands.Invalid.argument("only a message Gmail labels \(ScheduledSend.label) is deleted as a scheduled send")
        }
        let was = [recovery.email.isEmpty ? nil : "email \(recovery.email)", recovery.phone.isEmpty ? nil : "phone \(recovery.phone)"]
            .compactMap(\.self)
        var steps: [Planned] = []
        if switchedOn.contains(.password) {
            steps.append(Planned(key: .password, label: Step.password.name,
                                 summary: "Set \(user)'s password to a random one nobody is shown, so the attacker's copy stops working. "
                                    + "The person can't sign in until you give them a new one (Admin console → Reset password)",
                                 write: GamCommands.resetPassword(email: user)))
        }
        if !scheduled.isEmpty {
            let count = scheduled.count, people = ScheduledSend.recipients(scheduled).count
            steps.append(Planned(key: .scheduled, label: "Delete \(count) scheduled email\(count == 1 ? "" : "s")",
                                 summary: "Delete \(count) of \(user)'s emails scheduled to send (\(named(scheduled.map(\.subject)))), to "
                                    + "\(people) recipient\(people == 1 ? "" : "s"), for good, before \(count == 1 ? "its" : "their") "
                                    + "time comes. They can't be restored",
                                 write: try GamCommands.deleteMessages(email: user, ids: scheduled.map(\.id))))
        }
        if switchedOn.contains(.clearRecovery) {
            steps.append(Planned(key: .clearRecovery, label: Step.clearRecovery.name,
                                 summary: "Remove \(user)'s recovery email and recovery phone"
                                    + (was.isEmpty ? "" : " (now \(was.joined(separator: " and ")))")
                                    + ", so “Forgot password?” can't send a code to an attacker's. The old values aren't kept",
                                 write: GamCommands.clearRecovery(email: user)))
        }
        if switchedOn.contains(.revoke) {
            steps.append(Planned(key: .revoke, label: Step.revoke.name,
                                 summary: "Sign \(user) out of every web and device session, delete their app passwords, invalidate "
                                    + "their 2-Step Verification backup codes and revoke every connected app's access (OAuth tokens). "
                                    + "They sign in again and re-grant the apps they use; 2-Step Verification itself is left on",
                                 write: GamCommands.deprovisionUser(email: user)))
        }
        if switchedOn.contains(.forward) {
            steps.append(Planned(key: .forward, label: Step.forward.name,
                                 summary: "Turn off automatic forwarding of \(user)'s incoming mail (harmless if it's already off)",
                                 write: GamCommands.forwardOff(email: user)))
        }
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
        if autoReplyOff {
            steps.append(Planned(key: .autoReply, label: Step.autoReply.name,
                                 summary: "Turn off \(user)'s auto-reply, so nobody who writes to them gets its message. Its subject "
                                    + "and text stay in Gmail's settings, off",
                                 write: GamCommands.vacationOff(email: user)))
        }
        for (computer, action) in computers {
            switch action {
            case .block:
                steps.append(Planned(key: .computer, label: "Block \(computer.words)",
                                     summary: "Block \(user)'s sign-in on \(computer.words), so it can't reach their data: it stays "
                                        + "listed as blocked in the Admin console's Devices, and approving it there undoes this",
                                     write: try GamCommands.blockDeviceUser(name: computer.deviceUser)))
            case .delete:
                steps.append(Planned(key: .computer, label: "Remove \(user) from \(computer.words)",
                                     summary: "Take \(user)'s account off \(computer.words) and revoke its access to their data. It "
                                        + "comes back only if someone signs in on it again",
                                     write: try GamCommands.deleteDeviceUser(name: computer.deviceUser)))
            }
        }
        if !drafts.isEmpty {
            steps.append(Planned(key: .drafts, label: "Delete \(drafts.count) draft\(drafts.count == 1 ? "" : "s")",
                                 summary: "Delete \(drafts.count) of \(user)'s drafts (\(named(drafts.map(\.subject)))) for good, as Gmail's Discard does, so "
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

    /// Up to three subjects in quotes, each once, and how many others: what a deleting step names.
    private static func named(_ subjects: [String]) -> String {
        let subjects = subjects.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return subjects.prefix(3).map { "“\($0.isEmpty ? "(no subject)" : $0)”" }.joined(separator: ", ")
            + (subjects.count > 3 ? " and \(subjects.count - 3) other subjects" : "")
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

    /// One phone or tablet syncing the account (`GamCommands.printMobileDevices`): what it is, how it syncs, and when it
    /// first and last did.
    public struct MobileDevice: Sendable, Equatable, Identifiable {
        public let id: String
        /// The accounts on it (`email`): the Directory API's `email:` search matches a prefix, so the read keeps only the
        /// devices that list the person exactly.
        public let owners: [String]
        public let model: String
        public let os: String
        /// How it syncs, in words: the Android device policy app, Google's iOS app, or Exchange sync (Google Sync).
        public let kind: String
        public let status: String
        public let firstSync: String
        public let firstSynced: Date?
        public let lastSync: String
        public let lastSynced: Date?
        /// The device says it's rooted or jailbroken.
        public let reportsCompromise: Bool

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { Fields.text(record[key]) }
            id = text("resourceId")
            owners = (record["email"]?.array ?? []).compactMap(\.string)
            model = text("model")
            os = text("os")
            kind = switch text("type") {
            case "ANDROID": "Android"
            case "IOS_SYNC": "iPhone or iPad (Google's app)"
            case "GOOGLE_SYNC": "Exchange sync (Google Sync)"
            case let other: other
            }
            status = text("status")
            firstSync = text("firstSync")
            firstSynced = (try? Date(firstSync, strategy: .iso8601))
            lastSync = text("lastSync")
            lastSynced = (try? Date(lastSync, strategy: .iso8601))
            let compromise = PythonText.lower(text("deviceCompromisedStatus"))
            reportsCompromise = compromise.contains("compromise detected") && !compromise.hasPrefix("no ")
        }

        /// "Pixel 8, Android 15 (Android)".
        public var words: String {
            [model.isEmpty ? "A device" : model, os].filter { !$0.isEmpty }.joined(separator: ", ") + (kind.isEmpty ? "" : " (\(kind))")
        }
    }

    /// What to do with a computer the attacker signed in on: block the account there (it stays listed, blocked), or take
    /// the account off it.
    public enum ComputerAction: String, Sendable, CaseIterable {
        case block, delete
    }

    /// One computer signed in with the account (`GamCommands.printDevices`: Windows, Mac, Linux or ChromeOS, which the
    /// phones list never shows): what it is, its name, and when the person first and last synced it. An attacker's sign-in
    /// can leave one here, often a virtual machine.
    public struct Computer: Sendable, Equatable, Identifiable {
        /// Google's name for it, `devices/<id>`.
        public let id: String
        /// The person's own sign-in on it, `devices/<id>/deviceUsers/<id>`: what blocking or removing acts on. Empty when
        /// Google didn't give it, or gave one the builders refuse: that computer can't be picked, and the rest of the plan
        /// (the lock with it) still runs.
        public let deviceUser: String
        /// What it runs, as people say it: Windows, macOS, Linux, ChromeOS.
        public let kind: String
        public let model: String
        public let manufacturer: String
        public let os: String
        public let hostname: String
        public let serialNumber: String
        /// "the company's" or "personal" (`ownerType`), empty when Google doesn't say.
        public let ownership: String
        /// The person's state on it in words ("blocked", "the account wiped"…), empty when approved: the person's own
        /// `managementState`, else the device's.
        public let state: String
        /// Still signed in: not blocked, wiped, being wiped or unenrolled (a blocked device user stays listed until deleted).
        public let isActive: Bool
        /// When the person first signed in to it (their own `createTime`), else when they last registered with it
        /// (`firstSyncTime`, which Google sets again at each registration).
        public let firstSync: String
        public let firstSynced: Date?
        public let lastSync: String
        public let lastSynced: Date?
        /// The device says it's compromised (`compromisedState` COMPROMISED).
        public let reportsCompromise: Bool

        /// The computer in `record`, when it is one and `owner` is exactly among its users: the API's `email:` matches a
        /// prefix, and a phone or tablet is the phones list's.
        public init?(record: GamOutput.Record, owner: String) {
            func text(_ key: String, in object: GamOutput.Record? = nil) -> String { Fields.text((object ?? record)[key]) }
            kind = switch text("deviceType") {
            case "WINDOWS": "Windows"
            case "MAC_OS": "macOS"
            case "LINUX": "Linux"
            case "CHROME_OS": "ChromeOS"
            default: ""
            }
            let wanted = PythonText.lower(owner)
            let users = (record["users"]?.array ?? []).compactMap(\.object)
            guard !kind.isEmpty, let mine = users.first(where: { PythonText.lower(text("userEmail", in: $0)) == wanted }) else { return nil }
            id = text("name")
            deviceUser = GamCommands.isDeviceUserName(text("name", in: mine)) ? text("name", in: mine) : ""
            model = text("model")
            manufacturer = text("manufacturer")
            os = text("osVersion")
            hostname = text("hostname")
            serialNumber = text("serialNumber")
            ownership = switch text("ownerType") {
            case "COMPANY": "the company's"
            case "BYOD": "personal"
            default: ""
            }
            let raw = text("managementState", in: mine).isEmpty ? text("managementState") : text("managementState", in: mine)
            isActive = !["BLOCKED", "WIPING", "WIPED", "UNENROLLED"].contains(raw)
            state = switch raw {
            case "", "APPROVED": ""
            case "BLOCKED": "blocked"
            case "PENDING", "PENDING_APPROVAL": "waiting for approval"
            case "WIPING": "the account being wiped"
            case "WIPED": "the account wiped"
            case "UNENROLLED": "unenrolled"
            case "UNPROVISIONED": "not provisioned"
            case let other: PythonText.lower(other)
            }
            let signedIn = text("createTime", in: mine)
            firstSync = signedIn.isEmpty ? text("firstSyncTime", in: mine) : signedIn
            firstSynced = ChromeProfiles.date(firstSync)
            let last = text("lastSyncTime", in: mine)
            lastSync = last.isEmpty ? text("lastSyncTime") : last
            lastSynced = ChromeProfiles.date(lastSync)
            reportsCompromise = text("compromisedState") == "COMPROMISED"
        }

        /// Its model or maker says it's a virtual machine, as a remote attacker's often is: Hyper-V and Azure ("Virtual
        /// Machine"), VMware, VirtualBox, Parallels, QEMU and KVM, Xen, and the clouds' own.
        public var looksVirtual: Bool {
            let said = PythonText.lower(model + " " + manufacturer)
            return Self.virtualWords.contains { said.contains($0) }
        }

        static let virtualWords = ["virtual", "vmware", "virtualbox", "innotek", "parallels", "qemu", "kvm", "xen", "hvm domu",
                                   "google compute engine", "amazon ec2", "bochs"]

        /// "Virtual Machine, Windows 10.0.19045 (Windows), named DESKTOP-7Q2".
        public var words: String {
            [model.isEmpty ? "A computer" : model, os].filter { !$0.isEmpty }.joined(separator: ", ")
                + (kind.isEmpty ? "" : " (\(kind))") + (hostname.isEmpty ? "" : ", named \(hostname)")
        }

        /// The scope not delegated (GAM's "User: <admin>, Cloud Identity API - Devices Service/App not enabled", exit 73, or a
        /// scope refusal): granted in the Admin console.
        public static let delegationNote = "Listing computers needs the service account's domain-wide delegation to include "
            + "https://www.googleapis.com/auth/cloud-identity.devices, or its .readonly form if this domain's service account "
            + "was set up read-only for Cloud Identity Devices (Admin console: Security › Access and data control › API "
            + "controls › Domain-wide delegation). Until then, the Devices log in Pull Incident Logs shows each computer when "
            + "it registers."

        /// The service account's own list of APIs without it (GAM's "API access Denied", exit 12, before it asks Google):
        /// delegating the scope alone can't fix it.
        public static let scopeListNote = "This domain's service-account file carries GAM's own list of APIs, and Cloud "
            + "Identity Devices isn't on it, so GAM never asks Google for the scope: delegating it alone won't help. Set the "
            + "service account up again with Cloud Identity Devices among its APIs (or with no list, so GAM uses its "
            + "defaults), delegate the scope, and import the folder again on Setup. Until then, the Devices log in Pull "
            + "Incident Logs shows each computer when it registers."

        /// The note for a failed read, by its cause; nil when no scope explains it (a dead key's token error is exit 12
        /// too, but no "API access Denied" of the scope list's).
        public static func note(for error: GamError) -> String? {
            if error.exitCode == 12 {
                return error.stderr.contains("API access Denied") && !error.stderr.contains("Authentication Token Error")
                    ? scopeListNote : nil
            }
            return error.exitCode == 73 || error.kind == .scopeMissing ? delegationNote : nil
        }
    }

    /// One Apps Script project the person owns (`GamCommands.printScriptProjects`). A script someone authorized keeps
    /// acting for them, on triggers, for as long as that access lasts: one made or changed during an incident is worth a
    /// look.
    public struct ScriptProject: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let created: String
        public let createdAt: Date?
        public let modified: String
        public let modifiedAt: Date?
        /// Who changed it last, by address when Drive gives one.
        public let lastChangedBy: String
        public let inTrash: Bool

        public init(record: GamOutput.Record) {
            func text(_ key: String, in object: GamOutput.Record? = nil) -> String { Fields.text((object ?? record)[key]) }
            id = text("id")
            name = text("name")
            created = text("createdTime")
            createdAt = ChromeProfiles.date(created)
            modified = text("modifiedTime")
            modifiedAt = ChromeProfiles.date(modified)
            let by = record["lastModifyingUser"]?.object
            lastChangedBy = by.map { text("emailAddress", in: $0).isEmpty ? text("displayName", in: $0) : text("emailAddress", in: $0) } ?? ""
            inTrash = Fields.flag(record["trashed"])
        }

        /// Made or changed in the two weeks before `now`: in an incident, the ones to look at first.
        public func isRecent(at now: Date) -> Bool {
            [createdAt, modifiedAt].contains { $0.map { now.timeIntervalSince($0) <= Self.recent } ?? false }
        }

        public static let recent: TimeInterval = 14 * 24 * 60 * 60

        /// The latest changed first; one Drive gives no time for, last.
        public static func sorted(_ projects: [ScriptProject]) -> [ScriptProject] {
            projects.enumerated().sorted { a, b in
                (a.element.modifiedAt ?? .distantPast, b.offset) > (b.element.modifiedAt ?? .distantPast, a.offset)
            }.map(\.element)
        }

        /// A finished `GamCommands.printScriptProjects` for `user`: their projects, the latest changed first. printFileList
        /// exits 60 whenever it printed no row (`if not csvPF.rows: setSysExitRC(NO_ENTITIES_FOUND_RC)`, 7.48.30), which
        /// overwrites a failure's own code (Drive off, a refused token, one refusal that prints nothing at all), so 60 is
        /// "none" only on GAM's own word that Drive answered with nothing for this person, "Got 0 Drive Files/Folders … for
        /// <user>…" (written once `files.list` returned; `show_gettings` is on in the app's fresh config), with no other
        /// line. Anything else throws the `GamError`, never read as "no project".
        public static func list(_ result: GamResult, argv: [String], user: String) throws -> [ScriptProject] {
            let records = GamOutput.records(result.stdout)
            if result.exitCode == 0 { return sorted(records.map(ScriptProject.init(record:))) }
            let lines = PythonText.lines(result.stderr).map { PythonText.strip($0) }.filter { !$0.isEmpty }
            let wanted = PythonText.lower(user)
            let answered = lines.contains { line in
                line.hasPrefix("Got 0 Drive Files/Folders ") && PythonText.lower(line).hasSuffix(" for \(wanted)...")
            }
            guard result.exitCode == 60, records.isEmpty, answered, lines.allSatisfy(GamError.isProgress) else {
                throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv, stdout: result.stdout)
            }
            return []
        }
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
                                sendAs: [SendAs]?, roles: [AdminRole]?, scheduled: [MailboxSearch.Message]? = nil,
                                drafts: [Draft]? = nil, autoReply: Vacation? = nil,
                                devices: [MobileDevice]? = nil, computers: [Computer]? = nil,
                                apps: [ConnectedApps.App]? = nil, scripts: [ScriptProject]? = nil, now: Date = Date()) -> [String] {
        var said: [String] = []
        let user = account.primaryEmail
        if account.suspended { said.append("\(user) is suspended: nobody can sign in to it until it's restored.") }
        // First of what to undo: these go out on their own, on Gmail's clock.
        if let found = scheduled, case let scheduled = found.filter(ScheduledSend.isScheduled), !scheduled.isEmpty {
            let count = scheduled.count, people = ScheduledSend.recipients(scheduled).count
            let atLeast = found.count >= ScheduledSend.cap ? "At least " : ""
            said.append("\(atLeast)\(count == 1 ? "1 email is" : "\(count) emails are") scheduled to send from \(user), to \(people) "
                + "recipient\(people == 1 ? "" : "s"): Gmail sends \(count == 1 ? "it" : "them") at \(count == 1 ? "its" : "their") "
                + "time on its own, with nobody signed in. Delete \(count == 1 ? "it" : "them") unless \(user) scheduled "
                + "\(count == 1 ? "it" : "them").")
        }
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
        if let autoReply, autoReply.enabled {
            said.append("An auto-reply is on (“\(autoReply.subject)”): an attacker's sends their message, a link say, to everyone "
                + "who writes. Tick “\(Step.autoReply.name)” unless it's \(user)'s own.")
        }
        if let apps, !apps.isEmpty {
            let ai = apps.filter(\.looksLikeAI).map(\.name), broad = apps.filter { $0.reach == .broad && !$0.looksLikeAI }.map(\.name)
            let notes = [broad.isEmpty ? "" : "broad: \(broad.joined(separator: ", "))",
                         ai.isEmpty ? "" : "an AI assistant or agent by its name: \(ai.joined(separator: ", "))"].filter { !$0.isEmpty }
            said.append("\(apps.count == 1 ? "1 app has" : "\(apps.count) apps have") access to \(user)'s account"
                + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))")
                + ". The sign-out revokes them all; ask \(user) which they use before they grant them again.")
        }
        if let devices, !devices.isEmpty {
            said.append("\(devices.count == 1 ? "A phone or tablet syncs" : "\(devices.count) phones or tablets sync") \(user)'s account: "
                + "one they don't own may be the attacker's. The reset and the sign-out cut its sync off; to wipe the account "
                + "from it, use the Admin console's Devices."
                + (devices.contains(where: \.reportsCompromise) ? " One reports it's rooted or jailbroken." : ""))
        }
        // Only the computers still signed in: one already blocked or wiped needs nothing more, and is said as such.
        if let computers, case let active = computers.filter(\.isActive), !active.isEmpty {
            let count = active.count, virtual = active.filter(\.looksVirtual).count, stopped = computers.count - count
            let machines = virtual == 0 ? "" : count == 1 ? ", and it's a virtual machine"
                : ", \(virtual) of them \(virtual == 1 ? "a virtual machine" : "virtual machines")"
            said.append("\(count == 1 ? "A computer is" : "\(count) computers are") signed in with \(user)'s account\(machines): one "
                + "they don't use may be the attacker's. The sign-out ends its session; block it or take the account off it below."
                + (active.contains(where: \.reportsCompromise) ? " One reports it's compromised." : "")
                + (stopped == 0 ? "" : " \(stopped) more \(stopped == 1 ? "is" : "are") already blocked or wiped."))
        }
        if let scripts, case let recent = scripts.filter({ $0.isRecent(at: now) }), !recent.isEmpty {
            let names = recent.map { "“\($0.name.isEmpty ? "Untitled" : $0.name)”" }.joined(separator: ", ")
            said.append("\(recent.count == 1 ? "An Apps Script project" : "\(recent.count) Apps Script projects") in \(user)'s Drive "
                + "\(recent.count == 1 ? "was" : "were") made or changed in the last two weeks (\(names)): a script someone authorized keeps "
                + "acting for them on its triggers. The sign-out revokes its access; ask \(user) whether they wrote "
                + (recent.count == 1 ? "it, and delete it from their Drive if not." : "them, and delete any they didn't from their Drive."))
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

    // MARK: scheduled sends

    /// The emails waiting in Gmail's Scheduled to go out at their time: GamGUI's mailbox search (`GamCommands.searchMessages`,
    /// Spam and Trash included) for `in:scheduled`, every one (`cap`), each with its recipients (`MailboxSearch`). Gmail
    /// sends one at its time on its own, with nobody signed in, and it isn't a draft: the drafts' listing never shows it.
    public enum ScheduledSend {
        public static let query = "in:scheduled"
        /// Gmail's label on a scheduled message. Only a message carrying it is deleted as one, whatever the search returned.
        public static let label = "SCHEDULED"
        /// Above the most Gmail lets one person schedule (100, as guides to Gmail say), so a check lists every one.
        public static let cap = 500

        /// Labelled `SCHEDULED` by Gmail: its labels told apart by GAM's own count (a user label's name may hold the word),
        /// and never `SENT`, whose copy holds the only whole Bcc list (review 2026-10-23).
        public static func isScheduled(_ message: MailboxSearch.Message) -> Bool {
            message.labelsCount == message.labels.count && message.labels.contains(label) && !message.labels.contains("SENT")
        }

        /// Everyone the messages go to, each once (case aside), in their order.
        public static func recipients(_ messages: [MailboxSearch.Message]) -> [String] {
            var seen: Set<String> = []
            return messages.flatMap(\.recipients).filter { seen.insert(PythonText.lower($0)).inserted }
        }
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
