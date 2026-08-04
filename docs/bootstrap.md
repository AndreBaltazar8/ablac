# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with the checksum-pinned
`ablac-x86_64-linux` artifact from the `v0.1.0` GitHub release:

```text
published ablac binary
        |
        v
current src/*.ab -> build/ablac.bin
        |
        v
current src/*.ab -> fixed-point compiler
```

`make bootstrap` downloads and verifies that artifact. `make ablac` then uses
it to rebuild the current sources. `make self-rebuild` builds another compiler,
requires byte-identical LLVM IR from both compilers, audits the child for
project-C host symbols, and uses it to build and run a native probe.

The published binary is trusted only as the initial translator. The readable
Abla source graph and fixed-point check define the maintained compiler. A
future release can be bootstrapped by the previous Abla release without
reintroducing a second compiler implementation.

## Repository layout

```text
src/       compiler implementation and command-line entry points, all Abla
stdlib/    standard library written in Abla
runtime/   target startup and hosted platform adapters
tests/     language, diagnostic, conformance, and execution fixtures
tools/     bootstrap, test, benchmark, and release utilities
docs/      language and architecture contracts
```

The C backend in `src/backend_c.ab` is an optional diagnostic and differential
backend written in Abla. C and assembly files under `runtime/` are target
adapters for generated programs; they are not compiler implementations or a
compiler bootstrap stage.

LLVM, Clang, and LLD remain pinned native toolchain dependencies. Removing
those hosted dependencies is a separate freestanding goal described in
[full-self-hosting.md](full-self-hosting.md).
