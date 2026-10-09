@testable import Directory
import GamEngine
import Testing

@Suite("User filter")
struct UserFilterTests {
    func user(_ email: String, suspended: Bool = false, title: String = "", department: String = "", ou: String = "/") -> GamUser {
        GamUser(record: [
            "primaryEmail": .string(email), "suspended": .bool(suspended), "orgUnitPath": .string(ou),
            "name": .object(["givenName": .string(email.split(separator: "@").first.map(String.init)?.capitalized ?? ""),
                             "familyName": .string("Example")]),
            "organizations": .array([.object(["title": .string(title), "department": .string(department), "primary": .bool(true)])]),
        ])
    }

    @Test func theScopeAndTheSearchNarrowAsGamGUIs() {
        let users = [user("alice@example.com", title: "IT Director", department: "IT", ou: "/Staff"),
                     user("bob@example.com", suspended: true, department: "Sales"),
                     user("carol@example.com", ou: "/Contractors")]
        let emails = { (filter: UserFilter) in filter.apply(users).map(\.primaryEmail) }
        #expect(emails(UserFilter()) == users.map(\.primaryEmail))
        #expect(emails(UserFilter(scope: .active)) == ["alice@example.com", "carol@example.com"])
        #expect(emails(UserFilter(scope: .suspended)) == ["bob@example.com"])
        #expect(emails(UserFilter(query: "  DIRECTOR ")) == ["alice@example.com"], "title, any case, trimmed")
        #expect(emails(UserFilter(query: "sales")) == ["bob@example.com"], "department")
        #expect(emails(UserFilter(query: "/contr")) == ["carol@example.com"], "organizational unit")
        #expect(emails(UserFilter(query: "bob example")) == ["bob@example.com"], "the full name")
        #expect(emails(UserFilter(scope: .active, query: "sales")).isEmpty)
    }
}
