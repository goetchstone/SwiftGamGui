import Foundation
import Observation
import Stores

/// The emails Phishing's Find showed nobody here has, for Incident's log reader to show done: this app's own store
/// (`NobodyHasStore`), and why it didn't open or the last check couldn't be kept. One store for every domain; each check
/// names its own.
@MainActor
@Observable
final class NobodyHasChecks {
    private(set) var store: NobodyHasStore?
    /// Why a check isn't kept: the store didn't open (its file couldn't be read, or moved aside, so nothing is saved over
    /// it), or the last save failed. Nil while checks are kept.
    private(set) var problem: String?

    init(root: URL) {
        do {
            store = try NobodyHasStore(root: root)
        } catch {
            problem = Self.words(error)
        }
    }

    func checks(for domain: String) -> [NobodyHasStore.Check] { store?.checks(for: domain) ?? [] }

    /// Keeps that Find showed nobody on `domain` has these emails.
    func record(domain: String, messageIDs: [String], by: String, at: Date) {
        guard store != nil else { return }
        do {
            try store?.record(domain: domain, messageIDs: messageIDs, by: by, at: at)
            problem = nil
        } catch {
            problem = Self.words(error)
        }
    }

    private static func words(_ problem: SignatureStore.Problem) -> String {
        problem.message.replacingOccurrences(of: "templates", with: "emails Find showed nobody has")
    }
}
