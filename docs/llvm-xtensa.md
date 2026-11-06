# The Xtensa LLVM

Abla's ESP32 work needs LLVM's experimental Xtensa backend and the patches in
`nix/llvm-xtensa-*.patch`. A full LLVM build can take over an hour, so x86_64 Linux
uses a build made once by hand and published as a GitHub release of the fork
[AndreBaltazar8/llvm-project](https://github.com/AndreBaltazar8/llvm-project),
branch `abla/xtensa-23.1.3`: upstream's `llvmorg-23.1.3` with each patch as a commit.
Ordinary CI and Abla releases never compile LLVM. The separate manual companion
workflow described below is the exception; it runs only when a maintainer
explicitly requests a new companion.

`shell.nix` picks:

| Where | LLVM |
| --- | --- |
| x86_64 Linux | `nix/llvm-prebuilt.nix`: fetches the release by URL and sha256 |
| x86_64 Linux, `ABLA_NIX_LLVM_SOURCE=1` or changed patches | `nix/llvm.nix`: builds nixpkgs' LLVM with the patches |
| Other Nix hosts | `nix/llvm.nix` locally; off when `CI` is set |
| `ABLA_NIX_XTENSA=0` | nixpkgs' LLVM, without Xtensa |

`nix/llvm-prebuilt.nix` records a hash of the patches it was built with. If they
change, a local shell builds from source, so the patches being worked on are the
ones in use, and a CI shell stops with an error rather than build for an hour.

macOS doesn't use `shell.nix`: its jobs use Homebrew's LLVM, which has no Xtensa.
The packaged Linux toolchain likewise uses stock LLVM. The Nix-built library
requires newer glibc interfaces, including GLIBC_2.44; changing its RPATH is not
enough to use it on Ubuntu 22.04. See the measured
[portability study](design/xtensa-release-feasibility.md).

## Optional portable companion

André chose a separately versioned, optional download. It does not go into every
Abla release or replace the parent LLVM or Clang. Implementation is staged:
the fork's manual artifact workflow exists, but publication, installation and
compiler routing are not complete yet. Released compilers still need the Nix
setup for Xtensa until those gates pass. The
[design and gate list](design/xtensa-companion.md) records that status.

The private cohort is `opt`, `llc` and `libLLVM`, with the Xtensa backend, for
x86_64 Linux and native arm64/Intel macOS. Linux builds against glibc 2.35 and
carries its private C++/GCC/zlib dependencies, not a libc or loader. The Macs use
Apple Clang, loader-relative private LLVM and ad-hoc signing. Configuring a
macOS deployment target is not the same as testing on that OS version; the
workflow tests on macOS 15.

There are two distinct artifact families:

- `llvm-23.1.3-xtensa-N`: the existing Nix outputs, selected by
  `nix/llvm-prebuilt.nix`, with their store-path rewrite metadata.
- `abla-xtensa-llvm-23.1.3-R-<platform>.tar.gz`: the optional portable `opt`/`llc`
  companion, with its private libraries, licenses, versioned manifest and
  per-file SHA-256 hashes. It is not a drop-in Nix archive.

Its scope is to replace the Nix requirement for **Abla code generation only**.
It does not replace the ESP SDK, GNU linker, startup files, target libraries or
GNU-as orchestration for boot/vector assembly. This fork has no Xtensa LLD
backend. No Abla build downloads a companion implicitly.

### Explicit installation

The installer requires Python 3.9 or newer and its standard library; it uses no pip packages.
The Abla toolchain packagers include `bin/abla-install-xtensa`. From an existing
source checkout the equivalent command is:

```sh
python3 tools/install-xtensa-llvm.py --toolchain-root /path/to/abla-toolchain \
    --version 23.1.3-1
```

From a packaged toolchain use its absolute path, without adding the companion's
`bin` directory to `PATH`:

```sh
/path/to/abla-toolchain/bin/abla-install-xtensa --version 23.1.3-1
/path/to/abla-toolchain/bin/abla-install-xtensa --verify
```

For an offline install add `--archive /path/to/the-host-archive.tar.gz`. The
archive still has to match the checked-in catalog. Installation never changes
Clang, the parent LLVM, or the compiler binary. The current compiler does **not
yet route Xtensa code generation to the companion**; that is a separate gated
change. Installing it alone does not make a released compiler support Xtensa.

The catalog is `tools/xtensa-companions.json`, also shipped under
`share/abla/xtensa-companions.json`. It pins the archive URL and SHA-256 and the
raw per-archive manifest SHA-256 for each host. CI compares those pins with the
fork's published `.sha256` files and combined manifest; it downloads only this
small metadata, never LLVM sources or companion archives on a normal CI run.
A separate manually dispatched installer probe runs the real tools on all three
hosts and compares their output with the frozen Nix reference.

The installer hashes the entire archive before extracting it, rejects links and
special files, limits compressed and unpacked sizes, and checks the exact file
set and every file's SHA-256 before running a helper. It installs a read-only
revision under `lib/abla/xtensa-llvm/23.1.3-1` and atomically selects it with the
relative `current` symlink. Old revisions remain intact. A failed install keeps
the old selection; reinstalling the same revision fully verifies it first.

Every install, activation and explicit `--verify` rehashes **all** files. A
changed library with the same size and modification time fails that next full
check, and changing its manifest cannot bypass the catalog's pinned manifest
hash. This is not a promise to hash libraries on every build: the planned
compiler routing uses the selected immutable revision's manifest and file
identity in its cache key. After copying or restoring a toolchain, run
`--verify` before using it. Read-only file modes guard accidental writes, not a
malicious owner who can replace the installer, catalog or compiler themselves.

### Building a companion (maintainers)

The only source-building workflow is the fork's
[manual companion workflow](https://github.com/AndreBaltazar8/llvm-project/blob/main/.github/workflows/abla-xtensa-companion.yml).
It is not called by `ci.yml` or `release.yml`. Its config pins the fork commit
and source archive checksum. Run it after LLVM or its patches change, with a
new companion revision; never overwrite a published version.

```sh
gh workflow run abla-xtensa-companion.yml -R AndreBaltazar8/llvm-project \
    -f revision=1 -F publish=false
```

Review all three host builds, relocation and the clean Ubuntu 22.04 check,
sizes and timings, and the frozen assembly digest before requesting a
`publish=true` run. The Linux helper must run without the source build's GCC
installation; both Mac architectures run natively. The optional publisher
requires every gate to pass, creates a draft with all archives/checksums, and
then publishes it without changing the fork's latest-release marker. Failed
or already-used versions are not overwritten.

The release includes per-archive `.sha256`, `SHA256SUMS` and a combined
`manifest.json`. The installer catalog will pin the archive and manifest hashes
in one checked-in table and check them against the published metadata in CI.
Installation and full integrity verification remain explicit actions, separate
from compilation.

## Adding a patch

1. Write it against `llvm/` as `nix/llvm-xtensa-<name>.patch`, add it to
   `nix/llvm.nix` and to `patchNames` in `nix/llvm-prebuilt.nix`, and develop with
   the local shell, which builds from source once the patches differ.
2. Commit the same change on the fork's branch: `git apply --directory=llvm <patch>`.
3. Point `commit` and `sha256` in `nix/llvm-fork.nix` at it
   (`nix-prefetch-url --unpack <archive url>`).
4. For the Nix artifact, run
   `tools/package-llvm-xtensa.sh llvm-23.1.3-xtensa-<n+1> <directory>`
   on this kind of machine, not on CI.
5. Compare the new `llc` with the source-built one on Xtensa code, and check the
   archive's contents for local paths and keys.
6. `gh release create` the archive and its `.sha256` on the fork, tagged
   `llvm-23.1.3-xtensa-<n+1>` at the branch's commit.
7. Update `tag`, `sha256` and `patchesSha256` in `nix/llvm-prebuilt.nix`. Moving to a
   new LLVM or nixpkgs repeats this with a new branch.
8. For a portable companion, update the fork workflow's pinned source commit and
   archive checksum, use a new companion revision, and review all three dry-run
   results before publishing. Update a frozen assembly digest only after
   comparing the new source build with the intended reference; do not merely
   replace a failing golden value. Pin the published archive and manifest
   checksums in Abla's catalog and run its live metadata check.

The portable companion has its own revision and release workflow; updating the
Nix pin does not publish a companion or silently select a held patch. The
128–255-byte scavenging-slot fix remains under its separate hardware gate.
