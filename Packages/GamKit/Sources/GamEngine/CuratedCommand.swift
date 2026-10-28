/// GamGUI's curated Builder commands (`core/catalog/catalog.py::_curated`): typed fields and the builder GamGUI's calls, held to it
/// by `Tests/Fixtures/catalog_curated.json` (`CuratedCommandTests`): the same fields, and the same argv from the same values. A read
/// runs from the Builder as a promoted one does; a write is only ever a `GamWrite`, which runs through ChangeCore's preview and
/// confirm (`BuilderChanges`), never from here.
///
/// Two of GamGUI's 26 run from another screen instead (`elsewhere`). Deliberate differences from GamGUI's form
/// (`routes/builder.py::_assemble`), each where GAM would otherwise do something the operator didn't type: a person, group or
/// address field must hold one address GAM acts on as given (`GamCommands.isOneAddress`: GAM reads a bare name, `oauthuser` or a
/// list as someone else, and rewrites `uid:a@b` or `Name <a@b>` to `a@b`, so a refusal comparing addresses would miss it); an
/// undeleted account may be named `uid:<digits>` instead, GAM's own remedy when deleted accounts share an address; an empty
/// choice is its default (the form's picker starts there); a choice GamGUI doesn't list is refused; and a search doesn't show
/// message bodies (`notYet`) until a read can be audited, as the Builder's other sensitive reads wait.
public struct CuratedCommand: Sendable, Identifiable {
    /// One field of the command's form (GamGUI's `CommandSlot`).
    public struct Field: Sendable, Hashable, Identifiable {
        /// GamGUI's `SlotKind`.
        public enum Kind: String, Sendable, Hashable {
            /// The person the command is about.
            case targetUser = "target_user"
            case user, group, email, text, choice

            /// A person, a group or a typed address: one email address.
            public var isAddress: Bool { self != .text && self != .choice }
            /// A person or a group, whose address names what the change is for.
            var isSomeone: Bool { self == .targetUser || self == .user || self == .group }
        }

        public let key: String
        public let label: String
        public let kind: Kind
        public let required: Bool
        /// A choice's values, in GamGUI's order.
        public let choices: [String]
        public let defaultValue: String
        public let placeholder: String
        /// Words a text field offers to insert (GamGUI's click-to-insert chips), and a line about them.
        public let hints: [String]
        public let hintNote: String
        /// An account may be named by its unique ID (`uid:<digits>`) as well as its address (undelete only, not GamGUI's).
        public let takesUniqueID: Bool
        public var id: String { key }
    }

    /// What a command's values make: a read the Builder runs, or a write only ChangeCore runs.
    public enum Built: Sendable {
        case read(GamRead)
        case write(GamWrite)
    }

    public let id: String
    public let category: String
    public let subcategory: String
    public let name: String
    /// GamGUI's line for it, as the Builder shows it.
    public let syntax: String
    public let description: String
    /// GamGUI's, raised to ChangeCore's floor for its write (`WriteAction.minimumRisk`): a random password reset and an alias
    /// removed are destructive here, as on every other screen (`CuratedCommandTests` holds both halves).
    public let risk: CommandCatalog.Risk
    public let fields: [Field]
    /// GamGUI's `build` lambda, given each value as the form leaves it (trimmed, a choice's default for an empty one).
    let build: @Sendable (_ value: (String) -> String) throws -> Built

    /// The short grouping the list is shown in, as a catalog command's.
    public var area: String { CommandCatalog.area(of: category) }
    public var reads: Bool { risk == .read }

    /// The command `values` (by field key) make, refused in words when one is missing or isn't what the field takes.
    public func built(_ values: [String: String]) throws(GamCommands.Invalid) -> Built {
        let value = formValue(values)
        for field in fields {
            let text = value(field.key)
            if field.required, text.isEmpty { throw .argument("Fill in \(field.label)") }
            if field.kind.isAddress, !text.isEmpty, !GamCommands.isOneAddress(text), !(field.takesUniqueID && Self.isUniqueID(text)) {
                throw .argument("“\(text)” isn't one plain email address: enter the full address for \(field.label), like name@example.com"
                    + (field.takesUniqueID ? ", or the account's uid:<number>" : ""))
            }
            if field.kind == .choice, !field.choices.contains(text) {
                throw .argument("\(field.label) can't be “\(text)”: pick one of " + field.choices.joined(separator: ", "))
            }
            if let why = Self.notYet[id]?[field.key]?[text] { throw .argument(why) }
        }
        do {
            return try build(value)
        } catch let invalid as GamCommands.Invalid {
            throw invalid
        } catch {
            throw .argument(String(describing: error))
        }
    }

    /// Whom the change is for, as the guard and the audit name it: GamGUI's first person or group given (`_assemble`), else (a
    /// difference, so a new group or an undeleted account is named) the first address, else GamGUI's "(command)".
    public func target(_ values: [String: String]) -> String {
        let value = formValue(values)
        let named = fields.filter(\.kind.isSomeone) + fields.filter { $0.kind == .email }
        return named.lazy.map { value($0.key) }.first { !$0.isEmpty } ?? "(command)"
    }

    /// `uid:` and an account's unique ID, digits only, as GAM's `convertUIDtoEmailAddress` takes it.
    static func isUniqueID(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > 4, String(String.UnicodeScalarView(scalars[..<4])) == "uid:" else { return false }
        return scalars[4...].allSatisfy { ("0"..."9").contains($0) }
    }

    /// A value as the form leaves it: trimmed as Python's `strip()`, and a choice left empty at its default.
    private func formValue(_ values: [String: String]) -> (String) -> String {
        let defaults = Dictionary(fields.filter { $0.kind == .choice }.map { ($0.key, $0.defaultValue) }, uniquingKeysWith: { a, _ in a })
        return { key in
            let text = PythonText.strip(values[key] ?? "")
            return text.isEmpty ? defaults[key] ?? "" : text
        }
    }
}

extension CuratedCommand {
    /// GamGUI's curated commands this app runs from another screen, and why.
    public static let elsewhere: [String: String] = [
        "build.set_signature": "A signature is set on Signatures, which keeps the one it replaces so it can be put back.",
        "build.delete_user": "An account is deleted by offboarding's Close Out, with the checks a delete needs: an alias of another "
            + "account, a Drive transfer not finished.",
    ]

    /// Choices GamGUI's form offers that don't run here yet, by command and field, and why.
    public static let notYet: [String: [String: [String: String]]] = [
        "build.search_messages": ["detail": [GamCommands.MessageDetail.headersAndBody.rawValue:
            "Showing message bodies waits until a read can be audited, as the Builder's other sensitive reads do: pick Headers or Summary"]],
    ]

    /// GamGUI's curated commands, in its order, but for `elsewhere`.
    public static let all: [CuratedCommand] = {
        let delegates = "Gmail - Delegates", forwarding = "Gmail - Forwarding", vacation = "Gmail - Vacation"
        return [
            CuratedCommand("build.add_delegate", "Users", delegates, "Add mailbox delegate", .change,
                           [person(), field("delegate", "Delegate", .email)],
                           "gam user <email> add delegate <delegate>",
                           "Let another person read and send mail from this user's mailbox.") { v in
                .write(GamCommands.addDelegate(email: v("email"), delegate: v("delegate")))
            },
            CuratedCommand("build.remove_delegate", "Users", delegates, "Remove mailbox delegate", .change,
                           [person(), field("delegate", "Delegate", .email)],
                           "gam user <email> delete delegate <delegate>",
                           "Revoke a delegate's access to this user's mailbox.") { v in
                .write(GamCommands.removeDelegate(email: v("email"), delegate: v("delegate")))
            },
            // Sent as the user page's form sends it: HTML built from the text, so its line breaks hold and a typed '<' or '&' is
            // text, not markup.
            CuratedCommand("build.set_vacation", "Users", vacation, "Set vacation auto-reply", .change,
                           [person(), field("subject", "Subject", .text), field("message", "Message", .text)],
                           "gam user <email> vacation on subject <s> message <m> html contactsonly false domainonly false "
                               + "start Started end NotSpecified",
                           "Turn on the user's vacation auto-responder with a subject and message, for every sender and no end date "
                               + "(GAM would otherwise keep any earlier restriction or date).") { v in
                .write(GamCommands.setVacation(email: v("email"), subject: v("subject"), message: HTMLText.autoreplyHTML(v("message")),
                                               html: true))
            },
            CuratedCommand("build.vacation_off", "Users", vacation, "Turn off vacation auto-reply", .change, [person()],
                           "gam user <email> vacation off", "Switch off the user's vacation auto-responder.") { v in
                .write(GamCommands.vacationOff(email: v("email")))
            },
            CuratedCommand("build.print_delegates", "Users", delegates, "List mailbox delegates", .read, [person()],
                           "gam user <email> print delegates", "Show everyone who has delegate access to this user's mailbox.") { v in
                .read(GamCommands.printDelegates(email: v("email")))
            },
            CuratedCommand("build.add_forwarding_address", "Users", forwarding, "Add a forwarding address", .change,
                           [person(), field("address", "Forward to", .email)],
                           "gam user <email> add forwardingaddress <address>",
                           "Register an address the user is allowed to forward mail to (does not enable forwarding).") { v in
                .write(GamCommands.addForwardingAddress(email: v("email"), address: v("address")))
            },
            CuratedCommand("build.set_forward", "Users", forwarding, "Turn on forwarding", .change,
                           [person(), field("address", "Forward to", .email),
                            field("action", "Keep original as", .choice, choices: GamCommands.ForwardAction.allCases.map(\.rawValue),
                                  default: GamCommands.ForwardAction.keep.rawValue)],
                           "gam user <email> forward on <action> <address>",
                           "Auto-forward the user's incoming mail to an address, choosing what to do with the original.") { v in
                .write(GamCommands.setForward(email: v("email"), address: v("address"),
                                              action: try GamCommands.ForwardAction(validating: v("action"))))
            },
            CuratedCommand("build.forward_off", "Users", forwarding, "Turn off forwarding", .change, [person()],
                           "gam user <email> forward off", "Stop auto-forwarding the user's incoming mail.") { v in
                .write(GamCommands.forwardOff(email: v("email")))
            },
            CuratedCommand("build.search_messages", "Users", "Gmail - Messages", "Search a mailbox", .read,
                           [person(),
                            field("query", "Gmail search", .text,
                                  placeholder: "rfc822msgid:<id>  ·  from:… after:2026/06/23 before:2026/06/24",
                                  hints: ["rfc822msgid:", "from:", "to:", "subject:", "after:2026/06/23", "before:2026/06/25",
                                          "newer_than:7d", "older_than:30d", "has:attachment", "is:unread", "in:anywhere", "label:"],
                                  hintNote: "Click a chip to insert it. Dates are YYYY/MM/DD; combine terms freely (any Gmail search "
                                      + "operator works). rfc822msgid: matches the Message-ID."),
                            field("detail", "Show", .choice, choices: GamCommands.MessageDetail.allCases.map(\.rawValue),
                                  default: GamCommands.MessageDetail.headers.rawValue)],
                           "gam user <email> print messages query <q> headers all",
                           "Find messages in a mailbox by Gmail search (Message-ID, sender, subject, date) and show their full headers "
                               + "— incl. Return-Path / Received, so an envelope or bounce sender is visible. Capped at 50 results; "
                               + "Spam & Trash included.") { v in
                .read(GamCommands.searchMessages(email: v("email"), query: v("query"), detail: GamCommands.MessageDetail(label: v("detail"))))
            },
            CuratedCommand("build.find_users", "Users", "Users - Search", "Find users", .read,
                           [field("query", "User search", .text,
                                  placeholder: "isSuspended=true · orgUnitPath=/Sales · isEnrolledIn2Sv=false",
                                  hints: ["isSuspended=true", "isAdmin=true", "isEnrolledIn2Sv=false", "orgUnitPath=/Sales",
                                          "orgUnitPath='/Sales/Field Reps'", "email:admin*", "givenName:Jan*", "orgTitle:Manager",
                                          "orgDepartment=Engineering", "manager='boss@example.com'"],
                                  hintNote: "field=value — '=' exact, ':' contains, ':prefix*' starts-with (givenName/familyName/email "
                                      + "only). Space-separate clauses to AND them; single-quote values with spaces. orgUnitPath is an "
                                      + "exact match (not recursive).")],
                           "gam print users query <QueryUser>",
                           "Search the directory for users by an Admin-SDK query — suspended, admins, by OU, 2-step status, department, "
                               + "manager, name…") { v in
                .read(GamCommands.printUsers(query: v("query")))
            },
            CuratedCommand("build.find_cros", "ChromeOS Devices", "Devices - Search", "Find Chromebooks", .read,
                           [field("query", "Device search", .text, placeholder: "status:provisioned · asset_id:… · user:…",
                                  hints: ["status:provisioned", "asset_id:1234", "user:\"tom sawyer\"", "location:seattle",
                                          "recent_user:user@example.com", "sync:2026-01-01..", "last_user_activity:2026-06-01..2026-06-30",
                                          "aue:2026-01-01..2026-12-31", "chrome_version:111", "public_model_name:\"Pixelbook Go\""],
                                  hintNote: "field:value (colon only — no =, <, >). Quote multi-word values. Dates are YYYY-MM-DD with "
                                      + "'..' ranges (sync:2026-01-01.. = on/after). Space-separate to AND. status: provisioned | "
                                      + "disabled | deprovisioned | managed.")],
                           "gam print cros query <QueryCrOS>",
                           "Search the managed ChromeOS fleet — by status, asset ID, assigned user, location, last-sync/AUE date, or "
                               + "model…") { v in
                .read(GamCommands.printCros(query: v("query")))
            },
            CuratedCommand("build.find_files", "Users", "Drive - Search", "Find a user's Drive files", .read,
                           [person(),
                            field("query", "Drive search", .text, placeholder: "'me' in owners and trashed=false",
                                  hints: ["'me' in owners", "name contains 'budget'", "fullText contains 'confidential'",
                                          "mimeType='application/vnd.google-apps.folder'", "trashed=false", "starred=true",
                                          "'user@example.com' in writers", "sharedWithMe=true", "modifiedTime > '2026-01-01T00:00:00'",
                                          "and", "or"],
                                  hintNote: "Drive query — single-quote string values; booleans (trashed/starred/sharedWithMe) are bare "
                                      + "true/false. Combine clauses with the and/or chips. Timestamps are RFC3339, quoted.")],
                           "gam user <email> print filelist query <QueryDriveFile>",
                           "Search a user's Drive by a Drive query — by name, type, owner, sharing, or modified date…") { v in
                .read(GamCommands.printFileList(email: v("email"), query: v("query")))
            },
            CuratedCommand("build.print_forwarding", "Users", forwarding, "List forwarding addresses", .read, [person()],
                           "gam user <email> print forwardingaddresses", "Show the addresses this user may forward mail to.") { v in
                .read(GamCommands.printForwardingAddresses(email: v("email")))
            },
            CuratedCommand("build.create_alias", "Aliases", "", "Add an alias to a user", .change,
                           [field("alias", "New alias address", .email), person()],
                           "gam create alias <alias> user <email>",
                           "Give the user an additional email address that delivers to their mailbox.") { v in
                .write(GamCommands.createUserAlias(alias: v("alias"), email: v("email")))
            },
            CuratedCommand("build.delete_alias", "Aliases", "", "Remove an alias", .destructive,
                           [field("alias", "Alias address", .email)],
                           "gam delete alias <alias>", "Remove an email alias so it no longer delivers anywhere.") { v in
                .write(GamCommands.deleteAlias(alias: v("alias")))
            },
            CuratedCommand("build.add_group_member", "Groups", "", "Add member to group", .change,
                           [field("group", "Group", .group), field("member", "Member", .user),
                            field("role", "Role", .choice, choices: GamCommands.GroupRole.allCases.map(\.rawValue),
                                  default: GamCommands.GroupRole.member.rawValue)],
                           "gam update group <group> add <role> <member>",
                           "Add someone to a group as a member, manager, or owner.") { v in
                .write(GamCommands.addGroupMember(group: v("group"), member: v("member"),
                                                  role: try GamCommands.GroupRole(validating: v("role"))))
            },
            CuratedCommand("build.remove_group_member", "Groups", "", "Remove member from group", .change,
                           [field("group", "Group", .group), field("member", "Member", .user)],
                           "gam update group <group> remove <member>", "Remove someone from a group.") { v in
                .write(GamCommands.removeGroupMember(group: v("group"), member: v("member")))
            },
            CuratedCommand("build.create_group", "Groups", "", "Create a group", .change,
                           [field("email", "Group email", .email), field("name", "Display name", .text, required: false),
                            field("description", "Description", .text, required: false)],
                           "gam create group <email> name <name> description <desc>",
                           "Create a new Google Group; optionally set its display name and description.") { v in
                .write(GamCommands.createGroup(email: v("email"), name: v("name"), description: v("description")))
            },
            CuratedCommand("build.set_organization", "Users", "Profile", "Set title / department", .change,
                           [person(), field("title", "Title", .text, required: false),
                            field("department", "Department", .text, required: false)],
                           "gam update user <email> organization title <t> department <d> primary",
                           "Set the user's job title and department on their directory profile.") { v in
                .write(GamCommands.updateOrganization(email: v("email"), title: v("title"), department: v("department")))
            },
            CuratedCommand("build.reset_password", "Users", "", "Reset password (random)", .destructive, [person()],
                           "gam update user <email> password random changepassword off",
                           "Set the user's password to a new random value, locking out the old one.") { v in
                .write(GamCommands.resetPassword(email: v("email")))
            },
            CuratedCommand("build.signout_user", "Users", "", "Sign out everywhere", .change, [person()],
                           "gam user <email> signout",
                           "End all of the user's active sessions everywhere (forces re-login; does not change the password).") { v in
                .write(GamCommands.signOutUser(email: v("email")))
            },
            CuratedCommand("build.undelete_user", "Users", "", "Undelete account", .change,
                           [field("email", "Deleted user email", .email, takesUniqueID: true)],
                           "gam undelete user <email>",
                           "Restore a recently deleted account (within Google's ~20-day recovery window).") { v in
                .write(GamCommands.undeleteUser(email: v("email")))
            },
            // Handed-over ownership can't be taken back by a second transfer (docs/domains/offboarding.md). Drive names its privacy
            // level so every file moves, private and shared, as offboarding does; GAM refuses a level for calendar alone.
            CuratedCommand("build.transfer_data", "Data Transfers", "", "Transfer Drive/Calendar ownership", .destructive,
                           [person("old_owner", "From user"),
                            field("service", "Service", .choice, choices: transferServices, default: "drive"),
                            field("new_owner", "To user", .user)],
                           "gam create datatransfer <old> <service> <new> [all]",
                           "Hand a departing user's Drive (private and shared files) or Calendar content to another user.") { v in
                let service = v("service")
                let drive = service.split(separator: ",", omittingEmptySubsequences: false).contains("drive")
                return .write(GamCommands.createDataTransfer(oldOwner: v("old_owner"), service: service, newOwner: v("new_owner"),
                                                             privacy: drive ? .all : nil))
            },
            CuratedCommand("build.suspend_user", "Users", "", "Suspend account", .destructive, [person()],
                           "gam update user <email> suspended on",
                           "Block the user from signing in, without deleting the account (reversible).") { v in
                .write(GamCommands.setSuspended(email: v("email"), suspended: true))
            },
        ]
    }()

    /// GamGUI's `TRANSFER_SERVICES`: `drive,calendar` is one `<DataTransferServiceList>` element, both in one transfer (two
    /// overlapping transfers for one person get Google's 409).
    static let transferServices = ["drive", "calendar", "drive,calendar"]

    private init(_ id: String, _ category: String, _ subcategory: String, _ name: String, _ risk: CommandCatalog.Risk,
                 _ fields: [Field], _ syntax: String, _ description: String,
                 build: @escaping @Sendable (_ value: (String) -> String) throws -> Built) {
        self.id = id
        self.category = category
        self.subcategory = subcategory
        self.name = name
        self.risk = risk
        self.fields = fields
        self.syntax = syntax
        self.description = description
        self.build = build
    }

    private static func person(_ key: String = "email", _ label: String = "User") -> Field {
        field(key, label, .targetUser)
    }

    private static func field(_ key: String, _ label: String, _ kind: Field.Kind, required: Bool = true, choices: [String] = [],
                              default defaultValue: String = "", placeholder: String = "", hints: [String] = [],
                              hintNote: String = "", takesUniqueID: Bool = false) -> Field {
        Field(key: key, label: label, kind: kind, required: required, choices: choices, defaultValue: defaultValue,
              placeholder: placeholder, hints: hints, hintNote: hintNote, takesUniqueID: takesUniqueID)
    }
}
