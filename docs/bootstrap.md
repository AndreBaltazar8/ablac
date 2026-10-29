# Bootstrap and trust model

Abla has one compiler implementation. All compiler source is in `src/*.ab`,
and the production entry point is `src/orc_main.ab`. The former C++ seed and
multi-stage source bootstrap are no longer part of the repository.

A compiler cannot translate itself on an empty machine without an existing
executable translator. Clean builds therefore begin with a checksum-pinned
native `v0.2.23` host artifact for Linux x86-64, Intel macOS, or Apple Silicon.
Mach-O artifacts can be emitted and linked on Linux with LLVM, an Apple SDK,
and ABI stubs for the target libraries. The resulting artifact is then
executed by the matching Mac release gate.

```text
published ablac binary
        |
        v
current src/*.ab, a runtime with both object layouts -> bridge compiler
        |   (only while the published binary predates typed instances,
        v    see "Typed instance layout")
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
v0.2.23 stable host binaries. LLVM 23 has been used since v0.2.16.

The v0.2.14 tag preserves the bridge source and its reproducible source chain
from v0.2.13 in `tools/bootstrap-word0-bridge.sh`. Release tags preserve that
history; the temporary bridge branch is no longer needed.

## Strict-imports transition

The compiler's sources are a strict-imports package (`src/abla.toml` says
`visibility = "imports"`): each module imports the modules whose names it
uses. A few of them use the runtime's names, which every module sees
without an import only from the compiler that made the standard library
strict and the runtime visible everywhere. A compiler that knows
`visibility` but predates that rule (v0.2.20 is one) rejects those uses,
so building the compiler from source needs either a compiler that has the
rule or one from before `visibility`, which builds the sources flat. Clean
builds start from a bootstrap release that has it.

## Object layout change (extension-field overflow)

A class instance's header changed: `+24` is now its overflow of fields set by
name (0 when there is none), where it used to point at its own inline slots.
Compile-time code compiled by the JIT and the compiler running it share
objects, so a compiler whose own runtime predates this change can't run
compile-time JIT code against the new standard library (it reads `+24` as
the slots). A stage-1 compiler built by v0.2.18 has that old runtime: rebuild
it once more to produce stage 2 before running tests, parity or releases.
The v0.2.19 release completed that rebuild on every platform. The current
v0.2.23 bootstrap retains the new object layout for clean builds.
The release workflow retains the stage-2 rebuild and self-rebuild fixed-point
check for future code-generator changes.

## Typed instance layout

Class instances store their declared fields by kind (a word, a byte for a
bool, two words for a string, one for a reference, a boxed value otherwise)
behind a 16-byte header naming the class's descriptor, where they used to be
32-byte slots of a symbol and a boxed value. The code generator and the
runtime changed together: generated code passes a field's place (offset, kind
and tag, bit 48 set) where it used to pass its index, and a class's descriptor
(+ 2^62) where it passed its field count. The runtime that made both layouts
(for a stage-1 compiler whose seed still made the older calls) was the bridge;
this runtime makes typed instances only. A compiler from before typed
instances (v0.2.22 is one) can't build a compiler that
runs on it: its code would pass field counts, on which the runtime traps. So
`tools/build-self-hosted-current.sh` first builds and runs
`tools/bootstrap-typed-instances.ab` with the compiler it starts from; when
that doesn't exit 42, the compiler builds the sources once against a copy of
the standard library whose runtime also keeps the older layout
(`tools/bootstrap-untyped-objects.patch`), and the compiler that comes out of
it builds the result. The v0.2.23 bootstrap release makes typed instances, so
a clean build passes the probe and skips that step.
