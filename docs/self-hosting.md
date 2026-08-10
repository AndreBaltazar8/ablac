# Self-hosting status

The repository is source self-hosted and fixed-point self-hosted:

- every compiler implementation file is Abla source under `src/`;
- `src/orc_main.ab` is the only production compiler entry graph;
- the compiler builds that graph directly through its Abla-authored LLVM
  backend and toolchain driver;
- a rebuilt compiler emits byte-identical LLVM IR for the same graph;
- the rebuilt compiler can compile and run a native child program;
- clean checkouts use a versioned, checksum-pinned Abla compiler binary rather
  than compiling a second seed implementation.

The normal workflow is:

```sh
make              # obtain the release seed if needed and build src/*.ab
make test         # exercise the single self-hosted compiler
make self-rebuild # prove the compiler fixed point
make check        # both gates
```

`make test` uses the locked and vendored `abla-testrunner` package to schedule
the manifest in `tests/abla-tests.json`. Tests are bounded, process-isolated,
logged independently, and run with eight jobs by default. Set
`ABLA_TEST_JOBS` when the host needs a lower concurrency limit.

`tools/build-self-hosted-release.sh` splits compiler LLVM emission, object
generation, and linking into separate bounded processes to keep peak memory
predictable. `tools/test-pure-self-rebuild.sh` performs the fixed-point proof
through the public compiler behavior.

This does not mean the hosted compiler is freestanding. The current production
backend embeds libLLVM, and native linking uses the pinned Clang/LLD toolchain.
The `x86_64-linux-raw` output target is already libc-free, while removing LLVM,
the external linker, hosted libc, and startup adapters from the compiler itself
remains follow-on work in [full-self-hosting.md](full-self-hosting.md).
