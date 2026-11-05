These tests execute the interpreter and native JIT. They compare exact runtime
metadata and payload
bits, independently of float formatting and `any` equality. Every JIT site must
report that it ran natively; interpreter fallback is a test failure.

`expected.txt` records **known failures**, not skipped tests. Phase (d) will flip
scalar64, scalar32, mixed, erased-dense, nested, erased-field, map and capture
from `mismatch` to `pass` in both modes. The interpreter also needs the shared
lift emitter to preserve float identity at erased destinations; the JIT also
needs its native wire to carry that identity.

The mixed array includes integer bits indistinguishable from 1.5's payload,
signed zeros, subnormals, infinities, and noncanonical NaNs of both widths. Typed
dense arrays, typed/nullable fields and exact typed NaN bits are passing controls.
`inspect.ab` is copied under a disposable standard-library runtime directory by
`tools/runtime-fixture.sh`, so raw layout access stays restricted to the runtime.
The staged computations do not import or call the inspectors.

Run `tools/test-compile-time-erased-floats.sh <compiler>` in the Nix shell.
`ERASED_FLOAT_LIFT_EXPECT` can point at an all-pass expectation file when
screening the implementation; production tests will update the checked-in file.
