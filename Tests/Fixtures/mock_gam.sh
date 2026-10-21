#!/bin/sh
# Mock `gam` binary for offline tests. Behavior is driven by the argument vector and env vars set by
# the test:
#   GAM_MOCK_FIXTURES  - directory holding the *.json fixtures to echo back
#   GAM_MOCK_REFRESH   - if set, simulate an OAuth token refresh by rewriting oauth2.txt in GAMCFGDIR
#   GAM_MOCK_ARGV_LOG  - if set, append every invocation's argv to this file (tests/helpers.py reads it)
#   GAM_MOCK_STATE     - if set, a directory where the mock keeps settings between calls the way GAM
#                        merges into them (`vacation`, `signature`; the `gam_state` fixture), and the
#                        accounts `create user` made (`created`). A number in its
#                        `new_account_lag` file makes each account `create user` makes "still being set
#                        up by Google" for that many per-user calls (signature, calendar subscribe, task
#                        list), each failing as it did live — see still_provisioning. (A file, not an env
#                        var: the runner passes gam only an allowlisted environment.)
#
# The mock must fail the way real GAM fails: one more permissive than GAM turns a live break into a
# green test (CLAUDE.md, "the mock lies"). So:
#   - every call except `version` must find the credentials materialized in $GAMCFGDIR;
#   - each write the app issues has a STRICT handler accepting only the argv shape the vendored grammar
#     (gamgui/resources/gam7/GamCommands.txt) allows for it, and failing a malformed one the way GAM
#     does a usage error (echo the command, "ERROR: ...", exit 2);
#   - anything unhandled FAILS. Add a handler for a new command; never make the catch-all succeed.
# Failure triggers, by argument substring: *missing*/*nonexistent* -> "Does not exist" for the user,
# group, calendar, event or delegate (on `create user`'s org unit, GAM's "Invalid Organizational Unit");
# *exists* -> GAM's "Create Failed: Duplicate" on create, and "already exists" on a delegate add;
# plus USERLIMIT (no license left for a new account), SENDFAIL, SUBFAIL, CONFLICT409,
# FAILME, OWNACL, SWEEPFAIL, SWEEPBENIGN, SWEEPMIXED, SWEEPSLOW, SIGNOUTFAIL, INFOREFUSED (see each handler). The stderr wording
# and exit codes are GAM7's shape (2 usage error, 50 action failed, 51 action not performed, 56 does
# not exist) written from its source conventions, not captured from a tenant — only a live capture
# (plan Phase 8) proves them.
#
# The per-user reads (info user, show vacation/signature, print delegates, print groups member) answer for
# THAT user: each fixture user (mock_gam/print_users.json) has different data, and an address that isn't a
# user fails as GAM fails. Answering Alice's data for anyone let five wrong-target reads pass the whole
# suite (failure-log 2026-09-23).

set -eu

if [ -n "${GAM_MOCK_ARGV_LOG:-}" ]; then
  # NUL-separated (argv can't contain NUL): the arg count, then each arg.
  printf '%s\0' "$#" "$@" >> "$GAM_MOCK_ARGV_LOG"
fi

ARGS="$*"

usage_error() {  # GAM's usage error: the command line, then the reason; USAGE_ERROR_RC
  printf 'Command: gam %s\n\nERROR: %s\n' "$ARGS" "$1" 1>&2
  exit 2
}
missing_arg() { usage_error "Missing argument: Expected <$1>"; }
empty_arg() { usage_error "Empty argument: Expected <Non-empty $1>"; }
invalid_arg() { usage_error "Invalid argument: $1"; }
invalid_choice() { usage_error "Invalid choice ($1): Expected <$2>"; }
does_not_exist() {  # <entity> <name>; ENTITY_DOES_NOT_EXIST_RC
  printf '%s: %s, Does not exist\n' "$1" "$2" 1>&2
  exit 56
}
check_exists() {  # <entity> <name>: the *missing*/*nonexistent* trigger
  case "$2" in *missing*|*nonexistent*) does_not_exist "$1" "$2" ;; esac
}

in_directory() { grep -qF "\"primaryEmail\": \"$1\"" "$GAM_MOCK_FIXTURES/print_users.json"; }
# A directory user, or an account `create user` made while the mock keeps state: GAM can act as either.
known_user() { in_directory "$1" || { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/created/$1" ]; }; }
# A per-user Gmail/Calendar command acts AS the user, so GAM first needs a token for that address. For
# one that isn't a user the token request fails, and GAM reports the token endpoint's words against it
# (handleOAuthTokenError -> entityActionFailedWarning, ACTION_FAILED_RC; read from the vendored build).
not_a_user() {  # <address> <Show|Print>
  printf 'User: %s, User:, %s Failed: invalid_grant: Invalid email or User ID\n' "$1" "$2" 1>&2
  exit 50
}
# GAM 7.48.30's form of the same refusal (handleOAuthTokenError -> entityActionFailedWarning([USER, x, USER, None]) as
# formatKeyValueList joins it), seen live for a set on 2026-09-30 (onboarding.json): "User: x, User Set Failed: ...".
# not_a_user's "User:, " form is older and still used by the handlers before the Phishing screen's (a follow-up).
token_refused() {  # <address> <Action>
  printf 'User: %s, User %s Failed: invalid_grant: Invalid email or User ID\n' "$1" "$2" 1>&2
  exit 50
}
need_user() {  # <address> <Show|Print>: a fixture-directory user, or one the mock keeps state for
  in_directory "$1" && return 0
  if [ -n "${GAM_MOCK_STATE:-}" ] && { [ -e "$GAM_MOCK_STATE/vacation/$1" ] || [ -e "$GAM_MOCK_STATE/delegates/$1" ]; }; then
    return 0
  fi
  not_a_user "$1" "$2"
}
# A just-created account Google hasn't finished setting up. Live, 2026-09-30, a signature set 1 s after
# `create user` failed "User: x, User Set Failed: access_denied: Requested client not authorized"
# (exit 50) and a calendar subscribe 7 s after it "User: x, Calendar Service/App not enabled" (exit
# 73); both succeed once Google catches up. `create user` arms $GAM_MOCK_STATE/new_account_lag of them.
still_provisioning() {  # <user>: true, one fewer left, while the account is still being set up
  f="${GAM_MOCK_STATE:-}/provisioning/$1"
  { [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$f" ]; } || return 1
  n=$(cat "$f")
  if [ "$n" -le 1 ]; then rm -f "$f"; else echo $((n - 1)) > "$f"; fi
  return 0
}
not_ready_token() {  # <user> <Entity Action>: Google won't issue a token to act as the new account yet
  printf 'User: %s, %s Failed: access_denied: Requested client not authorized\n' "$1" "$2" 1>&2
  exit 50
}
canned_delegates() {  # <user>: each fixture user's own mail delegates, one per line
  case "$1" in
    alice@example.com) printf 'assistant@example.com\nbackup@example.com\n' ;;
    carol@example.com) printf 'helpdesk@example.com\n' ;;
  esac
}
delegates_of() {  # <user>: the current list — with GAM_MOCK_STATE, the stored one once a write touched it
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/delegates/$1" ]; then
    cat "$GAM_MOCK_STATE/delegates/$1"
  else
    canned_delegates "$1"
  fi
}
has_delegate() { delegates_of "$1" | grep -qixF -- "$2"; }   # Gmail compares addresses case-insensitively
# GAM's CSV (failure-log 2026-10-10, "GAM's CSV escapes"). GAM 7.48.22 writes every CSV with CPython 3.14's
# csv module in setDialect's dialect (gam/__init__.py:8830-8839): comma, double quote, quotes doubled, a
# backslash escape (csv_output_no_escape_char is off by default), QUOTE_MINIMAL, rows ending in "\n". So a
# backslash in a value is doubled, and a value holding a comma or a quote is quoted, its quotes doubled.
# A value here is one line (a JSON cell never holds a raw newline); one with CR or LF is refused.
CR=$(printf '\r')
gam_cell() {  # <value>: one CSV field as GAM writes it
  case "$1" in *"$CR"*|*'
'*) echo "ERROR: mock: a CSV value with a line break isn't modelled" 1>&2; exit 2 ;; esac
  escaped=$(printf '%s' "$1" | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/""/g')
  case "$1" in *[,\"]*) printf '"%s"' "$escaped" ;; *) printf '%s' "$escaped" ;; esac
}
gam_row() {  # <value>...: one CSV row as GAM writes it
  separator=""
  for value in "$@"; do printf '%s' "$separator"; gam_cell "$value"; separator=","; done
  printf '\n'
}
# `print … formatjson` (GAM's SetJSONTitles): a header of the key columns and `JSON`, then per record its
# key values and the record as GAM prints it, json.dumps(…, ensure_ascii=False, sort_keys=True). The data
# files hold one record per line in exactly that form (scripts/gen_fixtures.py refuses one that isn't, and
# any formatjson output whose bytes differ from Python's csv writer in GAM's dialect).
json_text() {  # <key> <json line>: a top-level string value holding no quote or backslash (an address, an ID)
  found=$(printf '%s' "$2" | sed -n "s/.*\"$1\": \"\([^\"\\\\]*\)\".*/\1/p")
  [ -n "$found" ] || { echo "ERROR: mock: no $1 in a data line" 1>&2; exit 2; }
  printf '%s' "$found"
}
print_formatjson() {  # <key column> <data file>: every record in the file
  echo "$1,JSON"
  while IFS= read -r record; do gam_row "$(json_text "$1" "$record")" "$record"; done < "$GAM_MOCK_FIXTURES/$2"
}
not_modelled() { echo "ERROR: mock: $1 isn't modelled" 1>&2; exit 2; }
# The tenant's groups, in the order GAM lists them (by address), and their members: mock_gam/groups.json
# and group_members.json. One data set for every group read, held together by MockGroupsTests: each count
# is its member list's length, and each directory user's `print groups member` names exactly the groups
# listing them (alice: sales, staff; bob: staff; carol: it; dana: none). allhands' twelve members aren't in
# the mock's directory, so `print groups member` refuses them. Members cover every role, a nested GROUP (its
# address only; GAM doesn't expand it without `recursive`), a suspended USER, and the CUSTOMER row (everyone
# in the organization), which has no address (shapes approximate: not captured from a tenant). With
# GAM_MOCK_STATE, a group a write changed keeps its new list in $GAM_MOCK_STATE/groups/<group>, and every
# group read (its members, a person's groups, the list's counts) follows it.
is_group() {  # <address>, already lowercased
  grep -qF "\"email\": \"$1\", " "$GAM_MOCK_FIXTURES/groups.json"
}
members_of() {  # <group, lowercased>: its member records, one per line, as a write left them
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/groups/$1" ]; then
    cat "$GAM_MOCK_STATE/groups/$1"
  else
    grep -F "\"group\": \"$1\", " "$GAM_MOCK_FIXTURES/group_members.json" || true
  fi
}
member_record() { members_of "$1" | grep -F "\"email\": \"$2\", " || true; }   # <group> <member>, lowercased
# The tenant's own domains (mock_gam/domains.json): its primary, a secondary, and a domain alias.
tenant_domain() {  # <domain, lowercased>
  grep -qF -e "\"domainName\": \"$1\"" -e "\"domainAliasName\": \"$1\"" "$GAM_MOCK_FIXTURES/domains.json"
}
# `todrive <ToDriveAttribute>*` (grammar 655) after a print/report read: only the shape the Builder emits
# (GAMCommands.todrive_args) — `todrive [tduser <EmailAddress>] [tdtitle <String>]`, each once, in that order,
# last on the line. GAM (CSVPrintFile.GetTodriveParameters, read from the vendored build) reads tduser with
# getString, which refuses an empty value, and tdtitle with minLen=0, which doesn't.
todrive_tail() {
  if [ "${1:-}" = "tduser" ]; then
    need_value $# "EmailAddress"
    [ -n "$2" ] || empty_arg "EmailAddress"
    shift 2
  fi
  if [ "${1:-}" = "tdtitle" ]; then need_value $# "String"; shift 2; fi
  [ $# -eq 0 ] || invalid_arg "$1"
}

is_bool() { case "${1:-}" in true|on|yes|enabled|1|false|off|no|disabled|0) return 0 ;; esac; return 1; }
bool_word() { case "$1" in true|on|yes|enabled|1) echo True ;; *) echo False ;; esac; }   # as GAM shows it
need_bool() {
  [ -n "${1:-}" ] || missing_arg "Boolean"
  is_bool "$1" || invalid_choice "$1" "true|on|yes|enabled|1|false|off|no|disabled|0"
}
need_value() { [ "$1" -ge 2 ] || missing_arg "$2"; }  # <remaining-arg-count> <what>: a keyword's value
code_points() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' '; }  # Python's len() of UTF-8 text
need_date() {  # <Date> ::= YYYY-MM-DD | (+|-)N(d|w|y) | never | today
  case "${1:-}" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]|[+-][0-9]*[dwy]|never|today) ;;
    "") missing_arg "Date" ;;
    *) usage_error "Invalid date ($1): Expected <YYYY-MM-DD>" ;;
  esac
}
ACL_ROLES="editor|freebusy|freebusyreader|owner|reader|writer|writerwithoutprivateaccess|none"
is_acl_role() { case "${1:-}" in editor|freebusy|freebusyreader|owner|reader|writer|writerwithoutprivateaccess|none) return 0 ;; esac; return 1; }
need_acl_role() {
  [ -n "${1:-}" ] || missing_arg "CalendarACLRole"
  is_acl_role "$1" || invalid_choice "$1" "$ACL_ROLES"
}
# [sendnotifications <Boolean>] — the only thing an ACL add may carry after its scope.
acl_notify_tail() {
  if [ $# -eq 0 ]; then return 0; fi
  [ "$1" = "sendnotifications" ] || invalid_arg "$1"
  need_bool "${2:-}"
  [ $# -eq 2 ] || invalid_arg "$3"
}

case "${1:-}" in
  version)
    echo "GAM 7.48.30 - mock"
    # As the real build does in a fresh config directory: its config line, then the cache it created.
    if [ -n "${GAMCFGDIR:-}" ]; then
      printf 'Config File: %s/gam.cfg, Section: DEFAULT\nCreated: %s/gamcache\n' "$GAMCFGDIR" "$GAMCFGDIR"
    fi
    exit 0
    ;;
esac

# Every other call is authenticated: GamGUI must have materialized the Keychain credentials into a
# private per-call GAMCFGDIR (never ~/.gam), and GAM can't act without its credential files. The exit
# codes are the build's (OAUTH2SERVICE_JSON_REQUIRED_RC and OAUTH2_TXT_REQUIRED_RC, both 16; they were
# once a guessed 12); the wording is approximate.
if [ -z "${GAMCFGDIR:-}" ]; then
  echo "ERROR: mock: GAMCFGDIR is not set - an authenticated call escaped the ephemeral config" 1>&2
  exit 2
fi
if [ ! -s "$GAMCFGDIR/oauth2service.json" ]; then
  printf 'ERROR: Service Account OAuth2 File: %s, Does not exist\n' "$GAMCFGDIR/oauth2service.json" 1>&2
  exit 16
fi
if [ ! -s "$GAMCFGDIR/oauth2.txt" ]; then
  printf 'ERROR: Client OAuth2 File: %s, Does not exist\nPlease run: gam oauth create\n' "$GAMCFGDIR/oauth2.txt" 1>&2
  exit 16
fi
# Real GAM, handed a fresh GAMCFGDIR, creates its cache and config there and says so on STDOUT, before
# any output (checked against the 7.48.22 build). A reader that doesn't drop these lines parses them as
# data: the first live directory load would have read the banner as its CSV header (PR #8's review).
printf 'Created: %s/gamcache\nConfig File: %s/gam.cfg, Initialized\n' "$GAMCFGDIR" "$GAMCFGDIR"
# GAM rewrites oauth2.txt whenever it refreshes the access token, on any authenticated call.
if [ -n "${GAM_MOCK_REFRESH:-}" ]; then
  printf 'refreshed-token-payload\n' > "$GAMCFGDIR/oauth2.txt"
fi

case "${1:-}" in
  MOCKFAIL)
    # MOCKFAIL <kind> -> emit a representative stderr line and exit non-zero.
    case "${2:-unknown}" in
      notfound) echo "ERROR: 404: Entity User does not exist - notFound" 1>&2 ;;
      scope)    echo "ERROR: 403: Request had insufficient authentication scopes" 1>&2 ;;
      rate)     echo "ERROR: 429: userRateLimitExceeded - rate limit" 1>&2 ;;
      auth)     echo "ERROR: invalid_grant: Token has been expired or revoked" 1>&2 ;;
      *)        echo "ERROR: something unexpected happened" 1>&2 ;;
    esac
    exit 1
    ;;
  MOCKSLEEP)
    # MOCKSLEEP <seconds> [pidfile] -> a call that hangs (a stalled API request), so the runner's
    # timeout/kill path runs. exec keeps this PID, so the pidfile names the process that must die.
    if [ -n "${3:-}" ]; then echo "$$" > "$3"; fi
    exec sleep "${2:-30}"
    ;;
esac

# A read may end in `todrive …` (the Builder's export to a Sheet). Only a print/report read takes it — the
# grammar's info/show/check lines have none, and the `info user`/`check serviceaccount` handlers ignore
# trailing words, so it is refused here. Check its attributes, then handle the read as without them (the
# canned CSV stays the output; GAM would print the Sheet's URL). A write is left to its strict handler.
case "${1:-}:${3:-}" in
  print:*|report:*|*:print) td_read=print ;;
  info:*|*:show|*:check) td_read=other ;;
  *) td_read="" ;;
esac
if [ -n "$td_read" ]; then
  td=0; i=0
  for a in "$@"; do i=$((i + 1)); if [ "$a" = "todrive" ]; then td=$i; break; fi; done
  if [ "$td" -gt 0 ]; then
    [ "$td_read" = print ] || invalid_arg todrive
    ( shift "$td"; todrive_tail "$@" ) || exit $?
    i=0
    for a in "$@"; do   # keep the words before `todrive` (the list was expanded before the loop)
      i=$((i + 1))
      [ "$i" -gt 1 ] || set --
      [ "$i" -ge "$td" ] || set -- "$@" "$a"
    done
  fi
fi

# Read commands -> the matching fixture, as GAM prints it.
# `gam print users [query <QueryUser>] [fields <UserFieldNameList>] formatjson` -> GAM's CSV: a `primaryEmail`
# and a `JSON` column per user (gam/__init__.py:48707-48716, header :49045-49058). Every user in
# mock_gam/print_users.json, whatever the query or fields (approximate: GAM asks Google for only the users the
# query matches and the fields named). Without formatjson GAM flattens each user into columns this mock
# doesn't model, and quotechar changes the CSV itself: each is refused rather than answered in a guessed
# shape, as is any other option of the grammar's (`gam print users`), none of which the app sends.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "users" ]; then
  shift 2; fj=""
  while [ $# -gt 0 ]; do
    case "$1" in
      query) need_value $# "QueryUser"; shift 2 ;;
      fields) need_value $# "UserFieldNameList"; [ -n "$2" ] || empty_arg "UserFieldNameList"; shift 2 ;;
      formatjson) fj=1; shift ;;
      *) not_modelled "print users with $1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print users without formatjson"
  print_formatjson primaryEmail print_users.json
  exit 0
fi
# `gam info user <addr>` -> THAT user's record, keyed on the address like GAM. An address that isn't in
# the directory fails the way GAM does — returning Alice for anyone was the same lie as the
# group-members bug in the failure log.
# Like the Directory API, an address matches case-insensitively and an ALIAS resolves to the account
# that owns it (Alice's a.anders@) — the record's primaryEmail then differs from what was asked.
if [ "${1:-}" = "info" ] && [ "${2:-}" = "user" ]; then
  [ -n "${3:-}" ] || missing_arg "UserItem"
  addr=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  # INFOREFUSED: Google refuses the read (a missing scope or a rate limit), not "does not exist":
  # GAM's entityActionFailedWarning, ACTION_FAILED_RC, as signout_refused below.
  case "$3" in *INFOREFUSED*) printf 'User: %s, Show Failed: Not Authorized to access this resource/api\n' "$3" 1>&2; exit 50 ;; esac
  # An account suspended since the directory was read (the Admin console, another admin): with GAM_MOCK_STATE,
  # $GAM_MOCK_STATE/suspended/<user> makes its record say so.
  info_record() {
    case "$1" in
      alice@example.com|a.anders@example.com|alice@alias.example.net) cat "$GAM_MOCK_FIXTURES/info_user.json" ;;
      bob@example.com)   cat "$GAM_MOCK_FIXTURES/info_user_suspended.json" ;;
      carol@example.com) cat "$GAM_MOCK_FIXTURES/info_user_carol.json" ;;   # her recovery details (the compromised check)
      *) grep -F "\"primaryEmail\": \"$1\"" "$GAM_MOCK_FIXTURES/print_users.json" ;;
    esac
  }
  record=$(info_record "$addr") || true
  [ -n "$record" ] || does_not_exist "User" "$3"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/suspended/$addr" ]; then
    record=$(printf '%s' "$record" | sed 's/"suspended": false/"suspended": true/')
  fi
  printf '%s\n' "$record"
  exit 0
fi
# `gam print group-members group <addr> formatjson` -> GAM's CSV, a `group` and a `JSON` column per member
# (gam/__init__.py:37588-37595), and the header alone for a memberless group. The JSON holds the group too,
# and each default member field (GROUPMEMBERS_DEFAULT_FIELDS, :37424), empty where a member has none
# (:37640-37648, :37741-37750). Only that shape, the one the app sends: without formatjson GAM flattens each
# member into columns this mock doesn't model. The address matches a group's whole address,
# case-insensitively, as the Directory API's groupKey does: a substring once answered for `xsales@` and
# refused `SALES@`. Anything else, a user's address included, isn't a group: code that has to tell a person
# from a group would otherwise pass here and break live. GAM's groupNotFound -> entityUnknownWarning:
# "Group: <addr>, Does not exist", ENTITY_DOES_NOT_EXIST_RC (read from the vendored build; wording
# approximate).
if [ "${1:-}" = "print" ] && [ "${2:-}" = "group-members" ]; then
  [ $# -ge 3 ] || { echo "ERROR: mock: print group-members without a group isn't modelled" 1>&2; exit 2; }
  [ "$3" = "group" ] || invalid_arg "$3"
  [ $# -ge 4 ] || missing_arg "GroupItem"
  [ -n "$4" ] || empty_arg "GroupItem"
  [ $# -ge 5 ] || { echo "ERROR: mock: print group-members without formatjson isn't modelled" 1>&2; exit 2; }
  [ "$5" = "formatjson" ] || invalid_arg "$5"
  [ $# -eq 5 ] || invalid_arg "$6"
  addr=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]')
  is_group "$addr" || does_not_exist "Group" "$4"
  echo "group,JSON"
  members_of "$addr" | while IFS= read -r member; do
    gam_row "$addr" "$member"
  done
  exit 0
fi

# `gam user <email> show vacation` (no formatjson) -> parseable text, like real GAM. With GAM_MOCK_STATE
# and a stored setting for the user, the stored one in GAM's _showVacation shape (a date, else
# Started/NotSpecified while it is on); otherwise canned.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "show" ] && [ "${4:-}" = "vacation" ]; then
  [ $# -eq 4 ] || invalid_arg "$5"
  need_user "$2" Show
  # Gmail off for this user (a GAM_MOCK_STATE/nogmail/<user> marker): GAM's per-user service refusal, in
  # the wording GamGUI's error fixture records ("<Service> Service/App not enabled"), exit 1.
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$2" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$2" 1>&2; exit 1
  fi
  vdir="${GAM_MOCK_STATE:-}/vacation/$2"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -d "$vdir" ]; then
    stored() { if [ -f "$vdir/$1" ]; then cat "$vdir/$1"; else printf '%s' "$2"; fi; }
    on="$(stored enabled False)"
    printf 'User: %s, Vacation:\n  Enabled: %s\n  Contacts Only: %s\n  Domain Only: %s\n' \
      "$2" "$on" "$(stored contactsonly False)" "$(stored domainonly False)"
    if [ -f "$vdir/start" ]; then printf '  Start Date: %s\n' "$(cat "$vdir/start")"
    elif [ "$on" = True ]; then echo "  Start Date: Started"; fi
    if [ -f "$vdir/end" ]; then printf '  End Date: %s\n' "$(cat "$vdir/end")"
    elif [ "$on" = True ]; then echo "  End Date: NotSpecified"; fi
    printf '  Subject: %s\n  Message:\n' "$(stored subject None)"
    stored message None | sed 's/^/    /'; echo
    exit 0
  fi
  case "$2" in   # each fixture user's own setting
    alice@example.com) on=True; subject="Out of office"; message="I am away until next week." ;;
    carol@example.com) on=False; subject="Conference week"; message="Carol is at a conference." ;;
    *) on=False; subject=None; message=None ;;
  esac
  printf 'User: %s, Vacation:\n  Enabled: %s\n  Contacts Only: False\n  Domain Only: False\n' "$2" "$on"
  printf '  Subject: %s\n  Message:\n    %s\n' "$subject" "$message"
  exit 0
fi

# `gam report users ...` -> usage CSV on stdout. GAM's progress goes to stderr (doReport, gam/__init__.py
# :14505 and :14558; show_gettings on by default): "Getting Reports for all users", then the page count, written
# after a CR and ended with CR LF while show_gettings_got_nl is off (:5260-5271, :5620-5623). A report Google
# refuses (a GAM_MOCK_STATE/noreports marker): accessErrorExit after the progress line (:14595-14596), here as
# when the admin can't read the customer either (:669-701), INVALID_DOMAIN_RC.
# Only GamGUI's shape (GAMCommands.report_users): `date <Date> parameters <service:parameter,...>`, read before
# the progress line as doReport reads them (:14363-14381): a field without ":" is GAM's invalid argument, a service
# outside USER_REPORT_SERVICES (:13582-13590) its invalid choice. Another shape GAM takes isn't modelled. The date's
# words are need_date's, approximate. A known lie: the CSV holds all four parameters whatever was asked for (GAM
# prints only those asked for); kept, so the output the fixtures recorded stays the same.
if [ "${1:-}" = "report" ] && [ "${2:-}" = "users" ]; then
  [ "${3:-}" = "date" ] && [ "${5:-}" = "parameters" ] && [ $# -le 6 ] || not_modelled "report users without GamGUI's date and parameters"
  need_date "$4"
  [ $# -eq 6 ] || missing_arg "String"
  printf '%s\n' "$6" | tr ', ' '\n\n' | while IFS= read -r field; do
    [ -n "$field" ] || continue
    case "$field" in
      *:*) case "${field%%:*}" in
             accounts|chat|classroom|docs|drive|gmail|gplus) ;;
             *) invalid_choice "${field%%:*}" "accounts|chat|classroom|docs|drive|gmail|gplus" ;;
           esac ;;
      *) usage_error "Invalid argument: Expected <service:parameter>" ;;
    esac
  done || exit $?
  printf 'Getting Reports for all users\n' 1>&2
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/noreports" ]; then
    printf '\nERROR: Customer ID: my_customer, Domain: example.com, User: admin@example.com, Access Forbidden\n' 1>&2
    exit 61
  fi
  printf '\rGot 3 Reports for all users on 2026-06-16...\r\n' 1>&2
  cat <<'EOF'
email,date,accounts:used_quota_in_mb,drive:num_items_created,gmail:num_emails_received,gmail:num_emails_sent
alice@example.com,2026-06-16,608873,1,125,10
bob@example.com,2026-06-16,1048576,0,5,0
carol@example.com,2026-06-16,2048,2,40,3
EOF
  exit 0
fi

# `gam report <application> (user <u>|all)|(select users <list>) start -<N>h|-<N>d end now [ip <IP>] [events <names>]
# maxactivities <N>` (doReport's activity form, GAM 7.48.30 :14084-14960), for the applications the app reads: "Getting all
# Activities for <u>" (or "all users"), then a CSV row per event, newest first (SortRows on id.time), from
# report_<application>.csv: the accounts' rows, or all; `ip` keeps that address's (actorIpAddress); `events` those names;
# `maxactivities` the newest N per account; an account listed twice is read once (GAM's entity list drops repeats). No
# fixture is the titles alone ("name"): no events. An account that isn't a user is the API's badRequest,
# entityUnknownWarning: "User: <u>, Does not exist", exit 56, after the others' rows; outside the domain (example.com)
# it is "Service not applicable", exit 73. The admin log's accounts are the actor only with `userisactor` (without it GAM
# filters USER_EMAIL==<u>: the events affecting them). Gmail over 30 days is the API's bad request (doReport's own
# comment: no more than 30 days apart): exit 56 for a named account, "ERROR: Bad Request" exit 53 for all. With
# GAM_MOCK_STATE/nolog/<application>, the edition doesn't keep that log: systemErrorExit(GOOGLE_API_ERROR_RC), exit 4
# (Google's words approximate). A known lie: every fixture event is answered whatever the window (the dates are fixed).
# The start is only the app's form, `-<N>h` or `-<N>d`. Only the app's shape.
# Chrome (:14790-14797): doReport reads userKey all and maps a named user to the filter DEVICE_USER==<u>, the computer's
# own login name ("carol"), so a work address finds none of a Mac's events, though a Chromebook's (its account) it does;
# nothing checks the address, so a non-user isn't refused, and the value is compared exactly as Google may. Its
# event names are capitals (REPORT_ACTIVITIES_UPPERCASE_EVENTS). The app reads an account both ways: GAM's own `user
# <address>`, and `user all filter PROFILE_USER_NAME==<address>`, the account signed in to the profile, the one filter
# modelled, for Chrome with `user all`; a Chrome `select` isn't modelled. An event without an IP address column is never
# one `ip` keeps.
if [ "${1:-}" = "report" ] && case "${2:-}" in login|logins|token|tokens|oauthtoken|gmail|accessevaluation|chat|useraccounts|drive|doc|docs|takeout|admin|mobile|devices|chrome|saml|calendar|calendars|groups|group|rules|contextawareaccess|vault) true ;; *) false ;; esac; then
  case "$2" in logins) app=login ;; tokens|oauthtoken) app=token ;; doc|docs) app=drive ;; devices) app=mobile ;; calendars) app=calendar ;; group) app=groups ;; *) app=$2 ;; esac
  shift 2; who=""; start=""; end=""; ip=""; max=""; events=""; actor=""; filter=""; selected=""
  while [ $# -gt 0 ]; do
    case "$1" in
      user) need_value $# "EmailAddress"; who=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      select) [ "${2:-}" = users ] || not_modelled "report select ${2:-}"; need_value $(($# - 1)) "UserList"
              who=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]'); selected=1; shift 3 ;;
      filter|filters) need_value $# "String"; filter="$2"; shift 2 ;;
      start|starttime) need_value $# "Time"; start="$2"; shift 2 ;;
      end|endtime) need_value $# "Time"; end="$2"; shift 2 ;;
      ip) need_value $# "String"; ip="$2"; shift 2 ;;
      maxactivities) need_value $# "Number"; max="$2"; shift 2 ;;
      event|events) need_value $# "EventNameList"; events=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
      userisactor) actor=1; shift ;;
      *) not_modelled "report $app with $1" ;;
    esac
  done
  [ -n "$who" ] && [ -n "$start" ] && [ -n "$max" ] || not_modelled "report $app without user, start and maxactivities"
  span=${start#-}; unit=${span#"${span%?}"}; count=${span%?}
  case "$start" in -*) ;; *) not_modelled "report start $start" ;; esac
  case "$unit:$count" in [hHdD]:[0-9]*) case "$count" in *[!0-9]*) usage_error "Invalid argument: Expected <(+|-)<Number>(m|h|d|w|y)>" ;; esac ;;
    *) usage_error "Invalid argument: Expected <(+|-)<Number>(m|h|d|w|y)>" ;; esac
  case "$unit" in [dD]) hours=$((count * 24)) ;; *) hours=$count ;; esac
  [ -z "$actor" ] || [ "$app" = admin ] || not_modelled "report $app userisactor"
  match=""
  # doReport's REPORT_ACTIVITIES_UPPERCASE_EVENTS: these logs' event names are capitals; the rest, lower case.
  case "$app" in admin|chrome|contextawareaccess|mobile|takeout) events=$(printf '%s' "$events" | tr '[:lower:]' '[:upper:]') ;; esac
  if [ "$app" = chrome ]; then
    [ -z "$selected" ] || not_modelled "report chrome select users"
    if [ -n "$filter" ]; then
      [ "$who" = all ] || not_modelled "report chrome user $who with a filter"
      case "$filter" in PROFILE_USER_NAME==?*) ;; *) not_modelled "report chrome filter $filter" ;; esac
      by=PROFILE_USER_NAME; match=${filter#PROFILE_USER_NAME==}   # as given: GAM passes a filter unchanged
    elif [ "$who" != all ]; then
      by=DEVICE_USER; match=$who; who=all
    fi
  else
    [ -z "$filter" ] || not_modelled "report $app filter"
  fi
  case "$end" in ""|now|NOW) ;; *) not_modelled "report end $end" ;; esac
  case "$max" in ""|*[!0-9]*) usage_error "Invalid argument: Expected <Number>" ;; esac
  case "$who" in *[[:space:]]*) not_modelled "an account list like $who" ;; esac
  if [ "$who" = all ]; then printf 'Getting all Activities for all users\n' 1>&2; fi
  if [ "$app" = gmail ] && [ "$hours" -gt 720 ]; then
    if [ "$who" = all ]; then printf '\nERROR: Bad Request\n' 1>&2; exit 53; fi
    printf 'name\n'
    for account in $(printf '%s' "$who" | tr ',' ' '); do printf 'User: %s, Does not exist\n' "$account" 1>&2; done
    exit 56
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nolog/$app" ]; then
    printf "\nERROR: 400: This application's log isn't available for this customer - invalid\n" 1>&2; exit 4
  fi
  file="$GAM_MOCK_FIXTURES/report_$app.csv"
  if [ -f "$file" ]; then head -n 1 "$file"; else printf 'name\n'; fi
  missing=""; rc=56; seen=" "
  # The admin log without userisactor reads the events that affected the account (USER_EMAIL), not what it did.
  if [ "$app" = admin ] && [ -z "$actor" ]; then by=USER_EMAIL; elif [ -z "$match" ]; then by=actor.email; fi
  for account in $(printf '%s' "$who" | tr ',' ' '); do
    case "$seen" in *" $account "*) continue ;; esac
    seen="$seen$account "
    if [ "$account" != all ]; then
      printf 'Getting all Activities for %s\n' "$account" 1>&2
      if ! in_directory "$account"; then
        case "$account" in
          *@example.com) printf 'User: %s, Does not exist\n' "$account" 1>&2; rc=56 ;;   # setSysExitRC: the last one wins
          *) printf 'User: %s, Service not applicable\n' "$account" 1>&2; rc=73 ;;
        esac
        missing=1; continue
      fi
    fi
    [ -f "$file" ] || continue
    tail -n +2 "$file" | awk -F, -v who="$account" -v ip="$ip" -v events="$events" -v by="$by" -v only="$match" \
      -v header="$(head -n 1 "$file")" '
      BEGIN { n = split(header, h, ","); for (i = 1; i <= n; i++) col[h[i]] = i
              m = split(events, e, ","); for (i = 1; i <= m; i++) want[e[i]] = 1 }
      (only != "" ? ((by in col) && $col[by] == only) : (who == "all" || ((by in col) && $col[by] == who))) \
        && (ip == "" || (("ipAddress" in col) && $col["ipAddress"] == ip)) && (m == 0 || ($1 in want))' \
      | head -n "$max"
  done
  [ -z "$missing" ] || exit "$rc"
  exit 0
fi

# `gam user <email> show signature` (no formatjson) -> THAT address's signature, as text. Without
# `primary` or `default`, printShowSignature gets the one send-as named by the address given, not the
# list (gam/__init__.py:78862-78865), and _showSendAs prints it (78560-78591): `SendAs Address: <addr>`
# (with the display name before it when one is set), its fields indented, `Signature:`, then the body
# (`None` when empty) as Ind.MultiLineText prints it (gamlib/glindent.py:45-46): every "\n" followed by
# the indent, then rstrip, so only "\n" starts an indented line. Only that shape: the app sends no option.
# With GAM_MOCK_STATE and a signature the mock set, that one, in the form GAM stored it; otherwise each
# fixture user's own. (rstrip here strips ASCII whitespace only; Python's also strips Unicode spaces,
# which every reader strips again.)
if [ "${1:-}" = "user" ] && [ "${3:-}" = "show" ] && [ "${4:-}" = "signature" ]; then
  [ $# -eq 4 ] || invalid_arg "$5"
  known_user "$2" || not_a_user "$2" Show
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$2" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$2" 1>&2; exit 1
  fi
  sfile="${GAM_MOCK_STATE:-}/signature/$2"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$sfile" ]; then
    sig=$(cat "$sfile"; printf .); sig=${sig%.}
  else
    case "$2" in
      alice@example.com) sig='Best,<br>Alice' ;;
      carol@example.com) sig='Carol Clark<br>Operations' ;;
      *) sig='' ;;
    esac
  fi
  [ -n "$sig" ] || sig=None
  shown=$(printf '%s\n' "$sig" | LC_ALL=C sed '1!s/^/    /'; printf .); shown=${shown%.}
  while :; do case "$shown" in *[[:space:]]) shown=${shown%?} ;; *) break ;; esac; done
  printf 'SendAs Address: <%s>\n  IsPrimary: True\n  Default: True\n  Signature:\n    %s\n' "$2" "$shown"
  exit 0
fi

# `gam print groups member <email>` -> CSV of THAT user's group emails: the groups listing them directly, in
# GAM's order (alice: sales, staff; bob: staff; carol: it; dana: none, the header alone). For an address
# that isn't a user the Directory API says "Invalid Input: memberKey" and GAM stops (invalidMember ->
# entityActionFailedExit, ACTION_FAILED_RC; read from the vendored build — wording approximate).
if [ "${1:-}" = "print" ] && [ "${2:-}" = "groups" ] && [ "${3:-}" = "member" ]; then
  [ -n "${4:-}" ] || missing_arg "EmailItem"
  [ $# -eq 4 ] || invalid_arg "$5"
  user=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]')
  known_user "$user" || { echo "ERROR: Group:, Print Failed: Invalid Input: memberKey" 1>&2; exit 50; }
  echo "email"
  while IFS= read -r record; do
    group=$(json_text email "$record")
    if member_record "$group" "$user" | grep -qF '"type": "USER"'; then echo "$group"; fi
  done < "$GAM_MOCK_FIXTURES/groups.json"
  exit 0
fi

# `gam print domains formatjson` -> GAM's CSV, a `domainName` and a `JSON` column per domain (gam/__init__.py
# :17097, :17127): the Directory API's Domains resource, its domain aliases nested in it. The tenant
# (mock_gam/domains.json): example.com (primary, aliased by alias.example.net) and a secondary example.net.
# GAM also takes todrive and showitemcountonly, without formatjson flattens the record into columns this
# mock doesn't model, and quotechar changes the CSV itself; the app sends none of them, so each is refused
# rather than answered in a guessed shape.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "domains" ]; then
  shift 2; fj=""
  while [ $# -gt 0 ]; do
    case "$1" in
      formatjson) fj=1; shift ;;
      quotechar) [ -n "$fj" ] || invalid_arg "$1"; [ -n "${2:-}" ] || missing_arg "Character"
        not_modelled "print domains with quotechar" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print domains without formatjson"
  print_formatjson domainName domains.json
  exit 0
fi

# `gam print groups [fields <GroupFieldNameList>]* formatjson` -> GAM's CSV, an `email` and a `JSON` column
# per group (gam/__init__.py:36720-36724, header :36870, :37014), the record holding the fields asked for
# (and the address, which GAM always prints). Each field must be a <GroupFieldName> (grammar 3965), matched
# as GAM matches it, lowercased with underscores dropped; another is GAM's invalid choice. Only the four the
# app asks for, together, are modelled (mock_gam/groups.json holds them); fewer would need the records cut
# down. The count is a string, as the Directory API sends an int64 (approximate). GAM also takes quotechar,
# and without formatjson flattens the record into columns; the app sends neither, so each is refused rather
# than answered in a guessed shape.
GROUP_FIELDS="admincreated|aliases|allowexternalmembers|allowgooglecommunication|allowwebposting|archiveonly|customfootertext|customreplyto|customrolesenabledforsettingstobemerged|defaultmessagedenynotificationtext|description|directmemberscount|email|enablecollaborativeinbox|collaborative|favoriterepliesontop|id|includecustomfooter|includeinglobaladdresslist|gal|isarchived|maxmessagebytes|memberscanpostasthegroup|messagedisplayfont|messagemoderationlevel|name|primarylanguage|replyto|sendmessagedenynotification|showingroupdirectory|spammoderationlevel|whocanaddreferences|whocanadd|whocanaddexternalmembers|whocanapprovemessages|whocanassigntopics|whocanassistcontent|whocancontactowner|whocandeleteanypost|whocandeletetopics|whocandiscovergroup|whocanenterfreeformtags|whocanhideabuse|whocaninvite|whocanjoin|whocanleavegroup|whocanlocktopics|whocanmaketopicssticky|whocanmarkduplicate|whocanmarkfavoritereplyonanytopic|whocanmarkfavoritereplyonowntopic|whocanmarknoresponseneeded|whocanmoderatecontent|whocanmodifytagsandcategories|whocanmovetopicsin|whocanmovetopicsout|whocanpostannouncements|whocanpostmessage|whocantaketopics|whocanunassigntopic|whocanunmarkfavoritereplyonanytopic|whocanviewgroup|whocanviewmembership"
if [ "${1:-}" = "print" ] && [ "${2:-}" = "groups" ]; then
  shift 2; fj=""; want=" email "
  while [ $# -gt 0 ]; do
    case "$1" in
      fields)
        need_value $# "GroupFieldNameList"
        [ -n "$2" ] || empty_arg "GroupFieldNameList"
        set -f   # a field of `*` is a word, not a glob
        for field in $(printf '%s' "$2" | tr ',' ' '); do
          field=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]' | tr -d '_')
          case "|$GROUP_FIELDS|" in *"|$field|"*) ;; *) invalid_choice "$field" "$GROUP_FIELDS" ;; esac
          case "$field" in
            email|name|description|directmemberscount) want="$want$field " ;;
            *) not_modelled "print groups field $field" ;;
          esac
        done
        set +f
        shift 2 ;;
      formatjson) fj=1; shift ;;
      quotechar)
        [ -n "$fj" ] || invalid_arg "$1"
        need_value $# "Character"
        not_modelled "print groups with quotechar" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print groups without formatjson"
  for field in name description directmemberscount; do
    case "$want" in *" $field "*) ;; *) not_modelled "print groups without field $field" ;; esac
  done
  # print_formatjson's output, each count as the group's members now are once a write changed them.
  echo "email,JSON"
  while IFS= read -r record; do
    group=$(json_text email "$record")
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/groups/$group" ]; then
      count=$(members_of "$group" | wc -l | tr -d ' ')
      record=$(printf '%s' "$record" | sed "s/\"directMembersCount\": \"[0-9]*\"/\"directMembersCount\": \"$count\"/")
    fi
    gam_row "$group" "$record"
  done < "$GAM_MOCK_FIXTURES/groups.json"
  exit 0
fi

# `<user> print messages query in:drafts max_to_print <n> headers subject showlabels showdate`: the compromised-
# account check's listing of drafts, GamCommands.listMessages, strict,
# as GAM 7.48.30's printShowMessagesThreads runs it, from mock_gam/messages.csv (the DRAFT label) and each
# message's mock_gam/message_headers/<id>. As GAM does: a token for the user (token_refused); showlabels reads the labels
# first, so Gmail off is userGmailServiceNotEnabledWarning (73); "Getting all Messages…" on stderr; Spam and Trash aren't
# listed without includespamtrash, so a message in $GAM_MOCK_STATE/trashed/<id> is left out; none is NO_ENTITIES_FOUND_RC
# (60) with the header line alone; at most max_to_print (0 is no limit, as GAM's maxToProcess). The Subject under its
# SMTP_HEADERS_MAP name; Date is Gmail's own time (showdate). Column order approximate; the app reads by name. Only that one
# label term and that one header.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "messages" ] && [ "${5:-}" = "query" ] \
   && [ "${7:-}" = "max_to_print" ] && [ "${9:-}" = "headers" ] && [ "${10:-}" = "subject" ]; then
  user=$2; query=$6; max=$8
  [ "$#" -eq 12 ] && [ "${11}" = showlabels ] && [ "${12}" = showdate ] || not_modelled "a listing other than the check's"
  case "$query" in in:drafts) want=DRAFT ;; *) not_modelled "a listing of $query" ;; esac
  case "$max" in ''|*[!0-9]*) usage_error "Invalid argument: Expected <integer x>=0>" ;; esac
  columns="User threadId id Subject Date LabelsCount Labels"
  if ! known_user "$user"; then gam_row $columns; token_refused "$user" Print; fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; gam_row $columns; exit 73
  fi
  printf 'Getting all Messages that match query ((%s)) for %s\n' "$query" "$user" 1>&2
  gam_row $columns
  n=0
  while IFS=, read -r owner id message tags; do
    [ "$owner" = "$user" ] || continue
    case " $tags " in *" $want "*) ;; *) continue ;; esac
    if [ -n "${GAM_MOCK_STATE:-}" ] && { [ -e "$GAM_MOCK_STATE/trashed/$id" ] || [ -e "$GAM_MOCK_STATE/deleted/$id" ]; }; then continue; fi
    [ "$max" -eq 0 ] || [ "$n" -lt "$max" ] || break
    data="$GAM_MOCK_FIXTURES/message_headers/$id"
    [ -f "$data" ] || not_modelled "message $id's headers"
    field() { sed -n "s/^$1: //p" "$data" | head -n 1; }
    set -- $tags
    gam_row "$user" "$(field Gmail-ThreadId)" "$id" "$(field Subject)" "$(field Gmail-InternalDate)" "$#" "$tags"
    n=$((n + 1))
  done < "$GAM_MOCK_FIXTURES/messages.csv"
  if [ "$n" -eq 0 ]; then printf '\rGot 0 Messages that matched query ((%s)) for %s...\r\n' "$query" "$user" 1>&2; exit 60; fi
  exit 0
fi

# `<user> delete messages ids <MessageIDEntity>` (8170-8174; _processMessagesThreads with ids: no doit, no count check):
# the compromised-account step that deletes the chosen drafts for good. As GAM 7.48.30 does: a token for the user;
# getProfile, so Gmail off is userGmailServiceNotEnabledWarning (73); "User: <u>, Delete N Messages"; then Gmail's
# batchDelete, message_batch_size (50) at a time: each "  User: <u>, Message: <id>, Deleted (j/N)", or a batch holding an ID
# the mailbox doesn't have (messages.csv, not already deleted) failing whole, "  User: <u>, Message: <the first five>,...,
# Delete Failed: Invalid message id(s) (a-b/N)" on stderr (entityActionFailedWarning, exit 50), the other batches done.
# Gmail's word for a valid-looking but missing ID is approximate. With GAM_MOCK_STATE a deleted message is
# $GAM_MOCK_STATE/deleted/<id>. Only a list of ASCII letters, digits, `-`, `_` and commas is modelled: GAM splits on
# whitespace too, and reads a file for a list selector.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "delete" ] && [ "${4:-}" = "messages" ] && [ "${5:-}" = "ids" ]; then
  user=$2
  [ $# -ge 6 ] || missing_arg "MessageIDEntity"
  [ $# -eq 6 ] || invalid_arg "$7"
  case "$6" in *[!A-Za-z0-9_,-]*) not_modelled "a message ID list like $6" ;; esac
  case "$(printf '%s' "$6" | tr '[:upper:]' '[:lower:]' | tr -d '_-')" in csvkmd|csvsubkey|csv|csvfile|file|csvdata) not_modelled "delete messages ids from $6" ;; esac
  known_user "$user" || token_refused "$user" Delete
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73
  fi
  set -f; ids=$(printf '%s' "$6" | tr ',' ' '); set +f
  n=$(printf '%s\n' $ids | grep -c . || true); failed=""
  if [ "$n" -eq 0 ]; then printf 'User: %s, Messages: 0, Not Deleted: No Messages matched\n' "$user" 1>&2; exit 60; fi
  if [ "$n" -eq 1 ]; then noun=Message; else noun=Messages; fi
  printf 'User: %s, Delete %s %s\n' "$user" "$n" "$noun"
  have() { grep -q "^$user,$1," "$GAM_MOCK_FIXTURES/messages.csv" && ! { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/deleted/$1" ]; }; }
  done_count=0
  set -- $ids
  while [ $# -gt 0 ]; do
    batch=""; k=0
    while [ $# -gt 0 ] && [ "$k" -lt 50 ]; do batch="$batch $1"; k=$((k + 1)); shift; done
    bad=""
    for id in $batch; do have "$id" || bad=1; done
    if [ -n "$bad" ]; then
      shown=$(printf '%s\n' $batch | head -n 5 | paste -sd, -); [ "$k" -gt 5 ] && shown="$shown,..."
      printf '  User: %s, Message: %s, Delete Failed: Invalid message id(s) (%s-%s/%s)\n' "$user" "$shown" "$((done_count + 1))" \
        "$((done_count + k))" "$n" 1>&2
      failed=1; done_count=$((done_count + k)); continue
    fi
    for id in $batch; do
      done_count=$((done_count + 1)); of=""; [ "$n" -gt 1 ] && of=" ($done_count/$n)"
      if [ -n "${GAM_MOCK_STATE:-}" ]; then mkdir -p "$GAM_MOCK_STATE/deleted"; : > "$GAM_MOCK_STATE/deleted/$id"; fi
      printf '  User: %s, Message: %s, Deleted%s\n' "$user" "$id" "$of"
    done
  done
  [ -z "$failed" ] || exit 50
  exit 0
fi

# `<user> print messages query rfc822msgid:<id> includespamtrash max_to_print <n> headers all showlabels showdate`: the
# Phishing screen's recipients read (GamCommands.searchMessages, detail .headers), strict, as GAM 7.48.30's
# printShowMessagesThreads runs it, from the mailboxes in mock_gam/messages.csv and each message's headers in
# mock_gam/message_headers/<id> (its `Gmail-` lines are Gmail's own fields; the rest its headers, in order; made up).
# With GAM_MOCK_STATE, $GAM_MOCK_STATE/trashed/<id> is in Trash (still found: includespamtrash), deleted/<id> purged
# (gone), and nogmail/<user> Gmail off. As GAM does:
#   - a token for the user (token_refused, "User Print Failed"); with showlabels the labels are read first, so Gmail off is
#     userGmailServiceNotEnabledWarning (73) before any list;
#   - the list ("Getting all Messages…" on stderr); none sets NO_ENTITIES_FOUND_RC (60);
#   - the CSV (_printMessage, SortTitles): User,threadId,id, GAM's default headers, LabelsCount,Labels, then every other
#     header name sorted; each header under its own name, a repeat as "<name> 1"; Date is the message's own time
#     (showdate overwrites the header); the header line is printed even with no row, after any failure.
# The same read answers Users' "Search a mailbox" (MailboxSearch, docs/domains/compromised-account.md slice 3): a query of
# space-separated Gmail terms, each modelled from the fixtures: `rfc822msgid:<id>`; `in:<label>` (the message's labels,
# case aside); `from:<text>` (its From header) and `to:<text>` (To, Cc or Bcc), case aside, as part of the header;
# `newer_than:<N>d|h`, a known lie: every fixture message is newer (their dates are fixed). Any other term, or a message
# whose headers the fixtures don't hold, is refused as not modelled, never answered more kindly than Gmail.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "messages" ] && [ "${5:-}" = "query" ]; then
  user=$2; query=$6
  shift 6
  spamtrash=""; all=""; labels=""; dates=""
  while [ $# -gt 0 ]; do
    word=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_')
    case "$word" in
      includespamtrash) spamtrash=1; shift ;;
      maxtoprint)
        [ $# -ge 2 ] || missing_arg "integer x>=0"
        case "$2" in ''|*[!0-9]*) usage_error "Invalid argument: Expected <integer x>=0>" ;; esac
        shift 2 ;;
      headers)
        [ $# -ge 2 ] || missing_arg "String"
        [ "$2" = all ] || not_modelled "print messages with headers other than all"
        all=1; shift 2 ;;
      showlabels) labels=1; shift ;;
      showdate) dates=1; shift ;;
      *) not_modelled "an rfc822msgid: search with $1" ;;
    esac
  done
  { [ -n "$spamtrash" ] && [ -n "$all" ] && [ -n "$labels" ] && [ -n "$dates" ]; } \
    || not_modelled "an rfc822msgid: search other than the recipients read"
  [ -n "$query" ] || empty_arg "Query"
  set -f
  for term in $query; do
    case "$term" in
      *[*?[]*) not_modelled "a Gmail term like $term" ;;
      rfc822msgid:?*|in:?*|from:?*|to:?*) ;;
      newer_than:[0-9]*[dh]) case "${term#newer_than:}" in *[!0-9dh]*|*[dh]?*) not_modelled "a Gmail term like $term" ;; esac ;;
      *) not_modelled "a Gmail term like $term" ;;
    esac
  done
  set +f
  # Each term of the query, against one message: its Message-ID, its labels, and its header file (`Gmail-` lines aside).
  matches() {  # <message-id> <labels> <id>; the terms hold no glob character (refused above)
    for term in $query; do
      case "$term" in
        rfc822msgid:*) [ "$1" = "${term#rfc822msgid:}" ] || return 1 ;;
        in:*) want=$(printf '%s' "${term#in:}" | tr '[:lower:]' '[:upper:]')
              case " $2 " in *" $want "*) ;; *) return 1 ;; esac ;;
        newer_than:*) ;;
        from:*|to:*)
          [ -f "$GAM_MOCK_FIXTURES/message_headers/$3" ] || not_modelled "message $3's headers"
          case "$term" in from:*) names='^From:' ;; *) names='^(To|Cc|CC|Bcc|BCC):' ;; esac
          grep -E "$names" "$GAM_MOCK_FIXTURES/message_headers/$3" | grep -qiF -- "${term#*:}" || return 1 ;;
      esac
    done
    return 0
  }
  base="User
threadId
id
Date
Subject
From
Reply-To
To
Delivered-To
Content-Type
Message-ID
LabelsCount
Labels"
  header_only() { gam_row $(printf '%s' "$base" | tr '\n' ' '); }
  if ! known_user "$user"; then header_only; token_refused "$user" Print; fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2
    header_only; exit 73
  fi
  printf 'Getting all Messages that match query ((%s)) for %s\n' "$query" "$user" 1>&2
  ids=""; labels_of=""
  while IFS=, read -r owner id message tags; do
    [ "$owner" = "$user" ] || continue
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/trashed/$id" ]; then now="$tags TRASH"; else now=$tags; fi
    matches "$message" "$now" "$id" || continue
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/deleted/$id" ]; then continue; fi
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/trashed/$id" ]; then tags="$tags TRASH"; fi
    ids="$ids $id"
    labels_of="$labels_of
$id $tags"
  done < "$GAM_MOCK_FIXTURES/messages.csv"
  if [ -z "$ids" ]; then
    printf '\rGot 0 Messages that matched query ((%s)) for %s...\r\n' "$query" "$user" 1>&2
    header_only; exit 60
  fi
  rows=$(mktemp -d)
  trap 'rm -rf "$rows"' EXIT
  n=0
  for id in $ids; do
    n=$((n + 1)); data="$GAM_MOCK_FIXTURES/message_headers/$id"
    [ -f "$data" ] || not_modelled "message $id's headers"
    tags=$(printf '%s\n' "$labels_of" | sed -n "s/^$id //p")
    {
      printf 'User\t%s\nthreadId\t%s\nid\t%s\n' "$user" "$(sed -n 's/^Gmail-ThreadId: //p' "$data")" "$id"
      # Each header under its own name, a repeat numbered from 1 (headerCounts); Date is replaced below.
      awk '/^Gmail-/ { next } { name = substr($0, 1, index($0, ": ") - 1); value = substr($0, index($0, ": ") + 2)
             c = seen[name]++; if (c > 0) name = name " " c; if (name != "Date") print name "\t" value }' "$data"
      printf 'Date\t%s\n' "$(sed -n 's/^Gmail-InternalDate: //p' "$data")"
      set -- $tags
      printf 'LabelsCount\t%s\nLabels\t%s\n' "$#" "$tags"
    } > "$rows/$n"
  done
  extras=$(cut -f1 "$rows"/* | LC_ALL=C sort -u | while IFS= read -r name; do
    printf '%s\n' "$base" | grep -qxF -- "$name" || printf '%s\n' "$name"; done)
  columns="$base
$extras"
  printf '\rGot %s Messages that matched query ((%s)) for %s...\r\n' "$n" "$query" "$user" 1>&2
  # The header, then each message's cells in the same order.
  old_ifs=$IFS; IFS='
'
  set --
  for column in $columns; do [ -n "$column" ] && set -- "$@" "$column"; done
  IFS=$old_ifs
  gam_row "$@"
  i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    old_ifs=$IFS; IFS='
'
    set --
    for column in $columns; do
      [ -n "$column" ] || continue
      set -- "$@" "$(awk -F '\t' -v k="$column" '$1 == k { print substr($0, length($1) + 2); exit }' "$rows/$i")"
    done
    IFS=$old_ifs
    gam_row "$@"
  done
  exit 0
fi

# `all users print messages query "rfc822msgid:<id> in:spam" includespamtrash headers message-id showlabels`: the Phishing
# screen's read of the copies Gmail filed to Spam (GamCommands.findSpamCopies, SpamCopies), strict, as GAM 7.48.30's
# printShowMessagesThreads runs it over every active user (isSuspended=False, by address), from mock_gam/messages.csv and
# each message's mock_gam/message_headers/<id>. With GAM_MOCK_STATE, nogmail/<user> is Gmail off, deleted/<id> gone and
# trashed/<id> in Trash with its SPAM label kept beside TRASH (whether Gmail's messages.trash drops SPAM isn't known here,
# so the app has to skip a copy in Trash by that label either way). Labels are the fixture's system labels, never a user
# label whose name holds a space (GAM joins names with one; the reader's own tests carry that case). As GAM does:
#   - every argument read first (getArgument: lowercased, `_` dropped), `query` needing a value; only this one form;
#   - the users listed ("Got <n> Users..."), then each in order, numbered (i/n) past one: showlabels reads the labels
#     first, so Gmail off is userGmailServiceNotEnabledWarning (73) before that user's "Getting all Messages…" line; the
#     list, Spam and Trash included (includeSpamTrash), of that Message-ID in Spam; none sets NO_ENTITIES_FOUND_RC (60);
#   - the CSV once every user is read (CSVPrintFile): User,threadId,id, the Message-ID header under its SMTP_HEADERS_MAP
#     name, LabelsCount,Labels; the header line even with no row; the last code set stands (setSysExitRC).
if [ "${1:-}" = "all" ] && [ "${2:-}" = "users" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "messages" ]; then
  shift 4
  query=""; queries=0; spamtrash=""; header=""; labels=""
  while [ $# -gt 0 ]; do
    word=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_')
    case "$word" in
      query)
        [ $# -ge 2 ] || missing_arg "Query"
        [ -n "$2" ] || empty_arg "Query"
        queries=$((queries + 1)); query=$2; shift 2 ;;
      includespamtrash) spamtrash=1; shift ;;
      headers)
        [ $# -ge 2 ] || missing_arg "String"
        [ "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" = message-id ] || not_modelled "all users print messages with headers $2"
        header=1; shift 2 ;;
      showlabels) labels=1; shift ;;
      *) not_modelled "all users print messages with $1" ;;
    esac
  done
  { [ "$queries" -eq 1 ] && [ -n "$spamtrash" ] && [ -n "$header" ] && [ -n "$labels" ]; } \
    || not_modelled "all users print messages other than the read of copies in Spam"
  case "$query" in
    "rfc822msgid:"*" in:spam") msgid=${query#rfc822msgid:}; msgid=${msgid% in:spam} ;;
    *) not_modelled "a Gmail query other than rfc822msgid:<id> in:spam" ;;
  esac
  case "$msgid" in ''|*[[:space:]]*) not_modelled "a Gmail query other than rfc822msgid:<id> in:spam" ;; esac
  users=$(grep -vF '"suspended": true' "$GAM_MOCK_FIXTURES/print_users.json" \
    | sed -n 's/.*"primaryEmail": "\([^"]*\)".*/\1/p' | LC_ALL=C sort)
  count=$(printf '%s\n' "$users" | grep -c . || true)
  printf 'Getting all Users that match query (isSuspended=False isGuest=False), may take some time on a large Google Workspace Account...\n' 1>&2
  printf 'Got %s Users...\r\n' "$count" 1>&2
  rows=""; rc=0; i=0
  for user in $users; do
    i=$((i + 1))
    if [ "$count" -gt 1 ]; then n=" ($i/$count)"; else n=""; fi
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
      printf 'User: %s, Gmail Service/App not enabled%s\n' "$user" "$n" 1>&2
      rc=73; continue
    fi
    printf 'Getting all Messages that match query ((%s)) for %s%s\n' "$query" "$user" "$n" 1>&2
    found=0
    while IFS=, read -r owner id message tags; do
      { [ "$owner" = "$user" ] && [ "$message" = "$msgid" ]; } || continue
      case " $tags " in *" SPAM "*) ;; *) continue ;; esac
      if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/deleted/$id" ]; then continue; fi
      if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/trashed/$id" ]; then tags="$tags TRASH"; fi
      data="$GAM_MOCK_FIXTURES/message_headers/$id"
      [ -f "$data" ] || not_modelled "message $id's headers"
      set -- $tags
      rows="$rows$(gam_row "$user" "$(sed -n 's/^Gmail-ThreadId: //p' "$data")" "$id" \
        "$(sed -n 's/^Message-ID: //p' "$data" | head -n 1)" "$#" "$tags")
"
      found=$((found + 1))
    done < "$GAM_MOCK_FIXTURES/messages.csv"
    if [ "$found" -eq 1 ]; then noun=Message; else noun=Messages; fi
    printf '\rGot %s %s that matched query ((%s)) for %s...\r\n' "$found" "$noun" "$query" "$user" 1>&2
    [ "$found" -gt 0 ] || rc=60
  done
  gam_row User threadId id Message-ID LabelsCount Labels
  printf '%s' "$rows"
  exit "$rc"
fi

# Any other `print messages` (no query, or another detail) is refused: until 2026-10-19 a canned pair of rows answered
# every one, whoever's mailbox and whatever was asked.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "messages" ]; then
  not_modelled "print messages other than a query with headers all, showlabels and showdate"
fi

# `<user> trash messages ids <MessageIDEntity>` (8186-8190; _processMessagesThreads with ids: nothing is listed, so Spam is no
# bar; no doit, no count check): the Phishing screen's trash of one mailbox's copies in Spam, by the IDs SpamCopies read. As
# GAM 7.48.30 does: a token for the user; getProfile, so Gmail off is userGmailServiceNotEnabledWarning (73); "User: <u>,
# Trash N Messages"; then Gmail's messages.trash on each ID, a batch request each: "  User: <u>, Message: <id>, Trashed
# (j/N)", or for an ID the mailbox doesn't have (messages.csv, not deleted) "  User: <u>, Message: <id>, Trash Failed: Does
# not exist (j/N)" on stderr (Gmail's notFound by _GMAIL_ERROR_REASON_TO_MESSAGE_MAP; entityActionFailedWarning, exit 50),
# the rest trashed. A copy already in Trash is trashed again without complaint (messages.trash as idempotent: assumed, not
# seen live). With GAM_MOCK_STATE a trashed message is $GAM_MOCK_STATE/trashed/<id>. Only a list of ASCII letters, digits,
# `-`, `_` and commas is modelled: GAM splits on whitespace too, and reads a file for a list selector. A word after the list
# that GAM takes there (doit, a count, csv…) isn't modelled, any other is GAM's invalid argument; and a suspended user's
# mailbox isn't, as for the trash by query: what GAM says for one is unknown.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "trash" ] && [ "${4:-}" = "messages" ] && [ "${5:-}" = "ids" ]; then
  user=$2
  [ $# -ge 6 ] || missing_arg "MessageIDEntity"
  if [ $# -gt 6 ]; then
    case "$(printf '%s' "$7" | tr '[:upper:]' '[:lower:]' | tr -d '_')" in
      doit|quick|notquick|maxtotrash|maxtoprocess|maxmessagesperthread|query|querytime*|matchlabel|or|and|labelids|\
      labelmatchpattern|sendermatchpattern|ids|csv) not_modelled "trash messages ids with $7" ;;
      *) invalid_arg "$7" ;;
    esac
  fi
  case "$6" in *[!A-Za-z0-9_,-]*) not_modelled "a message ID list like $6" ;; esac
  case "$(printf '%s' "$6" | tr '[:upper:]' '[:lower:]' | tr -d '_-')" in csvkmd|csvsubkey|csv|csvfile|file|csvdata) not_modelled "trash messages ids from $6" ;; esac
  known_user "$user" || token_refused "$user" Trash
  ! grep -F "\"primaryEmail\": \"$user\"" "$GAM_MOCK_FIXTURES/print_users.json" | grep -qF '"suspended": true' \
    || not_modelled "trash messages as a suspended user"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73
  fi
  set -f; ids=$(printf '%s' "$6" | tr ',' ' '); set +f
  n=$(printf '%s\n' $ids | grep -c . || true); failed=""
  if [ "$n" -eq 0 ]; then printf 'User: %s, Messages: 0, Not Trashed: No Messages matched\n' "$user" 1>&2; exit 60; fi
  if [ "$n" -eq 1 ]; then noun=Message; else noun=Messages; fi
  printf 'User: %s, Trash %s %s\n' "$user" "$n" "$noun"
  j=0
  for id in $ids; do
    j=$((j + 1)); of=""; [ "$n" -gt 1 ] && of=" ($j/$n)"
    if grep -q "^$user,$id," "$GAM_MOCK_FIXTURES/messages.csv" \
       && ! { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/deleted/$id" ]; }; then
      if [ -n "${GAM_MOCK_STATE:-}" ]; then mkdir -p "$GAM_MOCK_STATE/trashed"; : > "$GAM_MOCK_STATE/trashed/$id"; fi
      printf '  User: %s, Message: %s, Trashed%s\n' "$user" "$id" "$of"
    else
      printf '  User: %s, Message: %s, Trash Failed: Does not exist%s\n' "$user" "$id" "$of" 1>&2
      failed=1
    fi
  done
  [ -z "$failed" ] || exit 50
  exit 0
fi

# ---- One email out of every mailbox (docs/domains/phishing.md) --------------------------------------------------------
# `<UserTypeEntity> trash messages (query <QueryGmail>)+ [quick|notquick] [doit] [max_to_trash <Number>]` (8186-8190), as
# GAM 7.48.30's _processMessagesThreads runs it, for `all users` (every active user, by address: isSuspended=False) or
# `user <email>`. The mailboxes are mock_gam/messages.csv (`user,id,rfc822msgid,labels`, a message a line, made up); with
# GAM_MOCK_STATE a trashed message is $GAM_MOCK_STATE/trashed/<id>, and $GAM_MOCK_STATE/nogmail/<user> a person with
# Gmail off. Only the query the app sends, `rfc822msgid:<id> -in:sent`, is modelled; any other, and the grammar's other
# options, are refused as not modelled. As GAM does:
#   - every argument is read first, each keyword lowercased with `_` dropped (getArgument): `query` needs a value
#     (getString: missing or empty, Cmd.OB_QUERY), `max_to_trash` an integer x>=0 (getInteger), 0 being no limit; any
#     other word is an invalid argument; no query at all is "Missing argument: Expected <query|matchlabel|ids|labelids>";
#   - then per user: a token (token_refused, "User Trash Failed"); Gmail off, userGmailServiceNotEnabledWarning (73); the list
#     leaves Spam and Trash out (includeSpamTrash is False for trash) and, with `quick` (the default), asks Gmail for at
#     most max_to_trash, so only `notquick` sees more than the cap;
#   - none is "Messages: 0, Not Trashed: No Messages matched" (60); over the cap, "Count N exceeds maximum to Trash M"
#     (51); without doit, 'Use the "doit" argument to perform action' (51), each on stderr with (i/n) past one user;
#   - with doit, "Trash N Messages" and each message's "Trashed" on stdout;
#   - every user sets the exit code and the last one set stands (setSysExitRC): a domain's dry run is never 0;
#   - `all users … doit`, a domain-wide trash the app never sends, is refused as not modelled.
if { { [ "${1:-}" = "all" ] && [ "${2:-}" = "users" ]; } || [ "${1:-}" = "user" ]; } && [ "${3:-}" = "trash" ] \
   && [ "${4:-}" = "messages" ]; then
  entity=$1; target=${2:-}
  shift 4
  query=""; queries=0; quick=1; doit=""; max=1
  while [ $# -gt 0 ]; do
    word=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '_')
    case "$word" in
      query)
        [ $# -ge 2 ] || missing_arg "Query"
        [ -n "$2" ] || empty_arg "Query"
        queries=$((queries + 1)); query=$2; shift 2 ;;
      quick) quick=1; shift ;;
      notquick) quick=""; shift ;;
      doit) doit=1; shift ;;
      maxtotrash|maxtoprocess)
        [ $# -ge 2 ] || missing_arg "integer x>=0"
        value=$(printf '%s' "$2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$value" in ''|*[!0-9]*) usage_error "Invalid argument: Expected <integer x>=0>" ;; esac
        value=$(printf '%s' "$value" | sed 's/^0*//')
        if [ -z "$value" ]; then max=0; elif [ ${#value} -gt 9 ]; then max=999999999; else max=$value; fi
        shift 2 ;;
      matchlabel|or|and|labelids|ids|labelmatchpattern|sendermatchpattern|maxmessagesperthread|csv|todrive|querytime*)
        not_modelled "trash messages with $1" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ "$queries" -gt 0 ] || missing_arg "query|matchlabel|ids|labelids"
  [ "$queries" -eq 1 ] || not_modelled "trash messages with more than one query"
  case "$query" in
    "rfc822msgid:"*" -in:sent") msgid=${query#rfc822msgid:}; msgid=${msgid% -in:sent} ;;
    *) not_modelled "a Gmail query other than rfc822msgid:<id> -in:sent" ;;
  esac
  case "$msgid" in ''|*[[:space:]]*) not_modelled "a Gmail query other than rfc822msgid:<id> -in:sent" ;; esac
  if [ "$entity" = all ]; then
    [ -z "$doit" ] || not_modelled "all users trash messages with doit (the app trashes one mailbox at a time)"
    users=$(grep -vF '"suspended": true' "$GAM_MOCK_FIXTURES/print_users.json" \
      | sed -n 's/.*"primaryEmail": "\([^"]*\)".*/\1/p' | LC_ALL=C sort)
    count=$(printf '%s\n' "$users" | grep -c . || true)
    printf 'Getting all Users that match query (isSuspended=False isGuest=False), may take some time on a large Google Workspace Account...\n' 1>&2
    # getPageMessage(): "Got <n> Users...", the count the reader checks every user's line against.
    printf 'Got %s Users...\r\n' "$count" 1>&2
  else
    known_user "$target" || token_refused "$target" Trash
    ! grep -F "\"primaryEmail\": \"$target\"" "$GAM_MOCK_FIXTURES/print_users.json" | grep -qF '"suspended": true' \
      || not_modelled "trash messages as a suspended user"
    users=$target; count=1
  fi
  rc=0; i=0
  for user in $users; do
    i=$((i + 1))
    if [ "$count" -gt 1 ]; then n=" ($i/$count)"; else n=""; fi
    # The progress first: GAM prints it before the list call that finds Gmail off.
    printf 'Getting all Messages that match query ((%s)) for %s%s\n' "$query" "$user" "$n" 1>&2
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
      printf 'User: %s, Gmail Service/App not enabled%s\n' "$user" "$n" 1>&2
      rc=73; continue
    fi
    # Theirs, with this Message-ID, in neither Sent (the query), Spam nor Trash, and not trashed here since.
    ids=""; found=0
    while IFS=, read -r owner id message labels; do
      { [ "$owner" = "$user" ] && [ "$message" = "$msgid" ]; } || continue
      case " $labels " in *" SENT "*|*" SPAM "*|*" TRASH "*) continue ;; esac
      if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/trashed/$id" ]; then continue; fi
      if [ -n "$quick" ] && [ "$max" -gt 0 ] && [ "$found" -ge "$max" ]; then break; fi
      found=$((found + 1)); ids="$ids $id"
    done < "$GAM_MOCK_FIXTURES/messages.csv"
    if [ "$found" -eq 1 ]; then noun=Message; else noun=Messages; fi
    printf '\rGot %s %s that matched query ((%s)) for %s...\r\n' "$found" "$noun" "$query" "$user" 1>&2
    if [ "$found" -eq 0 ]; then
      printf 'User: %s, Messages: 0, Not Trashed: No Messages matched%s\n' "$user" "$n" 1>&2
      rc=60; continue
    fi
    if [ "$max" -gt 0 ] && [ "$found" -gt "$max" ]; then
      printf 'User: %s, %s: %s, Not Trashed: Count %s exceeds maximum to Trash %s%s\n' "$user" "$noun" "$found" "$found" "$max" "$n" 1>&2
      rc=51; continue
    fi
    if [ -z "$doit" ]; then
      printf 'User: %s, %s: %s, Not Trashed: Use the "doit" argument to perform action%s\n' "$user" "$noun" "$found" "$n" 1>&2
      rc=51; continue
    fi
    echo "User: $user, Trash $found $noun$n"
    j=0
    for id in $ids; do
      j=$((j + 1))
      if [ "$found" -gt 1 ]; then m=" ($j/$found)"; else m=""; fi
      if [ -n "${GAM_MOCK_STATE:-}" ]; then mkdir -p "$GAM_MOCK_STATE/trashed"; : > "$GAM_MOCK_STATE/trashed/$id"; fi
      echo "  User: $user, Message: $id, Trashed$m"
    done
  done
  exit "$rc"
fi

# `gam print cros [query <QueryCrOS>] [fields <CrOSFieldNameList>] formatjson` -> GAM's CSV, a `deviceId` and a
# `JSON` column per device (gam/__init__.py:25281-25291, header :25505-25507; Builder: Find Chromebooks).
# Every device in mock_gam/cros.json, whatever the query or fields (approximate, as `print users`). Without
# formatjson, with quotechar or with any other option of the grammar's (`gam print cros`) it is refused.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "cros" ]; then
  shift 2; fj=""
  while [ $# -gt 0 ]; do
    case "$1" in
      query) need_value $# "QueryCrOS"; shift 2 ;;
      fields) need_value $# "CrOSFieldNameList"; [ -n "$2" ] || empty_arg "CrOSFieldNameList"; shift 2 ;;
      formatjson) fj=1; shift ;;
      *) not_modelled "print cros with $1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print cros without formatjson"
  print_formatjson deviceId cros.json
  exit 0
fi

# `gam print chromeprofiles filter user_email="<address>" fields <ChromeProfileFieldNameList> formatjson` -> GAM's CSV,
# `name`, `profileId` and a `JSON` column per profile (doPrintShowChromeProfiles, gam/__init__.py:26525-26592 at 7.48.30;
# a person's page, Security tab): the profiles in mock_gam/chrome_profiles.json signed in with that address, none the
# titles alone (exit 0). Only that filter is modelled (the Chrome Management API's own field name, the address quoted);
# any other filter or option, or no formatjson, is refused; a field outside the grammar's <ChromeProfileFieldName> is
# getFieldsList's invalid choice. GAM_MOCK_STATE/noscope/chromemanagement is an authorization with no Chrome Management
# scope (buildGAPIObject: NO_SCOPES_FOR_API_RC, 15, before any request); GAM_MOCK_STATE/denied/chromeprofiles the API's
# refusal, without the Profiles scope (entityActionFailedExit, ACTION_FAILED_RC, 50; Google's words approximate).
# Not modelled: whether the API matches the address in another case, and what an unreported profile lacks.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "chromeprofiles" ]; then
  shift 2; fj=""; owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      filter|filters) need_value $# "String"
        case "$2" in user_email=\"?*\") owner=${2#user_email=\"}; owner=${owner%\"} ;; *) not_modelled "print chromeprofiles filter $2" ;; esac
        case "$owner" in *\"*|*\\*|*\**|*[[:space:]]*) not_modelled "print chromeprofiles filter $2" ;; esac
        shift 2 ;;
      fields) need_value $# "ChromeProfileFieldNameList"; [ -n "$2" ] || empty_arg "ChromeProfileFieldNameList"
        for field in $(printf '%s' "$2" | tr ',' ' '); do
          case "$field" in
            affiliationstate|annotatedlocation|annotateduser|attestationcredential|browserchannel|browserversion|deviceinfo|\
            displayname|extensioncount|firstenrollmenttime|identityprovider|lastactivitytime|lastpolicyfetchtime|\
            lastpolicysynctime|laststatusreporttime|name|osplatformtype|osplatformversion|osversion|policycount|profileid|\
            profilepermanentid|reportingdata|useremail|userid) ;;
            *) invalid_choice "$field" "affiliationstate|annotatedlocation|annotateduser|attestationcredential|browserchannel|browserversion|deviceinfo|displayname|extensioncount|firstenrollmenttime|identityprovider|lastactivitytime|lastpolicyfetchtime|lastpolicysynctime|laststatusreporttime|name|osplatformtype|osplatformversion|osversion|policycount|profileid|profilepermanentid|reportingdata|useremail|userid" ;;
          esac
        done
        shift 2 ;;
      formatjson) fj=1; shift ;;
      *) not_modelled "print chromeprofiles with $1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print chromeprofiles without formatjson"
  [ -n "$owner" ] || not_modelled "print chromeprofiles without a user_email filter"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/noscope/chromemanagement" ]; then
    printf '\nERROR: There are no scopes authorized for the API(s): Chrome Management API\n' 1>&2; exit 15
  fi
  printf 'Getting all Chrome Profiles that match query (user_email="%s")\n' "$owner" 1>&2
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/denied/chromeprofiles" ]; then
    printf '\nERROR: Chrome Profile: user_email="%s", Print Failed: Request had insufficient authentication scopes.\n' "$owner" 1>&2
    exit 50
  fi
  echo "name,profileId,JSON"
  while IFS= read -r record; do
    [ "$(json_text userEmail "$record")" = "$owner" ] || continue
    gam_row "$(json_text name "$record")" "$(json_text profileId "$record")" "$record"
  done < "$GAM_MOCK_FIXTURES/chrome_profiles.json"
  exit 0
fi

# `gam print mobile query email:<address> fields <MobileFieldNameList> formatjson` -> GAM's CSV, `resourceId` and a `JSON`
# column per device (doPrintMobileDevices, gam/__init__.py:34750-34891 at 7.48.30; the compromised-account check): the
# devices in mock_gam/mobile_devices.json with an owner the address starts, as the API's `email:` search matches a
# prefix (carol@example.com.au's phone answers carol@example.com), none the titles alone (exit 0). Only that
# query (_validateDeviceQuery: a field, a colon, a value, no `?`, else a usage error) and the grammar's field names;
# formatjson needs `resourceid` among them (its row is written from it). GAM_MOCK_STATE/denied/mobile is the API's
# refusal: ClientAPIAccessDeniedExit, the error then "Reauthentication is needed", API_ACCESS_DENIED_RC 12. Not modelled:
# Google's search beyond an owner's prefix.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "mobile" ]; then
  shift 2; fj=""; owner=""; fields=""
  while [ $# -gt 0 ]; do
    case "$1" in
      query) need_value $# "QueryMobile"
        case "$2" in *\?*|:*|*:) usage_error "Invalid Mobile Device query: $2" ;; email:?*) owner=${2#email:} ;;
          *:*) not_modelled "print mobile query $2" ;; *) usage_error "Invalid Mobile Device query: $2" ;; esac
        shift 2 ;;
      fields) need_value $# "MobileFieldNameList"; [ -n "$2" ] || empty_arg "MobileFieldNameList"; fields="$2"
        for field in $(printf '%s' "$2" | tr ',' ' '); do
          case "$field" in
            adbstatus|applications|basebandversion|bootloaderversion|brand|buildnumber|defaultlanguage|developeroptionsstatus|\
            devicecompromisedstatus|deviceid|devicepasswordstatus|email|encryptionstatus|firstsync|hardware|hardwareid|imei|\
            kernelversion|lastsync|managedaccountisonownerprofile|manufacturer|meid|model|name|networkoperator|os|\
            otheraccountsinfo|privilege|releaseversion|resourceid|securitypatchlevel|serialnumber|status|supportsworkprofile|\
            type|unknownsourcesstatus|useragent|wifimacaddress) ;;
            *) invalid_choice "$field" "MobileFieldName" ;;
          esac
        done
        shift 2 ;;
      formatjson) fj=1; shift ;;
      *) not_modelled "print mobile with $1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print mobile without formatjson"
  [ -n "$owner" ] || not_modelled "print mobile without an email: query"
  case ",$fields," in *,resourceid,*) ;; *) not_modelled "print mobile formatjson without resourceid (GAM's row needs it)" ;; esac
  printf 'Getting all Mobile Devices that match query (email:%s)\n' "$owner" 1>&2
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/denied/mobile" ]; then
    printf '\nERROR: Not Authorized to access this resource/api\n\nERROR: Reauthentication is needed, please run\n\ngam oauth create\n' 1>&2
    exit 12
  fi
  echo "resourceId,JSON"
  while IFS= read -r record; do
    case "$record" in *"\"$owner"*) gam_row "$(json_text resourceId "$record")" "$record" ;; esac   # a prefix, as the API's
  done < "$GAM_MOCK_FIXTURES/mobile_devices.json"
  exit 0
fi

# ---- Calendars (docs/domains/calendars.md; read from the vendored 7.48.22 build, not a tenant) --------------
# One data set: each directory user's calendar list (mock_gam/user_calendars/<user>.json), each calendar's
# rules (mock_gam/calendar_acls/<calendar>.json) and the rooms (mock_gam/resources.json), every record in the
# form GAM prints it. MockCalendarsTests.theCalendarsAgreeWithOneAnother holds them together. With
# GAM_MOCK_STATE, a calendar whose rules a write changed is read from $GAM_MOCK_STATE/acls/<calendar>, and a
# GAM_MOCK_STATE/nocalendar/<user> marker is a person with Calendar off.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# GAM's printGettingEntityItemForWhom, on stderr before a per-entity print (show_gettings is on by default):
# "Getting <items> for <whom>". GamError reads it as an unknown line; the app's reads drop it (GettingLines).
getting() { printf 'Getting %s for %s\n' "$1" "$2" 1>&2; }
calendar_off() { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nocalendar/$1" ]; }
# userCalServiceNotEnabledWarning (notACalendarUser): SERVICE_NOT_APPLICABLE_RC.
calendar_service_off() { printf 'User: %s, Calendar Service/App not enabled\n' "$1" 1>&2; exit 73; }
calendar_key() {  # <calendar id>: as the files name it (Google compares ids case-insensitively); a list or path isn't one
  case "$1" in *,*|*/*|"") not_modelled "a calendar id like $1" ;; esac
  lower "$1"
}
acl_file() {  # <calendar key>: the file holding its rules, or nothing when there is no such calendar
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/acls/$1" ]; then printf '%s' "$GAM_MOCK_STATE/acls/$1"
  elif [ -f "$GAM_MOCK_FIXTURES/calendar_acls/$1.json" ]; then printf '%s' "$GAM_MOCK_FIXTURES/calendar_acls/$1.json"; fi
}
# A secondary calendar's owner: the user whose `user_owned_calendars` file lists it, or whoever it was handed to
# while the mock keeps state; nothing for a calendar the fixtures don't hold.
calendar_owner() {  # <calendar id>
  key=$(lower "$1")
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/calendar_owner/$key" ]; then cat "$GAM_MOCK_STATE/calendar_owner/$key"; return; fi
  file=$(grep -ilF "\"id\": \"$key\"" "$GAM_MOCK_FIXTURES"/user_owned_calendars/*.json 2>/dev/null | head -n 1)
  [ -n "$file" ] || return 0
  file=${file##*/}; file=${file%.json}; printf '%s' "${file%.hidden}"
}

rows_of() {  # <file> <key value>...: each record in the file after the key columns, as GAM's formatjson row
  rows_file=$1; shift
  while IFS= read -r record; do gam_row "$@" "$record"; done < "$rows_file"
}
# _printShowCalendarACLs (:41833-41902): the rules, or the header alone and NO_ENTITIES_FOUND_RC (60) for none.
print_acl_rows() {  # <file> <key value>...
  [ -s "$1" ] || exit 60
  rows_of "$@"
}

# `gam user <u> print calendars fields id,summary,accessrole,primary formatjson` (printShowCalendars, :55691-55840)
# -> primaryEmail,calendarId,JSON, the person's own calendar list. Each field must be a <CalendarListField>
# (grammar 6266-6283), matched lowercased as GAM matches it; only the four the app asks for are modelled, and
# GAM's other options are refused rather than answered in a guessed shape. GAM acts as the person: one who
# isn't a user fails before anything prints, and one with Calendar off fails after the "Getting" line, exit 73.
# `... ownedsecondary [showhidden] fields id,summary formatjson`: the calendars on that list the person is
# dataOwner of, `dataOwner` added to the fields (:55747-55748, :55771-55776). The grammar (6288) shows the two
# as alternatives, but they're one parser loop. calendarList.list leaves hidden entries out unless showHidden:
# `user_owned_calendars/<u>.json` are the visible ones, `<u>.hidden.json` the hidden ones.
CALENDAR_LIST_FIELDS="accessrole|backgroundcolor|colorid|conferenceproperties|defaultreminders|deleted|description|foregroundcolor|hidden|id|location|notificationsettings|primary|selected|summary|summaryoverride|timezone"
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "calendars" ]; then
  user=$(lower "$2"); shift 4; fj=""; want=" "; owned=""; hidden=""
  while [ $# -gt 0 ]; do
    case "$1" in
      fields)
        need_value $# "CalendarListFieldList"
        [ -n "$2" ] || empty_arg "CalendarListFieldList"
        set -f
        for field in $(printf '%s' "$2" | tr ',' ' '); do
          field=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]' | tr -d '_')
          case "|$CALENDAR_LIST_FIELDS|" in *"|$field|"*) ;; *) invalid_choice "$field" "$CALENDAR_LIST_FIELDS" ;; esac
          case "$field" in id|summary|accessrole|primary) want="$want$field " ;; *) not_modelled "print calendars field $field" ;; esac
        done
        set +f
        shift 2 ;;
      formatjson) fj=1; shift ;;
      ownedsecondary) owned=1; shift ;;
      showhidden) hidden=1; shift ;;
      quotechar|delimiter|permissions|oneitemperrow|primary|noprimary|nogroups|noresources|nosystem|nousers|\
      addcsvdata|minaccessrole|showdeleted|showownorganizationonly|allcalendars)
        not_modelled "print calendars with $1" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print calendars without formatjson"
  if [ -n "$owned" ]; then
    [ "$want" = " id summary " ] || not_modelled "print calendars ownedsecondary with fields$want"
    known_user "$user" || not_a_user "$user" Print
    getting Calendars "$user"
    if calendar_off "$user"; then calendar_service_off "$user"; fi
    echo "primaryEmail,calendarId,JSON"
    for file in "$GAM_MOCK_FIXTURES/user_owned_calendars/$user.json" ${hidden:+"$GAM_MOCK_FIXTURES/user_owned_calendars/$user.hidden.json"}; do
      [ -f "$file" ] || continue
      while IFS= read -r record; do
        id=$(json_text id "$record")
        [ "$(calendar_owner "$id")" = "$user" ] || continue   # handed over since (`calendars … transfer ownership`)
        gam_row "$user" "$id" "$record"
      done < "$file"
    done
    exit 0
  fi
  [ -z "$hidden" ] || not_modelled "print calendars with showhidden"
  for field in id summary accessrole primary; do
    case "$want" in *" $field "*) ;; *) not_modelled "print calendars without field $field" ;; esac
  done
  known_user "$user" || not_a_user "$user" Print
  getting Calendars "$user"
  if calendar_off "$user"; then calendar_service_off "$user"; fi
  echo "primaryEmail,calendarId,JSON"
  if [ -f "$GAM_MOCK_FIXTURES/user_calendars/$user.json" ]; then
    while IFS= read -r record; do
      gam_row "$user" "$(json_text id "$record")" "$record"
    done < "$GAM_MOCK_FIXTURES/user_calendars/$user.json"
  else   # an account `create user` made: its primary calendar only
    gam_row "$user" "$user" "{\"accessRole\": \"owner\", \"id\": \"$user\", \"primary\": true, \"summary\": \"$user\"}"
  fi
  exit 0
fi

# `gam user <u> print calendaracls primary formatjson` (printShowCalendarACLs, :55972) -> primaryEmail,calendarId,JSON,
# `primary` read as the person (:55338-55339), each rule's id, role and scope only (:41839). GAM checks the
# primary calendar before it says it's getting the rules, so Calendar off fails without the "Getting" line.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "calendaracls" ]; then
  [ $# -ge 5 ] || missing_arg "UserCalendarEntity"
  [ "$5" = "primary" ] || not_modelled "print calendaracls of a calendar but primary"
  user=$(lower "$2"); shift 5; fj=""
  while [ $# -gt 0 ]; do
    case "$1" in
      formatjson) fj=1; shift ;;
      quotechar|noselfowner|addcsvdata) not_modelled "print calendaracls with $1" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print calendaracls without formatjson"
  known_user "$user" || not_a_user "$user" Print
  if calendar_off "$user"; then calendar_service_off "$user"; fi
  file=$(acl_file "$user")
  [ -n "$file" ] || not_modelled "the calendar rules of $user"
  getting "Calendar ACLs" "$user"
  echo "primaryEmail,calendarId,JSON"
  print_acl_rows "$file" "$user" "$user"
  exit 0
fi

# `gam calendars <list> transfer ownership <user>` (doCalendarsTransferOwnership, :55992-56014; GamUpdate 7.46.04;
# the grammar's 1685 lacks `ownership`, which getChoice requires: anything else is an invalid choice). Each calendar
# in the comma list in turn, "(i/n)" after each line when there's more than one: validateCalendar gets it with the
# admin's own access first, so one the admin can't see (here: one the fixtures don't hold) fails "Not Found" before
# any transfer; then transferOwnership as the admin: "Calendar: <id>, Ownership Transferred to: <user>" on stdout.
# A failure leaves the rest done, ACTION_FAILED_RC (50) at the end. (The new owner's refusal wording is
# approximate: the API's reason.)
if [ "${1:-}" = "calendars" ] && [ "${3:-}" = "transfer" ]; then
  [ $# -ge 4 ] || missing_arg "ownership"
  [ "$4" = "ownership" ] || invalid_choice "$4" "ownership"
  [ $# -ge 5 ] || missing_arg "EmailAddress"
  [ $# -eq 5 ] || invalid_arg "$6"
  to=$(lower "$5"); failed=""
  set -f; ids=$(printf '%s' "$2" | tr ',' ' '); set +f
  n=$(printf '%s\n' $ids | grep -c . || true); i=0
  for id in $ids; do
    i=$((i + 1)); of=""; [ "$n" -gt 1 ] && of=" ($i/$n)"
    owner=$(calendar_owner "$id")
    # `$GAM_MOCK_STATE/adminhidden/<id>`: a calendar the admin can't see, which validateCalendar's get can't find.
    if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/adminhidden/$(lower "$id")" ]; then owner=""; fi
    if [ -z "$owner" ]; then
      printf 'Calendar: %s, Transfer Ownership Failed: Not Found%s\n' "$id" "$of" 1>&2; failed=1; continue
    fi
    if ! known_user "$to"; then
      printf 'Calendar: %s, Transfer Ownership to: %s, Transfer Ownership Failed: Invalid Value%s\n' "$id" "$to" "$of" 1>&2
      failed=1; continue
    fi
    if [ -n "${GAM_MOCK_STATE:-}" ]; then
      mkdir -p "$GAM_MOCK_STATE/calendar_owner"; printf '%s' "$to" > "$GAM_MOCK_STATE/calendar_owner/$(lower "$id")"
    fi
    printf 'Calendar: %s, Ownership Transferred to: %s%s\n' "$id" "$to" "$of"
  done
  [ -z "$failed" ] || exit 50
  exit 0
fi

# `gam calendars <id> print acls|calendaracls formatjson` (doCalendarsPrintShowACLs, :41940) -> calendarId,JSON.
# GAM acts as the admin for an id ending .calendar.google.com, and as the address otherwise (validateCalendar,
# :41572-41589); a calendar it can't get fails "Calendar: <id>, Print Failed: Not Found", ACTION_FAILED_RC
# (50), before the "Getting" line. (Approximate: whether the admin can read a secondary calendar it isn't on,
# plan Q2; the mock answers for every calendar it holds.)
if [ "${1:-}" = "calendars" ] && [ "${3:-}" = "print" ] && { [ "${4:-}" = "calendaracls" ] || [ "${4:-}" = "acls" ]; }; then
  cal="$2"; key=$(calendar_key "$2"); shift 4; fj=""
  while [ $# -gt 0 ]; do
    case "$1" in
      formatjson) fj=1; shift ;;
      quotechar|noselfowner|addcsvdata) not_modelled "print calendaracls with $1" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print calendaracls without formatjson"
  file=$(acl_file "$key")
  if [ -z "$file" ]; then printf 'Calendar: %s, Print Failed: Not Found\n' "$cal" 1>&2; exit 50; fi
  getting "Calendar ACLs" "$cal"
  echo "calendarId,JSON"
  print_acl_rows "$file" "$cal"
  exit 0
fi

# `gam print resources fields id,name,email,resourcetype,buildingid formatjson` (doPrintShowResourceCalendars,
# :41423-41548) -> resourceId,resourceName,JSON; buildingId as `id:<id>` beside a looked-up buildingName, which
# is the raw id for a building GAM can't name (:41515-41517, :40799-40802). Each field must be a
# <ResourceFieldName> (grammar 4877-4900); only the five the app asks for are modelled. GAM's `query` is a
# structured filter GamGUI never sends (it filters the list itself), so it is refused, as is every other option.
RESOURCE_FIELDS="acls|autoacceptinvitations|buildingid|calendar|capacity|category|description|email|featureinstances|features|floor|floorsection|generatedresourcename|id|name|resourcecategory|resourcedescription|resourceemail|resourceid|resourcename|resourcetype|type|uservisibledescription"
if [ "${1:-}" = "print" ] && [ "${2:-}" = "resources" ]; then
  shift 2; fj=""; want=" "
  while [ $# -gt 0 ]; do
    case "$1" in
      fields)
        need_value $# "ResourceFieldNameList"
        [ -n "$2" ] || empty_arg "ResourceFieldNameList"
        set -f
        for field in $(printf '%s' "$2" | tr ',' ' '); do
          field=$(printf '%s' "$field" | tr '[:upper:]' '[:lower:]' | tr -d '_')
          case "|$RESOURCE_FIELDS|" in *"|$field|"*) ;; *) invalid_choice "$field" "$RESOURCE_FIELDS" ;; esac
          case "$field" in id|name|email|resourcetype|buildingid) want="$want$field " ;; *) not_modelled "print resources field $field" ;; esac
        done
        set +f
        shift 2 ;;
      formatjson) fj=1; shift ;;
      query|allfields|acls|noselfowner|calendar|convertcrnl|quotechar|showitemcountonly) not_modelled "print resources with $1" ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$fj" ] || not_modelled "print resources without formatjson"
  for field in id name email resourcetype buildingid; do
    case "$want" in *" $field "*) ;; *) not_modelled "print resources without field $field" ;; esac
  done
  echo "resourceId,resourceName,JSON"
  while IFS= read -r record; do
    gam_row "$(json_text resourceId "$record")" "$(json_text resourceName "$record")" "$record"
  done < "$GAM_MOCK_FIXTURES/resources.json"
  exit 0
fi

# Reads whose GAM shape this mock doesn't model, refused rather than answered in a guessed one: they printed
# NDJSON, which GAM never prints for them. No app screen reads them yet. Their CSV, read at 7.48.22, for
# whoever models one (in GAM's dialect, gam_row; the data from git history):
# - `user <u> print filelist … formatjson`: an `Owner` column, then Drive's own (printFileList, :60674).
# - `all users print calendars … formatjson`: primaryEmail,calendarId,JSON, each user's own calendars
#   (printShowCalendars, :55691, :55800-55818); a person with Calendar off exits 73 (the C3 index).
# - `calendars <cal> print events … formatjson`: calendarId,id,JSON, only the events the query or event ID
#   selects (:43147-43165, :43440-43441).
case "${1:-} ${2:-} ${3:-} ${4:-}" in
  "user "*" print filelist"|"all users print calendars"|"calendars "*" print events") not_modelled "gam $*" ;;
esac

# `gam <UserTypeEntity> show backupcodes|verificationcodes` (no options) -> text; a Builder sensitive
# read. The canned codes are what the audit must never contain.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "show" ] && { [ "${4:-}" = "backupcodes" ] || [ "${4:-}" = "verificationcodes" ]; }; then
  [ $# -eq 4 ] || invalid_arg "$5"
  check_exists "User" "$2"
  printf 'User: %s, Backup Verification Codes (2)\n  1: 11112222\n  2: 33334444\n' "$2"
  exit 0
fi

# Gmail settings reads the compromised-account check makes (GAM 7.48.30). Each acts as the person: one who isn't a user
# fails at the token (need_user), and Gmail off for them (GAM_MOCK_STATE/nogmail/<u>) is serviceNotAvailable,
# userGmailServiceNotEnabledWarning, exit 73, after GAM's "Getting <items> for <u>" and with the CSV titles alone (GAM
# writes the file at the end). Each takes only the arguments the app sends; anything else isn't modelled.
gmail_off() { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$1" ]; }
gmail_read() {  # <user> <items> <titles>: the token, the "Getting" line, and Gmail off
  need_user "$1" Print
  getting "$2" "$1"
  if gmail_off "$1"; then printf 'User: %s, Gmail Service/App not enabled\n' "$1" 1>&2; printf '%s\n' "$3"; exit 73; fi
}

# `gam user <u> print forwardingaddresses` (printShowForwardingAddresses, :78708-78760): `User,forwardingEmail,
# verificationStatus`, one row per address Gmail has, none for none. carol@ has her own (accepted) and one pending.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "forwardingaddresses" ]; then
  user=$(lower "$2")
  [ $# -eq 4 ] || not_modelled "print forwardingaddresses with $5"
  titles='User,forwardingEmail,verificationStatus'
  gmail_read "$user" "Forwarding Addresses" "$titles"
  printf '%s\n' "$titles"
  case "$user" in
    carol@example.com) printf '%s,carol.home@example.org,accepted\n%s,mailbox.backup@example.net,pending\n' "$user" "$user" ;;
  esac
  exit 0
fi

# `gam user <u> print forward` (printShowForward, :78577-78629): `User,forwardEnabled,forwardTo,disposition`, the address
# and disposition only while on. carol@ forwards to her own address; with GAM_MOCK_STATE, `forward` below keeps what it set.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "forward" ]; then
  user=$(lower "$2")
  [ $# -eq 4 ] || not_modelled "print forward with $5"
  titles='User,forwardEnabled,forwardTo,disposition'
  gmail_read "$user" "Forward Enabled" "$titles"
  printf '%s\n' "$titles"
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/forward/$user" ]; then
    printf '%s,%s\n' "$user" "$(cat "$GAM_MOCK_STATE/forward/$user")"
  else
    case "$user" in
      carol@example.com) printf '%s,True,carol.home@example.org,leaveInInbox\n' "$user" ;;
      *) printf '%s,False,,\n' "$user" ;;
    esac
  fi
  exit 0
fi

# `gam user <u> print sendas verifyonly` (printShowSendAs, :79158-79213): a row per address Gmail lists, the primary
# first, each signature a True/False (verifyonly). Column order approximate (`sortall`); the app reads by name. carol@
# can also send as an outside address; with GAM_MOCK_STATE, one `delete sendas` removed is left out.
sendas_deleted() { [ -n "${GAM_MOCK_STATE:-}" ] && grep -qixF -- "$2" "$GAM_MOCK_STATE/sendas_deleted/$1" 2>/dev/null; }
sendas_of() {  # <user>: each address the user can send as, beyond the primary, one per line
  case "$1" in carol@example.com) printf 'billing.desk@example.net\n' ;; esac
}
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "sendas" ]; then
  user=$(lower "$2")
  [ "$#" -eq 5 ] && [ "$5" = "verifyonly" ] || not_modelled "print sendas with ${5:-no options}"
  titles='User,displayName,isDefault,isPrimary,replyToAddress,sendAsEmail,signature,treatAsAlias,verificationStatus'
  gmail_read "$user" "SendAs Addresses" "$titles"
  printf '%s\n%s,,True,True,,%s,False,,\n' "$titles" "$user" "$user"
  sendas_of "$user" | while IFS= read -r address; do
    sendas_deleted "$user" "$address" || printf '%s,Billing Desk,False,False,,%s,False,False,accepted\n' "$user" "$address"
  done
  exit 0
fi

# `gam user <u> delete sendas <EmailAddressEntity>` (deleteInfoSendAs, :79126-79156): "User: <u>, Delete 1 SendAs Address",
# then the address indented, "Deleted"; one Gmail doesn't list fails notFound, the primary cannotDeletePrimarySendAs
# (entityActionFailedWarning, exit 50; the API's words approximate). Only one plain address is modelled: GAM splits on
# commas and whitespace, and reads a file for a list selector.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "delete" ] && [ "${4:-}" = "sendas" ]; then
  user=$(lower "$2")
  [ $# -ge 5 ] || missing_arg "EmailAddressEntity"
  [ $# -eq 5 ] || invalid_arg "$6"
  case "$5" in *@*) ;; *) not_modelled "delete sendas $5" ;; esac
  case "$5" in *[,[:space:]]*) not_modelled "a send-as list like $5" ;; esac
  address=$(lower "$5")
  need_user "$user" Delete
  printf 'User: %s, Delete 1 SendAs Address\n' "$user"
  if gmail_off "$user"; then printf '  User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73; fi
  if [ "$address" = "$user" ]; then
    printf '  User: %s, SendAs Address: %s, Delete Failed: Cannot delete the primary send-as address\n' "$user" "$address" 1>&2; exit 50
  fi
  if sendas_deleted "$user" "$address" || ! sendas_of "$user" | grep -qixF -- "$address"; then
    printf '  User: %s, SendAs Address: %s, Delete Failed: Not Found\n' "$user" "$address" 1>&2; exit 50
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then mkdir -p "$GAM_MOCK_STATE/sendas_deleted"; printf '%s\n' "$address" >> "$GAM_MOCK_STATE/sendas_deleted/$user"; fi
  printf '  User: %s, SendAs Address: %s, Deleted\n' "$user" "$address"
  exit 0
fi

# `gam print admins user <u>` (doPrintShowAdmins, :17653-17846): "Getting all Admin Role Assignments" then
# PRINT_ADMIN_TITLES and a row per role assigned to the person directly. alice@ is the super admin (_SEED_ADMIN_ROLE is
# that role's name); others hold none. An address that isn't a user is userNotFound: entityUnknownWarning, exit 56.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "admins" ]; then
  [ "${3:-}" = "user" ] && [ $# -eq 4 ] || not_modelled "print admins ${3:-} ${5:-}"
  user=$(lower "$4")
  printf 'Getting all Admin Role Assignments\n' 1>&2
  in_directory "$user" || does_not_exist "Administrator" "$4"
  printf 'roleAssignmentId,roleId,role,assignedTo,assignedToUser,assignedToGroup,assignedToServiceAccount,assignedToUnknown,'
  printf 'scopeType,orgUnitId,orgUnit,expirationDetails.expireTime\n'
  case "$user" in alice@example.com) printf '9170001,9170000,_SEED_ADMIN_ROLE,1001,alice@example.com,,,False,CUSTOMER,,,\n' ;; esac
  exit 0
fi

# `gam user <email> print delegates` (no formatjson) -> THAT user's delegates as plain CSV, like real GAM.
# printShowDelegates (gam/__init__.py:77232-77313) says "Getting all Delegates for <user>" first; Gmail off
# for the user (a GAM_MOCK_STATE/nogmail/<user> marker) is Gmail's "Mail service not enabled", read as
# serviceNotAvailable (gamlib/glgapi.py:311) and reported by userGmailServiceNotEnabledWarning (:2533,
# :2498-2502), exit 73; the CSV header is still written, with no rows.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "delegates" ]; then
  [ $# -eq 4 ] || invalid_arg "$5"
  need_user "$2" Print
  printf 'Getting all Delegates for %s\n' "$2" 1>&2
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$2" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$2" 1>&2
    printf 'User,delegateAddress,delegationStatus\n'
    exit 73
  fi
  printf 'User,delegateAddress,delegationStatus\n'
  delegates_of "$2" | while IFS= read -r d; do
    if [ -n "$d" ]; then printf '%s,%s,accepted\n' "$2" "$d"; fi
  done
  exit 0
fi

# `gam user <u> print filters labelidsonly formatjson` (printShowFilters, :77655-77712) -> CSV, each filter's
# flattened columns (in GAM's sort order) then its JSON. `user_filters/<u>.csv` is that output as GAM would print it;
# with GAM_MOCK_STATE, a filter `delete filters` removed is left out (the header stays the fixture's, where GAM keeps
# only the columns of rows written: the app reads the JSON). None: GAM's titles alone, `User,id`. As the person:
# "Getting Filters for <u>" first; Gmail off is userGmailServiceNotEnabledWarning, exit 73, then the titles.
deleted_filter() { [ -n "${GAM_MOCK_STATE:-}" ] && grep -qxF "$2" "$GAM_MOCK_STATE/filters_deleted/$1" 2>/dev/null; }
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && [ "${4:-}" = "filters" ]; then
  user=$(lower "$2"); shift 4
  [ "$*" = "labelidsonly formatjson" ] || not_modelled "print filters with $*"
  need_user "$user" Print
  printf 'Getting Filters for %s\n' "$user" 1>&2
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; printf 'User,id\n'; exit 73
  fi
  file="$GAM_MOCK_FIXTURES/user_filters/$user.csv"; rows=""
  if [ -f "$file" ]; then
    while IFS= read -r row; do
      id=$(printf '%s' "$row" | cut -d, -f2)
      deleted_filter "$user" "$id" || rows="$rows$row
"
    done <<EOF_ROWS
$(tail -n +2 "$file")
EOF_ROWS
  fi
  if [ -n "$rows" ]; then head -n 1 "$file"; printf '%s' "$rows"; else printf 'User,id\n'; fi
  exit 0
fi

# `gam user <u> delete filters <FilterIDEntity>` (deleteFilters, :77581-77604): "User: <u>, Delete <n> Filter(s)",
# then each in turn, indented, "User: <u>, Filter: <id>, Deleted (j/n)"; one Gmail doesn't have fails "Delete Failed:
# Not Found" (the API's words, approximate) and the rest are still deleted, exit 50 at the end. An empty list is
# NO_ENTITIES_FOUND_RC (60) after the count line; Gmail off, the count line, then the indented warning, exit 73.
# Not modelled, so never answered more kindly than GAM: whitespace (Python's split takes more than sh's, and getChoice
# strips it first) or anything but ASCII letters, digits, `_`, `-` and commas; and a list selector word (file, csv,
# csvfile, csvkmd, csvsubkey, csvdata, ignoring case, `_` and `-`), which GAM reads a file from (getEntityList).
if [ "${1:-}" = "user" ] && [ "${3:-}" = "delete" ] && [ "${4:-}" = "filters" ]; then
  user=$(lower "$2")
  [ $# -ge 5 ] || missing_arg "FilterIDEntity"
  [ $# -eq 5 ] || invalid_arg "$6"
  case "$5" in *[!A-Za-z0-9_,-]*) not_modelled "a filter ID list like $5" ;; esac
  case "$(lower "$5" | tr -d '_-')" in csvkmd|csvsubkey|csv|csvfile|file|csvdata) not_modelled "delete filters from $5" ;; esac
  need_user "$user" Delete
  set -f; ids=$(printf '%s' "$5" | tr ',' ' '); set +f
  n=$(printf '%s\n' $ids | grep -c . || true); i=0; failed=""
  if [ "$n" -eq 1 ]; then noun=Filter; else noun=Filters; fi
  printf 'User: %s, Delete %s %s\n' "$user" "$n" "$noun"
  [ "$n" -gt 0 ] || exit 60
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf '  User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73
  fi
  for id in $ids; do
    i=$((i + 1)); of=""; [ "$n" -gt 1 ] && of=" ($i/$n)"
    if deleted_filter "$user" "$id" || ! grep -q "^[^,]*,$id," "$GAM_MOCK_FIXTURES/user_filters/$user.csv" 2>/dev/null; then
      printf '  User: %s, Filter: %s, Delete Failed: Not Found%s\n' "$user" "$id" "$of" 1>&2; failed=1; continue
    fi
    if [ -n "${GAM_MOCK_STATE:-}" ]; then mkdir -p "$GAM_MOCK_STATE/filters_deleted"; printf '%s\n' "$id" >> "$GAM_MOCK_STATE/filters_deleted/$user"; fi
    printf '  User: %s, Filter: %s, Deleted%s\n' "$user" "$id" "$of"
  done
  [ -z "$failed" ] || exit 50
  exit 0
fi

# `gam user <admin> check serviceaccount (scope|scopes <APIScopeURLList>)*`, as the vendored 7.48.11
# build's checkServiceAccount prints it: `{label:73} PASS`, then each scope checked, sorted, as
# `  {scope:73} PASS (j/n)`. A scope asked for must be a SERVICE-ACCOUNT scope (lowercased, commas or
# spaces between) or GAM exits with an invalid choice — admin.directory.* are client-access scopes (the
# admin token, `gam oauth create`) and are refused here as GAM refuses them. The simulated tenant
# authorized exactly the scopes GamGUI pre-fills (core/setup.py DWD_SCOPES). A bare check asks about
# GAM's own larger default set, so its extra scopes FAIL and GAM exits SCOPES_NOT_AUTHORIZED_RC (10).
# A `*partialdwd*` admin's tenant authorized all of those but gmail.settings.sharing and tasks. On a FAIL,
# checkServiceAccount appends userinfo.email to the scopes checked and prints SCOPE_AUTHORIZATION_FAILED
# with the short link and the admin.google.com one (clientScopeToAdd = those scopes, sorted; authuser =
# the admin) — all on STDOUT (printLine), nothing on stderr — then exits SCOPES_NOT_AUTHORIZED_RC (10).
# The exit codes are the build's *_RC values; tests/test_gam_exit_codes.py holds them to it.
SA_AUTHORIZED="https://mail.google.com/ https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.settings.basic https://www.googleapis.com/auth/gmail.settings.sharing https://www.googleapis.com/auth/tasks"
# A sample of GAM's other default-on service-account scopes (gamlib glapi _SVCACCT_SCOPES).
SA_OTHER="https://www.googleapis.com/auth/documents https://www.googleapis.com/auth/drive.activity https://www.googleapis.com/auth/forms.body https://www.googleapis.com/auth/keep https://www.googleapis.com/auth/spreadsheets"
if [ "${1:-}" = "user" ] && [ "${3:-}" = "check" ] && [ "${4:-}" = "serviceaccount" ]; then
  sa_user="$2"; shift 4
  asked=""
  while [ $# -gt 0 ]; do
    case "$1" in
      scope|scopes)
        need_value $# "APIScopeURLList"
        [ -n "$2" ] || empty_arg "APIScopeURLList"
        for s in $(printf '%s' "$2" | tr 'A-Z,' 'a-z '); do
          case " $SA_AUTHORIZED $SA_OTHER " in
            *" $s "*) asked="$asked $s" ;;
            *) invalid_choice "$s" "$(printf '%s' "$SA_AUTHORIZED $SA_OTHER" | tr ' ' '|')" ;;
          esac
        done
        shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ -n "$asked" ] || asked="$SA_AUTHORIZED $SA_OTHER"
  checked=$(printf '%s\n' $asked | sort -u)
  n=$(printf '%s\n' "$checked" | wc -l | tr -d ' ')
  # A rejected service-account key (deleted or rotated in the Cloud console): the key row FAILs and GAM
  # stops before any scope is checked — no delegation table, no link. invalidOauth2serviceJsonExit then
  # writes its error and instructions to stderr and exits OAUTH2SERVICE_JSON_REQUIRED_RC (16).
  case "$sa_user" in
    *badkey*)
      printf '%-73s %s\n' "System time status" "PASS" \
        "Service Account Private Key Authentication" "FAIL"
      printf '\nERROR: Service Account OAuth2 File: %s, Does not exist or has invalid format, Authentication\n' \
        "$GAMCFGDIR/oauth2service.json" 1>&2
      printf 'Please run\n\ngam create|use project\ngam user <user> update serviceaccount\n\nto create and authorize a Service account.\n' 1>&2
      exit 16 ;;
  esac
  printf '%-73s %s\n' "System time status" "PASS" \
    "Service Account Private Key Authentication" "PASS" \
    "Service Account Private Key age; Google recommends rotating keys on a routine basis" "PASS"
  printf 'Domain-wide Delegation authentication:, User: %s, Scopes: %s\n' "$sa_user" "$n"
  granted="$SA_AUTHORIZED"
  case "$sa_user" in
    *partialdwd*) granted=$(printf '%s\n' $SA_AUTHORIZED | grep -v -e '/gmail\.settings\.sharing$' -e '/tasks$' | tr '\n' ' ') ;;
  esac
  j=0; failed=0
  for s in $checked; do
    j=$((j + 1))
    case " $granted " in *" $s "*) st=PASS ;; *) st=FAIL; failed=1 ;; esac
    printf '  %-73s %s (%d/%d)\n' "$s" "$st" "$j" "$n"
  done
  if [ "$failed" = 1 ]; then
    to_add=$(printf '%s\n' $checked https://www.googleapis.com/auth/userinfo.email | sort -u | paste -sd, -)
    printf '\nSome scopes FAILED or should be DISABLED!\nTo update authorization, please go to the following link in your browser:\n%s\n    %s\n\n' \
      "https://gam-shortn.appspot.com/mockdwd" \
      "https://admin.google.com/ac/owl/domainwidedelegation?clientScopeToAdd=$to_add&clientIdToAdd=1234567890&overwriteClientId=true&authuser=$sa_user"
    printf '%s\n' "You will be directed to the Google Workspace admin console Security > API Controls > Domain-wide Delegation page" \
      'The "Add a new Client ID" box will open' 'Make sure that "Overwrite existing client ID" is checked' 'Click AUTHORIZE' \
      "When the box closes you're done" \
      'After authorizing it may take some time for this test to pass so wait a few moments and then try this command again.' '' ''
    exit 10
  fi
  printf '\nAll scopes PASSED!\n\nService Account Client name: 1234567890 is fully authorized.\n\n'
  exit 0
fi

# `gam print datatransfers olduser <email>` -> CSV; a *pending* user has an in-flight transfer.
if [ "${1:-}" = "print" ] && [ "${2:-}" = "datatransfers" ]; then
  case "${4:-}" in
    *pending*) cat "$GAM_MOCK_FIXTURES/datatransfers_pending.csv" ;;
    *)         printf 'id,oldOwnerUserEmail,newOwnerUserEmail,overallTransferStatusCode,application\n' ;;
  esac
  exit 0
fi

# `gam user <u> print vaultholds|holds` (printShowUserVaultHolds, :45612-45690) -> CSV, no formatjson: every
# open matter's holds that name the person or an org unit above them, `User,matterId,matterName,holdId,name,
# orgUnitId,orgUnitPath` (its titles in their given order: `sortall` re-inserts each as given), the header alone
# for none. `vault_holds.csv` holds the rows. GAM acts as the admin throughout: it lists the open matters and their
# holds first, so a Vault refusal fails before anything prints, entityActionFailedWarning "Vault Hold Print Failed:
# <reason>", ACTION_FAILED_RC (50), modelled by `$GAM_MOCK_STATE/novault` (the reason is the API's; a token
# whose file names no Vault scope exits 15 earlier); then it reads each person's org units with the Directory, and
# one who isn't a user ends it: the command echo, "ERROR: User: <u>, Does not exist", ENTITY_DOES_NOT_EXIST_RC
# (getAllParentOrgUnitsForUser -> entityDoesNotExistExit, :1762-1768, :800-805).
if [ "${1:-}" = "user" ] && [ "${3:-}" = "print" ] && { [ "${4:-}" = "vaultholds" ] || [ "${4:-}" = "holds" ]; }; then
  user=$(lower "$2"); shift 4
  if [ $# -gt 0 ]; then
    case "$1" in todrive) not_modelled "print vaultholds todrive" ;; *) invalid_arg "$1" ;; esac
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/novault" ]; then
    echo "Vault Hold Print Failed: Request had insufficient authentication scopes." 1>&2; exit 50
  fi
  if ! known_user "$user"; then
    printf 'Command: gam %s\n\nERROR: User: %s, Does not exist\n' "$ARGS" "$user" 1>&2; exit 56
  fi
  echo "User,matterId,matterName,holdId,name,orgUnitId,orgUnitPath"
  grep -i "^$user," "$GAM_MOCK_FIXTURES/vault_holds.csv" || true
  exit 0
fi

# ================================ writes (strict) ================================================

# <UserAttribute>* plus the notify clause, as `gam create|add user` / `gam update user` take them. Only
# the attributes GamGUI emits are modelled; anything else is an invalid argument.
check_user_attrs() {
  while [ $# -gt 0 ]; do
    case "$1" in
      suspended|suspend|changepassword|changepasswordatnextlogin|archived|archive)
        need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      password)
        # Grammar 5838-5841: GAM reads these words as keywords, whatever their case, never as the password. `prompt` and
        # `uniqueprompt` read the password from the terminal, which the app's gam has none of: refused here (the wording
        # is the mock's own, not GAM's), so a value that is one of them can't pass as set (review 2026-10-21).
        need_value $# "Password"
        case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
          random|uniquerandom) shift 2; case "${1:-}" in [0-9]*) shift ;; esac ;;
          blocklogin) shift 2 ;;
          prompt|uniqueprompt) invalid_arg "password $2 needs a terminal" ;;
          *) shift 2 ;;
        esac ;;
      firstname|givenname|lastname|familyname)
        # getUserAttributes reads a name with getString(maxLen=60): longer is a usage error, which echoes
        # the whole command line, password and all (gam/__init__.py:46937-46941, getString 1854-1864).
        need_value $# "String"
        [ "$(code_points "$2")" -le 60 ] || invalid_arg "Expected <string length 0<=x<=60 for String>"
        shift 2 ;;
      displayname|recoveryemail|recoveryphone|ou|org|orgunitpath)
        need_value $# "String"; shift 2 ;;
      gal|includeinglobaladdresslist)  # [<Boolean>]: getBoolean's optional form, true when bare (grammar 5831)
        shift; if is_bool "${1:-}"; then shift; fi ;;
      notify|subject|notifypassword|from|mailbox|replyto|message|textmessage|htmlmessage)
        need_value $# "String"; shift 2 ;;
      notifyrecoveryemail|ignorenullpassword) shift ;;
      html) shift; if is_bool "${1:-}"; then shift; fi ;;
      organization)
        shift
        if [ "${1:-}" = "clear" ]; then shift; continue; fi
        while :; do  # (organization [<field> <String>]* notprimary|primary)
          case "${1:-}" in
            type|customtype|name|title|department|symbol|costcenter|location|description|domain|fulltimeequivalent)
              need_value $# "String"; shift 2 ;;
            primary|notprimary) shift; break ;;
            "") missing_arg "notprimary|primary" ;;
            *) invalid_arg "$1" ;;
          esac
        done ;;
      *) invalid_arg "$1" ;;
    esac
  done
}

# `gam create user <email> <UserAttribute>* [notify ...]` -> new account. An address already taken fails
# as doCreateUser's `except GAPI.duplicate` does: duplicateAliasGroupUserWarning names what holds it (a
# user, a user's alias, a group), exit ENTITY_DUPLICATE_RC (gam/__init__.py:2583-2612, 47315-47322, 356).
# Taken: a directory user, one of their aliases, a group, an account created earlier in this state, or
# an *exists* address. An org unit that doesn't exist fails the whole command (entityActionFailedExit,
# 47325-47326: ERROR_PREFIX, exit 50); GAM makes the path absolute first, which changes nothing here.
# Both found in GAM's source, not captured from a tenant (failure-log 2026-10-12).
duplicate_of() {  # <address, lowercased>: what GAM names as holding it, or nothing
  if in_directory "$1" || case "$1" in *exists*) true ;; *) false ;; esac \
     || { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/created/$1" ]; }; then
    printf 'User: %s' "$1"; return
  fi
  while IFS= read -r record; do
    case "$(printf '%s' "$record" | sed -n 's/.*"aliases": \[\([^]]*\)\].*/\1/p')" in
      *"\"$1\""*) printf 'User Alias: %s, User: %s' "$1" "$(json_text primaryEmail "$record")"; return ;;
    esac
  done < "$GAM_MOCK_FIXTURES/print_users.json"
  if is_group "$1"; then printf 'Group: %s' "$1"; fi
}
if { [ "${1:-}" = "create" ] || [ "${1:-}" = "add" ]; } && [ "${2:-}" = "user" ]; then
  [ -n "${3:-}" ] || missing_arg "EmailAddress"
  user=$(printf '%s' "$3" | LC_ALL=C tr 'A-Z' 'a-z'); shift 3
  check_user_attrs "$@"
  org=""
  while [ $# -gt 0 ]; do case "$1" in ou|org|orgunitpath) org="$2"; shift 2 ;; *) shift ;; esac; done
  held=$(duplicate_of "$user")
  if [ -n "$held" ]; then
    printf 'User: %s, Create Failed: Duplicate, %s\n' "$user" "$held" 1>&2
    exit 57
  fi
  case "$(printf '%s' "$org" | LC_ALL=C tr 'A-Z' 'a-z')" in
    *missing*|*nonexistent*) printf '\nERROR: User: %s, Create Failed: Invalid Organizational Unit\n' "$user" 1>&2; exit 50 ;;
  esac
  case "$user" in
    # Seen live 2026-09-30, when the subscription had no free license.
    *userlimit*) echo "ERROR: User: $user, Create Failed: Domain user limit reached. Contact Support." 1>&2; exit 50 ;;
  esac
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/created"
    : > "$GAM_MOCK_STATE/created/$user"
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/new_account_lag" ]; then
    mkdir -p "$GAM_MOCK_STATE/provisioning"
    cp "$GAM_MOCK_STATE/new_account_lag" "$GAM_MOCK_STATE/provisioning/$user"
  fi
  echo "User: $user, Added"
  exit 0
fi

# `gam update user <email> <UserAttribute>*` -> organization / suspended / password random.
if [ "${1:-}" = "update" ] && [ "${2:-}" = "user" ]; then
  [ -n "${3:-}" ] || missing_arg "UserItem"
  user="$3"; shift 3
  check_user_attrs "$@"
  check_exists "User" "$user"
  echo "User: $user, Updated"
  exit 0
fi

# `gam delete user <UserItem> [noactionifalias]` / `gam undelete user <UserItem> [ou|org|orgunit <path>]`
if [ "${1:-}" = "delete" ] && [ "${2:-}" = "user" ]; then
  [ -n "${3:-}" ] || missing_arg "UserItem"
  case "${4:-}" in ""|noactionifalias) ;; *) invalid_arg "$4" ;; esac
  [ $# -le 4 ] || invalid_arg "$5"
  check_exists "User" "$3"
  echo "User: $3, Deleted"
  exit 0
fi
if [ "${1:-}" = "undelete" ] && [ "${2:-}" = "user" ]; then
  [ -n "${3:-}" ] || missing_arg "UserItem"
  if [ $# -gt 3 ]; then
    case "$4" in ou|org|orgunit) [ -n "${5:-}" ] || missing_arg "OrgUnitPath" ;; *) invalid_arg "$4" ;; esac
    [ $# -le 5 ] || invalid_arg "$6"
  fi
  check_exists "User" "$3"
  echo "User: $3, Undeleted"
  exit 0
fi

# `gam user <email> signout` (8938). SIGNOUTFAIL: Google refuses users.signOut the way a missing
# admin.directory.user.security scope does — GAM's entityActionFailedWarning, ACTION_FAILED_RC.
signout_refused() {
  printf 'User: %s, Sign Out Failed: Not Authorized to access this resource/api\n' "$1" 1>&2
  exit 50
}
if [ "${1:-}" = "user" ] && [ "${3:-}" = "signout" ]; then
  [ $# -eq 3 ] || invalid_arg "$4"
  check_exists "User" "$2"
  case "$2" in *SIGNOUTFAIL*) signout_refused "$2" ;; esac
  echo "User: $2, Signed Out"
  exit 0
fi

# `gam user <email> deprovision|deprov [popimap] [signout] [turnoff2sv]` (7899): GAM's parser takes the
# three words in any order. Per user it deletes the app passwords, invalidates the backup codes and
# deletes the OAuth tokens, then (options) turns off 2SV, signs out, disables POP/IMAP. A failure is
# reported against the user and stops that user's remaining parts (deprovisionUser, read statically).
# The stdout wording is GAM's shape from its source conventions, not captured from a tenant, and nothing
# parses it. Before each part GAM says on stderr what it is getting (gam/__init__.py:74192, :74213, :74232; one
# user, so no counter). A suspended user's backup codes aren't touched (checkUserSuspended, :74188,
# :74220-74229): when they have codes, "Not Deprovisioned" with GAM's reason (glmsgs
# IS_SUSPENDED_NO_BACKUPCODES, read from the build) and ACTION_NOT_PERFORMED_RC (51) once the other parts have
# run; without codes nothing is said and it exits 0. Everyone has codes here (`show backupcodes`), except an
# account marked $GAM_MOCK_STATE/nobackupcodes/<user>.
if [ "${1:-}" = "user" ] && { [ "${3:-}" = "deprovision" ] || [ "${3:-}" = "deprov" ]; }; then
  user="$2"; signout=""; shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      popimap|turnoff2sv) ;;
      signout) signout=1 ;;
      *) invalid_arg "$1" ;;
    esac
    shift
  done
  check_exists "User" "$user"
  printf 'Getting Application Specific Password IDs for %s\n' "$user" 1>&2
  echo "User: $user, Application Specific Passwords: 0"
  printf 'Getting Backup Verification Codes for %s\n' "$user" 1>&2
  rc=0
  if grep -F "\"primaryEmail\": \"$(lower "$user")\"" "$GAM_MOCK_FIXTURES/print_users.json" | grep -qF '"suspended": true' \
     && ! { [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nobackupcodes/$(lower "$user")" ]; }; then
    printf 'User: %s, Backup Verification Codes Not Deprovisioned: User is suspended. You must unsuspend to process backupcodes\n' "$user" 1>&2
    rc=51
  else
    echo "User: $user, Backup Verification Codes, Invalidated"
  fi
  printf 'Getting Access Tokens for %s\n' "$user" 1>&2
  echo "User: $user, Access Tokens: 0"
  if [ -n "$signout" ]; then
    case "$user" in *SIGNOUTFAIL*) signout_refused "$user" ;; esac
    echo "User: $user, Signed Out"
  fi
  echo "User: $user, Deprovisioned"
  exit $rc
fi

# `gam user <email> signature <String> [html [<Boolean>]] [replyto <addr>] [default] [treatasalias <B>]
#  [name <String>] [primary]` — the signature text is required (an empty string clears it).
# A body GAM reads as a keyword: getStringOrFile (gam/__init__.py:1896-1899) normalizes the word after
# `signature` as checkArgumentPresent does (:892, strip, lower, `_` removed) and, when it names one of
# SORF_FILE_ARGUMENTS, reads the next argument (`html`) as that file or document instead of taking the
# word as the signature. Each fails before any user is touched, as it fails in the parse (wording
# approximate for the documents): readFile (:3054-3068) can't open `html` (FILE_ERROR_RC); gdoc and ghtml
# take `html` as the owner and then want a file (getGDocData :3134-3135); gcsdoc and gcshtml want a
# storage object name. Here the strip is ASCII whitespace only; the app refuses each such body itself.
gam_choice() {  # <argument>: checkArgumentPresent's normalization
  c=$1
  while :; do case "$c" in [[:space:]]*) c=${c#?} ;; *) break ;; esac; done
  while :; do case "$c" in *[[:space:]]) c=${c%?} ;; *) break ;; esac; done
  printf '%s' "$c" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -d '_'
}
# The body as GAM stores it: _processSignature (gam/__init__.py:78601-78608) removes every CR, turns each
# backslash-n pair into `<br/>`, and without html each line break too.
gam_stored_signature() {  # <body> <html: 1 or 0>
  printf '%s.' "$1" | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/\\n/<br\/>/g' \
    | if [ "$2" = 1 ]; then cat; else awk 'BEGIN { ORS = "" } NR > 1 { print "<br/>" } { print }'; fi
}
# `gam user <email> signature <String> [html [<Boolean>]] [replyto <addr>] [default] [treatasalias <B>]
#  [name <String>] [primary]` — the signature text is required (an empty string clears it). For an address
# that isn't a user, GAM's token request fails as it does for any per-user write (the live provisioning
# refusal's shape, with the token endpoint's words); with Gmail off, the service refusal. With
# GAM_MOCK_STATE the body is kept in the form GAM stored it, and `show signature` prints it.
if [ "${1:-}" = "user" ] && { [ "${3:-}" = "signature" ] || [ "${3:-}" = "sig" ]; }; then
  [ $# -ge 4 ] || missing_arg "String"
  user="$2"; body="$4"
  case "$(gam_choice "$body")" in
    file|htmlfile|textfile)
      [ -n "${5:-}" ] || missing_arg "FileName"
      printf 'ERROR: Unable to read File: %s, [Errno 2] No such file or directory: '"'"'%s'"'"'\n' "$5" "$5" 1>&2
      exit 6 ;;
    gdoc|ghtml) [ -n "${5:-}" ] || missing_arg "EmailAddress"; missing_arg "DriveFileEntity" ;;
    gcsdoc|gcshtml) [ -n "${5:-}" ] || missing_arg "StorageBucketObjectName"; invalid_arg "Expected <StorageBucketObjectName>" ;;
  esac
  shift 4; html=0
  while [ $# -gt 0 ]; do
    case "$1" in
      html) html=1; shift; if is_bool "${1:-}"; then case "$1" in false|off|no|disabled|0) html=0 ;; esac; shift; fi ;;
      default|primary) shift ;;
      replyto|name) need_value $# "String"; shift 2 ;;
      treatasalias) need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  if ! known_user "$user"; then
    printf 'User: %s, User Set Failed: invalid_grant: Invalid email or User ID\n' "$user" 1>&2; exit 50
  fi
  if still_provisioning "$user"; then not_ready_token "$user" "User Set"; fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 1
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/signature"
    stored=$(gam_stored_signature "$body" "$html"); stored=${stored%.}
    printf '%s' "$stored" > "$GAM_MOCK_STATE/signature/$user"
  fi
  echo "User: $user, SendAs Address: <$user>, Updated"
  exit 0
fi

# `gam user <email> add|create|delete delegate|delegates [convertalias] <UserEntity>`
if [ "${1:-}" = "user" ] && { [ "${4:-}" = "delegate" ] || [ "${4:-}" = "delegates" ]; }; then
  case "${3:-}" in
    add|create) verb="Add" ;;
    delete) verb="Delete" ;;
    *) echo "ERROR: mock: unhandled argv: $*" 1>&2; exit 2 ;;
  esac
  n=5
  if [ "${5:-}" = "convertalias" ]; then n=6; fi
  eval "delegate=\${$n:-}"
  [ -n "$delegate" ] || missing_arg "UserEntity"
  if [ $# -gt $n ]; then eval "invalid_arg \"\${$((n + 1))}\""; fi
  case "$delegate" in
    *missing*|*nonexistent*)
      printf 'User: %s, Delegate: %s, %s Failed: Does not exist\n' "$2" "$delegate" "$verb" 1>&2; exit 50 ;;
  esac
  # A delegate the user doesn't have: Gmail's delete is notFound, reported against the pair (processDelegates,
  # entityActionFailedWarning, ACTION_FAILED_RC; the API's words approximate). Until 2026-10-19 any removal passed.
  if [ "$verb" = "Delete" ] && ! has_delegate "$2" "$delegate"; then
    printf 'User: %s, Delegate: %s, Delete Failed: Not Found\n' "$2" "$delegate" 1>&2; exit 50
  fi
  # A delegate the user already has: GAM's processDelegates catches Gmail's alreadyExists and reports it
  # against the pair (entityActionFailedWarning, ACTION_FAILED_RC; read from the vendored build; Google's
  # wording approximate). *exists* is the trigger; a delegate the user has (delegates_of) fails the same way.
  if [ "$verb" = "Add" ]; then
    case "$delegate" in *exists*) already=1 ;; *) already="" ;; esac
    if has_delegate "$2" "$delegate"; then already=1; fi
    if [ -n "$already" ]; then
      printf 'User: %s, Delegate: %s, Add Failed: Delegate already exists.\n' "$2" "$delegate" 1>&2; exit 50
    fi
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then   # keep the list the way Gmail does, for the next print delegates
    ddir="$GAM_MOCK_STATE/delegates"; mkdir -p "$ddir"
    [ -f "$ddir/$2" ] || canned_delegates "$2" > "$ddir/$2"
    if [ "$verb" = "Add" ]; then
      printf '%s\n' "$delegate" >> "$ddir/$2"
    else
      grep -vixF -- "$delegate" "$ddir/$2" > "$ddir/$2.new" || true
      mv "$ddir/$2.new" "$ddir/$2"
    fi
  fi
  echo "User: $2, Delegate: $delegate, ${verb}ed"
  exit 0
fi

# `gam user <email> vacation [<Boolean>] [subject <S>] [message <S>] [html [<B>]] [contactsonly [<B>]]
#  [domainonly [<B>]] [start|startdate <Date>|Started] [end|enddate <Date>|NotSpecified]`
# GAM (setVacation, read from the vendored build) does NOT replace the settings: it reads them
# (getVacation), overwrites only the fields the command names and writes the result back — a flag or
# date left out keeps its old value. With GAM_MOCK_STATE the mock keeps them the same way.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "vacation" ]; then
  user="$2"; shift 3
  v_on=""; v_co=""; v_do=""; v_start=""; v_end=""; v_subject=""; v_message=""; has_subject=""; has_message=""
  if is_bool "${1:-}"; then v_on="$(bool_word "$1")"; shift; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      subject) need_value $# "String"; v_subject="$2"; has_subject=1; shift 2 ;;
      message|textmessage|htmlmessage) need_value $# "String"; v_message="$2"; has_message=1; shift 2 ;;
      html) shift; if is_bool "${1:-}"; then shift; fi ;;
      contactsonly) shift; v_co=True; if is_bool "${1:-}"; then v_co="$(bool_word "$1")"; shift; fi ;;
      domainonly) shift; v_do=True; if is_bool "${1:-}"; then v_do="$(bool_word "$1")"; shift; fi ;;
      start|startdate) need_value $# "Date"; [ "$2" = "Started" ] || need_date "$2"; v_start="$2"; shift 2 ;;
      end|enddate) need_value $# "Date"; [ "$2" = "NotSpecified" ] || need_date "$2"; v_end="$2"; shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  check_exists "User" "$user"
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    vdir="$GAM_MOCK_STATE/vacation/$user"; mkdir -p "$vdir"
    [ -z "$v_on" ] || printf '%s' "$v_on" > "$vdir/enabled"
    [ -z "$v_co" ] || printf '%s' "$v_co" > "$vdir/contactsonly"
    [ -z "$v_do" ] || printf '%s' "$v_do" > "$vdir/domainonly"
    [ -z "$has_subject" ] || printf '%s' "$v_subject" > "$vdir/subject"
    [ -z "$has_message" ] || printf '%s' "$v_message" > "$vdir/message"
    case "$v_start" in "") ;; Started) rm -f "$vdir/start" ;; *) printf '%s' "$v_start" > "$vdir/start" ;; esac
    case "$v_end" in "") ;; NotSpecified) rm -f "$vdir/end" ;; *) printf '%s' "$v_end" > "$vdir/end" ;; esac
  fi
  echo "User: $user, Vacation: Updated"
  exit 0
fi

# `gam user <email> add|create forwardingaddress|forwardingaddresses <EmailAddressEntity>`
if [ "${1:-}" = "user" ] && { [ "${3:-}" = "add" ] || [ "${3:-}" = "create" ]; } \
    && { [ "${4:-}" = "forwardingaddress" ] || [ "${4:-}" = "forwardingaddresses" ]; }; then
  [ -n "${5:-}" ] || missing_arg "EmailAddressEntity"
  [ $# -eq 5 ] || invalid_arg "$6"
  echo "User: $2, Forwarding Address: $5, Added"
  exit 0
fi

# `gam user <email> forward <FalseValues>` / `forward <TrueValues> <action> <EmailAddress>` (8000-8001). GAM's
# setForward (7.48.26): getBoolean first, then per user a token (not_a_user, "Set Failed") and one Gmail settings
# call, Gmail off its userGmailServiceNotEnabledWarning (exit 73); printed as _showForward prints what Gmail returns.
# Stricter than GAM, never looser: GAM strips the Boolean, ignores a word after `off`, and takes `on`'s action and address in any order
# and case (so a bad action is the mock's own invalid choice; GAM reads a lone word as the address).
if [ "${1:-}" = "user" ] && [ "${3:-}" = "forward" ]; then
  user=$2
  [ $# -ge 4 ] || missing_arg "true|false"
  boolean=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]')
  case "$boolean" in
    false|off|no|disabled|0) [ $# -eq 4 ] || invalid_arg "$5"; shown="Forward Enabled: False" ;;
    true|on|yes|enabled|1)
      actions="archive|delete|keep|leaveininbox|markread|trash"  # formatChoiceList sorts more than five
      case "${5:-}" in
        keep|leaveininbox) disposition=leaveInInbox ;;
        archive) disposition=archive ;;
        delete|trash) disposition=trash ;;
        markread) disposition=markRead ;;
        "") missing_arg "$actions" ;;
        *) invalid_choice "$5" "$actions" ;;
      esac
      [ -n "${6:-}" ] || missing_arg "EmailAddress"
      [ $# -eq 6 ] || invalid_arg "$7"
      shown="Forward Enabled: True, Forwarding Address: $6, Action: $disposition" ;;
    *) invalid_choice "$boolean" "true|false" ;;
  esac
  known_user "$user" || not_a_user "$user" Set
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then   # what `print forward` reads next
    mkdir -p "$GAM_MOCK_STATE/forward"
    case "$shown" in *True*) printf 'True,%s,%s' "$6" "$disposition" ;; *) printf 'False,,' ;; esac > "$GAM_MOCK_STATE/forward/$(lower "$user")"
  fi
  echo "User: $user, $shown"
  exit 0
fi

# `gam user <email> imap|imap4 <Boolean> [noautoexpunge] [expungebehavior archive|deleteforever|trash]
#  [maxfoldersize 0|1000|2000|5000|10000]` (8372) / `pop|pop3 <Boolean> [for allmail|newmail|mailfromnowon|fromnowon]
#  [action keep|leaveininbox|archive|delete|trash|markread]` (8378). GAM's setImap and setPop (7.48.26): the options
# first, then per user a token (not_a_user, "Set Failed") and one Gmail settings call, Gmail off its
# userGmailServiceNotEnabledWarning (exit 73); printed as _showImap and _showPop print the settings Gmail returns.
if [ "${1:-}" = "user" ] && case "${3:-}" in imap|imap4|pop|pop3) true ;; *) false ;; esac; then
  user=$2; setting=$3
  [ $# -ge 4 ] || missing_arg "true|false"
  boolean=$(printf '%s' "$4" | tr '[:upper:]' '[:lower:]')
  case "$boolean" in
    true|on|yes|enabled|1) enabled=True ;;
    false|off|no|disabled|0) enabled=False ;;
    *) invalid_choice "$boolean" "true|false" ;;
  esac
  # _popDefaults: `disabled` when off; `for` overwrites it, so `pop off for allmail` turns POP on, as in GAM.
  expunge=True; behavior=archive; size=0; disposition=leaveInInbox
  if [ "$enabled" = True ]; then window=allMail; else window=disabled; fi
  case "$setting" in imap*) kind=imap ;; *) kind=pop ;; esac
  shift 4
  while [ $# -gt 0 ]; do
    # Exact patterns: a glob here would let `x:noautoexpunge` through.
    case "$kind:$1" in
      imap:noautoexpunge) expunge=False; shift ;;
      imap:expungebehavior)
        [ $# -ge 2 ] || missing_arg "archive|deleteforever|trash"
        case "$2" in archive|trash) behavior=$2 ;; deleteforever) behavior=deleteForever ;;
          *) invalid_choice "$2" "archive|deleteforever|trash" ;; esac
        shift 2 ;;
      imap:maxfoldersize)
        [ $# -ge 2 ] || missing_arg "0|1000|2000|5000|10000"
        case "$2" in 0|1000|2000|5000|10000) size=$2 ;; *) invalid_choice "$2" "0|1000|2000|5000|10000" ;; esac
        shift 2 ;;
      pop:for)
        [ $# -ge 2 ] || missing_arg "allmail|fromnowon|mailfromnowon|newmail"
        case "$2" in allmail) window=allMail ;; fromnowon|mailfromnowon|newmail) window=fromNowOn ;;
          *) invalid_choice "$2" "allmail|fromnowon|mailfromnowon|newmail" ;; esac
        shift 2 ;;
      pop:action)
        [ $# -ge 2 ] || missing_arg "archive|delete|keep|leaveininbox|markread|trash"
        case "$2" in archive) disposition=archive ;; delete|trash) disposition=trash ;; keep|leaveininbox) disposition=leaveInInbox ;;
          markread) disposition=markRead ;; *) invalid_choice "$2" "archive|delete|keep|leaveininbox|markread|trash" ;; esac
        shift 2 ;;
      pop:confirm) shift ;;
      *) invalid_arg "$1" ;;
    esac
  done
  known_user "$user" || not_a_user "$user" Set
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -e "$GAM_MOCK_STATE/nogmail/$user" ]; then
    printf 'User: %s, Gmail Service/App not enabled\n' "$user" 1>&2; exit 73
  fi
  case "$kind" in
    imap) echo "User: $user, IMAP Enabled: $enabled, autoExpunge: $expunge, expungeBehavior: $behavior, maxFolderSize: $size" ;;
    *) if [ "$window" != disabled ]; then echo "User: $user, POP Enabled: True, For: $window, Action: $disposition"
       else echo "User: $user, POP Enabled: False"; fi ;;
  esac
  exit 0
fi

# `gam create|add alias|aliases <EmailAddressEntity> user|group|target <UniqueID>|<EmailAddress>
#  [verifynotinvitable]` / `gam delete alias|aliases [user|group|target] <EmailAddressEntity>`
if { [ "${1:-}" = "create" ] || [ "${1:-}" = "add" ]; } && { [ "${2:-}" = "alias" ] || [ "${2:-}" = "aliases" ]; }; then
  [ -n "${3:-}" ] || missing_arg "EmailAddressEntity"
  case "${4:-}" in
    user|group|target) ;;
    "") missing_arg "user|group|target" ;;
    *) invalid_choice "$4" "user|group|target" ;;
  esac
  [ -n "${5:-}" ] || missing_arg "EmailAddress"
  case "${6:-}" in ""|verifynotinvitable) ;; *) invalid_arg "$6" ;; esac
  [ $# -le 6 ] || invalid_arg "$7"
  case "$3" in *exists*) echo "ERROR: 409: Entity already exists - duplicate: $3" 1>&2; exit 1 ;; esac
  check_exists "User" "$5"
  echo "User: $5, Alias: $3, Added"
  exit 0
fi
if [ "${1:-}" = "delete" ] && { [ "${2:-}" = "alias" ] || [ "${2:-}" = "aliases" ]; }; then
  alias="${3:-}"
  case "$alias" in user|group|target) alias="${4:-}"; n=4 ;; *) n=3 ;; esac
  [ -n "$alias" ] || missing_arg "EmailAddressEntity"
  if [ $# -gt $n ]; then eval "invalid_arg \"\${$((n + 1))}\""; fi
  check_exists "Alias" "$alias"
  echo "Alias: $alias, Deleted"
  exit 0
fi

# `gam create|add group <EmailAddress> <GroupAttribute>*` (GamGUI sends name/description only).
if { [ "${1:-}" = "create" ] || [ "${1:-}" = "add" ]; } && [ "${2:-}" = "group" ]; then
  [ -n "${3:-}" ] || missing_arg "EmailAddress"
  group="$3"; shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      name|description) need_value $# "String"; shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  case "$group" in *exists*) echo "ERROR: 409: Entity already exists - duplicate: $group" 1>&2; exit 1 ;; esac
  echo "Group: $group, Added"
  exit 0
fi

# `gam update group <group> add|create [<GroupRole>] <member>` / `delete|remove [<GroupRole>] <member>`
# (grammar 3931, 3937), as doUpdateGroups (gam/__init__.py:35000, read at 7.48.22) runs them. Only the shape
# the app sends: one group and one member, though GAM reads each as a list (`<GroupEntity>`,
# `<UserTypeEntity>`), and none of the option words. Anything else is refused, not answered in a guessed
# shape; so is a group added to itself (Google's cycle refusal isn't modelled).
#   - checkGroupExists runs first: an address that isn't one of the tenant's groups, a person's included, is
#     entityUnknownWarning's "Group: <g>, Does not exist" (GAM lowercases it), ENTITY_DOES_NOT_EXIST_RC.
#   - One member is under GAM's batch_size (50), so it is one API call, and a failure is _showFailure with
#     Google's words: "Group: g, Member: m, Role: R, Add|Remove Failed: <why>", ACTION_FAILED_RC. The role
#     shown is the one asked for (MEMBER when none is). The address compares case-insensitively.
#     Approximate, Google's text not captured from a tenant:
#       add, already a member in any role: "Member already exists." (its 409 duplicate);
#       add, an address in one of the tenant's domains that is no user or group: "Does not exist" (a 404 on
#         memberKey, which GAM maps to memberNotFound and its own words);
#       add, an address Google can't read: "Invalid Input: memberKey" (one outside a plain address's
#         characters stands for it);
#       remove, not a member: "Does not exist".
#   - An address outside the tenant's domains is added: an admin may add an external member whatever the
#     group allows (GAM's `verifyallowexternal` exists to find them). GAM shows it with no status.
#   - Not modelled: an alias (Google adds the account it belongs to), the role's other spellings.
if [ "${1:-}" = "update" ] && { [ "${2:-}" = "group" ] || [ "${2:-}" = "groups" ]; }; then
  [ $# -ge 3 ] || missing_arg "GroupEntity"
  [ -n "$3" ] || empty_arg "GroupEntity"
  case "$3" in *,*) not_modelled "update group with a list of groups" ;; esac
  case "${4:-}" in
    add|create) act=Add; done_word=Added ;;
    delete|remove) act=Remove; done_word=Removed ;;
    *) not_modelled "update group ${4:-}" ;;
  esac
  group=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  shift 4
  role=MEMBER
  case "$(gam_choice "${1:-}")" in
    owner) role=OWNER; shift ;;
    manager) role=MANAGER; shift ;;
    member) role=MEMBER; shift ;;
  esac
  [ $# -ge 1 ] || missing_arg "UserTypeEntity"
  case "$1" in
    usersonly|groupsonly|notsuspended|suspended|notarchived|archived|delivery|preview|actioncsv)
      not_modelled "update group with $1" ;;
  esac
  [ $# -eq 1 ] || invalid_arg "$2"
  [ -n "$1" ] || empty_arg "UserTypeEntity"
  case "$1" in
    *,*) not_modelled "update group with a list of members" ;;
    *@*) ;;
    *) not_modelled "update group with a member that isn't an address" ;;
  esac
  member=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ "$member" != "$group" ] || not_modelled "a group added to itself"
  is_group "$group" || does_not_exist "Group" "$group"
  member_failed() {  # <why>
    printf '  Group: %s, Member: %s, Role: %s, %s Failed: %s\n' "$group" "$member" "$role" "$act" "$1" 1>&2
    exit 50
  }
  echo "Group: $group, $act 1 $(printf '%s' "$role" | cut -c1)$(printf '%s' "$role" | cut -c2- | tr '[:upper:]' '[:lower:]')"
  current=$(member_record "$group" "$member")
  if [ "$act" = Add ]; then
    [ -z "$current" ] || member_failed "Member already exists."
    local_part=${member%%@*}; domain=${member#*@}
    case "$local_part" in ""|*[!a-z0-9._%+\'-]*) member_failed "Invalid Input: memberKey" ;; esac
    case "$domain" in ""|*[!a-z0-9.-]*) member_failed "Invalid Input: memberKey" ;; esac
    if is_group "$member"; then
      type=GROUP; status=ACTIVE
    elif known_user "$member"; then
      type=USER; status=ACTIVE
      if grep -F "\"primaryEmail\": \"$member\"" "$GAM_MOCK_FIXTURES/print_users.json" | grep -qF '"suspended": true'; then
        status=SUSPENDED
      fi
    elif tenant_domain "$domain"; then
      member_failed "Does not exist"
    else
      type=USER; status=""
    fi
    # The member's ID as the data set has it, else one made from the address (the app never reads it).
    id=$(grep -F "\"email\": \"$member\", " "$GAM_MOCK_FIXTURES/group_members.json" | head -n 1 | sed -n 's/.*"id": "\([^"]*\)".*/\1/p')
    [ -n "$id" ] || id="mock-$(printf '%s' "$member" | cksum | cut -d ' ' -f 1)"
    record=$(printf '{"email": "%s", "group": "%s", "id": "%s", "role": "%s", "status": "%s", "type": "%s"}' \
      "$member" "$group" "$id" "$role" "$status" "$type")
  else
    [ -n "$current" ] || member_failed "Does not exist"
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/groups"
    kept="$GAM_MOCK_STATE/groups/.$group.$$"
    if [ "$act" = Add ]; then
      { members_of "$group"; printf '%s\n' "$record"; } > "$kept"
    else
      { members_of "$group" | grep -vF "\"email\": \"$member\", " || true; } > "$kept"
    fi
    mv "$kept" "$GAM_MOCK_STATE/groups/$group"
  fi
  printf '  Group: %s, Member: %s, %s: Role: %s\n' "$group" "$member" "$done_word" "$role"
  exit 0
fi

# A calendar's rules change as Google changes them, in GAM's words (docs/domains/calendars.md, F4-F6; read from
# the vendored 7.48.22 build, Google's own refusals approximate). The scope is GAM's <CalendarACLScopeEntity>,
# read with getEntityList (:7338-7342): split at commas and whitespace into rules, a selector word wanting a
# file. Each rule ID is normalized as normalizeRuleId does (:40654-40664): a bare address or name is
# `user:<address>`, lowercased, a bare name given the domain; `domain` is `domain:<domain>`; `user:`/`group:`
# addresses lowercased; anything else as given. The role is CALENDAR_ACL_ROLES_MAP's (:41596-41605). With
# GAM_MOCK_STATE the rules are kept in $GAM_MOCK_STATE/acls/<calendar>, seeded from the data file, and
# every print reads them there; an add of a scope that has a rule replaces it, as Google's insert does.
# Google refuses the account GAM acts as (calendar_actor) any change to its own access. A failure is said
# against its rule and the next rule still runs (_createCalendarACLs, _updateDeleteCalendarACLs).
mock_admin() {  # the account the materialized oauth2.txt signs in as, or nothing
  sed -n 's/.*"email": *"\([^"]*\)".*/\1/p' "$GAMCFGDIR/oauth2.txt" | head -n 1 | tr '[:upper:]' '[:lower:]'
}
mock_domain() { a=$(mock_admin); [ -n "$a" ] && printf '%s' "${a#*@}" || printf 'example.com'; }
calendar_actor() {  # <calendar key>: who GAM acts as (validateCalendar, :41574-41579)
  case "$1" in *.calendar.google.com) mock_admin ;; *) printf '%s' "$1" ;; esac
}
rule_id() {  # <scope word>: normalizeRuleId
  case "$1" in
    default|default:) printf 'default' ;;
    domain|domain:) printf 'domain:%s' "$(mock_domain)" ;;
    user:?*|group:?*)
      who=$(lower "${1#*:}")
      case "$who" in *@*) ;; *) who="$who@$(mock_domain)" ;; esac
      printf '%s:%s' "${1%%:*}" "$who" ;;
    *:*) printf '%s' "$1" ;;
    *@*) printf 'user:%s' "$(lower "$1")" ;;
    *) printf 'user:%s@%s' "$(lower "$1")" "$(mock_domain)" ;;
  esac
}
api_role() {  # <CalendarACLRole>: as Google stores it
  case "$1" in
    editor) echo writer ;;
    freebusy|freebusyreader) echo freeBusyReader ;;
    writerwithoutprivateaccess) echo writerWithoutPrivateAccess ;;
    *) echo "$1" ;;
  esac
}
rule_json() {  # <rule id> <api role>: the rule as GAM prints it, keys sorted
  case "$1" in
    default) printf '{"id": "default", "role": "%s", "scope": {"type": "default"}}' "$2" ;;
    user:*|group:*|domain:*) printf '{"id": "%s", "role": "%s", "scope": {"type": "%s", "value": "%s"}}' "$1" "$2" "${1%%:*}" "${1#*:}" ;;
    *) not_modelled "a calendar rule like $1" ;;
  esac
}
# The rule edits for one calendar: <op add|delete> <cal as given> <calendar key> <entity label> <role|-> <scope entity>
calendar_acl_change() {
  op=$1; cal=$2; key=$3; label=$4; role=$5; entity=$6
  case "$(lower "$entity")" in file|csvfile|csvkmd|csvdata|datafile|csvdatafile) missing_arg "FileName" ;; esac
  case "$entity" in *'"'*|*\\*) not_modelled "a calendar scope holding a quote or a backslash" ;; esac
  file=$(acl_file "$key")
  if [ -z "$file" ]; then
    printf '%s: %s, %s Failed: Not Found\n' "$label" "$cal" "$([ "$op" = add ] && echo Add || echo Delete)" 1>&2
    exit 50
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/acls"
    [ -f "$GAM_MOCK_STATE/acls/$key" ] || cp "$file" "$GAM_MOCK_STATE/acls/$key"
    file="$GAM_MOCK_STATE/acls/$key"
  fi
  actor=$(calendar_actor "$key")
  failed=""
  set -f
  for word in $(printf '%s' "$entity" | tr ',' ' '); do
    id=$(rule_id "$word")
    case "$id" in default|user:?*|group:?*|domain:?*) ;; *) not_modelled "a calendar rule like $id" ;; esac
    if [ "$op" = add ]; then
      api=$(api_role "$role"); shown="(Scope: $id, Role: $api)"; act="Add"
    else
      shown="(Scope: $id)"; act="Delete"
      [ "$role" = "-" ] || shown="(Scope: $id, Role: $(api_role "$role"))"
    fi
    if [ -n "$actor" ] && [ "$id" = "user:$actor" ]; then
      printf 'Calendar: %s, Calendar ACL: %s, %s Failed: Cannot change your own access level.\n' "$cal" "$shown" "$act" 1>&2
      failed=1; continue
    fi
    has=""; grep -qF "{\"id\": \"$id\", " "$file" && has=1
    if [ "$op" = delete ] && [ -z "$has" ]; then
      printf 'Calendar: %s, Calendar ACL: %s, Delete Failed: Not Found\n' "$cal" "$shown" 1>&2
      failed=1; continue
    fi
    if [ -n "${GAM_MOCK_STATE:-}" ]; then
      if [ "$op" = add ]; then
        line=$(rule_json "$id" "$api")
        if [ -n "$has" ]; then   # replaced where it stands
          awk -v id="{\"id\": \"$id\", " -v line="$line" 'index($0, id) == 1 { print line; next } { print }' "$file" > "$file.new"
        else
          { cat "$file"; printf '%s\n' "$line"; } > "$file.new"
        fi
      else
        grep -vF "{\"id\": \"$id\", " "$file" > "$file.new" || true
      fi
      mv "$file.new" "$file"
    fi
    printf 'Calendar: %s, Calendar ACL: %s, %sed\n' "$cal" "$shown" "$([ "$op" = add ] && echo Add || echo Delet)"
  done
  set +f
  [ -z "$failed" ] || exit 50
  exit 0
}

# `gam user <email> add|create calendaracls primary <CalendarACLRole> <scope> [sendnotifications <B>]` /
# `delete calendaracls primary [<CalendarACLRole>] <scope>`: the person's own primary calendar, GAM acting as
# them (createCalendarACLs, updateDeleteCalendarACLs, :55911-55935). Only `primary` is modelled, the calendar
# the app changes; a person who isn't a user fails as any per-user call does, and Calendar off exits 73.
if [ "${1:-}" = "user" ] && [ "${4:-}" = "calendaracls" ]; then
  user=$(lower "$2"); op="${3:-}"
  [ -n "${5:-}" ] || missing_arg "UserCalendarEntity"
  [ "$5" = "primary" ] || not_modelled "calendaracls of a calendar but primary"
  shift 5
  case "$op" in
    add|create)
      need_acl_role "${1:-}"
      [ -n "${2:-}" ] || missing_arg "CalendarACLScopeEntity"
      role="$1"; scope="$2"; shift 2
      acl_notify_tail "$@"; op=add ;;
    delete)
      role="-"
      if [ $# -eq 2 ]; then need_acl_role "$1"; role="$1"; shift; fi
      [ $# -ge 1 ] && [ -n "$1" ] || missing_arg "CalendarACLScopeEntity"
      [ $# -eq 1 ] || invalid_arg "$2"
      scope="$1" ;;
    *) echo "ERROR: mock: unhandled argv: $ARGS" 1>&2; exit 2 ;;
  esac
  check_exists "User" "$user"
  known_user "$user" || not_a_user "$user" "$([ "$op" = add ] && echo Add || echo Delete)"
  if calendar_off "$user"; then calendar_service_off "$user"; fi
  calendar_acl_change "$op" "$user" "$user" Calendar "$role" "$scope"
fi

# `gam calendars <id> add|create calendaracls <CalendarACLRole> <scope> [sendnotifications <B>]` /
# `gam calendars <id> delete calendaracls [<CalendarACLRole>] <scope>`: GamGUI's admin form (:41721-41775),
# GAM acting as calendar_actor. A calendar GAM can't get fails "Calendar: <id>, <Act> Failed: Not Found",
# exit 50 (validateCalendar, F4), not the old "Does not exist", 56.
if { [ "${1:-}" = "calendars" ] || [ "${1:-}" = "calendar" ]; } && { [ "${4:-}" = "calendaracls" ] || [ "${4:-}" = "acls" ]; }; then
  [ -n "${2:-}" ] || missing_arg "CalendarEntity"
  cal="$2"; key=$(calendar_key "$2"); op="${3:-}"; shift 4
  case "$op" in
    add|create)
      need_acl_role "${1:-}"
      [ -n "${2:-}" ] || missing_arg "CalendarACLScopeEntity"
      role="$1"; scope="$2"; shift 2
      acl_notify_tail "$@"; op=add ;;
    delete)
      role="-"
      if [ $# -eq 2 ]; then need_acl_role "$1"; role="$1"; shift; fi
      [ $# -ge 1 ] && [ -n "$1" ] || missing_arg "CalendarACLScopeEntity"
      [ $# -eq 1 ] || invalid_arg "$2"
      scope="$1" ;;
    *) echo "ERROR: mock: unhandled argv: $ARGS" 1>&2; exit 2 ;;
  esac
  calendar_acl_change "$op" "$cal" "$key" Calendar "$role" "$scope"
fi

# `gam all users delete calendaracls <UserCalendarEntity> [<CalendarACLRole>] <scope>` -> the offboarding
# sweep. Succeeds by default. OWNACL: the sweep also hits the departing user's OWN primary calendar and
# Google refuses to remove their owner ACL — the EXACT real stderr (leading spaces preserved), exit 50,
# which the connector tolerates. SWEEPFAIL: a real failure it must not tolerate. SWEEPBENIGN: a multi-user
# stderr (GAM's "Getting all/Got N" chatter, as in GamUpdate.txt, then one line per entity) where every
# line is tolerable; SWEEPMIXED: the same with one real per-user failure among them, exit 50 either way.
# SWEEPSLOW: a sweep still walking the domain when the runner's timeout fires (exec keeps the PID it kills).
if [ "${1:-}" = "all" ] && [ "${2:-}" = "users" ] && [ "${3:-}" = "delete" ] && [ "${4:-}" = "calendaracls" ]; then
  [ -n "${5:-}" ] || missing_arg "UserCalendarEntity"
  shift 5
  if [ $# -eq 2 ]; then need_acl_role "$1"; shift; fi
  [ $# -ge 1 ] && [ -n "$1" ] || missing_arg "CalendarACLScopeEntity"
  [ $# -eq 1 ] || invalid_arg "$2"
  scope="$1"
  case "$scope" in
    *SWEEPSLOW*) exec sleep 30 ;;
    *SWEEPCLEAN*)
      # A leaver suspended before offboarding is not among `all users`: no own calendar visited, exit 0.
      printf 'User: alice@example.com, Calendar: alice@example.com, Calendar ACL: (Scope: user:%s), Deleted\n' "$scope"
      exit 0 ;;
    *OWNACL*)
      printf '    Calendar: %s, Calendar ACL: (Scope: user:%s), Delete Failed: Cannot change your own access level.\n' "$scope" "$scope" 1>&2
      exit 50 ;;
    *SWEEPFAIL*)
      echo "ERROR: 403: Request had insufficient authentication scopes" 1>&2; exit 1 ;;
    *SWEEPBENIGN*|*SWEEPMIXED*)
      printf 'Getting all Users, may take some time on a large Google Workspace Account...\nGot 4 Users: alice@example.com - %s\n' "$scope" 1>&2
      echo "User: bob@example.com, Service not applicable/Does not exist" 1>&2
      # A user without Calendar: GAM's userCalServiceNotEnabledWarning (calendars.get primary →
      # notACalendarUser), SERVICE_NOT_APPLICABLE_RC — `all users` includes every active user.
      echo "User: dave@example.com, Calendar Service/App not enabled (3/4)" 1>&2
      case "$scope" in *SWEEPMIXED*)
        printf '    Calendar: carol@example.com, Calendar ACL: (Scope: user:%s), Delete Failed: Internal error encountered.\n' "$scope" 1>&2 ;;
      esac
      printf '    Calendar: %s, Calendar ACL: (Scope: user:%s), Delete Failed: Cannot change your own access level.\n' "$scope" "$scope" 1>&2
      exit 50 ;;
  esac
  # The default, as GAM walks `all users` (every active user; updateDeleteCalendarACLs, :55925-55935, and
  # _processCalendarACLs, :41681-41708 at 7.48.22): the progress lines; per user a header (with the count),
  # then their primary calendar's one rule, deleted where the user had shared with the leaver (the mock's
  # calendar_acls), "Delete Failed: Not Found" where they hadn't (Google's wording approximate), and, seen live
  # (2026-10-07, GAM 7.48.14), the leaver's own calendar, whose owner rule GAM can't remove: exit 50, every
  # line one GamGUI's sweep tolerates. A leaver who isn't active isn't visited, and the sweep exits 0.
  scope_key=$(lower "$scope")
  active=$(grep -vF '"suspended": true' "$GAM_MOCK_FIXTURES/print_users.json" | sed -n 's/.*"primaryEmail": "\([^"]*\)".*/\1/p')
  count=$(printf '%s\n' "$active" | grep -c .)
  printf 'Getting all Users, may take some time on a large Google Workspace Account...\nGot %s Users: %s - %s\n' \
    "$count" "$(printf '%s\n' "$active" | head -1)" "$(printf '%s\n' "$active" | tail -1)" 1>&2
  failed=0; n=0
  for user in $active; do
    n=$((n + 1))
    echo "User: $user, Delete Calendar ACLs from 1 Calendar ($n/$count)"
    echo "  Calendar: $user, Delete 1 Calendar ACL"
    if [ "$user" = "$scope_key" ]; then
      printf '    Calendar: %s, Calendar ACL: (Scope: user:%s), Delete Failed: Cannot change your own access level.\n' "$user" "$scope" 1>&2
      failed=1
    elif grep -qF "\"id\": \"user:$scope_key\"" "$(acl_file "$(lower "$user")")" 2>/dev/null; then
      echo "    Calendar: $user, Calendar ACL: (Scope: user:$scope), Deleted"
    else
      printf '    Calendar: %s, Calendar ACL: (Scope: user:%s), Delete Failed: Not Found\n' "$user" "$scope" 1>&2
      failed=1
    fi
  done
  [ "$failed" = 0 ] || exit 50
  exit 0
fi

# `gam user <owner> remove calendars <UserCalendarEntity>` -> PERMANENTLY delete a secondary calendar.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "remove" ] && [ "${4:-}" = "calendars" ]; then
  [ -n "${5:-}" ] || missing_arg "UserCalendarEntity"
  [ $# -eq 5 ] || invalid_arg "$6"
  check_exists "Calendar" "$5"
  echo "User: $2, Calendar: $5, Removed"
  exit 0
fi

# `gam user <email> add calendars <id> [selected <B>] …` (addCalendars, _processCalendarList, :55465-55499): put
# the calendar in the person's list, GAM acting as them. One who isn't a user fails as any per-user call does;
# Calendar off, or an account Google is still setting up, exits 73 from validateCalendar, before GAM steps in
# a level, so unindented. Each calendar's line is printed one level in (Ind.Increment, two spaces per level,
# gamlib/glindent.py): `  User: <u>, Calendar: <c>, Added` on success; a calendar GAM can't get, or one already
# in their list (Google's `duplicate`, plan Q7), `  User: <u>, Calendar: <c>, Add Failed: <why>`, exit 50
# (Google's words approximate). With GAM_MOCK_STATE the calendars added are kept in
# $GAM_MOCK_STATE/subscribed/<user> (`print calendars` doesn't list them yet).
# SUBFAIL: GamGUI's trigger for a subscribe GAM refuses (the partial-share path).
if [ "${1:-}" = "user" ] && [ "${3:-}" = "add" ] && [ "${4:-}" = "calendars" ]; then
  [ -n "${5:-}" ] || missing_arg "UserCalendarAddEntity"
  case "$*" in
    *SUBFAIL*) echo "ERROR: 403: Not authorized to act as user" 1>&2; exit 1 ;;
  esac
  user=$(lower "$2"); cal="$5"; key=$(calendar_key "$5"); shift 5
  while [ $# -gt 0 ]; do
    case "$1" in
      selected|hidden) need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      color|colorindex|colorid|backgroundcolor|foregroundcolor|summary) need_value $# "String"; shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  known_user "$user" || not_a_user "$user" Add
  if still_provisioning "$user" || calendar_off "$user"; then calendar_service_off "$user"; fi
  if [ -z "$(acl_file "$key")" ]; then
    printf '  User: %s, Calendar: %s, Add Failed: Not Found\n' "$user" "$cal" 1>&2; exit 50
  fi
  listed=""
  if [ -f "$GAM_MOCK_FIXTURES/user_calendars/$user.json" ] && grep -qF "\"id\": \"$key\"" "$GAM_MOCK_FIXTURES/user_calendars/$user.json"; then listed=1; fi
  if [ -n "${GAM_MOCK_STATE:-}" ] && [ -f "$GAM_MOCK_STATE/subscribed/$user" ] && grep -qxF "$key" "$GAM_MOCK_STATE/subscribed/$user"; then listed=1; fi
  if [ -n "$listed" ]; then
    printf '  User: %s, Calendar: %s, Add Failed: Duplicate\n' "$user" "$cal" 1>&2; exit 50
  fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/subscribed"
    printf '%s\n' "$key" >> "$GAM_MOCK_STATE/subscribed/$user"
  fi
  printf '  User: %s, Calendar: %s, Added\n' "$user" "$cal"
  exit 0
fi

# `gam user <email> add|create event <UserCalendarEntity> [id <S>] <EventAttribute>+ [<notification>]`
if [ "${1:-}" = "user" ] && { [ "${3:-}" = "add" ] || [ "${3:-}" = "create" ]; } && [ "${4:-}" = "event" ]; then
  [ -n "${5:-}" ] || missing_arg "UserCalendarEntity"
  user="$2"; cal="$5"; shift 5
  attrs=0
  while [ $# -gt 0 ]; do
    case "$1" in
      id) need_value $# "String"; shift 2 ;;
      summary|description|location|attendee|optionalattendee|timezone|color|recurrence|resource)
        need_value $# "String"; shift 2; attrs=$((attrs + 1)) ;;
      start|starttime|end|endtime)
        need_value $# "Time"
        if [ "$2" = "allday" ]; then need_date "${3:-}"; shift 3; else shift 2; fi
        attrs=$((attrs + 1)) ;;
      allday|birthday) need_value $# "Date"; need_date "$2"; shift 2; attrs=$((attrs + 1)) ;;
      available|tentative|googlemeet|hangoutsmeet|noreminders) shift; attrs=$((attrs + 1)) ;;
      notifyattendees) shift ;;
      sendnotifications) need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      sendupdates)
        case "${2:-}" in all|externalonly|none) ;; *) invalid_choice "${2:-}" "all|externalonly|none" ;; esac
        shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  [ "$attrs" -gt 0 ] || missing_arg "EventAttribute"
  check_exists "User" "$user"
  echo "User: $user, Calendar: $cal, Event: MockEvent_1, Added"
  exit 0
fi

# `gam calendars <id> delete events [<EventEntity>] [doit] [<EventNotificationAttribute>]`. Without `doit`
# GAM only reports what it would delete and does NOT delete — an app that forgot `doit` would show
# "Event deleted." for an event that still exists — so a doit-less delete fails here.
if { [ "${1:-}" = "calendars" ] || [ "${1:-}" = "calendar" ]; } && [ "${3:-}" = "delete" ] && [ "${4:-}" = "events" ]; then
  [ -n "${2:-}" ] || missing_arg "CalendarEntity"
  cal="$2"; shift 4
  eid=""; doit=""
  while [ $# -gt 0 ]; do
    case "$1" in
      id|eventid|event|events) need_value $# "EventId"; eid="$2"; shift 2 ;;
      doit) doit=1; shift ;;
      notifyattendees) shift ;;
      sendnotifications) need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      sendupdates)
        case "${2:-}" in all|externalonly|none) ;; *) invalid_choice "${2:-}" "all|externalonly|none" ;; esac
        shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  if [ -z "$eid" ]; then
    echo "ERROR: mock: delete events with no event id would select every event - never emitted" 1>&2; exit 2
  fi
  if [ -z "$doit" ]; then
    printf 'Calendar: %s, Event: %s, Delete not performed: Use doit argument to perform action\n' "$cal" "$eid" 1>&2
    exit 51
  fi
  check_exists "Event" "$eid"
  echo "Calendar: $cal, Event: $eid, Deleted"
  exit 0
fi

# `gam user <assignee> create tasklist <TasklistAttribute>* [returnidonly] [formatjson]` -> with
# returnidonly, GAM prints just the new tasklist id. Each list has its own id, and belongs to its user:
# with GAM_MOCK_STATE the mock mints one per call (`tasklists/<id>` holds the user); without it, one per
# user. An address that isn't a user fails on its token, as every per-user call does.
tasklist_owner_id() {  # <user>: the stateless mock's one list id for that user
  printf 'MockTasklist_u%s' "$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
}
if [ "${1:-}" = "user" ] && [ "${3:-}" = "create" ] && [ "${4:-}" = "tasklist" ]; then
  user="$2"; shift 4
  idonly=""
  while [ $# -gt 0 ]; do
    case "$1" in
      title) need_value $# "String"; shift 2 ;;
      returnidonly) idonly=1; shift ;;
      formatjson) shift ;;
      *) invalid_arg "$1" ;;
    esac
  done
  known_user "$user" || not_a_user "$user" "Create"
  # The token failure is per account, not per API, so the signature's live wording is ASSUMED here until a
  # live run (onboarding runbook, stage C) shows the task list's.
  if still_provisioning "$user"; then not_ready_token "$user" "Tasklist Create"; fi
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    mkdir -p "$GAM_MOCK_STATE/tasklists"
    id="MockTasklist_$(( $(ls "$GAM_MOCK_STATE/tasklists" | wc -l) + 1 ))"
    printf '%s' "$user" > "$GAM_MOCK_STATE/tasklists/$id"
  else
    id=$(tasklist_owner_id "$user")
  fi
  if [ -n "$idonly" ]; then echo "$id"; else echo "User: $user, Tasklist: $id, Added"; fi
  exit 0
fi

# `gam user <a> create task <TasklistEntity> <TaskAttribute>* [parent <id>] [previous <id>]` -> a task on
# the list. Only a list `create tasklist` made for this same user takes it: GAM reports any other as the
# insert's failure against the user, list and task (processTasks, gam/__init__.py:80637-80638, exit 50;
# Google's "Not Found" assumed, not captured). Before, ANY id passed, and then one fixed id passed for
# everyone, so "Created N of N" proved nothing (the mock lied). The token and the new-account lag are per
# account, as for every per-user call.
if [ "${1:-}" = "user" ] && [ "${3:-}" = "create" ] && [ "${4:-}" = "task" ]; then
  [ -n "${5:-}" ] || missing_arg "TasklistEntity"
  user="$2"; list="$5"; shift 5
  title=""
  while [ $# -gt 0 ]; do
    case "$1" in
      title) need_value $# "String"; title="$2"; shift 2 ;;
      notes|due|parent|previous) need_value $# "String"; shift 2 ;;
      status)
        case "${2:-}" in needsaction|completed) ;; *) invalid_choice "${2:-}" "needsaction|completed" ;; esac
        shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  known_user "$user" || not_a_user "$user" "Create"
  if still_provisioning "$user"; then not_ready_token "$user" "Task Create"; fi
  owner=""
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    case "$list" in */*|.*) ;; *) [ -f "$GAM_MOCK_STATE/tasklists/$list" ] && owner=$(cat "$GAM_MOCK_STATE/tasklists/$list") ;; esac
  elif [ "$list" = "$(tasklist_owner_id "$user")" ]; then
    owner="$user"
  fi
  if [ "$owner" != "$user" ]; then
    printf '  User: %s, Tasklist: %s, Task: %s, Create Failed: Not Found\n' "$user" "$list" "$title" 1>&2
    exit 50
  fi
  echo "User: $user, Tasklist: $list, Task: MockTask_1, Created"
  exit 0
fi

# `gam sendemail [recipient|to] <RecipientEntity> [subject <S>] [message <S>] [html [<B>]] ...` -> send.
# Real GAM 400s on a bad recipient, so a *SENDFAIL* address fails like an invalid `to` header.
if [ "${1:-}" = "sendemail" ]; then
  shift
  case "${1:-}" in recipient|to) shift ;; esac
  [ -n "${1:-}" ] || missing_arg "RecipientEntity"
  to="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      from|mailbox|replyto|cc|bcc|subject|message|textmessage|htmlmessage) need_value $# "String"; shift 2 ;;
      html) shift; if is_bool "${1:-}"; then shift; fi ;;
      singlemessage) shift ;;
      *) invalid_arg "$1" ;;
    esac
  done
  case "$to" in
    *SENDFAIL*) echo "ERROR: 400: Bad Request - invalidArgument: Invalid to header" 1>&2; exit 1 ;;
  esac
  echo "Email sent to $to"
  exit 0
fi

# `gam create|add datatransfer|transfer <old> <DataTransferServiceList> <new> [private|shared|all]
#  [releaseresources <Boolean>]` (doCreateDataTransfer, gam/__init__.py:17866-17912 at 7.48.22). GAM resolves
# each owner to a user ID as it reads it (convertEmailAddressToUID, :5997-6013): an address that isn't a user
# ends the command there, before any transfer (entityDoesNotExistExit: the command line, then "User: x, Does
# not exist", ENTITY_DOES_NOT_EXIST_RC; the marking of the bad argument is approximate). The same account
# twice, an alias of the old owner included, is a usage error (:17886-17888). On success GAM prints
# "Transfer Request Performed", then the transfer's ID, services, From and To (:17907-17912; the services are
# the Data Transfer API's app names). With GAM_MOCK_STATE a transfer stays in progress for the old owner
# ($GAM_MOCK_STATE/transfers/<old>), and a second one for them is Google's 409, which GAM's callGAPI doesn't
# expect: systemErrorExit(HTTP_ERROR_RC, 9). An <old> containing CONFLICT409 does the same without state.
transfer_owner() {  # <address>: the primary it resolves to, or the command ends as GAM's lookup does
  owner=$(lower "$1")
  # CONFLICT409 is a trigger, not an account: a pseudo-user, as *pending* is for print datatransfers.
  case "$owner" in *conflict409*) printf '%s' "$owner"; return ;; esac
  if known_user "$owner"; then printf '%s' "$owner"; return; fi
  held=$(duplicate_of "$owner")
  case "$held" in
    "User Alias: "*) printf '%s' "${held##*, User: }"; return ;;
  esac
  printf 'Command: gam %s\n\nERROR: User: %s, Does not exist\n' "$ARGS" "$owner" 1>&2
  exit 56
}
if { [ "${1:-}" = "create" ] || [ "${1:-}" = "add" ]; } && { [ "${2:-}" = "datatransfer" ] || [ "${2:-}" = "transfer" ]; }; then
  [ -n "${3:-}" ] || missing_arg "OldOwnerID"
  old_owner=$(transfer_owner "$3")
  [ -n "${4:-}" ] || missing_arg "DataTransferServiceList"
  services="calendar|datastudio|lookerstudio|data studio|googledrive|gdrive|drive|drive and docs"
  apps=""
  old_ifs=$IFS; IFS=,
  for svc in $4; do
    case "$svc" in
      calendar) app="Calendar" ;;
      datastudio|lookerstudio|"data studio") app="Looker Studio" ;;
      googledrive|gdrive|drive|"drive and docs") app="Drive and Docs" ;;
      *) IFS=$old_ifs; invalid_choice "$svc" "$services" ;;
    esac
    apps="${apps:+$apps,}$app"
  done
  IFS=$old_ifs
  [ -n "${5:-}" ] || missing_arg "NewOwnerID"
  new_owner=$(transfer_owner "$5")
  [ "$old_owner" != "$new_owner" ] || usage_error "New owner must differ from old owner"
  old="$3"; svcs="$4"; new="$5"; shift 5
  while [ $# -gt 0 ]; do
    case "$1" in
      # PRIVACY_LEVEL is a Drive parameter: GAM's _assignAppParameter refuses it (usage error) when no
      # listed app takes it.
      private|shared|all)
        case ",$svcs," in
          *,drive,*|*,googledrive,*|*,gdrive,*|*",drive and docs,"*) ;;
          *) usage_error "No data transfer application for key PRIVACY_LEVEL" ;;
        esac
        shift ;;
      releaseresources|release_resources) need_value $# "Boolean"; need_bool "$2"; shift 2 ;;
      *) invalid_arg "$1" ;;
    esac
  done
  conflict() { echo "ERROR: 409: conflict - Data transfer already in progress for the user." 1>&2; exit 9; }
  case "$old" in *CONFLICT409*) conflict ;; esac
  if [ -n "${GAM_MOCK_STATE:-}" ]; then
    [ ! -e "$GAM_MOCK_STATE/transfers/$old_owner" ] || conflict
    mkdir -p "$GAM_MOCK_STATE/transfers"
    printf '%s\n' "$new_owner" > "$GAM_MOCK_STATE/transfers/$old_owner"
  fi
  echo "Transfer Request Performed"
  echo "  Transfer ID: MockTransfer_$(printf '%s' "$old_owner" | cksum | cut -d' ' -f1)"
  echo "  Service: $apps"
  echo "  From: $old"
  echo "  To: $new"
  exit 0
fi

# Anything else is unhandled. Fail loudly: a catch-all that succeeded is how the mock used to lie — a
# `delete events` without doit, an invalid calendar role and 23 writes with no handler all "passed".
echo "ERROR: mock: unhandled argv: $*" 1>&2
exit 2
