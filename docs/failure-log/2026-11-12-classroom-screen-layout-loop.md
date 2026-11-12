# 2026-11-12 — The Classroom screen crashed the app on opening, and named no owner

- **Symptom:** CI's screenshots on PR #158: every Classroom picture failed, the app ending with a breakpoint trap (status
  133) about two seconds after launch. Under lldb it was AppKit's `NSGenericException`, "more Update Constraints in Window
  passes than there are views in the window", the same exception and address as the person page's crash
  (2026-10-10). Once the screen drew, its list showed no owner for any class, though the directory had them.
- **Cause:** the crash was the read-only note under the search field, `.fixedSize(horizontal: false, vertical: true)`,
  above the list in the split view's column: removing that modifier alone stops the crash; restoring it brings it back.
  No inspector was open, so it wasn't 2026-10-10's width sum. The empty owners were `GamUser.id`, which is the address,
  used as the Google account ID (`GamUser.accountID`): no class's `ownerId` ever matched.
- **Why not caught:** the package tests can't draw a screen, and the screen was first drawn by CI. The owner lookup lived
  in the view, where no test reached it. Investigating, I launched the app visibly on the operator's screen four times
  before stopping, against 2026-10-10's lesson.
- **Fix:** PR #158. The note wraps without `fixedSize`; `ClassroomReads.owners` names owners by `accountID`, held by
  `ClassroomReadsTests.ownersAreNamedFromTheDirectoryByAccountID`. The four Classroom screenshots render.
- **Prevention:** CI's screenshot run is the tripwire it was meant to be, and caught both. A look-up from the directory
  belongs in a store with a test, not in a view. Layout experiments run invisibly: a temporary local switch made the window
  transparent, off-screen and Dock-less (`setActivationPolicy(.accessory)`; `.prohibited` hides it from the snapshot too),
  and skipped the pointer warp. It wasn't committed; if layout bugs recur, a debug-only `SWIFTGAMGUI_INVISIBLE` is the tool
  to add. **Not proven** on a Mac at the operator's window size; CI's renders are the check.
