# Bounded compile-effect diagnostic paths

A Dualkind build importing the Stripe SDK spent its entire ten-minute build
budget generating a compile-effect error path. This happened before LLVM
emission, with approximately 233 MB RSS and one CPU core fully occupied.

Read-only instruction-pointer sampling of that live compiler process attributed
2,029 of 2,047 retained samples (99.1%) to `bootstrapCompileEffectPath`. The sample window
covered three seconds; this is evidence about that execution interval, not a
complete compiler profile. The normal debugger could not attach because ptrace
was denied, but user-only hardware sampling succeeded without escalation.

The diagnostic recursively expanded calls without remembering visited
functions or methods. Its depth limit of 32 bounded stack depth but not work:
a component with two recursive calls could expand exponentially. Effect
summaries are conservative, so a component can be marked with an effect while
having no concrete path to an external operation. Searching that component must
finish before examining a later branch that does contain the denied operation.

`bootstrapCompileEffectPath` now searches with a per-invocation table identifying
each function declaration or method by its declaration position. A declaration
already reached at an equal or shallower depth is skipped. A shorter later route
can revisit it, preserving the existing diagnostic depth budget. This bounds
repeated graph expansion without changing effect classification or permission
checks. The change affects diagnostics, not which compile-time operations are
allowed.

The regression parses a binary-recursive function and a binary-recursive method
with conservative effect summaries. Both searches must finish with no path. It
also verifies that a later real filesystem path is still reported, and that
shorter-depth revisits remain possible. An isolated fixture compiled against the
original implementation timed out after three seconds; the corrected fixture
completed with exit 42 in approximately two milliseconds. This is a bounded
regression measurement, not a measurement of the old fixture's eventual finish.

Run with the Nix toolchain:

```sh
nix-shell shell.nix --run 'tools/test-compile-effect-path.sh build/ablac-effect-path'
nix-shell shell.nix --run 'tools/test-pure-self-rebuild.sh build/ablac-effect-path'
```

The regression script also checks that existing filesystem, environment,
network, write, and clock compile-effect denials still reject within bounded
execution time. It is included in `make test`.

Both commands passed on 2026-09-05. The production O2 compiler rebuilt itself
with byte-identical emitted LLVM IR and successfully compiled and ran the native
child probe. No compiler changes were committed.

The original Stripe compile-time JSON expression also exposed a separate staged
evaluator recursion failure after the diagnostic search was fixed. Replacing
that already-static SDK metadata expression with its equivalent JSON literal
unblocked the application build. This diagnostic optimization does not claim to
fix that separate evaluator behavior.
