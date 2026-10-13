import Foundation
import GamEngine
import Observation
import Stores

/// The saved offboarding templates, for the Offboard screen: the store (`OffboardTemplateStore`) and what
/// opening it found. One store for every domain, as the signature templates are.
@MainActor
@Observable
final class OffboardTemplates {
    private(set) var store: OffboardTemplateStore?
    /// Why the store didn't open (its file couldn't be read, or moved aside): nothing can be saved, so nothing
    /// is saved over it.
    let openProblem: String?

    init(root: URL) {
        do {
            store = try OffboardTemplateStore(root: root)
            openProblem = nil
        } catch {
            openProblem = error.message
        }
    }

    var names: [String] { store?.names ?? [] }
    var defaultName: String? { store?.defaultName }
    /// Where opening moved an unreadable file, for the screen to say.
    var quarantined: URL? { store?.quarantined }
    func template(_ name: String) -> Offboarding.Template? { store?.template(name) }

    /// The first template that is exactly `template`, for a form filled some other way.
    func name(of template: Offboarding.Template) -> String? { names.first { self.template($0) == template } }

    /// The name it was saved under (stripped). Throws the store's problem: `.exists` when the name is saved and
    /// `replacing` is false, so the screen asks.
    func save(_ name: String, _ template: Offboarding.Template, replacing: Bool) throws(OffboardTemplateStore.Problem) -> String? {
        try store?.save(name, template, replacing: replacing)
    }

    func delete(_ name: String) throws(OffboardTemplateStore.Problem) {
        try store?.delete(name)
    }

    func setDefault(_ name: String?) throws(OffboardTemplateStore.Problem) {
        try store?.setDefault(name)
    }
}
