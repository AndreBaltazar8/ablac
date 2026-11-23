# The browser compiler

The compiler's front end (module graph, parse, semantic analysis, lowering) runs as a WebAssembly module in a page, in a Web Worker, with no
server compile. A page compiles a program and runs it there with the compiler's own evaluator. It ships as `abla-playground-<version>.tar.gz`, a
signed release asset (`make playground` builds it).

## What it is

`src/browser_main.ab` is a compiler entry point built for `wasm32-module` (`tools/build-playground.sh`, a release build). It reaches no LLVM
symbol and has no native compile-time tier:

- LLVM emission, ORC's JIT, the dynamic loader and the signal trampolines are installed by `bootstrapNativeInstall()` (`src/native_install.ab`),
  which the native compiler's entry points call and this entry never imports. Left uninstalled, `ct_native.ab`, `ct_eval.ab` and `backend.ab`
  refuse what needs them, and every compile-time `#` site is interpreted whatever `ABLA_COMPILE_EVAL` says (the default tier is `auto` only
  with the native tier).
- A program needs libLLVM when it calls LLVM's C API, not when its module graph declares a binding (`bootstrapLlvmNeedsLlvm`).
- Every raw Linux system call goes to one host import, `abla_host.syscall(number, a0..a5: i64) -> i64`: `src/browser_host.ab` defines
  `__ablaRuntimeBrowserSyscall`, which a bare wasm32 program that defines it uses in place of the runtime's four-call fallback. No other program
  has that function, so ordinary Wasm modules are unchanged. The module also imports `env.fork` (the page answers -1) and `env.strlen`.
- The standard library is read at `/stdlib` and the program at `/work` (the working directory and the program's project), from an in-memory file
  system. No environment is needed.

## Running a program

`run()` in `tools/playground/host.mjs` wraps the program: a module that imports its `main.ab` calls `main` at compile time (a `#` site), so the
compiler's evaluator runs the program. Its output is on descriptors 1 and 2, its `int` result is the exit status, and a runtime error is a
compiler diagnostic with source frames (`E_EVAL_OUT_OF_BOUNDS: index 5 out of bounds…`). Standard input is the bytes the page gives. The grants
are the clock, random bytes and `process.io` (standard input; no process can start: `fork` fails); files, the network and native code are not
granted. The step limit (`ABLA_EVAL_STEP_LIMIT`, 50 million by default) and the page's `terminate()` watchdog bound a run.

`compile()` lowers a program and reports its diagnostics without running it.

Measured on the suite: of the 190 programs of `tests/cases/*/main.ab` that build and run natively, 145 give the same output and exit status under
the evaluator (heavy crypto and parsing time out at 40 s, and fork, file system, socket, GC-stress and platform tests need what the page does not
have). The front end gives the same functions and instructions as the native one on 104 of 106 single-file programs; the other two differ only
by what the harness supplied. In Node a hello takes about 0.45 s end to end and `fib(25)` about 1.3 s.

## The package

`tools/build-playground.sh <compiler> <directory in the checkout> [version]` builds the module and packs, in
`abla-playground-<version>.tar.gz`:

| File | What |
| --- | --- |
| `compiler-<hash>.wasm` | the front end, about 5.6 MB (1.2 MB with brotli) |
| `stdlib-<hash>.bin.br` | the standard library, one brotli bundle with its index (0.8 MB); serve it with `Content-Encoding: br` |
| `host.mjs`, `vfs.mjs`, `stdlib-bundle.mjs` | the page's host: the system calls over an in-memory file system, `run` and `compile`, the bundle loader |
| `manifest.json` | names, sizes and sha256 of the above, the version; no dates |

The archive is byte for byte the same each time (sorted names, no owners or times, `gzip -n`): `tools/test-playground-build.sh` builds twice at
once and compares, then checks the unpacked package (`tools/playground/package-check.mjs`: hashes, size limits, the bundle loaded over HTTP, a
program run). `tools/release-check.sh` judges the archive of a release (check 10).

A page keeps the compiled module in memory (IndexedDB cannot store a `WebAssembly.Module`) and the bytes in an IndexedDB cache keyed by the module
and bundle hashes; each compilation uses a fresh instance, because the compiler keeps its state in its own heap.

## Limits

- Programs run at the interpreter's speed. The direct Wasm backend (lowered IR to a WASI command) was left out: about 150 IR opcodes and the whole
  value runtime. `bootstrapEmitProgram` (`src/backend/llvm/backend.ab`) is where it would plug in.
- A module built unoptimised (`--fast`, a development build) overflows a Chrome worker's stack in deep lowering; ship the release build.
- The module is built by the release compiler from the same tree as the standard library it reads: a standard library from another version has other
  object layouts.
