import Foundation
import Observation
import Stores

/// The saved signature templates, for the Signatures screen: the store (`SignatureStore`, design doc D2),
/// what opening it found, and where GamGUI's templates are when they can be copied. One store for every
/// domain, as in GamGUI.
@MainActor
@Observable
final class SignatureTemplates {
    private(set) var store: SignatureStore?
    /// Why the store didn't open (its file couldn't be read, or moved aside): nothing can be saved, so
    /// nothing is saved over it.
    let openProblem: String?
    /// GamGUI's templates file, when copying it can be offered: never in demo mode.
    private let gamGUIFile: URL?

    init(root: URL, gamGUIFile: URL?) {
        self.gamGUIFile = gamGUIFile
        do {
            store = try SignatureStore(root: root)
            openProblem = nil
        } catch let problem as SignatureStore.Problem {
            openProblem = problem.message
        } catch {
            openProblem = "The saved templates couldn't be opened (\(error))."
        }
    }

    var names: [String] { store?.names ?? [] }
    func body(_ name: String) -> String? { store?.body(name) }
    /// Where opening moved an unreadable file, for the screen to say.
    var quarantined: URL? { store?.quarantined }

    /// GamGUI has a templates file to copy: only offered outside demo mode. A check for the screen; the
    /// copy itself reads the file by descriptor.
    var canCopyFromGamGUI: Bool {
        gamGUIFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Throws the store's problem: `.exists` when the name is saved and `replacing` is false, so the screen
    /// asks first.
    func save(_ name: String, body: String, replacing: Bool) throws {
        try store?.save(name, body: body, replacing: replacing)
    }

    func delete(_ name: String) throws {
        try store?.delete(name)
    }

    func copyFromGamGUI() throws -> SignatureStore.CopyReport {
        guard let gamGUIFile, store != nil else { throw SignatureStore.Problem.noGamGUITemplates }
        return try store!.copy(fromGamGUI: gamGUIFile)
    }
}
