import GamEngine

/// How much a change can hurt.
public enum Risk: Int, Comparable, Sendable, CaseIterable {
    case readOnly = 0, low = 1, destructive = 2

    public static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
}

/// One concrete change a write would make, shown before it runs.
public struct Change: Sendable {
    /// The affected identity: an address, a group, a calendar.
    public let target: String
    public let summary: String
    public let risk: Risk
    /// The command that makes it, when the change is one `gam` call.
    public let argv: [String]?

    public init(target: String, summary: String, risk: Risk, argv: [String]? = nil) {
        self.target = target
        self.summary = summary
        self.risk = risk
        self.argv = argv
    }
}

/// What the operator gave at the confirm step: GamGUI's posted confirm fields, as values. The words are
/// kept as typed; the guard trims and folds them as GamGUI does.
public struct OperatorConfirmation: Sendable {
    /// The Confirm button.
    public var confirmed: Bool
    /// A destructive bulk change: the word `confirm`.
    public var typedWord: String
    /// A large opted-in change: the number of targets.
    public var typedCount: String
    /// An account delete: each deleted address.
    public var typedAddresses: [String]

    public init(confirmed: Bool = false, typedWord: String = "", typedCount: String = "", typedAddresses: [String] = []) {
        self.confirmed = confirmed
        self.typedWord = typedWord
        self.typedCount = typedCount
        self.typedAddresses = typedAddresses
    }
}

/// The destructive-operation guard, GamGUI's `core/guard.py`: what confirmation a set of changes needs,
/// and the check that it got it. Held to `Tests/Fixtures/guard.json` by `GuardTests`.
///
/// - destructive: a Confirm click;
/// - bulk (at least `bulkThreshold` targets) at any write risk: a Confirm click;
/// - destructive and bulk: the word `confirm` typed;
/// - more than a caller's `typedCountAbove` targets: their number typed;
/// - an account delete (a change whose argv is exactly `gam delete user <address>`): its address typed.
///
/// `refusal` is the half that counts. A screen showing a Confirm button proves nothing about what it
/// sends back: in GamGUI five routes once ran a suspend, an event delete, a company-wide signature
/// overwrite and a whole offboarding on a bare POST, because only their pages asked
/// (GamGUI failure-log 2026-09-23). Here the executor calls it before the first write.
public enum Guard {
    /// At or above this many targets a change is bulk.
    public static let bulkThreshold = 10
    /// Above this many, the decision warns that the change is unusually large.
    public static let hardCap = 200
    /// The count a caller passes as `typedCountAbove` when a mis-scoped overwrite of many accounts
    /// mustn't be clicked through.
    public static let countConfirmAbove = 25
    public static let typedWord = "confirm"

    public struct Decision: Sendable {
        public let maxRisk: Risk
        public let affected: [String]
        public let requiresConfirmation: Bool
        public let requiresTypedConfirmation: Bool
        public let overHardCap: Bool
        public let summary: String
        public let warnings: [String]
        public let requiresTypedCount: Bool
        /// The accounts deleted, each to be typed, once each in order.
        public let typedAddresses: [String]

        public var affectedCount: Int { affected.count }
    }

    public static func evaluate(
        _ changes: [Change], bulkThreshold: Int = bulkThreshold, hardCap: Int = hardCap, typedCountAbove: Int? = nil
    ) -> Decision {
        guard let maxRisk = changes.map(\.risk).max() else {
            return Decision(maxRisk: .readOnly, affected: [], requiresConfirmation: false, requiresTypedConfirmation: false,
                            overHardCap: false, summary: "No changes.", warnings: [], requiresTypedCount: false,
                            typedAddresses: [])
        }
        let affected = changes.map(\.target), count = affected.count
        let destructive = maxRisk == .destructive, bulk = count >= bulkThreshold
        let overHardCap = count > hardCap
        let verb = switch maxRisk {
        case .readOnly: "Read"
        case .low: "Change"
        case .destructive: "DESTRUCTIVE change"
        }
        var deleted: [String] = []
        for address in changes.compactMap(deletedAccount) where !deleted.contains(where: { $0.utf8.elementsEqual(address.utf8) }) {
            deleted.append(address)
        }
        return Decision(
            maxRisk: maxRisk, affected: affected,
            requiresConfirmation: destructive || (bulk && maxRisk >= .low),
            requiresTypedConfirmation: destructive && bulk,
            overHardCap: overHardCap,
            summary: "\(verb): \(count) target\(count == 1 ? "" : "s") affected.",
            warnings: overHardCap
                ? ["This affects \(count) accounts (over the \(hardCap) safety threshold). Double-check the target set."] : [],
            requiresTypedCount: typedCountAbove.map { count > $0 } ?? false,
            typedAddresses: deleted)
    }

    /// Why `confirmation` may not run `changes`, in the operator's words, or nil when it may.
    /// `confirmStep` is for a flow that always previews first (a bulk job, a multi-step routine): it
    /// needs the Confirm click whatever the count or risk. Above `typedCountAbove` targets the count
    /// typed must be the count resolved now, so a scope that grew since the preview is refused rather
    /// than run on the operator's older number.
    public static func refusal(
        _ changes: [Change], _ confirmation: OperatorConfirmation, confirmStep: Bool = false, typedCountAbove: Int? = nil
    ) -> String? {
        let decision = evaluate(changes, typedCountAbove: typedCountAbove)
        if decision.requiresTypedConfirmation {
            if !normalized(confirmation.typedWord).utf8.elementsEqual(typedWord.utf8) {
                return "Type confirm to run this destructive bulk change."
            }
        } else if (decision.requiresConfirmation || confirmStep) && !confirmation.confirmed {
            return "This change needs confirmation — preview it, then confirm."
        }
        let count = decision.affectedCount
        if decision.requiresTypedCount, !PythonText.strip(confirmation.typedCount).utf8.elementsEqual(String(count).utf8) {
            return "This changes \(count) accounts: preview again, and type \(count) to confirm."
        }
        let typed = Set(confirmation.typedAddresses.map { Array(normalized($0).utf8) })
        if decision.typedAddresses.contains(where: { !typed.contains(Array(normalized($0).utf8)) }) {
            return decision.typedAddresses.count == 1
                ? "Type the exact email address to confirm."
                : "Type the exact email address of each account to delete to confirm."
        }
        return nil
    }

    /// The address a change deletes when its argv is exactly an account delete.
    public static func deletedAccount(_ change: Change) -> String? {
        guard let argv = change.argv, let address = argv.last,
              argv.map({ Array($0.utf8) }) == GamCommands.deleteUser(email: address).argv.map({ Array($0.utf8) })
        else { return nil }
        return address
    }

    /// Why each typed address must not be deleted as typed. `resolved` pairs it with the primary address
    /// GAM resolves it to (nil: no such user). GAM's `delete user` deletes the account an alias belongs
    /// to, so an address resolving to another primary would delete an account the preview never named.
    public static func aliasDeletes(_ resolved: [(address: String, primary: String?)]) -> [String] {
        resolved.compactMap { address, primary in
            guard let primary, !primary.isEmpty,
                  !normalized(primary).utf8.elementsEqual(normalized(address).utf8) else { return nil }
            let shown = PythonText.strip(address)
            return "\(shown) is an alias of \(primary) — deleting it would delete \(primary)'s account. "
                + "Delete that account by its primary address, from the user's page."
        }
    }

    /// GamGUI's `.strip().lower()`.
    package static func normalized(_ text: String) -> String {
        PythonText.lower(PythonText.strip(text))
    }
}
