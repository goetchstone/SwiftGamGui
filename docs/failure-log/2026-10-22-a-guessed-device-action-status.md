# 2026-10-22 — A guessed device-action status kept a blocked computer on the to-do list

- **Symptom** — Building "Do It Here" for the attacker's computers, the operator blocked or deleted three of them in the
  Admin console. Read the logs would have kept all three on Still to do: the reader counted an admin's action on a device
  as done only when its `ACTION_EXECUTION_STATUS` contained "SUCCESS", and only from the Devices log.
- **Cause** — The status was guessed in the #100 security-review fix, not read from Google. The Reports API's Devices
  events give `EXECUTED` (or `PENDING`, `SENT_TO_DEVICE`, `CANCELLED`, `FAILED`, …), and an admin's block, delete or wipe
  from the Admin console is also its own Admin-log event (`MOBILE_DEVICE_BLOCK`, `_DELETE`, `_WIPE`, `MOBILE_ACCOUNT_WIPE`,
  mobile settings) that the reader never looked at. Any action counted, too, a lock or a sign-out as much as a block.
- **Why not caught** — The test built the event with the same guess (`ACTION_SUCCESS`), so it held the reader to itself.
  No real export had an admin's device action in it yet.
- **Fix** — `LogReading.deviceWord`: a device is gone once that account's latest word on it is an unregistration, a
  Devices-log block, wipe, unenroll or access refused that's `EXECUTED`, "blocked by the admin", or the Admin log's block,
  delete or wipe of that device for that account; approved (`MOBILE_DEVICE_APPROVE`, or the Devices log's `APPROVE` or
  `ALLOW_ACCESS` executed) or registered again is back, from any address. The Admin log's device steps say themselves in
  the timeline.
- **Prevention** — `LogReadingTests.eachLooseEndStaysUntilItsOwnFix` and `whatsDoneLeavesTheList` use Google's documented
  values: pending, sent and a lock stay; executed blocks and wipes, and each Admin-log step, leave. The live check is the
  operator's own block: read the logs again and see the three computers leave Still to do. Lesson, again: a value the
  reader matches comes from Google's reference or a real row, never from memory (see
  [2026-10-22-googles-account-warnings-have-no-actor](2026-10-22-googles-account-warnings-have-no-actor.md)).
