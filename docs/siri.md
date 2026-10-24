# Siri and Shortcuts

Say **"Change a title in GAM GUI"** ("Gam Gooey" is heard as GAM GUI, the app's name on screen and to
Siri). Siri asks whose title and the new one (a department too, if you like), and the app opens on Users
with that person selected and the change drafted. Nothing changes
until you check it and click **Save**: Siri only drafts. The same action is in Shortcuts as **Change
a Title**. If more than one person matches the name, the list shows them and nothing is drafted.

**Confirmed through Shortcuts (2026-10-10):** the action drafted a title and department change on a
real tenant, the operator saved it with a click, and the audit recorded `origin: siri`. **Spoken:** Siri
couldn't find "GamGUI" (it hears "GAM GUI", ignores alternative names on the Mac, and the original
GamGUI shares the old name), so the app is now named GAM GUI; the spoken check is open on that build.
