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
| `source_ref` is refused with `publish_release` on (`release.yml`'s `publish` job and `release-compiler.yml`'s `compiler` job, which `release.yml` calls per platform, first step) | `source_ref` builds a branch or commit to test the workflow, and the build jobs run the scripts of the tree they check out with a `contents: write` token; the publish job signs what those jobs uploaded. A published release is built from its tag, the tag ruleset's object. |
| In `release.yml` only the `bridge` and `publish` jobs hold a write permission | The build jobs (`compiler` on three runners, through `release-compiler.yml`, and the Windows toolchains) run the scripts of the tree they check out: the tag, or `source_ref` when testing. They hold `contents: read`. A draft bridge release is visible only to a token with push access, so the `bridge` job alone (no checkout, nothing of any tree runs in it) reads it and passes the assets on as the `bridge-assets` artifact. |
| `release.yml` downloads artifacts without `merge-multiple` | Merging into one directory lets an artifact overwrite a file of another with the same name without a trace. The publish job downloads one directory per artifact, refuses a file name two artifacts share and then flattens them into `release/`. |
| The workflows that build release assets install Nix through `./.github/actions/install-nix` (`release.yml`, `release-compiler.yml`, `static-suite.yml`, `windows-x64-toolchain.yml`, `windows-arm64-toolchain.yml`) | `cachix/install-nix-action` pins the Nix version (2.35.2 in the pinned commit) but fetches the installer script over TLS. The script holds the sha256 of the Nix archive it installs, so the local action checks the script against a pinned sha256 and hands the checked file to the action (`install_url: file://...`); the SBOM records it. Bump the version, the hash and the action pin together. |

## What a release consumes

- The compiler is built by the pinned previous release (checksum, and from v0.2.67 its signature), from the tag's sources.
- Native LLVM comes from `tools/llvm-*-pins.sh` (the fork's releases, sha256 pinned) and nixpkgs (a pinned commit).
- The Nix installer is pinned by sha256 (`.github/actions/install-nix`, in the SBOM).
- Not pinned by hash, and named in the SBOM comment:
  - `apt-get install` inside the pinned `ubuntu:22.04@sha256` image (binaryen, libzstd and others) for the dynamic
    toolchain archive. apt checks the Ubuntu archive's signed indexes, so the trust is the archive's, and the image is
    fixed by digest; what drifts is the package versions between two releases. The dynamic archive is the extra asset of one
    release (decision #90 A) and the static archive, the default, takes none of it. If the dynamic archive stays, pin it
    through a dated snapshot of the Ubuntu archive (a snapshot URL in the container's apt sources) rather than package hashes
    by hand, and add the snapshot date to the SBOM.
  - Homebrew's `binaryen` and `openssl@3` on the macOS runners. Homebrew checks each bottle's sha256 against its own index, so
    the trust is Homebrew's. The OpenSSL CLI is a test peer. Pinning a bottle by hand would make the build depend on a bottle Homebrew may withdraw.
- `nix_path: nixpkgs=https://github.com/NixOS/nixpkgs/archive/<commit>.tar.gz` in the workflows is fetched without a hash
  for `<nixpkgs>` lookups; the build itself uses `nix/nixpkgs.nix`, which carries the hash.

## Limits worth knowing

- The local action `.github/actions/install-nix` and the `release.yml` of a tag come from the tag's own tree when a job checks it out: a tag made before
  they existed (before v0.2.69) cannot be released again with this workflow (the job cannot find the action). Re-releasing an old tag uses the
  workflow files of that tag's time, or a new tag.
- Real cuts are published by the workflow's `publish` job once the `release` environment's reviewer approves it; the local flow
  (`publish_release` off, then `gh release create` from the maintainer's machine, docs/bootstrap.md, "Signed releases") is the
  fallback. `source_ref` is refused with `publish_release` on, so the publish path builds the pushed tag.
- The `bridge` job and its `bridge-assets` hand-off to the compiler jobs run only when a Release is dispatched with `bridge_release`, and no draft bridge
  release exists to rehearse them with: that path is fixed but unverified until the next bridge is needed. The publish job's flatten step is
  `tools/release-flatten-artifacts.sh`, tested on fixture directories by `tools/test-release-scripts.sh` (a shared file name is refused).

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
