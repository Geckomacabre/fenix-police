# Work in progress — remove before the 3.0.0 release merge

Paused mid-way through the 3.0 pass. Kept here only so nothing is lost if the
cloud container is reclaimed.

- `audits/` — the seven subsystem audit reports, the cross-lane API contract,
  and instructions left for client/client.lua. Server, client modules,
  ambient, incident and client.lua part A fixes are already on this branch;
  client.lua parts B and C (client2.md / client3.md) are still to do.
- `SPEC.md` — the planned 3.0 gameplay features (F1-F9).
- `patches/feat-ambient/` — F3 (carjack → pursuit), built but NOT yet reviewed.
  Apply with `git am .wip/patches/feat-ambient/*.patch`.
- `ci/` — lint and release-packaging GitHub Actions workflows, to move into
  `.github/workflows/` once lint is clean.
