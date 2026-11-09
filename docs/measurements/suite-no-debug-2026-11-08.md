# The suite without DWARF line tables, 2026-11-08

`tools/run-tests.sh` exports `ABLA_DEBUG=0` (unless the caller sets `ABLA_DEBUG`), so the suite's `--fast`
builds carry no DWARF line tables: a `--fast` build's debug information is 7% to 9% of its compile time
(`native-fast-screen-2026-11-08.md`). `RUN_TESTS_DEBUG=default` leaves `ABLA_DEBUG` unset, which is how the
suite ran before (`--fast` builds with debug information, release builds without); `RUN_TESTS_DEBUG=1` sets
`ABLA_DEBUG=1` for every build.

## Total suite CPU

`tools/run-tests.sh build/ablac` at `JOBS=8` pinned to CPUs 0-7, inside the full-test and build slots, from an empty
build cache each time, master `377d2f1a` plus this change, alternating default and `ABLA_DEBUG=0`. The CPU
column of `results.tsv` summed over the 310 commands; all 310 passed in every run.

| Run | default | `ABLA_DEBUG=0` | change |
|---|---:|---:|---:|
| pair A | 1,974.4 CPU-s (272 s wall) | 1,845.8 (258 s) | −6.5% |
| pair B | 2,289.5 (335 s) | 1,901.5 (258 s) | −16.9% |
| mean of the two | 2,131.9 | 1,873.7 | −12.1% |

The default runs differ by 16% between themselves (the machine was loaded during the second: CPU-seconds of a
command include waiting on shared caches), the `ABLA_DEBUG=0` runs by 3%. Against the quieter default run alone
the mean of the two candidate runs is −5.1%; the per-command median over the commands above 5 CPU-s is
−7.2% (pair A) and −19.0% (pair B). The bar (at least 5% less total suite CPU, all tests passing) is met on these two pairs;
the two pairs below qualify that.

### Two more pairs (master `0a541fcc` plus this change, 317 commands)

The first two pairs ran at different loads, so two more were run back to back (`ABLA_DEBUG=0`, default,
`ABLA_DEBUG=0`, default), same method, all 317 commands passing:

| Run | default | `ABLA_DEBUG=0` | change |
|---|---:|---:|---:|
| pair C | 1,843.6 (291 s wall) | 1,768.2 (242 s) | −4.1% |
| pair D | 1,884.4 | 1,881.3 | −0.2% |

Single scripts swing by 40 CPU-s between runs of the same configuration (`test-reproducible-elsewhere.sh`:
103 and 64 CPU-s in the default runs of pairs A and D), so no one pair is reliable. Over all four pairs (the 309
commands present in every run): the mean total is 1,956.6 default against 1,810.7 (−7.5%); the sum of per-command
medians is 1,899.3 against 1,801.1 (−5.2%); the median of the four totals is 1,888.2 against 1,824.8 (−3.4%).
The saving is real and concentrated in the compile-heavy scripts (`test-self-hosted.sh`,
`test-global-initializer-split.sh`, `test-ct.sh`, each 5% to 30%), but on the quietest readings it is 3% to 5%:
the 5% bar is met by the mean and the per-command median, not by the median of totals.

## What keeps debug information, and why

Run with `ABLA_DEBUG=0` on master the suite failed three scripts; each keeps debug information by itself:

| Script | How | Why |
|---|---|---|
| `tools/test-programmable-build.sh` | `export ABLA_DEBUG=1` | its ABI checks grep the readable function symbols of the kept `.ll` (`@abla_scalar_next = alias ...`), which a build has only with debug information |
| `tools/test-wasm-debug-reproducible.sh` | `export ABLA_DEBUG=1` | it compares the source map and the DWARF module of a development Wasm build, which exist only with debug information |
| `tools/test-ct.sh` | `-g` on the `--fast` object it reads | the checker reads that object for secret branches; without debug information the fast code differs and `ct_fix_arithmetic_u32` reports a branch (release builds in the script stay without) |

Scripts that already build with an explicit `-g` or `--debug` are unaffected: `test-codegen-units.sh`,
`test-generics.sh` (llvm-dwarfdump and llvm-symbolizer checks), `test-simd.sh`, `test-uint256.sh`,
`test-runtime-checks.sh`; `test-project-path-symbols.py` builds with `--no-debug` itself. The test driver needed no
change: it inherits the environment, and no driver entry read debug information.
