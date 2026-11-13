import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Calendars screen's writes, through ChangeCore (GamGUI's `web/routes/calendars.py`): sharing with a person or a
/// group (`/share`, `/share/group`), taking access away (`/unshare`), deleting a secondary calendar (`/delete`) and
/// deleting one event (`/event/delete`). A change is previewed (held by the executor exactly as it will run), confirmed
/// from its sheet, run once and audited; then the calendar's access is read again. Nothing here runs a `gam` write
/// itself. A group share is one run of many steps: it is in the jobs tray as it runs, with Stop.
@MainActor
@Observable
public final class CalendarChanges {
    public enum State: Sendable {
        case idle
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(Problem)
    }

    /// A held preview with what the sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public enum Kind: Sendable { case share, shareGroup, unshare, deleteCalendar, deleteEvent }

        /// What the sheet shows beyond the steps.
        public enum Detail: Sendable {
            case none
            /// The group's people the calendar is added for, in GAM's order, and how many of its members it isn't added
            /// for (a group inside it, a suspended account, the customer).
            case group(members: [String], leftOut: Int)
            /// The owner the delete acts as, and how many access rules the calendar had.
            case deleteCalendar(owner: String, accessRules: Int)
            /// The event as read just now.
            case deleteEvent(CalendarEvent)
        }

        public let preview: HeldPreview
        public let kind: Kind
        public let title: String
        /// What the confirm button says.
        public let confirmLabel: String
        public let calendarID: String
        public let calendarName: String
        /// Who the change is for: the address shared with, the rule's token removed, the owner, the event's ID.
        public let who: String
        /// Said before the confirm (D5).
        public let warnings: [String]
        public let detail: Detail

        public var id: UUID { preview.id }

        public var isDestructive: Bool { preview.decision.maxRisk == .destructive }

        /// How the change is undone, in words.
        public var undo: String {
            switch kind {
            case .share, .shareGroup: "Remove takes this access away again."
            case .unshare: "Share it again to give the access back."
            case .deleteCalendar: "This can't be undone: the calendar and all of its events are gone for everyone."
            case .deleteEvent: "This can't be undone from here."
            }
        }

        /// The members a group share adds the calendar for.
        public var members: [String] {
            if case .group(let members, _) = detail { return members }
            return []
        }
    }

    public struct Done: Sendable, Equatable {
        public let message: String
        /// Done, but not all of it: the rule is in but the calendar couldn't be added to every list (GamGUI's amber notice).
        public let partial: Bool
        /// A group share: each member it couldn't be added for, with why (the first `failuresKept`), and how many in all.
        public let failures: [String]
        public let failedCount: Int
        /// A calendar deleted: its ID, so the screen leaves its page.
        public let deletedCalendar: String?

        public init(message: String, partial: Bool, failures: [String] = [], failedCount: Int = 0, deletedCalendar: String? = nil) {
            self.message = message
            self.partial = partial
            self.failures = failures
            self.failedCount = failedCount
            self.deletedCalendar = deletedCalendar
        }
    }

    /// Why nothing changed, or the change failed: `summary` in words, `detail` GAM's own line.
    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
        public let detail: String?

        init(_ summary: String, detail: String? = nil) {
            self.summary = summary
            self.detail = detail
        }
    }

    /// A group share as it runs: its subscribes counted as each ends.
    public struct Progress: Sendable, Equatable {
        public var total: Int
        public var added = 0
        public var failed = 0
        public var stopping = false
        public var done: Int { added + failed }
    }

    /// GamGUI's `_CONFIRM_SAMPLE`: the members named on a group share's confirm step (the count is always the full one).
    public nonisolated static let confirmSample = 10
    /// The members a finished group share names as not added (invariant 9; GamGUI's `FAILED_SAMPLE_CAP`).
    public nonisolated static let failuresKept = 200

    public private(set) var state: State = .idle
    /// Counts changes that ran: a screen showing the calendar's access reads it again.
    public private(set) var finished = 0
    /// The calendar the current state is about, so a page shows a result only under its own calendar.
    public private(set) var subject: String?
    /// A group share running: how far it is.
    public private(set) var progress: Progress?
    /// What the operator typed didn't match (a calendar delete's DELETE, a group share's count): said on its sheet, which
    /// stays, and its preview isn't spent. Cleared once the typing changes (`typingChanged`).
    public private(set) var typedProblem: String?
    /// Counts each typed refusal, so the sheet says it again on a repeated wrong attempt, not only the first.
    public private(set) var typedRefusals = 0
    /// The page's event search.
    public let events: CalendarEventSearch
    /// Each preview, edit and dismissal counts one: a preview whose reads end after a newer one began (or after the form
    /// changed) holds nothing the sheet shows, so a slow group read never puts an older target on the confirm.
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let groups: GroupStore
    private let reads: CalendarReads
    /// For the reads a change makes before its preview: whether the target is a group and who is in it, an event.
    private let runner: AuthenticatedRunner?
    /// Tests only: the mock's state folder.
    var environment: [String: String] = [:] {
        didSet { events.environment = environment }
    }

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, groups: GroupStore, reads: CalendarReads,
                runner: AuthenticatedRunner?) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.groups = groups
        self.reads = reads
        self.runner = runner
        events = CalendarEventSearch(setup: setup, runner: runner)
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the current state is about `calendarID`.
    public func concerns(_ calendarID: String) -> Bool {
        subject.map { Guard.normalized($0) == Guard.normalized(calendarID) } ?? false
    }

    /// A preview begins: about `calendarID`, newer than any still reading.
    private func begin(_ calendarID: String) -> Int {
        subject = calendarID
        typedProblem = nil
        serial += 1
        return serial
    }

    /// Whether the preview numbered `serial` is still the newest: no other began, the form wasn't edited.
    private func isCurrent(_ serial: Int) -> Bool { serial == self.serial }

    /// The page's calendar, or its share form's target or role, changed: a preview still reading is dropped when it ends.
    /// One already shown stays: its sheet is modal, and the form clears its target once the sheet opens.
    public func edited() {
        serial += 1
    }

    /// The directory's active people, lowercased (GamGUI's `_active_emails`), or nil before it is loaded.
    public var activeAddresses: Set<String>? {
        directory.users.map { users in Set(users.filter { !$0.suspended }.map { PythonText.lower($0.primaryEmail) }) }
    }

    // MARK: sharing

    /// GamGUI's `/calendars/share`: the rule (`add_calendar_acl_cal`), then the calendar put in the list of whoever it
    /// is for (`subscribe_calendar`): a person's, as a second step needing the first; a group's active members', one
    /// step each, from a confirm step that names their count. Checked first, none of it changing the argv for a valid
    /// target (D5-D8): one address, a role of the grammar's, not the account GAM acts as.
    public func previewShare(calendarID: String, name: String, target: String, role: String) async {
        guard !isBusy else { return }
        let serial = begin(calendarID)
        // The tenant the screen's reads belong to, before any await: a switch during the group check refuses it.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let target = PythonText.strip(target)
        guard !target.isEmpty else { return refuse("Enter a person or group to share with.") }
        if let problem = CalendarSharing.calendarTargetProblem(target) { return refuse(problem) }
        let calendarRole: GamCommands.CalendarRole
        do {
            calendarRole = try GamCommands.CalendarRole(validating: role)
        } catch GamCommands.Invalid.argument(let why) {
            return refuse("Couldn't share calendar: \(why).")
        } catch {
            return refuse("Couldn't share calendar.")
        }
        let rules = reads.access(.access(calendar: calendarID))
        // `group:` and one address (GAM's `<CalendarACLScope>`, GamGUI's `_subscribers_for`): a group, said so, never
        // looked up as a person.
        if let group = CalendarSharing.explicitGroup(target) {
            return await previewShareGroup(calendarID: calendarID, name: name, group: group, role: calendarRole, members: nil,
                                           explicit: true, rules: rules, tenant: tenant, serial: serial)
        }
        if let actor = CalendarSharing.actingAccount(for: calendarID, admin: setup.connectedAdmin),
           Guard.normalized(actor) == Guard.normalized(target) {
            return refuse(CalendarSharing.ownAccessRefusal)
        }
        let kind = await kind(of: target, on: tenant?.domain)
        guard isCurrent(serial) else { return }
        switch kind {
        case .person:
            let steps = [
                WriteStep(GamCommands.addCalendarACL(calendarID: calendarID, scope: target, role: calendarRole), target: calendarID,
                          summary: "Let \(target) \(CalendarSharing.roleVerb(calendarRole)) on \(name).", about: ["scope": target]),
                WriteStep(GamCommands.subscribeCalendar(email: target, calendarID: calendarID), target: target,
                          summary: "Add \(name) to \(target)'s calendar list.", requires: [0], about: ["calendar": calendarID]),
            ]
            let warnings = CalendarSharing.warnings(target: target, role: calendarRole, rules: rules)
            await hold(steps, kind: .share, title: "Share \(name) with \(target)", confirmLabel: "Share", calendarID: calendarID,
                       name: name, who: target, warnings: warnings, detail: .none, confirmStep: false, expecting: tenant,
                       serial: serial)
        case .group(let members):
            await previewShareGroup(calendarID: calendarID, name: name, group: target, role: calendarRole, members: members,
                                    explicit: false, rules: rules, tenant: tenant, serial: serial)
        case .unknown(let problem):
            state = .problem(problem)
        }
    }

    /// A group (GamGUI's `_subscribers_for` and `_grant_and_subscribe`): the rule for the group, then the calendar added
    /// to each active member's list, one step each, each needing the rule. The members are read now and held: the
    /// confirm runs exactly these. Three deliberate differences from GamGUI: the rule's scope is `group:<address>` (GAM
    /// reads a bare address as a person's rule, `normalizeRuleId`); only members who are active people get a step (a
    /// group inside it, or a suspended account, would only fail); and a `group:` target that GAM says is no group is
    /// refused (`explicit`), where GamGUI shared with it and subscribed nobody.
    private func previewShareGroup(calendarID: String, name: String, group: String, role: GamCommands.CalendarRole,
                                   members known: [GroupMember]?, explicit: Bool, rules: [CalendarACL]?,
                                   tenant: (domain: Domain, generation: Int)?, serial: Int) async {
        let read: [GroupMember]
        if let known {
            read = known
        } else {
            let found = await members(of: group, on: tenant?.domain)
            guard isCurrent(serial) else { return }
            switch found {
            case .members(let members): read = members
            case .notAGroup: return refuse(explicit ? "\(group) isn't a group here." : "\(group) isn't a group any more.")
            case .problem(let problem): return state = .problem(problem)
            }
        }
        let people = Self.activePeople(read)
        let scope = "group:\(group)"
        var steps = [WriteStep(GamCommands.addCalendarACL(calendarID: calendarID, scope: scope, role: role), target: calendarID,
                               summary: "Let the group \(group) \(CalendarSharing.roleVerb(role)) on \(name).", about: ["scope": scope])]
        for person in people {
            steps.append(WriteStep(GamCommands.subscribeCalendar(email: person, calendarID: calendarID), target: person,
                                   summary: "Add \(name) to \(person)'s calendar list.", requires: [0],
                                   about: ["calendar": calendarID, "group": group]))
        }
        var warnings: [String] = []
        let key = PythonText.lower(group)
        if let existing = rules?.first(where: { $0.scopeType == "group" && PythonText.lower($0.scopeValue) == key }) {
            warnings.append(existing.role == CalendarSharing.storedRole(role)
                ? "\(group) already has this access (\(existing.roleLabel))."
                : "\(group) already has access (\(existing.roleLabel)): sharing changes it to \(CalendarACL.label(forRole: role.rawValue)).")
        }
        if role == .owner { warnings.append("Owners can change sharing and delete the calendar.") }
        let leftOut = read.count - people.count
        let count = people.count
        let jobTitle = "Share \(name) with \(group) and add it to \(count) member\(count == 1 ? "'s calendar" : "s' calendars")"
        await hold(steps, kind: .shareGroup, title: "Share \(name) with \(group)", confirmLabel: "Share", calendarID: calendarID,
                   name: name, who: group, warnings: warnings, detail: .group(members: people, leftOut: leftOut), confirmStep: true,
                   typedCountAbove: Guard.bulkThreshold, jobTitle: jobTitle, expecting: tenant, serial: serial)
    }

    /// The members a calendar is added for: people (`USER`) whose membership is active, with an address, once each, in
    /// GAM's order.
    nonisolated static func activePeople(_ members: [GroupMember]) -> [String] {
        var seen: Set<String> = [], people: [String] = []
        for member in members where member.memberType == "USER" && PythonText.upper(member.status) == "ACTIVE"
            && member.email.unicodeScalars.contains("@") && seen.insert(Guard.normalized(member.email)).inserted {
            people.append(member.email)
        }
        return people
    }

    /// GamGUI's `/calendars/unshare`: one rule removed by its token (`delete_calendar_acl_cal`), from its confirm
    /// step as GamGUI's in-page confirm asked. An owner's rule has no Remove (`_calendar_detail.html:18`).
    public func previewUnshare(calendarID: String, name: String, rule: CalendarACL) async {
        guard !isBusy else { return }
        let serial = begin(calendarID)
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard !rule.isOwner else { return refuse("\(rule.who) owns \(name): an owner's access isn't removed here.") }
        if let problem = CalendarSharing.unshareProblem(rule) { return refuse(problem) }
        if rule.scopeType == "user", let actor = CalendarSharing.actingAccount(for: calendarID, admin: setup.connectedAdmin),
           Guard.normalized(actor) == Guard.normalized(rule.scopeValue) {
            return refuse(CalendarSharing.ownAccessRefusal)
        }
        let token = rule.scopeToken
        let step = WriteStep(GamCommands.deleteCalendarACL(calendarID: calendarID, scope: token), target: calendarID,
                             summary: "Remove \(rule.who)'s access (\(rule.roleLabel)) to \(name).", about: ["scope": token])
        await hold([step], kind: .unshare, title: "Remove \(rule.who)'s access to \(name)", confirmLabel: "Remove",
                   calendarID: calendarID, name: name, who: token, warnings: [], detail: .none, confirmStep: true, expecting: tenant,
                   serial: serial)
    }

    // MARK: deleting

    /// GamGUI's `/calendars/delete/preview`: a secondary calendar, deleted for everyone acting as its data owner
    /// (`remove_calendar`, GAM's `remove calendars`). Who it acts as is the data owner read now (`print settings`), while the
    /// directory has them active, never taken from the screen and never another owner (GamGUI's `_resolve_delete_owner` took
    /// the first active owner rule: a listed deviation); the run reads the data owner again first and is refused if it
    /// changed, or the account is no longer active. The confirm wants DELETE
    /// typed, in capitals: the executor holds that word with the preview and refuses a run without it.
    public func previewDeleteCalendar(calendarID: String, name: String) async {
        guard !isBusy else { return }
        let serial = begin(calendarID)
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard CalendarDeletion.isSecondary(calendarID) else { return refuse(CalendarDeletion.notSecondary) }
        guard let active = activeAddresses else {
            return refuse("Load the directory (Home or Users) first: the owner the delete acts as must be an active account.")
        }
        let read = CalendarReads.Read.access(calendar: calendarID)
        await reads.load(read)
        guard isCurrent(serial) else { return }
        if let problem = reads.problem(for: read) { return state = .problem(Problem(problem.summary, detail: problem.detail)) }
        guard let rules = reads.access(read) else { return refuse("Couldn't read who has access to \(name), so nothing was previewed.") }
        guard let domain = tenant?.domain, let runner else { return refuse("Connect a domain on Setup first.") }
        let dataOwner: String?
        switch await Self.readDataOwner(calendarID, runner: runner, domain: domain, environment: environment) {
        case .owner(let found): dataOwner = found
        case .gone:
            guard isCurrent(serial) else { return }
            return refuse(Self.calendarGone)
        case .failed(let problem):
            guard isCurrent(serial) else { return }
            return state = .problem(Problem("Couldn't read who owns \(name), so nothing was previewed. \(problem.summary)",
                                            detail: problem.detail))
        }
        guard isCurrent(serial) else { return }
        let owner: String
        switch CalendarDeletion.owner(of: calendarID, dataOwner: dataOwner, active: active) {
        case .owner(let found): owner = found
        case .refused(let why): return refuse(why)
        }
        let precondition = ownerStillOwns(owner, calendarID: calendarID, domain: domain)
        let step = WriteStep(GamCommands.removeCalendar(owner: owner, calendarID: calendarID), target: calendarID,
                             summary: "Delete \(name) and all of its events, for everyone, acting as its owner \(owner).",
                             risk: .destructive, about: ["owner": owner])
        await hold([step], kind: .deleteCalendar, title: "Delete \(name)", confirmLabel: "Delete Calendar", calendarID: calendarID,
                   name: name, who: owner, warnings: [], detail: .deleteCalendar(owner: owner, accessRules: rules.count),
                   confirmStep: true, typedWord: CalendarDeletion.typedWord, expecting: tenant, precondition: precondition, serial: serial)
    }

    /// The run's check (GamGUI's delete re-resolves the owner, `_resolve_delete_owner`): the calendar's data owner read again
    /// (`print settings`), still `owner`, and their account read now (`info user`) still active: GAM can't act as a suspended or
    /// deleted account. Never another owner instead: the operator previews again. Each failure is said in fixed words, never
    /// an error's type name.
    private func ownerStillOwns(_ owner: String, calendarID: String, domain: Domain) -> @Sendable () async throws -> Bool {
        let runner = runner, environment = environment
        return {
            guard let runner else { throw PreconditionRefusal("Connect a domain on Setup first.") }
            switch await Self.readDataOwner(calendarID, runner: runner, domain: domain, environment: environment) {
            case .gone: throw PreconditionRefusal(Self.calendarGoneAtRun)
            case .failed(let problem):
                throw PreconditionFailure("Couldn't check who owns the calendar before deleting it. \(problem.summary)")
            case .owner(let found):
                guard let found, Guard.normalized(found) == Guard.normalized(owner) else {
                    throw PreconditionRefusal("\(owner) is no longer this calendar's owner \u{2014} preview the delete again.")
                }
            }
            let info = GamCommands.infoUser(email: owner, fields: ["primaryEmail", "suspended"])
            let inactive = PreconditionRefusal("\(owner) is suspended or no longer exists \u{2014} preview the delete again.")
            let account: GamResult
            do {
                account = try await runner.run(info, as: domain, extraEnvironment: environment)
            } catch {
                throw PreconditionFailure("Couldn't check that \(owner) is still active. "
                    + DirectoryStore.problem(for: error, argv: info.argv).summary)
            }
            guard account.exitCode == 0 else {
                let error = GamError(exitCode: account.exitCode, stderr: account.stderr, argv: info.argv)
                if error.kind == .notFound { throw inactive }
                throw PreconditionFailure("Couldn't check that \(owner) is still active. \(error.remediation)")
            }
            if GamUser(record: GamOutput.one(account.stdout)).suspended { throw inactive }
            return true
        }
    }

    /// A calendar Google can't find: at the preview, and at the run (nothing ran).
    public nonisolated static let calendarGone = "That calendar no longer exists."
    public nonisolated static let calendarGoneAtRun = "That calendar no longer exists \u{2014} nothing was deleted."

    /// What the data owner read found.
    enum OwnerRead: Sendable {
        /// The data owner Google names, or nil when it names none.
        case owner(String?)
        /// Google has no such calendar (GAM's "Not Found").
        case gone
        /// Couldn't read it: the remediation in `summary`, GAM's line in `detail`.
        case failed(Problem)
    }

    /// The calendar's data owner read now (`print settings fields id,dataowner`): GAM's `Owner`, Google's `dataOwner`.
    nonisolated static func readDataOwner(_ calendarID: String, runner: AuthenticatedRunner, domain: Domain,
                                          environment: [String: String]) async -> OwnerRead {
        let command = GamCommands.printCalendarSettings(calendarID: calendarID)
        do {
            let output = try await runner.run(command, as: domain, extraEnvironment: environment)
            guard output.exitCode == 0 else {
                let error = GamError(exitCode: output.exitCode, stderr: output.stderr, argv: command.argv, stdout: output.stdout)
                if error.kind == .notFound { return .gone }
                return .failed(Problem(error.remediation, detail: error.message))
            }
            guard !output.stdoutTruncated else { return .failed(Problem("GAM's answer was longer than one call can return.")) }
            return .owner(CalendarDeletion.dataOwner(GamOutput.records(output.stdout)))
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: command.argv)
            return .failed(Problem(problem.summary, detail: problem.detail))
        }
    }

    /// GamGUI's `/calendars/event/preview`: the event read again now (`get_event`), then its delete held (`delete_event`,
    /// with `doit`, and no updates sent). A series' event deletes every occurrence, which the sheet says. The run reads it
    /// again first: one deleted since is refused.
    public func previewDeleteEvent(calendarID: String, name: String, eventID: String) async {
        guard !isBusy else { return }
        let serial = begin(calendarID)
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        guard let domain = tenant?.domain, let runner else { return refuse("Connect a domain on Setup first.") }
        let event: CalendarEvent
        let read = await Self.readEvent(eventID, on: calendarID, runner: runner, domain: domain, environment: environment)
        guard isCurrent(serial) else { return }
        switch read {
        case .success(let found?): event = found
        case .success(nil): return refuse(Self.eventGone)
        case .failure(let problem):
            return state = .problem(Problem("Couldn't read the event, so nothing was previewed. \(problem.summary)", detail: problem.detail))
        }
        let environment = environment
        let shown = (recurrence: event.recurrence, recurringEventID: event.recurringEventID)
        let precondition: @Sendable () async throws -> Bool = {
            switch await Self.readEvent(eventID, on: calendarID, runner: runner, domain: domain, environment: environment) {
            case .success(nil): throw PreconditionRefusal(Self.eventGone)
            case .success(let found?):
                // A series' event deletes every occurrence, an instance's only one: what the sheet said must still hold.
                guard found.recurrence == shown.recurrence, found.recurringEventID == shown.recurringEventID else {
                    throw PreconditionRefusal(Self.eventChanged)
                }
                return true
            case .failure(let problem): throw PreconditionFailure("Couldn't re-read the event before deleting it. \(problem.summary)")
            }
        }
        let warnings = Self.deleteWarnings(event)
        let step = WriteStep(GamCommands.deleteEvent(calendarID: calendarID, eventID: eventID), target: calendarID,
                             summary: "Delete \u{201C}\(event.summary)\u{201D} (\(event.when)) from \(name).", risk: .destructive,
                             about: ["event": eventID])
        await hold([step], kind: .deleteEvent, title: "Delete \u{201C}\(event.summary)\u{201D}", confirmLabel: "Delete Event",
                   calendarID: calendarID, name: name, who: eventID, warnings: warnings, detail: .deleteEvent(event),
                   confirmStep: true, expecting: tenant, precondition: precondition, serial: serial)
    }

    /// What an event's delete says first. A series (it has rules and is no one's instance) loses every occurrence, in
    /// GamGUI's words. An instance (Google's `recurringEventId` is set: "for an instance of a recurring event, the id of
    /// the recurring event to which this instance belongs", Events reference) is deleted by its own ID, which cancels that
    /// one occurrence only: a deliberate difference from GamGUI's `_event_delete.html`, which warned of the whole series.
    nonisolated static func deleteWarnings(_ event: CalendarEvent) -> [String] {
        if !event.recurringEventID.isEmpty {
            return ["One occurrence of a recurring event \u{2014} deleting removes only this occurrence; the rest of the series stays."]
        }
        if !event.recurrence.isEmpty { return ["Recurring event \u{2014} deleting removes the entire series (all occurrences)."] }
        return []
    }

    /// GamGUI's words for an event that isn't there any more.
    public nonisolated static let eventGone = "That event no longer exists."
    /// An event made a series, or no longer one, since its preview: what the delete removes isn't what the sheet said.
    public nonisolated static let eventChanged = "That event has changed since the preview (whether it repeats) \u{2014} nothing "
        + "was deleted. Preview the delete again."

    /// One event read now: nil when Google has no such event (GAM's "Not Found") or it is deleted (`status` "cancelled":
    /// Google's events.get always returns a deleted event, Events reference; a 410 "Resource has been deleted" is read the
    /// same way), else the event, or why it couldn't be read (the remediation in `summary`, GAM's line in `detail`).
    nonisolated static func readEvent(_ eventID: String, on calendarID: String, runner: AuthenticatedRunner, domain: Domain,
                                      environment: [String: String]) async -> Result<CalendarEvent?, Problem> {
        let command = GamCommands.getEvent(calendarID: calendarID, eventID: eventID)
        do {
            let output = try await runner.run(command, as: domain, extraEnvironment: environment)
            if output.exitCode != 0 {
                let error = GamError(exitCode: output.exitCode, stderr: output.stderr, argv: command.argv, stdout: output.stdout)
                if output.exitCode == 50, error.kind == .notFound || output.stderr.contains("Resource has been deleted") {
                    return .success(nil)
                }
                return .failure(Problem(error.remediation, detail: error.message))
            }
            let event = GamOutput.records(output.stdout).map(CalendarEvent.init(record:)).first { $0.eventID == eventID }
            guard let event, event.status != "cancelled" else { return .success(nil) }
            return .success(event)
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: command.argv)
            return .failure(Problem(problem.summary, detail: problem.detail))
        }
    }

    private func refuse(_ summary: String) {
        state = .problem(Problem(summary))
    }

    /// The typed word or count didn't match: said on the sheet, counted so a repeat is said again; nothing runs.
    private func refuseTyped(_ why: String) {
        typedProblem = why
        typedRefusals += 1
    }

    /// The count a group share wants typed, in words.
    public nonisolated static func typedCountRefusal(_ count: Int) -> String {
        "Type \(count), the number of changes, to confirm."
    }

    /// The typed word or count changed: an earlier mismatch no longer stands.
    public func typingChanged() {
        typedProblem = nil
    }

    private func hold(_ steps: [WriteStep], kind: Pending.Kind, title: String, confirmLabel: String, calendarID: String,
                      name: String, who: String, warnings: [String], detail: Pending.Detail, confirmStep: Bool,
                      typedCountAbove: Int? = nil, typedWord: String? = nil, jobTitle: String = "",
                      expecting: (domain: Domain, generation: Int)?, precondition: (@Sendable () async throws -> Bool)? = nil,
                      serial: Int) async {
        guard let executor else {
            return refuse("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
        }
        let held = await executor.preview(steps, confirmStep: confirmStep, typedCountAbove: typedCountAbove, expecting: expecting,
                                          typedExactWord: typedWord, title: jobTitle, precondition: precondition)
        // A newer preview began, or the form changed, while this was being held: it's dropped, never shown.
        guard isCurrent(serial) else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, kind: kind, title: title, confirmLabel: confirmLabel,
                                        calendarID: calendarID, calendarName: name, who: who, warnings: warnings, detail: detail))
        case .failure(let refusal):
            refuse(refusal.message)
        }
    }

    // MARK: who the target is (D6, GamGUI's `_subscribers_for`)

    enum TargetKind {
        case person
        /// A group, with its members when they were read to find that out.
        case group([GroupMember]?)
        case unknown(Problem)
    }

    /// An active account in the directory is a person; one of the tenant's groups is a group; otherwise GAM is
    /// asked for the address's members: an answer (even none) is a group, "Does not exist" a person (an outside
    /// address too, whose subscribe may then fail, as in GamGUI). Any other failure says so: GamGUI guessed
    /// "person" there, and a group taken for a person would be shared with no one subscribed.
    func kind(of target: String, on domain: Domain?) async -> TargetKind {
        let key = Guard.normalized(target)
        if directory.users?.contains(where: { !$0.suspended && Guard.normalized($0.primaryEmail) == key }) == true { return .person }
        if groups.group(at: target) != nil { return .group(nil) }
        switch await members(of: target, on: domain) {
        case .members(let members): return .group(members)
        case .notAGroup: return .person
        case .problem(let problem): return .unknown(problem)
        }
    }

    enum MembersRead {
        case members([GroupMember])
        /// GAM's "Does not exist" for the address.
        case notAGroup
        case problem(Problem)
    }

    /// `print group-members group <address>`: the members GAM lists, not a group, or the problem.
    private func members(of group: String, on domain: Domain?) async -> MembersRead {
        guard let domain, let runner else {
            return .problem(Problem("Couldn't check whether \(group) is a group: connect a domain on Setup first."))
        }
        let read = GamCommands.printGroupMembers(group: group)
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            if result.exitCode == 0 {
                guard !result.stdoutTruncated else {
                    return .problem(Problem("\(group) has more members than one call can return, so nothing was previewed."))
                }
                return .members(GamOutput.records(result.stdout).map(GroupMember.init(record:)))
            }
            let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
            if error.kind == .notFound { return .notAGroup }
            return .problem(Problem("Couldn't check whether \(group) is a group, so nothing was previewed. \(error.remediation)",
                                    detail: error.message))
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: read.argv)
            return .problem(Problem("Couldn't check whether \(group) is a group, so nothing was previewed. \(problem.summary)",
                                    detail: problem.detail))
        }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows: an older one (the target or
    /// role changed since) never runs, though the executor still holds it. Then the calendar's access is read
    /// again. `confirmation` is what the operator gave; the executor decides whether it's enough. A calendar delete
    /// also wants its `typedWord` to be DELETE (GamGUI's exact-case gate), and a large group share the number of changes
    /// typed (the guard's): the executor refuses a run without them, and a mistyped one is said here first, so the sheet
    /// stays and its preview isn't spent (the executor spends a preview it refuses).
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        if pending.kind == .deleteCalendar, !CalendarDeletion.typedMatches(confirmation.typedWord) {
            return refuseTyped(CalendarDeletion.typedRefusal)
        }
        let decision = pending.preview.decision
        if !decision.typedCountMatches(confirmation.typedCount) {
            return refuseTyped(Self.typedCountRefusal(decision.affectedCount))
        }
        typedProblem = nil
        state = .running(pending)
        let outcome: RunOutcome
        if pending.kind == .shareGroup {
            outcome = await runWithProgress(pending, confirmation, executor: executor)
        } else {
            outcome = await executor.run(pending.preview, confirmation: confirmation)
        }
        progress = nil
        if let refusal = outcome.refusal { return refuse(refusal) }
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        let who = pending.who
        switch (pending.kind, outcome.steps.first, outcome.steps.dropFirst().first) {
        case (_, .failed(let message, let kind)?, _):
            let what = switch pending.kind {
            case .share, .shareGroup: "Couldn't share the calendar with \(who)."
            case .unshare: "Couldn't remove \(who)'s access."
            case .deleteCalendar: "Couldn't delete the calendar."
            case .deleteEvent: "Couldn't delete the event."
            }
            state = .problem(Problem("\(what) \(Self.remediation(kind))", detail: message))
        case (_, .skipped(let reason)?, _), (_, .waiting(let reason)?, _):
            state = .problem(Problem(reason))
        case (_, nil, _):
            state = .problem(Problem("Nothing ran."))
        case (.share, .succeeded, .succeeded?):
            state = .done(Done(message: "Shared with \(who) — it will now appear in their Google Calendar.\(note)", partial: false))
        case (.share, .succeeded, _):
            state = .done(Done(message: "Shared with \(who), but couldn't auto-add it to their calendar list — they can add it "
                + "manually in Google Calendar.\(note)", partial: true))
        case (.shareGroup, .succeeded, _):
            state = .done(Self.groupDone(pending, outcome.steps, note: note))
        case (.unshare, .succeeded, _):
            state = .done(Done(message: "Removed access for \(who).\(note)", partial: false))
        case (.deleteCalendar, .succeeded, _):
            reads.forget(calendar: pending.calendarID)
            state = .done(Done(message: "Calendar deleted: \u{201C}\(pending.calendarName)\u{201D}.\(note)", partial: false,
                               deletedCalendar: pending.calendarID))
        case (.deleteEvent, .succeeded, _):
            events.forget(eventID: who, on: pending.calendarID)
            state = .done(Done(message: "Event deleted.\(note)", partial: false))
        }
        if case .succeeded? = outcome.steps.first { finished += 1 }
        if pending.kind != .deleteCalendar { await reads.load(.access(calendar: pending.calendarID)) }
    }

    /// A group share's run, counted as each subscribe ends.
    private func runWithProgress(_ pending: Pending, _ confirmation: OperatorConfirmation, executor: Executor) async -> RunOutcome {
        progress = Progress(total: pending.members.count)
        let (events, observer) = AsyncStream<(Int, RunOutcome.Step)>.makeStream()
        let watcher = Task { @MainActor [weak self] in
            for await (index, result) in events where index > 0 {
                switch result {
                case .succeeded: self?.progress?.added += 1
                case .failed, .waiting: self?.progress?.failed += 1
                // A step never begun (a Stop, an account-wide failure, a tenant switch) isn't a failure: the result counts
                // it as not attempted.
                case .skipped: break
                }
            }
        }
        let outcome = await executor.run(pending.preview, confirmation: confirmation, progress: observer)
        observer.finish()
        await watcher.value
        return outcome
    }

    /// Stop a group share after the subscribe in flight (GamGUI's Stop): the rest read "Not run: stopped."
    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        guard await executor.stopAfterCurrentStep(pending.id) else { return }
        progress?.stopping = true
    }

    /// GamGUI's group results (`_calendar_subscribe_job.html`, `stop_requested`, `stop_reason`): where it now appears,
    /// who it couldn't be added for, or why it stopped and how many weren't attempted. A member whose subscribe never began
    /// (the operator's Stop, an account-wide failure, a tenant switch, a cancel) is not attempted, never a failure.
    nonisolated static func groupDone(_ pending: Pending, _ steps: [RunOutcome.Step], note: String) -> Done {
        let members = pending.members, total = members.count
        guard total > 0 else {
            return Done(message: "Shared with \(pending.who), but that group has no members to add it for.\(note)", partial: false)
        }
        var added = 0, failures: [String] = [], failed = 0, notRun = 0, stoppedBy: String?
        for (index, member) in members.enumerated() {
            let step = index + 1 < steps.count ? steps[index + 1] : nil
            let why: String
            switch step {
            case .succeeded?:
                added += 1
                continue
            case .skipped(let reason)?:
                notRun += 1
                if stoppedBy == nil { stoppedBy = reason }
                continue
            case nil:
                notRun += 1
                continue
            case .failed(let message, let kind)?: why = kind?.remediation ?? message
            case .waiting(let message)?: why = message
            }
            failed += 1
            if failures.count < failuresKept { failures.append("\(member) \u{2014} \(why)") }
        }
        let whose = total == 1 ? "member's" : "members'"
        if notRun > 0 {
            let why = stoppedBy == Executor.stopped || stoppedBy == nil ? "Stopped by you \u{2014} \(notRun) not attempted."
                : "\(stoppedBy!) The remaining \(notRun) \(notRun == 1 ? "was" : "were") not attempted."
            return Done(message: "\(why) Added to \(added) of \(total) \(whose) calendars before stopping.\(note)", partial: true,
                        failures: failures, failedCount: failed)
        }
        let appears = "Shared with \(pending.who). It now appears in \(added) of \(total) \(whose) Google Calendars."
        guard failed > 0 else { return Done(message: appears + note, partial: false) }
        return Done(message: appears + " Couldn't add it for \(failed) \u{2014} they can add it manually.\(note)", partial: true,
                    failures: failures, failedCount: failed)
    }

    /// The failure in this screen's words: Google's own-access refusal is GamError's offboarding remediation
    /// (held to GamGUI), which this screen says its own way (D7).
    nonisolated static func remediation(_ kind: GamError.Kind?) -> String {
        kind == .ownACL ? CalendarSharing.ownAccessRefusal : kind?.remediation ?? ""
    }

    #if DEBUG
    /// Debug builds' screenshots only: `done` shown as `calendarID`'s last result. Nothing is held and no `gam` runs.
    public func showDemo(_ done: Done, about calendarID: String) {
        guard !isBusy else { return }
        subject = calendarID
        state = .done(done)
    }
    #endif

    /// Back to the page; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        state = .idle
    }
}
