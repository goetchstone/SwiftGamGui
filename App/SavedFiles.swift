import Foundation
import Observation
import Stores
import SwiftUI

/// The files this app saved through a save panel, for Files (plan F4): this app's own list (`SavedFilesStore`), and why it didn't
/// open or the last save couldn't be listed. Each screen that saves a CSV through a save panel lists it here once it's written
/// (`record`), found in the environment, so a screen shown without it (none today) saves all the same and lists nothing.
@MainActor
@Observable
final class SavedFiles {
    private(set) var store: SavedFilesStore?
    /// Why a saved file isn't listed: the list didn't open (its file couldn't be read, or was moved aside, so nothing is saved
    /// over it), or the last save to it failed. Nil while files are listed.
    private(set) var problem: String?
    private let root: URL

    init(root: URL) {
        self.root = root
        reopen()
    }

    /// Opens the list again when it didn't open (Files' ⌘R): a list that opens clears the problem.
    func reopen() {
        guard store == nil else { return }
        do {
            store = try SavedFilesStore(root: root)
            problem = store?.quarantined != nil ? "The list of saved files couldn't be read, so it was set aside and started again." : nil
        } catch {
            problem = Self.words(error)
        }
    }

    var files: [SavedFilesStore.Saved] { store?.files ?? [] }

    /// Lists `url`, just saved as `what`.
    func record(_ url: URL, what: String) {
        guard store != nil else { return }
        do {
            try store?.record(url, what: what)
            problem = nil
        } catch {
            problem = Self.words(error)
        }
    }

    private static func words(_ problem: SignatureStore.Problem) -> String {
        problem.message.replacingOccurrences(of: "templates", with: "list of saved files")
    }
}
