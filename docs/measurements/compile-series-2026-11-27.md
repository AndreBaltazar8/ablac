# Compile cost across releases (2026-11-27)

Cold builds with each release's published Linux toolchain, from v0.2.50 to master
3045428c2 (between v0.2.78 and v0.2.79), measured on 2026-11-27 for #1204.

Method: user instructions (`perf stat -e instructions:u`, the `cpu_atom` count) on one
E-core (CPU 25) of an i9-13900K, Linux 6.17.3, each build in a fresh cache; wall time
beside it. Every version runs in the same FHS environment, so the wrapper's overhead is the
same for all. `hello` and `json` are a hello world and a JSON program; `self` is the
release's own compiler built from its own sources (a newer compiler can't build an old
release's sources, so the input differs per release; `G/kline` divides by its source lines).

| version | release hello | release json | `--fast` hello | `--fast` json | self | self G/kline |
|---|--:|--:|--:|--:|--:|--:|
| v0.2.50 | 1.593 G, 0.44 s | 7.752 G, 1.87 s | 1.219 G, 0.37 s | 3.487 G, 0.84 s | 709.4 G, 143.9 s | 6.339 |
| v0.2.55 | 1.838 G, 0.53 s | 7.869 G, 2.04 s | 1.315 G, 0.34 s | 3.492 G, 0.82 s | 719.8 G, 152.1 s | 6.302 |
| v0.2.60 | 2.869 G, 0.63 s | 9.297 G, 1.97 s | 1.960 G, 0.56 s | 4.502 G, 1.07 s | 776.4 G, 162.9 s | 6.384 |
| v0.2.65 | 3.085 G, 0.62 s | 10.430 G, 2.18 s | 2.121 G, 0.42 s | 5.406 G, 1.10 s | 892.2 G, 181.9 s | 6.394 |
| v0.2.66 | 3.235 G, 0.64 s | 11.342 G, 2.58 s | 2.118 G, 0.39 s | 5.422 G, 1.20 s | | |
| v0.2.67 | 2.917 G, 0.59 s | 10.523 G, 2.21 s | 4.723 G, 0.89 s | 7.953 G, 1.47 s | | |
| v0.2.70 | 2.897 G, 0.55 s | 11.378 G, 2.38 s | 4.640 G, 0.83 s | 7.876 G, 1.41 s | | |
| v0.2.74 | 2.862 G, 0.58 s | 11.370 G, 2.59 s | 4.577 G, 0.88 s | 7.811 G, 1.46 s | | |
| v0.2.77 | 2.857 G, 0.54 s | 11.367 G, 2.31 s | 4.569 G, 0.82 s | 7.804 G, 1.47 s | | |
| v0.2.78 | 2.858 G, 0.66 s | 11.369 G, 2.90 s | 4.569 G, 1.05 s | 7.806 G, 1.79 s | | |
| 3045428c2 | 2.838 G, 0.53 s | 11.373 G, 2.28 s | 4.525 G, 0.87 s | 7.799 G, 1.51 s | | |

What the series shows:

- From v0.2.70 to master the instruction counts are flat (within 1.4%). Wall time moved by
  up to 29% between v0.2.77 and v0.2.78 with no change in instructions: it follows the
  machine's load, not the compiler.
- A cold `--fast` build doubled at v0.2.67, when the `--fast` runtime became a prebuilt
  object that a new cache compiles once (later `--fast` builds in that cache are cheaper
  than before). From v0.2.80 the Linux toolchain ships that object: in a fresh cache,
  `--fast` hello went from 5.59 G to 1.80 G instructions and the JSON program from 9.39 G
  to 5.48 G (default debug information, E-core, ed0b2dc19).
- Release cold builds grew from v0.2.52 to v0.2.66 with the host runtime that every
  program compiles from source (1,845 to 5,969 lines: the libc-free runtime, the macOS
  dispatcher, the collector's registry).
- Self-build cost per source line rose 3.4% from v0.2.50 to master of 2026-11-26.
