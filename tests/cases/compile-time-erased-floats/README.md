These tests execute the interpreter and native JIT. They compare exact runtime
metadata and payload bits, independently of float formatting and `any` equality. Every JIT site must
report that it ran natively; interpreter fallback is a test failure.

`expected.txt` requires every case to pass. The repro-only parent commit records
known failures for scalar64, scalar32, mixed, erased-dense, nested, erased-field,
map and capture in both modes. The fix preserves explicit float identity in the
shared lift emitter and native wire. The shared compiler-API client also checks
wire version rejection, integer lookalikes, static typed fallback and cycles.

The mixed array includes integer bits indistinguishable from 1.5's payload,
signed zeros, subnormals, infinities, and noncanonical NaNs of both widths. Typed
dense arrays, typed/nullable fields and exact typed NaN bits are passing controls.
`inspect.ab` is copied under a disposable standard-library runtime directory by
`tools/runtime-fixture.sh`, so raw layout access stays restricted to the runtime.
The staged computations do not call the inspectors.

Run `tools/test-compile-time-erased-floats.sh <compiler>` in the Nix shell.
`ERASED_FLOAT_LIFT_PROFILE=release` also checks optimized code generation.
`ERASED_FLOAT_LIFT_EXPECT` overrides the expectation file for negative controls.

`ABLA_LIFT_CODEC_CHECK=1` also runs the same cases through the ordinary value
codec, including native positional captures. `tools/test-lift-codec-closures.sh`
adds shared variables, graph aliases, recursive and consuming closures; it
requires identical IR with the codec flag enabled and disabled in both tiers.
