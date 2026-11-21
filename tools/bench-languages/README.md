# Manual language benchmark lab

Run from an isolated ablac worktree:

```sh
tools/bench-languages/run --output build/language-smoke --compiler build/gate/stage2 --smoke
tools/bench-languages/run --output build/language-results --compiler build/gate/stage2
```

The runner re-enters `shell.nix` here. It imports the repository's SHA-256-verified
nixpkgs revision, providing GCC, Rust, Go, Zig 0.14, GNU time, jq, json-c, PCRE2
and oha. Abla is the explicitly selected compiler, recorded by version and SHA-256,
using this worktree's stdlib. This is a **manual lab**, with no per-push CI hookup.
Use a new output directory each time. `--help` lists filtering and smoke options.
C is always required. Missing tools, build failures, wrong outputs or failed HTTP
requests abort the run and leave `raw.json` marked failed; no success ratios are
emitted. Interrupted processes leave logs and samples; there is no resume mode.

The runner is shell; the clock/child-process helper is Abla. One helper measures
monotonic elapsed time around fork/exec/wait, redirecting output directly to files.
No Python or Node is needed. The helper is built outside compile samples. Each
program queues on the shared fair-flock build slot (`BENCH_SLOT=4`), retains its
lease for that program's builds/runs, and releases it before the next program.
Each hold is capped at 600 seconds; a cap failure aborts the result instead of
publishing incomplete ratios. It uses a fixed CPU (`BENCH_CPU=24`). Queue time is outside the clock. The host
remains shared: there is no isolated-core, fixed-frequency or cold-page-cache claim.
Do not wrap an entire long run in a shared-slot lease; each program releases it.
Run long sessions under a user systemd unit so they survive an agent turn.

## Workloads

The six scalar tasks follow the [Benchmarks Game task definitions](https://benchmarksgame-team.pages.debian.net/benchmarksgame/description/summary.html).
These are independently written matching scalar algorithms, **not** a comparison
against that site's fastest threaded/SIMD entries. Compiler auto-vectorization is
allowed; target-native flags, fast-math and explicit parallelism are not used.

| Task | Full input | Operation and output check |
|---|---:|---|
| binary-trees | depth 18 | Stretch depth 19, retained depth 18, ephemeral trees at even depths 4–18; recursive make/check; exact depth/iteration/check totals. C/Zig free each tree; Rust drops; Abla/Go collect. |
| fannkuch | 11 | Sequential rotation/count permutation enumeration, prefix flips, alternating checksum and maximum. Same scratch-copy algorithm. |
| n-body | 5,000,000 | Canonical Sun/Jupiter/Saturn/Uranus/Neptune constants, offset momentum, pairwise velocity updates then positions, dt=0.01; initial/final energy. |
| spectral-norm | 1500 | Implicit A(i,j), 10 alternating A-transpose-A power iterations, 64-bit floats, final sqrt(u.v/v.v). |
| mandelbrot | 2000 | Scalar 50-step escape test, mapped [-1.5,0.5] × [-1,1], complete PBM output including partial-byte padding. |
| fasta | 1,000,000 | Repeat ALU 2n, LCG seed 42/modulus 139968 with cumulative IUB and human probabilities for 3n/5n; 60-column output. |
| json | 100 iterations | Read fixed 2048-object input once, parse generic DOM and serialize on every iteration; output final full JSON. Escaped strings, arrays, nulls, booleans and integers; sorted-key canonical comparison against original fixture. |
| regex-redux | fixed 500k-base FASTA | Compile strip expression, nine alternative 8-mer expressions, five sequential replacement expressions; exact counts and lengths. Independent deterministic fixture includes all IUB symbols. |
| http-echo | 10,000 requests | One blocking server worker, fresh HTTP/1.1 connection, fixed 256-byte POST body, no keepalive, pinned oha concurrency 1. |
| hello | 100 starts/sample | Print hello and exit; measure batch time per process without GNU-time wrapper. |

JSON and regex are **library-dependent**, not pure language/codegen comparisons.
C, Rust and Zig use the same pinned json-c and non-JIT PCRE2 via their own FFI calls;
Abla uses abla/json and abla/regex, Go uses encoding/json and regexp. The high-level
operation is matched; engines and allocation policies differ. HTTP is a deliberately
minimal fixed-body protocol on loopback, not a general parser or production server.
All implementations receive the same payload and use the same accept/read/write/
close algorithm. Go's runtime can use helper threads; GOMAXPROCS=1 during runtime.

Floating text is compared with absolute plus relative 1e-8 tolerance; finite numeric
syntax and output line counts are checked. JSON compares sorted-key canonical values.
All other complete outputs compare byte for byte, including binary PBM. Validation
runs before timing and again on every measured finite workload. HTTP verifies body
bytes with curl before and after load, plus timed success/error/status/total-byte
counts from oha; it does not hash each response body inside the timed client.

## Metrics and limits

One warmup per arm, five runtime samples in rotating language order. Three compile
samples per arm rotate order too; target and language caches are fresh each time.
Go's cold GOCACHE rebuilds standard library packages, Zig's private caches rebuild
compiler-rt; preinstalled libraries shipped by each compiler remain available.
These are end-to-end cold-output builds, not frontend-only times. Commands are in
`build-one.sh` and copied into the result logs. Binaries are optimized portable
builds, executed unstripped; both raw and stripped file bytes are reported. Shared
library/dependency closure sizes are **excluded**, so linked sizes alone do not
represent distribution size. Abla retains its normal libc-free defaults.

Runtime wall includes the GNU-time launcher plus child process; the per-child GNU
time RSS excludes the Abla measurement helper. Hello startup is measured separately
without GNU time, including Abla's command construction, fork, exec and wait cost.
It measures warm process launch, not cold-disk startup or time to first byte. HTTP
uses oha's measured duration/rate and the server's live `/proc/PID/status` VmHWM.
KiB RSS is converted to bytes. A zero RSS observation means unavailable/below tool
resolution, not a zero-memory claim; ratios with a zero C denominator are null.

`results.json` has schemaVersion=1, metadata, samples and
`programs[task].languages[language]`. Each verified row has wallSeconds, rssBytes,
compileSeconds `{median,min,max}`, rawBytes, strippedBytes and ratiosToC. Hello adds
startupSeconds; HTTP adds requestsPerSecond, with corresponding ratiosToC fields.
Raw samples, source/binary hashes,
compiler version/hash, Nix pin, tool paths, CPU details and pre-acquisition load
are retained. Min/max ranges and raw data matter more than a single ratio on this
busy host. `report.md` includes ratios **language/C** (smaller is less time/space),
with a geometric mean over the six scalar CPU rows only. JSON, regex, startup and
HTTP never enter that geometric mean. Do not interpret a smoke run as performance
evidence: it only proves that build, execution, validation and reporting connect.

The first completed local baseline is archived in
[the c2e0a4b2 report](../../docs/measurements/languages-c2e0a4b2.md), with all raw
samples and provenance. It predates batch EF and v0.2.65; its locally rebuilt
compiler reporting 0.2.64 is identified by source commit and binary hash.

## Additional measurements

Select `--programs string-build` to measure building one 3,200,000-byte string
from 200,000 alternating 16-byte lines (101 lines in smoke runs). Each program
grows its output incrementally and writes the finished bytes, which the runner
compares in full. Abla uses string concatenation. C, Rust, Go and Zig use growing
buffers. This measures the language-level construction strategies and is outside
the historical six-task geometric mean. The default ten-workload selection
remains comparable to the c2e0a4b2 baseline. Regex-heavy coverage is already in
the default selection as regex-redux.

Compare matched Linux x86-64 static and dynamic compiler artifacts like this:

```sh
tools/bench-languages/compiler-hello build/compiler-hello /path/to/static/ablac /path/to/dynamic/ablac
```

Use both artifacts from the same release or source build. The dynamic compiler's
loader and libraries must already be available. The runner verifies linkage,
records compiler hashes and uses this checkout as the common sysroot. It warms
each compiler once, then records 12 counterbalanced pairs of fresh, no-cache
release builds of the same hello program on one pinned CPU. It verifies the
result of every build outside the timed interval. Wall time covers process
launch, compilation and linking with warm OS caches. The compiler comparison
includes any linker difference between artifacts. The JSON summary reports a
static/dynamic ratio of median wall times, with raw samples beside it.
