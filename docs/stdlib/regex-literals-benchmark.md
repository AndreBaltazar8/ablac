# Regex literal runtime comparison

Local compiler source: `259e3a9ad526532b4840feab133a58828af1f742`, based on
`c2e0a4b2`. Compiler binary SHA-256:
`35b68cb4ff8999f9d54b54e1b1c37a530b0214ccd04ebdfc092067a216fd263d`.
Host: Intel Core i9-13900K; all measured processes pinned to CPU 8 on a shared host.

```sh
LC_ALL=C taskset -c 8 tools/bench-regex-literals.sh build/ablac 100000
```

The script builds one release executable and runs each mode five times, alternating
mode order. Each run performs 100,000 whole-text matches against `([a-z]+)-(\d+)`,
alternating `item-123` and `no match`. All 15 runs produced the checked count of
50,000 matches. Times are wall seconds including process startup.

| Mode | Five runs (seconds) | Median |
|---|---|---|
| Compile the string on each iteration | 0.466, 0.452, 0.452, 0.449, 0.435 | 0.452 |
| Reuse `$regex` | 0.138, 0.141, 0.147, 0.141, 0.147 | 0.141 |
| Reuse a runtime-compiled matcher | 0.136, 0.136, 0.144, 0.144, 0.146 | 0.144 |

Literal reuse was about **3.2 times faster than repeated compilation** in this
case. Cached runtime matching had overlapping timings. All modes use the same
Pike VM. For comparable startup work, every mode compiles the runtime pattern
once during common setup; only the first mode repeats that work inside the loop.
This comparison measures reuse and repeated compilation, with no performance
threshold in the test suite.

Raw samples are written to `build/bench-regex-literals/times.tsv`. The release
benchmark build and all 15 output checks passed.

Compiler validation: **8 focused commands passed, 0 failed**, using:

```text
test-regex|test-syntax-compile|test-subparser-named-arguments|test-compile-time-diagnostics|test-ct-bridge
```

The new tests cover exact error messages and source positions, numbered and
optional captures, Unicode, GC stress, release builds, distinct frozen sites,
and interpreter/JIT/bridge parity. The builder test also requires its explicit
`#` probe to execute natively under JIT. The full suite is outside this focused
validation.
