import Foundation

/// One person's license seats (GamGUI's `core/licenses.py`, roadmap 4.3): what they hold, what can be added or changed, and
/// when a removal is refused. Every choice comes from one read, `print licenses`, which with no product named passes over a
/// product Google won't let it read without saying so: only what the read found is acted on, and "holds none found" is never
/// "holds none".
///
/// Google's words for the preview: "If you remove a user's license, you might lose their data." (Admin Help, "Assign, remove,
/// and reassign licenses"), which also says a license unassigned "might take up to 24 hours" before it can go to someone
/// else. A change is "a different SKU in the same product" (Licensing API, licenseAssignments.patch).
public enum Licenses {
    public static let source = "https://knowledge.workspace.google.com/admin/billing/assign-remove-and-reassign-licenses"
    public static let mightLoseData = "If you remove a user's license, you might lose their data."
    public static let reassignWait = "A license removed can take up to 24 hours before it can be given to someone else."
    public static let onlySeatsRead = "GAM passes over a product Google won't let it read without saying so, so this covers only the seats read."

    /// One seat as `print licenses` lists it: `userId,productId,productDisplay,skuId,skuDisplay`, userId lowercased by GAM.
    public struct Seat: Sendable, Hashable, Identifiable {
        public let user: String
        public let productID: String
        public let product: String
        public let skuID: String
        public let sku: String

        public init(user: String, productID: String, product: String, skuID: String, sku: String) {
            (self.user, self.productID, self.product, self.skuID, self.sku) = (user, productID, product, skuID, sku)
        }

        public init(record: GamOutput.Record) {
            func text(_ key: String) -> String { record[key]?.string ?? "" }
            self.init(user: PythonText.lower(PythonText.strip(text("userId"))), productID: text("productId"),
                      product: text("productDisplay"), skuID: text("skuId"), sku: text("skuDisplay"))
        }

        public var id: String { "\(user)|\(productID)|\(skuID)" }
        /// The license, whoever holds it.
        public var key: String { "\(productID)|\(skuID)" }
        /// Whether GAM can be given its IDs as one `nv:` seat (`GamCommands.licenseSKU`): one it can't is never offered.
        public var nameable: Bool { (try? GamCommands.licenseSKU(productID: productID, skuID: skuID)) != nil }

        fileprivate var byName: (String, String) { (PythonText.lower(product), PythonText.lower(sku)) }
    }

    private static func ordered(_ a: Seat, _ b: Seat) -> Bool {
        a.byName.0 != b.byName.0 ? a.byName.0.unicodeScalars.lexicographicallyPrecedes(b.byName.0.unicodeScalars)
            : a.byName.1.unicodeScalars.lexicographicallyPrecedes(b.byName.1.unicodeScalars)
    }

    /// GamGUI's `held_by`: the seats the read lists for `email`, one per license, by product then license name.
    public static func held(_ seats: [Seat], by email: String) -> [Seat] {
        let who = PythonText.lower(PythonText.strip(email))
        var byKey: [String: Seat] = [:]
        for seat in seats where seat.user == who { byKey[seat.key] = seat }
        return byKey.values.sorted(by: ordered)
    }

    /// GamGUI's `in_domain`: each license someone in the domain holds, the first seat standing in for its names.
    public static func inDomain(_ seats: [Seat]) -> [String: Seat] {
        var out: [String: Seat] = [:]
        for seat in seats where out[seat.key] == nil { out[seat.key] = seat }
        return out
    }

    /// GamGUI's `choices`: the seats they hold, each with what it can change to (another license of the same product the domain
    /// holds), and what can be added (a license of a product they hold none of).
    public struct Choices: Sendable {
        public let held: [(seat: Seat, changes: [Seat])]
        public let adds: [Seat]
    }

    public static func choices(_ seats: [Seat], for email: String) -> Choices {
        let mine = held(seats, by: email)
        let products = Set(mine.map(\.productID)), keys = Set(mine.map(\.key))
        let others = inDomain(seats).filter { !keys.contains($0.key) }.map(\.value).sorted(by: ordered)
        return Choices(held: mine.map { seat in (seat, others.filter { $0.productID == seat.productID }) },
                       adds: others.filter { !products.contains($0.productID) })
    }

    /// GamGUI's `on_suspended`: each seat on an account the directory read says is suspended, as (their primary address, the
    /// seat), one per license, by address then license name. A seat on an address the directory doesn't list isn't one.
    public static func onSuspended(_ seats: [Seat], users: [GamUser]) -> [(email: String, seat: Seat)] {
        var suspended: [String: String] = [:]
        for user in users where user.suspended {
            suspended[PythonText.lower(PythonText.strip(user.primaryEmail))] = PythonText.strip(user.primaryEmail)
        }
        var held: [String: (String, Seat)] = [:]
        for seat in seats { if let email = suspended[seat.user] { held["\(seat.user)|\(seat.key)"] = (email, seat) } }
        return held.values.sorted { a, b in
            let x = PythonText.lower(a.0), y = PythonText.lower(b.0)
            return x != y ? x.unicodeScalars.lexicographicallyPrecedes(y.unicodeScalars) : ordered(a.1, b.1)
        }.map { (email: $0.0, seat: $0.1) }
    }

    private static func failed(_ transfer: Offboarding.DataTransfer) -> Bool { PythonText.lower(PythonText.strip(transfer.status)) == "failed" }

    /// GamGUI's `transfer_refusal`: why a removal is refused while a data transfer from `email` is unfinished, or can't be
    /// checked (nil read). A transfer that failed has stopped and doesn't refuse: the confirm step names it.
    public static func transferRefusal(_ email: String, _ transfers: [Offboarding.DataTransfer]?) -> String? {
        guard let transfers else {
            return "Couldn't check whether a data transfer from \(email) is still running, so the license isn't removed. Try again in a moment."
        }
        let running = transfers.filter { !$0.isFinished && !failed($0) }
        guard !running.isEmpty else { return nil }
        let what = running.map { "\($0.application) (\($0.status.isEmpty ? "unfinished" : $0.status))" }.joined(separator: ", ")
        return "A data transfer from \(email) hasn't finished (\(what)), so the license isn't removed: remove it once the transfer completes."
    }

    /// GamGUI's `failed_transfers`: the applications whose transfer from them failed, for the confirm step to name.
    public static func failedTransfers(_ transfers: [Offboarding.DataTransfer]?) -> [String] {
        (transfers ?? []).filter(failed).map(\.application)
    }

    /// GamGUI's `many_refusal`: in a run over many people a failed transfer keeps the seat too (there is no one to ask).
    public static func manyRefusal(_ email: String, _ transfers: [Offboarding.DataTransfer]?) -> String? {
        if let refusal = transferRefusal(email, transfers) { return refusal }
        let failed = failedTransfers(transfers)
        guard !failed.isEmpty else { return nil }
        return "A data transfer from \(email) failed (\(failed.joined(separator: ", "))): what it was moving may still be only on their "
            + "account, so the license isn't removed. Transfer it again, or remove it from their page."
    }
}
