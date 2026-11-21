import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// Export to a Google Sheet… (plan F4, GamGUI #174's `/builder/sheet/preview` and `/builder/sheet/export`): a read's table put
/// in a new Sheet in the connected admin's own Drive, shared with nobody. A curated write through ChangeCore like every other:
///
/// - **The preview holds the exact argv**: the read's own (the `GamRead` the table came from), then GAM's `todrive` options
///   (`GamCommands.exportToSheet`), held by the executor. Confirming runs that, once, never one rebuilt since.
/// - **It holds a fresh read**: GAM runs the read again and uploads what it gets then, so its rows can differ from the table on
///   screen, and it has every row, not only those a filter shows. The preview says so, with the table's count.
/// - **The scope check** (a read: `check serviceaccount scopes <drive>,<spreadsheets>`, `UserAccess.sheetExportScopes`): a scope
///   known to be refused holds nothing and offers no Export, with Setup's delegation link (every scope this app asks for); one
///   that couldn't be checked is said as unknown, and Export is still offered.
/// - **The outcome is read from the upload's own lines** (`RunOutcome.noted`: the link, or which failure line GAM printed about
///   the admin), never GAM's one-line error summary: made, not made, or unknown (`SheetExport.outcome`).
/// - **Audited** as `export_to_sheet` by the executor (begin and end, the end keeping `url` or `upload`), target the admin,
///   `extra.command` the catalog id. Sensitive reads stay browse-only here, so there is no `sensitive_export`.
/// - **A switch drops a held preview** (`setup.onTenantChange`); the executor refuses one held for another tenant anyway, and
///   a running export finishes on the domain it was previewed on, its records naming that domain.
@MainActor
@Observable
public final class SheetExports {
    public enum State: Sendable {
        case idle
        /// The scope check is running.
        case checking
        /// What the sheet shows; confirming runs exactly its held preview.
        case previewing(Pending)
        case running(Pending)
        case done(Done)
        case problem(String)
    }

    /// A preview with what its sheet says about it.
    public struct Pending: Sendable, Identifiable {
        /// Held by the executor; nil when a scope the export needs is known to be refused: nothing is held, and no Export.
        public let preview: HeldPreview?
        public let id: UUID
        /// The catalog id and name of the read.
        public let command: String
        public let commandName: String
        /// The new file's name.
        public let name: String
        /// The admin whose Drive it goes in; "" when the token names none (GAM picks the admin itself).
        public let owner: String
        public let domain: Domain
        /// The rows the table on screen holds (the export holds a fresh read, every row).
        public let rows: Int
        /// The exact `gam …` line, quoted as it's typed.
        public let commandLine: String
        /// Each scope the export needs, what it does for it, and whether it's allowed (nil: not checked).
        public let scopes: [Scope]
        /// The scope check in words: "" when both are allowed.
        public let scopeWords: String
        /// Setup's Domain-Wide Delegation link, every scope this app asks for; only when a scope is known to be refused.
        public let delegationLink: URL?

        public var canExport: Bool { preview != nil }
    }

    public struct Scope: Sendable, Identifiable, Equatable {
        public let scope: String
        public let purpose: String
        /// True allowed, false not allowed, nil not checked.
        public let allowed: Bool?
        public var id: String { scope }
    }

    /// What an export did.
    public struct Done: Sendable {
        public let outcome: SheetExport.Outcome
        public let name: String
        public let commandLine: String
        /// GAM's error, when the write failed; "" otherwise.
        public let detail: String
        /// The write happened but the audit log couldn't record it: Files won't list it. "" otherwise.
        public let unrecorded: String

        public init(outcome: SheetExport.Outcome, name: String, commandLine: String, detail: String, unrecorded: String) {
            self.outcome = outcome
            self.name = name
            self.commandLine = commandLine
            self.detail = detail
            self.unrecorded = unrecorded
        }
    }

    public private(set) var state: State = .idle
    private let executor: Executor?
    private let setup: SetupModel
    private let access: UserAccess
    /// Counts previews asked for: one that comes back after a newer one was asked for is dropped.
    private var asked = 0

    public init(executor: Executor?, setup: SetupModel, access: UserAccess) {
        self.executor = executor
        self.setup = setup
        self.access = access
        setup.onTenantChange { [weak self] in self?.tenantChanged() }
    }

    /// A switch drops what was shown for the old tenant, its held preview with it. An export running goes on, on its own tenant.
    private func tenantChanged() {
        guard !isBusy else { return }
        dismiss()
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    /// Whether the export's sheet is up: checking, a preview, running, or what came of it.
    public var isShown: Bool {
        if case .idle = state { return false }
        return true
    }

    /// Whether a catalog command's table can go to a Sheet: a read GAM's `todrive` takes (`SheetExport.takesToDrive`).
    public nonisolated static func offered(syntax: String, curated: Bool) -> Bool {
        SheetExport.takesToDrive(syntax: syntax, curated: curated)
    }

    // MARK: previewing

    /// Holds the export of `read` (the read its table came from, the catalog command `command` named `commandName`, `rows` on
    /// screen) for the domain connected now, after the scope check. Refused, with why, when there's no GAM, no domain, a read
    /// that isn't one GAM's `todrive` takes or that already carries it, or a switch during the check.
    public func preview(read: GamRead, command: String, commandName: String, rows: Int) async {
        guard !isBusy else { return }
        asked += 1
        let request = asked
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        // The tenant the export is bound to, before any await.
        guard let domain = setup.active else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        let generation = setup.generation
        let owner = PythonText.strip(setup.connectedAdmin ?? "")
        let name = SheetExport.title(domain: domain.name, read: commandName)
        let write: GamWrite
        do {
            write = try GamCommands.exportToSheet(read, title: name)
        } catch {
            guard case .argument(let why) = error else { return }
            state = .problem(why + ".")
            return
        }
        state = .checking
        let checked = await access.sheetExportScopes(admin: owner, in: domain)
        let missing = checked.map { $0.values.contains(false) } ?? false
        let link = missing ? await setup.delegationLink(for: domain) : nil
        guard request == asked else { return }
        guard setup.active == domain, setup.generation == generation else {
            state = .problem("The connected domain changed while the export was checked, so nothing is held. Export again.")
            return
        }
        let step = WriteStep(write, target: owner.isEmpty ? "(admin Drive)" : owner, summary: "Export \(commandName) to a Google Sheet",
                             risk: .low, about: ["command": command], timeout: ActivityLogs.timeout)
        let scopes = SheetExport.scopes.map { Scope(scope: $0.scope, purpose: $0.purpose, allowed: checked?[$0.scope]) }
        func pending(_ preview: HeldPreview?) -> Pending {
            Pending(preview: preview, id: preview?.id ?? UUID(), command: command, commandName: commandName, name: name, owner: owner,
                    domain: domain, rows: rows, commandLine: step.commandLine, scopes: scopes,
                    scopeWords: SheetExport.scopeState(checked), delegationLink: link)
        }
        guard !missing else {
            state = .previewing(pending(nil))
            return
        }
        // A domain-wide read plus its upload: a cut-off would leave a file nobody can name, so it gets a read's long timeout.
        let held = await executor.preview([step], confirmStep: true, expecting: (domain, generation),
                                          title: "Export \(commandName) to a Google Sheet")
        guard request == asked else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview): state = .previewing(pending(preview))
        case .failure(let refusal): state = .problem(refusal.message)
        }
    }

    // MARK: confirming

    /// Runs `pending` once, exactly as held, while it's the preview the sheet shows: the only way an export runs. The executor
    /// decides whether `confirmation` is enough (a click: its preview asked for one). The outcome is read from what the run's own
    /// output said (`RunOutcome.noted`), never GAM's summary line.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let held) = state, held.id == pending.id, let preview = pending.preview
        else { return }
        state = .running(pending)
        let outcome = await executor.run(preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal + " Nothing ran.")
            return
        }
        let owner = preview.steps.first?.target ?? ""
        let noted = outcome.noted[0] ?? [:]
        let ok = outcome.steps.first?.isSucceeded ?? false
        let detail: String = switch outcome.steps.first {
        case .failed(let message, _)?: message
        case .skipped(let reason)?, .waiting(let reason)?: reason
        case .succeeded?, nil: ""
        }
        let shown: SheetExport.Outcome = if outcome.began.contains(0) {
            SheetExport.outcome(ok: ok, url: noted["url"] ?? "", upload: noted["upload"] ?? "",
                                owner: owner == "(admin Drive)" ? "" : owner, error: ok ? "" : detail)
        } else {
            // GAM never started (no begin record, or the run stopped first): nothing was made.
            SheetExport.Outcome(url: "", made: .no, said: "Nothing was made: GAM didn't run. \(detail)",
                                todo: "Export again once that's put right.")
        }
        state = .done(Done(outcome: shown, name: pending.name, commandLine: pending.commandLine, detail: ok ? "" : detail,
                           unrecorded: outcome.auditProblem ?? ""))
    }

    /// Back to the table; a held preview is dropped from the executor, so it can't be run later.
    public func dismiss() {
        guard !isBusy else { return }
        if case .previewing(let pending) = state, let preview = pending.preview, let executor {
            Task { await executor.discard(preview.id) }
        }
        state = .idle
    }

    #if DEBUG
    /// Debug builds' screenshots only: `done` shown as the last export's result, any held preview dropped. No `gam` runs.
    public func showDemo(_ done: Done) {
        guard !isBusy else { return }
        dismiss()
        state = .done(done)
    }
    #endif
}
