# 2026-10-23 — Every Gmail event read as a send: the attacker's reading became "pull from every mailbox"

- **Symptom** — During a real incident the operator saw a great many "Pull … from every mailbox" items in Read the logs,
  each saying the email "went through Gmail from" the attacker's address and "went out from the attacker's address".
  Acting on them would have moved real mail (anything the attacker read in the person's mailbox) out of every mailbox that
  had it. The operator asked before trashing them; nothing was pulled.
- **Cause** — `LogReading.read`'s mail rule took every Gmail-log event from a suspect address with a Message-ID as mail
  the attacker sent. Every Gmail event is named `delivery`; what happened is `event_info.mail_event_type` (Google's
  appendix "Gmail Activity Events": 1 sent, 31 viewed, 7 first open, 29 draft, 13 to Trash, 35 send begun…), which the
  reader never read. Each row's words ("Delivery") and details (its first four parameters) didn't say it either.
- **Why not caught** — The mock lied. `report_gmail.csv` had two `delivery` rows, both sends in spirit, with
  `message_info` only and no `event_info`: the reader's rule and its tests were written against that shape, never
  Google's reference or a real row. The shape was guessed, as the device action status was
  ([2026-10-22-a-guessed-device-action-status](2026-10-22-a-guessed-device-action-status.md)).
- **Fix** — `LogReading.isSent`: a pull only for 1 and 35, a message sent and begun drafted once. Each Gmail row says its
  type in Google's words (`ActivityLogs.gmailWords`), its type left out of its details. The finding says "was sent from".
- **Prevention** — The mock now carries `event_info.mail_event_type` as GAM prints a nested parameter (GAM 7.48.30
  :14854-14899) and a view by the attacker's address beside the sends, as real logs have.
  `LogReadingTests.onlyMailTheAttackerSentIsPulled` (fails without the fix: views, opens, drafts, trash and an untyped
  event were pulled) and `ActivityLogsTests.gmailsNestedParametersAreNamedByTheirChain` (every type in words) hold it.
  Proven against a greener mock only: the live check is the operator's next pull, where the Gmail rows should say Sent,
  Viewed and the rest and only the attacker's sends should be offered to pull. Lesson, the third time in two days: a
  field the reader matches comes from Google's reference or a real row, never from the mock it was written beside.
