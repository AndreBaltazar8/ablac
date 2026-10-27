# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with a checksum-pinned
native `v0.2.21` host artifact for Linux x86-64, Intel macOS, or Apple Silicon.
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

`tools/test-clean-bootstrap.sh` checks that path from a fresh clone: the
pinned release builds a stage-1 compiler from the current sources, and the
stage-1 builds and runs a program. It reports which errors stop it when the
sources use something newer than the pinned release, which means the pin has
to move. It isn't part of `make test`; `ABLA_BOOTSTRAP_URL` and
`ABLA_BOOTSTRAP_SHA256` try a candidate release.

For the v0.2.20 to v0.2.21 transition, `build-self-hosted-current.sh` first
builds checkpoint `773683772ce54bcfae4fdfd7049b55bd28ea1814` from a
checksum-pinned source archive. That checkpoint implements private declarations
and generics, but its own standard library still uses syntax v0.2.20 accepts.
The intermediate compiler then builds the current sources. This automatic
handoff applies to a v0.2.20 compiler only; newer bootstraps build directly.
The release workflow still rebuilds stage 2 and verifies the fixed point.

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

## Word-zero intrinsic transition

The v0.2.14 release is the bootstrap bridge for `ablaRuntimeValueWord0`, which
v0.2.13 cannot compile. The v0.2.15 source tag pins that bridge's host binaries
and checksums. Current clean builds start directly from the checksum-pinned
v0.2.21 stable host binaries. LLVM 23 has been used since v0.2.16.

The v0.2.14 tag preserves the bridge source and its reproducible source chain
from v0.2.13 in `tools/bootstrap-word0-bridge.sh`. Release tags preserve that
history; the temporary bridge branch is no longer needed.

## Object layout change (extension-field overflow)

A class instance's header changed: `+24` is now its overflow of fields set by
name (0 when there is none), where it used to point at its own inline slots.
Compile-time code compiled by the JIT and the compiler running it share
objects, so a compiler whose own runtime predates this change can't run
compile-time JIT code against the new standard library (it reads `+24` as
the slots). A stage-1 compiler built by v0.2.18 has that old runtime: rebuild
it once more to produce stage 2 before running tests, parity or releases.
The v0.2.19 release completed that rebuild on every platform. The current
v0.2.21 bootstrap retains the new object layout for clean builds.
The release workflow retains the stage-2 rebuild and self-rebuild fixed-point
check for future code-generator changes.
