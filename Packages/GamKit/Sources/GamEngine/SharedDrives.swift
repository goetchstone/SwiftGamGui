import Foundation

/// Shared drives (GamGUI's `core/shared_drives.py`, roadmap 4.7): a drive's members, and one change to them at a time.
///
/// A drive's members are users and groups. Drive's role names and the words its screen shows: organizer "Manager",
/// fileOrganizer "Content manager", writer "Contributor", commenter "Commenter", reader "Viewer". A drive is never left without a
/// manager here: removing or demoting its last one is refused. A read that failed or came back without the drive is unknown,
/// never "no members".
public enum SharedDrives {
    /// Drive's role → GAM's word for it, most access first.
    public static let gamWord: [(drive: String, word: String)] = [("organizer", "organizer"), ("fileOrganizer", "fileorganizer"),
                                                                 ("writer", "writer"), ("commenter", "commenter"), ("reader", "reader")]
    public static let labels: [String: String] = ["organizer": "Manager", "fileOrganizer": "Content manager", "writer": "Contributor",
                                                  "commenter": "Commenter", "reader": "Viewer"]
    /// (GAM word, label), most access first.
    public static var roleChoices: [(word: String, label: String)] { gamWord.map { ($0.word, labels[$0.drive]!) } }
    public static let memberTypes = ["user", "group"]
    public static let lastManager = "{who} is {drive}'s only manager. A shared drive with none can only be looked after from the Admin console, so add another manager first."

    public static func label(_ role: String) -> String { labels[role] ?? (role.isEmpty ? "unknown role" : role) }
    static func driveRole(_ word: String) -> String? { gamWord.first { $0.word == word }?.drive }

    /// A shared drive's or a permission's ID as Drive makes them: letters, digits, `-` and `_`, at most 200.
    public static func isItemID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 200
            && value.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_" }
    }

    public struct Drive: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public init?(record: GamOutput.Record) {
            let id = PythonText.strip(record["id"]?.string ?? "")
            guard isItemID(id) else { return nil }
            self.id = id
            name = PythonText.strip(record["name"]?.string ?? "")
        }
        public init(id: String, name: String) { (self.id, self.name) = (id, name) }
    }

    public struct Member: Sendable, Hashable, Identifiable {
        /// The permission's ID: what a change names.
        public let id: String
        public let kind: String
        public let role: String
        public let email: String
        public let name: String
        public let deleted: Bool
        public var who: String { !email.isEmpty ? email : !name.isEmpty ? name : "permission \(id)" }
        /// A manager who counts: an organizer whose account is still there.
        public var manages: Bool { role == "organizer" && !deleted }

        init?(permission: JSONObject) {
            let id = PythonText.strip(permission["id"]?.string ?? "")
            guard isItemID(id) else { return nil }
            self.id = id
            kind = permission["type"]?.string ?? ""
            role = permission["role"]?.string ?? ""
            email = PythonText.strip(permission["emailAddress"]?.string ?? "")
            name = PythonText.strip(permission["displayName"]?.string ?? "")
            deleted = permission["deleted"] == .bool(true)
        }
    }

    public struct Unread: Error, Sendable { public let reason: String }

    /// GamGUI's `members_from`: exactly one row, for that drive, holding its permissions; anything else is unknown.
    public static func members(_ records: [GamOutput.Record], driveID: String) throws(Unread) -> [Member] {
        let rows = records.filter { $0["id"]?.string == driveID }
        guard rows.count == 1, records.count == 1 else {
            throw Unread(reason: "GAM answered without the drive's members, so who has access can't be told.")
        }
        guard let permissions = rows[0]["permissions"]?.array else {
            throw Unread(reason: "GAM's answer left the drive's members out, so who has access can't be told.")
        }
        var members: [Member] = []
        for permission in permissions {
            guard let object = permission.object, let member = Member(permission: object) else {
                throw Unread(reason: "GAM listed a member of the drive without its permission ID, so it couldn't be named.")
            }
            members.append(member)
        }
        let order = Dictionary(uniqueKeysWithValues: gamWord.enumerated().map { ($0.element.drive, $0.offset) })
        return members.sorted { a, b in
            let x = order[a.role] ?? 9, y = order[b.role] ?? 9
            return x != y ? x < y : PythonText.lower(a.who).unicodeScalars.lexicographicallyPrecedes(PythonText.lower(b.who).unicodeScalars)
        }
    }

    public enum Action: String, Sendable { case add, role, remove }

    /// One change to one drive's members, as its preview showed it.
    public struct Change: Sendable, Equatable {
        public let driveID: String
        public let driveName: String
        public let action: Action
        public let who: String
        /// GAM's word for the role it gets (add, role).
        public let role: String
        /// add: user or group.
        public let kind: String
        /// role, remove: the permission's ID, and the role as read (Drive's name).
        public let memberID: String
        public let was: String

        public func write() throws -> GamWrite {
            switch action {
            case .add: try GamCommands.addDriveMember(driveID: driveID, kind: kind, email: who, role: role)
            case .role: try GamCommands.setDriveMemberRole(driveID: driveID, permissionID: memberID, role: role)
            case .remove: try GamCommands.removeDriveMember(driveID: driveID, permissionID: memberID)
            }
        }

        public var newLabel: String { driveRole(role).map(label) ?? "" }
        var drive: String { driveName.isEmpty ? driveID : driveName }
        public var words: String {
            switch action {
            case .add: "add \(who) to \(drive) as \(newLabel)"
            case .role: "change \(who) on \(drive) from \(label(was)) to \(newLabel)"
            case .remove: "remove \(who) (\(label(was))) from \(drive)"
            }
        }
        public var question: String { words.prefix(1).uppercased() + words.dropFirst() + "?" }
        public var done: String {
            switch action {
            case .add: "Added \(who) to \(drive) as \(newLabel)."
            case .role: "\(who) is now \(newLabel) on \(drive)."
            case .remove: "Removed \(who) from \(drive)."
            }
        }
    }

    private static func isLastManager(_ member: Member, _ members: [Member]) -> Bool {
        member.manages && members.count(where: \.manages) == 1
    }

    private static func lastManagerWords(_ who: String, _ drive: Drive) -> String {
        lastManager.replacingOccurrences(of: "{who}", with: who).replacingOccurrences(of: "{drive}", with: drive.name.isEmpty ? drive.id : drive.name)
    }

    /// GamGUI's `plan`: a change the members just read allow, or why not.
    public static func plan(_ members: [Member], drive: Drive, action: Action, email: String = "", kind: String = "",
                            role: String = "", memberID: String = "") -> Result<Change, Unread> {
        let name = drive.name.isEmpty ? drive.id : drive.name
        switch action {
        case .add:
            let email = PythonText.strip(email)
            guard GamCommands.isOneAddress(email) else { return .failure(Unread(reason: "Enter one full email address: a bare name or a list isn't one member.")) }
            guard memberTypes.contains(kind) else { return .failure(Unread(reason: "Pick whether it's a person or a group.")) }
            guard driveRole(role) != nil else { return .failure(Unread(reason: "Pick a role.")) }
            if let there = members.first(where: { PythonText.lower($0.email) == PythonText.lower(email) }) {
                return .failure(Unread(reason: "\(there.who) is already on \(name) as \(label(there.role)): change their role instead."))
            }
            return .success(Change(driveID: drive.id, driveName: drive.name, action: .add, who: email, role: role, kind: kind, memberID: "", was: ""))
        case .role, .remove:
            guard let member = members.first(where: { $0.id == memberID }) else {
                return .failure(Unread(reason: "That member isn't on \(name) any more. The list below is as it is now."))
            }
            if action == .role {
                guard let new = driveRole(role) else { return .failure(Unread(reason: "Pick a role.")) }
                if new == member.role { return .failure(Unread(reason: "\(member.who) is already \(label(member.role)) on \(name).")) }
            }
            if isLastManager(member, members) { return .failure(Unread(reason: lastManagerWords(member.who, drive))) }
            return .success(Change(driveID: drive.id, driveName: drive.name, action: action, who: member.who,
                                   role: action == .role ? role : "", kind: "", memberID: member.id, was: member.role))
        }
    }

    /// GamGUI's `moved`: why `change` no longer fits the members read again just before it runs, or nil.
    public static func moved(_ change: Change, members: [Member]) -> String? {
        let name = change.driveName.isEmpty ? change.driveID : change.driveName
        if change.action == .add {
            return members.contains { PythonText.lower($0.email) == PythonText.lower(change.who) } ? "\(change.who) was added to \(name) since the preview." : nil
        }
        guard let member = members.first(where: { $0.id == change.memberID }) else { return "\(change.who) isn't on \(name) any more." }
        if member.role != change.was { return "\(change.who)'s role on \(name) changed since the preview, to \(label(member.role))." }
        if isLastManager(member, members) {
            return lastManagerWords(change.who, Drive(id: change.driveID, name: change.driveName))
        }
        return nil
    }

    /// GamGUI's `SHARED_DRIVE_FILE_FIELDS`.
    public static let fileFields = ["id", "name", "mimeType", "modifiedTime", "lastModifyingUser", "webViewLink"]
}
