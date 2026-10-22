import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// One person's groups, mail delegates, auto-reply and signature, read live when their page opens (GamGUI's `/users/groups` and
/// `/users/delegates`, lazy-loaded the same way). Kept only for the tenant, generation and person they were
/// read for, so a switch never shows one tenant's memberships as another's; the last few people are kept,
/// so pages open in two windows each keep their own.
@MainActor
@Observable
public final class UserAccess {
    public struct Lists: Sendable, Equatable {
        /// Group addresses the person is a member of.
        public let groups: [String]
        /// Addresses delegated access to the person's mailbox (`print delegates`), read on its own: Gmail off
        /// for the person fails this read (GAM exits 73), never their groups.
        public let delegates: Result<[String], Problem>
        /// Their auto-reply (`show vacation`), read on its own: a person without Gmail still shows their
        /// groups and delegates (GamGUI loads each panel separately).
        public let vacation: Result<Vacation, Problem>
        /// Their Gmail signature (`show signature`) as GAM showed it, read by GamGUI's reader
        /// (`Signature.parseShown`), "" when none is set. On its own too: Gmail off fails only this.
        public let signature: Result<String, Problem>
    }

    private struct Loaded {
        let email: String
        let domain: Domain
        let generation: Int
        /// When the read started: a slower, older read of the same person never replaces it.
        let serial: Int
        let result: Result<Lists, Problem>
    }

    /// A person as read for one tenant.
    private struct Key: Hashable {
        let email: String
        let domain: Domain
        let generation: Int
    }

    public struct Problem: Error, Sendable, Equatable {
        public let summary: String
    }

    private let setup: SetupModel
    private let runner: AuthenticatedRunner?
    /// The people read, newest first, kept per person: two windows' pages never evict each other's lists.
    /// Bounded (invariant 9), and only the connected tenant's are kept.
    private var loaded: [Loaded] = []
    /// The people being read, for the tenant they're read for: an old tenant's read never shows as this one's.
    private var reading = ReadsInFlight<Key>()
    private let keep: Int
    /// Tests only: the mock's state folder, so a read sees what a write just changed.
    var environment: [String: String] = [:]

    public init(setup: SetupModel, runner: AuthenticatedRunner?, keep: Int = 8) {
        self.setup = setup
        self.runner = runner
        self.keep = keep
    }

    /// A read of `email` is waiting or running.
    public func isReading(_ email: String) -> Bool {
        guard let domain = setup.active else { return false }
        return reading.isRunning(Key(email: email, domain: domain, generation: setup.generation))
    }

    /// The lists for `email`, while they belong to the connected tenant.
    public func lists(for email: String) -> Lists? {
        guard let loaded = current(email), case .success(let lists) = loaded.result else { return nil }
        return lists
    }

    public func problem(for email: String) -> String? {
        guard let loaded = current(email), case .failure(let problem) = loaded.result else { return nil }
        return problem.summary
    }

    private func current(_ email: String) -> Loaded? {
        loaded.first { $0.email == email && $0.domain == setup.active && $0.generation == setup.generation }
    }

    /// Four reads as the connected domain: `print groups member`, `print delegates`, `show vacation`,
    /// `show signature`.
    /// `delay` holds them back, reading from the start: a page that opens and is left within it reads
    /// nothing (arrowing down the list).
    public func load(_ email: String, after delay: Duration = .zero) async {
        guard let domain = setup.active, let runner else { return }
        let generation = setup.generation
        let key = Key(email: email, domain: domain, generation: generation)
        let serial = reading.start(key)
        defer { reading.end(key, serial) }
        if delay > .zero {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
        }
        // The four reads at once: each is its own gam call.
        let environment = environment
        async let groupsRead = Self.result { try await Self.read(GamCommands.printGroups(member: email), with: runner, as: domain, environment) }
        async let delegatesRead = Self.result { try await Self.read(GamCommands.printDelegates(email: email), with: runner, as: domain, environment) }
        async let vacationRead = Self.result { try await Self.read(GamCommands.showVacation(email: email), with: runner, as: domain, environment) }
        async let signatureRead = Self.result { try await Self.read(GamCommands.showSignature(email: email), with: runner, as: domain, environment) }
        let (groups, delegates, vacation, signature) = await (groupsRead, delegatesRead, vacationRead, signatureRead)
        guard !Task.isCancelled else { return }
        let result: Result<Lists, Problem> = groups.map { groups in
            Lists(groups: Self.groups(from: groups), delegates: delegates.map(Self.delegates(from:)),
                  vacation: vacation.map(Vacation.init(showText:)), signature: signature.map(Signature.parseShown))
        }
        // A switch while reading: these belong to the old tenant, so they're dropped.
        guard !Task.isCancelled, setup.active == domain, setup.generation == generation,
              current(email).map({ $0.serial < serial }) ?? true
        else { return }
        loaded.removeAll { $0.email == email || $0.domain != domain || $0.generation != generation }
        loaded.insert(Loaded(email: email, domain: domain, generation: generation, serial: serial, result: result), at: 0)
        if loaded.count > keep { loaded.removeLast(loaded.count - keep) }
    }

    /// The person's mail delegates, read now as the connected domain and not kept: offboarding's preview
    /// decides on them (GamGUI's `list_delegates`, read live by `_delegate_warning`). A failure is GAM's own
    /// words (`GamError.message`), which that warning quotes.
    public func delegates(of email: String) async -> Result<[String], Problem> {
        await readNow(GamCommands.printDelegates(email: email), parse: Self.delegates(from:))
    }

    /// The secondary calendars the person owns, hidden ones included, read now and not kept: offboarding's preview
    /// warns that the transfer doesn't move them and the delete loses them. A failure is GAM's own words.
    public func ownedSecondaryCalendars(of email: String) async -> Result<[UserCalendar], Problem> {
        await readNow(GamCommands.printOwnedSecondaryCalendars(email: email)) { GamOutput.records($0).map(UserCalendar.init(record:)) }
    }

    /// The person's Gmail filters, read now and not kept: offboarding's "Remove filters that forward" deletes those
    /// that forward, and its run reads them again on the plan's `domain` first. A failure is GAM's own words (Gmail off
    /// for the person, say).
    public func mailFilters(of email: String, in domain: Domain? = nil) async -> Result<[Offboarding.MailFilter], Problem> {
        await readNow(GamCommands.printFilters(email: email), in: domain) { GamOutput.records($0).map(Offboarding.MailFilter.init(record:)) }
    }

    /// The Vault holds that cover the person, read now and not kept: offboarding's preview warns that a hold stops
    /// the transfer and the delete. A failure is GAM's own words (an admin without Vault access, say).
    public func vaultHolds(of email: String) async -> Result<[Offboarding.VaultHold], Problem> {
        await readNow(GamCommands.printVaultHolds(email: email)) { GamOutput.records($0).map(Offboarding.VaultHold.init(record:)) }
    }

    // MARK: Check Account (the compromised-account response): each read now, not kept, GAM's own words when it fails

    /// The account with its 2-Step Verification and recovery details (`Compromised.accountFields`): an alias reads as the
    /// account that owns it, as `account(_:in:)` does.
    public func compromisedAccount(_ email: String) async -> Result<GamUser, Problem> {
        await readNow(GamCommands.infoUser(email: email, fields: Compromised.accountFields)) { GamUser(record: GamOutput.one($0)) }
    }

    /// Every Gmail filter, with what it matches and does: offboarding's read, read for all of them.
    public func filters(of email: String) async -> Result<[Compromised.Filter], Problem> {
        await readNow(GamCommands.printFilters(email: email)) { GamOutput.records($0).map(Compromised.Filter.init(record:)) }
    }

    /// Auto-forwarding as Gmail has it; nil when GAM printed no row for the person.
    public func forwarding(of email: String) async -> Result<Compromised.Forwarding?, Problem> {
        await readNow(GamCommands.printForward(email: email)) { Compromised.Forwarding(records: GamOutput.records($0)) }
    }

    public func forwardingAddresses(of email: String) async -> Result<[Compromised.ForwardingAddress], Problem> {
        await readNow(GamCommands.printForwardingAddresses(email: email)) {
            GamOutput.records($0).map(Compromised.ForwardingAddress.init(record:))
        }
    }

    /// The apps given access to `email`'s account, or to every account's (nil): one Directory API call per account, so every
    /// account's gets the long timeout.
    public func connectedApps(of email: String? = nil, in pinned: Domain? = nil) async -> Result<[ConnectedApps.App], Problem> {
        guard let read = try? GamCommands.printTokens(user: email) else {
            return .failure(Problem(summary: "Couldn't read the connected apps: “\(email ?? "")” isn't one email address."))
        }
        return await readNow(read, in: pinned, timeout: email == nil ? ActivityLogs.timeout : GamRunner.defaultTimeout) {
            ConnectedApps.apps(ConnectedApps.grants($0))
        }
    }

    /// The phones and tablets syncing the account (`GamCommands.printMobileDevices`).
    public func mobileDevices(of email: String) async -> Result<[Compromised.MobileDevice], Problem> {
        guard let read = try? GamCommands.printMobileDevices(user: email) else {
            return .failure(Problem(summary: "Couldn't read the devices: “\(email)” isn't one email address."))
        }
        let owner = PythonText.lower(email)
        return await readNow(read) { stdout in
            GamOutput.records(stdout).map(Compromised.MobileDevice.init(record:))
                .filter { $0.owners.contains { PythonText.lower($0) == owner } }
        }
    }

    /// The computers signed in with the account (`GamCommands.printDevices`), only those that list the person exactly; a
    /// refusal for want of the devices scope says how to grant it, by its cause (`Compromised.Computer.note(for:)`).
    public func computers(of email: String) async -> Result<[Compromised.Computer], Problem> {
        guard let domain = setup.active, let runner else { return .failure(Problem(summary: "Connect a domain on Setup first.")) }
        guard let read = try? GamCommands.printDevices(user: email) else {
            return .failure(Problem(summary: "Couldn't read the computers: “\(email)” isn't one email address."))
        }
        do {
            let result = try await runner.run(read, as: domain, extraEnvironment: environment)
            guard result.exitCode == 0 else { throw GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv) }
            return Self.outcome(result, argv: read.argv) { stdout in
                GamOutput.records(stdout).compactMap { Compromised.Computer(record: $0, owner: email) }
            }
        } catch let error as GamError {
            return .failure(Problem(summary: error.message + (Compromised.Computer.note(for: error).map { " " + $0 } ?? "")))
        } catch GamRunnerError.timedOut {
            return .failure(Problem(summary: GamError(exitCode: nil, stderr: "", argv: read.argv).message))
        } catch {
            return .failure(Problem(summary: SetupModel.message(for: error)))
        }
    }

    /// The auto-reply as it is now (`show vacation`), read on its own: Check Account's, never a page's cached lists.
    public func autoReply(of email: String) async -> Result<Vacation, Problem> {
        await readNow(GamCommands.showVacation(email: email)) { Vacation(showText: $0) }
    }

    public func sendAs(of email: String) async -> Result<[Compromised.SendAs], Problem> {
        await readNow(GamCommands.printSendAs(email: email)) { GamOutput.records($0).map(Compromised.SendAs.init(record:)) }
    }

    /// The person's drafts, the newest `Compromised.Draft.cap`: an attacker's session can leave thousands. None is no drafts.
    public func drafts(of email: String) async -> Result<[Compromised.Draft], Problem> {
        await listed(GamCommands.listMessages(email: email, query: "in:drafts", max: Compromised.Draft.cap))
    }

    private func listed(_ read: GamRead) async -> Result<[Compromised.Draft], Problem> {
        guard let domain = setup.active, let runner else { return .failure(Problem(summary: "Connect a domain on Setup first.")) }
        do {
            return .success(try Compromised.Draft.list(try await runner.run(read, as: domain, timeout: Compromised.Draft.timeout,
                                                                          extraEnvironment: environment), argv: read.argv))
        } catch let error as GamError {
            return .failure(Problem(summary: error.message))
        } catch let incomplete as MessageCopies.Incomplete {
            return .failure(Problem(summary: incomplete.reason))
        } catch GamRunnerError.timedOut {
            return .failure(Problem(summary: GamError(exitCode: nil, stderr: "", argv: read.argv).message))
        } catch {
            return .failure(Problem(summary: SetupModel.message(for: error)))
        }
    }

    /// The admin roles assigned to the person directly (not through a group).
    public func adminRoles(of email: String) async -> Result<[Compromised.AdminRole], Problem> {
        await readNow(GamCommands.printAdmins(user: email)) { GamOutput.records($0).map(Compromised.AdminRole.init(record:)) }
    }

    /// GamGUI's "Search a mailbox": `email`'s messages matching the Gmail search `query`, the newest
    /// `GamCommands.messageCap`, Spam and Trash included, each with its recipients (`MailboxSearch`). None found is no
    /// messages, not a failure; a read cut off at the runner's cap is.
    /// The Chrome profiles signed in with `email`'s account (`ChromeProfiles`), on `pinned` or the connected domain.
    public func chromeProfiles(of email: String, in pinned: Domain? = nil) async -> Result<[ChromeProfiles.Profile], Problem> {
        guard let domain = pinned ?? setup.active, let runner else { return .failure(Problem(summary: "Connect a domain on Setup first.")) }
        let read: GamRead
        do {
            read = try GamCommands.printChromeProfiles(user: email)
        } catch {
            return .failure(Problem(summary: "Couldn't read Chrome profiles: “\(email)” isn't one email address."))
        }
        do {
            return .success(try ChromeProfiles.profiles(try await runner.run(read, as: domain, extraEnvironment: environment), argv: read.argv))
        } catch let error as GamError {
            return .failure(Problem(summary: error.message + (ChromeProfiles.needsScope(error) ? " " + ChromeProfiles.scopeNote : "")))
        } catch let incomplete as MessageCopies.Incomplete {
            return .failure(Problem(summary: incomplete.reason))
        } catch GamRunnerError.timedOut {
            return .failure(Problem(summary: GamError(exitCode: nil, stderr: "", argv: read.argv).message))
        } catch {
            return .failure(Problem(summary: SetupModel.message(for: error)))
        }
    }

    public func searchMailbox(of email: String, query: String, in pinned: Domain? = nil) async -> Result<[MailboxSearch.Message], Problem> {
        guard let domain = pinned ?? setup.active, let runner else { return .failure(Problem(summary: "Connect a domain on Setup first.")) }
        let read = GamCommands.searchMessages(email: email, query: query, detail: .headers)
        do {
            return .success(try MailboxSearch.messages(try await runner.run(read, as: domain, extraEnvironment: environment), argv: read.argv))
        } catch let error as GamError {
            return .failure(Problem(summary: error.message))
        } catch let incomplete as MessageCopies.Incomplete {
            return .failure(Problem(summary: incomplete.reason))
        } catch GamRunnerError.timedOut {
            return .failure(Problem(summary: GamError(exitCode: nil, stderr: "", argv: read.argv).message))
        } catch {
            return .failure(Problem(summary: SetupModel.message(for: error)))
        }
    }

    /// One activity log (`ActivityLogs`) for `users` (none: every account) over the last `hours`, only from `ip` when it's
    /// given, the newest `cap` per account; GAM's own words when the read fails, as when an edition doesn't keep the log.
    public func activity(_ application: ActivityLogs.Application, users: [String], hours: Int, ip: String = "",
                         events: [String] = [], cap: Int, chrome: GamCommands.ChromeMatch = .profile,
                         in domain: Domain? = nil) async -> Result<[ActivityLogs.Row], Problem> {
        do {
            let read = try GamCommands.reportActivity(application, users: users, hours: hours, ip: ip, events: events, maxActivities: cap,
                                                      chrome: chrome)
            // GAM reads one account after another: twenty accounts' Gmail takes far longer than one read.
            return await readNow(read, in: domain, timeout: ActivityLogs.timeout) { ActivityLogs.rows($0, application: application) }
        } catch GamCommands.Invalid.argument(let why) {
            return .failure(Problem(summary: "Couldn't read the \(application.name) log: \(why)."))
        } catch {
            return .failure(Problem(summary: "\(error)"))
        }
    }

    /// `read` run now as `pinned`, or the connected domain, parsed; GAM's own words (`GamError.message`) when it fails.
    private func readNow<T>(_ read: GamRead, in pinned: Domain? = nil, timeout: Duration = GamRunner.defaultTimeout,
                            parse: (String) -> T) async -> Result<T, Problem> {
        guard let domain = pinned ?? setup.active, let runner else { return .failure(Problem(summary: "Connect a domain on Setup first.")) }
        do {
            return Self.outcome(try await runner.run(read, as: domain, timeout: timeout, extraEnvironment: environment),
                                argv: read.argv, parse: parse)
        } catch GamRunnerError.timedOut {
            return .failure(Problem(summary: GamError(exitCode: nil, stderr: "", argv: read.argv).message))
        } catch {
            return .failure(Problem(summary: SetupModel.message(for: error)))
        }
    }

    /// A finished read as a value: GAM's own words when it failed, and never a read cut off at the runner's cap taken as
    /// whole (its oldest rows, and a half-written last one, would pass as all there is; review 2026-10-19).
    static func outcome<T>(_ result: GamResult, argv: [String], parse: (String) -> T) -> Result<T, Problem> {
        guard result.exitCode == 0 else {
            return .failure(Problem(summary: GamError(exitCode: result.exitCode, stderr: result.stderr, argv: argv).message))
        }
        guard !result.stdoutTruncated else {
            return .failure(Problem(summary: "GAM printed more than \(GamRunner.outputCap / 1_048_576) MiB, so this wasn't all read. "
                + "Read fewer accounts or a shorter window."))
        }
        return .success(parse(result.stdout))
    }

    /// A read's outcome as a value, with any error worded for the screen.
    private static func result(_ body: () async throws -> String) async -> Result<String, Problem> {
        do {
            return .success(try await body())
        } catch let problem as Problem {
            return .failure(problem)
        } catch {
            return .failure(Problem(summary: "A read failed (\(type(of: error)))."))
        }
    }

    /// One account as the directory has it now (`info user`), read fresh on `domain`, never another tenant's: an
    /// alias reads as the account that owns it. Offboarding's run checks with it that the two accounts are still
    /// what its preview showed.
    public func account(_ email: String, in domain: Domain, fields: [String] = []) async throws -> GamUser {
        guard let runner else { throw Problem(summary: "This build has no GAM.") }
        return GamUser(record: GamOutput.one(try await Self.read(GamCommands.infoUser(email: email, fields: fields), with: runner,
                                                                 as: domain, environment)))
    }

    private static func read(_ read: GamRead, with runner: AuthenticatedRunner, as domain: Domain,
                             _ environment: [String: String]) async throws -> String {
        let result = try await runner.run(read, as: domain, extraEnvironment: environment)
        guard result.exitCode == 0 else {
            let error = GamError(exitCode: result.exitCode, stderr: result.stderr, argv: read.argv)
            throw Problem(summary: "\(error.message) \(error.remediation)")
        }
        return result.stdout
    }

    /// GamGUI's `list_user_groups`: the `email` column, where it holds an address.
    static func groups(from stdout: String) -> [String] {
        GamOutput.records(stdout).compactMap { $0["email"]?.string }.filter { $0.contains("@") }
    }

    /// GamGUI's `list_delegates`: `delegateAddress`, `delegate` or `Delegate Address`, whichever GAM printed.
    static func delegates(from stdout: String) -> [String] {
        GamOutput.records(stdout).compactMap { record in
            ["delegateAddress", "delegate", "Delegate Address"].lazy.compactMap { record[$0]?.string }.first { !$0.isEmpty }
        }
    }
}
