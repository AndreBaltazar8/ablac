# Libc-free programs and freestanding targets

Linux x86-64, AArch64 and RISC-V 64 programs use Abla startup, allocation, memory routines,
system calls, signal/panic paths and threads by default. An executable that
brings no C-library dependency links as a static PIE without a dynamic loader
or needed libraries. There is no separate raw-Linux opt-in target. An explicit
C-library dependency can select a hosted link; `ablac build --verbose` explains
that selection. Pure Abla TLS does not require OpenSSL.

The built-in Linux targets are `x86_64-linux`, `aarch64-linux` and
`riscv64-linux`.
[Target selection](targets.md) describes their scope and the other targets.
[Toolchain linking](toolchain.md#build) distinguishes the compiler's own
libraries from those needed by an emitted program. The installed dynamic
compiler and LLVM tools can have host dependencies while producing a libc-free
program. The static compiler can embed LLVM and, with its LLD bridge, link in
process; that is not an independent backend or proof of no native
build-tool dependencies.

## Without an operating system

A libc-free Linux process still depends on the Linux kernel. Bare-metal
microcontrollers, kernels and Wasm modules have different startup, imports,
linker scripts and runtime hooks. A framework or build library supplies those
contracts; accepting an LLVM triple alone supplies none of them. Xtensa
requires the [separate LLVM companion](llvm-xtensa.md). Hostless Wasm can run
without runtime imports for the operations it supports; modules using the
host ABI need a host to implement those imports.

The standard library exposes typed files, sockets, processes and buffers over
platform implementations. Prefer those public APIs to raw system calls.
`ByteBuffer`/`ByteSlice` and trusted native-memory APIs provide low-level
building blocks, but a raw integer address cannot itself establish provenance,
alignment, allocation lifetime or portability. Native access remains gated by
trusted declarations and compile-time capabilities.

The removed historical `x86_64-linux-raw` adapter is not a current target alias.
Its old C/assembly startup does not describe today's ordinary Linux program
runtime. See [self-hosting boundaries](full-self-hosting.md) for what the
compiler's static artifact checks actually prove.
