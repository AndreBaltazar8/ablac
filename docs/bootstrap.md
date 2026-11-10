# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with a checksum-pinned
native `v0.2.52` host artifact for Linux x86-64, Intel macOS, or Apple Silicon.
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
with `gh release download <tag> -p ablac-x86_64-linux` as `published`:

```sh
tools/build-self-hosted-current.sh published build/rebuilt
cmp published build/rebuilt
```

(`chmod +x` it first.) Since v0.2.28 release CI uses the default shell, whose store paths
are in the binary's RUNPATH, so `ABLA_NIX_XTENSA=0` or an edit to `shell.nix` changes those
bytes and nothing else. Releases up to v0.2.27 were built without Xtensa and cut the module
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
`tools/test-bootstrap-convergence.py` lists them. `v0.2.51`: route A starts from the checksum-pinned v0.2.51
and route B from v0.2.50, rebuilding the v0.2.51 sources (`1758d94e64b0e7f31f22107f8556fd63dc4351c6`) twice; the
default stays the v0.2.45 pair above. Adding a lineage is adding its two seed checksums and the bridge commit.

**Release step.** At each release, add a `LINEAGES` entry for the new tag (route A: the new tag's pinned seed; route B: the previous release's seed; historical: the new tag's source commit) and dispatch the workflow with `lineage=<tag>`.

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
adapter that translates the standard library's stable Linux-style syscall
contract to Darwin libc, socket, and kqueue APIs. It contains no Abla value,
allocation, evaluator, or compiler implementation.

LLVM, Clang, and the platform linker remain native toolchain dependencies.
Linux pins them through Nix, with [a prebuilt LLVM for Xtensa](llvm-xtensa.md);
macOS uses Homebrew LLVM and the system
Mach-O linker. Removing those hosted dependencies is a separate freestanding goal described in
[full-self-hosting.md](full-self-hosting.md).

## Word-zero intrinsic transition

The v0.2.14 release is the bootstrap bridge for `ablaRuntimeValueWord0`, which
v0.2.13 cannot compile. The v0.2.15 source tag pins that bridge's host binaries
and checksums. Current clean builds start directly from the checksum-pinned
v0.2.52 stable host binaries. LLVM 23 has been used since v0.2.16.

The v0.2.14 tag preserves the bridge source and its reproducible source chain
from v0.2.13 in `tools/bootstrap-word0-bridge.sh`. Release tags preserve that
history; the temporary bridge branch is no longer needed.

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
v0.2.52 bootstrap retains the new object layout for clean builds.
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
The pinned v0.2.52 compiler makes typed instances and builds the current
runtime directly. Earlier compilers need a historical bridge compiler.
