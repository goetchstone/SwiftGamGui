import Foundation
/// GAM argv builders: Swift ports of GamGUI's `GAMCommands` (`core/gam/commands.py`). Each returns a
/// `GamRead` or a `GamWrite` (`GamCommand.swift`) whose argv is **byte-identical** to GamGUI's live-proven
/// builder for the same inputs, held to
/// `Tests/Fixtures/argv.json` by `GoldenArgvTests` (invariants 1 and 11). Every operator value is one
/// element; nothing is ever joined into a command line. An empty optional value is left out, as
/// GamGUI's `if value:` does.
public enum GamCommands {
    public enum Invalid: Error, Equatable, Sendable {
        case argument(String)
    }

    /// Bounds an empty or broad message search so it can't dump a whole mailbox into the table.
    public static let messageCap = 50
    static let eventFields = "id,summary,start,end,recurrence,recurringeventid,organizer,creator,status"
    static let calendarFields = "id,summary,accessrole,primary"

    // MARK: diagnostics and setup

    public static func version() -> GamRead {
        GamRead(["version"])
    }

    /// Verifies domain-wide delegation for exactly `scopes`:
    /// `gam <UserTypeEntity> check serviceaccount (scope|scopes <APIScopeURLList>)*`, the list one
    /// comma-joined element. Without it GAM checks its own, larger default set and refuses an operator
    /// who authorized only the scopes the app asked for (GamGUI failure-log 2026-09-25). The noun is
    /// `serviceaccount` here, though GAM says `create svcacct`.
    public static func checkServiceAccount(admin: String, scopes: [String]) throws -> GamRead {
        guard !scopes.isEmpty else { throw Invalid.argument("check_svcacct needs the scopes to check") }
        return GamRead(["user", admin, "check", "serviceaccount", "scopes", scopes.joined(separator: ",")])
    }

    // MARK: users (read)

    public static func printUsers(query: String = "", fields: [String] = []) -> GamRead {
        GamRead(["print", "users"] + optional("query", query)
            + ["fields", (fields.isEmpty ? userListFields : fields).joined(separator: ","), "formatjson"])
    }

    /// Searches the ChromeOS fleet by a CrOS query.
    public static func printCros(query: String = "", fields: [String] = []) -> GamRead {
        GamRead(["print", "cros"] + optional("query", query)
            + ["fields", (fields.isEmpty ? crosListFields : fields).joined(separator: ","), "formatjson"])
    }

    /// Searches a user's Drive files by a Drive v3 query.
    public static func printFileList(email: String, query: String = "", fields: [String] = []) -> GamRead {
        GamRead(["user", email, "print", "filelist"] + optional("query", query)
            + ["fields", (fields.isEmpty ? fileListFields : fields).joined(separator: ","), "formatjson"])
    }

    /// Admin SDK usage report (storage, mail, Drive). The data lags two to three days.
    public static func reportUsers(date: String, parameters: [String]) -> GamRead {
        GamRead(["report", "users", "date", date, "parameters", parameters.joined(separator: ",")])
    }

    public static func infoUser(email: String, fields: [String] = []) -> GamRead {
        GamRead(["info", "user", email, "fields", (fields.isEmpty ? userDetailFields : fields).joined(separator: ","), "formatjson"])
    }

    // MARK: users (write)

    /// With `notify`, Google emails the sign-in details (with the one-time password) straight to that
    /// address, so the operator never handles them. The notify clause follows the user attributes
    /// (the grammar's `create|add user` rule); `notifypassword` carries the same password, which the
    /// audit redacts.
    public static func createUser(
        email: String, firstName: String, lastName: String, password: String,
        changePassword: Bool = true, orgUnit: String = "", notify: String = ""
    ) -> GamWrite {
        GamWrite(["create", "user", email, "firstname", firstName, "lastname", lastName, "password", password,
         "changepassword", changePassword ? "on" : "off"]
            + optional("org", orgUnit)
            + (notify.isEmpty ? [] : ["notify", notify, "notifypassword", password]), action: .createUser)
    }

    /// GAM's `organization` replaces the primary organization, so both fields always go together
    /// (the editor pre-fills the current values) and changing one never clears the other.
    public static func updateOrganization(email: String, title: String = "", department: String = "") -> GamWrite {
        GamWrite(["update", "user", email, "organization", "title", title, "department", department, "primary"], action: .updateOrganization)
    }

    public static func setSuspended(email: String, suspended: Bool) -> GamWrite {
        GamWrite(["update", "user", email, "suspended", suspended ? "on" : "off"], action: suspended ? .suspendUser : .unsuspendUser)
    }

    // MARK: written here first
    // Each was checked against the vendored grammar and GAM's source; GamGUI has since taken each one, so its argv is held
    // to GamGUI's (GoldenArgvTests), and what each refuses beyond GamGUI's cases by NativeArgvTests.

    /// One of a person's phones as Google keeps it: its type (GAM's word for it, or `custom` with `customType`), the
    /// number, and whether it's the primary one. `GamUser.Phone` is this; it lives here so the fuzz build has it.
    public struct Phone: Sendable, Equatable {
        public let type: String
        public let customType: String
        public let value: String
        public let primary: Bool

        public init(type: String, customType: String = "", value: String, primary: Bool) {
            (self.type, self.customType, self.value, self.primary) = (type, customType, value, primary)
        }

        /// As a user record holds it: a custom type's name and the primary flag only when there's one.
        var json: JSONValue {
            var phone: GamOutput.Record = ["type": .string(type), "value": .string(value)]
            if !customType.isEmpty { phone["customType"] = .string(customType) }
            if primary { phone["primary"] = .bool(true) }
            return .object(phone)
        }
    }

    /// GAM's phone types (5890-5892 `phone [type assistant|…|work_pager|(custom <String>)]`). A type outside them GAM
    /// keeps as a custom type of that name (getKeywordAttribute), so a phone goes back only with one of these, `custom`
    /// with its name, or no type.
    public static let phoneTypes: Set<String> = [
        "assistant", "callback", "car", "company_main", "grand_central", "home", "home_fax", "isdn", "main", "mobile",
        "other", "other_fax", "pager", "radio", "telex", "tty_tdd", "work", "work_fax", "work_mobile", "work_pager",
    ]

    /// The person's phones, every one of them (5890-5894 `phone [type …] [value <String>] notprimary|primary`, 5915
    /// `phone clear`). GAM sends the phones it's given as the list Google keeps in place of the old one, and drops one
    /// with no value (getUserAttributes, updateUsers' users.update, gam/__init__.py:47476-47489 at 7.48.30), so a phone
    /// left out is deleted: the others go as they are, and none left is `phone clear`. Each number one line, at most one
    /// primary (GAM's usage error otherwise).
    public static func updatePhones(email: String, phones: [Phone]) throws -> GamWrite {
        guard phones.count(where: \.primary) <= 1 else { throw Invalid.argument("only one phone can be the primary") }
        var argv = ["update", "user", email]
        for phone in phones {
            guard !phone.value.isEmpty, !phone.value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else { throw Invalid.argument("each phone is a number on one line") }
            let type = PythonText.lower(phone.type)
            // GAM strips a custom type's name (getKeywordAttribute) and keeps none on a phone that isn't `custom`.
            guard type == "custom" || phone.customType.isEmpty else {
                throw Invalid.argument("a phone of type “\(phone.type)” with its own name would lose the name")
            }
            let typed: [String]
            if type.isEmpty {
                typed = []
            } else if type == "custom" {
                guard !PythonText.strip(phone.customType).isEmpty else { throw Invalid.argument("a custom phone type has a name") }
                guard PythonText.strip(phone.customType) == phone.customType else {
                    throw Invalid.argument("the custom phone type “\(phone.customType)” would come back without its spaces")
                }
                typed = ["type", "custom", phone.customType]
            } else {
                guard phoneTypes.contains(type) else { throw Invalid.argument("“\(phone.type)” isn't a phone type GAM keeps as it is") }
                typed = ["type", type]
            }
            argv += ["phone"] + typed + ["value", phone.value, phone.primary ? "primary" : "notprimary"]
        }
        return GamWrite(phones.isEmpty ? argv + ["phone", "clear"] : argv, action: .updatePhones)
    }

    /// Both recovery fields emptied, so "Forgot password?" can't reach the leaver's own phone or address
    /// (grammar 5858-5859 under `update user`, 5958; GAM sends an empty value as a cleared field). The command
    /// line shown and audited masks both (`ArgvRedaction`), so the step's words say what it does.
    public static func clearRecovery(email: String) -> GamWrite {
        GamWrite(["update", "user", email, "recoveryemail", "", "recoveryphone", ""], action: .clearRecovery)
    }

    /// A password the operator hands over, which Google makes the person change at their next sign-in (grammar 5958
    /// `update user <UserItem> <UserAttribute>*`; 5854-5857 `password <Password>`, 5841 `changepassword <Boolean>`).
    /// GamGUI's reset is `random` with `changepassword off`, which nobody sees, so this one is native. `password` is
    /// one element and never one of GAM's words there (`random`, `uniquerandom`, `blocklogin`, `prompt`,
    /// `uniqueprompt`): `TemporaryPassword`'s are three dashed groups,
    /// masked in what's shown and audited (`ArgvRedaction`) and in GAM's echo (`SecretScrub`).
    package static func setPassword(email: String, password: String) -> GamWrite {
        GamWrite(["update", "user", email, "password", password, "changepassword", "on"], action: .setPassword)
    }

    /// Out of the Global Address List and autocomplete (grammar 5847). Always the explicit `off`: GAM reads a
    /// bare `gal` as on.
    public static func hideFromDirectory(email: String) -> GamWrite {
        GamWrite(["update", "user", email, "gal", "off"], action: .hideFromDirectory)
    }

    /// IMAP off (grammar 8403 `<UserTypeEntity> imap|imap4 <Boolean>`). GAM sends its defaults with it (`_imapDefaults`:
    /// auto-expunge, archive, no folder limit), which matter only while IMAP is on.
    public static func imapOff(email: String) -> GamWrite {
        GamWrite(["user", email, "imap", "off"], action: .imapOff)
    }

    /// POP off (8409 `<UserTypeEntity> pop|pop3 <Boolean>`). GAM sends `leaveInInbox` with it (`_popDefaults`), so no
    /// mail is moved or deleted.
    public static func popOff(email: String) -> GamWrite {
        GamWrite(["user", email, "pop", "off"], action: .popOff)
    }

    /// Each calendar's owner made `newOwner`, in one command: GAM goes through the list and reports each, a failure
    /// leaving the rest done (doCalendarsTransferOwnership). `transfer ownership`, not the grammar's bare `transfer`
    /// (1694 lacks the word; GAM's source and GamUpdate 7.46.04 need it). The list is one <CalendarEntity> element
    /// GAM splits on commas and Python's whitespace, by code point, so each ID is checked by scalar: ASCII letters,
    /// digits and `._-+`, one `@`, ending `.calendar.google.com` (GAM gets any other ID as a user's calendar).
    public static func transferCalendarOwnership(calendarIDs: [String], to newOwner: String) throws -> GamWrite {
        func isCalendarID(_ id: String) -> Bool {
            id.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "._-+@".unicodeScalars.contains($0)) }
                && id.unicodeScalars.filter { $0 == "@" }.count == 1 && id.lowercased().hasSuffix(".calendar.google.com")
        }
        guard !calendarIDs.isEmpty, calendarIDs.allSatisfy(isCalendarID)
        else { throw Invalid.argument("each calendar to hand over is one calendar ID") }
        return GamWrite(["calendars", calendarIDs.joined(separator: ","), "transfer", "ownership", newOwner],
                        action: .transferCalendarOwnership)
    }

    /// The person's Gmail filters, each one's JSON with its `action.forward` (grammar 7990-7991; printShowFilters).
    /// `labelidsonly` skips the label-name lookup this has no use for.
    public static func printFilters(email: String) -> GamRead {
        GamRead(["user", email, "print", "filters", "labelidsonly", "formatjson"])
    }

    /// The filters deleted in one command: GAM goes through the list, a failure leaving the rest done (grammar 7986;
    /// deleteFilters). The list is one <FilterIDEntity> element split on commas: each ID is ASCII letters, digits, `-_`,
    /// and the element mustn't be a list selector GAM reads a file from instead (getChoice, ignoring case, `_` and `-`).
    public static func deleteFilters(email: String, filterIDs: [String]) throws -> GamWrite {
        guard let list = idList(filterIDs) else { throw Invalid.argument("each filter to delete is one filter ID") }
        return GamWrite(["user", email, "delete", "filters", list], action: .deleteFilters)
    }

    /// `ids` as one entity-list element GAM splits on commas, or nil: each ID ASCII letters, digits, `-` and `_`, and the
    /// element never a list selector GAM reads a file from instead (getChoice, ignoring case, `_` and `-`).
    static func idList(_ ids: [String]) -> String? {
        let list = ids.joined(separator: ",")
        let selectors: Set = ["csvkmd", "csvsubkey", "csv", "csvfile", "file", "csvdata"]   // ENTITY_LIST_SELECTORS
        guard !ids.isEmpty, ids.allSatisfy({ id in
            !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" || $0 == "_") }
        }), !selectors.contains(list.lowercased().filter { $0 != "_" && $0 != "-" })
        else { return nil }
        return list
    }

    /// A short listing of the messages a Gmail search finds: the newest `max` (8264 `max_to_print`), each with only its
    /// Subject (8266 `headers <SMTPHeaderList>`; GAM names the column by SMTP_HEADERS_MAP), its labels and Gmail's own time
    /// (8267-8268). Only the subject: a phishing draft's Bcc list can run to hundreds of addresses, and thousands of those
    /// would pass the runner's cap (review 2026-10-19). Spam and Trash aren't searched.
    public static func listMessages(email: String, query: String, max: Int) -> GamRead {
        GamRead(["user", email, "print", "messages", "query", query, "max_to_print", String(max), "headers", "subject",
                 "showlabels", "showdate"])
    }

    /// The messages `ids` deleted for good (8199-8203 `delete messages … (ids <MessageIDEntity>)`; _processMessagesThreads:
    /// with ids no `doit` is needed and no count is checked): Gmail's batchDelete, `message_batch_size` (50) at a time, as
    /// Gmail's own Discard deletes a draft. A batch holding an ID Gmail refuses fails whole ("Invalid message id(s)"), the
    /// other batches done. Not Trash: a trashed draft may still be a draft, and sendable (review 2026-10-19). The list is
    /// one element GAM splits on commas (`idList`).
    public static func deleteMessages(email: String, ids: [String]) throws -> GamWrite {
        guard let list = idList(ids) else { throw Invalid.argument("each message to delete is one message ID") }
        return GamWrite(["user", email, "delete", "messages", "ids", list], action: .deleteMessages)
    }

    /// The secondary calendars `email` owns (`dataOwner`), hidden ones included: GAM filters the person's own
    /// calendar list, which leaves hidden entries out unless asked (grammar 6303-6304; printShowCalendars).
    /// Rows `primaryEmail,calendarId,JSON`, the JSON with `id`, `summary` and `dataOwner`.
    public static func printOwnedSecondaryCalendars(email: String) -> GamRead {
        GamRead(["user", email, "print", "calendars", "ownedsecondary", "showhidden", "fields", "id,summary", "formatjson"])
    }

    /// The open Vault matters' holds that cover `email`, directly or through an org unit above them (grammar 5720;
    /// printShowUserVaultHolds). CSV only: `User,matterId,matterName,holdId,name,orgUnitId,orgUnitPath`.
    public static func printVaultHolds(email: String) -> GamRead {
        GamRead(["user", email, "print", "vaultholds"])
    }

    /// Who has a copy of one email: GAM's own dry run of the trash below, over every active user (`all users` is
    /// `isSuspended=False isGuest=False`). Without `doit`, `_processMessagesThreads` (7.48.30) lists each user's matches
    /// (Gmail's `messages.list`, Spam and Trash left out) and prints a count per user, every line on stderr, and
    /// returns before any trash call; it never exits 0 across a domain, since each user sets the code (60 for no
    /// copy, 51 for a count) and the last one stands. Grammar 8215-8219. `notquick`, so a count is every match: with
    /// GAM's default `quick` it asks Gmail for at most `max_to_trash` and no count could exceed it. Reviewed in
    /// `CommandKindTests`: `trash` is a destructive verb, and only the absent `doit` makes this a read.
    public static func findMessageCopies(_ message: MessageID) -> GamRead {
        GamRead(["all", "users", "trash", "messages", "query", message.query, "notquick", "max_to_trash", "1"])
    }

    /// One mailbox's copies of the email moved to its Trash (Gmail empties it after 30 days; until then
    /// `untrash messages` puts them back). At most `copies`, the count the dry run showed for this mailbox, so a run
    /// never trashes more than its preview did: a mailbox holding more by then is left alone with GAM's "Count N
    /// exceeds maximum to Trash M" (exit 51). GAM reads `max_to_trash 0` as no limit, so a count below 1 is refused.
    public static func trashMessage(email: String, _ message: MessageID, copies: Int) throws -> GamWrite {
        guard copies >= 1 else { throw Invalid.argument("a mailbox to trash from holds at least one copy") }
        return GamWrite(["user", email, "trash", "messages", "query", message.query, "notquick", "max_to_trash", String(copies), "doit"],
                        action: .trashMessage)
    }

    /// Who has a copy of the email in Spam, each by Gmail's ID: `print messages` over every active user (8261-8270
    /// `… query <QueryGmail> … [includespamtrash] … [headers <SMTPHeaderList>] … [showlabels]`), which lists Spam and Trash
    /// as the dry run above never does (printShowMessagesThreads, 7.48.30). Only the Message-ID header (GAM's default set
    /// has To, hundreds of addresses a mailbox for a mass phish) and the labels: `SpamCopies` checks each copy is this
    /// email, in Spam and not Trash.
    public static func findSpamCopies(_ message: MessageID) -> GamRead {
        GamRead(["all", "users", "print", "messages", "query", message.spamQuery, "includespamtrash", "headers", "message-id",
                 "showlabels"])
    }

    /// One mailbox's copies in Spam moved to its Trash, by the IDs `findSpamCopies` read (8215-8219 `trash messages …
    /// (ids <MessageIDEntity>)`; _processMessagesThreads: with ids nothing is listed, so Spam is no bar, no `doit` is needed
    /// and no count is checked; Gmail's `messages.trash` runs on each ID). Exactly those copies, so never more than the
    /// preview showed; one gone since is GAM's "Does not exist" for that ID (exit 50), the rest trashed. The list is one
    /// element GAM splits on commas (`idList`, 770 `<MessageIDList>`).
    public static func trashMessages(email: String, ids: [String]) throws -> GamWrite {
        guard let list = idList(ids) else { throw Invalid.argument("each message to trash is one message ID") }
        return GamWrite(["user", email, "trash", "messages", "ids", list], action: .trashMessage)
    }

    /// Auto-forwarding as Gmail has it now (8032; printShowForward): CSV `User,forwardEnabled,forwardTo,disposition`, the
    /// address and what happens to the kept copy only while it's on.
    public static func printForward(email: String) -> GamRead {
        GamRead(["user", email, "print", "forward"])
    }

    /// The person's send-as addresses, the primary among them (8328; printShowSendAs), CSV. `verifyonly` makes each
    /// signature a yes or no rather than its HTML.
    public static func printSendAs(email: String) -> GamRead {
        GamRead(["user", email, "print", "sendas", "verifyonly"])
    }

    /// One account's sign-in on a computer, blocked in Google's endpoint management: the computer can't reach the account's
    /// data, and stays listed as blocked (approving it undoes it). 4392; _performCIDeviceUserAction. `name` is the device
    /// user's own (`isDeviceUserName`), by which GAM acts without `doit`.
    public static func blockDeviceUser(name: String) throws -> GamWrite {
        guard isDeviceUserName(name) else { throw Invalid.argument("a computer's sign-in is devices/<id>/deviceUsers/<id>") }
        return GamWrite(["block", "deviceuser", name], action: .blockDeviceUser)
    }

    /// One account's sign-in on a computer, deleted: the account is taken off it and its access to the account's data
    /// revoked (4389; the same). It shows again only if someone signs in on it again.
    public static func deleteDeviceUser(name: String) throws -> GamWrite {
        guard isDeviceUserName(name) else { throw Invalid.argument("a computer's sign-in is devices/<id>/deviceUsers/<id>") }
        return GamWrite(["delete", "deviceuser", name], action: .deleteDeviceUser)
    }

    /// A device user's name as Google gives it and GAM takes it by name (DEVICE_USERNAME_PATTERN, `devices/.+/deviceUsers/.+`),
    /// held to Google's ID characters: never `query:`, `id`, a list, the API's `-` wildcard (`devices/-/deviceUsers/-`, every
    /// one) or anything GAM reads as more than the one name.
    static func isDeviceUserName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        let id = { (part: Substring) in !part.isEmpty && part != "-" && part.count <= 256
            && part.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" } }
        return parts.count == 4 && parts[0] == "devices" && parts[2] == "deviceUsers" && id(parts[1]) && id(parts[3])
    }

    /// One send-as address taken off the person's "Send mail as" list (8324; deleteInfoSendAs). The address is one
    /// <EmailAddressEntity> element GAM splits on commas and Python's whitespace, or reads a file from when it's a list
    /// selector, so it must be one plain address (`isOneAddress`).
    public static func deleteSendAs(email: String, address: String) throws -> GamWrite {
        guard isOneAddress(address) else { throw Invalid.argument("each send-as address to remove is one email address") }
        return GamWrite(["user", email, "delete", "sendas", address], action: .deleteSendAs)
    }

    /// A time GAM reads as one (<Time>), in the one form the app writes: `yyyy-mm-ddThh:mm:ssZ`, UTC to the second, each
    /// field in range (GAM's parser refuses a 13th month; a day past its month's end is GAM's to refuse).
    static func isReportTime(_ time: String) -> Bool {
        let scalars = Array(time.unicodeScalars)
        guard scalars.count == 20 else { return false }
        let shape = scalars.enumerated().allSatisfy { index, scalar in
            switch index {
            case 4, 7: scalar == "-"
            case 10: scalar == "T"
            case 13, 16: scalar == ":"
            case 19: scalar == "Z"
            default: ("0"..."9").contains(scalar)
            }
        }
        func number(_ from: Int, _ to: Int) -> Int { scalars[from..<to].reduce(0) { $0 * 10 + Int($1.value - 48) } }
        return shape && (1...12).contains(number(5, 7)) && (1...31).contains(number(8, 10)) && number(11, 13) < 24
            && number(14, 16) < 60 && number(17, 19) < 60
    }

    /// An address GAM acts on as given, in an <EmailAddressEntity> or <UserEntity>: no comma or whitespace to split on, an
    /// `@` (so never a list selector), nothing around it to strip, and no form GAM rewrites to another address
    /// (normalizeEmailAddressOrUID takes `Name <a@b>` as `a@b`; convertUIDtoEmailAddress reads `id:` and `uid:`, matched
    /// ignoring case as Python does, so `ıd:` too: no `:` at all).
    package static func isOneAddress(_ address: String) -> Bool {
        Address.looksLikeEmail(address) && PythonText.strip(address) == address
            && !address.unicodeScalars.contains { $0 == "<" || $0 == ">" || $0 == ":" }
    }

    /// A Google account's address in a filter's value, lowercased: letters, digits, `.`, `_`, `'` and `-` before the `@`
    /// (Google's username characters), and a domain of letters, digits and `-` in dot-separated labels. Nothing a
    /// filter could read as more than the value (a comma, an operator, a quote, a wildcard); nil for anything else.
    static func filterAddress(_ address: String) -> String? {
        let lowered = PythonText.lower(address)
        let parts = lowered.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[0].unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || "._'-".unicodeScalars.contains($0) })
        else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        }) else { return nil }
        return lowered
    }

    /// How Chrome's log finds one account's events (`reportActivity`): `profile`, by the account signed in to the Chrome
    /// profile (`PROFILE_USER_NAME`); `device`, GAM's own match for a named user, the device's user (`DEVICE_USER`: a
    /// Chromebook's account, but on a Mac or PC the computer's login name). Neither finds every event alone: ChromeOS
    /// sign-ins, data-protection events and extension requests carry no profile (Google's appendix), and on a Mac or PC
    /// an event with no profile names no account at all.
    public enum ChromeMatch: Sendable, CaseIterable {
        case profile, device
    }

    /// How the admin log reads an account: what it did as an admin (`userisactor`), or what admins did to it (doReport
    /// otherwise maps each account to the filter `USER_EMAIL==<account>`, :14779-14788): a password reset, a sign-out.
    public enum AdminMatch: Sendable, CaseIterable {
        case actor, affected
    }

    /// An activity report's application (4704-4743), as GAM's REPORT_CHOICE_MAP keys spell it. The Admin console's
    /// "Access" log (cookie validation, access-token requests) is `access_evaluation`.
    public enum ActivityApplication: String, CaseIterable, Sendable {
        case login, token, saml, gmail
        case accessEvaluation = "accessevaluation"
        case chat
        case userAccounts = "useraccounts"
        case takeout, mobile, chrome, drive, calendar, groups, admin, rules
        case contextAwareAccess = "contextawareaccess"
        case vault
        /// The rest of GAM's activity logs (REPORT_CHOICE_MAP; not `gplus` or `jamboard`, whose services have ended).
        case gemini = "geminiinworkspaceapps"
        case meet, contacts, keep, tasks
        case adminDataAction = "admindataaction"
        case accessTransparency = "accesstransparency"
        case dataStudio = "datastudio"
        case groupsEnterprise = "groupsenterprise"
        case profile, ldap
        case directorySync = "directorysync"
        case gcp
        case cloudSearch = "cloudsearch"
        case classroom
        case dataMigration = "datamigration"
        case meetHardware = "meethardware"
        case assignments, graduation
    }

    /// Activity events, newest first (4744-4758; doReport's activity form): `users` one address each (`user` for one,
    /// `select users` for several, `user all` for none); `start -<hours>h end now` (getDeltaTime: now less that many
    /// hours; the end named so Gmail's 30-day rule doesn't move it), or `start` and `end` both given as times (`isReportTime`,
    /// UTC to the second, which GAM passes on as they are: a window fixed once, read further back page by page); `ip` keeps
    /// the events from that address
    /// (actorIpAddress, server-side); `events` only those names; `maxactivities` bounds each read (invariant 9). CSV, a row
    /// per event. The admin log reads the accounts by `admin` (`AdminMatch`): with `userisactor`, what they did as admins,
    /// or without it what admins did to them. Chrome's is read one account at a time, by `chrome` (`ChromeMatch`): the profile's account
    /// (`user all filter PROFILE_USER_NAME==<account>`, the filter passed as given, so the address lowercased as Google
    /// keeps it), or GAM's own `user <account>`, which doReport turns into `DEVICE_USER==<account>`. Throws for a window
    /// outside 1 hour to 180 days (30 for Gmail, the API's limit), more than 20 accounts (Chrome: more than one, and only
    /// Google's address characters) or one that isn't one address, an `ip` that isn't one IP address, or an event name
    /// that isn't letters and `_`.
    public static func reportActivity(_ application: ActivityApplication, users: [String] = [], hours: Int, start: String = "",
                                      end: String = "", ip: String = "", events: [String] = [], maxActivities: Int,
                                      chrome: ChromeMatch = .profile, admin: AdminMatch = .actor) throws -> GamRead {
        guard (1...4_320).contains(hours), maxActivities > 0 else { throw Invalid.argument("a report reads 1 hour to 180 days") }
        // Both times or neither; the one form sorts as it reads, so the start must sort before the end.
        guard start.isEmpty == end.isEmpty, start.isEmpty || (isReportTime(start) && isReportTime(end) && start < end) else {
            throw Invalid.argument("a report's window is a start and an end, each yyyy-mm-ddThh:mm:ssZ, the start first")
        }
        guard application != .gmail || hours <= 720 else { throw Invalid.argument("the Gmail log reads at most 30 days") }
        guard users.count <= 20, users.allSatisfy(isOneAddress) else {
            throw Invalid.argument("each account is one email address, and at most 20 at once")
        }
        guard application != .chrome || users.count <= 1 else { throw Invalid.argument("the Chrome log reads one account at a time") }
        // What was done to an account is read through a filter GAM builds from it (`USER_EMAIL==<account>`): only Google's
        // address characters, as Chrome's filter is held to.
        guard application != .admin || admin == .actor || users.allSatisfy({ filterAddress($0) != nil }) else {
            throw Invalid.argument("an account the admin log reads what was done to is one plain address")
        }
        let chromeAccount = application == .chrome ? users.first.map(filterAddress) : nil
        guard chromeAccount != .some(nil) else { throw Invalid.argument("“\(users[0])” isn't an address the Chrome log can match") }
        guard ip.isEmpty || Address.isIP(ip) else { throw Invalid.argument("“\(ip)” isn't one IP address") }
        guard events.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ($0.isASCII && $0.properties.isAlphabetic) || $0 == "_" } })
        else { throw Invalid.argument("an event name is letters and “_”") }
        let who: [String]
        if users.isEmpty {
            who = ["user", "all"]
        } else if let account = chromeAccount ?? nil {
            who = chrome == .profile ? ["user", "all", "filter", "PROFILE_USER_NAME==\(account)"] : ["user", account]
        } else {
            who = users.count == 1 ? ["user", users[0]] : ["select", "users", users.joined(separator: ",")]
        }
        return GamRead(["report", application.rawValue] + who + (application == .admin && !users.isEmpty && admin == .actor ? ["userisactor"] : [])
            + ["start", start.isEmpty ? "-\(hours)h" : start, "end", end.isEmpty ? "now" : end] + optional("ip", ip)
            + (events.isEmpty ? [] : ["events", events.joined(separator: ",")]) + ["maxactivities", String(maxActivities)])
    }

    /// The Chrome profiles signed in with `user`'s account that Google knows of (2310-2349; doPrintShowChromeProfiles):
    /// `print chromeprofiles filter user_email="<user>"`, the Chrome Management API's own field name, the address quoted
    /// so its `@` and dots are one value, and lowercased as Google keeps it (GAM passes a filter as given). CSV
    /// `name,profileId,JSON`. Needs GAM's "Chrome Management API - Profiles" scope (exit 15 with no Chrome Management scope
    /// at all, 50 with the API's refusal) and managed profile reporting on in the Admin console. Throws for an address
    /// outside Google's address characters (`filterAddress`).
    public static func printChromeProfiles(user: String) throws -> GamRead {
        guard let account = filterAddress(user) else { throw Invalid.argument("“\(user)” isn't one email address") }
        return GamRead(["print", "chromeprofiles", "filter", "user_email=\"\(account)\"", "fields", chromeProfileFields, "formatjson"])
    }

    /// The phones and tablets that sync `user`'s account (4569-4576; doPrintMobileDevices): `print mobile query
    /// email:<user> fields … formatjson`, the Directory API's mobile search by owner, the address lowercased and only
    /// Google's address characters (`filterAddress`, so the query is one `field:value`). `listlimit 0`: GAM cuts every list in
    /// the JSON to one by default (doPrintMobileDevices: `listLimit = 1`, `cleanJSON`), so a shared device listed only its first
    /// owner, and the reader then said the second had no phone. CSV `resourceId,JSON`. A refusal is GAM's
    /// ClientAPIAccessDeniedExit, exit 12.
    public static func printMobileDevices(user: String) throws -> GamRead {
        guard let account = filterAddress(user) else { throw Invalid.argument("“\(user)” isn't one email address") }
        return GamRead(["print", "mobile", "query", "email:\(account)", "fields", mobileFields, "listlimit", "0", "formatjson"])
    }

    /// What a device says: whose (`email`, which the formatjson row needs `resourceid` beside), what it is, and its syncs.
    static let mobileFields = "resourceid,email,model,os,type,status,firstsync,lastsync,devicecompromisedstatus"

    /// Every device signed in with `user`'s account that Google's endpoint management knows, computers among them, which
    /// `printMobileDevices` never lists (4373-4381; doPrintCIDevices): `print devices query email:<user> fields …
    /// userfields … formatjson`, the Cloud Identity Devices API's search by user (`email:`, Google's mobile device search
    /// field, matching a prefix), the address as `filterAddress` gives it (so the query is one `field:value`, as
    /// _validateDeviceQuery requires). Every view (GAM's default `all`), each device with its users. CSV `name,JSON`. The
    /// service account impersonates the admin, so without the scope delegated it is "User: <admin>, Cloud Identity API -
    /// Devices Service/App not enabled", exit 73; a scope list without the API is SvcAcctAPIAccessDeniedExit, exit 12.
    public static func printDevices(user: String) throws -> GamRead {
        guard let account = filterAddress(user) else { throw Invalid.argument("“\(user)” isn't one email address") }
        return GamRead(["print", "devices", "query", "email:\(account)", "fields", deviceFields, "userfields", deviceUserFields,
                        "formatjson"])
    }

    /// What an endpoint says (4298-4331): what it is, who made it and what it's called, whose company it is, its state, and
    /// when it was imported and last synced.
    static let deviceFields = "devicetype,model,manufacturer,osversion,hostname,serialnumber,ownertype,managementstate,"
        + "compromisedstate,createtime,lastsynctime"

    /// What each of its users says (4333-4343): who, when they first signed in to it and last synced it, and their state on it.
    static let deviceUserFields = "name,useremail,createtime,firstsynctime,lastsynctime,managementstate"

    /// The Apps Script projects `user` owns (7822-7849 `<UserTypeEntity> print filelist … [showmimetype <MimeTypeList>] …
    /// (fields <DriveFieldNameList>) … [formatjson]`; printFileList): Drive files of type `gscript`
    /// (application/vnd.google-apps.script), which GAM puts in Drive's own query beside its default `'me' in owners`, so
    /// only the person's own projects in their My Drive are listed, a binned one too (`trashed` says so). A project bound
    /// inside a Sheet or Doc isn't a Drive file, and one in a shared drive isn't the person's, so neither shows; GAM has no
    /// command for a project's triggers. CSV `Owner,id,name,JSON`. GAM exits 60 whenever it printed no row, for none and
    /// for a failure alike (`Compromised.ScriptProject.list` tells them apart).
    public static func printScriptProjects(user: String) throws -> GamRead {
        guard isOneAddress(user) else { throw Invalid.argument("“\(user)” isn't one email address") }
        return GamRead(["user", user, "print", "filelist", "showmimetype", "gscript", "fields", scriptFields, "formatjson"])
    }

    /// What a project says (7620-7714 <DriveFieldName>): its name, when it was made and last changed and by whom, and
    /// whether it's in the bin.
    static let scriptFields = "id,name,createdtime,modifiedtime,trashed,lastmodifyinguser"

    /// What a person's Chrome profile says: whose, where, which browser, and when it was last used.
    static let chromeProfileFields = "displayname,useremail,lastactivitytime,firstenrollmenttime,osplatformtype,osversion,"
        + "browserversion,browserchannel,deviceinfo,affiliationstate"

    /// The apps people have given access to their account (9119-9128; _printShowTokens): every account but the suspended
    /// ones (GAM's default, all users), or one person's. CSV `user,clientId,displayText,anonymous,nativeApp,userKey,scopes`,
    /// the scopes space-joined (csv_output_field_delimiter's default). A refusal is ClientAPIAccessDeniedExit, exit 12.
    /// Reports' mail review (roadmap 3.2, GamGUI's `all_users_print_forward`): every active account's forwarding that is on
    /// (grammar `<UserTypeEntity> print forward [enabledonly]`). No formatjson: CSV `User,forwardEnabled,forwardTo,disposition`,
    /// each account announced on stderr, which is how a skipped one is told apart (`MailReview.accountFor`).
    public static func allUsersPrintForward() -> GamRead {
        GamRead(["all", "users", "print", "forward", "enabledonly"])
    }

    /// Every active account's mail delegates (`<UserTypeEntity> print delegates [shownames]`). No formatjson: CSV
    /// `User,delegateName,delegateAddress,delegationStatus`, each account announced ("Getting all Delegates for <u>").
    public static func allUsersPrintDelegates() -> GamRead {
        GamRead(["all", "users", "print", "delegates", "shownames"])
    }

    // MARK: many signatures in one call (roadmap 5.4, GamGUI #193)

    /// Every listed person's stored signature in one call, the addresses one a line on GAM's standard input (`file -`).
    public static func printSignaturesFromStdin(emails: [String] = []) -> GamRead {
        GamRead(["file", "-", "print", "signature"], input: Data(SignaturesFast.emailsStdin(emails).utf8))
    }

    /// GAM's own `csv` loop sets each row's signature, the rows (`User`, `signature`) on standard input. The delimiter, no
    /// escape character and quote are said here, not left to gam.cfg (a `\\` escape would eat backslashes), in the order
    /// `openCSVFileReader` checks them, each once: GamGUI's order leaves `noescapechar` unread and GAM exits 2 (a listed
    /// deviation, `GoldenArgvTests.deviations`). `~User` and
    /// `~signature` are whole-argument substitutions. An empty cell would clear a signature: `SignaturesFast.refusal` refuses one.
    public static func setSignaturesCSV(rows: [(email: String, body: String)] = []) -> GamWrite {
        GamWrite(["csv", "-", "columndelimiter", ",", "noescapechar", "true", "quotechar", "\"",
                  "gam", "user", "~User", "signature", "~signature", "html"],
                 action: .setSignaturesFast, input: Data(SignaturesFast.rowsCSV(rows).utf8))
    }

    /// The apps people have given access to their account (9119-9128; _printShowTokens): every account but the suspended
    /// ones (GAM's default, all users), or one person's. CSV `user,clientId,displayText,anonymous,nativeApp,userKey,scopes`,
    /// the scopes space-joined (csv_output_field_delimiter's default). A refusal is ClientAPIAccessDeniedExit, exit 12.
    /// A group's settings (roadmap 4.4, GamGUI's `info_group_settings`): `info group <g> quick fields <list> formatjson`, no
    /// members or aliases, one JSON line. A list would read several, so the group is one address.
    public static func infoGroupSettings(group: String) throws -> GamRead {
        guard isOneAddress(group) else { throw Invalid.argument("'\(group)' isn't one group address") }
        return GamRead(["info", "group", group, "quick", "fields", (["email"] + GroupSettings.table.map(\.key)).joined(separator: ","),
                        "formatjson"])
    }

    /// `update group <g> <GroupAttribute>*` (GamGUI's `update_group_settings`): only the settings that change, in the table's
    /// order, each value one the table offers. An abuse@ or postmaster@ group is refused (GAM writes none of its settings yet
    /// says it did), and so is a list.
    public static func updateGroupSettings(group: String, changes: [String: String]) throws -> GamWrite {
        guard isOneAddress(group), !GroupSettings.skipped(group) else {
            throw Invalid.argument("'\(group)' isn't a group whose settings GAM changes")
        }
        guard !changes.isEmpty else { throw Invalid.argument("no setting to change") }
        for (key, value) in changes where GroupSettings.table.first(where: { $0.key == key })?.values.contains(value) != true {
            throw Invalid.argument("'\(key)' '\(value)' isn't a group setting this app offers")
        }
        let argv = GroupSettings.table.compactMap { row in changes[row.key].map { [row.key, $0] } }.flatMap { $0 }
        return GamWrite(["update", "group", group] + argv, action: .updateGroupSettings)
    }

    // MARK: the closed list of Builder writes (roadmap 5.1, GamGUI #189)

    /// `update user <u> primaryemail <new> noactionifalias`: an alias is refused by GAM (51) rather than rename its owner; a new
    /// name `vfe` is GAM's "make one up", refused here.
    public static func renameUser(email: String, newEmail: String) throws -> GamWrite {
        guard isOneAddress(email), isOneAddress(newEmail) else {
            throw Invalid.argument("the account and its new address are each one full email address")
        }
        if PythonText.lower(String(newEmail.split(separator: "@", maxSplits: 1).first ?? "")) == "vfe" {
            throw Invalid.argument("GAM reads a new address named vfe@ as “make one up”: choose another name")
        }
        if PythonText.lower(PythonText.strip(newEmail)) == PythonText.lower(PythonText.strip(email)) {
            throw Invalid.argument("that is the address the account has now")
        }
        return GamWrite(["update", "user", email, "primaryemail", newEmail, "noactionifalias"], action: .renameUser)
    }

    /// `create admin <holder> <role> customer|org_unit <unit>`: the role by its name as Google keeps it (an `id:`/`uid:` prefix
    /// would skip GAM's check); no org unit is the whole organization, and the top-level unit by any spelling is refused.
    public static func createAdmin(email: String, role: String, orgUnit: String = "") throws -> GamWrite {
        guard isOneAddress(email) else { throw Invalid.argument("'\(email)' isn't one email address") }
        let lower = PythonText.lower(role)
        if PythonText.strip(role).isEmpty || role != PythonText.strip(role) || lower.hasPrefix("id:") || lower.hasPrefix("uid:") {
            throw Invalid.argument("name the role as Google has it, such as _HELP_DESK_ADMIN_ROLE (`print adminroles` lists them)")
        }
        let unit = PythonText.strip(orgUnit)
        if !orgUnit.isEmpty, unit.unicodeScalars.allSatisfy({ $0 == "/" }) || PythonText.lower(unit) == "root" {
            throw Invalid.argument("That is the top-level org unit: leave the org unit blank for the whole organization.")
        }
        return GamWrite(["create", "admin", email, role] + (orgUnit.isEmpty ? ["customer"] : ["org_unit", orgUnit]), action: .createAdmin)
    }

    /// `delete group <g> noactionifalias`: an alias is refused (51) rather than delete the group behind it; one address.
    public static func deleteGroup(group: String) throws -> GamWrite {
        guard isOneAddress(group) else { throw Invalid.argument("'\(group)' isn't one group address") }
        return GamWrite(["delete", "group", group, "noactionifalias"], action: .deleteGroup)
    }

    public static func printTokens(user: String? = nil) throws -> GamRead {
        guard user.map(isOneAddress) ?? true else { throw Invalid.argument("“\(user ?? "")” isn't one email address") }
        return GamRead((user.map { ["user", $0] } ?? []) + ["print", "tokens"])
    }

    /// Every license seat (4498 `gam print licenses`; doPrintLicenses at the 7.52.04 tag), no product named: the audit runs'
    /// license usage (plan F3). CSV `userId,productId,productDisplay,skuId,skuDisplay`, userId lowercased, the display names
    /// from GAM's own table (the ID itself for one it doesn't know). With no product named GAM lists every product it knows
    /// and passes over one Google refuses (invalid, forbidden, invalidArgument) without a word or a code, so a missing product
    /// isn't "no seats". Without the License Manager scope it exits NO_SCOPES_FOR_API_RC (15).
    public static func printLicenses() -> GamRead {
        GamRead(["print", "licenses"])
    }

    /// These accounts' grants, suspended ones included (9119-9128 `gam print tokens ... [<UserTypeEntity>]`; `users <list>` is
    /// convertEntityToList, no suspension filter; _printShowTokens at the 7.52.04 tag): the audit runs' admin token review (plan
    /// F3). The list is one argv element, comma-joined, each one address, lowercased, repeats dropped. CSV as `printTokens`. An
    /// account Google doesn't know is entityUnknownWarning (56 in the domain, 73 outside it) and the rest are read; a refused
    /// token is 12.
    public static func printTokens(users: [String]) throws -> GamRead {
        guard !users.isEmpty else { throw Invalid.argument("a list of accounts is needed") }
        if let bad = users.first(where: { !isOneAddress($0) }) { throw Invalid.argument("Not one address: “\(bad)”") }
        var seen: Set<String> = [], listed: [String] = []
        for address in users.map({ PythonText.lower(PythonText.strip($0)) }) where seen.insert(address).inserted { listed.append(address) }
        return GamRead(["print", "tokens", "users", listed.joined(separator: ",")])
    }

    /// Every admin role assignment, a group's expanded to its member users (1588-1591 `gam print admins ... [recursive]`;
    /// doPrintShowAdmins at the 7.52.04 tag): the admin token review (plan F3). Not `types user`: with `recursive` it drops a
    /// group's row, members and all, before expanding it. CSV PRINT_ADMIN_TITLES; an expanded row has assignedToUser and
    /// assignedToGroup both set; a holder GAM couldn't name has assignedToUnknown True and assignedTo alone, exit 0.
    public static func printAllAdmins() -> GamRead {
        GamRead(["print", "admins", "recursive"])
    }

    /// Every shared drive in the domain, as the admin (doPrintShowSharedDrives: domain admin access): the audit runs' shared
    /// drive members (plan F3). `noorgunits`: no org-unit path lookup, one Directory read fewer. CSV `User,id,name,JSON`. No
    /// drive at all is exit 60 (NO_ENTITIES_FOUND_RC) with the titles: GAM's none.
    public static func printSharedDrives() -> GamRead {
        GamRead(["print", "shareddrives", "noorgunits", "formatjson"])
    }

    /// Every shared drive's own permissions, one row each (doPrintShowSharedDriveACLs, domain admin access): CSV
    /// `User,id,name,createdTime,JSON`, the JSON `{"permission": {...}}`; a drive with none is one row with JSON `{}`
    /// (`shownopermissionsdrives true`). GAM drops a drive whose permissions it can't read without a word or a code
    /// (printShowSharedDriveACLs passes fileNotFound, forbidden and the rest), so the run reads `printSharedDrives` too. The
    /// grammar's `gam print shareddriveacls` line omits shownopermissionsdrives (its `<UserTypeEntity>` form has it);
    /// printShowSharedDriveACLs, which both forms run, takes it.
    public static func printSharedDriveACLs() -> GamRead {
        GamRead(["print", "shareddriveacls", "oneitemperrow", "shownopermissionsdrives", "true", "formatjson"])
    }

    /// The admin role assignments `user` holds directly (1588-1591; doPrintShowAdmins), CSV with `role` and `scopeType`.
    /// Without `recursive`, a role held through a group isn't listed.
    public static func printAdmins(user: String) -> GamRead {
        GamRead(["print", "admins", "user", user])
    }

    // MARK: Google Classroom (read only)
    // GAM reads Classroom with the ADMIN token (buildGAPIObject(CLASSROOM)), so its scopes are picked when the admin token is
    // made, not delegated: without them GAM exits NO_SCOPES_FOR_API_RC (15). A teacher, student or course it can't find is a
    // warning and ENTITY_DOES_NOT_EXIST_RC (56). Read from the 7.51.00 build (doPrintCourses, doPrintCourseParticipants,
    // _getCoursesInfo) by GamGUI, and held to its builders (`argv.json`); never run on a tenant (plan 2026-11-11 E1).

    /// The grammar's <CourseState>, in GamGUI's order (`COURSE_STATES`).
    public enum CourseState: String, CaseIterable, Sendable {
        case active, archived, provisioned, declined, suspended
    }

    /// A class's fields (3332 <CourseFieldName>), never `enrollmentcode`, which lets anyone who has it join the class.
    static let courseFields = "id,name,section,room,coursestate,ownerid,creationtime,updatetime,alternatelink"

    /// A Classroom course ID as Google gives it: ASCII digits, at most 30. GAM reads a comma as a list and `d:` as an alias, so
    /// nothing else is one course.
    public static func isCourseID(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 30 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Classes, read only (3332 `print courses`): by ID, or every class a teacher or a student is in, or every class, in the
    /// given states. CSV `id,JSON`. `ownerEmail` has GAM look up each distinct owner's address, one Directory read per owner:
    /// off for a domain-wide read, whose owners the directory cache already names by `ownerId`. `aliases` adds a
    /// `JSON-aliases` column after `JSON` (one Classroom call per class, in GAM's run), each item an object as the API gives
    /// it, `{"alias": "d:…"}`. `counts` (the audit runs' Classroom, plan F3): `show all countsonly` adds each class's teacher
    /// and student counts to its JSON (`teachers`, `students`), one Classroom list call each per class. GAM counts a roster
    /// Google won't return as 0, without a word (_getCourseAliasesMembers passes notFound and serviceNotAvailable), so a 0 is
    /// never "an empty class".
    public static func printCourses(teacher: String = "", student: String = "", states: [CourseState] = [],
                                    courseIDs: [String] = [], ownerEmail: Bool = true, aliases: Bool = false,
                                    counts: Bool = false) throws -> GamRead {
        var argv = ["print", "courses"]
        if !courseIDs.isEmpty {
            guard teacher.isEmpty, student.isEmpty, states.isEmpty else {
                throw Invalid.argument("Classes by ID take no teacher, student or state filter")
            }
            for id in courseIDs {
                guard isCourseID(id) else { throw Invalid.argument("Not a Classroom course ID: “\(id)”") }
                argv += ["course", id]
            }
        }
        for (keyword, address) in [("teacher", teacher), ("student", student)] where !address.isEmpty {
            guard isOneAddress(address) else { throw Invalid.argument("Not one address: “\(address)”") }
            argv += [keyword, address]
        }
        if !states.isEmpty {
            var seen: Set<CourseState> = []
            argv += ["states", states.filter { seen.insert($0).inserted }.map(\.rawValue).joined(separator: ",")]
        }
        return GamRead(argv + (ownerEmail ? ["owneremail"] : []) + (aliases ? ["aliases"] : [])
                       + (counts ? ["show", "all", "countsonly"] : []) + ["fields", courseFields, "formatjson"])
    }

    /// Every class's teachers and students in the given states, one GAM run (3343 `print course-participants states`): the
    /// same rows as one class's (`courseId,courseName,JSON-teachers,JSON-students`), one per class. A states list is needed.
    public static func printAllCourseParticipants(states: [CourseState]) throws -> GamRead {
        guard !states.isEmpty else { throw Invalid.argument("A states list is needed: every class's people, in some states") }
        var seen: Set<CourseState> = []
        return GamRead(["print", "course-participants", "states",
                        states.filter { seen.insert($0).inserted }.map(\.rawValue).joined(separator: ","), "show", "all", "formatjson"])
    }

    /// One class's teachers and students (3343 `print course-participants`). CSV
    /// `courseId,courseName,JSON-teachers,JSON-students`: one row per class, each `JSON-` cell a list of people.
    public static func printCourseParticipants(courseID: String) throws -> GamRead {
        guard isCourseID(courseID) else { throw Invalid.argument("Not a Classroom course ID: “\(courseID)”") }
        return GamRead(["print", "course-participants", "course", courseID, "show", "all", "formatjson"])
    }

    // MARK: calendar access, as the calendar's user

    public static func printCalendarACLs(email: String, calendar: String = "primary") -> GamRead {
        GamRead(["user", email, "print", "calendaracls", calendar, "formatjson"])
    }

    /// `target` is a scope: a bare email is a user; `group:<email>`, `domain` and `default` pass as-is.
    public static func addCalendarACL(email: String, target: String, role: CalendarRole = .reader, calendar: String = "primary") -> GamWrite {
        GamWrite(["user", email, "add", "calendaracls", calendar, role.rawValue, target], action: .addCalendarACL)
    }

    public static func deleteCalendarACL(email: String, scope: String, calendar: String = "primary") -> GamWrite {
        GamWrite(["user", email, "delete", "calendaracls", calendar, scope], action: .deleteCalendarACL)
    }

    // MARK: calendars, resources, events

    public static func printResources(query: String = "") -> GamRead {
        GamRead(["print", "resources", "fields", "id,name,email,resourcetype,buildingid"] + optional("query", query) + ["formatjson"])
    }

    public static func printUserCalendars(email: String) -> GamRead {
        GamRead(["user", email, "print", "calendars", "fields", calendarFields, "formatjson"])
    }

    /// Every user's calendar list, secondary calendars included.
    public static func printAllCalendars() -> GamRead {
        GamRead(["all", "users", "print", "calendars", "fields", calendarFields, "formatjson"])
    }

    /// The admin form: the ACLs of any calendar id (room or secondary), no impersonation.
    public static func printCalendarACLs(calendarID: String) -> GamRead {
        GamRead(["calendars", calendarID, "print", "calendaracls", "formatjson"])
    }

    /// One calendar's data owner (Google's Calendars resource `dataOwner`, set only for a secondary calendar), read as the
    /// admin as the ACL read is: `calendars.get` with the fields asked (doCalendarsPrintShowSettings). `dataowner` is in GAM's
    /// CALENDAR_SETTINGS_FIELDS_CHOICE_MAP though the grammar's <CalendarSettingsField> (2010-2017) leaves it out; `id` comes
    /// first anyway (`initialField`). Rows `calendarId,JSON`. The calendar delete acts as this owner. GamGUI's
    /// `print_calendar_data_owner` since its #125.
    public static func printCalendarSettings(calendarID: String) -> GamRead {
        GamRead(["calendars", calendarID, "print", "settings", "fields", "id,dataowner", "formatjson"])
    }

    /// The admin form, as `printCalendarACLs(calendarID:)`. Notifications are off by default: the
    /// subscribe makes the calendar appear, which is the point, since people miss the sharing email.
    public static func addCalendarACL(calendarID: String, scope: String, role: CalendarRole = .reader, sendNotifications: Bool = false) -> GamWrite {
        GamWrite(["calendars", calendarID, "add", "calendaracls", role.rawValue, scope]
            + (sendNotifications ? ["sendnotifications", "true"] : []), action: .addCalendarACL)
    }

    public static func deleteCalendarACL(calendarID: String, scope: String) -> GamWrite {
        GamWrite(["calendars", calendarID, "delete", "calendaracls", scope], action: .deleteCalendarACL)
    }

    /// Puts the calendar in the recipient's sidebar; runs as the recipient.
    public static func subscribeCalendar(email: String, calendarID: String, selected: Bool = true) -> GamWrite {
        GamWrite(["user", email, "add", "calendars", calendarID] + (selected ? ["selected", "true"] : []), action: .subscribeCalendar)
    }

    /// **Permanently** deletes a secondary calendar for everyone, acting as an owner (`Calendars.delete`).
    /// GAM's footgun: `remove calendars` deletes it; `delete calendars` would only unsubscribe this user.
    public static func removeCalendar(owner: String, calendarID: String) -> GamWrite {
        GamWrite(["user", owner, "remove", "calendars", calendarID], action: .removeCalendar)
    }

    public static func printEvents(calendarID: String, query: String = "", after: String = "", before: String = "") -> GamRead {
        GamRead(["calendars", calendarID, "print", "events"]
            + optional("query", query) + optional("after", after) + optional("before", before)
            + ["fields", eventFields, "formatjson"])
    }

    /// Re-reads one event by id for the delete preview.
    public static func getEvent(calendarID: String, eventID: String) -> GamRead {
        GamRead(["calendars", calendarID, "print", "events", "eventid", eventID, "fields", eventFields, "formatjson"])
    }

    /// GAM dry-runs `delete events` without `doit`. Deleting a recurring master id drops the series.
    public static func deleteEvent(calendarID: String, eventID: String, doit: Bool = true) -> GamWrite {
        GamWrite(["calendars", calendarID, "delete", "events", "eventid", eventID] + (doit ? ["doit"] : []) + ["sendupdates", "none"], action: .deleteEvent)
    }

    // MARK: lifecycle (offboarding)

    /// A random password and no change prompt: the old password stops working; the mailbox stays live.
    public static func resetPassword(email: String) -> GamWrite {
        GamWrite(["update", "user", email, "password", "random", "changepassword", "off"], action: .resetPassword)
    }

    public static func signOutUser(email: String) -> GamWrite {
        GamWrite(["user", email, "signout"], action: .signOutUser)
    }

    /// `deprovision|deprov [popimap] [signout] [turnoff2sv]` (GamCommands.txt 7930): deletes app
    /// passwords, backup codes and OAuth tokens, then with `signout` ends every session. Not
    /// `turnoff2sv` (it weakens a locked account nobody needs to sign in to); not `popimap` (POP and
    /// IMAP need a credential, and all are revoked here).
    public static func deprovisionUser(email: String) -> GamWrite {
        GamWrite(["user", email, "deprovision", "signout"], action: .deprovisionUser)
    }

    /// `service` is a `<DataTransferServiceList>`: one service (`drive`, `calendar`) or a comma-joined
    /// list riding as one element. Both in one transfer avoids Google's 409 "transfer already in
    /// progress" when two transfers for the same user overlap. `releaseResources` is a Calendar parameter
    /// (`RELEASE_RESOURCES`, GamGUI #160), a bare word after the privacy: GAM refuses it, a usage error, when
    /// Calendar isn't in `service`. Nothing here sends it yet.
    public static func createDataTransfer(oldOwner: String, service: String, newOwner: String, privacy: TransferPrivacy? = nil,
                                          releaseResources: Bool = false) -> GamWrite {
        GamWrite(["create", "datatransfer", oldOwner, service, newOwner] + (privacy.map { [$0.rawValue] } ?? [])
                 + (releaseResources ? ["release_resources"] : []), action: .createDataTransfer)
    }

    /// Transfers are asynchronous; the CSV carries `overallTransferStatusCode`.
    public static func printDataTransfers(oldOwner: String = "") -> GamRead {
        GamRead(["print", "datatransfers"] + optional("olduser", oldOwner))
    }

    /// Removes the leaver from every other user's primary calendar (GAM loops over all users).
    public static func removeAllCalendarACLs(email: String) -> GamWrite {
        GamWrite(["all", "users", "delete", "calendaracls", "primary", email], action: .removeAllCalendarACLs)
    }

    /// GAM's `add event` defaults `sendupdates` to none, so an attendee would get no invitation;
    /// `[<EventNotificationAttribute>]` follows the attributes (GamCommands.txt 6486).
    public static func addCalendarEvent(calendar: String, summary: String, start: String, end: String, description: String = "", attendee: String = "") -> GamWrite {
        GamWrite(["user", calendar, "add", "event", "primary", "summary", summary, "start", "allday", start, "end", "allday", end]
            + optional("description", description)
            + (attendee.isEmpty ? [] : ["attendee", attendee, "sendupdates", "all"]), action: .addCalendarEvent)
    }

    public static func deleteUser(email: String) -> GamWrite {
        GamWrite(["delete", "user", email], action: .deleteUser)
    }

    public static func undeleteUser(email: String) -> GamWrite {
        GamWrite(["undelete", "user", email], action: .undeleteUser)
    }

    // MARK: onboarding: a Google Tasks checklist on the assignee and a welcome email

    /// `returnidonly`, so the output is just the new list's id to attach tasks to.
    public static func createTaskList(assignee: String, title: String) -> GamWrite {
        GamWrite(["user", assignee, "create", "tasklist", "title", title, "returnidonly"], action: .createTaskList)
    }

    public static func createTask(assignee: String, taskListID: String, title: String, notes: String = "") -> GamWrite {
        GamWrite(["user", assignee, "create", "task", taskListID, "title", title] + optional("notes", notes), action: .createTask)
    }

    public static func sendEmail(to: String, subject: String, body: String, html: Bool = true) -> GamWrite {
        GamWrite(["sendemail", "to", to, "subject", subject, "message", body] + (html ? ["html"] : []), action: .sendEmail)
    }

    // MARK: Gmail: signature, delegates, vacation

    public static func setSignature(email: String, signature: String, html: Bool = true) -> GamWrite {
        GamWrite(["user", email, "signature", signature] + (html ? ["html"] : []), action: .setSignature)
    }

    /// Text output; `show signature` has no `formatjson`.
    public static func showSignature(email: String) -> GamRead {
        GamRead(["user", email, "show", "signature"])
    }

    /// The stored signature verbatim, as CSV (GamGUI's `print_signature`; printShowSignature's print mode, where `compact`
    /// would strip its line breaks): what ChangeCore reads and keeps before a signature is replaced (`Signature.exact`).
    /// `show signature` is the display form, whose reader strips each line.
    public static func printSignature(email: String) -> GamRead {
        GamRead(["user", email, "print", "signature"])
    }

    public static func addDelegate(email: String, delegate: String) -> GamWrite {
        GamWrite(["user", email, "add", "delegate", delegate], action: .addDelegate)
    }

    public static func removeDelegate(email: String, delegate: String) -> GamWrite {
        GamWrite(["user", email, "delete", "delegate", delegate], action: .removeDelegate)
    }

    /// Plain CSV with a `delegateAddress` column: `print delegates` refuses `formatjson`.
    public static func printDelegates(email: String) -> GamRead {
        GamRead(["user", email, "print", "delegates"])
    }

    /// GAM's `vacation` doesn't replace the settings: it overwrites only the fields named and writes the
    /// rest back. So every setting is named (each flag explicitly, a missing date as `Started` or
    /// `NotSpecified`, GamCommands.txt 8348), or a leftover "domain only" or past end date survives.
    public static func setVacation(
        email: String, subject: String, message: String, html: Bool = true,
        start: String = "", end: String = "", contactsOnly: Bool = false, domainOnly: Bool = false
    ) -> GamWrite {
        GamWrite(["user", email, "vacation", "on", "subject", subject, "message", message] + (html ? ["html"] : [])
            + ["contactsonly", contactsOnly ? "true" : "false", "domainonly", domainOnly ? "true" : "false",
               "start", start.isEmpty ? "Started" : start, "end", end.isEmpty ? "NotSpecified" : end], action: .setVacation)
    }

    public static func vacationOff(email: String) -> GamWrite {
        GamWrite(["user", email, "vacation", "off"], action: .vacationOff)
    }

    /// Text output; `show vacation` has no `formatjson`.
    public static func showVacation(email: String) -> GamRead {
        GamRead(["user", email, "show", "vacation"])
    }

    // MARK: Gmail: forwarding

    public static func addForwardingAddress(email: String, address: String) -> GamWrite {
        GamWrite(["user", email, "add", "forwardingaddress", address], action: .addForwardingAddress)
    }

    public static func printForwardingAddresses(email: String) -> GamRead {
        GamRead(["user", email, "print", "forwardingaddresses"])
    }

    /// Forwards to an address already added and verified.
    public static func setForward(email: String, address: String, action: ForwardAction = .keep) -> GamWrite {
        GamWrite(["user", email, "forward", "on", action.rawValue, address], action: .setForward)
    }

    public static func forwardOff(email: String) -> GamWrite {
        GamWrite(["user", email, "forward", "off"], action: .forwardOff)
    }

    // MARK: message search (read-only)

    /// Finds messages in one mailbox by a Gmail search. `headers all` shows `Return-Path` and
    /// `Received`, so a bounce sender is visible; spam and trash are included, since bounces land there.
    /// The output is CSV: `print messages` refuses `formatjson`. `max` is GamGUI's `messageCap` but for the compromised-
    /// account check's scheduled sends, which lists every one (`Compromised.ScheduledSend.cap`).
    public static func searchMessages(email: String, query: String = "", detail: MessageDetail = .headers,
                                      max: Int = messageCap) -> GamRead {
        let shown: [String] = switch detail {
        case .summary: ["showlabels", "showdate", "showsize", "showsnippet"]
        case .headersAndBody: ["headers", "all", "showbody", "showlabels", "showdate"]
        case .headers: ["headers", "all", "showlabels", "showdate"]
        }
        return GamRead(["user", email, "print", "messages"] + optional("query", query)
            + ["includespamtrash", "max_to_print", String(max)] + shown)
    }

    // MARK: aliases

    public static func createUserAlias(alias: String, email: String) -> GamWrite {
        GamWrite(["create", "alias", alias, "user", email], action: .createUserAlias)
    }

    public static func deleteAlias(alias: String) -> GamWrite {
        GamWrite(["delete", "alias", alias], action: .deleteAlias)
    }

    // MARK: groups and domains

    public static func printGroups(fields: [String] = []) -> GamRead {
        GamRead(["print", "groups", "fields", (fields.isEmpty ? groupListFields : fields).joined(separator: ","), "formatjson"])
    }

    /// The groups `member` belongs to, as CSV with an `email` column.
    public static func printGroups(member: String) -> GamRead {
        GamRead(["print", "groups", "member", member])
    }

    public static func createGroup(email: String, name: String = "", description: String = "") -> GamWrite {
        GamWrite(["create", "group", email] + optional("name", name) + optional("description", description), action: .createGroup)
    }

    public static func printGroupMembers(group: String) -> GamRead {
        GamRead(["print", "group-members", "group", group, "formatjson"])
    }

    /// The primary and secondary domains, each with its aliases: what counts as internal.
    public static func printDomains() -> GamRead {
        GamRead(["print", "domains", "formatjson"])
    }

    public static func addGroupMember(group: String, member: String, role: GroupRole = .member) -> GamWrite {
        GamWrite(["update", "group", group, "add", role.rawValue, member], action: .addGroupMember)
    }

    public static func removeGroupMember(group: String, member: String) -> GamWrite {
        GamWrite(["update", "group", group, "remove", member], action: .removeGroupMember)
    }

    // MARK: a read's table to a new Google Sheet (plan F4)

    /// Appended to a `print` or `report` read: GAM writes the read's CSV to a new Google Sheet instead of printing it (GamGUI's
    /// `todrive_args`, held to `argv.json`). Grammar `todrive <ToDriveAttribute>*`, read from GAM's
    /// `CSVPrintFile.GetTodriveParameters` at 7.52.04. No `tduser`: the Sheet goes in the connected admin's own Drive (GAM's
    /// `_getAdminEmail`, the sign-in token's address). No `tdshare`, `tdalert` or `tdnotify`: it's shared with nobody.
    /// `tdnobrowser true`: GAM would otherwise open the Sheet in this Mac's browser itself (`webbrowser.open`); `tdnoemail
    /// true`: `todrive_noemail` follows `no_browser`, and GAM would email the link through the admin's Gmail. `title` names
    /// the file, one element (GAM takes any string, even empty, so an empty one is left out and GAM names it
    /// `<domain> - <list>`). Only `exportToSheet` appends it, and only the executor runs that.
    public static func todriveArgs(title: String = "") -> [String] {
        ["todrive"] + optional("tdtitle", title) + ["tdnobrowser", "true", "tdnoemail", "true"]
    }

    /// `token` as GAM reads a keyword (`getArgument`, 7.52.04: lowercased, every `_` dropped), stripped first as GamGUI's
    /// `as_keyword` strips (GAM doesn't: the stricter side). `to_drive` and `ToDrive` are `todrive` to GAM: compare this, never
    /// the raw spelling.
    public static func asKeyword(_ token: String) -> String {
        String(String.UnicodeScalarView(PythonText.lower(PythonText.strip(token)).unicodeScalars.filter { $0 != "_" }))
    }

    /// Whether GAM would read any element of `argv` as `todrive`: a read that writes a Sheet (GamGUI's `carries_todrive`). Every
    /// read path refuses one (`UserAccess.catalogRead`, `AuditRuns.isAuditRead`); only `exportToSheet` adds the word, as a write.
    public static func carriesToDrive(_ argv: [String]) -> Bool {
        argv.contains { asKeyword($0) == "todrive" }
    }

    /// Whether `argv` is a read GAM takes `todrive` on at its end: a `print` or `report` command, its verb first (`print users`)
    /// or after an entity (`user <x> print delegates`, `all users print …`), as the mock reads it; or an entity's `list` with
    /// nothing after it (`user <x> list`): GAM's `_doList` (7.52.04) reads `todrive` only right after `list`, before `data`, so
    /// appended to a bare entity list it's there. Never the top-level `gam list <EntityList>`, which takes `todrive` only before
    /// its entity list, never at the end (review of #199). Only these print a CSV (CSVPrintFile).
    public static func takesToDrive(_ argv: [String]) -> Bool {
        argv.first == "print" || argv.first == "report" || (argv.count > 2 && argv[2] == "print")
            || (argv.count == 3 && argv[2] == "list")
    }

    /// A read's table to a new Google Sheet (plan F4, GamGUI's `export_to_sheet`): `read`'s exact argv, then `todriveArgs(title:)`.
    /// GAM runs the read again and uploads what it gets then, so it's a write: only ChangeCore runs it, from its held preview.
    /// Refuses a read that isn't a `print` or `report` read and one that already carries `todrive` in any spelling GAM reads
    /// (`carriesToDrive`): a second file, made under GAM's own defaults (its browser, its email).
    public static func exportToSheet(_ read: GamRead, title: String) throws(Invalid) -> GamWrite {
        guard takesToDrive(read.argv) else { throw .argument("Only a print or report read, or an entity's list, can go to a Google Sheet") }
        guard !carriesToDrive(read.argv) else {
            throw .argument("This read already says todrive, so it can't be exported again: build it without that word")
        }
        return GamWrite(read.argv + todriveArgs(title: title), action: .exportToSheet)
    }

    // MARK: the Builder's catalog reads (invariant 3's one door from the catalog)

    /// A catalog command's read with `values` (by slot key), as GamGUI's generic read builder puts it together: each value trimmed
    /// as Python trims and one argv element, an optional one left out when empty. Refuses a command that isn't runnable, a
    /// required value left empty (where GamGUI would pass an empty argument along) and a value that's a keyword that changes things
    /// (`CommandCatalog.valueKeywordsThatChange`: GamGUI #174's `WRITE_KEYWORDS` and `doit`), which GAM would read as a write.
    public static func catalogRead(_ command: CommandCatalog.Command, values: [String: String]) throws(Invalid) -> GamRead {
        guard command.runnable else {
            throw .argument(command.sensitive ? "\(command.name) is a download or a secret: it runs from the Builder once its run is audited"
                            : "\(command.name) isn't a command that only reads, so the Builder doesn't run it")
        }
        func value(_ key: String) -> String { PythonText.strip(values[key] ?? "") }
        if let missing = command.slots.first(where: { $0.required && value($0.key).isEmpty }) {
            throw .argument("Fill in \(missing.label)")
        }
        if let keyword = command.slots.first(where: { CommandCatalog.valueChangesThings(value($0.key)) }) {
            throw .argument("\(keyword.label) can't be “\(value(keyword.key))”: GAM reads that as a keyword that changes things, and the Builder only reads")
        }
        var argv: [String] = []
        for part in command.template {
            switch part {
            case .literal(let word): argv.append(word)
            case .required(let key): argv.append(value(key))
            case .optional(let key): if !value(key).isEmpty { argv.append(value(key)) }
            case .optionalPair(let key, let prefix): if !value(key).isEmpty { argv += [prefix, value(key)] }
            }
        }
        return GamRead(argv)
    }

    /// `[keyword, value]`, or nothing when `value` is empty.
    private static func optional(_ keyword: String, _ value: String) -> [String] {
        value.isEmpty ? [] : [keyword, value]
    }
}
