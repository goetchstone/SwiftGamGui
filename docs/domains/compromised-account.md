# Compromised account

**One line:** for a person who stays employed but whose account was taken over: Check Account reads what an attacker
commonly changes (and changes nothing), the operator ticks what to undo, and the lock plus the picks run as one
ChangeCore preview, the person's address typed. Built 2026-10-19 (slice 1); the sign-in and app-grant reports are
slice 2. The plan and its defaults: [docs/plans/2026-10-19-compromised-account.md](../plans/2026-10-19-compromised-account.md).

**Owns invariants:** #1 (each pick one argv element: a delegate or send-as address must be one plain address, a filter
ID list offboarding's checked one), #2 (one held preview, the precondition at the run), #10 (nothing from Siri or a
model: the screen only).

**Enforcement home:** `Packages/GamKit/Tests/GamEngineTests/CompromisedTests.swift` (the core and the mock),
`Packages/GamKit/Tests/DirectoryStoreTests/CompromisedChangesTests.swift` (the check, the plan and the run against the
strict mock), `NativeArgvTests` (each new argv), `WriteRouteTests.onlyTheRoutineLoosensTheRunsRules` (this model may
let only `requires` stop a step; it may not tolerate failures).

## Files
- `Packages/GamKit/Sources/GamEngine/Compromised.swift`: the pure core. `Step` (names shared with `Offboarding.Step`),
  `steps(...)` (each `Planned` one `GamWrite`), `header`, `whatStopsWhat`, and the reads in words: `Filter`,
  `Forwarding`, `ForwardingAddress`, `SendAs`, `AdminRole`, `Account`, `findings`.
- `Packages/GamKit/Sources/Directory/CompromisedChanges.swift`: the model (check, plan, run, stop).
- `Packages/GamKit/Sources/Directory/UserAccess.swift`: the check's reads (`compromisedAccount`, `filters`, `forwarding`,
  `forwardingAddresses`, `sendAs`, `adminRoles`; `delegates` is offboarding's).
- `App/CompromisedView.swift` (sidebar "Compromised"); `CompromisedConfirmSheet` in `App/ChangePreviewSheet.swift`, where
  every confirmation is made (`WriteRouteTests`).

## How it works
0. **From a person's page** (the operator, 2026-10-19: "a button to do that for anyone"): Users → Actions → **Secure
   Account…** hands the address to this screen (`ContentView.compromisedPerson`), which starts a new form for it
   (`Form(person:)`: nothing ticked, not even the reset) and checks it. Users holds no reference to this model
   (`WriteRouteTests.onlyItsScreenReachesTheCompromisedModel`).
1. **Check Account:** `info user P fields <Compromised.accountFields> formatjson` first (an alias reads as its owner; a
   failure stops the check, in GAM's words), then at once: `print filters labelidsonly formatjson`, `print forward`,
   `print forwardingaddresses`, `print delegates`, `print sendas verifyonly`, `print admins user P`. Each failure is said
   beside its list, never taken as "none". `findings` says what to look at first. The connected admin as P is shown and
   blocks the plan.
2. **Pick:** a box per filter (delete), delegate (remove) and send-as address but the primary (remove). None ticked.
3. **Preview:** `steps` in run order: reset, clear recovery (switched, off), sign-out, forwarding off, the filters (one
   command), each delegate, each send-as address, IMAP off and POP off (switched, on). "Password already reset" ticks
   the reset as done. When the reset runs, every other step `requires` it; otherwise nothing stops anything.
   `stopsAtAccountWideFailure: false`: a refused sign-out (the admin token's scope) mustn't stop forwarding off (the
   service account's). The person's address is typed; ten steps with a destructive one also ask for `confirm`.
4. **Run:** the precondition reads P fresh (`info user`): the same primary address, suspension and admin flags, and
   not the connected admin, or nothing runs. Stop between steps. Then the account is **checked again**, and ticks on
   what's gone are dropped. Preview the Rest ticks the lock steps that succeeded as done.

## Grammar and source (GAM 7.48.30)
| Command | Grammar | Source |
|---|---|---|
| `user P print forward` | 8003 | printShowForward: `User,forwardEnabled,forwardTo,disposition` |
| `user P print forwardingaddresses` | 7997 | printShowForwardingAddresses: `User,forwardingEmail,verificationStatus` |
| `user P print sendas verifyonly` | 8297 | printShowSendAs: each signature a bool with `verifyonly` |
| `user P delete sendas S` | 8293 | deleteInfoSendAs: an <EmailAddressEntity> split on commas and whitespace |
| `print admins user P` | 1579 | doPrintShowAdmins: PRINT_ADMIN_TITLES; `_SEED_ADMIN_ROLE` is Super Admin; no group roles without `recursive` |
| `user P delete delegate D` | 7919 | processDelegates: Gmail's notFound for one they don't have, exit 50 |
| `info user P fields …recoveryPhone,isEnforcedIn2Sv…` | 5780-5810 | USER_FIELDS_CHOICE_MAP |

## Gotchas / mock-lies traps
- **The mock's Gmail reads act as the person** (`gmail_read`): a non-user fails at the token (exit 50), `nogmail/<u>` is
  exit 73 with the titles alone, and any option the app doesn't send isn't modelled. Until 2026-10-19 `print
  forwardingaddresses` answered `fwd@example.com` for anyone, and removing a delegate the person didn't have passed.
- **carol@ is the mock's taken-over account:** forwarding on to carol.home@example.org, two forwarding addresses (one
  pending), three filters (two forward), helpdesk@ as a delegate, billing.desk@example.net as a send-as address, and a
  recovery email and phone (`info_user_carol.json`, so the directory's reports don't change). alice@ is the super
  admin in `print admins`.
- **`forward` keeps state** (`GAM_MOCK_STATE/forward/<u>`), so `print forward` after `forward off` says off.
- **Not modelled, for the live check to tell:** Gmail's exact words for a refused send-as delete; whether `print
  admins user` lists a role held through a group (not without `recursive`, per the source).
- **User labels show as IDs** (`labelidsonly`): the system labels an attacker's filter uses are named.
- **"Already done" belongs to one person** (review 2026-10-19): Preview the Rest ticks the lock steps that succeeded,
  and those ticks once carried to the next person typed, whose plan then skipped the reset and the sign-out. Now a new
  address clears every tick and pick, and `plan` refuses lock steps ticked by another person's run (`Form.restOf`).
- **A removal is one address GAM acts on as given** (`GamCommands.isOneAddress`): GAM reads `Name <a@b>` as `a@b` and
  `id:`/`uid:` as an ID, so those are refused too.

## Testing / live verification
`swift test --package-path Packages/GamKit --filter "Compromised|NativeArgv"`.

**L1 (read-only, the operator's go):** Search the taken-over mailbox for `in:sent newer_than:3d`: the phish is there, its
Bcc list matches the message's own. Then Check Account on the real taken-over account: every list matches what the Admin
console and Gmail's settings show (filters, forwarding, delegates, send-as, recovery, 2SV, roles). Nothing runs.

**L2 (the operator's yes in chat for "secure P"):** tick the reset as done if it was; tick what the attacker made; run.
Then in Google: sessions ended, no app passwords or connected apps, forwarding off, the ticked filters, delegates and
send-as addresses gone, IMAP and POP off. Mark the README rows confirmed.

## Search a mailbox (slice 3)
- Users → a person → Mail → **Search this mailbox**: GamGUI's `searchMessages` (`print messages query <q> includespamtrash
  max_to_print 50 headers all showlabels showdate`), read by `MailboxSearch` (GamEngine) one row per message with
  `MessageRecipients`' header rules: To, Cc and Bcc by name with GAM's numbered repeats, never `Delivered-To`. The query
  starts as `in:sent newer_than:3d`: a taken-over account's Sent mail shows the phishing and its Bcc list. None found is
  GAM's exit 60, read as no messages; a read past the runner's cap is incomplete, never all there is.
- `MailboxSearches` (Directory) keeps each person's last search for the tenant, the last eight people.
- **The mock:** the Phishing screen's strict `print messages` handler answers it too, for the terms it models
  (`rfc822msgid:`, `in:`, `from:`, `to:`, and `newer_than:`, a known lie: the fixture dates are fixed); any other term, a
  glob character, or a message whose headers the fixtures lack is not modelled. The canned pair of rows that answered
  every other `print messages` until 2026-10-19 is gone.
- **Not modelled, for the live check to tell:** Gmail's own search semantics beyond those terms.

## Next
- Slice 2: `report login user P` and `report token user P events authorize` as tables (time, event, IP; app and scopes).
- Not built (the plan says why): 2SV off, suspend, deleting forwarding addresses, a signature check.
