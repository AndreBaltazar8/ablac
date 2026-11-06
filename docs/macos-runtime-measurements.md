# macOS hosted runtimes: v0.2.45 versus v0.2.47

Measured November 6, 2026 in [CI run 42159997472](https://github.com/AndreBaltazar8/ablac/actions/runs/42159997472).
Both architectures completed every build and all 110 timed runs per architecture.
There are also 22 retained warmup runs per architecture. No compiler, runtime,
stdlib or benchmark source changed for this measurement.

The runtime median geomean is **+1.42% on arm64**, **−0.59% on x86_64**
(v0.2.47 against v0.2.45, equally weighted over the 11 runnable programs).
Every program's two observed wall-time ranges overlap on each architecture.
This small, noisy sample does not establish equivalence or distinguish a real
performance change from runner noise or code layout. The largest observed median
increases are trees +11.37% on arm64 and fib +6.95% on Intel; retain those as
follow-up candidates, not diagnosed regressions.

RSS is broadly flat: the JSON-reader medians change +0.02% / −1.15%
(arm64 / Intel), and JSON-megabyte −0.38% / +0.50%. arm64 maps drops 5.63%,
with overlapping RSS ranges. Changes to tiny-process RSS amount to a few pages.

Stripped size grows **448–464 bytes on arm64**, **456–4,560 bytes on Intel**.
The 11 runtime workloads and the HTTP server have the same section growth
within each architecture: +1,856 bytes of `__text` on arm64, +2,128 on Intel,
plus common stubs, pointer slots, constants and unwind data. The size-only
HTTPS client has another 88 / 160 text bytes (arm64 / Intel). Symbol spans with
size growth are Darwin adapter helpers (`darwin_ioctl`, `darwin_poll`, syscall dispatch and flag/error mapping).
The eight added imports are `cfgetispeed`, `cfgetospeed`, `cfmakeraw`,
`cfsetispeed`, `cfsetospeed`, `readlink`, `select$DARWIN_EXTSN` and `symlink`.
Some Intel `__DATA_CONST`/`__DATA` file offsets move by an additional 4,096
bytes, explaining the page-sized jumps. These are real size increases; no size
normalization has been applied.

## Method and limits

- Download the published, checksum-verified v0.2.45 and v0.2.47 compiler for the
  runner's architecture. Each compiler builds against **its own release-tag
  stdlib**. The exact source commits and compiler hashes are in the raw record.
- Use the same frozen v0.2.47 benchmark sources for both. `git diff` confirms
  all `tests/benchmarks`, `event-http-server.ab` and `https-client.ab` sources
  are unchanged between those tags.
- Build the 13 programs from `tools/bench-compare.py` in release mode with
  `--no-cache`, a private cache per build, and four build jobs. Both versions
  use the same installed LLVM/SDK on a given runner. `dispatch` exercises
  interfaces, lambdas and small objects.
- Run unstripped binaries. One untimed warmup per version/program precedes
  **five fresh-process runs per version**, alternating first/second position
  each round. Warmups are retained but excluded from summaries. There is no
  cache reset between runtime processes; startup and ordinary allocator/GC
  work are included. No allocator environment overrides are applied.
- Wall time is Python's monotonic interval around `/usr/bin/time -l -p` and
  one program process. The native tool's coarser real/user/system times are
  also retained. Darwin peak RSS is **bytes**, per process, not compiler RSS
  or a sum over children. The ~11 ms arm64 websocket run is especially
  sensitive to launch overhead.
- All non-timing output matches across all warmups and samples. For the two
  JSON programs and websocket-codec, only their printed timing/rate fields
  are normalized. A nonzero exit or `MISMATCH` aborts the measurement.
- Strip a separate copy using the runner's Apple `strip -o`; retain both raw
  and stripped sizes/hashes. Binary size is measured once per deterministic
  build, not sampled five times.
- `event-http-server` is persistent and `https-client` requires the public
  network. Like `bench-compare.py`, they have size/build data only: **no server
  throughput, TLS/network performance or latency claim**.
- These hosted runners are not CPU-pinned or isolated. arm64 is a three-vCPU
  Apple M1 VM with 7 GiB RAM (macOS 15.8.2, LLVM 23.1.5); Intel is four vCPUs
  on i7-8700B with 14 GiB (macOS 15.7.9, LLVM 23.1.0). Both use Xcode 16.4 /
  SDK 15.5. Compare versions within a runner, not absolute times across CPUs.
  Sample load averages are retained; arm64 was visibly busy after VM boot.
- v0.2.45 already contains the earlier allocator/root-frame work. This pair
  **does not measure that work against its original pre-change baseline**;
  it establishes current Mac behavior and the change across these releases.
  Wasm and other non-Linux targets remain unmeasured here.

The first dispatch failed before compiling because Python could not raise its
Darwin child stack limit. The successful dispatch uses each tag's existing
compiler launcher for builds and ordinary stack limits for timed programs.
No samples from the failed dispatch are included.

## arm64

Times are milliseconds; RSS is MiB (2^20 bytes); size is stripped bytes. Positive deltas mean v0.2.47 uses more. No runner/core-isolation claim.

| Program | v045 time | v047 time | Δ | v045 RSS | v047 RSS | Δ | v045 size | v047 size | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fib | 1051.58 [981.22–1145.38] | 1081.32 [939.05–1357.64] | +2.83% | 1.19 [1.19–1.22] | 1.22 [1.19–1.22] | +2.63% | 70504 | 70952 | +0.64% |
| sieve | 705.37 [656.10–745.88] | 685.05 [625.36–857.77] | -2.88% | 128.28 [124.30–132.38] | 124.22 [116.12–132.38] | -3.17% | 70504 | 70968 | +0.66% |
| nbody | 354.47 [320.06–382.44] | 347.83 [336.08–369.25] | -1.87% | 1.27 [1.27–1.31] | 1.27 [1.27–1.34] | +0.00% | 87048 | 87512 | +0.53% |
| trees | 948.16 [885.09–1070.07] | 1055.98 [985.52–1182.03] | +11.37% | 222.08 [219.34–223.44] | 222.09 [221.73–222.91] | +0.01% | 70504 | 70968 | +0.66% |
| strings | 185.27 [169.61–190.70] | 191.77 [165.63–192.98] | +3.51% | 158.53 [153.56–165.42] | 160.50 [157.88–167.91] | +1.24% | 70520 | 70968 | +0.64% |
| maps | 256.45 [235.47–274.68] | 246.66 [239.52–312.00] | -3.82% | 148.97 [140.17–161.30] | 140.58 [135.94–145.95] | -5.63% | 70520 | 70984 | +0.66% |
| dispatch | 159.59 [155.55–228.07] | 168.31 [154.25–245.82] | +5.46% | 1.61 [1.58–1.61] | 1.61 [1.58–1.61] | +0.00% | 70520 | 70968 | +0.64% |
| matrix | 300.75 [288.34–302.57] | 303.38 [289.82–305.49] | +0.88% | 8.09 [8.09–8.09] | 8.09 [8.09–8.17] | +0.00% | 87048 | 87512 | +0.53% |
| websocket-codec | 11.10 [10.98–11.64] | 11.16 [10.86–11.49] | +0.49% | 20.88 [20.88–20.94] | 20.88 [20.88–20.88] | +0.00% | 87056 | 87520 | +0.53% |
| json-readers | 285.87 [282.36–320.71] | 286.24 [277.22–327.46] | +0.13% | 189.58 [186.39–191.59] | 189.62 [187.98–197.75] | +0.02% | 153200 | 153664 | +0.30% |
| json-megabyte | 1603.91 [1555.19–1852.28] | 1610.25 [1576.85–1682.03] | +0.40% | 424.83 [401.78–446.39] | 423.23 [406.25–448.36] | -0.38% | 219328 | 219792 | +0.21% |
| event-http-server | — | — | — | — | — | — | 169680 | 170144 | +0.27% |
| https-client | — | — | — | — | — | — | 154688 | 155152 | +0.30% |

## x86_64

Times are milliseconds; RSS is MiB (2^20 bytes); size is stripped bytes. Positive deltas mean v0.2.47 uses more. No runner/core-isolation claim.

| Program | v045 time | v047 time | Δ | v045 RSS | v047 RSS | Δ | v045 size | v047 size | Δ |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| fib | 1009.25 [972.16–1066.66] | 1079.44 [1003.61–1129.26] | +6.95% | 0.56 [0.55–0.57] | 0.56 [0.55–0.57] | -0.69% | 37064 | 37520 | +1.23% |
| sieve | 1590.59 [1550.57–1642.26] | 1657.55 [1588.49–1859.60] | +4.21% | 102.87 [102.75–102.87] | 102.88 [102.84–102.88] | +0.01% | 37072 | 41632 | +12.30% |
| nbody | 926.01 [868.86–945.03] | 857.30 [779.27–914.19] | -7.42% | 0.59 [0.59–0.60] | 0.60 [0.59–0.61] | +0.66% | 61672 | 66232 | +7.39% |
| trees | 2795.53 [2588.32–2962.42] | 2825.71 [2496.08–3059.82] | +1.08% | 211.45 [210.18–221.05] | 211.45 [210.20–216.47] | -0.00% | 37072 | 41624 | +12.28% |
| strings | 608.30 [586.70–641.40] | 642.90 [620.36–765.65] | +5.69% | 140.24 [137.74–140.25] | 140.24 [140.24–140.41] | -0.00% | 41176 | 45728 | +11.05% |
| maps | 682.95 [669.25–880.79] | 693.07 [683.04–923.52] | +1.48% | 132.31 [131.95–132.66] | 131.95 [131.95–132.08] | -0.27% | 45280 | 45736 | +1.01% |
| dispatch | 437.55 [368.50–469.98] | 407.94 [390.59–427.64] | -6.77% | 0.95 [0.94–0.95] | 0.95 [0.94–0.95] | +0.00% | 41176 | 41632 | +1.11% |
| matrix | 845.78 [701.78–929.59] | 799.37 [749.54–832.35] | -5.49% | 7.45 [7.44–7.45] | 7.45 [7.45–7.46] | +0.05% | 61672 | 62136 | +0.75% |
| websocket-codec | 51.74 [49.23–57.82] | 47.74 [47.31–54.03] | -7.73% | 21.77 [21.77–21.78] | 21.77 [21.77–21.77] | -0.02% | 57576 | 58040 | +0.81% |
| json-readers | 1025.59 [1012.09–1052.02] | 1036.15 [970.94–1116.26] | +1.03% | 181.59 [180.05–186.41] | 179.50 [175.85–181.91] | -1.15% | 139608 | 144160 | +3.26% |
| json-megabyte | 4971.53 [4718.86–5280.87] | 5069.33 [4381.19–5318.88] | +1.97% | 319.89 [300.66–357.19] | 321.48 [300.20–347.93] | +0.50% | 209312 | 213872 | +2.18% |
| event-http-server | — | — | — | — | — | — | 151864 | 156416 | +3.00% |
| https-client | — | — | — | — | — | — | 141088 | 145648 | +3.23% |

## Raw data and reproduction

[Raw samples, commands, sizes, hashes, host provenance and section deltas](measurements/macos-runtime-v0.2.47.json)
are checked in. The CI run additionally retains the binaries and complete stdout,
stderr and build logs for 14 days. The local measurement worktree retains those
artifacts under `build/runtime-lab/{arm64,intel}`.

Run the manual, measurement-only matrix with:

```sh
gh workflow run ci.yml --ref master -f macos_runtime_bench=true
```

The normal Linux/Mac suite jobs are skipped for that opt-in dispatch; their
ordinary push/PR/default-dispatch behavior is unchanged. The harness is
`tools/bench-macos-runtime.sh` plus `tools/bench-macos-runtime.py`.
