@testable import Directory
import GamEngine
import Testing

@Suite("Person match")
struct PersonMatchTests {
    func user(_ email: String, _ given: String, _ family: String, aliases: [String] = []) -> GamUser {
        GamUser(record: [
            "primaryEmail": .string(email),
            "name": .object(["givenName": .string(given), "familyName": .string(family)]),
            "aliases": .array(aliases.map { .string($0) }),
        ])
    }

    var users: [GamUser] {
        [user("alice@example.com", "Alice", "Anders", aliases: ["a.anders@example.com"]),
         user("alex@example.com", "Alex", "Kim"),
         user("alex.k@example.com", "Alex", "Kim"),
         user("bob@example.com", "Bob", "Brown")]
    }

    @Test func anAddressOrAnAliasNamesItsAccount() {
        #expect(PersonMatch.resolve(" Alice@Example.com ", in: users) == .one("alice@example.com"))
        #expect(PersonMatch.resolve("a.anders@example.com", in: users) == .one("alice@example.com"))
        #expect(PersonMatch.resolve("nobody@example.com", in: users) == .none)
        #expect(PersonMatch.resolve("alice@example", in: users) == .none, "an address must match whole")
    }

    @Test func aWholeNameOnlyOnePersonHas() {
        #expect(PersonMatch.resolve("alice anders", in: users) == .one("alice@example.com"))
        #expect(PersonMatch.resolve("Bob Brown", in: users) == .one("bob@example.com"))
    }

    @Test func twoPeopleWithTheNameAreNeverGuessedBetween() {
        #expect(PersonMatch.resolve("Alex Kim", in: users) == .several(["alex@example.com", "alex.k@example.com"]))
        #expect(PersonMatch.resolve("alex", in: users) == .several(["alex@example.com", "alex.k@example.com"]))
    }

    @Test func partOfANameFindsOnlyWhenItFindsOne() {
        #expect(PersonMatch.resolve("anders", in: users) == .one("alice@example.com"))
        #expect(PersonMatch.resolve("zed", in: users) == .none)
        #expect(PersonMatch.resolve("   ", in: users) == .none)
    }
}
