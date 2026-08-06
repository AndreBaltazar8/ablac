# Freestanding and raw-kernel profile

Direct system calls are useful for small static Linux programs, kernels,
embedded targets, and eventually replacing the bootstrap C runtime. They are
not the portable public API.

On an x86-64 Linux host,
`ablac build app.ab --target x86_64-linux-raw -o app` produces a static ELF
with its own `_start`, raw `exit_group`, `mmap`/`munmap` allocation, and
compiler fallback memory primitives. LLD is invoked without CRT or libc, and
the driver rejects host or LLVM runtime imports for this profile. Other hosts
can still use extension-defined LLVM targets for object emission without
pretending that they have the Linux headers and executable-link contract.

The intended layering is:

```text
abla/fs, abla/process, abla/net
        -> platform interfaces
        -> posix/libc | linux/raw | wasi | embedded target
        -> kernel or host ABI
```

The phase-safe `ByteBuffer`/`ByteSlice` API and opt-in native word/pointer cells
now exist. Raw Linux filesystem, terminal, process, TCP, polling, and graceful
signal-drain implementations are built on them and pass no-project-C native
gates. The pointer cells provide explicit lifetime and LLVM-lowered
load/store operations for out-parameters, but ownership is not yet enforced by
the type system. A target-specific kernel intrinsic remains gated on:

- checked pointer provenance, alignment, and ownership rules;
- `Result<T, Errno>` and non-panicking error propagation;
- target triple/profile selection;
- capability rules for compile-time I/O;
- verified register/clobber lowering in each backend.

The target module exposes fixed-arity syscall intrinsics for low-level systems
work; standard-library code wraps them in typed descriptors, owned buffers,
and protocol-specific operations. Application code should prefer those typed
wrappers because a generic syscall call still cannot express pointer
provenance, buffer length, error type, or target portability.
