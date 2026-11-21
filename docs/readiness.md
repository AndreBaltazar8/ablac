# Internal production readiness

Internal only. Regenerate with `tools/readiness.sh`; this is an evidence inventory, not a production approval or stability policy.

Source revision: `8b069114febef2595bdd00647a5169d1f37e57c0`. Source counts describe this working tree. Saved results may describe older revisions; only explicitly recorded revisions identify what was tested.

## Stability

Evidence: `build/readiness/releases.json`; SHA-256 `658d8bb1394a3f5e770bbb0c5afe4be87267a480611708e2ba5695302e26a710`.

| Release | Migration bullets |
|---|---:|
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

Suite inventory: **545 recipe commands**, **399 case directories**. These are source inventory counts, not passing checks.

Missing: completed gate, stage2 == stage3 result and suite pass/fail totals.

### Fuzz campaigns and disagreements

Harness: `tools/fuzz/run`; `tools/test-fuzz-abla.sh` checks the harness and planted disagreement controls. Scratch seed directories are not campaign results.

Missing: structured campaign totals and disagreement counts (fuzz.json).

Evidence: `/home/andre/agents-memory/abla/ablac-differential-fuzzer.md`; SHA-256 `6b367dbb65b2becb51fa74c4df2202d5f3eb1e4f2a29bb46e7a2aed3346bb5c2`.

Historical campaign narrative, final 24 lines (may be stale; no aggregate inferred; consult the full source above):

    
    2026-11-12 ablac-c6 took over #648 (from ablac-e2). Standing on 195f43b9 (build/ablac.bin SHA-256 9d9e77fd…a621d53): default 7601–7640, hosted 7701–7710, cross-target 7801–7804, focused ownership_lifetime_check 7901–7920, all agree. Branch fuzz-804-c6 aa2cb156 (on b1d218e5) adds `fresh_select_check` (#804: `??`-selected fresh resource as argument/field owner/receiver/loop source, fresh resource-interface `when` subject via prelude `face(n, other)`, FaceTicket/OtherFace); focused 7961–7980 and default 7981–8000 agree; handed to ablac-d1. Lesson: never edit tools/fuzz-differential in the worktree a running campaign uses (each run re-reads it): develop in a second worktree. Next free seeds: above 8000.
    
    ## 2026-11-14 Abla port (decision #60, ablac-9e for lead ablac-74)
    
    Campaign on master cae5a190 with the Python fuzzer (seeds 8001–8720, all modes and campaigns) found nothing; shared
    globals now pass (#796 fixed). The fuzzer is ported to Abla as tools/fuzz (built and run by tools/fuzz/run, like
    tools/ct-timing): stage 1 + batches A–E2, a stacked chain of local branches on cae5a190 — fuzz-abla-stage1 54bc57ad,
    -types 330359f4, -collections 6ede22da, -ownership c6ffb238, -data 67e9eaba, -campaigns b55279d1, -graphs 0357ff83,
    -retire-python fb375205 (removes tools/fuzz-differential, its suite step and allow-list entries; the node harness moved
    to tools/fuzz/wasm-run.mjs). Key facts:
    - Same six modes and all 43 items (35 families, plain check, 7 campaigns), same flags (--focus, --hosted-tasks,
      --panics, --shared-globals, --module-graphs, --subparser-graphs, --cross-target-tiers, --check-*, --program,
      --replay). PRNG is xoshiro256** via SplitMix64 (reference vectors in --selftest); Abla seeds do NOT match Python
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

### Open wrong-code bug candidates

Heuristic scan of open TODO list items for wrong code, miscompiles, wrong results, or mode disagreements. Candidate titles and source lines follow; inspect the full items to distinguish resolved findings inside an open tracking item. This is not a bug count; unlabelled bugs can be missed. Completed items are excluded.

    TODO.md:421 - [ ] **`tools/fuzz-differential` findings** (2026-11-08; branch `fuzz-differential`). The fuzzer builds
    TODO.md:863 - [ ] **`--fast` builds are read on every target; the Xtensa one is partly unplaced.** `tools/test-ct.sh` builds the fixture
    TODO.md:3305 - [ ] **instcombine: `0.0 / (0.0 * v)` becomes a signed zero (LLVM 23.1.x; found by the differential fuzzer, seed 100097, 2026-11-21).** `%v = sitofp i64 %n
    TODO.md:3314 - [ ] **fdlibm-exact `sinh`, `cosh`, `tanh`, `asin`, `acos`, `erf`, `log1p`, `log2`, `log10`, `expm1` (static libc, src/static_libc/math2.ab and math3.ab).**

## Security

Security mechanisms and limits: `docs/reliability-roadmap.md`, `docs/constant-time.md`, `docs/ownership.md`. Declared tests are inventory, not security audit results:

    tools/test-bignum-secret.sh
    tools/test-compile-effects.sh
    tools/test-compile-tls.sh
    tools/test-emutls.sh
    tools/test-http-tls-deadline.sh
    tools/test-subparser-generated-adapter.sh
    tools/test-subparser-named-arguments.sh
    tools/test-subparser-site-key.sh
    tools/test-tls-accept-deadline.sh
    tools/test-tls-binding.sh
    tools/test-tls-bogo.sh
    tools/test-tls-chains.sh
    tools/test-tls-client-ca.sh
    tools/test-tls-ecdsa-curve.sh
    tools/test-tls-faults.sh
    tools/test-tls-fuzz.sh
    tools/test-tls-handles.sh
    tools/test-tls-hosted-mix.sh
    tools/test-tls-pure-interop.sh
    tools/test-tls-pure.sh
    tools/test-tls-resume-review.sh
    tools/test-tls-session.sh
    tools/test-tls-trust-cache.sh
    tools/test-tls-trust-env.sh
    tools/test-tls-unix.sh
    tools/test-typed-subparser-inspection.sh
    tools/test-websocket-tls-server.sh
    tools/test-x509.sh

Missing: independent audit, vulnerability inventory and security fuzz campaign evidence (security.md).

## Performance

| Benchmark | Abla | C | Rust | Go | Zig |
|---|---|---|---|---|---|
| Runtime / RSS / compile time / size | Missing | Missing | Missing | Missing | Missing | Missing |

Awaiting `tools/bench-languages` measurements. Archive its report as `benchmarks.md` with revision, toolchains and host metadata.

## Platforms

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
        name: Patched libLLVM*.a for aarch64-linux
        runs-on: ubuntu-24.04-arm

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
      publish:
        if: ${{ inputs.publish_release }}
        runs-on: ubuntu-24.04

Missing: saved CI run outcomes for the source revision.

## Ecosystem

Missing: tools/test-siblings.sh summary.

## Docs

Missing: stdlib public declaration documentation coverage (tools/stdlib-doc coverage.json).

## Real-world deployments

Missing: verified, hand-maintained deployments.

