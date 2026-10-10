import Foundation
import Observation

/// What Siri asked for, handed to the screens. Siri only drafts (invariant 10): the Users screen turns a
/// request into a preview the operator checks and saves; the voice side never reaches a write.
@MainActor
@Observable
final class SiriDrafts {
    /// "Change a title": who, as said or typed, and the new title (and department, when one was given).
    struct TitleChange: Equatable, Identifiable {
        let id = UUID()
        let person: String
        let title: String
        let department: String?
        let made = ContinuousClock.now

        /// A request left waiting (no domain connected, the directory never loaded) isn't drafted long
        /// after it was asked for.
        var isStale: Bool { ContinuousClock.now - made > .seconds(600) }
    }

    var titleChange: TitleChange?
}
