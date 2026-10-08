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
- [ ] **`ablaRuntimePointerFromAddress` is missing for the Android and embedded
  targets.** The stdlib's semantic pass can't find the intrinsic for those targets
  (it's declared in `stdlib/abla/runtime/self/entry.ab`). It fails:
  - abla-mobile: `tests/android_build_variants.ab`, `tests/android_panic_build.ab`,
    `examples/*/android_build.ab`;
  - abla-food: `android_build.ab`;
  - abla-embedded: the board build drivers `examples/*/build.ab` (all but
    `board-detect-c6`).
- [ ] **Packages of packages don't resolve.** A dependency's own dependencies
  aren't found from inside `.abla/packages/<dep>/source`. abla-compare's
  `servers/abla/main.ab` and `diagnostics/http_pipeline_memory.ab` fail because
  abla-web's imports of abla-postgres, abla-redis and abla-nats don't resolve
  there (they build once those packages are linked in by hand).
- [ ] **xtensa intrinsics on the host target.** abla-embedded
  `radio-mac-registers` `dispatcher.ab`, `interrupt.ab` and `power.ab` use an
  xtensa intrinsic that can't be lowered on the host; the compiler crashes
  (exit 139) instead of reporting it. `radio-mac-registers/build.ab` also needs
  an `llc` with the xtensa target.

## Packages

- [ ] **abla-testrunner: `ablaHostIsMacOS` is ambiguous.** The package and the
  stdlib now both define it, so `tests/parser_test.ab` and
  `tests/integration_test.ab` fail with `E_IMPORT_UNQUALIFIED_AMBIGUOUS`.
- [ ] **abla-testrunner: `tests/fixture.ab` fails to link** (a missing symbol).

## Not checked

Linux-only linking and running (abla-graphics, abla-doom, the X11/Wayland
tests), the ESP32 and Android cross builds (their toolchains aren't installed),
and tests that need network services.
