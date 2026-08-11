# LLVM native backend

LLVM is the current production-quality native backend and will remain an
optional hosted accelerator. Because libLLVM is implemented in C++ and loads
libc, it cannot prove the final freestanding self-host goal. The required
baseline Abla machine-code/ELF backend is planned in
[full-self-hosting.md](full-self-hosting.md).

The generated-C backend is a bootstrap and differential-testing backend. It is
not the destination of the self-hosted compiler. The normal native pipeline is:

```text
Abla source
  -> self-hosted frontend and typed IR
  -> Abla-authored LLVM backend
  -> LLVM object emission
  -> native linker
  -> executable
```

The bootstrap form emits deterministic textual LLVM IR and invokes `llc`.
The final compiler binds LLVM 21's C API from Abla, runs the O2 pipeline, and
emits the object in-process. Both consume the same verified `BootstrapProgram`
and tagged-value ABI as the interpreter and bootstrap C backend. Production
LLVM modules contain the value runtime itself: scalars, closures/cells, arrays,
objects, strings, formatting, equality, and non-recursive rope flattening are
emitted by Abla. Programs without host-capability imports also emit their own
allocator wrappers and raw-syscall panic path, link no project C symbols, and
do not initialize the host argument bridge. Programs importing filesystem,
process, network, or memory facilities conservatively select the tracked shared
allocator so compound values created on either side of the ABI can be safely
grown and reset.

## Reproducibility contract

- Target triple and data layout are explicit compiler inputs.
- Functions, globals, symbols, constants, and metadata are emitted in stable
  source/IR order.
- LLVM optimization level and pipeline are versioned compiler inputs.
- Object and executable comparisons normalize platform metadata that is not
  semantically controlled; LLVM IR snapshots remain byte-identical.
- Every native fixture must agree with the VM and bootstrap-C result before the
  C path can be retired.

## Bootstrap handoff

1. Stage 0 compiles the Abla compiler while its LLVM backend is being brought
   up.
2. The Abla compiler emits LLVM IR for ordinary fixtures and then for its own
   complete source graph.
3. `llc` emits objects and `ld.lld` links the compiler with the native runtime.
4. That compiler repeats the build and produces equivalent LLVM/object output.
5. The in-process LLVM binding replaces the `opt` and `llc` subprocesses.
6. Replace the selected host/linker surface with Abla platform modules; the
   generated-C backend then becomes optional compatibility tooling. The pure
   allocator/panic path has already crossed this boundary.

The guarded compiler launcher remains mandatory throughout this process. A
backend or optimizer defect must fail at its address-space or time limit rather
than consuming the development machine.

Fixed-size LLVM scratch storage is emitted in each function's entry block.
Emitting `alloca` inside an Abla loop is forbidden: LLVM retains that storage
until the function returns, so even a tiny call-argument array would otherwise
grow the native stack on every iteration. The native self-host gate compiles
the complete compiler twice and includes a 250,000-iteration regression under
a 64 MiB process limit.

Before emission, a conservative scalar plan proves `i64` and `bool` SSA values
from constants, typed parameters and direct calls, native declarations,
arithmetic, comparisons, and scalar locals. A local is native only when every
store agrees on one scalar type. Proven values have no `AblaValue` slot unless
an actual use crosses a dynamic, aggregate, capture, indirect-call, or other
boxed boundary. Native local allocas remain in the entry block so LLVM's O2
promotion turns straight-line and control-flow storage into SSA registers and
PHI nodes. Unsupported operations retain the boxed runtime path unchanged.

The resulting object backend is used by `ablac build`; the same module is the
input to the Abla-authored persistent ORC session used by `run` and `repl`.
The command and capability contract is defined in
`docs/toolchain.md`.

Native C calls preserve declared `i64`, `bool`, `cstring`, explicit pointer,
and `void` ABI types. Strings are adapted only for `cstring` inputs; native
`cstring` results remain rejected because their ownership cannot be inferred.
Explicit pointer values are trusted-platform opaque handles. Ordinary
functions cannot call raw pointer intrinsics; checked buffers currently enforce
bounds and closed state while affine ownership, borrowed views, and automatic
drop insertion are completed.

The current `build/ablac run` path drives LLVM ORC in-process through the typed
C ABI. It resolves the exported Abla runtime, looks up `main`, and invokes it
without AOT object emission or linking. The bootstrap compiler uses the same
Abla binding in a separate runner until the C bootstrap path is retired. The
current ORC API associates modules with resource trackers and proves
load/execute/reclaim/reload in one process. The expression REPL uses that path;
persistent declaration state and in-process network swapping are next.
