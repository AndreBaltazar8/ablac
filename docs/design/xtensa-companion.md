# Optional Xtensa LLVM companion

Status: phases 1–2 merged at dffc60aa; phase 3 routing prototype under validation, 2026-11-06.
André chose the optional, separately versioned companion after the
[feasibility measurements](xtensa-release-feasibility.md). The phases 2–3 design
below is approved; installer and compiler routing remain separate handoffs.

## Phase 1: independent manual artifact

The fork's manual workflow is
[abla-xtensa-companion.yml](https://github.com/AndreBaltazar8/llvm-project/blob/5d19168bc04c02040848300a97d65a1847c5da7b/.github/workflows/abla-xtensa-companion.yml),
not a job in ordinary Abla CI or its release workflow. Its first dry run is
[42214578962](https://github.com/AndreBaltazar8/llvm-project/actions/runs/42214578962).
Publication is disabled for this run and requires a separate review.

It builds private `opt`, `llc` and `libLLVM` for x86_64 Linux and both Macs,
with only the Xtensa backend registered. It does not build Clang or LLD. The
frozen assembly digest must equal the existing full-backend prebuilt on all
three platforms; reducing the registered target set is not permission to change
Xtensa output. Linux uses glibc 2.35 and includes private C++/GCC/zlib libraries,
not a libc or loader. Macs use Apple Clang and loader-relative private LLVM.

Each archive is named
`abla-xtensa-llvm-23.1.3-1-<platform>.tar.gz`; its root has `bin/opt`, `bin/llc`,
`lib/`, licenses and `manifest.json`. The manifest records source commit and
archive checksum, companion revision, builder commit/run, host architecture,
LLVM version and every packaged file's checksum. It carries no compiler,
SDK, Clang or firmware linker. The release has per-archive checksums and a
combined manifest. Versions and assets are never overwritten.

The dry run must establish relocation, exact frozen assembly, optimization and
object output on both Macs and on a clean Ubuntu 22.04 container. The Linux
package must work without the source build's GCC installation. Build times,
sizes and evidence are reported before any publication.

## Phase 2: explicit verified installation

Add a Python 3 installer, `tools/install-xtensa-llvm.py`, and ship it as
`bin/abla-install-xtensa` in future toolchain packages. The documented command
is explicit, for example:

```sh
/path/to/abla-toolchain/bin/abla-install-xtensa --version 23.1.3-1
# From a source checkout, against an existing toolchain:
python3 tools/install-xtensa-llvm.py --toolchain-root /path/to/abla-toolchain \
    --version 23.1.3-1
```

No `ablac build`, analysis, staging or compiler startup downloads anything.
There is no PATH modification or replacement of `bin/opt`, `bin/llc`, Clang,
the parent's LLVM library or SDK tools. Updating setup-abla is optional follow-up;
the documented command suffices for this task.

A checked-in catalog pins the exact release URL and archive SHA-256 for each
supported host and companion revision. It is filled only after phase 1 is
published. Unknown versions and architectures are errors, not `latest`
lookups. An optional `--archive` accepts an offline copy with the same pinned
checksum. A later artifact revision needs an explicit catalog/installer update,
not a new parent compiler binary or a helper download during a build.

The installer checks archive checksum before extraction, then schema, platform,
LLVM compatibility and all manifest file hashes. Archives permit regular files
and directories only, with bounded count and unpacked size; absolute paths,
traversal, links and device entries are refused. Extraction goes into a private
staging directory under the destination filesystem. A final rename installs
`lib/abla/xtensa-llvm/<version>/`; an atomically replaced `current` symlink
selects it. Compiler invocations resolve that selection to the immutable version
directory once, so an activation between opt and llc cannot mix cohorts. Existing matching versions are idempotent; existing different bytes
are refused rather than overwritten. The previous selection remains usable if
validation or installation fails. Python 3 and network access are requirements
of this explicit installer, not of compiled programs.

## Phase 3: target-specific resolution and code generation

Resolve once per build invocation in `src/toolchain.ab`, keyed by the LLVM
triple's architecture. Only `xtensa` uses the companion. Host, Wasm, RISC-V and
all other target paths keep their present tool selection. In particular, no
private DSO is loaded into the parent compiler.

For installed toolchains, derive the toolchain root from the actual compiler
image and select `lib/abla/xtensa-llvm/current`. The explicit environment
override `ABLA_XTENSA_LLVM_ROOT` selects a manifested cohort for source builds,
testing and installations outside that root. A missing, incomplete,
incompatible or wrong-host cohort is a typed error before optimization. The
missing-companion diagnostic includes the explicit install command. Never
fall back to a random `opt` or `llc` on PATH.

`shell.nix` should expose its already-selected patched LLVM through a small
Nix-generated cohort manifest and `ABLA_XTENSA_LLVM_ROOT`. The manifest's tool
and library paths can refer to immutable store outputs. This keeps developer
Nix builds working without installing the portable companion or building LLVM
again. A non-Xtensa Nix shell exports no such root. The manifest scheme must
cover both this development cohort and the portable archive; it must not
silently accept unmanifested executables as a released companion.

Both external optimization and object emission use absolute selected paths,
including `bootstrapExternalEmitObjectForTarget` and its cache identity. Preserve
the existing pass lists. Select the CPU settings currently supplied by the ESP
wrapper: `ABLA_ESP_CPU=esp32` (default), `esp32s2`, or `esp32s3`, with S3 mapped
to `esp32` plus `-dfpaccel` because this pinned fork has no `esp32s3` CPU. Refuse
an unknown or RISC-V CPU paired with an Xtensa triple. Pass the resolved CPU
and features to both opt's target analysis and llc. Xtensa always uses static
relocations, including `--fast`, and retains function/data sections.

Preserve the wrapper's explicit direct-call and narrow-branch options (default
on), and text-section-literal option (default off). Include every resolved CPU,
feature and codegen option in the target cache identity. This proposal reuses
the existing ESP environment knobs rather than adding a new target-description
API. Multi-CPU invocations remain separate commands, as with today's wrapper.

The cache key includes the selected manifest bytes (source/revision and file
hashes), paths and current size/revision of both helpers and all private shared
libraries, and the resolved target options. A library-only replacement must
invalidate cached objects even if `opt --version` is unchanged. Do not read a
100+ MiB DSO into an Abla string to key each build: installation verifies the
content hashes, and runtime file identities catch ordinary replacement. Nix
store paths additionally identify immutable dependency closures. Missing or
invalid files are errors even on a warm object-cache hit.

ESP's GNU assembler/linker and SDK remain framework dependencies. Existing
boot/vector assembly that relies on GNU layout directives is not made portable
by shipping LLVM. Do not silently switch those sequences to LLVM's assembler;
retain their framework-controlled assembly step. The initial compiler gates
cover ordinary LLVM-generated Xtensa objects, not an unmeasured board image.
If bypassing the old PATH wrapper exposes a boot/vector assembly dependency in
the requested gates, report it before expanding the compiler API.

## Full integrity checks and retained limitations

The catalog also pins the per-platform manifest hash. Full file-content checks
run before install/activation and on every explicit `abla-install-xtensa
--verify` call, even when sizes and mtimes have not changed. Verification is
streaming in Python and uses its standard library only. It never trusts an
unchanged size/mtime as a substitute for the manifest's content hashes. The
same-size/same-mtime DSO mutation regression must fail this check; changing the
manifest to match the damaged DSO must fail its catalog-pinned manifest hash.

Normal compiler resolution reads the manifest and checks schema, selected host,
version and file identities before cache lookup. It does not stream every DSO
on every build. Thus local modifications that deliberately preserve both size
and mtime are caught at the next full integrity check, rather than guaranteed
to be detected by the fast identity check. Installed files are read-only and
the explicit verify command is documented; this is not a sandbox against a
local owner replacing compiler tools. Nix development manifests refer to
immutable store paths. The final implementation must name these exact check
points in the user documentation and tests.

The existing Xtensa 128–255-byte scavenging-slot issue is unchanged: its newer
patch is held for a separate hardware gate. This companion starts with the
currently pinned seven-patch commit, not the held `llvm-23.1.3-xtensa-2` source.
Do not silently change the source pin to include that independent fix.

## Gates and handoffs

1. Phase 1: dry-run evidence and sizes/times on all three hosts, then review
   before publishing the companion. No automatic LLVM source builds enter
   normal CI or Abla releases.
2. Phase 2: explicit network/offline install, checksum/tamper/traversal controls,
   relocation, idempotence and atomic selection; original toolchain files
   unchanged. The install command is documented with its Python requirement.
3. Phase 3: a toolchain with stock parent LLVM and Clang, no patched tools on
   PATH, emits the existing fixtures through the installed companion. Compare
   objects byte-for-byte with the Nix cohort using the same resolved target
   settings. Poison PATH to prove routing; test missing/cohort/version errors
   and cache invalidation for CPU, revision, helper and DSO replacements.
4. Run abla-embedded's check-source on a frozen checkout, and separately compile
   its package-import fixture to Xtensa under the 4 GiB launcher cap, reporting
   peak RSS. check-source includes host IR/native tests; it is not itself proof
   that every firmware object passed through the companion.
5. Usual compiler gates: stages 2/3 fixed point, pure self-rebuild, full suite,
   macOS CI and the NovaKind tool checks for build-path changes. Source and
   stdlib changes pass fmt. Coordinate local work around the quiet window and
   use at most four CPUs outside the authorized full-suite gate.


## First dry run (2026-11-06)

These are **unpublished dry-run artifacts**, not installer pins. The source
[run 42214578962](https://github.com/AndreBaltazar8/llvm-project/actions/runs/42214578962)
built all three cohorts from the pinned fork. Its Linux job failed after the
build because the validation code truncated a deliberately spaced `ldd` path.
The retained loader trace shows the private libraries loaded from that full
path. The fix is branch commit
[9b2956f](https://github.com/AndreBaltazar8/llvm-project/commit/9b2956fed2e8c1ca285a0825d74475aa4f3db355).

The verification-only
[follow-up 42221924474](https://github.com/AndreBaltazar8/llvm-project/actions/runs/42221924474)
uses the same retained archives on fresh hosts without rebuilding LLVM. All three fresh-host checks have passed, including clean Ubuntu 22.04 on
glibc 2.35. The [follow-up run metadata](xtensa-companion-data/verification-run.json)
records the repair independently; the original failed run remains part of the
evidence. Publication is disabled.

| Host | Archive bytes (MiB) | Unpacked MiB | Whole source job, min | Build/package, min |
| --- | ---: | ---: | ---: | ---: |
| Linux x86_64 | 30,720,929 (29.30) | 69.00 | 48.90 | not retained |
| macOS arm64 | 20,341,870 (19.40) | 44.53 | 25.22 | 23.88 |
| macOS Intel | 22,072,828 (21.05) | 48.40 | 69.08 | 65.62 |

Linux CPU/peak/build-summary data were not written before the old verifier
failed; they are not inferred. The repaired producer saves these before its
post-build checks. Whole-job time above includes checkout, dependencies and
source fetch; the separate build/package metric starts at CMake configuration.

All three archives produce these exact hashes, also compared byte-for-byte
with fresh Nix full-backend output on the same fixture:

```text
assembly:         b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791
direct object:    528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1
optimized object: 8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672
```

The repaired Linux follow-up runs on **glibc 2.35**, with no GCC installation
from the source build, and with a parent-style library search path set. Its
private LLVM/C++/GCC/zlib dependencies still load from the relocated archive.
Mach-O inspection of the arm64 archive finds only loader-relative private
LLVM paths and system libraries, with no absolute build-directory RPATH.

Raw [package sizes and dry hashes](xtensa-companion-data/dry-run-packages.json),
[source run metadata](xtensa-companion-data/source-run.json), per-host timing
and smoke files are retained under `xtensa-companion-data/`. This is the
LLVM-helper fixture, not the complete firmware or stock-parent compiler
interoperability gate; those remain phase 3 work.


## Installer test fixture while publication waits

Before publication, the production catalog remained pending until the fork
published all three archives. `tools/fixtures/xtensa-companion-unpublished.json` is explicitly marked
`UNPUBLISHED_TEST_FIXTURE`; it pins the original dry-run archives and manifests
from run 42214578962. It is never copied into a packaged toolchain. Its nested
catalog simulates accepted metadata only for the offline integration test.

The opt-in installer probe can download those retained Actions artifacts and
pass `--archive` plus an explicitly generated test catalog to the exact packaged
installer. This does not publish or activate an archive in a user's toolchain,
and does not replace the canonical catalog. The report records
`unpublishedTestFixture: true`. After publication the same probe runs without
the test-fixture input and checks the actual published catalog and downloads.

The [three-platform installer run 42242927842](https://github.com/AndreBaltazar8/ablac/actions/runs/42242927842)
passed at `90204bef`, with the explicit unpublished input. It used the published
v0.2.48 parent toolchains, relocated under a directory with spaces. The installer
left all 472 original Linux files/symlinks and all 115 files/symlinks on each
Mac unchanged (regular-file bytes/modes and symlink targets). Offline install, idempotent activation
and full verification passed. Assembly, direct object and optimized object
hashes matched the Nix digests above on every host.

Each host then flipped a byte in the **real private libLLVM**, preserving its
size and nanosecond modification time. `--verify` rejected it with a file
SHA-256 mismatch before invoking a helper. Restoring the byte, timestamp and
mode allowed a fresh verification to pass. Raw results and negative-control
messages are [retained beside the other evidence](xtensa-companion-data/unpublished-installer-run.json).
There are also 21 passing offline catalog/installer controls.

This proves the installer against the frozen dry-run cohorts, **not** against
published companion assets. The canonical catalog is now filled from the live
release; the corresponding live-input probe is recorded separately below.
Compiler routing is still a separate phase.


## Publication attempt and permission blocker

[Run 42228156011](https://github.com/AndreBaltazar8/llvm-project/actions/runs/42228156011),
at builder `9b2956f`, acquired ARM on attempt 4 after three requests ended before
any step with hosted-runner capacity errors. Only one of the four subsequently
authorized hourly retries was needed. Linux and Intel successful builds were
reused, not rebuilt. All three source builds and the clean Ubuntu 22.04 check
then passed. Their assembly and direct/optimized object hashes still match
Nix exactly. **All three archive byte hashes differ from the dry run**, as
allowed: the builder/run metadata and packaged README differ. They were initially
unpublished build artifacts; the owner subsequently published those exact bytes,
as verified separately below. The
[package comparison](xtensa-companion-data/publication-build-packages.json)
records exact sizes and hashes.

Release creation failed HTTP 403, `Resource not accessible by integration`,
despite the job log showing `GITHUB_TOKEN` Contents: write. That initial automatic attempt created no release or tag. The stopped retry controller deliberately does not retry this
non-capacity failure, and no hourly retry timer remains active.

`source-commit.txt` is generated from the identical `sourceCommit` in all three
retained manifests: exactly `a254932917786ca006920fcb8ec02f3c5556dd06`, without
a newline. That file was not retained separately, but its exact content follows
from the publisher code and verified manifests. The target is reachable from
branch `abla/xtensa-23.1.3`, whose head `e4da75d4` is one commit ahead. Relative
to its parent `0a4c02e4`, `a2549329` changes only
`llvm/lib/Target/Xtensa/XtensaFrameLowering.cpp`; it does **not** change workflows.
Its history diverges from current fork main and does differ in workflow files.
The broader tag/workflow-permission explanation is plausible, not established.
[Commit evidence](xtensa-companion-data/publish-source-commit.json) and
[branch reachability](xtensa-companion-data/publish-source-branch-reachability.json)
are retained.

The owner pre-created the exact `a2549329` tag over SSH and reran only the
publisher. Release creation still returned the same HTTP 403. Thus a missing tag
was not sufficient to explain or fix this failure. The owner then ran the exact
workflow index script against the verified run artifacts, checked every assertion,
created a draft release with the owner token, and undrafted it with
`--latest=false`. The fork's latest release stayed `llvm-23.1.3-xtensa-2`.
The workflow's release-creation step needs explicitly approved owner credentials
or this manual step; the repository does not contain such a token.

The tag still names the exact built source. Changing it to `e4da75d4` would
misstate the artifacts' source: that extra scavenging fix is under a separate
gate. Phase 3 still waits for the phase-2 handoff.


## Published revision 1 verification

The [published release](https://github.com/AndreBaltazar8/llvm-project/releases/tag/abla-xtensa-llvm-23.1.3-1)
was downloaded again independently. All three per-archive `.sha256` files and all
four `SHA256SUMS` entries pass. The combined index SHA-256 is
`3204023d7dac2f3a6044efd925e4fe7c61f7fdd10753879a7d4e39bf46d6f4a8`.
The tag points to `a254932917786ca006920fcb8ec02f3c5556dd06`. Each published
archive is byte-identical to its verified publish-run archive, linking it to
the matching Nix code-generation hashes above. All differ from the original
dry-run archive bytes.

The canonical `tools/xtensa-companions.json` now pins those published archive
SHA-256 values and each raw per-archive manifest hash. The live metadata check
passes for all three hosts. A copied catalog with one intentionally wrong pin
fails with `published .sha256 mismatch`; it is never used for installation.
The [published package comparison](xtensa-companion-data/published-packages.json),
[release metadata](xtensa-companion-data/published-release.json),
[tag metadata](xtensa-companion-data/published-tag.json), published checksum
files and the negative-control message are retained alongside the other evidence.


## Live installer verification

[Run 42269233930](https://github.com/AndreBaltazar8/ablac/actions/runs/42269233930)
passed on `1327720e` using the canonical catalog and public release URLs, with
no unpublished input or offline archive override. It uses the same packaging
helper as the Linux and Mac toolchain packagers.

| Host | Original parent entries preserved | Nix assembly/direct/optimized object hashes | Real DSO tamper rejected and restored |
| --- | ---: | --- | --- |
| x86_64 Linux | 472 | all three exact | yes |
| arm64 macOS | 115 | all three exact | yes |
| x86_64 macOS | 115 | all three exact | yes |

Regular-file bytes and modes, and symlink targets, are unchanged in the parent
v0.2.48 toolchains. Installation into a relocated path with spaces, idempotent
selection and explicit verification pass. On each host a byte in the real
private libLLVM was changed while preserving file size and nanosecond mtime;
verification rejected it by its pinned hash before execution. Restoring the
original byte, timestamp and mode allowed verification to pass again. The
report explicitly records `unpublishedTestFixture: false`.

[Raw run metadata](xtensa-companion-data/published-installer-run.json), per-host
result JSON and negative messages are retained. The 21 offline controls,
actionlint, shellcheck and touched doc-example filter also pass. No compiler or
stdlib source changed, and no claim is made that the current compiler routes
Xtensa through this cohort: that is the separately reviewed phase 3.


## Phase 3 validation in progress

The prototype on `feat-xtensa-routing` starts at `dffc60aa`. Selection is an
immutable value captured by the emitter and explicitly passed to the native
cache identity; it is not a process-global context. Target-local tool/CPU/flag
controls pass using real LLVM behind instrumented wrappers, including poisoned
PATH, helper/library/manifest changes, warm-cache missing-file refusals, and a
`current` link switched during the version check. Live GNU layout markers refuse;
markers eliminated by optimization pass.

Before density legalization, local stages 2 and 3 were byte-identical with SHA-256
`d482834dc5e6c5ad607b061b0b50707c9cf097fbdc0fede0c700096f873cfba7`.
The two compiler builds peaked at 1,375,376 and 1,380,088 KiB with four CPUs.
These are verification samples, not a wall-time performance claim.

The stale embedded checkout `7e9ce53` fails with the same 71 semantic error
headings under released v0.2.48, exact `dffc60aa` and the prototype; its first
error is `region.noescape-effect:nvs_flash_init`. The gate uses the previously
approved `da5a939` checkout instead. No embedded sources are modified. The real
firmware peak, check-source, stock-parent Linux/Mac CI, host-output comparisons
and downstream compatibility gates are still pending at this prototype commit.

### Firmware parity and the compiled assembly stage

The existing SDK wrapper does more than choose a CPU. It defaults
`ABLA_XTENSA_NARROW=1` and applies a code-density transform before assembly.
Selecting `esp32` already enables density; adding `+density` produces an
identical direct object, so it does not recover those instruction selections.
On frozen embedded `da5a939` package-import, bypassing that transform added
5,211 bytes across 199 of 558 allocatable sections. Disabling the wrapper's
transform made its allocatable bodies match direct llc on the same bitcode.

The companion route therefore has an isolated, compiled Abla legalization
stage in `src/xtensa_assembly.ab`. Its mappings, verbatim regions and literal
placement are checked by exact text differential against the frozen SDK script
(SHA-256 `a2fd95380faf9c54d500cfed1795cad53c557fabd031df31c008e324db2a10c3`).
The offline test includes operand boundaries and the complete firmware assembly.
Python is used only for this test, not by the build stage. `ABLA_XTENSA_NARROW=0`
disables instruction narrowing; both choices and the stage identity enter the
cache key and the successful CLI build's `<output>.xtensa-tools.json` manifest.

The selected private llc emits assembly. After legalization, that text becomes
module-level assembly in an otherwise empty LLVM module, assembled by the same
absolute private llc. No `llvm-mc`, assembler or Python is discovered on PATH.
An assembly failure is an `E_XTENSA_ASSEMBLY` failure, never accepted as an object.
This is ordinary Abla codegen, not the SDK's GNU-as boot/vector layout pipeline.

Freestanding Xtensa defaults to `nounwind`, including fast builds, so unwind
tables are not emitted. `ABLA_ESP_KEEP_UNWIND=1` preserves the existing opt-in
contract; LLVM's integrated assembler can reject unsupported CFI forms and that
failure stays visible. Literal sections are aligned by assembly declarations
before object emission. This repairs LLVM 23.1.3's inline-assembly `emitLiteral`
path, which omits the alignment used by `startLiteralSection`. L32R requires the
four-byte alignment; it is not an arbitrary linker-script convention. No object
section, unwind bytes or loadable content is patched with objcopy.

Inspection of live GNU layout markers renders a separate copy of the optimized
bitcode. Code generation keeps the original bitcode: printing and reparsing it
otherwise changed use-list ordering and five equal-sized instruction bodies.
The scratch legalized object matches all 558 allocatable bodies and their
alignments, with no new sections; its extra 36 bytes are non-loadable metadata.
Final compiler/firmware and installed-cohort gates remain in progress.

The stock-parent Linux probe uses Ubuntu 24.04: the published v0.2.48 compiler
itself needs GLIBC_2.38. This does not change the companion's separately proven
clean Ubuntu 22.04/glibc 2.35 compatibility.

Final compiled-stage stages 2 and 3 are byte-identical with SHA-256
`2a2735f29a590a44ef6756c09bd81fa6643e7846b6635c0f4da0889f0873998e`.
The frozen `da5a939` firmware build passes the 4 GiB launcher, peaking at
3,403,912 KiB. Its object is 144,892 bytes against 144,824 for the SDK wrapper:
all 558 allocatable section bodies and every section alignment match, with
no added sections. The remaining 68 bytes are non-loadable metadata. This
single peak is a capacity check, not evidence of an RSS improvement.
