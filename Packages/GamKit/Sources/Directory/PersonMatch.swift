import GamEngine

/// Who a spoken or typed name means in the loaded directory. Siri hands the app words, not an account,
/// so a draft starts from the one person they name, or stops to let the operator choose: it never
/// guesses between two.
public enum PersonMatch: Equatable, Sendable {
    case one(GamUser.ID)
    /// More than one person fits; the list shows them, filtered by the words.
    case several([GamUser.ID])
    case none

    /// An address names its account (or an alias of it); otherwise a whole name that only one person
    /// has; otherwise the one person whose name or address contains the words. Never a title,
    /// department or unit: "Finance" isn't a person, even when only one person works there.
    public static func resolve(_ words: String, in users: [GamUser]) -> PersonMatch {
        let wanted = withoutPossessive(PythonText.lower(PythonText.strip(words)))
        guard !wanted.isEmpty else { return .none }
        if wanted.contains("@") {
            let found = users.filter { user in
                ([user.primaryEmail] + user.aliases).contains { PythonText.lower(PythonText.strip($0)) == wanted }
            }
            return match(found)
        }
        let named = users.filter { PythonText.lower($0.fullName) == wanted }
        if !named.isEmpty { return match(named) }
        let needle = Array(wanted.unicodeScalars)
        return match(users.filter { user in
            [user.fullName, user.primaryEmail].contains { UserFilter.contains(Array(PythonText.lower($0).unicodeScalars), needle) }
        })
    }

    /// "Alice's", answering "Who's getting the new title?" as people do: the name without its "'s".
    static func withoutPossessive(_ words: String) -> String {
        for ending in ["'s", "\u{2019}s", "s'", "s\u{2019}"] where words.hasSuffix(ending) && words.count > ending.count {
            return String(words.dropLast(ending.hasPrefix("s") ? 1 : 2))
        }
        return words
    }

    private static func match(_ users: [GamUser]) -> PersonMatch {
        switch users.count {
        case 0: .none
        case 1: .one(users[0].id)
        default: .several(users.map(\.id))
        }
    }
}
