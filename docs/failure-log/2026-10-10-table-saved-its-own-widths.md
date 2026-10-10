# 2026-10-10 — The Users table saved its own column widths as the operator's layout

- **Symptom:** none reported yet. Found while timing the person page: in a copy of the Users layout,
  `TableColumnCustomization` changed 17 times over three openings and closings of a page with no one
  touching a column (37 with the inspector's slide). PR #29 saved the whole customization a second after
  any change, so every opening saved the squeezed widths beside the page as the operator's layout, and
  an untouched second window wrote its copy again.
- **Cause:** PR #29 assumed a change to the customization meant the operator dragged, hid or moved a
  column. SwiftUI's Table also writes the widths NSTableView autoresizes to whenever the list narrows or
  widens. Its visibility never changed by itself (0 of 37).
- **Why not caught:** the review flagged it as unverified; nothing ran the table with a page opening,
  and CI's snapshots read no preferences (debug snapshots save nothing).
- **Fix:** PR #30 saves only which columns are hidden, the moment the operator hides or shows one, and
  drops PR #29's saved layout; widths and order last the session.
- **Prevention:** the runbook says what the table writes by itself and what is saved. Nothing automatic:
  a tripwire would need the app running with a real table; the frame-timing harness (directory-home
  runbook, "Opening a page") is how it was measured.
