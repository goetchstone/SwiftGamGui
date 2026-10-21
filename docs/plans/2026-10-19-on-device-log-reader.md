# Plan: an on-device reader for security logs

**Status (2026-10-21): R1 and R2 built** (Read the logs, under Pull Incident Logs; runbook:
docs/domains/compromised-account.md, "Log reader"). Asked for: the incident logs read by a model on this Mac, with
recommendations, and the fixes the logs point to set up to run.

## Why
When an account is taken over and used to mass-send phishing, the logs answer the questions that matter: which address
the attacker used, which accounts it reached, who typed a password into the fake page, which email to pull. Getting
those answers by hand means grouping thousands of rows, and a false lead is easy (an office address signs everyone in; a
reply listed under its sender can make a mailbox look compromised). Code does the grouping; the on-device model explains
it in plain words; the fixes it points to are drafts the operator confirms.

## The rule
- **Code finds, code drafts, the model explains.** Every finding comes from a tested rule. Each fix is a draft code
  makes from a finding: **Secure Account for a person**, or **pull one email by its Message-ID**. A draft only opens its
  screen with the value filled in (Compromised Account checks the person; Phishing finds who has the email); that
  screen's own preview, typed confirmation and ChangeCore run do the rest (invariants 2 and 10). The model never writes a
  draft, a command or an address: it words the findings, each point citing them, and a point citing none is dropped.
- **The model never reads what an attacker wrote.** Its prompt is each finding's kind, accounts, addresses and counts;
  never a subject, a URL or a Message-ID.
- **Apart from anything that can run gam.** `Assist` depends on no GamKit module; its one screen hands a fix on as an
  address or a Message-ID (`WriteRouteTests.theLogReaderCanRunNothing`).
- **On-device only** (`SystemLanguageModel`). Tenant data never leaves the Mac; no cloud fallback.
- **Works with no model.** Unavailable, Apple Intelligence off, or the model not ready: the findings and drafts show
  alone, and the screen says why in words.

## The rules (each with a case that fires and one that must not)
- **Suspect addresses:** an IP of a sign-in Google called suspicious (a `suspicious_…` event, one marked suspicious, an
  attack warning, an account disabled as hijacked), and the address the operator pulled by. Not every flag: a person's
  own failed challenge or a denied cookie is flagged too, from the office as often as anywhere (review 2026-10-21). Never
  an address only because many accounts used it; one more than 10 accounts signed in from is said as likely shared (an
  office, a VPN) and drafts nothing, unless the operator pulled by it.
- **In from a suspect address** (a sign-in to Google or to another app through it, an app grant, an account change)
  → Secure Account. **A Takeout export from it** → Secure Account, and the data counted as the attacker's. **Chat
  messages from it** → said: ask who got them not to open their links.
- **A failed sign-in from a suspect address:** someone had that password, likely from the fake page → Secure Account.
- **Chrome:** a password typed on a phishing site → Secure Account; on another site, a breached password, or past
  Chrome's phishing warning → said.
- **Mail through Gmail from a suspect address** → pull that email from everyone. Its sender is secured by their sign-in
  from that address: whose mailbox a Gmail row is isn't certain from the row alone.
- **After the lock:** a suspect address's events after a time the operator gives → said.

## Not built unless asked
A sender's volume (until the Gmail log's sent and received events are told apart live), Admin console CSV import, IP
lookups over the network, the model choosing or filling anything, alerts or background scanning, cloud models, Siri.
