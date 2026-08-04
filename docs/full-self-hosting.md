# Freestanding self-hosting follow-on

Abla's compiler implementation is now entirely Abla and clean builds start
from a published Abla compiler binary. The remaining boundary is narrower:
the hosted compiler still embeds libLLVM and invokes the pinned native linker
toolchain.

These properties are distinct:

| Property | State |
| --- | --- |
| Compiler sources are only Abla | complete |
| One Abla compiler rebuilds the current compiler | complete |
| Rebuilt compiler reaches byte-identical LLVM IR | complete |
| Clean checkout needs no alternate compiler implementation | complete |
| Raw user programs avoid libc | complete for `x86_64-linux-raw` |
| Compiler executable avoids libLLVM and libc | open |
| Builds avoid external object, assembler, and linker tools | open |

The next architectural step is a baseline native backend written in Abla that
can emit a deterministic static ELF executable directly. It should share the
existing typed IR and verifier, while LLVM becomes an optional hosted
accelerator rather than part of the self-maintaining root.

That backend must eventually provide:

- x86-64 instruction selection, calling conventions, stack frames, and a
  simple deterministic register allocator;
- symbols, relocations, sections, and whole-program ELF emission;
- `_start`, argument/environment decoding, syscalls, allocation, and panic
  support emitted without compiling runtime C or assembly;
- compiler filesystem, process, cache, diagnostic, and package I/O through
  typed Abla system modules;
- `build`, `run`, `repl`, and `serve` behavior without LLVM being available.

The final proof should build two compiler generations from the published seed,
compare deterministic artifacts and manifests, reject dynamic dependencies and
undefined host symbols, record child processes to exclude external native
tools, and build/run representative compiler, standard-library, package, and
server probes under the resource watchdog.

Until that proof exists, “fully self-hosted” in release notes means that Abla
is the sole compiler implementation and maintenance language, not that the
hosted binary has no third-party native libraries.
