import Foundation
import GamEngine
import Vault

/// The read record (plan F1, GamGUI #170's `catalog_read`): one per catalog read the operator runs from the Builder, appended
/// to the audit log `Executor` writes once the read has ended, ok or failed. It says which command (`extra.command`),
/// whom it was about (`target`), where it was started (`extra.origin`), how many rows a table had (`extra.rows`) and the domain
/// (`extra.domain`); never the output. Held to GamGUI's records by `Tests/Fixtures/audit.json` (`reads`).
///
/// A read the app quits during leaves no record: `applicationWillTerminate` stops GAM and the app exits before the read's own
/// code runs again to write one. There is no begin record for a read, by choice: a read changed nothing, so there is no outcome
/// to check afterwards.
///
/// Not a write path (invariant 2): it holds an audit log and nothing else, so it can run no `gam`, and its one action is
/// `read` (`WriteRouteTests.theReadRecordIsNoWritePath`). Sensitive reads stay browse-only here, so `sensitive_read` is never
/// written; the screens still read GamGUI's as a read (`AuditLog.readActions`).
public struct ReadAudit: Sendable {
    /// Where a recorded read was started (GamGUI's `READ_ORIGINS`). GamGUI also has `sequence`, a read step of a Builder
    /// sequence; this app has no sequences, so only the Builder's Run. Any other origin can't be spelled: a case, never a string.
    public enum Origin: String, Sendable, CaseIterable {
        case builder
    }

    /// How the read ended.
    public enum Outcome: Sendable, Equatable {
        /// GAM answered: `rows` is how many rows its table had (`CatalogResult.tableRows`), nil when it printed no table.
        case read(rows: Int?)
        /// GAM's words, or why it couldn't run.
        case failed(String)
        /// Its task was cancelled before GAM finished. Nothing cancels a Builder read today; this is for a Stop, when one comes.
        /// A quit records nothing (above).
        case interrupted
    }

    /// The one action this writes.
    public static let action = "read"
    /// A read stopped before GAM finished (its task cancelled), as its record says it (`extra.error`).
    public static let interrupted = "Stopped before GAM finished, so nothing was read."

    private let log: AuditLog

    public init(log: AuditLog) {
        self.log = log
    }

    /// Appends the record of one read that ended, and returns it as written. `argv` is masked as every record's is. Throws
    /// when the log can't be written: the caller says so rather than show a read the log is missing. `now` is for tests.
    @discardableResult
    public func record(command: String, target: String, argv: [String], domain: Domain, origin: Origin = .builder,
                       outcome: Outcome, now: Date = Date()) throws -> JSONObject {
        var extra: JSONObject = ["command": .string(command), "origin": .string(origin.rawValue)]
        switch outcome {
        case .read(let rows): if let rows { extra["rows"] = .number(String(rows)) }
        case .failed(let error): extra["error"] = .string(error)
        case .interrupted: extra["error"] = .string(Self.interrupted)
        }
        let ok = if case .read = outcome { true } else { false }
        do {
            return try log.record(Self.action, target: target, argv: argv, ok: ok, extra: extra, domain: domain.name, now: now)
        } catch {
            AuditFailure.report(error)
            throw error
        }
    }
}
