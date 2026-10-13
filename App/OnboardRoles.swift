import Foundation
import GamEngine
import Observation
import Stores

/// The roles the Onboard screen offers (slice O1): GamGUI's, read from its own file and never written
/// (`GamGUIRoles`). Read when the screen opens and again on request; what couldn't be read is said, with
/// where roles come from.
@MainActor
@Observable
final class OnboardRoles {
    /// GamGUI's roles file: built at run time from the real folder, or the demo's temporary copy.
    let file: URL
    private(set) var roles: [RoleTemplate] = []
    private(set) var problem: String?
    private(set) var loaded = false

    init(file: URL) {
        self.file = file
    }

    func reload() {
        do {
            roles = try GamGUIRoles.read(file).roles
            problem = roles.isEmpty ? "GamGUI has no onboarding roles yet. Add one in GamGUI's Onboarding \u{2192} Role templates." : nil
        } catch {
            roles = []
            problem = error.message
        }
        loaded = true
    }

    func role(named name: String) -> RoleTemplate? {
        roles.first { $0.name.utf8.elementsEqual(name.utf8) }
    }
}
