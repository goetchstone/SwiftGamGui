#if DEBUG
import ChangeCore
import Foundation
import GamEngine

/// Debug builds only: the Audit screen's demo log, for its screenshots. Written fresh in the temporary folder
/// `AppServices.demo()` hands it, never anywhere else: example changes as this app records them (a begin, then
/// an end), one that failed, one the app stopped in the middle of, and two records GamGUI wrote. Enough for two pages.
enum DemoAudit {
    static func write(to url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) else { return }
        for suffix in [""] + (1...AuditLog.retainedGenerations).map({ ".\($0)" }) {
            try? FileManager.default.removeItem(at: URL(filePath: url.path + suffix))
        }
        let log = AuditLog(url: url)
        var minutes = 0.0
        /// 2026-10-08 09:00 UTC, a minute later each record.
        func next() -> Date {
            minutes += 1
            return Date(timeIntervalSince1970: 1_791_450_000 + minutes * 60)
        }
        func change(_ write: GamWrite, _ target: String, about: [String: String] = [:], failing error: String? = nil,
                    kind: String = "", ends: Bool = true) {
            var extra: JSONObject = ["preview": .string(UUID().uuidString), "origin": .string("form"), "step": .number("0")]
            for (key, value) in about { extra[key] = .string(value) }
            var begin = extra
            begin["phase"] = .string("begin")
            _ = try? log.record(write.action.rawValue, target: target, argv: write.argv, actor: "admin@example.com", extra: begin, now: next())
            guard ends else { return }
            var end = extra
            end["phase"] = .string("end")
            if let error {
                end["error"] = .string(error)
                end["kind"] = .string(kind)
            }
            _ = try? log.record(write.action.rawValue, target: target, argv: write.argv, exitCode: error == nil ? 0 : 50,
                            ok: error == nil, actor: "admin@example.com", extra: end, now: next())
        }
        _ = try? log.record("add_group_member", target: "dana@example.com",
                        argv: ["update", "group", "staff@example.com", "add", "member", "dana@example.com"], exitCode: 0, ok: true,
                        extra: ["group": .string("staff@example.com")], now: next())
        _ = try? log.record("remove_domain", connector: "keychain", target: "example.net", ok: true,
                        extra: ["detail": .string("Deleted example.net's credentials from the Keychain."), "outcome": .string("deleted")],
                        now: next())
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
        change(GamCommands.setSignature(email: "alice@example.com", signature: "<p>Alice Anders</p>"), "alice@example.com")
        change(GamCommands.setSuspended(email: "dana@example.com", suspended: true), "dana@example.com", ends: false)
        change(GamCommands.addGroupMember(group: "sales@example.com", member: "bob@example.com"), "bob@example.com",
               about: ["group": "sales@example.com"], failing: "Member already exists.", kind: "duplicate")
        change(GamCommands.updateOrganization(email: "alice@example.com", title: "IT Director", department: "IT"), "alice@example.com")
    }
}
#endif
