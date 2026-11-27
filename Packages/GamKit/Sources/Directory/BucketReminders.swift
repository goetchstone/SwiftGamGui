import ChangeCore
import Foundation
import GamEngine
import Observation
import Setup
import Vault

/// No 2SV and No recovery → Email them a reminder… (GamGUI's `/reports/remind/*`, roadmap 3.3, D3): the fix is the person's to
/// make, so the action is an email asking them to. One `sendemail` a person from the connected admin, through ChangeCore.
///
/// - **Read again at preview**: the card counted a cached list, so the preview loads the directory again and holds the people
///   that read found in the bucket, in address order, with the exact subject and message: Confirm sends that, never text
///   edited since.
/// - **The operator's text is never markup** (`html`, GamGUI's `reminder_html`): escaped, its line breaks kept.
/// - **The guard's rules for many**: a confirm always; more than 25, the count typed. In the jobs tray, one person at a time,
///   with Stop; a failure every later send would share stops it.
@MainActor
@Observable
public final class BucketReminders {
    public enum State: Sendable {
        case idle
        case checking
        case previewing(Pending)
        case running(Pending)
        case done(String)
        case problem(String)
    }

    public struct Pending: Sendable, Identifiable {
        public let preview: HeldPreview
        public let key: String
        public let subject: String
        public let people: [GamUser]
        public var id: UUID { preview.id }
        public var count: Int { people.count }
        public var needsCount: Bool { preview.decision.requiresTypedCount }
    }

    /// GamGUI's `SECURITY_PAGE` and `REMINDERS`: each bucket's starting subject and message.
    public nonisolated static let securityPage = "https://myaccount.google.com/security"
    public nonisolated static let reminders: [String: (subject: String, message: String)] = [
        "no_2sv": ("Please turn on 2-Step Verification",
                   "Hello,\n\nYour Google account doesn't have 2-Step Verification turned on yet. It keeps your account safe "
                   + "even if someone learns your password. Please turn it on from the Security page of your Google account: "
                   + "\(securityPage)\n\nThank you."),
        "no_recovery": ("Please add a recovery email or phone",
                        "Hello,\n\nYour Google account has no recovery email or phone. Without one, getting back into your "
                        + "account after a lost password takes much longer. Please add one from the Security page of your "
                        + "Google account: \(securityPage)\n\nThank you."),
    ]
    /// People a preview lists by name (GamGUI's `_REMIND_SHOWN`).
    public nonisolated static let shown = 200
    nonisolated static let failuresSaid = 5

    /// GamGUI's `reminder_html`: the text stripped, each line HTML-escaped as Python's `html.escape` does, joined by `<br>`.
    public nonisolated static func html(_ text: String) -> String {
        PythonText.splitlines(PythonText.strip(text)).map { line in
            var out = ""
            for scalar in line.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&#x27;"
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        }.joined(separator: "<br>")
    }

    public private(set) var state: State = .idle
    /// Which bucket the state is about.
    public private(set) var key: String?
    public private(set) var typedProblem: String?
    private var serial = 0
    private let executor: Executor?
    private let setup: SetupModel
    private let directory: DirectoryStore

    public init(executor: Executor?, setup: SetupModel, directory: DirectoryStore) {
        self.executor = executor
        self.setup = setup
        self.directory = directory
        setup.onTenantChange { [weak self] in self?.dismiss() }
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .running: true
        default: false
        }
    }

    /// Reads the directory again and holds, for bucket `key`, one email a person with this exact text.
    public func preview(key: String, subject: String, message: String) async {
        guard !isBusy else { return }
        serial += 1
        let serial = serial
        self.key = key
        typedProblem = nil
        guard Self.reminders[key] != nil else {
            state = .problem("Not a list that gets a reminder.")
            return
        }
        let subject = PythonText.strip(subject)
        guard !subject.isEmpty, !PythonText.strip(message).isEmpty else {
            state = .problem("Write a subject and a message first.")
            return
        }
        guard let executor else {
            state = .problem("This build has no GAM. Build the app again after running scripts/fetch_gam.sh.")
            return
        }
        guard let domain = setup.active else {
            state = .problem("Connect a domain on Setup first.")
            return
        }
        let generation = setup.generation
        let before = directory.revision
        state = .checking
        await directory.load()
        guard serial == self.serial else { return }
        guard setup.active == domain, setup.generation == generation else {
            state = .problem("The connected domain changed while the directory was read, so nothing is offered. Preview again.")
            return
        }
        guard directory.problem == nil, let users = directory.users, directory.revision != before else {
            state = .problem("Couldn't read the directory again, so nothing is offered. " + (directory.problem?.summary ?? "Try again."))
            return
        }
        let people = (DirectoryReport.build(users).first { $0.key == key }?.users ?? [])
            .sorted { PythonText.lower($0.primaryEmail).unicodeScalars.lexicographicallyPrecedes(PythonText.lower($1.primaryEmail).unicodeScalars) }
        guard !people.isEmpty else {
            state = .done("Read again just now: nobody is on this list any more. Nothing to send.")
            return
        }
        let body = Self.html(message)
        let steps = people.map {
            WriteStep(GamCommands.sendEmail(to: $0.primaryEmail, subject: subject, body: body), target: $0.primaryEmail,
                      summary: "Email \($0.primaryEmail) the reminder “\(subject)”", about: ["bucket": key])
        }
        let n = people.count
        let held = await executor.preview(steps, confirmStep: true, typedCountAbove: Guard.countConfirmAbove,
                                          expecting: (domain, generation),
                                          title: "Reminder “\(subject)” to \(n) \(n == 1 ? "person" : "people")")
        guard serial == self.serial else {
            if case .success(let preview) = held { await executor.discard(preview.id) }
            return
        }
        switch held {
        case .success(let preview): state = .previewing(Pending(preview: preview, key: key, subject: subject, people: people))
        case .failure(let refusal): state = .problem(refusal.message)
        }
    }

    /// Sends `pending` once, exactly as held. A count typed that isn't the guard's is said first, and nothing is sent.
    public func confirm(_ pending: Pending, _ confirmation: OperatorConfirmation) async {
        guard !isBusy, let executor, case .previewing(let shown) = state, shown.id == pending.id else { return }
        if !pending.preview.decision.typedCountMatches(confirmation.typedCount) {
            typedProblem = "Type \(pending.count), the number of people, to confirm."
            return
        }
        typedProblem = nil
        state = .running(pending)
        let outcome = await executor.run(pending.preview, confirmation: confirmation)
        if let refusal = outcome.refusal {
            state = .problem(refusal)
            return
        }
        guard setup.isConnected(to: pending.preview) else {
            state = .idle
            return
        }
        var sent = 0, failed: [String] = [], notRun = 0, stoppedBy: String?
        for (person, step) in zip(pending.people, outcome.steps + Array(repeating: nil, count: max(0, pending.count - outcome.steps.count))) {
            switch step {
            case .succeeded?: sent += 1
            case .failed(let message, let kind)?: failed.append("\(person.primaryEmail): \(kind?.remediation ?? message)")
            case .skipped(let why)?, .waiting(let why)?:
                notRun += 1
                if stoppedBy == nil { stoppedBy = why }
            case nil: notRun += 1
            }
        }
        var words = "Sent \(sent) of \(pending.count) reminder\(pending.count == 1 ? "" : "s")."
        if notRun > 0 {
            let why = stoppedBy == nil || stoppedBy == Executor.stopped ? "Stopped by you" : stoppedBy!
            words = "\(why) \u{2014} \(notRun) not attempted. " + words
        }
        if !failed.isEmpty {
            words += " Not sent: " + failed.prefix(Self.failuresSaid).joined(separator: "; ")
                + (failed.count > Self.failuresSaid ? "; and \(failed.count - Self.failuresSaid) more" : "") + "."
        }
        words += outcome.auditProblem.map { " \($0)" } ?? ""
        state = failed.isEmpty && notRun == 0 ? .done(words) : .problem(words)
    }

    /// Stop after the email in flight.
    public func stop() async {
        guard case .running(let pending) = state, let executor else { return }
        _ = await executor.stopAfterCurrentStep(pending.id)
    }

    public func typingChanged() { typedProblem = nil }

    public func dismiss() {
        guard !isBusy else { return }
        serial += 1
        typedProblem = nil
        state = .idle
    }
}
