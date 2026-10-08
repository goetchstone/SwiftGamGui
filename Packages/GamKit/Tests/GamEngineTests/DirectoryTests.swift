import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for reading records into users, groups and members (invariant 11): every record in
/// `Tests/Fixtures/gam_models.json`, generated from frozen GamGUI's models, gives the same fields.
@Suite("Directory models")
struct DirectoryTests {
    struct Fixture<Model: Decodable>: Decodable {
        /// The record as JSON text, read here through `JSONValue`: a number keeps the form it was
        /// written in (`1.50`, `1E2`), which is what Python's `str()` of it depends on.
        let record: String
        let model: Model

        var value: GamOutput.Record { JSONValue.parse(record)?.object ?? [:] }
    }

    struct User: Decodable {
        let primary_email: String, given_name: String, family_name: String, suspended: Bool, org_unit_path: String
        let is_admin: Bool, is_delegated_admin: Bool, enrolled_2sv: Bool, title: String, department: String
        let location: String, phone: String, recovery_email: String, last_login_time: String?, aliases: [String]
        let full_name: String
    }

    struct Group: Decodable {
        let email: String, name: String, description: String, members_count: Int?
    }

    struct Member: Decodable {
        let email: String, role: String, member_type: String, status: String
    }

    struct Constants: Decodable {
        let PY_UPPER: [[JSONNumber]]
    }

    /// A code point, or a list of them.
    enum JSONNumber: Decodable {
        case one(UInt32), many([UInt32])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let point = try? container.decode(UInt32.self) { self = .one(point) } else { self = .many(try container.decode([UInt32].self)) }
        }
    }

    struct Document: Decodable {
        let constants: Constants
        let users: [Fixture<User>]
        let groups: [Fixture<Group>]
        let members: [Fixture<Member>]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.gamModelsJSON))

    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    @Test func usersReadAsGamGUIReadsThem() {
        for item in document.users {
            let user = GamUser(record: item.value), want = item.model
            let label = "\(item.value)"
            #expect(Self.same(user.primaryEmail, want.primary_email), "email \(label)")
            #expect(Self.same(user.givenName, want.given_name) && Self.same(user.familyName, want.family_name), "name \(label)")
            #expect(Self.same(user.fullName, want.full_name), "full name \(label)")
            #expect(user.suspended == want.suspended && user.isAdmin == want.is_admin, "flags \(label)")
            #expect(user.isDelegatedAdmin == want.is_delegated_admin && user.isEnrolledIn2SV == want.enrolled_2sv, "flags \(label)")
            #expect(Self.same(user.orgUnitPath, want.org_unit_path), "org unit \(label)")
            #expect(Self.same(user.title, want.title) && Self.same(user.department, want.department), "organization \(label)")
            #expect(Self.same(user.location, want.location) && Self.same(user.phone, want.phone), "location \(label)")
            #expect(Self.same(user.recoveryEmail, want.recovery_email), "recovery \(label)")
            #expect((user.lastLoginTime == nil) == (want.last_login_time == nil)
                    && Self.same(user.lastLoginTime ?? "", want.last_login_time ?? ""), "last login \(label)")
            #expect(user.aliases.map { Array($0.utf8) } == want.aliases.map { Array($0.utf8) }, "aliases \(label)")
        }
        #expect(document.users.count > 200)
    }

    /// `str.upper()` scalar by scalar over every code point, Swift-only assignments included (PR #7's
    /// review: Unicode 17 gave U+A7D3 an uppercase that Python's 16 doesn't have).
    @Test func uppercaseIsPythons() {
        var table: [UInt32: [UInt32]] = [:]
        for pair in document.constants.PY_UPPER {
            if case .one(let point) = pair[0], case .many(let mapped) = pair[1] { table[point] = mapped }
        }
        #expect(table.count > 1400)
        var mismatches: [UInt32] = []
        for point in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(point) else { continue }
            let mine = PythonText.upper(String(scalar)).unicodeScalars.map(\.value)
            if mine != (table[point] ?? [point]) { mismatches.append(point) }
        }
        #expect(mismatches.isEmpty, "differs at \(mismatches.prefix(10).map { String($0, radix: 16) })")
    }

    @Test func groupsAndMembersReadAsGamGUIReadsThem() {
        for item in document.groups {
            let group = GamGroup(record: item.value), want = item.model
            #expect(Self.same(group.email, want.email) && Self.same(group.name, want.name)
                    && Self.same(group.description, want.description), "\(item.value)")
            #expect(group.membersCount == want.members_count, "count \(item.value)")
        }
        for item in document.members {
            let member = GroupMember(record: item.value), want = item.model
            #expect(Self.same(member.email, want.email) && Self.same(member.role, want.role)
                    && Self.same(member.memberType, want.member_type) && Self.same(member.status, want.status),
                    "\(item.value)")
        }
        #expect(document.groups.count > 100 && document.members.count > 100)
    }
}
