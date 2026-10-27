# 2026-10-24 — Built with Xcode 27.1, Onboard's role went blank and the log reader stopped scrolling to its findings

- **Symptom** — CI's screenshots: Onboard's Role picker showed nothing, though the summary under it was Salesperson's,
  and Read the logs came out at the top of Investigate instead of at its findings. Same code since they last rendered
  right (2026-10-21); this Mac, on Xcode 27.0, builds both right. They were found only when every screenshot was
  refreshed together: each PR had refreshed only its own, and these two pictures still showed the old, right state.
- **Cause** — CI's runner moved from Xcode 27.0 (27A266a) to 27.1 (27A9275) on the same macOS 27.0.1, and SwiftUI
  behaves by the SDK an app is built with. Measured in CI (the snapshot log's `state:` lines): the reader's scroll ran,
  0.1 s after its reading came, and landed at the page's top (y 0 of 2,599), while the logs' anchor on the same page
  still scrolled (y 222). The reader's `.id` was on `LogReaderView`, whose body wraps its one section in a `Group`
  with `.onChange` and `.sheet`; the logs' is on a view that is its section. The Role picker's selection, `roleName`,
  is "" until the roles load and the demo picks one, so on its first draw it matched no item; Signatures' person picker,
  the same `@SceneStorage` and the same kind of `ForEach`, always has an item for its selection, and still showed it.
- **Why not caught** — Nothing checks what a screenshot shows, only that it was taken; the pictures in `docs/` were
  refreshed one PR at a time, so two stale ones hid the change. A toolchain update arrives with no commit, so nothing
  on this side marks it. Two of the first diagnoses were guesses made from pictures (see PR #115), not measurements.
- **Fix** — The reader puts its anchor on the section it shows (`LogReaderView.anchor`), not on its wrapper. The Role
  picker has an item for a selection that's no role ("Choose a role…"), as Signatures' has. Both matter in use, not
  only in the demo: Pull Again and Show the Events scroll the same page, and a role picker that stays blank looks
  unset. The snapshot log names what a picture can't: each pop-up's value as VoiceOver reads it, each scroll view's
  position, and the reading demo's timing.
- **Prevention** — Every screenshot is refreshed at once (`scripts/refresh_screenshots.sh`), so a change shows in the
  next run's pictures. A picture that looks wrong is first compared with `main`'s own render of it, then measured from
  the `state:` lines, before anything is changed (`pre-commit`). An anchor goes on the exact view to scroll to; a
  picker's selection always has an item.
