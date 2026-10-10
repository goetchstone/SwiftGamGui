# 2026-10-10 — The screenshots hid the Rendered | HTML switch, and a diagnostic commit reached main

- **Symptom:** CI's `person-mail` and `signatures-alice` images (PR #43) showed each signature preview
  as a white box with no Rendered | HTML switch, no Copy HTML and no Change Signature… button. The
  screen itself had them; only the images didn't. To find out why, a temporary commit that logged the
  geometry and wrote a second, raw image was pushed to the PR's branch, and the PR, green, was merged
  with it.
- **Cause:** the debug snapshot draws each `WKWebView` from its own `takeSnapshot` over the capture,
  since `cacheDisplay` can't draw a web view (WebKit draws it in another process). It drew over the web
  view's `visibleRect`, and for a web view hosted in SwiftUI that came back larger than the view itself:
  340 by 215 for a 320 by 120 view. The white image covered the controls above and below it.
- **Why not caught:** the snapshot path draws a web view for the first time in this PR, and nothing
  compared the image with the layout. The diagnostic went to the PR's own branch, which had CI green and
  was ready to merge.
- **Fix:** the snapshot draws only the visible part within the web view's bounds
  (`visibleRect.intersection(bounds)`); the temporary logging and raw image are removed. The
  `signatures-alice` image opens a taller window, so both signatures show.
- **Prevention:** `Spikes.drawWebViews` says why it clips. A diagnostic for a PR goes on a branch of its
  own, never on the branch under review: the operator merges a green PR, and should be able to.
