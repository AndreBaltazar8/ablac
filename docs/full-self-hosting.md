# Self-hosting and native dependency boundaries

Abla's compiler algorithms are implemented in Abla. A clean build starts from
a checksum-pinned Abla release; no second implementation of the language is
needed. That is separate from whether the executable loads native libraries,
embeds third-party code, or starts external tools.

| Property | Evidence and boundary |
|---|---|
| One Abla compiler rebuilds the compiler | `make self-rebuild`, `tools/test-pure-self-rebuild.sh` |
| Rebuilt compiler reaches byte-identical LLVM IR | The self-rebuild gate compares the generations' LLVM IR |
| Linux programs avoid libc by default | x86-64 and AArch64 use their own startup/runtime; explicit C-library dependencies can select a hosted link; `tools/test-libc-free-programs.sh` guards the corpus and its exceptions |
| Linux static compiler needs no dynamic loader or C library | `src/orc_main_static.ab`, `tools/test-static-artifact.sh`: static PIE, no `PT_INTERP`/`DT_NEEDED`, child compile/run and x86-64 fixpoint; AArch64 runtime checks use qemu |
| Compiler stops depending on LLVM | Not implemented: static linking embeds LLVM rather than replacing it |
| Libc-free Linux program links need no clang driver | Links go directly to LLD; `tools/test-toolchain-without-c-development.sh` checks a packaged toolchain without C development files |
| Static compiler can link in its own process | x86-64 with the LLD archives/header settings from `tools/static-llvm-env.sh`; `src/static_lld.ab` calls the small `runtime/abla_lld_shim.cpp` C++ adapter |
| Every build avoids all external native tools | Not established: dynamic compiler and static builds without embedded LLD use external linking; other target/platform paths can require SDKs and tools |

The static compiler's C-library compatibility implementation is Abla source in
`src/static_libc`. Its native symbol table supports the operations LLVM and
the JIT need; it does not provide general dynamic loading. The optional LLD
bridge is one C++ source compiled when building that static configuration, not
a second Abla frontend or evaluator. LLVM/LLD, their archives and their build
toolchain remain native dependencies.

The v0.2.65 release workflow makes the static x86-64 compiler the default raw
Linux asset and retains the dynamic one for the transition. From v0.2.66 the
installable Linux toolchain archive is the static one too; the dynamic compiler
and its libraries ship for one more release as `abla-toolchain-dynamic-x86_64-linux`.
macOS has its own libSystem/Homebrew/SDK boundary. See
[toolchain.md](toolchain.md), [bootstrap.md](bootstrap.md), and
[targets.md](targets.md) for those distinctions.

A future backend independent of LLVM would need instruction selection,
register allocation, calling conventions, relocations and object/executable
emission, plus runtime and toolchain proofs on each target. The current static
artifact checks do not establish that independence.
