import Foundation
import Observation
import Stores

/// Sign-ins marked as the person's own ("That was them"), for Incident's log reader: this app's own store
/// (`KnownSignInStore`), and why it didn't open. One store for every domain; each mark names its own.
@MainActor
@Observable
final class KnownSignIns {
    private(set) var store: KnownSignInStore?
    /// Why the store didn't open (its file couldn't be read, or moved aside): nothing is marked, so nothing is saved over it.
    let openProblem: String?

    init(root: URL) {
        do {
            store = try KnownSignInStore(root: root)
            openProblem = nil
        } catch {
            openProblem = error.message
        }
    }

    func marks(for domain: String) -> [KnownSignInStore.Mark] { store?.marks(for: domain) ?? [] }

    /// Marks the sign-in; the problem in words, or nil when it was saved.
    func mark(domain: String, account: String, address: String, note: String) -> String? {
        guard store != nil else { return openProblem ?? "The marked sign-ins couldn't be opened." }
        guard !domain.isEmpty else { return "Connect a domain on Setup first." }
        do {
            try store?.mark(domain: domain, account: account, address: address, note: note)
            return nil
        } catch {
            return error.message
        }
    }

    /// Undoes a mark; the problem in words, or nil when it was saved.
    func unmark(_ id: String) -> String? {
        do {
            try store?.unmark(id)
            return nil
        } catch {
            return error.message
        }
    }
}
