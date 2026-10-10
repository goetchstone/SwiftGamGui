# 2026-10-10 — Clicking a name crashed GamGUI in a narrow window

- **Symptom:** after the person page shipped (PR #27), clicking a name on Users in the operator's 900x572
  window crashed the app: `NSGenericException: The window has been marked as needing another Update
  Constraints in Window pass, but it has already had more Update Constraints in Window passes than there
  are views in the window`, from `+[NSApplication _crashOnException:]`.
- **Cause:** a SwiftUI inspector on macOS 27 floats over the list, so when it opens, the list's minimum
  width grows by the inspector's width (measured: 186 pt becomes 646 with a 460 pt inspector), but the
  window's minimum size is not raised. In a window narrower than sidebar + list minimum + inspector,
  AppKit's layout loops until it gives up. PR #27 widened the inspector (min 380, ideal 460, max 720)
  in a window whose minimum stayed 760, and left the sidebar's and the inspector's widths unbounded by
  anything the window had room for. A wider sidebar or a dragged-out inspector reaches the same
  condition at any window size.
- **Why not caught:** CI renders every tab, but at the window's default size, and CI's AppKit clips an
  overfull column instead of looping, so the crash never happens there. Nothing measured whether a
  column's content fits it. The screenshot script ignored the app's exit status.
- **Fix:** PR #28. `ColumnWidths` bounds the sidebar (150–190 pt) and the inspector (320–400) and
  raises the window's minimum to 920, so with both at their widest the page needs about 800. The
  page's content may shrink (it clips) instead of widening the inspector. The tabs are shorter
  (Profile, Groups, Mail, Security). Reproduced first: a standalone copy of the layout (invisible
  window, no Dock icon) crashed at the operator's address (`0x1958f0dd8`) at 815 pt and not at 820,
  with a 250 pt sidebar at 900, and with the inspector dragged to 600. Its measured minimum explains
  every crash it made: 2 × sidebar + 16 + inspector. It does not explain the operator's crash at 900,
  which had 84 pt to spare by that sum, so the margin is 100 pt and the cause is open. Apple
  acknowledges the bug on its developer forums (thread 836901).
- **Prevention:** every snapshot lists each split view column's width and the width its content
  needs, and fails when one is short (`Spikes.columnsTooNarrow`). `scripts/screenshots.sh` opens the
  person page, on every tab, in the smallest window with the sidebar and the inspector dragged to their
  widest, fails unless the page has 100 pt to spare, and fails on a non-zero exit. The test failed on
  the old widths before the fix landed. The `pre-commit` skill asks for bounds and a `smallest` run
  for any new or wider column. Investigating it, an agent launched a visible test app in a loop on the
  operator's screen. Layout experiments now run on CI, or invisibly (transparent, off-screen, no Dock
  icon).
