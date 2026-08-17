# RootHide PID1 A/B CI v1

This bundle builds two isolated stability candidates from the same P013onEr RootHide
repository revision:

- **B1-phase1-dedup** — only the one-file live-trustcache duplicate-upload fix.
- **B2-phase2-readonly** — supersedes B1 and includes read-only-first signature
  preparation plus final-cdhash trustcache de-duplication.

B2 must **not** apply the B1 patch first; its patch was generated against the clean
P013 source and already contains the collector correction in its final Phase 2 form.
The workflow matrix therefore applies exactly one patch per build.

## Install into a real repository

Copy the included `.github/` tree into a recursive checkout of the P013onEr RootHide
repository, commit it to a test branch, then run:

`Actions -> RootHide PID1 stability A-B -> Run workflow`

The run should produce two artifacts, one for B1 and one for B2, from the same source
revision and toolchain.

## Recommended device order

1. Keep unmodified 7a07400 as A/reference.
2. Test B1 to isolate duplicate trustcache publication.
3. Test B2 to add the read-only-first signature preparation change.
4. Use the same app set and launch-count checkpoints for all three.

Do not change tweaks/bootstrap contents between the short A/B measurement windows if
you want trustcache-entry growth to be comparable.
