#if DEBUG
import ChangeCore
import Directory
import Foundation
import GamEngine
import Vault

/// Debug builds only: the Audit screen's demo log, for its screenshots. Written fresh in the temporary folder
/// `AppServices.demo()` hands it, never anywhere else: example changes as this app records them (a begin, then
/// an end), one that failed, one the app stopped in the middle of, Builder reads (plan F1), and two older records GamGUI wrote
/// that name no domain. Two domains, example.com and example.org, and enough for two pages.
enum DemoAudit {
    /// Empties the demo log, every generation, when it's in the temporary folder: false (and nothing touched) otherwise.
    @discardableResult
    static func reset(_ url: URL) -> Bool {
        guard url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) else { return false }
        for suffix in [""] + (1...AuditLog.retainedGenerations).map({ ".\($0)" }) {
            try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
        }
        return true
    }

    /// Respond's picture: Phishing's finished run on the demo's phish (the mock's Gmail log shows carol sending it from the
    /// attacker's address), trashed from alice's and dana's mailboxes with every mailbox searched, as `PhishingChanges`
    /// records it, so Still to do lists it done.
    static func writePulled(to url: URL) {
        guard reset(url), let message = try? GamCommands.MessageID(validating: "<phish-1@mail.example.com>") else { return }
        let log = AuditLog(url: url), preview = UUID().uuidString
        let about = PhishingAudit.about(message, on: "example.com", steps: 2, searchedEverywhere: true)
        for (index, mailbox) in ["alice@example.com", "dana@example.com"].enumerated() {
            guard let write = try? GamCommands.trashMessage(email: mailbox, message, copies: 1) else { return }
            var extra: JSONObject = ["preview": .string(preview), "origin": .string("form"), "step": .number(String(index))]
            for (key, value) in about { extra[key] = .string(value) }
            // 2026-10-19 15:30 UTC, an hour after it was sent, two seconds a step.
            let at = Date(timeIntervalSince1970: 1_792_423_800 + Double(index) * 2)
            var begin = extra, end = extra
            begin["phase"] = .string("begin")
            end["phase"] = .string("end")
            _ = try? log.record(write.action.rawValue, target: mailbox, argv: write.argv, actor: "admin@example.com", extra: begin,
                                domain: "example.com", now: at)
            _ = try? log.record(write.action.rawValue, target: mailbox, argv: write.argv, exitCode: 0, ok: true, actor: "admin@example.com",
                                extra: end, domain: "example.com", now: at + 1)
        }
    }

    /// Files' picture: two exports of a Builder table to a Google Sheet, as the executor records them (a begin, then an end
    /// keeping what GAM's own lines said): one made, its link the mock's, and one GAM refused before making anything (the service
    /// account not allowed Drive). Nothing is run: the argv is the builder's, written to the demo log only.
    static func writeExports(to url: URL) {
        guard reset(url), let made = try? GamCommands.exportToSheet(GamCommands.printDelegates(email: "carol@example.com"),
                                                                     title: "example.com - List mailbox delegates"),
              let refused = try? GamCommands.exportToSheet(GamCommands.printForwardingAddresses(email: "alice@example.com"),
                                                           title: "example.com - List forwarding addresses")
        else { return }
        let log = AuditLog(url: url)
        let ends: [(GamWrite, String, Bool, JSONObject)] = [
            (refused, "build.print_forwarding", false, ["upload": .string("drive_refused"), "kind": .string("service_not_enabled"),
                                                         "error": .string("User: admin@example.com, Drive API v3 Service/App not enabled")]),
            (made, "build.print_delegates", true, ["url": .string("https://docs.google.com/spreadsheets/d/1MockSheet3215791460/edit?usp=drivesdk")]),
        ]
        for (index, (write, command, ok, kept)) in ends.enumerated() {
            // 2026-11-21 14:00 UTC, an hour apart.
            let at = Date(timeIntervalSince1970: 1_795_788_000 + Double(index) * 3_600)
            var begin: JSONObject = ["command": .string(command), "preview": .string(UUID().uuidString), "origin": .string("form"),
                                     "step": .number("0"), "phase": .string("begin")]
            _ = try? log.record(write.action.rawValue, target: "admin@example.com", argv: write.argv, actor: "admin@example.com",
                                extra: begin, domain: "example.com", now: at)
            begin["phase"] = .string("end")
            for (key, value) in kept { begin[key] = value }
            _ = try? log.record(write.action.rawValue, target: "admin@example.com", argv: write.argv, exitCode: ok ? 0 : 73, ok: ok,
                                actor: "admin@example.com", extra: begin, domain: "example.com", now: at + 20)
        }
    }

    static func write(to url: URL) {
        guard reset(url) else { return }
        let log = AuditLog(url: url)
        var minutes = 0.0
        /// 2026-10-08 09:00 UTC, a minute later each record.
        func next() -> Date {
            minutes += 1
            return Date(timeIntervalSince1970: 1_791_450_000 + minutes * 60)
        }
        func change(_ write: GamWrite, _ target: String, about: [String: String] = [:], failing error: String? = nil,
                    kind: String = "", ends: Bool = true, on domain: String = "example.com") {
            var extra: JSONObject = ["preview": .string(UUID().uuidString), "origin": .string("form"), "step": .number("0")]
            for (key, value) in about { extra[key] = .string(value) }
            var begin = extra
            begin["phase"] = .string("begin")
            _ = try? log.record(write.action.rawValue, target: target, argv: write.argv, actor: "admin@example.com", extra: begin,
                                domain: domain, now: next())
            guard ends else { return }
            var end = extra
            end["phase"] = .string("end")
            if let error {
                end["error"] = .string(error)
                end["kind"] = .string(kind)
            }
            _ = try? log.record(write.action.rawValue, target: target, argv: write.argv, exitCode: error == nil ? 0 : 50,
                            ok: error == nil, actor: "admin@example.com", extra: end, domain: domain, now: next())
        }
        /// A Builder read as `ReadAudit` records it once it ends: never its output.
        func read(_ command: String, _ target: String, _ argv: [String], on domain: String, _ outcome: ReadAudit.Outcome) {
            guard let domain = Domain(domain) else { return }
            _ = try? ReadAudit(log: log).record(command: command, target: target, argv: argv, domain: domain, outcome: outcome, now: next())
        }
        // Written by GamGUI before records named their domain: Unknown.
        _ = try? log.record("add_group_member", target: "dana@example.com",
                        argv: ["update", "group", "staff@example.com", "add", "member", "dana@example.com"], exitCode: 0, ok: true,
                        extra: ["group": .string("staff@example.com")], domain: nil, now: next())
        _ = try? log.record("remove_domain", connector: "keychain", target: "example.net", ok: true,
                        extra: ["detail": .string("Deleted example.net's credentials from the Keychain."), "outcome": .string("deleted")],
                        domain: nil, now: next())
        for (index, name) in ["erin", "frank", "grace", "heidi", "ivan", "judy", "mallory"].enumerated() {
            change(GamCommands.updateOrganization(email: "\(name)@example.com", title: "Account Manager",
                                                  department: index.isMultiple(of: 2) ? "Sales" : "Support"), "\(name)@example.com")
        }
        change(GamCommands.addDelegate(email: "alice@example.com", delegate: "bob@example.com"), "alice@example.com")
        change(GamCommands.setVacation(email: "carol@example.com", subject: "Out of office", message: "Back on Monday."),
               "carol@example.com")
        change(GamCommands.removeGroupMember(group: "staff@example.com", member: "bob@example.com"), "bob@example.com",
               about: ["group": "staff@example.com"])
        change(GamCommands.signOutUser(email: "bob@example.com"), "bob@example.com",
               failing: "User: bob@example.com, Sign Out Failed: Not Authorized to access this resource/api", kind: "scope_missing")
        change(GamCommands.updateOrganization(email: "olivia@example.org", title: "Teacher", department: "Science"), "olivia@example.org",
               on: "example.org")
        read("raw.4497", "(command)", ["print", "licenses"], on: "example.org", .read(rows: 42))
        change(GamCommands.setSignature(email: "alice@example.com", signature: "<p>Alice Anders</p>"), "alice@example.com")
        change(GamCommands.setSuspended(email: "dana@example.com", suspended: true), "dana@example.com", ends: false)
        change(GamCommands.addGroupMember(group: "sales@example.com", member: "bob@example.com"), "bob@example.com",
               about: ["group": "sales@example.com"], failing: "Member already exists.", kind: "duplicate")
        change(GamCommands.updateOrganization(email: "alice@example.com", title: "IT Director", department: "IT"), "alice@example.com")
        read("raw.7950", "alice@example.com", ["user", "alice@example.com", "print", "delegates"], on: "example.com", .read(rows: 2))
        // A user who isn't one: the mock's (GAM's) stderr and exit code, worded as the Builder words any failed read.
        let missing = ["user", "zoe@example.com", "print", "delegates"]
        read("raw.7950", "zoe@example.com", missing, on: "example.com",
             .failed(GamError(exitCode: 56, stderr: "Getting all Delegates for zoe@example.com\nUser: zoe@example.com, Does not exist\n",
                              argv: missing).message))
        // A bare `print users` prints one column (primaryEmail), no comma: not a table, so no row count, as GamGUI records it.
        read("raw.6078", "(command)", ["print", "users"], on: "example.org", .read(rows: nil))
    }
}
#endif
