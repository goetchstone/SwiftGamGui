import Foundation

/// Reports' named reports (GamGUI #151, roadmap 3.1, `core/reports.py` `NAMED_REPORTS`): nine domain-wide reads the Builder
/// already runs, named so they can be found, each with the access it needs. No builder of their own: each opens its catalog
/// read, which runs, filters and exports there like any other.
///
/// A read is named by its grammar up to its first option, never by its catalog id, which moves with every GAM bump:
/// `command(in:)` wants exactly one runnable read, and `NamedReportsTests` fails a bump that renames one or makes it match two.
/// Each token and scope is GAM's own (`gamlib/glapi.py` at 7.52.04: `_CLIENT_SCOPES` for the admin token, `_SVCACCT_SCOPES` for
/// the service account), checked there, not copied on trust.
public struct NamedReport: Sendable, Hashable, Identifiable {
    /// Which credential GAM reads it with.
    public enum Token: Sendable, Hashable {
        /// `oauth2.txt`: its scopes are ticked when GAM's OAuth client is created.
        case admin
        /// `oauth2service.json`, through domain-wide delegation.
        case serviceAccount
    }

    public let key: String
    public let title: String
    /// What it reads, in words.
    public let what: String
    /// The catalog command's grammar up to its first option.
    public let syntax: String
    public let token: Token
    public let scope: String
    public var id: String { key }

    /// GamGUI's table, in its order. The shared drives' members are "Shared drive members", never the audit run's "Shared drive
    /// permissions" (GamGUI #178): the notes that point to that run name it.
    public static let all: [NamedReport] = [
        NamedReport(key: "licenses", title: "Licenses", what: "Who holds which Google Workspace license.",
                    syntax: "gam print licenses", token: .admin, scope: "https://www.googleapis.com/auth/apps.licensing"),
        NamedReport(key: "shared_drives", title: "Shared drives", what: "Every shared drive in the domain.",
                    syntax: "gam print shareddrives", token: .serviceAccount, scope: "https://www.googleapis.com/auth/drive"),
        NamedReport(key: "shared_drive_acls", title: "Shared drive members", what: "Who has access to each shared drive, and how.",
                    syntax: "gam print shareddriveacls", token: .serviceAccount, scope: "https://www.googleapis.com/auth/drive"),
        NamedReport(key: "shared_drive_organizers", title: "Shared drive organizers", what: "Who can manage each shared drive.",
                    syntax: "gam print shareddriveorganizers", token: .serviceAccount, scope: "https://www.googleapis.com/auth/drive"),
        NamedReport(key: "org_units", title: "Org units", what: "The organizational units and their paths.",
                    syntax: "gam print orgs|ous", token: .admin, scope: "https://www.googleapis.com/auth/admin.directory.orgunit"),
        NamedReport(key: "mobile_devices", title: "Mobile devices", what: "Phones and tablets that sync with the domain.",
                    syntax: "gam print mobile", token: .admin, scope: "https://www.googleapis.com/auth/admin.directory.device.mobile"),
        NamedReport(key: "group_members", title: "Group memberships", what: "Every group's members and their roles.",
                    syntax: "gam print group-members", token: .admin, scope: "https://www.googleapis.com/auth/admin.directory.group"),
        NamedReport(key: "data_transfers", title: "Data transfers", what: "Drive and Calendar ownership transfers and how far each got.",
                    syntax: "gam print datatransfers|transfers", token: .admin,
                    scope: "https://www.googleapis.com/auth/admin.datatransfer"),
        NamedReport(key: "alerts", title: "Google's alerts", what: "The Alert Center: suspicious sign-ins, phishing, device issues.",
                    syntax: "gam print alerts", token: .serviceAccount, scope: "https://www.googleapis.com/auth/apps.alerts"),
    ]

    /// The one runnable catalog read this names (GamGUI's `named_report_command`), else nil: a bump renamed it, or it matches
    /// more than one. Bytes compared, so nothing Unicode treats as equal can stand in for the grammar.
    public func command(in catalog: CommandCatalog) -> CommandCatalog.Command? {
        let exact = Array(syntax.utf8), prefix = exact + Array(" ".utf8)
        let hits = catalog.commands.filter {
            let line = Array($0.syntax.utf8)
            return $0.runnable && (line == exact || line.starts(with: prefix))
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// `command` as this report's read built bare, as the Builder builds it with no option filled (GamGUI #178's `named_run`):
    /// nil unless it is a runnable read (confidently read-only, not sensitive) that asks for no value, whose argv starts with
    /// `print`. The one door from a named report to a `GamRead` an audit run may run (plan F7a): `catalogRead`'s own checks
    /// stand too, so nothing here can name a write.
    public static func bareRead(_ command: CommandCatalog.Command?) -> GamRead? {
        guard let command, command.runnable, command.risk == .read, !command.uncertain,
              !command.slots.contains(where: \.required),
              let read = try? GamCommands.catalogRead(command, values: [:]), read.argv.first == "print"
        else { return nil }
        return read
    }

    /// Whether the admin token holds this read's scope, or its `.readonly` form (GamGUI's `admin_scope_held`). Nil for a
    /// service-account read, whose delegation only GAM's own check can see, and when the token's scopes can't be read: unknown
    /// is never "held".
    public func adminScopeHeld(_ granted: [String]?) -> Bool? {
        guard token == .admin, let granted else { return nil }
        let wanted = [Array(scope.utf8), Array((scope + ".readonly").utf8)]
        return granted.contains { wanted.contains(Array($0.utf8)) }
    }
}
