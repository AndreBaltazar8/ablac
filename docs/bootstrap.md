# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with a checksum-pinned
native `v0.2.4` host artifact for Linux x86-64, Intel macOS, or Apple Silicon.
Mach-O artifacts can be emitted and linked on Linux with LLVM, an Apple SDK,
and ABI stubs for the target libraries. The resulting artifact is then
executed by the matching Mac release gate.

```text
published ablac binary
        |
        v
current src/*.ab -> build/ablac.bin
        |
        v
current src/*.ab -> fixed-point compiler
```

`make bootstrap` selects, downloads, and verifies the artifact for the current
host. `make ablac` then uses
it to rebuild the current sources. `make self-rebuild` builds another compiler,
requires byte-identical LLVM IR from both compilers, audits the child for
unresolved Abla runtime symbols, and uses it to build and run a native probe.

The published binary is trusted only as the initial translator. The readable
Abla source graph and fixed-point check define the maintained compiler. A
future release can be bootstrapped by the previous Abla release without
reintroducing a second compiler implementation.

## Repository layout

```text
src/       compiler implementation and command-line entry points, all Abla
stdlib/    standard library written in Abla
stdlib/abla/runtime/   portable runtime and target platform modules, all Abla
runtime/   narrow Darwin translation adapter used only by Mach-O artifacts
tests/     language, diagnostic, conformance, and execution fixtures
tools/     bootstrap, test, benchmark, and release utilities
docs/      language and architecture contracts
```

There is no generated-C backend or second compiler runtime. The portable
runtime is Abla source compiled into the same LLVM unit as each program.
Mach-O artifacts additionally link `runtime/abla_darwin_compat.c`, a narrow
adapter that translates the standard library's stable Linux-style syscall
contract to Darwin libc, socket, and kqueue APIs. It contains no Abla value,
allocation, evaluator, or compiler implementation.

LLVM, Clang, and the platform linker remain native toolchain dependencies.
Linux pins them through Nix; macOS uses Homebrew LLVM and the system
Mach-O linker. Removing those hosted dependencies is a separate freestanding goal described in
[full-self-hosting.md](full-self-hosting.md).
