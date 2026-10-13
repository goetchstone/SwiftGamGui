import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// The Groups screen's writes (GamGUI's `/groups/members` add and `/groups/members/remove`), through
/// ChangeCore: people added to the open group with a role, or a member removed, each previewed (held by the
/// executor exactly as it will run), confirmed from its sheet, run once and audited; then the group's
/// members are read again, as GamGUI's board reads them after every write. Nothing here runs `gam` itself.
///
/// One deliberate difference from GamGUI, whose form adds one person: several addresses (one per line, or
/// separated by commas or semicolons) are one preview with one GamGUI step each, and the guard's rules for
/// many targets apply (the count typed above 25).
@MainActor
@Observable
public final class GroupChanges {
    public enum State: Sendable {
        case idle
        /// The preview the sheet shows; confirming runs exactly this.
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(Problem)
    }

    /// A held preview with what the confirm sheet says about it.
    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        /// The group's address, as listed.
        public let group: String
        public let title: String
        /// What the confirm button says.
        public let confirmLabel: String
        /// Each step's member address, as held.
        public let members: [String]
        /// Said before the confirm: the removed member's role and what leaving means.
        public let notes: [String]
        let adding: GamCommands.GroupRole?

        public var id: UUID { preview.id }
        /// People are added (else a member is removed).
        public var isAdding: Bool { adding != nil }
    }

    /// Why nothing changed, or not everything did: `summary` in words, `detail` GAM's own errors.
    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
        public let detail: String?

        init(_ summary: String, detail: String? = nil) {
            self.summary = summary
            self.detail = detail
        }
    }

    /// GamGUI's `PICK_LIMIT`: people suggested at once; typing more narrows them.
    public nonisolated static let pickLimit = 15
    /// Failures said by name in a result; the rest are counted (invariant 9).
    nonisolated static let failuresSaid = 5

    public private(set) var state: State = .idle
    /// The group the current state is about (as `Guard` compares addresses), so its page alone shows it.
    public private(set) var subject: String?
    private let executor: Executor?
    private let setup: SetupModel
    private let members: GroupMembers

    public init(executor: Executor?, setup: SetupModel, members: GroupMembers) {
        self.executor = executor
        self.setup = setup
        self.members = members
    }

    public var isBusy: Bool {
        if case .running = state { return true }
        return false
    }

    /// Whether the current state is about `group`.
    public func concerns(_ group: String) -> Bool {
        subject.map { $0 == Guard.normalized(group) } ?? false
    }

    // MARK: previews

    /// GamGUI's `add_member`, refusing in its order and words before anything is held: the group, then an
    /// empty list, then each address that isn't one address. GAM reads a bare name, `oauthuser` or a list
    /// as someone else. No directory check: GamGUI makes none, and GAM says who it doesn't know.
    public func previewAdd(_ addresses: String, to group: GamGroup, role: GamCommands.GroupRole) async {
        guard !isBusy else { return }
        // The tenant the screen's reads (the group, the people) belong to, before any await.
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let address = PythonText.strip(group.email)
        subject = Guard.normalized(group.email)
        guard Address.looksLikeEmail(address) else {
            state = .problem(Problem("Pick a group first."))
            return
        }
        let people = Self.addresses(in: addresses)
        guard !people.isEmpty else {
            state = .problem(Problem("Enter the email address of the person to add."))
            return
        }
        if let wrong = people.first(where: { !Address.looksLikeEmail($0) }) {
            state = .problem(Problem("“\(wrong)” isn't one email address. Pick someone from the suggestions, or type their full address."))
            return
        }
        let steps = people.map { person in
            WriteStep(GamCommands.addGroupMember(group: address, member: person, role: role), target: person,
                      summary: "Add \(person) to \(address) as \(role.rawValue).", about: ["group": address])
        }
        await hold(steps, group: address, title: people.count == 1 ? "Add \(people[0]) to \(address)" : "Add \(people.count) people to \(address)",
                   confirmLabel: people.count == 1 ? "Add" : "Add \(people.count) People", notes: [], adding: role, expecting: tenant)
    }

    /// GamGUI's `remove_preview`: one member with an address (everyone in the organization has none),
    /// always from its confirm step, saying their role and what leaving means (`_group_remove_confirm.html`).
    /// The role is the one the list read, not one a form sent.
    public func previewRemove(_ member: GroupMember, from group: GamGroup) async {
        guard !isBusy else { return }
        let tenant = setup.active.map { (domain: $0, generation: setup.generation) }
        let address = PythonText.strip(group.email), person = PythonText.strip(member.email)
        subject = Guard.normalized(group.email)
        guard Address.looksLikeEmail(address), Address.looksLikeEmail(person) else {
            state = .problem(Problem("Pick a member to remove."))
            return
        }
        let step = WriteStep(GamCommands.removeGroupMember(group: address, member: person), target: person,
                             summary: "Remove \(person) from \(address).", about: ["group": address])
        let role: String? = switch PythonText.lower(PythonText.strip(member.role)) {
        case "owner": "They are an owner — make sure the group keeps one."
        case "manager": "They are a manager."
        default: nil
        }
        let leaving = "They stop getting the group's mail and lose what is shared with it. You can add them back."
        await hold([step], group: address, title: "Remove \(person) from \(address)?", confirmLabel: "Remove",
                   notes: [role, leaving].compactMap { $0 }, adding: nil, expecting: tenant)
    }

    private func hold(_ steps: [WriteStep], group: String, title: String, confirmLabel: String, notes: [String],
                      adding: GamCommands.GroupRole?, expecting: (domain: Domain, generation: Int)?) async {
        guard let executor else {
            state = .problem(Problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh."))
            return
        }
        switch await executor.preview(steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove, expecting: expecting) {
        case .success(let preview):
            state = .previewing(Pending(preview: preview, group: group, title: title, confirmLabel: confirmLabel,
                                        members: steps.map(\.target), notes: notes, adding: adding))
        case .failure(let refusal):
            state = .problem(Problem(refusal.message))
        }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows: an older one (the list
    /// edited or the group changed since) never runs, though the executor still holds it. `confirmation` is
    /// what the operator gave; the executor decides whether it's enough. Then the group is read again, on
    /// the tenant the write ran on only.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(Problem(refusal))
            return
        }
        if setup.active == pending.preview.domain, setup.generation == pending.preview.generation {
            await members.load(pending.group)
        }
        let result = Self.result(of: pending, outcome.steps)
        let note = outcome.auditProblem.map { " \($0)" } ?? ""
        switch result {
        case .success(let message): state = .done(message + note)
        case .failure(let problem): state = .problem(Problem(problem.summary + note, detail: problem.detail))
        }
    }

    /// Back to the page; a held preview simply expires unused.
    public func dismiss() {
        guard !isBusy else { return }
        state = .idle
    }

    // MARK: words

    /// What a run did, in GamGUI's words for one person ("Added m to g as role.", "Couldn't add m to g.
    /// <why>"), and for several: how many were added, and why each of the first few weren't.
    nonisolated static func result(of pending: Pending, _ steps: [RunOutcome.Step]) -> Result<String, Problem> {
        let group = pending.group
        var added: [String] = [], failed: [(why: String, detail: String?)] = []
        for (member, step) in zip(pending.members, steps) {
            switch step {
            case .succeeded:
                added.append(member)
            case .failed(let message, let kind):
                failed.append((why(message, kind: kind, member: member, group: group, adding: pending.adding != nil),
                               kind == nil ? nil : message))
            case .skipped(let reason):
                failed.append((reason, nil))
            }
        }
        failed += Array(repeating: ("Nothing ran.", nil), count: max(0, pending.members.count - steps.count))
        guard let role = pending.adding else {
            let member = pending.members.first ?? ""
            guard let failure = failed.first else { return .success("Removed \(member) from \(group).") }
            return .failure(Problem("Couldn't remove \(member) from \(group). \(failure.why)", detail: failure.detail))
        }
        let count = pending.members.count
        if failed.isEmpty {
            return .success(count == 1 ? "Added \(added[0]) to \(group) as \(role.rawValue)."
                                       : "Added \(count) people to \(group) as \(role.rawValue).")
        }
        if count == 1 {
            return .failure(Problem("Couldn't add \(pending.members[0]) to \(group). \(failed[0].why)", detail: failed[0].detail))
        }
        let said = failed.prefix(failuresSaid)
        let more = failed.count - said.count
        let head = added.isEmpty ? "Added none of the \(count) people to \(group)."
                                 : "Added \(added.count) of \(count) people to \(group) as \(role.rawValue)."
        let summary = ([head] + said.map(\.why) + (more > 0 ? ["\(more) more weren't added either."] : [])).joined(separator: " ")
        let details = said.compactMap(\.detail)
        return .failure(Problem(summary, detail: details.isEmpty ? nil : details.joined(separator: "\n")))
    }

    /// Why one member's write failed. GAM's member line ("Member: m, Role: R, Add|Remove Failed: <why>",
    /// doUpdateGroups' `_showFailure`) is said for this member; anything else is GamGUI's remediation for
    /// GAM's kind.
    nonisolated static func why(_ message: String, kind: GamError.Kind?, member: String, group: String, adding: Bool) -> String {
        let text = PythonText.lower(message)
        if text.contains("member: "), text.contains(adding ? "add failed: " : "remove failed: ") {
            if adding, text.contains("member already exists") { return "\(member) is already in \(group)." }
            if adding, text.contains("invalid input: memberkey") { return "Google doesn't take \(member) as an address. Check it." }
            if kind == .notFound {
                return adding ? "Google has no user or group at \(member). Check the address." : "\(member) isn't in \(group) now."
            }
        }
        return kind?.remediation ?? message
    }

    /// The addresses in what the operator typed: one per line, or separated by commas or semicolons, each
    /// stripped as GamGUI strips its one, the empty ones and repeats (as `Guard` compares addresses)
    /// dropped. Nothing else is split: "Carol Clark" stays one entry, refused in GamGUI's words.
    public nonisolated static func addresses(in text: String) -> [String] {
        let separators = PythonText.lineBreaks.union([UInt32(UInt8(ascii: ",")), UInt32(UInt8(ascii: ";"))])
        var entries: [String] = [], current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if separators.contains(scalar.value) {
                entries.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        entries.append(String(current))
        var seen: Set<String> = [], addresses: [String] = []
        for entry in entries.map({ PythonText.strip($0) }) where !entry.isEmpty && seen.insert(Guard.normalized(entry)).inserted {
            addresses.append(entry)
        }
        return addresses
    }

    /// GamGUI's people type-ahead (`_pick` over the directory): those whose address or name holds the
    /// words (stripped, lowercased by `str.lower()`, compared scalar by scalar), at most `pickLimit` in the
    /// directory's order, and whether there were more. Nothing until something is typed.
    public nonisolated static func people(matching query: String, in users: [GamUser]) -> (shown: [GamUser], more: Bool) {
        let needle = Array(PythonText.lower(PythonText.strip(query)).unicodeScalars)
        guard !needle.isEmpty else { return ([], false) }
        let hits = users.filter { user in
            [user.primaryEmail, user.fullName].contains { UserFilter.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
        }
        return (Array(hits.prefix(pickLimit)), hits.count > pickLimit)
    }
}
