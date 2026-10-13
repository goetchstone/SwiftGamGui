import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Calendars screen's writes (GamGUI's `/calendars/share` for one person, and `/calendars/unshare`), through
/// ChangeCore: a change is previewed (held by the executor exactly as it will run), confirmed from its sheet, run
/// once and audited; then the calendar's access is read again. Nothing here runs a `gam` write itself. Sharing
/// with a group, which fans out one subscribe per member, waits for background jobs (C4); deleting a calendar
/// (C3b) and events are later slices.
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
        public enum Kind: Sendable { case share, unshare }

        public let preview: HeldPreview
        public let kind: Kind
        public let title: String
        /// What the confirm button says.
        public let confirmLabel: String
        public let calendarID: String
        public let calendarName: String
        /// Who the change is for: the address shared with, or the rule's token removed.
        public let who: String
        /// Said before the confirm (D5).
        public let warnings: [String]

        public var id: UUID { preview.id }

        /// How the change is undone, in words.
        public var undo: String {
            kind == .share ? "Remove takes this access away again." : "Share it again to give the access back."
        }
    }

    public struct Done: Sendable, Equatable {
        public let message: String
        /// The rule is in but the calendar couldn't be added to their list (GamGUI's amber notice).
        public let partial: Bool

        public init(message: String, partial: Bool) {
            self.message = message
            self.partial = partial
        }
    }

    /// Why nothing changed, or the change failed: `summary` in words, `detail` GAM's own line.
    public struct Problem: Sendable, Equatable {
        public let summary: String
        public let detail: String?

        init(_ summary: String, detail: String? = nil) {
            self.summary = summary
            self.detail = detail
        }
    }

    public private(set) var state: State = .idle
    /// Counts changes that ran: a screen showing the calendar's access reads it again.
    public private(set) var finished = 0
    /// The calendar the current state is about, so a page shows a result only under its own calendar.
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore
    private let groups: GroupStore
    private let reads: CalendarReads
    /// For the one read a share makes before its preview: whether the target is a group.
    private let runner: AuthenticatedRunner?
    /// Tests only: the mock's state folder.
    var environment: [String: String] = [:]

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore, groups: GroupStore, reads: CalendarReads,
                runner: AuthenticatedRunner?) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        self.groups = groups
        self.reads = reads
        self.runner = runner
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the current state is about `calendarID`.
    public func concerns(_ calendarID: String) -> Bool {
        subject.map { Guard.normalized($0) == Guard.normalized(calendarID) } ?? false
    }

    // MARK: previews

    /// GamGUI's `/calendars/share` for one person: the rule (`add_calendar_acl_cal`), then the calendar put in
    /// their list (`subscribe_calendar`) as two steps, the second needing the first. Checked first, none of it
    /// changing the argv for a valid target (D5-D8): one address, a role of the grammar's, not the account GAM
    /// acts as, and a person rather than a group.
    public func previewShare(calendarID: String, name: String, target: String, role: String) async {
        guard !isBusy else { return }
        subject = calendarID
        // The tenant the screen's reads belong to, before any await: a switch during the group check refuses it.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let target = PythonText.strip(target)
        guard !target.isEmpty else { return refuse("Enter a person or group to share with.") }
        if let problem = CalendarSharing.shareTargetProblem(target) { return refuse(problem) }
        let calendarRole: GamCommands.CalendarRole
        do {
            calendarRole = try GamCommands.CalendarRole(validating: role)
        } catch GamCommands.Invalid.argument(let why) {
            return refuse("Couldn't share calendar: \(why).")
        } catch {
            return refuse("Couldn't share calendar.")
        }
        if let actor = CalendarSharing.actingAccount(for: calendarID, admin: setup.connectedAdmin),
           Guard.normalized(actor) == Guard.normalized(target) {
            return refuse(CalendarSharing.ownAccessRefusal)
        }
        switch await kind(of: target, on: tenant?.domain) {
        case .person: break
        case .group:
            return refuse("“\(target)” is a group: sharing with a group adds it for each member, one change each. "
                + "That comes with background jobs; use GamGUI's Calendars for now.")
        case .unknown(let problem):
            return state = .problem(problem)
        }
        let steps = [
            WriteStep(GamCommands.addCalendarACL(calendarID: calendarID, scope: target, role: calendarRole), target: calendarID,
                      summary: "Let \(target) \(CalendarSharing.roleVerb(calendarRole)) on \(name).", about: ["scope": target]),
            WriteStep(GamCommands.subscribeCalendar(email: target, calendarID: calendarID), target: target,
                      summary: "Add \(name) to \(target)'s calendar list.", requires: [0], about: ["calendar": calendarID]),
        ]
        let warnings = CalendarSharing.warnings(target: target, role: calendarRole,
                                                rules: reads.access(.access(calendar: calendarID)))
        await hold(steps, kind: .share, title: "Share \(name) with \(target)", confirmLabel: "Share", calendarID: calendarID,
                   name: name, who: target, warnings: warnings, confirmStep: false, expecting: tenant)
    }

    /// GamGUI's `/calendars/unshare`: one rule removed by its token (`delete_calendar_acl_cal`), from its confirm
    /// step as GamGUI's in-page confirm asked. An owner's rule has no Remove (`_calendar_detail.html:18`).
    public func previewUnshare(calendarID: String, name: String, rule: CalendarACL) async {
        guard !isBusy else { return }
        subject = calendarID
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
                   calendarID: calendarID, name: name, who: token, warnings: [], confirmStep: true, expecting: tenant)
    }

    private func refuse(_ summary: String) {
        state = .problem(Problem(summary))
    }

    private func hold(_ steps: [WriteStep], kind: Pending.Kind, title: String, confirmLabel: String, calendarID: String,
                      name: String, who: String, warnings: [String], confirmStep: Bool,
                      expecting: (domain: Domain, generation: Int)?) async {
        guard let executor else {
            return refuse("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
        }
        switch await executor.preview(steps, confirmStep: confirmStep, expecting: expecting) {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, kind: kind, title: title, confirmLabel: confirmLabel,
                                        calendarID: calendarID, calendarName: name, who: who, warnings: warnings))
        case .failure(let refusal):
            refuse(refusal.message)
        }
    }

    // MARK: who the target is (D6, GamGUI's `_subscribers_for`)

    enum TargetKind: Equatable {
        case person, group
        case unknown(Problem)
    }

    /// An active account in the directory is a person; one of the tenant's groups is a group; otherwise GAM is
    /// asked for the address's members: an answer (even none) is a group, "Does not exist" a person (an outside
    /// address too, whose subscribe may then fail, as in GamGUI). Any other failure says so: GamGUI guessed
    /// "person" there, and a group taken for a person would be shared with no one subscribed.
    func kind(of target: String, on domain: Domain?) async -> TargetKind {
        let key = Guard.normalized(target)
        if directory.users?.contains(where: { !$0.suspended && Guard.normalized($0.primaryEmail) == key }) == true { return .person }
        if groups.group(at: target) != nil { return .group }
        guard let domain, let runner else {
            return .unknown(Problem("Couldn't check whether \(target) is a group: connect a domain on Setup first."))
        }
        let read = GamCommands.printGroupMembers(group: target)
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            if result.exitCode == 0 { return .group }
            let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
            if error.kind == .notFound { return .person }
            return .unknown(Problem("Couldn't check whether \(target) is a group, so nothing was previewed. \(error.remediation)",
                                    detail: error.message))
        } catch {
            let problem = DirectoryStore.problem(for: error, argv: read.argv)
            return .unknown(Problem("Couldn't check whether \(target) is a group, so nothing was previewed. \(problem.summary)",
                                    detail: problem.detail))
        }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows: an older one (the target or
    /// role changed since) never runs, though the executor still holds it. Then the calendar's access is read
    /// again. `confirmation` is what the operator gave; the executor decides whether it's enough.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal { return refuse(refusal) }
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        let who = pending.who
        switch (pending.kind, outcome.steps.first, outcome.steps.dropFirst().first) {
        case (.share, .succeeded, .succeeded?):
            state = .done(Done(message: "Shared with \(who) — it will now appear in their Google Calendar.\(note)", partial: false))
        case (.share, .succeeded, _):
            state = .done(Done(message: "Shared with \(who), but couldn't auto-add it to their calendar list — they can add it "
                + "manually in Google Calendar.\(note)", partial: true))
        case (.unshare, .succeeded, _):
            state = .done(Done(message: "Removed access for \(who).\(note)", partial: false))
        case (_, .failed(let message, let kind)?, _):
            let what = pending.kind == .share ? "Couldn't share the calendar with \(who)." : "Couldn't remove \(who)'s access."
            state = .problem(Problem("\(what) \(Self.remediation(kind))", detail: message))
        case (_, .skipped(let reason)?, _), (_, .waiting(let reason)?, _):
            state = .problem(Problem(reason))
        case (_, nil, _):
            state = .problem(Problem("Nothing ran."))
        }
        if case .succeeded? = outcome.steps.first { finished += 1 }
        await reads.load(.access(calendar: pending.calendarID))
    }

    /// The failure in this screen's words: Google's own-access refusal is GamError's offboarding remediation
    /// (held to GamGUI), which this screen says its own way (D7).
    nonisolated static func remediation(_ kind: GamError.Kind?) -> String {
        kind == .ownACL ? CalendarSharing.ownAccessRefusal : kind?.remediation ?? ""
    }

    /// Back to the page; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }
}
