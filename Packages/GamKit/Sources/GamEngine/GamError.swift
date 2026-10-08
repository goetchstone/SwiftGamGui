/// A failed GAM run, read as GamGUI reads one (`core/gam/errors.py`): a kind that drives the remediation
/// and whether a bulk loop stops, the message an operator sees, and GAM's output with any echoed secret
/// masked. Held to `Tests/Fixtures/gam_errors.json` (generated from frozen GamGUI by
/// `scripts/gen_fixtures.py`) by `GamErrorTests`. The patterns are GamGUI's, each placed and ordered by
/// an incident in its failure log; the comments say which.
public struct GamError: Error, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case authExpired = "auth_expired"
        case scopeMissing = "scope_missing"
        case rateLimited = "rate_limited"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        /// Google refused to remove a calendar owner's own access: the one refusal the offboarding sweep
        /// expects (the leaver's own calendar), unlike a real 403.
        case ownACL = "own_acl"
        /// A user for whom a Google service is off (GAM's "<Service> Service/App not enabled"), not the
        /// account-wide "<API> not enabled. Please run …" failure.
        case serviceNotEnabled = "service_not_enabled"
        /// No free license for another account ("Domain user limit reached", seen live 2026-09-30).
        /// Every later create fails the same way.
        case licenseLimit = "license_limit"
        case notAuthenticated = "not_authenticated"
        case timeout
        case unknown

        /// Most severe first. A stderr whose lines disagree reads as its most severe line, so a real
        /// failure is never reported as the benign per-entity notice printed beside it. An account-wide
        /// failure outranks a per-entity one, and an unrecognized error outranks the refusals a
        /// best-effort sweep tolerates.
        public static let bySeverity: [Kind] = [
            .authExpired, .notAuthenticated, .scopeMissing, .licenseLimit, .rateLimited, .timeout, .unknown,
            .permissionDenied, .ownACL, .serviceNotEnabled, .notFound,
        ]

        /// About the connection, not the one target: every later call in a bulk loop would fail the same
        /// way, so the loop stops at the first. Not `licenseLimit`: only later creates fail.
        public var isAccountWide: Bool {
            self == .authExpired || self == .notAuthenticated || self == .scopeMissing
        }

        public var remediation: String {
            switch self {
            // The admin token in oauth2.txt was revoked or expired. Check access tests the service
            // account, not this, and importing the folder again is the only way to replace it.
            case .authExpired:
                "Your sign-in expired. Run `gam oauth create` again, then import the folder again on Setup."
            // Two places grant a scope, and GAM's words don't say which.
            case .scopeMissing:
                "A required API scope is not authorized. An admin (Directory, Reports) scope is granted by "
                    + "re-running `gam oauth create` and ticking it; a per-user (Gmail, Calendar, Drive) scope "
                    + "by Domain-Wide Delegation. Setup's Check access re-checks the delegated scopes GamGUI's "
                    + "own commands use and links to authorize any that fail."
            case .rateLimited:
                "Google is rate-limiting requests. Wait a moment and retry."
            case .notFound:
                "The requested user, group, or resource was not found."
            case .permissionDenied:
                "The authorized account lacks permission for this action. Check the admin role and scopes."
            case .ownACL:
                "Google doesn't let a calendar's owner remove their own access. That's expected for the "
                    + "departing user's own calendar."
            case .serviceNotEnabled:
                "That Google service is turned off for this user. Check their license, or the service's "
                    + "on/off setting for their organizational unit in the Admin console."
            case .licenseLimit:
                "Your Google Workspace subscription has no free license for another account. Free one "
                    + "(delete or unlicense a departed user's account) or add licenses under Billing in the "
                    + "Admin console, then run it again."
            case .notAuthenticated:
                "GAM is not set up for this domain yet. Import its credentials on Setup first."
            case .timeout:
                "The command timed out. Check connectivity and retry."
            case .unknown:
                "GAM reported an error. See the details."
            }
        }
    }

    public let kind: Kind
    /// GAM's exit code; nil when the process never returned (a timeout).
    public let exitCode: Int32?
    /// The kind of every error line; `kind` is the most severe of them. A best-effort caller checks
    /// these, so one real failure among benign per-entity notices is never tolerated.
    public let kinds: Set<Kind>
    /// GAM's stderr, with echoed secrets masked: GAM echoes the command line, password included, on a
    /// usage error.
    public let stderr: String
    /// The argv that ran, with the value after each sensitive keyword masked.
    public let argv: [String]?
    /// What GAM printed on stdout before failing, masked like stderr. Some failures answer there
    /// (`check serviceaccount`'s table). Never in `message`, `description` or a dump: a logged error
    /// carries no directory data.
    public let stdout: String

    /// GamGUI's `GAMError.from_run`. A nil exit code is a timeout, whatever was printed.
    public init(exitCode: Int32?, stderr: String, argv: [String]? = nil, stdout: String = "") {
        if let exitCode {
            let kinds = Set(Self.errorLines(stderr).map(\.kind))
            kind = Self.worst(kinds)
            self.kinds = kinds.isEmpty ? [kind] : kinds
            self.exitCode = exitCode
        } else {
            kind = .timeout
            kinds = [.timeout]
            self.exitCode = nil
        }
        self.stderr = SecretScrub.scrub(stderr)
        self.stdout = SecretScrub.scrub(stdout)
        self.argv = argv.map(ArgvRedaction.redact)
    }

    /// The kind's remediation; for a missing scope, followed by the scopes GAM named.
    public var remediation: String {
        guard kind == .scopeMissing else { return kind.remediation }
        let named = ScopeURLs.find(in: stderr)
        return named.isEmpty ? kind.remediation : kind.remediation + " GAM named: " + named.joined(separator: ", ") + "."
    }

    /// The last line of the reported kind: in a mixed stderr the tail can be a benign notice.
    public var message: String {
        let lines = Self.errorLines(stderr)
        let shown = lines.filter { $0.kind == kind }.map(\.line)
        let detail = (shown.isEmpty ? lines.map(\.line) : shown).last ?? ""
        let base = "GAM failed (\(kind.rawValue), exit=\(exitCode.map(String.init) ?? "None"))"
        return detail.isEmpty ? base : "\(base): \(detail)"
    }

    // MARK: classifying stderr

    /// Each stderr line that reports something, with its kind. A multi-entity command (`all users …`)
    /// prints one line per entity, so a stderr can hold benign and real failures side by side;
    /// classifying the whole text by its first match let one "not found" mask the rest (GamGUI
    /// failure-log 2026-09-23).
    static func errorLines(_ stderr: String) -> [(kind: Kind, line: String)] {
        PythonText.lines(stderr).map(PythonText.strip)
            .filter { !$0.isEmpty && !isProgress($0) && !isInstruction($0) }
            .map { (classify($0), $0) }
    }

    static func worst(_ kinds: Set<Kind>) -> Kind {
        Kind.bySeverity.first(where: kinds.contains) ?? .unknown
    }

    /// GAM's progress chatter on stderr (gam.cfg `show_gettings`, on by default): "Getting all Users,
    /// may take some time…", "Got 150 Users: …". Not an error line.
    static func isProgress(_ line: String) -> Bool {
        let scalars = Array(line.unicodeScalars)
        if scalars.starts(with: "Getting all ".unicodeScalars) { return true }
        guard scalars.starts(with: "Got ".unicodeScalars) else { return false }
        let digits = scalars.dropFirst(4).prefix(while: PythonText.isDecimal)
        return !digits.isEmpty && scalars.dropFirst(4 + digits.count).first == " "
    }

    /// The instructions GAM prints after a rejected service-account key say what to run, not what
    /// failed. Read as error lines, the last ("…a Service account.") read as not-authenticated and
    /// became the message (GamGUI failure-log 2026-10-01).
    static let instructions = ["Please run", "gam create|use project", "gam user <user> update serviceaccount",
                               "to create and authorize a Service account."]

    static func isInstruction(_ line: String) -> Bool {
        instructions.contains { $0.utf8.elementsEqual(line.utf8) }
    }

    /// One line's kind, first match wins. Order matters: more specific first.
    static func classify(_ line: String) -> Kind {
        let text = Folded(EntityCount.removed(from: line))
        // A per-user Gmail or Calendar command for an address that isn't a user: GAM reports the token
        // endpoint's words against that user. Before the expired sign-in, whose "invalid_grant" it
        // also says: the admin's sign-in is fine (GamGUI failure-log 2026-09-23).
        if text.has("invalid_grant: invalid email or user id") || text.has("invalid_grant: not a valid email")
            || text.has("invalid_grant: the account has been deleted") { return .notFound }
        if text.has("invalid_grant") || text.has("token has been expired or revoked") { return .authExpired }
        if text.has("insufficient", thenLater: "scope") || text.has("access_denied", thenLater: "scope")
            || text.has("not authorized to access") { return .scopeMissing }
        // `rate.?limit` also covers "userRateLimitExceeded".
        if text.has("rate", thenAtMostOneThen: "limit") || text.has("quota") || text.has("too many requests")
            || text.hasWord("429") { return .rateLimited }
        // A missing or unreadable credentials file is setup, not a missing user: before not-found,
        // whose words it also says (GamGUI failure-log 2026-09-23).
        if text.hasCredentialFileMissing || text.has("oauth2 file:", thenLater: "does not exist") { return .notAuthenticated }
        // Its own kind, before the generic 403: the sweep tolerates exactly this refusal.
        if text.has("cannot change your own access level") || text.has("cannotchangeownacl") { return .ownACL }
        // Before not-found: a refusal that also says "not found" is a refusal; after it, a real 403
        // passed as the not-found an all-users sweep tolerates (GamGUI failure-log 2026-09-24).
        if text.has("forbidden") || text.has("permission denied") || text.has("insufficientpermissions")
            || text.hasWord("403") { return .permissionDenied }
        // GamGUI's `resource.*not found` is covered by "not found".
        if text.has("does not exist") || text.has("not found") || text.has("notfound") || text.hasWord("404") { return .notFound }
        // Narrow on purpose: GAM's account-wide "Calendar not enabled. Please run …" is a real failure.
        if text.has("service/app not enabled") { return .serviceNotEnabled }
        if text.has("domain user limit reached") { return .licenseLimit }
        if text.has("please run", thenLater: "oauth") || text.has("no", thenLater: "credentials")
            || text.has("service account") { return .notAuthenticated }
        return .unknown
    }

    /// A line as `re.IGNORECASE` compares it to GamGUI's ASCII patterns, which are written here in
    /// lowercase. Folding keeps one scalar per scalar, and a letter folds to a letter, so `\b` reads it
    /// as it reads the original.
    struct Folded {
        let scalars: [Unicode.Scalar]

        init(_ line: String) {
            scalars = line.unicodeScalars.map(PythonText.folded)
        }

        /// The starts of every occurrence of `needle`.
        func starts(of needle: String) -> [Int] {
            let target = Array(needle.unicodeScalars)
            guard !target.isEmpty, scalars.count >= target.count else { return [] }
            return (0...(scalars.count - target.count)).filter { scalars[$0..<($0 + target.count)].elementsEqual(target) }
        }

        func has(_ needle: String) -> Bool {
            !starts(of: needle).isEmpty
        }

        /// `first.*then`.
        func has(_ first: String, thenLater then: String) -> Bool {
            guard let start = starts(of: first).first else { return false }
            let after = start + first.unicodeScalars.count
            return starts(of: then).contains { $0 >= after }
        }

        /// `first.?then`.
        func has(_ first: String, thenAtMostOneThen then: String) -> Bool {
            let length = first.unicodeScalars.count
            let thens = Set(starts(of: then))
            return starts(of: first).contains { thens.contains($0 + length) || thens.contains($0 + length + 1) }
        }

        /// `\bneedle\b`, for a needle that starts and ends with word characters.
        func hasWord(_ needle: String) -> Bool {
            let length = needle.unicodeScalars.count
            return starts(of: needle).contains { start in
                (start == 0 || !PythonText.isWord(scalars[start - 1]))
                    && (start + length == scalars.count || !PythonText.isWord(scalars[start + length]))
            }
        }

        /// `oauth2(?:service)?\.(?:txt|json)\b.*(?:not found|does not exist)`.
        var hasCredentialFileMissing: Bool {
            for name in ["oauth2.txt", "oauth2.json", "oauth2service.txt", "oauth2service.json"] {
                let length = name.unicodeScalars.count
                for start in starts(of: name) {
                    let end = start + length
                    guard end == scalars.count || !PythonText.isWord(scalars[end]) else { continue }
                    if starts(of: "not found").contains(where: { $0 >= end })
                        || starts(of: "does not exist").contains(where: { $0 >= end }) { return true }
                }
            }
            return false
        }
    }
}

extension GamError: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { message }
    public var debugDescription: String { message }
    /// Everything but `stdout`, so a dump of a logged error carries no directory data.
    public var customMirror: Mirror {
        Mirror(self, children: ["kind": kind, "exitCode": exitCode as Any, "kinds": kinds,
                                "stderr": stderr, "argv": argv as Any])
    }
}

/// GAM's per-entity counter, " (403/1200)" on the 403rd of 1,200 users: `\s*\(\d+/\d+\)`. Dropped
/// before classifying, since the status-code patterns read it as an HTTP 403, 404 or 429 (GamGUI
/// failure-log 2026-09-24).
enum EntityCount {
    static func removed(from line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        var kept = String.UnicodeScalarView(), index = 0
        while index < scalars.count {
            if let end = match(scalars, at: index) {
                index = end
            } else {
                kept.append(scalars[index])
                index += 1
            }
        }
        return String(kept)
    }

    private static func match(_ scalars: [Unicode.Scalar], at start: Int) -> Int? {
        var index = start
        while index < scalars.count, PythonText.isSpace(scalars[index]) { index += 1 }
        func digits() -> Bool {
            let first = index
            while index < scalars.count, PythonText.isDecimal(scalars[index]) { index += 1 }
            return index > first
        }
        func literal(_ scalar: Unicode.Scalar) -> Bool {
            guard index < scalars.count, scalars[index] == scalar else { return false }
            index += 1
            return true
        }
        return literal("(") && digits() && literal("/") && digits() && literal(")") ? index : nil
    }
}

/// GamGUI's `_scrub_stderr`: `(?i)\b(password|notifypassword)\s+\S+` becomes the keyword (as GAM printed
/// it) and a mask. GAM echoes the full command line on a usage error, so a submitted password can
/// appear in its output. A value with a space (echoed quoted) is masked only up to the space, as in
/// GamGUI; every password the app sends is one token.
enum SecretScrub {
    static let keywords = ["password", "notifypassword"]

    static func scrub(_ text: String) -> String {
        let original = Array(text.unicodeScalars)
        let folded = original.map(PythonText.folded)
        var out = String.UnicodeScalarView(), index = 0
        while index < original.count {
            if index == 0 || !PythonText.isWord(original[index - 1]), let (keywordEnd, end) = match(folded, at: index) {
                out.append(contentsOf: original[index..<keywordEnd])
                out.append(contentsOf: " ***redacted***".unicodeScalars)
                index = end
            } else {
                out.append(original[index])
                index += 1
            }
        }
        return String(out)
    }

    private static func match(_ folded: [Unicode.Scalar], at start: Int) -> (keywordEnd: Int, end: Int)? {
        for keyword in keywords {
            let target = Array(keyword.unicodeScalars)
            guard folded.count >= start + target.count, folded[start..<(start + target.count)].elementsEqual(target) else { continue }
            var index = start + target.count
            let spaces = index
            while index < folded.count, PythonText.isSpace(folded[index]) { index += 1 }
            let value = index
            while index < folded.count, !PythonText.isSpace(folded[index]) { index += 1 }
            if value > spaces, index > value { return (start + target.count, index) }
        }
        return nil
    }
}

/// GamGUI's `redact_argv`: the value after a sensitive keyword is masked, for the audit and for errors.
public enum ArgvRedaction {
    public static let sensitiveKeys = ["password", "notifypassword", "signature", "recoveryemail", "recoveryphone", "alternateemail"]
    public static let mask = "***redacted***"

    public static func redact(_ argv: [String]) -> [String] {
        var out: [String] = [], maskNext = false
        for token in argv {
            if maskNext {
                out.append(mask)
                maskNext = false
                continue
            }
            out.append(token)
            let lowered = token.lowercased()
            maskNext = sensitiveKeys.contains { $0.utf8.elementsEqual(lowered.utf8) }
        }
        return out
    }
}

/// The Google API scope URLs GAM names in an error, as GamGUI's `_SCOPE_URL` finds them
/// (`https://(?:www\.googleapis\.com/auth/[\w.\-/]*\w|mail\.google\.com/)`), deduplicated and in
/// code-point order. A URL ends at its last word character, so a sentence's punctuation isn't taken.
enum ScopeURLs {
    static func find(in text: String) -> [String] {
        let scalars = Array(text.unicodeScalars)
        var found: [[Unicode.Scalar]] = [], index = 0
        while index < scalars.count {
            if let end = match(scalars, at: index) {
                let url = Array(scalars[index..<end])
                if !found.contains(url) { found.append(url) }
                index = end
            } else {
                index += 1
            }
        }
        return found.sorted { $0.lexicographicallyPrecedes($1) { $0.value < $1.value } }.map(PythonText.string)
    }

    private static func match(_ scalars: [Unicode.Scalar], at start: Int) -> Int? {
        func has(_ literal: String, at index: Int) -> Bool {
            let target = Array(literal.unicodeScalars)
            return scalars.count >= index + target.count && scalars[index..<(index + target.count)].elementsEqual(target)
        }
        guard has("https://", at: start) else { return nil }
        let host = start + 8
        if has("www.googleapis.com/auth/", at: host) {
            let path = host + 24
            var index = path, lastWord: Int?
            while index < scalars.count, PythonText.isWord(scalars[index]) || ".-/".unicodeScalars.contains(scalars[index]) {
                if PythonText.isWord(scalars[index]) { lastWord = index }
                index += 1
            }
            if let lastWord { return lastWord + 1 }
        }
        return has("mail.google.com/", at: host) ? host + 16 : nil
    }
}
