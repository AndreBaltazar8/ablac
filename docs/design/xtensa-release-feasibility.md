# Xtensa in released toolchains: feasibility probe

Status: measurements complete, 2026-11-06. This is a proposal, not a packaging
change; the choice remains with André. Branch `probe-xtensa-portable`, based on the v0.2.48 bootstrap pin
`9b3570b4`. Normal CI, release builds, and `docs/llvm-xtensa.md` retain their
existing policy: they do not compile LLVM.

## What actually needs changing

The pinned fork is `a254932917786ca006920fcb8ec02f3c5556dd06`, matching
`nix/llvm-fork.nix`. The existing `llvm-23.1.3-xtensa-1` asset is 46,302,300 bytes
of xz-compressed Nix outputs. The fork also has a Linux `-2` release, but no Mac
assets. This probe uses the release pinned by Abla, not the unselected release.

The compiler's Xtensa path in `bootstrapExternalEmitObjectForTarget` writes
portable LLVM IR/bitcode and calls external `opt` and `llc`. It does not use the
native held-module code generator. This suggests a separate patched codegen
helper could leave the parent compiler's stock LLVM and Clang untouched. A
complete frontend/helper interoperability check is still required; LLVM-only
smoke tests do not establish it. In the pinned `optdriver.cpp`, target-machine
creation failure is a warning followed by generic analysis. Thus stock `opt`
without Xtensa may produce an object with a patched `llc`, but it does not
preserve Xtensa target-cost decisions. The conservative helper cohort includes
patched **both `opt` and `llc`**, not just `llc`.

Xtensa firmware linking remains a separate SDK dependency. The pinned fork's
`lld/ELF/Arch` has no Xtensa implementation. Shipping its LLVM tools does not
replace ESP's GNU linker, SDK, libraries or startup files. `lld` is measured as
part of the tool cohort, not claimed to gain an Xtensa linker backend.

## Reusing the existing Linux release first

[Manual CI 42193172723](https://github.com/AndreBaltazar8/ablac/actions/runs/42193172723)
took 72 seconds in its Linux job, with **no LLVM source compilation**.
[Raw dependency and size data](xtensa-release-feasibility-data/reuse-files.json)
and the [run summary](xtensa-release-feasibility-data/reuse-summary.json) are retained here. It used
Abla's cached pinned fork, copied the dependency closure of `llc`, and ran it
inside the release's digest-pinned Ubuntu 22.04 container with no Nix store
mounted.

| Component | Bytes | MiB |
| --- | ---: | ---: |
| Patched `llc` | 303,408 | 0.29 |
| `libLLVM.so.23.1` | 205,385,736 | 195.87 |
| Matching loader, libc, C++ runtime and other libraries | 9,608,088 | 9.16 |
| Complete isolated helper, including wrapper | 215,297,393 | 205.32 |
| Helper tar.gz | 71,221,586 | 67.92 |

The ordinary Ubuntu loader/libc refuses the original code. The required symbol
versions include `GLIBC_2.44`, `GLIBC_2.38`, and `GLIBC_ABI_GNU2_TLS`; this is not
merely an absolute Nix path problem: the imported `sinh` and `cosh` symbols
explicitly request `GLIBC_2.44`. Changing RPATH or statically linking the
same LLVM object files does not erase those imported libc interfaces.

Invoking the **matching bundled loader** with its private library directory
works: the existing binary emits the four assembly patterns asserted by
`tools/test-llvm-xtensa.sh` and an `EM_XTENSA` object. This is a process-isolated
helper, not permission to load a second libc into the parent compiler. The
probe deliberately uploads measurements rather than publishing the helper.

For context, the published v0.2.48 Linux toolchain tar.gz is 107,720,719 bytes.
Adding this helper alongside the current toolchain would be substantial. The
Mac archives are only 3,286,059 / 3,508,524 bytes because they currently depend
on external Homebrew LLVM; comparing those archive sizes with a bundled LLVM
without counting that dependency would be misleading.

## Source-build measurements

[Manual CI 42194401898](https://github.com/AndreBaltazar8/ablac/actions/runs/42194401898)
completed one source experiment per platform, all green:

- Linux: the same Ubuntu 22.04 image as release packaging, GCC 12, glibc 2.35.
- Apple Silicon: native `macos-15` Xcode compiler.
- Intel: native `macos-15-intel` Xcode compiler.

Each job builds Release LLVM with all normal backends plus experimental Xtensa,
shared `libLLVM`, selected codegen/tools, and LLD. Clang is not rebuilt: the
isolated-helper options retain the stock compiler/Clang installation. A complete
replacement distribution would need matching Clang too; that extra build cost
is not measured here. The probe then relinks `llc` and
`lld` against the already-built component archives. This second variant means
**static LLVM**, not a fully static operating-system executable. Linux also
statically links the C++ runtime in that variant; Mac keeps the system C++ and
system libraries. The configured Mac deployment target is 13.0, but the probe
runs on macOS 15 and does not prove execution on older Macs.

The jobs record configuration, build/relink wall and CPU time, largest-process
peak RSS (not the sum of workers), raw/stripped/gzip sizes, dynamic dependencies,
symbol versions, and assembly/object smoke results. They use at most four
compile jobs, one linker, and a 300-minute job limit. The tables below are
single cold builds on those dated runners, not repeated
timing samples. The static phases reuse the first build; their times are not
standalone LLVM build times.

### Completed platform measurements

| Host | Compile jobs | Shared build, min | Static incremental phase, s | Build CPU, min | Largest process, GiB | Whole job, min |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Linux / glibc 2.35 | 4 | 104.92 | 267.43 | 417.58 | 5.00 | 111.82 |
| macOS arm64 | 3 | 50.59 | 6.90 | 140.63 | 2.42 | 53.43 |
| macOS Intel | 4 | 99.75 | 10.74 | 310.76 | 2.99 | 104.13 |

The runners had approximately 16 GiB (Linux), 7 GiB (arm64), and 14 GiB
(Intel). Linux used GCC 12.3.0; both Macs used Xcode 16.4 / Apple Clang 17.0.0.
The Linux static phase also changed C++ runtime linkage: it regenerated
TableGen outputs and rebuilt four driver C++ files before linking. It was not
just two linker commands. Neither static phase is a second full source build.

Every platform passed shared and static patched-assembly/`EM_XTENSA` object
checks. All six source-build assemblies and the reused Linux prebuilt assembly
are byte-identical for this four-feature fixture. All source archive SHA-256s
also match. This is not a complete firmware comparison.

Both Linux variants execute in Ubuntu 22.04 with glibc 2.35; the inspected LLVM artifacts’ numeric GLIBC
symbol-version maximum is **2.34**, with no requirement for 2.44. That does not
claim a runtime test on glibc 2.34. Static Linux `llc` has no `libLLVM` or
`libstdc++` dependency, but still loads libc, libm, libgcc, zlib and the system
loader. Static Mac `llc` loads only system `libSystem`, zlib and libc++; neither
variant is a fully static system executable.

| Stripped component, MiB | Linux | macOS arm64 | macOS Intel |
| --- | ---: | ---: | ---: |
| Shared-linked `llc` | 0.17 | 0.17 | 0.15 |
| Shared `libLLVM` | 157.17 | 124.25 | 132.14 |
| Shared-linked `lld` | 6.45 | 4.36 | 4.87 |
| Static-LLVM `llc` | 142.30 | 112.86 | 119.88 |
| Static-LLVM `lld` | 149.54 | 117.56 | 125.13 |
| Complete shared cohort, unpacked | 166.88 | 131.50 | 139.97 |
| Complete shared cohort, tar.gz | 56.10 | 41.44 | 44.60 |
| Static `llc` only, individual gzip | 47.16 | 34.54 | 37.04 |
| Static `lld` only, individual gzip | 50.02 | 36.47 | 39.18 |

The shared cohort includes nine tools listed in the recorded configuration,
not Clang or the C++ runtime's external DSOs. The latter still need accounting
in an installable Linux package. Individual gzip sizes are not complete
installable archives; static `opt` is unmeasured.

[Combined raw counters and sizes](xtensa-release-feasibility-data/summary.json)
include every component, stage, job identity, symbol version and total. Separate
[Linux](xtensa-release-feasibility-data/linux/job-summary.json),
[arm64](xtensa-release-feasibility-data/macos-arm64/job-summary.json) and
[Intel](xtensa-release-feasibility-data/macos-x86_64/job-summary.json) summaries
link the retained stage/dependency evidence to the workflow jobs.

## Options for a decision

1. **Keep the present Nix/embedded-SDK route.** No new release build time or
   shipped bytes. Ordinary published toolchains still cannot emit Xtensa.
2. **Reuse the Linux fork as a private loader-isolated helper.** No new LLVM
   compilation; the prototype repack/test job took 1.2 runner-minutes. Cost:
   roughly 68 MiB gzip alongside the existing package, duplicated LLVM,
   maintained libc/C++/XML dependencies, licensing/source obligations and a
   security-update cadence for that runtime. This solves Linux only, and still
   needs full Abla/tool-routing validation. It must not replace the parent's
   libc or globally override its LLVM library.
3. **Build the fork against old libc and ship a private shared helper cohort.**
   Avoids shipping a newer libc, but keeps a second LLVM DSO unless the entire
   distribution is rebuilt consistently. Clang and other C++ LLVM clients must
   not accidentally load a different build with the same LLVM SONAME. The
   measured shared-cohort cost is 56.10 / 41.44 / 44.60 MiB gzip, with source
   jobs taking 111.82 / 53.43 / 104.13 minutes on Linux / arm64 / Intel.
4. **Ship a static-component codegen helper.** One executable can avoid a
   second runtime `libLLVM` dependency; it still uses libc, and therefore must
   be built against the chosen old libc on Linux. The source probe measures
   static `llc`/`lld` using all normal LLVM backends; a static `opt` is additional
   unmeasured cost if both tools are needed. A smaller Xtensa-only helper is a
   further possible experiment, not a size/time result from this run.

The conservative option to take forward to an integration screen is the
**old-libc/native-Mac private shared cohort**, built and published once per fork/toolchain update, fetched by
ordinary releases. It avoids vendoring a second Linux libc and preserves the
patched optimizer as well as codegen. Keep the stock parent/Clang cohort
isolated until a complete replacement build is chosen and tested. If this
payload is too large, the next useful measurement is an Xtensa-only `opt` plus
`llc` cohort; its size/time is not measured here. Static `llc` alone is not a
complete cost for the comparable optimization pipeline.

A musl-based fully static Linux helper would be a distinct build/validation
option; it cannot be inferred from a static-LLVM link. It is not measured here.
The published fork archive contains a shared library and tools, not the LLVM
component archives needed for a static relink, so that option needs a new build.
On Mac, static component libraries remain compatible with dynamic system
libraries; a fully static system executable is not Apple's supported model.

For any accepted option, publish a separately versioned, checksummed LLVM
artifact when patches/tool versions change, and let normal release jobs only
fetch it. That keeps expensive LLVM builds out of every Abla release. Delivery
can bundle the chosen cohort for out-of-box support, or use an explicitly
installed, versioned platform companion so ordinary users avoid the added
download. The companion adds installer/manifest/tool-routing work and must not
be an implicit download triggered by untrusted build code. Future
production gates include the installed launcher/tool-selection path, LLVM
version/TTI compatibility, source/assembly patch checks, real embedded objects
and the existing firmware compile-memory cap (private helpers can no longer
share an identical LLVM mapping with the parent);
the present probes are not a firmware or board qualification. The existing
Xtensa test/SDK wrapper also supplies the ESP CPU and changes PIC to static
relocation; the generic external compiler path does not yet carry those
settings. Backend availability alone is therefore not out-of-box ESP support.

A private cohort also needs explicit target-specific tool selection. The
compiler knows the triple, whereas an `opt` PATH shim may see only a bitcode
filename. It should not guess the target from bytes or globally replace the
parent/compiler/Clang LLVM. That routing is production implementation work for
after a decision; it is not part of these probes. Compilation cache keys must also
cover the selected helper executables and private-library build identity;
`--version` alone cannot distinguish patch revisions that retain 23.1.3.

## CI cost and boundaries

The first dispatched experiment was reuse-only Linux. The second is one source
build on Linux and each Mac: Linux has used its two-dispatch budget; each Mac
has used one. No automatic trigger compiles LLVM. The source dispatch has an
upper bound of 900 aggregate runner-minutes across its three 300-minute jobs;
measured successful-job total is **269.38 runner-minutes**, or **270.58**
including the reuse probe. There were no failed source jobs and no reruns. These
are candidate distribution configurations, not a one-variable ABI experiment:
host compilers and optional-library settings differ from the Nix build. Size
differences must not be attributed to old libc alone.

This repository is public. Standard GitHub-hosted public-repository compute
does not draw down included private-repository compute, but runner occupancy,
artifact storage and maintenance still matter. Probe artifacts retain only
measurements/logs for seven days, not the large LLVM build trees or binaries.

References: [LLVM CMake options](https://llvm.org/docs/CMake.html),
[LLVM distribution guidance](https://llvm.org/docs/BuildingADistribution.html),
[Apple's static-library versus static-system-executable distinction](https://developer.apple.com/library/archive/qa/qa1118/_index.html)
(archived guidance), and
[GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
