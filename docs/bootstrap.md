# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with a checksum-pinned
native `v0.2.78` host artifact for Linux x86-64, Intel macOS, or Apple Silicon.
Mach-O artifacts can be emitted and linked on Linux with LLVM, an Apple SDK,
and ABI stubs for the target libraries. The resulting artifact is then
executed by the matching Mac release gate.

```text
published ablac binary
        |
        v
current src/*.ab, a runtime with both object layouts -> bridge compiler
        |   (only while the published binary predates typed instances,
        v    see "Typed instance layout")
current src/*.ab -> build/ablac.bin
        |
        v
current src/*.ab -> fixed-point compiler
```

`make bootstrap` selects, downloads, and verifies the artifact for the current
host. `make ablac` then uses
it to rebuild the current sources. `make self-rebuild` builds another compiler,
requires byte-identical LLVM IR from both compilers, audits the child for
unresolved Abla runtime symbols, and uses it to build and run a native probe.

`tools/bootstrap-stages.sh <bootstrap> <directory>` is the fixed-point check
of a tree: it builds stage 1 with the given compiler and stage 2 with stage 1,
keeping the bitcode stage 2 was built from (`ABLA_COMPILER_BITCODE=<path>`),
then runs stage 2 only up to its own bitcode (`ABLA_COMPILER_BITCODE_ONLY=1`)
and compares the two byte for byte. Equal bitcode gives the same executable,
since `opt` and code generation are deterministic
(`tools/test-reproducible-build.sh`), and skipping them saves about 48 s of a
three-stage build. It prints `stage2 == stage3` only on a match. `--full`
builds stage 3 whole and also compares the executables, for release gates.

`tools/test-clean-bootstrap.sh` checks that path from a fresh clone: the
pinned release builds a stage-1 compiler from the current sources, and the
stage-1 builds and runs a program. It reports which errors stop it when the
sources use something newer than the pinned release, which means the pin has
to move. It isn't part of `make test`; `ABLA_BOOTSTRAP_URL` and
`ABLA_BOOTSTRAP_SHA256` try a candidate release.

For the v0.2.20 to v0.2.21 transition, `build-self-hosted-current.sh` first
builds checkpoint `773683772ce54bcfae4fdfd7049b55bd28ea1814` from a
checksum-pinned source archive. That checkpoint implements private declarations
and generics, but its own standard library still uses syntax v0.2.20 accepts.
The intermediate compiler then builds the current sources. This automatic
handoff applies to a v0.2.20 compiler only; newer bootstraps build directly.
The release workflow still rebuilds stage 2 and verifies the fixed point.

A Linux release is reproducible byte for byte. From the tag, in any directory,
with `gh release download <tag> -p ablac-dynamic-x86_64-linux` as `published` (from v0.2.66 on the
`ablac-x86_64-linux` asset is the statically linked compiler, which the release checks by its fixpoint:
tools/test-static-artifact.sh; it is the bootstrap seed, and the dynamic asset ships beside it as an opt-in: it is the only compiler with compile-time `dlopen` and the stage 2 cmp proof):

```sh
tools/build-self-hosted-current.sh published build/rebuilt
cmp published build/rebuilt
```

(`chmod +x` it first.) Since v0.2.28 release CI uses the default shell. Its LLVM
store path is in the binary's RUNPATH, so `ABLA_NIX_XTENSA=0` or a change to the pinned LLVM
can change that path and the build ID. Historical releases also recorded the shell's OpenSSL path and, up to
v0.2.74, its own lib directory. Releases up to v0.2.27 were built without Xtensa and cut the module
by the machine's processors, so they match only with `ABLA_NIX_XTENSA=0 ABLA_NATIVE_JOBS=4`.
`tools/test-reproducible-elsewhere.sh` guards this; `--self` is the release's gate.

### Compare a published macOS compiler

The manual CI input `macos_published_rebuild=true` runs independent native
rebuilds on `macos-15` (arm64) and `macos-15-intel` (x86_64):

```sh
gh workflow run ci.yml --ref master -f macos_published_rebuild=true
```

This check is deliberately pinned to v0.2.47. It checks out that tag in a
separate directory, downloads the checksum-pinned v0.2.46 seed named by the
**tag's** bootstrap script, and builds two generations with the release's
LLVM toolchain. It also checks the downloaded v0.2.47 assets against their
published SHA-256 values. Ordinary CI jobs do not run in this opt-in mode.

[Independent rebuild run 42158176059](https://github.com/AndreBaltazar8/ablac/actions/runs/42158176059)
on November 6, 2026 matched both raw published assets:

| Architecture | Bytes | Rebuild environment | Published and rebuilt SHA-256 |
| --- | ---: | --- | --- |
| arm64 | 5,941,568 | macOS 15.8.2, Xcode 16.4, SDK 15.5, LLVM 23.1.5 | `9dabf38f755b2799bebd26fe6923805505fed0b87a5673af8880984e871d1d35` |
| x86_64 | 7,505,280 | macOS 15.7.9, Xcode 16.4, SDK 15.5, LLVM 23.1.0 | `528ea7b619820215b63a678a8c4d43e55a326428014d13f92d9ee64db36c2e4d` |

Both had zero differing sections and function spans. This verifies that release
with those recorded toolchains, not arbitrary future SDK or LLVM versions.
No timestamp, path, UUID or signature exception was needed.

The final link name is `fixed-compiler`, matching release CI: Apple's arm64
ad-hoc CodeDirectory includes this name as its identifier. Renaming the
finished file preserves its bytes; linking it with another name need not.
The existing `ZERO_AR_DATE=1` link environment also remains in effect.

The gate is raw `cmp`, including UUIDs, paths, load commands and signatures.
It does not strip, normalize or re-sign either image. Artifacts retain both
binaries, build logs, seed/toolchain/SDK provenance, and Mach-O inventories.
On a mismatch, `comparison/comparison.json` identifies the first differing
byte, its section or load command, and changed function spans where symbols
permit. Deliberate code, UUID and (when present) signature mutations verify
that the comparator rejects differences. A changed SDK, linker or LLVM
version is recorded, not silently accepted as an exception.

The published binary is trusted only as the initial translator. The readable
Abla source graph and fixed-point check define the maintained compiler. A
future release can be bootstrapped by the previous Abla release without
reintroducing a second compiler implementation.

## Signed releases

From the release named in `tools/first-signed-release`, every release carries `SHA256SUMS` (the sha256 of every
asset, including the bill of materials) and `SHA256SUMS.sig`, an `ssh-keygen -Y sign` signature (namespace
`abla-release`) by the project key whose public half is `release-signing.pub` at the repository root. The private key
is the secret `ABLA_RELEASE_SIGNING_KEY` of the GitHub environment `release` (master-only, André reviews each run; its backup is git-crypt encrypted in `secrets/`); the publish job of
`.github/workflows/release.yml` signs with `tools/sign-release.sh`, which verifies the result against the committed
public key before anything is published. The release also ships `ablac-<version>.spdx.json`, an SPDX 2.3 bill of
materials (`tools/release-sbom.sh`: the assets with their sha256, the LLVM fork commit and patch, the prebuilt LLVM
archives, the Xtensa companion, the nixpkgs commit and the bootstrap seed), and a GitHub build-provenance attestation
for every asset (`gh attestation verify <asset> --repo AndreBaltazar8/ablac`).

When a release is made locally (the publish-off run's artifacts are checked, then uploaded with `gh release create`),
run `tools/sign-release.sh DIR KEYFILE --tag vX.Y.Z` from the release commit's checkout on the directory `release-check.sh`
checked: it writes the SBOM, `SHA256SUMS` and `SHA256SUMS.sig` there and verifies them against `release-signing.pub`
(`KEYFILE` may also be named by `ABLA_RELEASE_SIGNING_KEY_FILE`). Run `release-check.sh` on that directory again: its
`signature` check passes, and every file of the directory is uploaded.

To check a download by hand, put `SHA256SUMS`, `SHA256SUMS.sig` and the assets in one directory and run
`tools/verify-release.sh --version vX.Y.Z DIR [ASSET...]`. It refuses a release without a signature, a signature that does not verify
under the key `tools/release-signing-keys` gives that version, signed files whose bill of materials is another release's,
and any asset that is not listed or does not match. Without `--version` it checks against `release-signing.pub`, the
current key. `tools/release-signing-keys` maps each range of releases to the key that signs it, so a replaced key keeps
verifying the releases it signed and nothing later; the open range's key is `release-signing.pub`. The consumers verify the same way and
fail closed for a signed release: `setup-abla` (the toolchain archive), `tools/bootstrap-compiler.sh` (the seed, besides
its pinned sha256), `tools/release-pin.sh` (the release it pins) and `tools/release-check.sh` (the `signature` check, and
the `sbom` check that the bill of materials lists exactly the assets with their sha256; both are SKIP before publish,
since the publish job makes and signs them). Releases before the first signed one have only the checksum files; the
bootstrap seed's pinned sha256 in the repository covers them. `tools/test-release-signing.sh` runs the accept and
refuse cases with throwaway keys.

## Historical-seed convergence

The manual **Historical bootstrap convergence** workflow
(`.github/workflows/bootstrap-convergence.yml`) compares two fresh Linux
builders at the selected branch or commit. It never publishes a release.
Its challenge seeds are fixed separately from the normal moving bootstrap
pin:

- Route A: checksum-pinned v0.2.45 → candidate stage 1 → stage 2 → stage 3.
- Route B: checksum-pinned v0.2.44 → v0.2.45 sources, twice → candidate
  stage 1 → stage 2 → stage 3. The historical source commit is
  `ca9221b0615cd419284a9e8e9f671bf8429ccd3b`, the v0.2.45 tag; that tag's
  own bootstrap pin is v0.2.44.

A newer pair is chosen with `--lineage` (and the workflow's `lineage` input); `LINEAGES` in
`tools/test-bootstrap-convergence.mjs` lists them. `v0.2.51`: route A starts from the checksum-pinned v0.2.51
and route B from v0.2.50, rebuilding the v0.2.51 sources (`1758d94e64b0e7f31f22107f8556fd63dc4351c6`) twice; the
The same shape for `v0.2.52` and `v0.2.53` (the latter: A the v0.2.53 pin, B v0.2.52, sources `b9ed669ce148440cef09650dde9db4085358f0cd`). The
default stays the v0.2.45 pair above. Adding a lineage is adding its two seed checksums and the bridge commit.

**Release gate.** A release is not published until this gate is green on its source commit.
`tools/release-convergence.sh run vX --source-ref <the commit vX is made from>` dispatches the workflow with
`lineage=<the release before vX>` and `source_ref=<commit>`, waits, checks that the run's comparison names that lineage and
that commit, prints `PASS` or `FAIL`, and writes the release-notes text (both seeds and their checksums, the bridge
commit, the canonical IR, stage 2 and toolchain hashes, the run) to `build/release-vX.notes.md`, for
`gh release create ... --notes-file`. Route A starts from the previous release's binary and route B from the one before it,
so both seeds exist before vX does. `tools/release-check.sh` has a required `convergence` check that fails unless a green run
for that source and lineage exists (`--convergence-run ID`, or the newest matching green run; `--source-ref` names the
commit until the tag does). After vX is published, add its `LINEAGES` entry (route A: vX's pinned seed; route B: the previous
release's seed; historical: vX's tag commit) and the workflow's `lineage` option: they gate the next release, and a unit test
fails when the two lists differ. `tools/release-after.sh vX` does this and the pin (`tools/release-pin.sh`) in one go, changing
only those lines (`--commit` commits the steps separately, `--times FILE` also refreshes `tools/test-times.tsv`).

Each source tree uses its own runtime, standard library and Nix shell.
Candidate sources occupy `/build/source` on both builders, with a declared
environment, fresh home, temporary and cache directories, no object-cache
reuse, and at most four CPUs. The script refuses to overwrite an existing
`/build/source` or `/build/historical`. Seed downloads are checked against
reviewed SHA-256 values; missing, incompatible or corrupt seeds fail the job,
with no fallback to a different seed.

The canonical representation is the exact bytes of explicit, non-debug
`--emit-llvm src/orc_main.ab`, before pruning, optimization or partitioning.
Both stages emit it using the same entry spelling and logical source path.
The gate checks stage 2 against stage 3 in each route, then compares the
routes' stage-2 IR, ordinary compiler objects and executables. It also runs
a native child returning 42. Kept production `.ll`, optimized bitcode and
IR emitted by an older seed while building stage 1 are different artifacts;
they are not substituted for this comparison. No source attributes, symbol
names or other metadata are stripped to make a mismatch pass.

Route artifacts retain both raw IR files, compiler binaries and objects,
per-stage logs and durations, source revision/tree/archive hashes, seed and
stage-chain hashes, and Nix toolchain paths, versions and closure identities.
The join verifies those records and the dispatched revision, and retains an
exact-match or first-difference report. Trigger with the Actions UI or:

```sh
gh workflow run bootstrap-convergence.yml --ref <branch-or-tag> -f lineage=v0.2.51
```

This is historical-seed route assurance within one compiler lineage, not a
trusting-trust defense or an independent compiler implementation. It does not
replace release tests or close tiers 4 and 5 of the
[reliability roadmap](reliability-roadmap.md#7-complete-self-hosting-and-bootstrap-trust).
Initially run it manually around releases, rather than adding five historical
route builds to every push. Allow about 6–12 extra build minutes plus cold
toolchain setup for route B; these are planning estimates, not a latency gate.

## Windows release fixed points

When [Release](../.github/workflows/release.yml) ships a Windows zip
(`windows=with` for x64 or `windows_arm64=with` for ARM64), it runs the
native fixed point on that architecture before publication. The packaged
compiler builds stage 2, which then builds stage 3. The job compares their
COFF objects, export definitions, and PE executables, runs hello with stage 3,
and checks that a scalar compile-time probe runs natively in all three
compilers. The dispatch-only `fixpoint` modes still let you choose the
interpreter or native tier. The `only` modes exercise the packaged zip.

For a publish-off run, [release-check.sh](../tools/release-check.sh) requires
`PASS windows-fixpoint` or `PASS windows-arm64-fixpoint` for each Windows zip
in the candidate assets. It reads that release run's job result and log,
checks the digest of the zip the job used, and reports the matching stage 2
and stage 3 PE SHA-256. Use the same release run ID when checking already
downloaded or locally signed assets with `--artifacts`.

## Repository layout

```text
src/       compiler implementation and command-line entry points, all Abla
stdlib/    standard library written in Abla
stdlib/abla/runtime/   portable runtime and target platform modules, all Abla
runtime/   narrow Darwin translation adapter used only by Mach-O artifacts
tests/     language, diagnostic, conformance, and execution fixtures
tools/     bootstrap, test, benchmark, and release utilities
docs/      language and architecture contracts
```

There is no generated-C backend or second compiler runtime. The portable
runtime is Abla source compiled into the same LLVM unit as each program.
Mach-O artifacts additionally link `runtime/abla_darwin_compat.c`, a narrow
adapter for remaining compatibility paths. Current macOS builds route most
portable system calls through the Abla BSD-system-call dispatcher; the older
C implementations remain for iOS and older bootstrap compilers. It contains no Abla value,
allocation, evaluator, or compiler implementation.

LLVM and the platform linkers remain native toolchain dependencies. Libc-free
Linux program links use LLD directly without clang; the x86-64 static compiler
can embed LLD through `runtime/abla_lld_shim.cpp` when its archives and headers
are configured. The dynamic toolchain and other targets retain their own
native build-tool requirements.
Linux pins them through Nix, with [a prebuilt LLVM for Xtensa](llvm-xtensa.md);
macOS uses Homebrew LLVM and the system
Mach-O linker. Removing those hosted dependencies is a separate freestanding goal described in
[full-self-hosting.md](full-self-hosting.md).

## Word-zero intrinsic transition

The v0.2.14 release is the bootstrap bridge for `ablaRuntimeValueWord0`, which
v0.2.13 cannot compile. The v0.2.15 source tag pins that bridge's host binaries
and checksums. Current clean builds start directly from the checksum-pinned
v0.2.78 stable host binaries. LLVM 23 has been used since v0.2.16.

The v0.2.14 tag preserves the bridge source and its reproducible source chain
from v0.2.13. The historical `tools/bootstrap-word0-bridge.sh` helper has been
removed from the current tree; it is not a prerequisite or command for a
current clean build. Release tags preserve the source history.

## Strict-imports transition

The compiler's sources are a strict-imports package (`src/abla.toml` says
`visibility = "imports"`): each module imports the modules whose names it
uses. A few of them use the runtime's names, which every module sees
without an import only from the compiler that made the standard library
strict and the runtime visible everywhere. A compiler that knows
`visibility` but predates that rule (v0.2.20 is one) rejects those uses,
so building the compiler from source needs either a compiler that has the
rule or one from before `visibility`, which builds the sources flat. Clean
builds start from a bootstrap release that has it.

## Object layout change (extension-field overflow)

A class instance's header changed: `+24` is now its overflow of fields set by
name (0 when there is none), where it used to point at its own inline slots.
Compile-time code compiled by the JIT and the compiler running it share
objects, so a compiler whose own runtime predates this change can't run
compile-time JIT code against the new standard library (it reads `+24` as
the slots). A stage-1 compiler built by v0.2.18 has that old runtime: rebuild
it once more to produce stage 2 before running tests, parity or releases.
The v0.2.19 release completed that rebuild on every platform. The current
v0.2.78 bootstrap retains the new object layout for clean builds.
The release workflow retains the stage-2 rebuild and self-rebuild fixed-point
check for future code-generator changes.

## Typed instance layout

Class instances store their declared fields by kind (a word, a byte for a
bool, two words for a string, one for a reference, a boxed value otherwise)
behind a 16-byte header naming the class's descriptor, where they used to be
32-byte slots of a symbol and a boxed value. The code generator and the
runtime changed together: generated code passes a field's place (offset, kind
and tag, bit 48 set) where it used to pass its index, and a class's descriptor
(+ 2^62) where it passed its field count. The runtime that made both layouts
(for a stage-1 compiler whose seed still made the older calls) was the bridge;
this runtime makes typed instances only. A compiler from before typed
instances (v0.2.22 is one) can't build a compiler that
runs on it: its code would pass field counts, on which the runtime traps.
The pinned v0.2.78 compiler makes typed instances and builds the current
runtime directly. Earlier compilers need a historical bridge compiler.
