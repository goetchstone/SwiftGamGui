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

    /// `deprovision|deprov [popimap] [signout] [turnoff2sv]` (GamCommands.txt 7899): deletes app
    /// passwords, backup codes and OAuth tokens, then with `signout` ends every session. Not
    /// `turnoff2sv` (it weakens a locked account nobody needs to sign in to); not `popimap` (POP and
    /// IMAP need a credential, and all are revoked here).
    public static func deprovisionUser(email: String) -> GamWrite {
        GamWrite(["user", email, "deprovision", "signout"], action: .deprovisionUser)
    }

    /// `service` is a `<DataTransferServiceList>`: one service (`drive`, `calendar`) or a comma-joined
    /// list riding as one element. Both in one transfer avoids Google's 409 "transfer already in
    /// progress" when two transfers for the same user overlap.
    public static func createDataTransfer(oldOwner: String, service: String, newOwner: String, privacy: TransferPrivacy? = nil) -> GamWrite {
        GamWrite(["create", "datatransfer", oldOwner, service, newOwner] + (privacy.map { [$0.rawValue] } ?? []), action: .createDataTransfer)
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
    /// `[<EventNotificationAttribute>]` follows the attributes (GamCommands.txt 6469).
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
    /// `NotSpecified`, GamCommands.txt 8286), or a leftover "domain only" or past end date survives.
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
    /// The output is CSV: `print messages` refuses `formatjson`.
    public static func searchMessages(email: String, query: String = "", detail: MessageDetail = .headers) -> GamRead {
        let shown: [String] = switch detail {
        case .summary: ["showlabels", "showdate", "showsize", "showsnippet"]
        case .headersAndBody: ["headers", "all", "showbody", "showlabels", "showdate"]
        case .headers: ["headers", "all", "showlabels", "showdate"]
        }
        return GamRead(["user", email, "print", "messages"] + optional("query", query)
            + ["includespamtrash", "max_to_print", String(messageCap)] + shown)
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

    /// `[keyword, value]`, or nothing when `value` is empty.
    private static func optional(_ keyword: String, _ value: String) -> [String] {
        value.isEmpty ? [] : [keyword, value]
    }
}
