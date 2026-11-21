# Abla language benchmarks

This is a local baseline of compiler/stdlib commit `c2e0a4b24fc10c3c9f08204330410ef4383a55c1`.
The locally rebuilt compiler reports `0.2.64`; it is **not the published v0.2.64 compiler, batch EF, or v0.2.65**.
The workload and measurement code is commit `3df33704e620df027195652305ce5dc1bfb0d6d6`;
report-only postprocessing is commit `911fce40f01de69079fe2bedf00545bcefde8da3`.
Hardware: Intel Core i9-13900K, Linux x86-64, CPU 8 (P-core), one pinned CPU.
The host was shared; no core/frequency isolation is claimed.

[All raw samples and full-precision statistics](languages-c2e0a4b2.json),
[measurement-source hashes](languages-c2e0a4b2.sources.sha256),
[input hashes](languages-c2e0a4b2.inputs.sha256),
[tool store paths](languages-c2e0a4b2.tools.txt).
The complete local binaries, outputs, build logs, load measurements and CPU information
remain in `.claude/worktrees/cx2-benchmarks/build/language-full4/`.
Inputs are generated deterministically by the committed runner.

The run completed 150 cold builds, 250 runtime samples, 50 size measurements and
25 startup batches (100 process launches each): 475 records. All ten Abla binaries
have no dynamic `NEEDED` libraries. The scalar CPU mean excludes JSON, regex, HTTP
and startup. Notable resource observations: Abla peak RSS was 258.7 MiB for trees,
137.6 MiB for JSON, and 31.0 MiB for HTTP; C was 34.1, 5.3 and 1.9 MiB respectively.
JSON/regex are comparisons of library paths, with the engines and allocation
policies described below.

Measurement source `3df33704e620df027195652305ce5dc1bfb0d6d6`. Smoke: false. CPU 8, 5 runtime samples and 3 cold builds per language. Status: complete.

Toolchains: c: gcc (GCC) 16.2.0; rust: rustc 1.98.1 (48a229cea 2026-09-01) (built from a source tarball); go: go version go1.26.8 linux/amd64; zig: 0.14.1; abla: ablac 0.2.64; oha: oha 1.16.0.

Nixpkgs: `6510408d147d8c5e6d76043e899e9251756f6a75`. Abla compiler SHA-256: `640aabb5948d5595345f6be117b854c747095d3433481279d33e9c3645700663`.

Ratios are language / C; smaller is less time/memory/size. Finite-workload wall seconds include the GNU-time launcher. Startup excludes that launcher and includes fork/exec/wait overhead; HTTP uses oha elapsed time. These are measurements on a shared machine, not isolated hardware.

| Program | Language | Wall s | /C | RSS MiB | /C | Stripped bytes | /C | Compile s | /C |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| binary-trees | c | 0.916444 | 1 | 34.148 | 1 | 18448 | 1 | 0.221 | 1 |
| binary-trees | abla | 2.019894 | 2.204 | 258.738 | 7.577 | 25824 | 1.4 | 0.681 | 3.088 |
| binary-trees | rust | 1.330932 | 1.452 | 33.93 | 0.994 | 402232 | 21.804 | 0.242 | 1.099 |
| binary-trees | go | 1.778533 | 1.941 | 45.195 | 1.323 | 1601176 | 86.794 | 6.242 | 28.29 |
| binary-trees | zig | 1.078878 | 1.177 | 33.902 | 0.993 | 197296 | 10.695 | 6.021 | 27.29 |
| fannkuch | c | 1.368758 | 1 | 2.027 | 1 | 14352 | 1 | 0.167 | 1 |
| fannkuch | abla | 2.704927 | 1.976 | 0.25 | 0.123 | 28528 | 1.988 | 0.867 | 5.194 |
| fannkuch | rust | 1.780279 | 1.301 | 2.02 | 0.996 | 406328 | 28.312 | 0.275 | 1.651 |
| fannkuch | go | 1.640207 | 1.198 | 2.219 | 1.094 | 1597080 | 111.279 | 6.459 | 38.71 |
| fannkuch | zig | 1.555274 | 1.136 | 1.527 | 0.753 | 13536 | 0.943 | 2.556 | 15.319 |
| fasta | c | 0.085446 | 1 | 2.031 | 1 | 14360 | 1 | 0.143 | 1 |
| fasta | abla | 0.161674 | 1.892 | 23.203 | 11.423 | 35664 | 2.484 | 0.786 | 5.516 |
| fasta | rust | 0.088038 | 1.03 | 2.063 | 1.015 | 406328 | 28.296 | 0.246 | 1.727 |
| fasta | go | 0.107715 | 1.261 | 2.215 | 1.09 | 1592984 | 110.932 | 5.731 | 40.219 |
| fasta | zig | 0.102879 | 1.204 | 1.27 | 0.625 | 14120 | 0.983 | 2.077 | 14.578 |
| hello | c | 0.000706 | 1 | 1.77 | 1 | 14352 | 1 | 0.114 | 1 |
| hello | abla | 0.000555 | 0.786 | 0.25 | 0.141 | 20960 | 1.46 | 0.385 | 3.379 |
| hello | rust | 0.000789 | 1.119 | 2.027 | 1.146 | 398136 | 27.741 | 0.151 | 1.321 |
| hello | go | 0.00109 | 1.545 | 1.961 | 1.108 | 1584728 | 110.419 | 5.555 | 48.731 |
| hello | zig | 0.000637 | 0.902 | 1.266 | 0.715 | 4888 | 0.341 | 1.905 | 16.711 |
| http-echo | c | 0.281761 | 1 | 1.945 | 1 | 14352 | 1 | 0.135 | 1 |
| http-echo | abla | 0.285259 | 1.012 | 31.035 | 15.954 | 32896 | 2.292 | 0.642 | 4.769 |
| http-echo | rust | 0.281528 | 0.999 | 2.184 | 1.122 | 414520 | 28.882 | 0.221 | 1.638 |
| http-echo | go | 0.276246 | 0.98 | 7.383 | 3.795 | 2038168 | 142.013 | 5.934 | 44.077 |
| http-echo | zig | 0.283217 | 1.005 | 1.426 | 0.733 | 12640 | 0.881 | 2.096 | 15.567 |
| json | c | 0.257584 | 1 | 5.281 | 1 | 14352 | 1 | 0.129 | 1 |
| json | abla | 0.251627 | 0.977 | 137.578 | 26.05 | 80576 | 5.614 | 1.268 | 9.841 |
| json | rust | 0.258358 | 1.003 | 5.867 | 1.111 | 422728 | 29.454 | 0.234 | 1.814 |
| json | go | 0.328087 | 1.274 | 7.844 | 1.485 | 2092408 | 145.792 | 6.216 | 48.231 |
| json | zig | 0.257206 | 0.999 | 5.324 | 1.008 | 21880 | 1.525 | 2.162 | 16.776 |
| mandelbrot | c | 0.155881 | 1 | 2.023 | 1 | 14352 | 1 | 0.134 | 1 |
| mandelbrot | abla | 0.15878 | 1.019 | 2.109 | 1.042 | 32688 | 2.278 | 0.767 | 5.711 |
| mandelbrot | rust | 0.163155 | 1.047 | 2.109 | 1.042 | 406328 | 28.312 | 0.251 | 1.866 |
| mandelbrot | go | 0.160821 | 1.032 | 2.223 | 1.098 | 1601176 | 111.565 | 5.771 | 42.977 |
| mandelbrot | zig | 0.158473 | 1.017 | 1.527 | 0.755 | 13216 | 0.921 | 2.085 | 15.529 |
| n-body | c | 0.144164 | 1 | 2.027 | 1 | 14648 | 1 | 0.175 | 1 |
| n-body | abla | 0.459509 | 3.187 | 0.25 | 0.123 | 52288 | 3.57 | 1.041 | 5.934 |
| n-body | rust | 0.113389 | 0.787 | 2.012 | 0.992 | 435000 | 29.697 | 0.245 | 1.396 |
| n-body | go | 0.247379 | 1.716 | 2.223 | 1.096 | 1601176 | 109.31 | 6.256 | 35.655 |
| n-body | zig | 0.117153 | 0.813 | 1.523 | 0.751 | 17064 | 1.165 | 2.344 | 13.36 |
| regex-redux | c | 0.089814 | 1 | 4.613 | 1 | 14432 | 1 | 0.141 | 1 |
| regex-redux | abla | 0.19069 | 2.123 | 25.547 | 5.538 | 92664 | 6.421 | 1.135 | 8.064 |
| regex-redux | rust | 0.089024 | 0.991 | 4.422 | 0.959 | 410424 | 28.438 | 0.23 | 1.632 |
| regex-redux | go | 0.21451 | 2.388 | 7.391 | 1.602 | 1991960 | 138.024 | 5.794 | 41.154 |
| regex-redux | zig | 0.089831 | 1 | 4.547 | 0.986 | 208952 | 14.478 | 5.303 | 37.669 |
| spectral-norm | c | 0.054522 | 1 | 2.016 | 1 | 14352 | 1 | 0.179 | 1 |
| spectral-norm | abla | 0.073117 | 1.341 | 0.25 | 0.124 | 46848 | 3.264 | 0.918 | 5.144 |
| spectral-norm | rust | 0.066934 | 1.228 | 2.09 | 1.037 | 430904 | 30.024 | 0.249 | 1.392 |
| spectral-norm | go | 0.067247 | 1.233 | 2.219 | 1.101 | 1597080 | 111.279 | 6.023 | 33.74 |
| spectral-norm | zig | 0.06663 | 1.222 | 1.785 | 0.886 | 198848 | 13.855 | 5.938 | 33.265 |

CPU-workload geometric means (binary-trees, fannkuch, n-body, spectral-norm, mandelbrot, fasta only):

- abla: 1.816x C (6 workloads)
- c: 1x C (6 workloads)
- go: 1.363x C (6 workloads)
- rust: 1.119x C (6 workloads)
- zig: 1.084x C (6 workloads)

Startup milliseconds per hello process (batch median, includes process-launch overhead):

| Language | ms | /C |
|---|---:|---:|
| abla | 0.158 | 0.504 |
| c | 0.313 | 1 |
| go | 0.533 | 1.703 |
| rust | 0.376 | 1.201 |
| zig | 0.273 | 0.872 |

HTTP requests/second (one blocking server, concurrency 1, fresh connection per request; a larger throughput ratio is faster):

| Language | requests/s | /C |
|---|---:|---:|
| abla | 35056 | 0.988 |
| c | 35491 | 1 |
| go | 36200 | 1.02 |
| rust | 35520 | 1.001 |
| zig | 35309 | 0.995 |

JSON and regex compare library paths: json-c/PCRE2 via FFI in C, Rust and Zig; native libraries in Abla and Go. JSON values are compared after key-order canonicalization. Floating outputs allow absolute + relative tolerance 1e-8. All other complete outputs match byte for byte. HTTP checks echo bytes before/after load and timed response counts/length/status.

RSS is child GNU-time peak RSS (KiB converted to bytes), or live server VmHWM for HTTP. Zero means unavailable, never a zero-memory claim. Binary sizes exclude shared-library closures. Compile time uses fresh application and Go/Zig caches; preinstalled toolchain libraries and OS page cache remain warm. Min/max, individual samples, commands, source/binary hashes, tool paths, versions, CPU information and load are retained alongside the table.
