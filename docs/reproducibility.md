# What a third party can rebuild bit for bit

The claim, stated so that it can be checked and so that its limits are visible. Every row names the check that backs it.

## Proven today

| Claim | How to check it | Backed by |
| --- | --- | --- |
| **Stage 2 equals stage 3**: the compiler built by the pinned seed from the sources (stage 1), by stage 1 (stage 2) and by stage 2 (stage 3) are the same bytes from stage 2 on | `tools/bootstrap-stages.sh <seed> <dir>` prints `stage2 == stage3`; `--full` compares the executables too | `tools/bootstrap-stages.sh`, `tools/test-pure-self-rebuild.sh`, the release gate |
| **A Linux release rebuilds byte for byte, anywhere**: another directory, `HOME`, temporary directory, time zone, locale, any number of processors | `tools/build-self-hosted-current.sh published build/rebuilt && cmp published build/rebuilt` (docs/bootstrap.md) | `tools/test-reproducible-elsewhere.sh --self`, run by `release.yml` |
| **The release asset is the checked build**: the Linux binary of the workflow run is `cmp` equal to a local stage 2 before the tag is published | `tools/release-check.sh` check `stage2` | `tools/release-check.sh` |
| **Two seeds reach the same compiler**: the previous release and the one before it, each bootstrapping the candidate, give identical canonical IR | `bootstrap-convergence.yml` (`tools/release-convergence.sh`) | the required `convergence` check of `release-check.sh` |
| **Code generation is deterministic**: the same program built twice gives the same object and executable | two builds, `cmp` | `tools/test-reproducible-build.sh` |
| **The macOS compilers of v0.2.47 rebuild raw-`cmp` equal** on `macos-15` and `macos-15-intel`, with the recorded Xcode, SDK and LLVM | the manual `macos_published_rebuild` input of `ci.yml` | docs/bootstrap.md, run 42158176059 |
| **The release's files are the ones the project signed** (from v0.2.67) | `tools/verify-release.sh DIR` | docs/bootstrap.md "Signed releases" |

## Not proven

- **The seed.** The first stage comes from a binary: the pinned previous release. It is checked by its sha256 (and from
  v0.2.67 by the project's signature), not rebuilt from source: there is no chain from a C compiler or an older
  source-only compiler. The convergence check shows that two different seeds reach the same compiler, which makes a
  seed that inserts a backdoor visible only if both lines of seeds carry it. Someone who wants to avoid trusting any
  binary has no path today.
- **LLVM.** The compiler links LLVM and lld. The Linux static compiler takes them from nixpkgs (a pinned commit) with
  the fork's patches (`nix/llvm-fork.nix`); the prebuilt archives of the fork's releases (the portable Linux LLVM,
  the macOS LLVMs, the Xtensa companion) are pinned by sha256, but were built by CI and are not rebuilt by this
  repository's checks. Rebuilding them bit for bit is not claimed.
- **macOS, beyond v0.2.47.** The v0.2.47 rebuild is one recorded comparison with recorded tools. A newer release, SDK, Xcode or
  LLVM has no such run, and the executable of a Mac build carries paths, a UUID and an ad-hoc signature that
  depend on the machine.
- **Windows.** No reproducibility check exists.
- **The toolchain archives.** The dynamic Linux archive and the macOS archives take packages from `apt` and Homebrew
  at build time (docs/ci-security.md), which are not pinned by hash. The static Linux archive does not; its content is
  covered only through the static compiler's fixpoint and its size and dependency checks, not by a rebuild of the archive.
- **`ablac-dynamic-x86_64-linux` against other build environments.** Up to v0.2.74 the RUNPATH held the build shell's own
  store path (`<hash>-nix-shell/lib`, a directory that does not exist; its hash follows the shell's arguments), so a rebuild
  in another shell differed in 52 bytes: that path and the GNU build id. `shell.nix` no longer lets it into a link; two
  shells (the default and `ABLA_NIX_ANDROID_TESTS=1`) link the same bytes. `ABLA_NIX_XTENSA=0` still changes the
  store paths of LLVM in the RUNPATH.
- **`ablac-x86_64-linux` (the static compiler) is not rebuilt bit for bit by a third party.** The release checks it by its
  fixpoint (pass 2 equals pass 3, `tools/test-static-artifact.sh`, which a third party can run on the published file
  with the pinned archives from `tools/static-llvm-env.sh`). `tools/build-static-compiler.sh` on the published dynamic
  asset gave the same file in three runs here, but not the published one (v0.2.73: 3,816 bytes smaller, .text and .rodata
  differ); the cause is not found. Compare the dynamic asset, not the static one.
- **The Xtensa and Wasm outputs of a user's program** are deterministic for one toolchain (the same compiler, the same
  LLVM) and are not compared across LLVM versions.
- **Source provenance of dependencies of the nixpkgs closure** beyond what nixpkgs itself provides.

## What would close the gaps

1. A source-built seed: a small bootstrap compiler in a language with a long-lived reference compiler, or a published
   chain of the earliest releases rebuilt in order, so the first trusted binary is a few steps from source.
2. A rebuild of the Linux static compiler and the prebuilt LLVM archives in an independent environment on every
   release, published as a comparison like the v0.2.47 macOS one.
3. Hash-pinned apt and Homebrew inputs, or removing them from the archives (the static archive already has none).
4. A macOS rebuild on every release.
