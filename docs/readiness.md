# Internal production readiness

Internal only. Regenerate with `tools/readiness.sh`; this is an evidence inventory, not a production approval or stability policy.

Source revision: `ba5d6b7d5c26a65059ed7ca02c32a6780add41c7`. Source counts describe this working tree. Saved results may describe older revisions; only explicitly recorded revisions identify what was tested.

## Stability

Evidence: `saved evidence/releases.json`; SHA-256 `324766880ed4b60b433a7732a4adc2778b060eec8f1b1bc5c0bbe544ef32ea26`.

| Release | Migration bullets |
|---|---:|
| v0.2.79 | 6 |
| v0.2.78 | 3 |
| v0.2.77 | 2 |
| v0.2.74 | 2 |
| v0.2.73 | 2 |
| v0.2.72 | 4 |
| v0.2.71 | 2 |
| v0.2.70 | 4 |
| v0.2.69 | 24 |
| v0.2.68 | 20 |
| v0.2.67 | 10 |
| v0.2.66 | 10 |
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

Suite inventory: **709 recipe commands**, **499 case directories**. These are source inventory counts, not passing checks.

Missing: completed gate, stage2 == stage3 result and suite pass/fail totals.

### Published release checks

Evidence: `saved evidence/release-check.log`; SHA-256 `f20aca011c98ac9e9491efa8868fe58bb5bf7922418cbed4fc4a203c1792f68b`.

    Saved from ~/archive/ablac-release-v0.2.79 (e6, 2026-11-28) for release v0.2.79, tag ba5d6b7d5c26a65059ed7ca02c32a6780add41c7, release run https://github.com/AndreBaltazar8/ablac/actions/runs/46029964816 (dispatched on master 67f69b0c0, tag=v0.2.79).

    1. tools/release-check.sh v0.2.79 46029964816 <local stage 2>, before publish (check.log). The two windows*-fixpoint FAILs are the checker not reading those jobs' logs, as printed; the jobs themselves are in the run.
    release-check v0.2.79  run 46029964816  /home/andre/archive/ablac-release-v0.2.79/check
    PASS  assets   24 files, the names of v0.2.78
    PASS  sha256   12 files match their .sha256
    SKIP  signature unsigned before publish (the publish job signs SHA256SUMS)
    PASS  version  prints 'ablac 0.2.79'
    PASS  stage2   ablac-dynamic-x86_64-linux cmp equal to build/gate/stage2 (d12a85450f4c)
    PASS  convergence v0.2.78 seeds (A v0.2.78, B v0.2.77) both reach 64f6d2034790 at ba5d6b7d5c26 (https://github.com/AndreBaltazar8/ablac/actions/runs/46030062723)
    PASS  static   no PT_INTERP, no DT_NEEDED, smoke compile, fixpoint
    PASS  static-aarch64 no PT_INTERP, no DT_NEEDED, smoke compile (no fixpoint)
    SKIP  static-input cannot read the Linux job log of run 46029964816
    PASS  toolchain the static package: no PT_INTERP, no DT_NEEDED, no shared library or external LLVM tool, 46 MB, version 0.2.79 with an empty PATH
    PASS  playground version 0.2.79, the module matches its hash (6 MB), the stdlib bundle carries its hash
    FAIL  windows-fixpoint cannot read windows-fixpoint logs for run 46029964816
    PASS  windows  the toolchain layout, 32 MB, ablac.exe is a console PE for x86_64 with no C runtime import and carries version 0.2.79
    FAIL  windows-arm64-fixpoint cannot read windows-arm64 / Compare two native ARM64 compiler self-builds logs for run 46029964816
    PASS  windows-arm64 the toolchain layout, 30 MB, ablac.exe is a console PE for aarch64 with no C runtime import and carries version 0.2.79
    RESULT: FAIL

    2. tools/release-convergence.sh run v0.2.79 --source-ref ba5d6b7d5 (conv.log).
    release-convergence: run 46030062723 (https://github.com/AndreBaltazar8/ablac/actions/runs/46030062723), lineage v0.2.78, source ba5d6b7d5c26a65059ed7ca02c32a6780add41c7
    PASS  convergence v0.2.78 seeds (A v0.2.78, B v0.2.77) both reach 64f6d2034790 at ba5d6b7d5c26 (https://github.com/AndreBaltazar8/ablac/actions/runs/46030062723)
    release-convergence: release-notes text in build/release-v0.2.79.notes.md (gh release create ... --notes-file build/release-v0.2.79.notes.md)

    3. The release run's static suite on ba5d6b7d5 (artifacts static-suite-logs-1..4, each shard's static-suite-source.sha is ba5d6b7d5):
    shard 1: 180 passed, 0 failed in 1227s
    shard 2: 181 passed, 0 failed in 1730s
    shard 3: 174 passed, 0 failed in 1344s
    shard 4: 174 passed, 0 failed in 1569s
    total: 709 passed, 0 failed

    4. After publish, tools/release-after.sh v0.2.79 (after.log):
      ablac-x86_64-linux: 8c0f67519b46 matches the binary
      ablac-x86_64-macos: 2b3c53ce33ec matches the binary
      ablac-arm64-macos: 4a99d7a4e6d2 matches the binary
    verify-release: signature good; 6 file(s) match the signed checksums

    5. Release run 46029964816 jobs (gh run view, 2026-11-28):
    - windows-toolchain / windows-object · success
    - compiler-linux / compiler (ubuntu-24.04, ablac-x86_64-linux, x86_64, linux) · success
    - compiler-macos (macos-15-intel, ablac-x86_64-macos, x86_64) / compiler (macos-15-intel, ablac-x86_64-macos, x86_64, macos) · success
    - windows-arm64 / Cross-build the Windows ARM64 compiler object on Linux · success
    - compiler-macos (macos-15, ablac-arm64-macos, arm64) / compiler (macos-15, ablac-arm64-macos, arm64, macos) · success
    - bridge · skipped
    - windows-toolchain / windows-link · success
    - windows-arm64 / Link the ARM64 compiler with the pinned SDK and static CRT · success
    - windows-toolchain / windows-package · success
    - windows-arm64 / Package the Windows ARM64 toolchain · success
    - windows-arm64 / Run the packaged ARM64 compiler with only System32 on PATH · success
    - windows-toolchain / windows-exercise · success
    - windows-fixpoint · success
    - windows-arm64 / Compare two native ARM64 compiler self-builds · success
    - static-suite / Static suite (shard 2/4) · success
    - static-suite / Static suite (shard 1/4) · success
    - static-suite / Static suite (shard 4/4) · success
    - static-suite / Static suite (shard 3/4) · success
    - static-suite / Verify the full static recipe passed · success
    - publish · success

### Fuzz campaigns and disagreements

Harness: `tools/fuzz/run`; `tools/test-fuzz-abla.sh` checks the harness and planted disagreement controls. Scratch seed directories are not campaign results.

Missing: structured campaign totals and disagreement counts (fuzz.json).

Evidence: `/home/andre/agents-memory/abla/ablac-differential-fuzzer.md`; SHA-256 `a32a64f73a174b4609502b489b81795afa08ebbbc3df7051d434a66843135821`.

Historical campaign narrative, final 24 lines (may be stale; no aggregate inferred; consult the full source above):

    FC landed at `f7b0215ed`. Built an exact stage 2 with the v0.2.66 seed in `.claude/worktrees/cx10-fuzz648-fc`; stage 2 and stage 3 emitted identical bitcode. Replay on the matching sysroot used the same fuzzer tree, seed ranges, check counts and flags as FB. Again all 32 seeds agreed, zero disagreed, all 768 generated checks and eight additional panic cases passed, and each shard exited 0. Stage-2 payload SHA-256 `811dc1ea29a46b118b6d1630c70277d857d9578f3e36312a9dedd105f7a657a7` matched before/after each hold. Durable logs, commands and actual exit statuses are in `evidence/fuzz648-fb-fc/fc/`. Reported to ablac-74 and ablac-47. Neither campaign changed tracked files. #648 remains the standing fuzzer item.

    ## WASI and RISC-V comparison arms (#648, ablac-a5)

    Opt in with `ABLA_FUZZ_WASI=1` (Wasmtime, override `ABLA_WASMTIME`) and `ABLA_FUZZ_RISCV64=1` (QEMU user-mode, override `ABLA_QEMU_RISCV64`). Optional arms run the same generated program as native fast/release, with a named skip if the compiler or runtime is unavailable. The ordinary corpus compares portable values and exact stdout and status, without filtering pointer addresses. The suite uses a synthetic address round-trip to verify 32/64-bit pointer expectations independently. WASI built-in panics lose guest diagnostic text by design in the backend; require exactly the Wasmtime unreachable trap, exit 134, and stdout `before\n`. Explicit `panic()` writes its own diagnostic and invokes proc_exit 101. These checks are separate from ordinary result comparison. WASI skips hosted tasks and both cross targets skip the host libc campaign.

    Baseline `79833ecf5` (stage 2 `d5acdac2a6564da7ede960ae03386d1b0a1569e8fe2548badc48b4dfbe4b12bb`) passes seeds 101200–101215 and 101216–101224 with `--panics`: 25 seeds ×24, all six reference modes plus WASI, nine additional panic shapes, zero unanticipated disagreements, two exits 0. RISC-V unavailable on that compiler. Saved under `evidence/fuzz648-targets/79833ecf5/`. The branch `cx10-fuzz-targets-fh` at `c83397c7c` on FH `6c3c9abff` replays the same seeds with QEMU and Wasmtime plus hosted seeds 101225–101228. Qualification logs under `.claude/worktrees/cx10-fuzz-targets-fh/build/campaign/`; systemd unit `ablac-cx10-fuzz-targets-fh`. Still awaiting completion.

    FH qualification complete. A copied gate payload did not reproduce identical bitcode in the new checkout, so `c83397c7c` on `6c3c9abff` was fully bootstrapped from the v0.2.66 pin. Stage 2 and stage 3 bitcode match. Exact stage-2 payload `252b9b216501e63a150bee72ee0c133f09ad2eff6b06abff3d311e43573c9192` matched before/after each hold. The 25 portable seeds agreed in all eight modes (600 checks, all nine panic shapes) and the four hosted seeds agreed in five modes (96 checks, RISC-V included and WASI explicitly skipped). All shards exit 0, no compiler disagreement. Focused suite 7/0, including five guards, test-wasm-wasi and test-fuzz-abla with both target controls. The standalone RISC-V test is CI-only and was not part of this filter. Saved commands, logs and exit statuses under `evidence/fuzz648-targets/6c3c9abff/`. Handoff for FK is `cx10-fuzz-targets-fk` at `074ec34f1` on `94f20765c`. The tooling files match the tested FH branch, and the integrated suite preserves 7e's build-path byte-difference control. The final replay received a shell syntax and diff check.

    GA56+GA7 `9d6d3b81c`: ablac-ae covered `region_member_check`, seeds 101300–101315 ×24, on the matching gated stage 2 (`0b6bb062654933c75ab8370913952f2b45123ecccfc325bb40a469c53e202b69`). All 16 seeds and 384 checks agreed in eight modes including Wasmtime and QEMU. Campaign exit 0, payload verified before and after. Log: `evidence/fuzz648-ga7-region/101300-101315.log`.

    v0.2.69 pre-release follow-up `150c711df`: ablac-75 is assigned the default compiler mix, seeds 101400–101415 ×24, with WASI and RISC-V enabled. Verified merge30's gated stage-2 payload `9089575f8e00c285a8f011d140a7ab6321d8d6e8764ce193f67d977441911af4` (651/0, stage2==stage3). Results: 16/16 seeds, 384 checks across eight modes, campaign and unit exit 0, payload unchanged. Evidence: /home/andre/archive/ablac-cx2-fuzz-v0269.1wlFbohP/report.md.

    GA36 `c2c2b769a`: default seeds 101500–101515 and `--focus ownership_lifetime_check` seeds 101516–101531, 24 checks per seed. All 32 seeds and 768 generated checks agree across all eight modes including WASI/Wasmtime and RISC-V/QEMU. Both campaigns and systemd units exited 0. Gated stage-2 payload SHA-256 `e7145b6ad7ecfba081c9a8e088a5a8ed190224879247a526c639071c281a85d8` matched before and after both runs. Logs, commands and statuses: `evidence/fuzz648-ga36/`.

    v0.2.74 `e69fba506`: default seeds 101600–101615 and `--focus ownership_lifetime_check` seeds 101616–101631, 24 checks each. All 32 seeds and 768 checks agreed in all eight modes. Both campaign and unit exit statuses were 0. Release-gated stage-2 payload `0663a81216ce299554b21ba57b6bc886bea418238eef50825f57e4dfa69ef035` matched before and after both runs. Logs and exit statuses: `evidence/fuzz648-v0274/`.

    ## GA47 campaign and logical_assign_check (#648, ablac-a5, 2026-11-26)

    Branch fuzz-logical-wip at 9924cab3b on GA47 7468889aa adds `logical_assign_check` (&&=/||=, gen_logical.ab, in FUZZ_RARE and the --control-oracle list) and `tools/fuzz/parsers/tls-tickets.ab` (ticket key rotation/expiry model; `tools/fuzz/parsers/run tls-tickets --seeds A-B --inputs N`). Gotchas met: a function returning a parameter's object is refused (ownership.managed-return-borrow-contract) and a field of a call result cannot be mutated unless the call makes a fresh object and stores it (the pattern of tests/cases/logical-assignment/field.ab); under an assignment to h.box.flag the RHS must not call h.fresh (it would swap the object the model's slot names). On GA47 stage 2 (f384461e…): focused 101700–101739, default 101740–101755 (WASI + RISC-V), --libc 101760–101779, f64-boundary seeds 2–6 ×1500, tls-tickets 1–1000 ×300, test-fuzz-abla: all clean. Next free Abla seeds: above 101779.
    Slot lesson: wrap `timeout` INSIDE the fair-flock hold (fair-flock --max-hold 600 ... timeout 590 cmd); an outer timeout counts queue time and killed a step that never ran.

    2026-11-27 ablac-12 on #648 (GA52–56 follow-up). New families on master: static_concat_check (gen_static.ab), gc_churn_check (gen_gc.ab; Wasm collection via memorySetCollectionGrowth, boxes capped at 9000 elements and 20000 a phase so the `#` build stays under the 120 s limit), scalar_mix_check (gen_scalar.ab), sealed_when_check (gen_sealed.ab), all in FUZZ_RARE and --control-oracle; tools/fuzz/analysis-scalar.mjs replays editor edits under ABLA_ANALYSIS_INCREMENTAL_TYPING=2 against a cold analysis (#1132 scalar bodies), run by test-fuzz-abla.sh with --control. Seeds used: 101800–101999 (all clean on 3045428c2, merge30 199cedde0, GA61 60b904b32, GA62 fe946980a; no compiler disagreement; the only finding was the grouped `is` arm not narrowing, fixed by #166). Allocated next: 103000–103999 to ablac-12 (102000–102999 is ablac-64). Rule from the lead: take the next free thousand above the highest allocated range and note it here.

### Open wrong-code bug candidates

Heuristic scan of open TODO list items for wrong code, miscompiles, wrong results, or mode disagreements. Candidate titles and source lines follow; inspect the full items to distinguish resolved findings inside an open tracking item. This is not a bug count; unlabelled bugs can be missed. Completed items are excluded.

    TODO.md:444 - [ ] **`tools/fuzz-differential` findings** (2026-11-08; branch `fuzz-differential`). The fuzzer builds
    TODO.md:886 - [ ] **`--fast` builds are read on every target; the Xtensa one is partly unplaced.** `tools/test-ct.sh` builds the fixture
    TODO.md:3342 - [ ] **macOS still has the instcombine fdiv miscompile (owner TBD).** The macOS compiler's in-process libLLVM and the clang of its LTO prepare step are Homebrew's

## Security

Security mechanisms and limits: `docs/reliability-roadmap.md`, `docs/constant-time.md`, `docs/ownership.md`. Declared tests are inventory, not security audit results:

    tools/test-bignum-secret.sh
    tools/test-compile-effects.sh
    tools/test-compile-tls.sh
    tools/test-emutls.sh
    tools/test-fuzz-parsers.sh
    tools/test-http-tls-deadline.sh
    tools/test-parser-nesting.sh
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
    tools/test-websocket-tls-client.sh
    tools/test-websocket-tls-server.sh
    tools/test-workflow-security.sh
    tools/test-x509.sh

Evidence: `saved evidence/security.md`; SHA-256 `ebaa7bb32fbaab1683db9dbf1d03560bdf3d7c75e5e6e80d214711c4d7db2e16`.

    Security review evidence for v0.2.79 (saved by ablac-e6, security lead, 2026-11-28).

    Programme: #1139, reviews by Claude agents, one area per reviewer and round, each finding
    reproduced and rated by the security lead (critical: code execution or key compromise from
    untrusted input; high: memory unsafety from safe code or a boundary bypass; medium: integrity
    bypass with conditions, or a full outage from one request; low: availability or hardening).
    Policy (decision D1): fixed openly, no embargo; until a fix ships, public text names no
    reproduction, and a fixing release adds a known-issue line with a workaround to the older
    releases it affects.

    Areas: 1 compile-time capabilities, 2 package fetch and lock, 3 TLS (pure stack),
    4 untrusted-input parsers and HTTP servers, 5 crypto primitives, 6 signed releases and SBOM,
    7 runtime memory safety, 8 the editor's analysis service, 9 platform runtimes (macOS),
    10 trusted native code in the standard library. Rounds through v0.2.79: area 1 r1-r5,
    area 4 r1-r8, area 10 r1-r3, the others r1-r2.

    Scope of this evidence: the source at tag v0.2.79 (ba5d6b7d5). What v0.2.79 fixed is in its
    release notes. Findings that affect v0.2.79 and are fixed after it are listed, with known-issue
    lines for the affected releases, in the notes of the release that ships each fix (v0.2.80 is
    in preparation); their details are withheld here until then.

    Limitations: reviews read code and run reproductions on this machine (x86-64 Linux, with
    macOS and Windows behaviour from CI); no third-party audit; physical and non-timing side
    channels, the OS kernel and the siblings' application logic are out of scope; fuzzing is
    recorded separately (fuzz.json) and is not part of this file.

## Performance

Evidence: `saved evidence/benchmarks.md`; SHA-256 `7b18861e5f01bae526df7d7ff79aaa24ba75c40cb4c2a02788d8810938bb3e99`.

Benchmark evidence near v0.2.79 (saved by ablac-e6, 2026-11-28, from the owners' reports).
These describe the revisions named, not necessarily the source revision of this report.

1. abla-compare HTTP server matrix (ablac-d0, 2026-11-27; ~/archive/abla-compare-d0-20261127,
   note ~/agents-memory/abla/abla-compare-20261127.md). Host: i9-13900K (CPUs 12 and 13 offline),
   Linux 6.17.3, harness defaults (one Abla worker, 64 connections, 3 s warm-up, 3 x 10 s),
   quiet machine (all fair-flock slots held), pinned nixpkgs
   6510408d, frozen abla-web inputs (baed16d abla.lock). Compilers: v0.2.46 (control,
   matches the Nov 6 baseline's compiler), v0.2.78 and master 3045428c2. Three runs each.
   Single worker, req/s, v0.2.78 against the Nov 6 baseline: plaintext 301807 (-9.5%),
   parameters 284607 (+2.8%), body-16k 137217 (-22.2%), json-strings-4k 138601 (+51%);
   wins against the Nov 6 peers: 16 of 21 (Nov 6: 17). Six workers: plaintext 1700086
   (-1%), body-16k 802183 (-17.4%). Causes found: body-16k a checked word-copy loop
   (fixed in v0.2.79, 0b5fcacc7), plaintext +3% each from the Host checks and event deadlines
   (hardening). Instruction counts per request (perf stat -e instructions:u, one
   connection) are the method for later changes; per-change numbers are in the v0.2.80 notes.
2. Final rerun on master after the v0.2.80 HTTP changes (ablac-d0, 2026-11-27 21:12 UTC,
   final/single-master-final.json; the JSON does not record the compiler revision): single
   worker, median of three 10 s runs: plaintext 312275 req/s, body-16k 177933, json-strings-4k
   165135.
3. Compile speed across releases (#1204, ablac-52, 2026-11-27; ~/archive/ablac-release-series-1204,
   note ~/agents-memory/abla/ablac-release-series-1204.md): instructions (cpu_atom, CPU 25)
   per build from v0.2.50 to master; flat from v0.2.70 to master; self-build per source line
   +3.4% from v0.2.50 to GA56; --fast cold builds doubled at v0.2.67 (the prebuilt fast
   runtime object built in each new cache; shipped prebuilt after v0.2.79).

## Platforms

Evidence: `saved evidence/release.json`; SHA-256 `7c7cb7738912eeef287d94200cefbf8cd9bd7c85983811c3ba835d016a26ddf4`.

Published assets for [v0.2.79](https://github.com/AndreBaltazar8/ablac/releases/tag/v0.2.79) (27):

- `abla-playground-0.2.79.tar.gz`
- `abla-playground-0.2.79.tar.gz.sha256`
- `abla-toolchain-arm64-macos.tar.gz`
- `abla-toolchain-arm64-macos.tar.gz.sha256`
- `abla-toolchain-dynamic-x86_64-linux.tar.gz`
- `abla-toolchain-dynamic-x86_64-linux.tar.gz.sha256`
- `abla-toolchain-x86_64-linux.tar.gz`
- `abla-toolchain-x86_64-linux.tar.gz.sha256`
- `abla-toolchain-x86_64-macos.tar.gz`
- `abla-toolchain-x86_64-macos.tar.gz.sha256`
- `abla-toolchain-x86_64-windows.zip`
- `abla-toolchain-x86_64-windows.zip.sha256`
- `ablac-0.2.79.spdx.json`
- `ablac-arm64-macos`
- `ablac-arm64-macos.sha256`
- `ablac-dynamic-x86_64-linux`
- `ablac-dynamic-x86_64-linux.sha256`
- `ablac-static-aarch64-linux`
- `ablac-static-aarch64-linux.sha256`
- `ablac-windows-arm64.zip`
- `ablac-windows-arm64.zip.sha256`
- `ablac-x86_64-linux`
- `ablac-x86_64-linux.sha256`
- `ablac-x86_64-macos`
- `ablac-x86_64-macos.sha256`
- `SHA256SUMS`
- `SHA256SUMS.sig`

Missing: saved CI run outcomes for the source revision.

Coverage tiers recorded in the source checkout’s platform matrix.

| Platform | Tier | Compiler host evidence | Program target evidence |
|---|---|---|---|
| Linux x86-64 | T1 | Native suite, dynamic self-build and static compiler fixpoint | Native executables; default libc-free link with explicit dependency exceptions |
| Linux AArch64 | T2 | Cross-built static compiler exercised under qemu in CI; native self-build and smoke on manual dispatch | Static programs cross-built and selected programs executed under qemu |
| macOS arm64 | T2 | Native compiler, selected host checks and self-rebuild | Native Mach-O; selected runtime paths, iOS Simulator integration |
| macOS Intel | T2 | Native compiler and selected host checks; release self-rebuild | Native Mach-O; selected runtime paths |
| Android arm64 | T2 | No Android-hosted compiler gate | Shared libraries checked against NDK; exports executed by bionic under qemu |
| iOS arm64 and Simulator | T2 Simulator / T3 device | No iOS-hosted compiler gate | Device archive/XCFramework checks; selected exported calls run on arm64 Simulator |
| WebAssembly hosted | T2 | No Wasm-hosted compiler gate | Release/development modules execute with the `abla_host` ABI under Node |
| WebAssembly hostless | T2 | No Wasm-hosted compiler gate | Import-free runtime fixtures and differential programs execute under Node |
| Xtensa / ESP32 | T3 | No compiler hosted on the microcontroller | Object/assembly checks and optional companion integration; no required board run |
| Linux RISC-V 64 | T2 | Static compiler (pinned patched LLVM/lld) executed under qemu in CI: release and fast hello, in-process object emission; self-build fixed point under qemu on manual dispatch | Static LP64D programs; every module program that links static runs under qemu and matches x86-64 (335 of 336) |
| Windows x86-64 | T2 | Packaged compiler smoke on `windows-latest` nightly and on dispatch; native fixed point required when the zip ships | Cross-built on Linux; the freestanding exit-status program, the hosted crash program with its symbolized backtrace, and selected hosted programs run natively on `windows-latest` in CI |
| Windows ARM64 | T2 | Packaged compiler smoke and native fixed point on `windows-11-arm` required when the zip ships | Hosted programs cross-built on Linux and run natively on `windows-11-arm` in CI |

Declared workflow jobs and matrices, extracted from `.github/workflows`. This configuration does not establish passing CI or hardware coverage; conditional/manual jobs remain conditional/manual.

### `.github/workflows/aarch64-native-fixpoint.yml`

      cross-build:
        name: Cross-build the AArch64 compiler and reference program
        runs-on: ubuntu-24.04
      native:
        name: AArch64 self-build and smoke with empty PATH
        runs-on: ubuntu-24.04-arm

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
        name: ${{ inputs.xtensa_compiler_memory_probe && 'Xtensa compiler memory probe' || format('Linux suite (shard {0}/3)', matrix.shard) }}
          matrix:
            shard: ${{ fromJSON(inputs.xtensa_compiler_memory_probe && '[1]' || '[1,2,3]') }}
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
              - {runner: macos-15, name: macOS host tests (Apple Silicon), tests: host, logs: arm64-host}
              - {runner: macos-15, name: macOS host and compiler fixed point, tests: live, logs: arm64}
              - {runner: macos-15-intel, name: macOS host and compiler fixed point (Intel), tests: host, logs: x86_64}
              - {runner: macos-15-intel, name: macOS live compiler tests (Intel), tests: live, logs: x86_64-live}
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
        name: Linux module programs link no libc (AArch64, ${{ matrix.part }}/3)
          matrix:
            part: [1, 2, 3]
        runs-on: ubuntu-24.04
      libc-free-riscv64:
        if: ${{ !inputs.xtensa_companion_routing_probe && !inputs.xtensa_companion_embedded_probe && !inputs.xtensa_companion_install_probe && !inputs.macos_published_rebuild && !inputs.macos_runtime_bench && !inputs.android_pointer_tags_control && !inputs.xtensa_compiler_memory_probe }}
        name: Linux module programs link no libc (RISC-V 64, ${{ matrix.part }}/3)
          matrix:
            part: [1, 2, 3]
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

### `.github/workflows/macos-analyze-session.yml`

      session:
        name: Analysis session (${{ matrix.architecture }})
          matrix:
            include:
              - runner: macos-15
                architecture: arm64
              - runner: macos-15-intel
                architecture: x86_64
        runs-on: ${{ matrix.runner }}

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

### `.github/workflows/release-compiler.yml`

      compiler:
          matrix:
            include:
              - runner: ${{ inputs.runner }}
                asset: ${{ inputs.asset }}
                architecture: ${{ inputs.architecture }}
                platform: ${{ inputs.platform }}
        runs-on: ${{ matrix.runner }}

### `.github/workflows/release.yml`

      bridge:
        if: ${{ inputs.bridge_release != '' && inputs.windows != 'only' && inputs.windows != 'fixpoint' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' }}
        runs-on: ubuntu-24.04
      compiler-linux:
        if: ${{ !cancelled() && !failure() && inputs.windows != 'only' && inputs.windows != 'fixpoint' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' }}
      compiler-macos:
        if: ${{ !cancelled() && !failure() && inputs.windows != 'only' && inputs.windows != 'fixpoint' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' }}
          matrix:
            include:
              - runner: macos-15
                asset: ablac-arm64-macos
                architecture: arm64
              - runner: macos-15-intel
                asset: ablac-x86_64-macos
                architecture: x86_64
      static-suite:
        if: ${{ !cancelled() && !failure() && inputs.windows != 'only' && inputs.windows != 'fixpoint' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' }}
      windows-toolchain:
        if: ${{ inputs.windows != 'off' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' }}
      windows-fixpoint:
        if: ${{ inputs.windows == 'with' || inputs.windows == 'fixpoint' }}
        runs-on: windows-latest
      windows-arm64:
        if: ${{ inputs.windows_arm64 == 'only' || inputs.windows_arm64 == 'fixpoint' || (inputs.windows_arm64 == 'with' && inputs.windows != 'only' && inputs.windows != 'fixpoint') }}
      publish:
        if: ${{ !cancelled() && !failure() && inputs.publish_release && inputs.windows != 'only' && inputs.windows != 'fixpoint' && inputs.windows_arm64 != 'only' && inputs.windows_arm64 != 'fixpoint' && needs.compiler-linux.result == 'success' && needs.compiler-macos.result == 'success' && needs.static-suite.result == 'success' && (inputs.windows != 'with' || needs.windows-fixpoint.result == 'success') && (inputs.windows_arm64 != 'with' || needs.windows-arm64.result == 'success') }}
        runs-on: ubuntu-24.04

### `.github/workflows/rv64-static-convergence.yml`

      stage2:
        name: Build native RV64 release stage 2 under QEMU
        runs-on: ubuntu-24.04
      stage3:
        name: Build native RV64 release stage 3 and compare
        runs-on: ubuntu-24.04

### `.github/workflows/static-nightly.yml`

      compiler:
        runs-on: ubuntu-24.04
      suite:

### `.github/workflows/static-suite.yml`

      shard:
        name: Static suite (shard ${{ matrix.shard }}/4)
        runs-on: ubuntu-24.04
          matrix:
            shard: [1, 2, 3, 4]
      coverage:
        name: Verify the full static recipe passed
        runs-on: ubuntu-24.04

### `.github/workflows/windows-arm64-toolchain.yml`

      object:
        name: Cross-build the Windows ARM64 compiler object on Linux
        runs-on: ubuntu-24.04
      link:
        name: Link the ARM64 compiler with the pinned SDK and static CRT
        runs-on: windows-11-arm
      package:
        name: Package the Windows ARM64 toolchain
        runs-on: ubuntu-24.04
      exercise:
        name: Run the packaged ARM64 compiler with only System32 on PATH
        runs-on: windows-11-arm
      fixpoint:
        name: Compare two native ARM64 compiler self-builds
        if: ${{ inputs.fixpoint_tier != '' }}
        runs-on: windows-11-arm

### `.github/workflows/windows-compiler-link.yml`

      cross-compile:
        name: Compile the Windows compiler object on Linux
        runs-on: ubuntu-24.04
      link:
        name: Link the Windows compiler with its static LLVM SDK
        runs-on: ${{ inputs.architecture == 'arm64' && 'windows-11-arm' || 'windows-latest' }}

### `.github/workflows/windows-x64-ci.yml`

      windows-toolchain:
        if: ${{ github.ref == 'refs/heads/master' }}

### `.github/workflows/windows-x64-toolchain.yml`

      windows-object:
        runs-on: ubuntu-24.04
      windows-link:
        runs-on: windows-latest
      windows-package:
        runs-on: ubuntu-24.04
      windows-exercise:
        runs-on: windows-latest

## Ecosystem

Missing: tools/test-siblings.sh summary.

## Docs

Evidence: `saved evidence/coverage.json`; SHA-256 `1558043ce1db4c26d5e9aa4a38339a56d03c4f280a244ac38c015b63372a5444`.

Public declarations documented: **9704/9704** (100%); undocumented: **0**.

Coverage measures declared API documentation, not documentation quality or example execution.

## Real-world deployments

Missing: verified, hand-maintained deployments.
