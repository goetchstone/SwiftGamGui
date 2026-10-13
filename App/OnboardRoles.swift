import Foundation
import GamEngine
import Observation
import Stores

/// The onboarding roles, for the Onboard screen and its role editor: this app's own store (`RoleStore`), what
/// opening it found, and where GamGUI's roles are when they can be copied once. One store for every domain, as
/// in GamGUI.
@MainActor
@Observable
final class OnboardRoles {
    private(set) var store: RoleStore?
    /// Why the store didn't open (its file couldn't be read, or moved aside): nothing can be saved, so nothing is
    /// saved over it.
    let openProblem: String?
    /// GamGUI's roles file, when copying it can be offered: never in demo mode.
    private let gamGUIFile: URL?

    init(root: URL, gamGUIFile: URL?) {
        self.gamGUIFile = gamGUIFile
        do {
            store = try RoleStore(root: root)
            openProblem = nil
        } catch {
            openProblem = error.message
        }
    }

    var roles: [RoleTemplate] { store?.roles ?? [] }
    var welcomeNames: [String] { store?.welcomeNames ?? [Onboarding.defaultWelcome] }
    /// Where opening moved an unreadable file, for the editor to say.
    var quarantined: URL? { store?.quarantined }

    func role(named name: String) -> RoleTemplate? { store?.role(name) }

    /// The roles naming `template` as their signature: what deleting it on Signatures would leave without one.
    func roles(usingSignature template: String) -> [String] { store?.roles(usingSignature: template) ?? [] }

    /// GamGUI has a roles file to copy: only offered outside demo mode. A check for the editor; the copy itself reads
    /// the file by descriptor.
    var canCopyFromGamGUI: Bool {
        gamGUIFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// What was saved. Throws the store's problem: `.exists` when the name is saved and `replacing` is false, so the
    /// editor asks.
    @discardableResult
    func save(_ role: RoleTemplate, replacing: Bool, renaming previous: String?) throws(RoleStore.Problem) -> RoleTemplate? {
        try store?.save(role, replacing: replacing, renaming: previous)
    }

    func delete(_ name: String) throws(RoleStore.Problem) {
        try store?.delete(name)
    }

    func copyFromGamGUI() throws(RoleStore.Problem) -> RoleStore.CopyReport? {
        guard let gamGUIFile else { return nil }
        return try store?.copy(fromGamGUI: gamGUIFile)
    }

    #if DEBUG
    /// Debug builds' demo only: the demo's roles (GamGUI's format, `Tests/Fixtures/demo/onboarding.json`) saved into
    /// this store, a fresh temporary folder, as they'd be typed into the editor.
    func seedForDemo(from file: URL) {
        guard let demo = try? GamGUIRoles.read(file) else { return }
        for (name, email) in demo.welcomes { _ = try? store?.saveWelcome(email, as: name) }
        for role in demo.roles { _ = try? store?.save(role, replacing: true) }
    }
    #endif
}
