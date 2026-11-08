# WebAssembly modules: v0.2.45 to v0.2.51

Measured November 8, 2026 on x86-64 Linux with Node (see the raw record,
[wasm-runtime-v0.2.51.json](measurements/wasm-runtime-v0.2.51.json)). This is the WebAssembly half of the
non-Linux baselines; the macOS half is in [macos-runtime-measurements.md](macos-runtime-measurements.md).

## Results

Every change below is against the release or build named with it, not against one base throughout. Timings are from a
shared machine: the first rounds of a long run are in a slower phase for every version at once (the first five of
25 samples sit about 50% above the rest in the 25-round files), so the medians drop the first fifth of the rounds
and the minimum, over all rounds, is quoted beside them. A difference counts only where median and minimum agree.

**Size.** From v0.2.45 to v0.2.49 the modules are byte-identical in size. v0.2.50 adds 167 to 177 bytes to every
program (+0.6% to +2.6% against v0.2.49, geomean +1.5%); the release holds `913a5999` (write the panic message on
modules that already import the host `write`), the likely cause, not bisected. v0.2.51 adds another 757 bytes
to `trees` (+8.8% against v0.2.50) and 1,080 to `maps` (+6.5%) and nothing to the other six. For `trees` the cause is
`74de74d3` (compare erased floats of one kind as typed `==` does through `any`): it adds a float-bits branch (a
150-line function in the module) to `__ablaRuntimeEqual`, which `x != null` on a class went through. Bisected by
building `trees` with the v0.2.51 compiler and v0.2.51's stdlib with only that branch removed (`vB`), and with the
whole `__ablaRuntimeEqual` back to v0.2.50's (`vA`): both give v0.2.50's 8,598 bytes exactly
([wasm-runtime-trees-bisect.json](measurements/wasm-runtime-trees-bisect.json)). The `maps` growth was not bisected.
Master (8f013949, built with a compiler from that tree) is back to 8,598 bytes for `trees`.

**Run time, `trees`.** Against v0.2.50, in the bisect run: v0.2.51 is +14.3% on the median (1,564 against 1,369 ms) and
+12.8% on the minimum (1,500 against 1,329); `vA` and `vB` are -0.1% and +1.9% on the median and -1.2% and -0.7% on
the minimum. The float branch is the cost. Against v0.2.49 in a 25-round rerun
([wasm-runtime-v0.2.51-rerun-25.json](measurements/wasm-runtime-v0.2.51-rerun-25.json)), v0.2.51 is +10.2% on the
median and +11.7% on the minimum, v0.2.50 -0.6% and -1.0%. In a third run on a busier machine
([wasm-runtime-master-8f013949.json](measurements/wasm-runtime-master-8f013949.json)), master is +0.1% on the median
and -1.7% on the minimum against v0.2.50 while v0.2.51 is +19.9% and +15.1%: master avoids the branch with the native
null test (`runtime-hotspot`), which takes `x != null` off `__ablaRuntimeEqual`.

**Run time, the rest** (first run, against v0.2.45, median and minimum). `maps` is faster by -41.9% and -32.6% at
v0.2.51 (-20.7% and -1.3% at v0.2.50), and its final memory is 5.8% smaller at v0.2.51: the release packs map slots and
reads keys in place. `strings` is faster on the minimum (-17.9%) but not on the median (-1.1%). `dispatch` is +25.1%
on the median at v0.2.51 but +8.7% on the minimum, and +2.6% / +0.1% in the 25-round rerun (against v0.2.49 and
v0.2.50): noise, the ranges overlap. `matrix` and `nbody` show +16.4% and +16.6% medians at v0.2.47 and v0.2.51 with
minimums within 3%: noise. `fib` and `sieve` do not move.

**`any-eq-outline`.** Moving the float branch into a `@noinline` helper, applied to v0.2.51's stdlib and built with the
v0.2.51 compiler (25 rounds, [wasm-runtime-any-eq-outline.json](measurements/wasm-runtime-any-eq-outline.json)), does
not bring Wasm back. `trees` is 9,347 bytes against 9,355 (v0.2.51) and 8,598 (v0.2.50); against v0.2.50 its median is
+12.8% (2,201 against 1,951 ms; v0.2.51: +17.2%) and its minimum +22.8% (v0.2.51: +21.4%). A loop of erased integer
and string equalities (`anyeq`) is 6,004 bytes against 6,005 and 5,802, +4.4% on the median (v0.2.51: +5.7%) and +3.1% on
the minimum (v0.2.51: -4.5%). The median gains a few points, the minimum none; the helper is still reachable, so its
code stays in the module, and the extra tag-2 test stays in the common path. Removing the branch from
`__ablaRuntimeEqual` altogether does restore both (the bisect above).

No optimization was selected: the one regression found is already fixed on master, and the other differences are
inside the machine's noise. Left open: the same measurement on a quiet machine, a `wasm-opt` pass (size),
browser engines, and the other targets (Android, Windows, Wasm WASI).

## Release by release (first run, nine rounds)


### Module size (bytes) (change against v0.2.45)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 10,013 | 10,013 (+0.0%) | 10,013 (+0.0%) | 10,013 (+0.0%) | 10,013 (+0.0%) | 10,187 (+1.7%) | 10,187 (+1.7%) |
| fib | 6,861 | 6,861 (+0.0%) | 6,861 (+0.0%) | 6,861 (+0.0%) | 6,861 (+0.0%) | 7,037 (+2.6%) | 7,037 (+2.6%) |
| maps | 16,473 | 16,473 (+0.0%) | 16,473 (+0.0%) | 16,473 (+0.0%) | 16,473 (+0.0%) | 16,647 (+1.1%) | 17,727 (+7.6%) |
| matrix | 25,842 | 25,842 (+0.0%) | 25,842 (+0.0%) | 25,842 (+0.0%) | 25,842 (+0.0%) | 26,009 (+0.6%) | 26,009 (+0.6%) |
| nbody | 28,619 | 28,619 (+0.0%) | 28,619 (+0.0%) | 28,619 (+0.0%) | 28,619 (+0.0%) | 28,786 (+0.6%) | 28,786 (+0.6%) |
| sieve | 8,947 | 8,947 (+0.0%) | 8,947 (+0.0%) | 8,947 (+0.0%) | 8,947 (+0.0%) | 9,123 (+2.0%) | 9,123 (+2.0%) |
| strings | 11,163 | 11,163 (+0.0%) | 11,163 (+0.0%) | 11,163 (+0.0%) | 11,163 (+0.0%) | 11,337 (+1.6%) | 11,337 (+1.6%) |
| trees | 8,421 | 8,421 (+0.0%) | 8,421 (+0.0%) | 8,421 (+0.0%) | 8,421 (+0.0%) | 8,598 (+2.1%) | 9,355 (+11.1%) |
| **geomean change** |  | +0.00% | +0.00% | +0.00% | +0.00% | +1.52% | +3.41% |

### Gzip size (bytes) (change against v0.2.45)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 4,825 | 4,825 (+0.0%) | 4,825 (+0.0%) | 4,825 (+0.0%) | 4,825 (+0.0%) | 4,958 (+2.8%) | 4,958 (+2.8%) |
| fib | 3,279 | 3,279 (+0.0%) | 3,279 (+0.0%) | 3,279 (+0.0%) | 3,279 (+0.0%) | 3,404 (+3.8%) | 3,404 (+3.8%) |
| maps | 7,214 | 7,214 (+0.0%) | 7,214 (+0.0%) | 7,214 (+0.0%) | 7,214 (+0.0%) | 7,331 (+1.6%) | 7,735 (+7.2%) |
| matrix | 10,838 | 10,838 (+0.0%) | 10,838 (+0.0%) | 10,838 (+0.0%) | 10,838 (+0.0%) | 10,969 (+1.2%) | 10,969 (+1.2%) |
| nbody | 11,319 | 11,319 (+0.0%) | 11,319 (+0.0%) | 11,319 (+0.0%) | 11,319 (+0.0%) | 11,458 (+1.2%) | 11,458 (+1.2%) |
| sieve | 4,335 | 4,335 (+0.0%) | 4,335 (+0.0%) | 4,335 (+0.0%) | 4,335 (+0.0%) | 4,465 (+3.0%) | 4,465 (+3.0%) |
| strings | 5,348 | 5,348 (+0.0%) | 5,348 (+0.0%) | 5,348 (+0.0%) | 5,348 (+0.0%) | 5,481 (+2.5%) | 5,481 (+2.5%) |
| trees | 4,035 | 4,035 (+0.0%) | 4,035 (+0.0%) | 4,035 (+0.0%) | 4,035 (+0.0%) | 4,158 (+3.0%) | 4,509 (+11.7%) |
| **geomean change** |  | +0.00% | +0.00% | +0.00% | +0.00% | +2.39% | +4.13% |

### Median run time (ms), first 20% of the rounds dropped (change against v0.2.45)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 288 | 296 (+2.6%) | 307 (+6.4%) | 308 (+6.8%) | 290 (+0.6%) | 333 (+15.4%) | 360 (+25.1%) |
| fib | 896 | 889 (-0.8%) | 893 (-0.3%) | 897 (+0.1%) | 903 (+0.8%) | 898 (+0.2%) | 883 (-1.5%) |
| maps | 612 | 606 (-1.0%) | 521 (-14.9%) | 574 (-6.3%) | 458 (-25.2%) | 486 (-20.7%) | 356 (-41.9%) |
| matrix | 793 | 880 (+10.9%) | 923 (+16.4%) | 712 (-10.3%) | 707 (-10.8%) | 713 (-10.2%) | 724 (-8.7%) |
| nbody | 1,878 | 1,840 (-2.1%) | 1,880 (+0.1%) | 1,866 (-0.6%) | 1,888 (+0.5%) | 1,885 (+0.3%) | 2,190 (+16.6%) |
| sieve | 911 | 901 (-1.0%) | 909 (-0.2%) | 905 (-0.6%) | 913 (+0.3%) | 932 (+2.4%) | 902 (-1.0%) |
| strings | 407 | 413 (+1.6%) | 409 (+0.5%) | 401 (-1.4%) | 417 (+2.5%) | 423 (+3.9%) | 402 (-1.1%) |
| trees | 2,211 | 2,168 (-1.9%) | 2,143 (-3.1%) | 2,143 (-3.1%) | 2,157 (-2.4%) | 2,190 (-0.9%) | 2,518 (+13.9%) |
| **geomean change** |  | +0.96% | +0.26% | -2.03% | -4.68% | -1.71% | -2.03% |

### Minimum run time (ms) (change against v0.2.45)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 278 | 277 (-0.4%) | 277 (-0.5%) | 279 (+0.4%) | 280 (+0.4%) | 279 (+0.2%) | 303 (+8.7%) |
| fib | 870 | 850 (-2.2%) | 873 (+0.4%) | 860 (-1.1%) | 865 (-0.5%) | 871 (+0.2%) | 847 (-2.7%) |
| maps | 358 | 349 (-2.6%) | 342 (-4.5%) | 386 (+7.7%) | 349 (-2.7%) | 354 (-1.3%) | 241 (-32.6%) |
| matrix | 622 | 602 (-3.3%) | 617 (-0.8%) | 610 (-1.9%) | 608 (-2.2%) | 611 (-1.7%) | 605 (-2.7%) |
| nbody | 1,063 | 1,077 (+1.3%) | 1,068 (+0.5%) | 1,064 (+0.1%) | 1,065 (+0.2%) | 1,074 (+1.0%) | 1,067 (+0.4%) |
| sieve | 858 | 861 (+0.5%) | 880 (+2.7%) | 856 (-0.1%) | 877 (+2.2%) | 910 (+6.1%) | 874 (+1.9%) |
| strings | 339 | 291 (-14.1%) | 316 (-6.7%) | 300 (-11.6%) | 284 (-16.2%) | 271 (-20.2%) | 278 (-17.9%) |
| trees | 1,997 | 1,948 (-2.5%) | 2,070 (+3.7%) | 2,077 (+4.0%) | 2,094 (+4.8%) | 1,889 (-5.4%) | 2,345 (+17.4%) |
| **geomean change** |  | -3.02% | -0.74% | -0.46% | -1.93% | -2.94% | -4.64% |

### Peak linear memory (bytes) (change against v0.2.45)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 2,162,688 | 2,162,688 (+0.0%) | 2,162,688 (+0.0%) | 2,162,688 (+0.0%) | 2,162,688 (+0.0%) | 2,162,688 (+0.0%) | 2,162,688 (+0.0%) |
| fib | 1,114,112 | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) |
| maps | 290,914,304 | 290,914,304 (+0.0%) | 290,914,304 (+0.0%) | 290,914,304 (+0.0%) | 290,914,304 (+0.0%) | 290,914,304 (+0.0%) | 274,137,088 (-5.8%) |
| matrix | 9,502,720 | 9,502,720 (+0.0%) | 9,502,720 (+0.0%) | 9,502,720 (+0.0%) | 9,502,720 (+0.0%) | 9,502,720 (+0.0%) | 9,502,720 (+0.0%) |
| nbody | 1,114,112 | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) | 1,114,112 (+0.0%) |
| sieve | 858,521,600 | 858,521,600 (+0.0%) | 858,521,600 (+0.0%) | 858,521,600 (+0.0%) | 858,521,600 (+0.0%) | 858,521,600 (+0.0%) | 858,521,600 (+0.0%) |
| strings | 445,775,872 | 445,775,872 (+0.0%) | 445,775,872 (+0.0%) | 445,775,872 (+0.0%) | 445,775,872 (+0.0%) | 445,775,872 (+0.0%) | 445,775,872 (+0.0%) |
| trees | 2,706,833,408 | 2,706,833,408 (+0.0%) | 2,706,833,408 (+0.0%) | 2,706,833,408 (+0.0%) | 2,706,833,408 (+0.0%) | 2,706,833,408 (+0.0%) | 2,706,833,408 (+0.0%) |
| **geomean change** |  | +0.00% | +0.00% | +0.00% | +0.00% | +0.00% | -0.74% |

### Run-time ranges (min to max, ms)

| program | v0.2.45 | v0.2.46 | v0.2.47 | v0.2.48 | v0.2.49 | v0.2.50 | v0.2.51 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dispatch | 278 to 401 | 277 to 479 | 277 to 354 | 279 to 386 | 280 to 380 | 279 to 420 | 303 to 423 |
| fib | 870 to 1,042 | 850 to 931 | 873 to 973 | 860 to 933 | 865 to 1,018 | 871 to 1,101 | 847 to 918 |
| maps | 358 to 727 | 349 to 666 | 342 to 746 | 386 to 738 | 349 to 674 | 354 to 691 | 241 to 507 |
| matrix | 622 to 1,387 | 602 to 1,136 | 617 to 1,180 | 610 to 1,079 | 608 to 874 | 611 to 1,200 | 605 to 1,491 |
| nbody | 1,063 to 1,920 | 1,077 to 1,984 | 1,068 to 2,003 | 1,064 to 2,121 | 1,065 to 1,977 | 1,074 to 2,651 | 1,067 to 2,673 |
| sieve | 858 to 1,435 | 861 to 1,440 | 880 to 1,424 | 856 to 1,516 | 877 to 1,424 | 910 to 1,374 | 874 to 1,414 |
| strings | 339 to 466 | 291 to 467 | 316 to 458 | 300 to 462 | 284 to 473 | 271 to 490 | 278 to 465 |
| trees | 1,997 to 2,249 | 1,948 to 2,214 | 2,070 to 2,516 | 2,077 to 2,338 | 2,094 to 2,505 | 1,889 to 2,350 | 2,345 to 3,031 |

Outputs identical across versions: yes

## Method and limits

- Each release compiler (`ablac-x86_64-linux` of v0.2.45 to v0.2.51, checksum-verified) builds against **its own
  release-tag stdlib** (`ABLA_SYSROOT`), the same way the macOS measurement does.
- The programs are the eight of `tests/benchmarks/perf` (fib, sieve, nbody, trees, strings, maps, dispatch,
  matrix), unchanged between the releases. Each is built as a release `wasm32-module` through
  `#wasmBuildModule` in a small driver, with `--no-cache`. The programs that read files, sockets or the clock
  for output (the JSON ones, websocket-codec, the servers) are left out: a bare module has only the
  `abla_host` imports.
- [tools/wasm-bench/run.mjs](../tools/wasm-bench/run.mjs) instantiates a module with the four `abla_host`
  imports and nothing else, calls `main`, and reports the run time of that call (instantiation apart), the
  program's output and the final size of its linear memory (its peak, memory never shrinks).
- One round is not kept as a warmup (`bench.py run --warmup N`; the first run's JSON files used one), then nine
  (first run) or 25 fresh Node processes per version, pinned to one CPU, with the order of versions alternating each
  round. Every sample is kept. `report.py --skip 0.2` drops the first fifth of them before taking the median, because
  the early rounds of a long run on this shared machine are a slower phase for every version; the minimum and the
  min-to-max range use all of them. Judge a difference by median and minimum together.
- The program's output must be the same in every round and in every version; a mismatch aborts `bench.py run`
  (the first run's files were checked across versions and on each version's first round only).
- Size is exact (one deterministic build) and is the module as built, with no `wasm-opt` pass.

Reproduce with `tools/wasm-bench/bench.py build RELEASES OUT`, then `bench.py run OUT --json result.json`
and `report.py result.json --skip 0.2` (see their headers).
