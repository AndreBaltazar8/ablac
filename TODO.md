# TODO

Known failures found by compiling every `abla-*` package against ablac `1a90db5`
(2026-10-08). Every item below fails with the previous compiler (`f49012f`) too: none
is a regression of `1a90db5`.

## Compiler and stdlib

- [ ] **`utcIso8601Parse` fails IR verification.** `stdlib/abla/date/entry.ab`
  `utcIso8601Parse` (line ~173) breaks an LLVM function check
  (`E_IR_FUNCTION_VERIFICATION`). Any program that imports `abla/date` and reaches it
  fails to build. Seen in most abla-graphics targets and in abla-doom's `src/main.ab`;
  both pass the semantic pass first.
  Not reproducible at `baccfbd` on macOS: abla-doom `src/main.ab`, abla-graphics
  `examples/buffer-pool/main.ab` and a program calling `utcIso8601Parse` directly
  pass the IR pass (with and without `--fast`) and stop only at the link (`-lvulkan`
  isn't installed). The failing logs probably came from another compiler build or
  stdlib tree; recheck on Linux before closing.
- [x] **`ablaRuntimePointerFromAddress` is missing for the Android and embedded
  targets.** Fixed in `314c080`: a non-hosted target that links a C library
  (`libcFree` false: Android, ESP-IDF) gets the runtime and the libc platform again
  (`bootstrapNativeBuildWithEmitterStateCache`); since `ca65e9a` only hosted and Wasm
  targets got them. Libc-free targets stay runtime-neutral.
  - abla-mobile's Android drivers and abla-food's `android_build.ab` now build both
    objects (arm64, x86_64) and the packaging files; they stop at Gradle/the NDK (not
    installed here). Package-side: abla-mobile's `runtime/native/CMakeLists.txt` still
    compiles ablac's `runtime/abla_runtime.c` (removed in `93ce196`) and its C platform
    layer implements that old C runtime ABI. The objects now carry the Abla runtime
    (it calls `malloc`/`free`/`pthread_*`/`write`/`abort`; emulated TLS on Android),
    so that native layer needs updating.
  - abla-embedded: the ESP32-C6 (RISC-V) drivers build their objects; the Xtensa
    drivers pass the compiler and stop at `llc` (no ESP LLVM with the Xtensa target
    here). Untested at the ESP-IDF link: the runtime's thread-local is general-dynamic
    TLS (`0dcbd67`), so an object that reaches the runtime references
    `__tls_get_addr`, which ESP-IDF may not provide; a static-only target could use
    local-exec.
- [x] **Packages of packages don't resolve.** Fixed in `4e5fa1a`
  (`bootstrapResolvePackageImport`): in a dependency's own copy (prepared
  `.abla/packages/<dep>/source` or vendored `vendor/<dep>`), the dependency's own
  `abla.lock` no longer ends the search; it continues to the enclosing project.
  abla-compare's `servers/abla/main.ab`, `diagnostics/http_pipeline_memory.ab` and
  `--project .` build offline.
- [x] **xtensa intrinsics on the host target.** The crash is fixed in `d32ab95`: after a
  lowering error the backend skips the passes, verifier and printer over the partial
  module, so `dispatcher.ab` and `interrupt.ab` report
  `E_LLVM_INSTRUCTION_UNSUPPORTED` and exit 1 instead of 139. Building them still needs
  an Xtensa target, and `radio-mac-registers/build.ab` an `llc` with it.
- [x] **`val x = #exportFunction(...)` exported nothing.** Found with the Android
  objects: since `9ba9ab9` such a value wasn't a reachability root, so neither the
  export nor the function reached LLVM (`exportCheckedFunction` was unaffected).
  abla-mobile's apps and `tools/test-android-extension.sh` use this form. Fixed in
  `087b3b6` (`bootstrapSourceInitializerWritesGlobal`).
- [ ] **`abla/platform/host`'s `extern:"host"` functions have no native
  implementation.** They lived in the C host runtime removed in `93ce196`; only the
  compile-time evaluator implements a few. A native program that calls one fails at
  the link with an undefined `ablaHost*` symbol. Either implement them on the public
  modules or reject such calls in a native build with a diagnostic naming the public
  replacement (`abla/fs`, `abla/io`, `abla/process/*`).
- [ ] **`tools/test-wasm-mvc-extension.sh` checks a stale symbol.** It greps
  `llvm-readobj --symbols` for `abla_mvc_revision`, but a linked module's symbol table
  lists name-section names (`app.revision`); the export itself is present. Check the
  export section instead. (Before `087b3b6` the build failed earlier.)

## Packages

Package-side work (not changed from ablac):

- [ ] **abla-testrunner: `ablaHostIsMacOS` is ambiguous.** The package and the
  stdlib both define it, so `tests/parser_test.ab` and `tests/integration_test.ab`
  fail with `E_IMPORT_UNQUALIFIED_AMBIGUOUS` and `symbol.duplicate`. The two
  declarations are identical. Fix in `src/testrunner.ab`: replace
  `noescape extern:"intrinsic" fun ablaHostIsMacOS(): bool` with
  `import "abla/platform/host"`.
- [ ] **abla-testrunner: `tests/fixture.ab` fails to link** (`_ablaHostArgument`,
  `_ablaHostSleep`, `_ablaHostWriteStdout` undefined). Cause: the `abla/platform/host`
  item above; the package moved `src/` to the public APIs in `54f3fac` but not
  `tests/`, and `parser_test.ab`/`integration_test.ab` fail the same way once the
  ambiguity is fixed. Fix: in the three test files import the public modules instead
  of `abla/platform/host` and use `processArgument(i)` (`abla/process/arguments`),
  `sleep(ms)` and `monotonicMilliseconds()` (`abla/process/time`), `print(text)`
  (`abla/io`), `currentDirectory().text` and `path(p).readText()` (`abla/fs`).
  Checked on a scratch copy: with this and the item above, `make check` passes.

## Not checked

Linux-only linking and running (abla-graphics, abla-doom, the X11/Wayland
tests), the ESP32 and Android cross builds (their toolchains aren't installed),
and tests that need network services.
