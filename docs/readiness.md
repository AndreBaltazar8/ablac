# Internal production readiness

Internal only. Regenerate with `tools/readiness.sh`; this is an evidence inventory, not a production approval or stability policy.

Source revision: `d30fc0d8300f20f9f549ac93793ad73384fa76fc`. Source counts describe this working tree. Saved results may describe older revisions; only explicitly recorded revisions identify what was tested.

## Stability

Evidence: `saved evidence/releases.json`; SHA-256 `283ccd299a676f032afab986eee60981e63ada32e20e9c60688ab479254de42d`.

| Release | Migration bullets |
|---|---:|
| v0.2.67 | 5 |
| v0.2.66 | 3 |
| v0.2.65 | 5 |
| v0.2.64 | 3 |
| v0.2.63 | 10 |
| v0.2.62 | 12 |
| v0.2.61 | Missing |
| v0.2.60 | Missing |
| v0.2.59 | Missing |
| v0.2.58 | Missing |
| v0.2.57 | Missing |
| v0.2.56 | Missing |
| v0.2.55 | Missing |
| v0.2.54 | Missing |
| v0.2.53 | Missing |
| v0.2.52 | Missing |
| v0.2.51 | Missing |
| v0.2.50 | Missing |
| v0.2.49 | Missing |
| v0.2.48 | Missing |
| v0.2.47 | Missing |
| v0.2.46 | Missing |
| v0.2.45 | Missing |
| v0.2.44 | Missing |
| v0.2.42 | Missing |
| v0.2.41 | Missing |
| v0.2.39 | Missing |
| v0.2.37 | Missing |
| v0.2.36 | Missing |
| v0.2.35 | Missing |
| v0.2.34 | Missing |
| v0.2.32 | Missing |
| v0.2.31 | Missing |
| v0.2.30 | Missing |
| v0.2.29 | Missing |
| v0.2.28 | Missing |
| v0.2.27 | Missing |
| v0.2.26 | Missing |
| v0.2.25 | Missing |
| v0.2.24 | Missing |
| v0.2.23 | Missing |
| v0.2.22 | Missing |
| v0.2.21 | Missing |
| v0.2.20 | Missing |
| v0.2.19 | Missing |
| v0.2.18 | Missing |
| v0.2.17 | Missing |
| v0.2.16 | Missing |
| v0.2.15 | Missing |
| v0.2.13 | Missing |
| v0.2.12 | Missing |
| v0.2.11 | Missing |
| v0.2.10 | Missing |
| v0.2.7 | Missing |
| v0.2.6 | Missing |
| v0.2.5 | Missing |
| v0.2.4 | Missing |
| v0.2.3 | Missing |
| v0.2.2 | Missing |
| v0.2.1 | Missing |
| v0.2.0 | Missing |
| v0.1.0 | Missing |

Counts are top-level migration bullets, a proxy for breaking changes. A present section with prose but no bullets counts zero bullets; it does not prove zero breaks. Releases without a migration section are missing.

## Correctness

Suite inventory: **625 recipe commands**, **448 case directories**. These are source inventory counts, not passing checks.

Missing: completed gate, stage2 == stage3 result and suite pass/fail totals.

### Fuzz campaigns and disagreements

Harness: `tools/fuzz/run`; `tools/test-fuzz-abla.sh` checks the harness and planted disagreement controls. Scratch seed directories are not campaign results.

Missing: structured campaign totals and disagreement counts (fuzz.json).

Evidence: `/home/andre/agents-memory/abla/ablac-differential-fuzzer.md`; SHA-256 `e01c4d2d7c34bab2272f8fcaadfd697d64f8d09d6e837c79ef336fcd8687ab7b`.

Historical campaign narrative, final 24 lines (may be stale; no aggregate inferred; consult the full source above):

      seeds; use 100000 up (used so far: 100000–100968; 100841–100968 = ownership families --focus resource_drop/ownership_lifetime/default_owner/fresh_select, 32 seeds x 24 checks each, on the #736 follow-up evaluator fix, all clean).
    - Oracles: JSON/YAML expectations come from tools/fuzz/oracle.ab (own value tree + json.dumps-compatible writer), never
      abla/json; tests/cases/fuzz-oracle/json.jsonl (436 Python-computed cases) pins it in --selftest (it caught that
      ensure_ascii escapes DEL). Drop-order oracles computed in the generator as before.
    - Minimiser now iterates to a fixpoint (Python's single pass kept lines later removable lines read).
    - Suite step tools/test-fuzz-abla.sh (~70–100 s on 4 CPUs): self-tests, --control-minimise (planted Wasm-only
      difference), --control-oracle f1,...,f6 (wrong expectations reported in all six modes), one seed per campaign.
    - Abla gotchas met: mutating through an alias of a field (`val s = this.s; s[0] = ...`) or a for-variable is a borrow
      error: index directly or use `var` parameters; a return type cannot start a continuation line; compile-time code
      may not read the clock (compile.effect-denied); wasm build requests need root-relative paths.

    ## FB/FC comparison (#648, ablac-a5)

    FB `b0b10442d` stage 2, matching sysroot: default seeds 101100–101115 ×24 (six modes), 101116–101123 ×24 with `--panics` (six modes plus eight native/Wasm panic cases), and 101124–101131 ×24 with `--hosted-tasks` (four modes). All 32 seeds agree, zero disagree, 768 generated checks and eight additional panic cases, exit 0 for each shard. The gate-produced stage-2 payload SHA-256 `5c9d327197b8b3200d930db48d0bf51d2caa3264d844020a3951bcb3450d2047` matched before/after every hold. Ignored worktree `.claude/worktrees/cx10-fuzz648-fb`; durable logs, commands and actual unit statuses in `evidence/fuzz648-fb-fc/fb/`. Results sent to ablac-74 and ablac-47. Replay the same seeds on landed FC. Its planned `a365f072e` was rebased to `2ece0285c` with only a Windows LLVM packaging-script delta at the time of the FB result.

    FC landed at `f7b0215ed`. Built an exact stage 2 with the v0.2.66 seed in `.claude/worktrees/cx10-fuzz648-fc`; stage 2 and stage 3 emitted identical bitcode. Replay on the matching sysroot used the same fuzzer tree, seed ranges, check counts and flags as FB. Again all 32 seeds agreed, zero disagreed, all 768 generated checks and eight additional panic cases passed, and each shard exited 0. Stage-2 payload SHA-256 `811dc1ea29a46b118b6d1630c70277d857d9578f3e36312a9dedd105f7a657a7` matched before/after each hold. Durable logs, commands and actual exit statuses are in `evidence/fuzz648-fb-fc/fc/`. Reported to ablac-74 and ablac-47. Neither campaign changed tracked files. #648 remains the standing fuzzer item.

    ## WASI and RISC-V comparison arms (#648, ablac-a5)

    Opt in with `ABLA_FUZZ_WASI=1` (Wasmtime, override `ABLA_WASMTIME`) and `ABLA_FUZZ_RISCV64=1` (QEMU user-mode, override `ABLA_QEMU_RISCV64`). Optional arms run the same generated program as native fast/release, with a named skip if the compiler or runtime is unavailable. The ordinary corpus compares portable values and exact stdout and status, without filtering pointer addresses. The suite uses a synthetic address round-trip to verify 32/64-bit pointer expectations independently. WASI built-in panics lose guest diagnostic text by design in the backend; require exactly the Wasmtime unreachable trap, exit 134, and stdout `before\n`. Explicit `panic()` writes its own diagnostic and invokes proc_exit 101. These checks are separate from ordinary result comparison. WASI skips hosted tasks and both cross targets skip the host libc campaign.

    Baseline `79833ecf5` (stage 2 `d5acdac2a6564da7ede960ae03386d1b0a1569e8fe2548badc48b4dfbe4b12bb`) passes seeds 101200–101215 and 101216–101224 with `--panics`: 25 seeds ×24, all six reference modes plus WASI, nine additional panic shapes, zero unanticipated disagreements, two exits 0. RISC-V unavailable on that compiler. Saved under `evidence/fuzz648-targets/79833ecf5/`. The branch `cx10-fuzz-targets-fh` at `c83397c7c` on FH `6c3c9abff` replays the same seeds with QEMU and Wasmtime plus hosted seeds 101225–101228. Qualification logs under `.claude/worktrees/cx10-fuzz-targets-fh/build/campaign/`; systemd unit `ablac-cx10-fuzz-targets-fh`. Still awaiting completion.

    FH qualification complete. A copied gate payload did not reproduce identical bitcode in the new checkout, so `c83397c7c` on `6c3c9abff` was fully bootstrapped from the v0.2.66 pin. Stage 2 and stage 3 bitcode match. Exact stage-2 payload `252b9b216501e63a150bee72ee0c133f09ad2eff6b06abff3d311e43573c9192` matched before/after each hold. The 25 portable seeds agreed in all eight modes (600 checks, all nine panic shapes) and the four hosted seeds agreed in five modes (96 checks, RISC-V included and WASI explicitly skipped). All shards exit 0, no compiler disagreement. Focused suite 7/0, including five guards, test-wasm-wasi and test-fuzz-abla with both target controls. The standalone RISC-V test is CI-only and was not part of this filter. Saved commands, logs and exit statuses under `evidence/fuzz648-targets/6c3c9abff/`. Handoff for FK is `cx10-fuzz-targets-fk` at `074ec34f1` on `94f20765c`. The tooling files match the tested FH branch, and the integrated suite preserves 7e's build-path byte-difference control. The final replay received a shell syntax and diff check.

### Open wrong-code bug candidates

Heuristic scan of open TODO list items for wrong code, miscompiles, wrong results, or mode disagreements. Candidate titles and source lines follow; inspect the full items to distinguish resolved findings inside an open tracking item. This is not a bug count; unlabelled bugs can be missed. Completed items are excluded.

    TODO.md:446 - [ ] **`tools/fuzz-differential` findings** (2026-11-08; branch `fuzz-differential`). The fuzzer builds
    TODO.md:888 - [ ] **`--fast` builds are read on every target; the Xtensa one is partly unplaced.** `tools/test-ct.sh` builds the fixture
    TODO.md:3344 - [ ] **macOS still has the instcombine fdiv miscompile (owner TBD).** The macOS compiler's in-process libLLVM and the clang of its LTO prepare step are Homebrew's

## Security

Security mechanisms and limits: `docs/reliability-roadmap.md`, `docs/constant-time.md`, `docs/ownership.md`. Declared tests are inventory, not security audit results:

    tools/test-bignum-secret.sh
    tools/test-compile-effects.sh
    tools/test-compile-tls.sh
    tools/test-emutls.sh
    tools/test-fuzz-parsers.sh
    tools/test-http-tls-deadline.sh
    tools/test-subparser-generated-adapter.sh
    tools/test-subparser-named-arguments.sh
    tools/test-subparser-raw-isolation.sh
    tools/test-subparser-site-key.sh
    tools/test-tls-accept-deadline.sh
    tools/test-tls-binding.sh
    tools/test-tls-bogo.sh
    tools/test-tls-chains.sh
    tools/test-tls-client-ca.sh
    tools/test-tls-diff.sh
    tools/test-tls-ecdsa-curve.sh
    tools/test-tls-faults.sh
    tools/test-tls-fuzz.sh
    tools/test-tls-handles.sh
    tools/test-tls-ocsp.sh
    tools/test-tls-pure-interop.sh
    tools/test-tls-pure.sh
    tools/test-tls-resume-review.sh
    tools/test-tls-session.sh
    tools/test-tls-trust-cache.sh
    tools/test-tls-trust-env.sh
    tools/test-tls-unix.sh
    tools/test-typed-subparser-inspection.sh
    tools/test-websocket-tls-server.sh
    tools/test-workflow-security.sh
    tools/test-x509.sh

Missing: independent audit, vulnerability inventory and security fuzz campaign evidence (security.md).

## Performance

| Benchmark | Abla | C | Rust | Go | Zig |
|---|---|---|---|---|---|
| Runtime / RSS / compile time / size | Missing | Missing | Missing | Missing | Missing | Missing |

Awaiting `tools/bench-languages` measurements. Archive its report as `benchmarks.md` with revision, toolchains and host metadata.

## Platforms

Missing: published asset snapshot for the source revision (release.json).

Missing: saved CI run outcomes for the source revision.

Coverage tiers recorded in the source checkout’s platform matrix.

| Platform | Tier | Compiler host evidence | Program target evidence |
|---|---|---|---|
| Linux x86-64 | T1 | Native suite, dynamic self-build and static compiler fixpoint | Native executables; default libc-free link with explicit dependency exceptions |
| Linux AArch64 | T2 | Cross-built static compiler executed under qemu; no native host full-suite gate | Static programs cross-built and selected programs executed under qemu |
| macOS arm64 | T2 | Native compiler, selected host checks and self-rebuild | Native Mach-O; selected runtime paths, iOS Simulator integration |
| macOS Intel | T2 | Native compiler and selected host checks; release self-rebuild | Native Mach-O; selected runtime paths |
| Android arm64 | T2 | No Android-hosted compiler gate | Shared libraries checked against NDK; exports executed by bionic under qemu |
| iOS arm64 and Simulator | T2 Simulator / T3 device | No iOS-hosted compiler gate | Device archive/XCFramework checks; selected exported calls run on arm64 Simulator |
| WebAssembly hosted | T2 | No Wasm-hosted compiler gate | Release/development modules execute with the `abla_host` ABI under Node |
| WebAssembly hostless | T2 | No Wasm-hosted compiler gate | Import-free runtime fixtures and differential programs execute under Node |
| Xtensa / ESP32 | T3 | No compiler hosted on the microcontroller | Object/assembly checks and optional companion integration; no required board run |
| Windows x86-64 | T2 | The packaged `ablac.exe` is exercised on `windows-latest` in release runs (`windows: with` or `only`), not in push CI; no Windows self-rebuild or suite shard yet | Cross-built on Linux; selected programs run natively on `windows-latest` in CI (the freestanding exit-status program and the hosted crash program with its symbolized backtrace); the hosted file, process, socket and thread programs run under Wine on Linux only |
| Windows ARM64 | T2 | No Windows-hosted compiler | Hosted programs cross-built on Linux and run natively on `windows-11-arm` in CI |

Declared workflow jobs and matrices, extracted from `.github/workflows`. This configuration does not establish passing CI or hardware coverage; conditional/manual jobs remain conditional/manual.

### `.github/workflows/bootstrap-convergence.yml`

      route:
        name: Fresh Linux route ${{ matrix.route }}
        runs-on: ubuntu-24.04
          matrix:
            route: [a, b]
      compare:
        name: Compare raw IR and bootstrap provenance
        if: ${{ always() && !cancelled() }}
        runs-on: ubuntu-24.04

### `.github/workflows/ci.yml`

      linux:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control }}
        name: Linux suite (shard ${{ matrix.shard }}/2)
          matrix:
            shard: [1, 2]
        runs-on: ubuntu-24.04
      windows-cross:
        if: ${{ !inputs.xtensa_compiler_memory_probe && !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control }}
        name: Windows programs, cross-built on Linux
        runs-on: ubuntu-24.04
      windows-run:
        name: Windows programs, run on Windows
        runs-on: windows-latest
      windows-arm64-cross:
        if: ${{ !inputs.xtensa_compiler_memory_probe && !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control }}
        name: Windows ARM64 programs, cross-built on Linux
        runs-on: ubuntu-24.04
      windows-arm64-run:
        name: Windows ARM64 program runtime
        runs-on: windows-11-arm
      macos:
        if: ${{ !inputs.xtensa_compiler_memory_probe && !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control }}
        name: ${{ matrix.name }}
          matrix:
            include:
              - {runner: macos-15, name: macOS host and compiler fixed point, full: true}
              - {runner: macos-15-intel, name: macOS host and compiler fixed point (Intel), full: false}
        runs-on: ${{ matrix.runner }}
      macos-published-rebuild:
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.macos_published_rebuild }}
        name: v0.2.47 exact rebuild (${{ matrix.architecture }})
          matrix:
            include:
              - runner: macos-15
                architecture: arm64
              - runner: macos-15-intel
                architecture: x86_64
        runs-on: ${{ matrix.runner }}
      macos-runtime-bench:
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.macos_runtime_bench }}
        name: Native Mac runtime (${{ matrix.architecture }})
          matrix:
            include:
              - runner: macos-15
                architecture: arm64
              - runner: macos-15-intel
                architecture: x86_64
        runs-on: ${{ matrix.runner }}
      libc-free-aarch64:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control && !inputs.xtensa_compiler_memory_probe }}
        name: Linux module programs link no libc (AArch64)
        runs-on: ubuntu-24.04
      libc-free-riscv64:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control && !inputs.xtensa_compiler_memory_probe }}
        name: Linux module programs link no libc (RISC-V 64)
        runs-on: ubuntu-24.04
      static-compiler:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control && !inputs.xtensa_compiler_memory_probe }}
        name: Static compiler (no loader, no libc)
        runs-on: ubuntu-24.04
      static-compiler-aarch64:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control && !inputs.xtensa_compiler_memory_probe }}
        name: Static compiler for AArch64 under qemu
        runs-on: ubuntu-24.04
      android-pointer-tags-control:
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.android_pointer_tags_control }}
        name: AArch64 tagged-pointer positive and negative controls
        runs-on: ubuntu-24.04
      xtensa-companion-install:
        if: ${{ github.event_name == 'workflow_dispatch' && inputs.xtensa_companion_install_probe }}
        name: Optional Xtensa installer (${{ matrix.runner }})
          matrix:
            include:
              - {runner: ubuntu-24.04, platform: x86_64-linux}
              - {runner: macos-15, platform: arm64-macos}
              - {runner: macos-15-intel, platform: x86_64-macos}
        runs-on: ${{ matrix.runner }}
      xtensa-companion-install-report:
        if: ${{ always() && github.event_name == 'workflow_dispatch' && inputs.xtensa_companion_install_probe }}
        runs-on: ubuntu-24.04
      xtensa-companion-routing:
        if: ${{ github.event_name == 'workflow_dispatch' && (inputs.xtensa_companion_routing_probe || inputs.xtensa_companion_embedded_probe) }}
        name: Stock parent Xtensa routing (${{ matrix.runner }})
          matrix:
            runner: ${{ fromJSON(inputs.xtensa_companion_embedded_probe && '["ubuntu-24.04"]' || '["ubuntu-24.04","macos-15","macos-15-intel"]') }}
        runs-on: ${{ matrix.runner }}

### `.github/workflows/llvm-aarch64-static.yml`

      build:
        name: Patched LLVM and lld static archives for aarch64-linux
        runs-on: ubuntu-24.04-arm

### `.github/workflows/llvm-linux-portable.yml`

      build:
        runs-on: ubuntu-24.04

### `.github/workflows/llvm-macos.yml`

      build:
        name: Patched LLVM for ${{ matrix.architecture }}-macos
          matrix:
            include:
              - {runner: macos-15, architecture: arm64}
              - {runner: macos-15-intel, architecture: x86_64}
        runs-on: ${{ matrix.runner }}

### `.github/workflows/llvm-riscv64-static.yml`

      build:
        name: Cross-build patched LLVM and lld for riscv64-linux
        runs-on: ubuntu-24.04

### `.github/workflows/llvm-windows-static.yml`

      build:
        name: Patched LLVM and lld static archives for Windows ${{ inputs.architecture }}
        runs-on: ${{ inputs.architecture == 'arm64' && 'windows-11-arm' || 'windows-2025' }}

### `.github/workflows/probe-stage1.yml`

      probe:
        name: stage 1 (${{ matrix.variant }} ${{ matrix.run }})
        runs-on: macos-15
          matrix:
            include:
              - {variant: both, run: 1}
              - {variant: both, run: 2}
              - {variant: both, run: 3}
              - {variant: none, run: 1}

### `.github/workflows/release.yml`

      compiler:
        if: ${{ inputs.windows != 'only' && inputs.windows != 'fixpoint' }}
          matrix:
            include:
              - runner: ubuntu-24.04
                asset: ablac-x86_64-linux
                architecture: x86_64
                platform: linux
              - runner: macos-15
                asset: ablac-arm64-macos
                architecture: arm64
                platform: macos
              - runner: macos-15-intel
                asset: ablac-x86_64-macos
                architecture: x86_64
                platform: macos
        runs-on: ${{ matrix.runner }}
      static-suite:
        if: ${{ inputs.windows != 'only' && inputs.windows != 'fixpoint' }}
      windows-object:
        if: ${{ inputs.windows != 'off' }}
        runs-on: ubuntu-24.04
      windows-link:
        runs-on: windows-latest
      windows-package:
        runs-on: ubuntu-24.04
      windows-exercise:
        runs-on: windows-latest
      windows-fixpoint:
        if: ${{ inputs.windows == 'fixpoint' }}
        runs-on: windows-latest
      publish:
        if: ${{ !cancelled() && !failure() && inputs.publish_release && inputs.windows != 'only' && inputs.windows != 'fixpoint' }}
        runs-on: ubuntu-24.04

### `.github/workflows/rv64-static-convergence.yml`

      compare:
        name: Compare native RV64 release stages under QEMU
        runs-on: ubuntu-24.04

### `.github/workflows/static-nightly.yml`

      compiler:
        runs-on: ubuntu-24.04
      suite:

### `.github/workflows/static-suite.yml`

      shard:
        name: Static suite (shard ${{ matrix.shard }}/2)
        runs-on: ubuntu-24.04
          matrix:
            shard: [1, 2]
      coverage:
        name: Verify the full static recipe passed
        runs-on: ubuntu-24.04

### `.github/workflows/windows-compiler-link.yml`

      cross-compile:
        name: Compile the Windows compiler object on Linux
        runs-on: ubuntu-24.04
      link:
        name: Link the Windows compiler with its static LLVM SDK
        runs-on: windows-latest

## Ecosystem

Missing: tools/test-siblings.sh summary.

## Docs

Missing: stdlib public declaration documentation coverage (ablac doc coverage.json).

## Real-world deployments

Missing: verified, hand-maintained deployments.
