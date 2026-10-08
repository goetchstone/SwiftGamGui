import Foundation
import Testing
@testable import GamEngine
import TestSupport

/// GamGUI parity for reading records into users, groups and members (invariant 11): every record in
/// `Tests/Fixtures/gam_models.json`, generated from frozen GamGUI's models, gives the same fields.
@Suite("Directory models")
struct DirectoryTests {
    struct Fixture<Model: Decodable>: Decodable {
        let record: JSONText
        let model: Model
    }

    /// A record as the fixture holds it, read back through `JSONValue` (the fixture's JSON is plain).
    struct JSONText: Decodable {
        let value: GamOutput.Record

        init(from decoder: Decoder) throws {
            let object = try decoder.singleValueContainer().decode(AnyJSON.self)
            guard case .object(let record) = object.value else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not an object")) }
            value = record
        }
    }

    struct AnyJSON: Decodable {
        let value: JSONValue

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { value = .null }
            else if let flag = try? container.decode(Bool.self) { value = .bool(flag) }
            else if let number = try? container.decode(Int.self) { value = .number(String(number)) }
            else if let number = try? container.decode(Double.self) { value = .number(String(number)) }
            else if let text = try? container.decode(String.self) { value = .string(text) }
            else if let items = try? container.decode([AnyJSON].self) { value = .array(items.map(\.value)) }
            else { value = .object(try container.decode([String: AnyJSON].self).mapValues(\.value)) }
        }
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

    struct Document: Decodable {
        let users: [Fixture<User>]
        let groups: [Fixture<Group>]
        let members: [Fixture<Member>]
    }

    let document = try! JSONDecoder().decode(Document.self, from: Data(contentsOf: Fixtures.gamModelsJSON))

    static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    @Test func usersReadAsGamGUIReadsThem() {
        for item in document.users {
            let user = GamUser(record: item.record.value), want = item.model
            let label = "\(item.record.value)"
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

    @Test func groupsAndMembersReadAsGamGUIReadsThem() {
        for item in document.groups {
            let group = GamGroup(record: item.record.value), want = item.model
            #expect(Self.same(group.email, want.email) && Self.same(group.name, want.name)
                    && Self.same(group.description, want.description), "\(item.record.value)")
            #expect(group.membersCount == want.members_count, "count \(item.record.value)")
        }
        for item in document.members {
            let member = GroupMember(record: item.record.value), want = item.model
            #expect(Self.same(member.email, want.email) && Self.same(member.role, want.role)
                    && Self.same(member.memberType, want.member_type) && Self.same(member.status, want.status),
                    "\(item.record.value)")
        }
        #expect(document.groups.count > 100 && document.members.count > 100)
    }
}
