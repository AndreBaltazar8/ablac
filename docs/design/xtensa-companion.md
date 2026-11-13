# Optional Xtensa LLVM companion

Status: phases 1–2 merged at dffc60aa; phase 3 merged at 4b944cfc; phase 4 published-cohort consumer gates pass, 2026-11-06.
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

The packaged native installer is `bin/abla-install-xtensa`. The command
is explicit, for example:

```sh
/path/to/abla-toolchain/bin/abla-install-xtensa --version 23.1.3-1
```

The native command limits compressed archives to 512 MiB and unpacked contents
to 1 GiB, using a private spool and two validation passes before publication.

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
validation or installation fails. Network access is needed for downloads; offline
archives require none. HTTP proxies are not supported; use `--archive` with a
file downloaded by other means when a proxy is needed.

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
streaming in the native implementation. It never trusts an
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
   unchanged. The native install command and offline path are documented.
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


## Phase 3 implementation and validation

The compiler resolves a target-local cohort before cache lookup and retains that
same immutable selection through optimization and code generation. Absolute opt
and llc paths, manifest bytes, helper/library file identities, CPU and feature
settings enter the cache identity. Non-Xtensa tool selection is unchanged. The
Darwin virtual `/proc/self/exe` readlink correction is a separate commit; it uses
the adapter's existing recorded-image validation.

`ABLA_XTENSA_FEATURES` is an explicit comma-separated `+name,-name` override,
appended after CPU defaults. Malformed syntax is `E_XTENSA_FEATURES`; LLVM owns
feature vocabulary. The QEMU uint256 test uses `-mul32high`, because its CPU
lacks that instruction. No PATH wrapper carries these settings implicitly.

### Density, literal alignment and object identity

The pinned backend does not select all SDK density forms: explicit `+density`
leaves the same 5,211-byte gap across 199 firmware sections. The isolated
`src/xtensa_assembly.ab` stage mirrors the frozen SDK script, SHA-256
`a2fd95380faf9c54d500cfed1795cad53c557fabd031df31c008e324db2a10c3`.
Its offline test uses the real firmware assembly and operand edges, requires
exact text, preserves verbatim regions, and covers density and unwind options.
Espressif's Python SDK script is used only as this test's oracle. The production stage is compiled Abla, followed
by the same selected llc's integrated assembler; no objcopy or GNU tool lookup.

Freestanding functions are `nounwind` by default, including fast builds, so no
unwind-table stripping is needed. `ABLA_ESP_KEEP_UNWIND=1` preserves the opt-in;
unsupported integrated-assembler CFI still fails visibly. Literal sections are
aligned before object emission. LLVM 23.1.3's inline-assembly `emitLiteral` omits
the alignment that its ordinary `startLiteralSection` sets; L32R requires four
bytes. This is an emitter requirement, not arbitrary linker-script padding.

The GNU-marker inspection prints a separate copy of optimized bitcode; codegen
keeps the original, preserving its use-list order. Live boot/vector markers are
`E_XTENSA_EXTERNAL_ASSEMBLER`; GNU-as and ESP SDK orchestration stay outside the
companion. The stock-parent probe uses Ubuntu 24.04 because the published v0.2.48
**compiler** requires GLIBC_2.38. The independent companion retains its separately
verified Ubuntu 22.04/glibc 2.35 compatibility.

An early installed test exposed an extra temporary/PID `STT_FILE` symbol. The
empty module now has canonical `source_filename = "abla"`, replacing only llc's
first unnumbered `.file "abla"`; numbered DWARF directives stay intact. The offline
test also requires identical objects for two temporary input filenames.
Stage `xtensa-assembly-v3` always repairs literal placement: disabling instruction
rewriting must not put literal pools in the preceding jump-table section.

Default firmware output is **whole-object identical** to the SDK wrapper:
144,824 bytes, SHA-256
`8d09555ca807d581fa02d48ebccfe5ec88e1e584601ffb6b657a50339a7b471c`.
All 558 allocated section bodies/alignments and 2,005 normalized relocations
therefore agree.

With `ABLA_XTENSA_NARROW=0`, both objects are 150,008 bytes. Thirty bytes in three
bodies differ only in L32R immediate fields overwritten by identical
`R_XTENSA_SLOT0_OP` RELA records. The opt-out gate masks **only** those 16-bit
fields, requires every section's metadata and remaining bytes, all symbol
definitions/bindings, and all normalized relocations including addends to match.
Actual-object controls reject a changed register/opcode or RELA addend and accept
a changed relocated placeholder. Default density keeps the stricter whole-object
comparison.

The SDK and installed opt-out objects also link to byte-identical **stripped
entire ELF images**, SHA-256
`3ced584ed5bb5d36248ebcba1c88a64f4151ddd65d04ebeef8b8e47bbc0dc116`, with
ESP `15.2.0_20251204` GNU ld and the checked-in
[comparison linker script](../../tests/cases/xtensa-routing/firmware-link.ld).
That script supplies synthetic SDK symbol bindings to compare relocated bytes;
the image is not executed and is not a board image. CI has no GNU firmware
linker, so records that linked check as unavailable rather than claiming it ran.

### Frozen compiler and downstream gates

The final source tree is `28d778d34371e5326452b3378779111a93762ea6`. Stages 1,
2 and 3 are byte-identical, 8,289,520 bytes, SHA-256
`f6f265c09eb475dbe477b119c391918d5556b9edde8f1ff08c44aaee06b00604`.
The pure self-rebuild also passes its IR comparison and native child check.

- Full local suite: **329 passed, 0 failed, 214 s**, JOBS=8 on CPUs 0–7,
  ordinary 8 MiB parent stack, no nohup; load 17.30 at start and 16.67 at end.
- Non-Xtensa: eight whole objects (fib/readers native, Wasm and RISC-V,
  fast/release) and fib/readers diagnostic IR equal the frozen dffc60aa compiler.
- Frozen `abla-embedded da5a939` full `tools/check-source`: passes, peak
  **3,132,076 KiB**, 158.72 s, under the 4 GiB launcher. Its default package-import
  object has the exact SDK hash above. These are source/codegen tests, not hardware.
- NovaKind: android-plan, tool-rebuild, native-build-roots and operation-log-unit
  pass against frozen `da132731`, using a separate FIFO retained build-focus lease
  per program, released after each run. No DB/full-test lease or consumer edit.
- [Three-host installed routing](https://github.com/AndreBaltazar8/ablac/actions/runs/42289218049):
  stock parent LLVM remains unchanged, 24 objects equal Nix (two fixtures, three
  CPUs, fast/release and both density settings), poisoned PATH and warm identity
  controls pass. [Final Linux installed firmware](https://github.com/AndreBaltazar8/ablac/actions/runs/42299874099)
  also passes the 24 objects and actual firmware comparison under 4 GiB,
  peak **3,216,368 KiB**, 60.5 s. Its wide object additionally passes the final
  all-symbol and mutation checks after download.
- Regular final Linux/macOS CI:
  [42300669653](https://github.com/AndreBaltazar8/ablac/actions/runs/42300669653):
  **green**, Linux 329/329 in 801 s, plus macOS hosted paths, iOS Simulator
  smoke and the pure compiler fixed point. The Linux memory guard passed
  (its successful numeric stdout is not retained by the workflow).

GNU time peaks above are the largest single process, not summed children, and
are capacity observations, not claims of an RSS improvement. Raw results are
[final local gates](xtensa-companion-data/phase3-final-local.json),
[installed firmware](xtensa-companion-data/phase3-embedded-installed.json) and
`phase3-routing-*.json` alongside the other evidence.

### Self-emission memory attribution

The first regular CI peak, 1,651,436 KiB, exceeded the old 1,400,000 × 1.10 guard.
Master's earlier push passed that guard but did not retain its successful numeric
stdout. The [frozen paired CI matrix](https://github.com/AndreBaltazar8/ablac/actions/runs/42297453462)
therefore rebuilt dffc60aa and 13ddb261 in the same runner, at the same absolute
source path, with three alternating rounds for every source/compiler combination.
It retained exact IR hashes, GNU time samples and memory-by-phase traces.

| Source | Compiler | Median KiB | Range KiB |
| --- | --- | ---: | ---: |
| dffc60aa | dffc60aa | 1,496,012 | 1,494,332–1,498,588 |
| dffc60aa | 13ddb261 | 1,498,088 | 1,492,740–1,503,012 |
| 13ddb261 | dffc60aa | 1,551,272 | 1,547,208–1,554,384 |
| 13ddb261 | 13ddb261 | 1,548,292 | 1,543,308–1,638,804 |

Each source produces identical IR with either compiler. Added source, not running
the Xtensa route on a host build, accounts for the median change. New module parse
deltas are 323,055 bytes for assembly and 213,341 for tools; total parse-end growth
is about 0.84 MB, with 22 extra reached functions and only five extra demanded
functions beyond those. There is no embedded fixture, large table or broad generic
fan-out. Local old/new-source/compiler medians are 1,297,016/1,319,716 KiB; isolated
source additions give roughly 26 MB peak growth.

The remaining spread is collection placement: normalization crosses a collection
(about 339 → 168 MB). High runs keep another 50–60 MB **before annotations**, then
carry it into module emission. Either compiler shows this mode under contention.
No allocator or GC policy changes belong to this routing patch; the sensitivity
is recorded separately in TODO.md. The reviewed record is 1,430,000 KiB, keeping
the guard's existing 10% rule. The final local guard measured 1,312,860 KiB.

[CI samples](xtensa-companion-data/phase3-memory-ci.json),
[compressed raw phase traces](xtensa-companion-data/phase3-memory-traces.json.gz),
[local pairs](xtensa-companion-data/phase3-memory-local.json) and
[isolated source additions](xtensa-companion-data/phase3-memory-attribution.json)
retain the attribution and its limits.


## Phase 4: full consumer gate with the published cohort

After phase 3 merged at `4b944cfc`, the unmodified `abla-embedded da5a939`
`tools/check-source` passed with an owned installed-layout copy of the same
`f6f265c0…` compiler and the **published portable** `23.1.3-1` cohort.
`ABLA_XTENSA_LLVM_ROOT` was cleared, so the compiler discovered it from its actual
image. All 21 fresh Xtensa sidecars identify that published cohort. The installer
fully verified every cohort file before and after the checker and again after
the separate package-import build; the compiler image remained unchanged.

| Gate | Peak KiB | Wall seconds | Limit |
| --- | ---: | ---: | ---: |
| Full embedded source checker | 3,152,424 | 228.39 | 4 GiB |
| Separate package-import object | 3,137,848 | 45.46 | 4 GiB |

The separate object is whole-byte SDK/Nix exact: 144,824 bytes,
`8d09555ca807d581fa02d48ebccfe5ec88e1e584601ffb6b657a50339a7b471c`.
The full checker's package object has the same hash. Peaks are GNU time's largest
single process, not summed children, and are capacity checks rather than a claimed
RSS improvement. No board code was executed.

This local NixOS run used `steam-run` to provide the portable helpers' FHS loader.
The parent compiler remained linked to developer Nix LLVM; the legacy SDK's
independent llc/llvm-mc self-tests also used those developer tools. This is not a
new claim about a stock released parent: the three-host stock-parent and actual
Linux firmware proofs remain the phase 3 CI runs above.

The first attempt stopped at a host build because the inherited Nix-shell
`TMPDIR` was hidden inside the FHS environment. Its failure log is retained. The
successful attempt used a new owned temporary directory visible inside FHS; no
compiler or consumer source was changed.

Usual compiler gates and the four NovaKind programs are inherited from the exact
same source/tests/tools, as verified against `26c10687` and `4b944cfc`; they were
not repeated for this documentation-only follow-up. NovaKind's assertion counts
are 52 / 23 / 2 / 31, total 108. The runner's first three raw counters include a
PASS-summary line as well.

[Structured proof and 21 manifest identities](xtensa-companion-data/phase4-published-check-source.json),
[full checker log](xtensa-companion-data/phase4-check-source.log),
[initial FHS setup failure](xtensa-companion-data/phase4-fhs-setup-failure.log),
[pre-check verification](xtensa-companion-data/phase4-verify-before.log), and
[post-check verification](xtensa-companion-data/phase4-verify-after.log) retain
these results and their scope.
