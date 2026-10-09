import Foundation
import Vault

/// The service-account scopes Setup asks the operator to authorize for domain-wide delegation: those of
/// the APIs the curated `gam user …` commands call. Copied from GamGUI's `core/setup.py` `DWD_SCOPES`
/// (taken from the vendored GAM's service-account table, not guessed). A client-access scope (the
/// admin token's, such as `admin.directory.user.security`) never belongs here: delegation can't grant
/// it, and GAM refuses it in `check serviceaccount`.
public enum DelegationScopes {
    public static let all: [(scope: String, purpose: String)] = [
        ("https://www.googleapis.com/auth/calendar", "Calendar sharing, the offboarding sweep and reminder"),
        ("https://mail.google.com/", "Gmail full access — GAM's default Gmail scope; message search"),
        ("https://www.googleapis.com/auth/gmail.modify", "Gmail messages and labels — GAM's default"),
        ("https://www.googleapis.com/auth/gmail.settings.basic", "Signatures and auto-reply"),
        ("https://www.googleapis.com/auth/gmail.settings.sharing", "Mail delegation and forwarding"),
        ("https://www.googleapis.com/auth/drive", "A user's Drive file list"),
        ("https://www.googleapis.com/auth/tasks", "Onboarding task lists"),
    ]

    public static var scopes: [String] { all.map(\.scope) }

    /// The Admin-console page that adds the client and its scopes, pre-filled: the same shape
    /// `gam check serviceaccount` prints on a failure. Nil without a client ID.
    public static func authorizationURL(clientID: String, scopes: [String] = scopes, domain: Domain? = nil) -> URL? {
        guard !clientID.isEmpty else { return nil }
        var components = URLComponents(string: "https://admin.google.com/ac/owl/domainwidedelegation")!
        var items = [
            URLQueryItem(name: "clientScopeToAdd", value: scopes.joined(separator: ",")),
            URLQueryItem(name: "clientIdToAdd", value: clientID),
            URLQueryItem(name: "overwriteClientId", value: "true"),
        ]
        if let domain { items.append(URLQueryItem(name: "dn", value: domain.name)) }
        components.queryItems = items
        return components.url
    }
}

/// The vendored build's exit codes Setup branches on, held to `Tests/Fixtures/exit_codes.json` (read
/// from the binary itself). They were once guessed as 1 (GamGUI failure-log 2026-10-01).
public enum GamExitCode {
    /// A delegated scope isn't authorized; the PASS/FAIL table and the link are on stdout.
    public static let scopesNotAuthorized: Int32 = 10
    /// A missing, unreadable or rejected `oauth2service.json`. Rows on stdout only for a rejected key.
    public static let oauth2ServiceJSONRequired: Int32 = 16
    /// Exits whose stdout can still be `check serviceaccount`'s answer.
    public static let checkAnswers: Set<Int32> = [scopesNotAuthorized, oauth2ServiceJSONRequired]
}

/// `gam user <admin> check serviceaccount scopes …`, read. Port of GamGUI's `verify()`,
/// `_check_result`, `_parse_check` and `_extract_auth_url`, with their failure history: a failing
/// scope and a rejected key are answers, not crashes (2026-09-25); each row is classified before it is
/// summarized, because a failing key is not a delegation problem (2026-09-25).
public struct AccessCheck: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let label: String
        public let passed: Bool
        public var isScope: Bool { label.hasPrefix("https://") }
    }

    public enum Outcome: Sendable, Equatable {
        case authorized
        /// Domain-wide delegation is missing for `failed` of `of` scopes (or for an unknown number).
        case delegationIncomplete(failed: Int, of: Int)
        /// A non-scope check failed (the service-account key, this Mac's clock): no link helps.
        case serviceAccountProblem([String])
        /// GAM failed without a check answer; its last error line.
        case failed(String)
    }

    public let outcome: Outcome
    public let rows: [Row]
    /// GAM's Admin-console link, when delegation is incomplete. The direct admin.google.com one wins
    /// over GAM's third-party short link.
    public let authorizationURL: URL?

    public var isAuthorized: Bool { outcome == .authorized }

    public static func interpret(_ result: GamResult) -> AccessCheck {
        let rows = rows(in: result.stdout)
        guard result.exitCode == 0 || (GamExitCode.checkAnswers.contains(result.exitCode) && !rows.isEmpty) else {
            return AccessCheck(outcome: .failed(errorLine(in: result.stderr) ?? "GAM exited \(result.exitCode)"),
                               rows: [], authorizationURL: nil)
        }
        let text = PythonText.upper(result.stdout)
        let failed = result.exitCode != 0 || text.contains("FAILED") || text.contains("DISABLED!")
            || rows.contains { !$0.passed }
        if !rows.isEmpty, !failed {
            return AccessCheck(outcome: .authorized, rows: rows, authorizationURL: nil)
        }
        let failingChecks = rows.filter { !$0.passed && !$0.isScope }.map(\.label)
        if !failingChecks.isEmpty {
            return AccessCheck(outcome: .serviceAccountProblem(failingChecks), rows: rows, authorizationURL: nil)
        }
        let scopes = rows.filter(\.isScope)
        return AccessCheck(outcome: .delegationIncomplete(failed: scopes.filter { !$0.passed }.count, of: scopes.count),
                           rows: rows, authorizationURL: authorizationURL(in: result.stdout))
    }

    /// GAM's own error line: the first that starts `ERROR:`, not the instructions GAM prints after it
    /// ("Please run: gam oauth create"), which once replaced the real error (GamGUI failure-log
    /// 2026-10-01). Otherwise the last non-empty line.
    static func errorLine(in stderr: String) -> String? {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.first { $0.hasPrefix("ERROR:") } ?? lines.last
    }

    /// GAM's check prints about fifteen lines; anything past this is not a check table.
    static let rowLineLimit = 1000

    /// `(label, PASS/FAIL)` from both `Label: PASS` and GAM's scope-table `<scope>   FAIL (n/m)` forms.
    /// Word boundaries are the simple, ASCII ones Python's `\b` uses, so `Key:FAIL` is still a row.
    static func rows(in stdout: String) -> [Row] {
        let status = /\b(PASS|FAIL)\b/.wordBoundaryKind(.simple)
        return stdout.split(whereSeparator: \.isNewline).prefix(rowLineLimit).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let match = line.firstMatch(of: status) else { return nil }
            let label = line[..<match.range.lowerBound].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":")).trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : Row(label: label, passed: match.output.1 == "PASS")
        }
    }

    static func authorizationURL(in stdout: String) -> URL? {
        let found = stdout.matches(of: /https:\/\/(?:gam-shortn\.appspot\.com|admin\.google\.com)\/\S+/)
            .map { String($0.output).trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        let direct = found.first { $0.hasPrefix("https://admin.google.com/") }
        return (direct ?? found.first).flatMap(URL.init(string:))
    }
}

extension AuthenticatedRunner {
    /// Setup's "Check access": a read, run as `admin` against exactly `DelegationScopes`. Throws the
    /// Vault's errors (no credentials, a locked Mac) and the runner's; GAM's own answer, pass or fail,
    /// comes back as an `AccessCheck`.
    public func checkAccess(admin: String, as domain: Domain) async throws -> AccessCheck {
        let read = try GamCommands.checkServiceAccount(admin: admin, scopes: DelegationScopes.scopes)
        return AccessCheck.interpret(try await run(read, as: domain))
    }
}
