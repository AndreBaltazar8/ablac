# Downstream sweep, 2026-11-09 (v0.2.52 candidate)

Every `abla-*` checkout's own CI steps, each at its `origin/HEAD` (a detached worktree per repo, so the
checkouts were not touched), run with the v0.2.52 release candidate's stage 2 (`ablac 0.2.52`, built from
Prepare `0eaf983e` by the release worktree) and a detached `0eaf983e` tree as its sysroot. The method is that
of `downstream-sweep-2026-11-08.md`: a repo's steps are its CI workflow's `make` targets (or the previous
sweep's list where it has no workflow), run where no credentials are needed, through the shared build slots.

Status: in progress. The table below is filled as steps finish.

| Repo | Tested at | Result |
|---|---|---|
| abla-lsp | 740913a | `npm test` with `ABLA_COMPILER` set to the candidate: 61 pass, 0 fail |
| abla-web3d | ca5320d | `examples/characters/build.ab` builds `characters.wasm` (748,282 bytes with `--fast --no-cache`) |
