# 2026-11-21 — A roster alias planned its own account's removal; the risk bases were too wide

- **Symptom:** nothing seen live (no Education tenant). Found by this repo's review of its Classroom port on 2026-11-14, logged
  then as "Open, shared with GamGUI" in docs/domains/classroom.md, and fixed in GamGUI first (its #128, its failure log of
  2026-11-14). (1) A SIS that lists a teacher by an old address that is now an alias (`jdoe@` for `jane.smith@`) read as "no
  account": she was left out of the class's SIS teachers, another SIS teacher became owner (hand-over step 07), and
  `jane.smith@` was removed (08) from the class she owned; a student the same way (10). The note said such people "aren't added
  (nor removed)". Without the directory the same happened unnoted. (2) Removing every co-teacher of 400 classes wasn't held back,
  and archived classes counted in both risk bases.
- **Cause:** (1) `UserAccess.directoryAddresses` returned primary addresses only, and `RosterPlan.plan` compared SIS addresses
  with Classroom's (always primaries) as plain text. The directory read asked for `aliases` already; nothing used them, and
  `GamUser` didn't read `nonEditableAliases` (alias-domain addresses), which `fields aliases` also returns. (2) `flags` measured
  teacher removals against teachers and students, and `managed` and `enrolled` counted archived classes.
- **Why not caught:** every planner case used one address per person, so a primary and its alias never met; the risk cases had
  one class and one role. The planner is held to GamGUI's, so the parity test passed on GamGUI's flaw: parity is a floor.
- **Fix:** this branch, with the fixtures regenerated at GamGUI d03f5a6. `GamUser.primaryOfEveryAddress` (GamGUI's
  `primary_of_every_address`, shared with the incident screen's `DirectoryIndex`) maps every address to its account's primary;
  `directoryAddresses` returns it; `plan` reads each SIS address through it, notes the aliased and, without the directory, holds
  a class whose roster names someone Classroom doesn't list there (no removal, no owner change). Risk bases: active classes only,
  teacher removals against their teachers (`ChangeList.teachers`). The mock's Alice has `nonEditableAliases`, as GAM gives it.
- **Prevention:** `roster_plan.json` now records GamGUI's alias, hold and risk-base cases with the directory as [address,
  primary] pairs (`RosterPlanTests` refuses two spellings read as one key); `RosterCompareTests.aSISAddressThatIsAnAliasIsReadAsItsAccount`
  plans through the mock by Alice's alias and her alias-domain address and checks the read asks for `aliases`;
  `DirectoryTests` holds `nonEditableAliases` and the map. **Not proven live:** no Education tenant to compare on.
