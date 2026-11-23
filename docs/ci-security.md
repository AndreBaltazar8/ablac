# CI security rules

The workflows in `.github/workflows` hold the keys of a release: the `contents: write` token that publishes it and the
secret that signs it (`ABLA_RELEASE_SIGNING_KEY`, docs/bootstrap.md "Signed releases"). `tools/test-workflow-security.sh`
checks the rules below on every workflow (`--controls` shows each rule refusing a workflow that breaks it).

| Rule | Why |
| --- | --- |
| No `pull_request_target`, `workflow_run`, `issue_comment` or `pull_request_review` trigger | These run with secrets and a write token on input an outsider controls. `ci.yml` uses `pull_request`, which a fork runs with a read-only token and no secrets. |
| Top-level `permissions: contents: read` | Every job starts read-only. Only `release.yml` raises a job: `contents: write` (the bridge draft is read through the API, and the release is published), and `id-token` and `attestations: write` on the publish job (build provenance). |
| Every action is pinned to a full commit SHA | A tag or branch of an action can be moved to run other code in the release. Only `actions/*` (GitHub's own) and `cachix/install-nix-action` are allowed. |
| `persist-credentials: false` on every checkout | The token does not stay in `.git/config` for later steps. |
| Secrets only in `release.yml`, only the signing key | No other workflow, including those a pull request starts, can read one. |
| No `${{ inputs.* }}`, `github.event.*` or `github.head_ref` inside a `run:` script | The expression is pasted into the script before the shell parses it, so a value is code. Pass it through `env:`. |
| No `actions/cache`, no `cache:` key, no self-hosted runner | Nothing a pull request writes is read back by a later run. Every runner is a fresh GitHub-hosted machine, and Nix builds from `cache.nixos.org` (the default key) with nixpkgs pinned to a commit (`nix/nixpkgs.nix`). |

## What a release consumes

- The compiler is built by the pinned previous release (checksum, and from v0.2.67 its signature), from the tag's sources.
- Native LLVM comes from `tools/llvm-*-pins.sh` (the fork's releases, sha256 pinned) and nixpkgs (a pinned commit).
- Not pinned by hash, and listed in the SBOM comment: `apt-get install` inside the pinned `ubuntu:22.04` image (binaryen,
  libssl and others) for the dynamic toolchain archive, Homebrew's `binaryen` and `openssl@3` on macOS (the macOS compiler
  links Homebrew's OpenSSL), and `cachix/install-nix-action`, which downloads the Nix installer from
  `releases.nixos.org` when it runs. The static Linux compiler, the default asset, takes none of the apt or Homebrew inputs.
- `nix_path: nixpkgs=https://github.com/NixOS/nixpkgs/archive/<commit>.tar.gz` in the workflows is fetched without a hash
  for `<nixpkgs>` lookups; the build itself uses `nix/nixpkgs.nix`, which carries the hash.

## Settings that are not in the repository

These need the repository owner. They were applied on 2026-11-23 (decision #114), and the rules above do not replace them:

1. Settings → Actions → General: *Workflow permissions* = read repository contents; *Require approval for all outside
   collaborators* for fork pull requests. **Done.**
2. A GitHub Environment `release` with a required reviewer (André) and `master` as the only deployment branch, holding
   `ABLA_RELEASE_SIGNING_KEY`, and `environment: release` on the publish job (`release.yml`; `test-workflow-security.sh`
   fails a workflow whose job reads the key without it). Without it, anyone who can push a branch can dispatch a
   workflow on it that reads the secret. **Done**; a repository-level secret of the same name is deleted once the
   workflow with `environment: release` is on master.
3. A ruleset on `v*` tags (no deletion, no moving: "release tags") and one on `master` (no deletion, no force-push:
   "master"). **Done.**

## Findings of the first review (2026-11-23)

- `static-nightly.yml` pinned `cachix/install-nix-action` to a 37-character value, not a commit: the nightly job could
  not start. Fixed, and rule 3 would have caught it.
- `probe-stage1.yml` had no `permissions:` and so ran with the repository's default token. Fixed.
- Four `run:` scripts pasted a dispatch input into the shell (`bootstrap-convergence.yml` twice, `probe-stage1.yml`,
  `ci.yml`). The inputs are choices, booleans and a number that only a writer can set, so this was a hardening fix.
  `ci.yml`'s `${{ inputs.xtensa_companion_unpublished_fixture && '' || '--published' }}` also always produced
  `--published` (an empty string is false in an expression), so the unpublished fixture never ran: it now does.
