# Clean-bootstrap convergence, v0.2.52 lineage, 2026-11-10

The gate of [bootstrap.md](../bootstrap.md) (`tools/test-bootstrap-convergence.mjs`, lineage `v0.2.52`) on master
`0de1b8ec` (tree `f4741303`), run locally with the candidate at one absolute path (`--root`). Follows
[the v0.2.51 run](bootstrap-convergence-v0.2.51.md).

| Route | Seed | Steps |
|---|---|---|
| A | v0.2.52 release binary, sha256 `126d8355…` | stage 1, stage 2, stage 3 of the candidate |
| B | v0.2.51 release binary, sha256 `d8e24762…` | v0.2.52's source (`0eaf983e`) built twice, then stage 1, 2, 3 of the candidate |

**Result: converged.** The raw, pre-prune `--emit-llvm src/orc_main.ab` IR is byte for byte the same across the two
routes and across generations 2 and 3 (sha256 `e0117c50…`), and so are the stage 2 and stage 3 objects (`24292c49…`) and
compiler binaries (`7b59a0cf…`). Both routes recorded identical toolchain closures (`7157d43a…`) and environments
(`e419f7f5…`). The candidate is a post-v0.2.52 master, so its binary (`7b59a0cf…`) is not a release; the v0.2.53
lineage is run on the release candidate and compares against the published binary.

Wall-clock seconds per step (not CPU: the steps ran behind a shared-machine slot queue, and the figures include the
time waiting for a slot):

| Step | Route A | Route B |
|---|---|---|
| historical build 1 / 2 | – | 509 / 585 |
| stage 1 | 659 | 201 |
| stage 2 | 891 | 680 |
| stage 3 | 1409 | 611 |

The comparison step refuses a source revision other than the checked-out `HEAD`, so run it from a checkout of the
candidate commit.
