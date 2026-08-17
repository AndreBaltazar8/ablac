# Freestanding and raw-kernel profile

Direct system calls are useful for small static Linux programs, kernels, and
embedded targets, but they are not yet a public executable target. The former
raw Linux target was removed with its project-owned C and assembly startup.
It will return only when startup, allocation, panic, and process entry are
expressed by Abla source or compiler intrinsics.

The intended layering is:

```text
abla/fs, abla/process, abla/net
        -> platform interfaces
        -> posix/libc | linux/raw | wasi | embedded target
        -> kernel or host ABI
```

The phase-safe `ByteBuffer`/`ByteSlice` API and opt-in native word/pointer cells
now exist. Linux filesystem, terminal, process, TCP, polling, and graceful
signal-drain implementations are built on them. The pointer cells provide
explicit lifetime and LLVM-lowered
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
