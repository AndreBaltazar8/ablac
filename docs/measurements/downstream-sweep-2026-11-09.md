# Downstream sweep, 2026-11-09 (v0.2.52 candidate)

Every `abla-*` checkout's own CI steps, each at its `origin/HEAD` (a detached worktree per repo, so the
checkouts were not touched), run with the v0.2.52 release candidate's stage 2 (`ablac 0.2.52`, built from
Prepare `0eaf983e` by the release worktree) and a detached `0eaf983e` tree as its sysroot and as the sibling
`../ablac` the repos expect. The method is that of `downstream-sweep-2026-11-08.md`: a repo's steps are its CI
workflow's `make` targets (or the previous sweep's list where it has no workflow), run where no credentials
are needed, on two CPUs.

| Repo | Tested at | Result |
|---|---|---|
| abla-blockchain | 92c6f83 | test ok; test-ct ok |
| abla-cli | 20cc9f1 | test ok |
| abla-compare | baed16d | server build ok (after `ablac package vendor --project .`, which a fresh worktree needs) |
| abla-embedded | 5d20099 | check ok (from a worktree under `~/Desktop/projects/worktrees`: the `bwrap` fallback checks cannot chdir into `/tmp`) |
| abla-food | 08a3397 | test ok against a throwaway PostgreSQL 16 on 127.0.0.1:15432, db `mimo` |
| abla-graphics | 34786d5 | test-core ok |
| abla-lsp | 740913a | `npm test` with `ABLA_COMPILER` set to the candidate: 61 pass, 0 fail |
| abla-mcp | af7e95d | check ok |
| abla-mjml | 0bdd5ea | test ok |
| abla-mobile | d736f6e | tools/test-file-exports.sh ok; tools/test-android-build-config.sh ok; tools/test-mobile-template.sh ok |
| abla-mvc | a21baba | test-library ok |
| abla-nats | 0bd19ea | check ok |
| abla-one | 8a6ba1f | test ok (`make test` vendors the locked packages first) |
| abla-pdf | 68982d9 | test-in-shell ok |
| abla-postgres | b56c87a | check ok |
| abla-printers | 7f4f7b1 | test-in-shell ok |
| abla-qr | 4fdc564 | test-in-shell ok; interop ok |
| abla-redis | 9f66e87 | check ok |
| abla-s3 | b884bc4 | test-in-shell ok |
| abla-saft | 3eadffc | test-in-shell ok (8 of 8 after `tools/fetch-sources.sh`; `xsd_test` needs the fetched XSDs); programs-in-shell ok |
| abla-smtp | 9ae698f | test ok |
| abla-soap | 326cf4a | test ok; at ok |
| abla-stripe | f5d220c | check ok |
| abla-testrunner | 01080c3 | check ok |
| abla-web | 224870e | check ok (after `ablac package vendor --project .`) |
| abla-web3d | ca5320d | `examples/characters/build.ab` builds `characters.wasm` (748,282 bytes with `--fast --no-cache`) |
| abla-xml | fea4622 | unit ok; conformance ok; fuzz ok |

No ablac regression was found: every step passes with the candidate.

- First-pass failures that were the sweep's setup, not the compiler: repos that run `../ablac/...` found no
  sibling `ablac` in the scratch directory (abla-embedded, -graphics, -mcp, -mobile, -mvc, -nats, -one) and
  passed once it existed; abla-compare and abla-web had no vendored packages in a fresh worktree; abla-saft's
  `xsd_test` needed the fetched sources.
- Not run: `abla-doom` (needs xvfb and a GPU), `abla-site` (a deploy), `abla-tmlanguage` (Node only, no
  compiler), `abla-original` (an archive of the old tree), and abla-xml's `make written` (needs `xmllint`).
- The candidate may be replaced by the final release candidate; a later pass is noted below if it changes.
