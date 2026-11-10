# Clean-bootstrap convergence, v0.2.51 lineage, 2026-11-10

The gate of [bootstrap.md](../bootstrap.md) (`tools/test-bootstrap-convergence.py`, lineage `v0.2.51`), run locally on
the newest seed pair with the candidate at `2617a727` (tree `db773b21`; the hashes of the branch before it was rebased onto master). The IR carries source paths, so both
routes and the comparison ran with the candidate at the same absolute path (`--root`).

| Route | Seed | Steps |
|---|---|---|
| A | v0.2.51 release binary, sha256 `d8e24762…` | stage 1, stage 2, stage 3 of the candidate |
| B | v0.2.50 release binary, sha256 `aa40e582…` | v0.2.51's source (`1758d94e`) built twice, then stage 1, 2, 3 of the candidate |

**Result: converged.** The raw, pre-prune `--emit-llvm src/orc_main.ab` IR is byte for byte the same across the two
routes and across generations 2 and 3 (sha256 `ba97f692…`), and so are the stage 2 and stage 3 object files
(`684e486d…`) and compiler binaries (`126d8355…`). Both routes recorded identical toolchain closures
(`7157d43a…`) and environments (`e419f7f5…`).

The stage 2 binary built from either seed is also, byte for byte, the v0.2.52 release's Linux x86-64 binary
(`platform_sha256` of the v0.2.52 pin, `126d8355…`): the release is reproduced from a seed two releases old.

Wall-clock seconds per step (not CPU: the steps ran behind a shared-machine slot queue, and the larger figures
include time waiting for a slot; route A's stage 1 and stage 2 ran without a queue):

| Step | Route A | Route B |
|---|---|---|
| historical build 1 / 2 | – | 2352 / 2310 |
| stage 1 | 285 | 1904 |
| stage 2 | 430 | 3302 |
| stage 3 | 1485 | 2118 |

A first attempt at route B stopped at its own 30-minute step timeout while queued for a slot; the timeout is now
off whenever `--wrap` is used. The comparison step refuses a source revision other than the checked-out `HEAD`, so
it ran from a detached checkout of `2617a727`; the branch has since gained only that timeout change and the release
step of the docs.

Reproduce: `python3 tools/test-bootstrap-convergence.py route --lineage v0.2.51 --root <abs>/build/source a|b <out>`
for each route, then `compare --lineage v0.2.51 --root <abs>/build/source <out-a> <out-b> <out-cmp>`; or dispatch
the workflow with `lineage=v0.2.51`. A `v0.2.52` lineage (A: v0.2.52, B: v0.2.51, historical `0eaf983e`) is
recorded for the next run.
