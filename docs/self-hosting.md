# Self-hosting status

The repository is source self-hosted and fixed-point self-hosted:

- every compiler implementation file is Abla source under `src/`;
- `src/orc_main.ab` is the dynamic compiler entry; `src/orc_main_static.ab`
  adds the Linux static compiler's own C-library compatibility and optional
  in-process LLD integration;
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

`make test` runs the recipe of `make test-serial` through `tools/run-tests.sh`,
with one result/log per command and concurrency controlled by `JOBS` (the CPU
count by default). Nested runners use `ABLA_TEST_JOBS`/`ABLA_SUITE_JOBS` to
bound their own work. The conformance manifest in `tests/abla-tests.json` is
one part of the suite, run by the self-hosted test driver; it is not the whole
suite's scheduler.

`tools/build-self-hosted-release.sh` splits compiler LLVM emission, object
generation, and linking into separate bounded processes to keep peak memory
predictable. `tools/test-pure-self-rebuild.sh` performs the fixed-point proof
through the public compiler behavior.

Application builds also compile the portable Abla algorithms in
`stdlib/abla/runtime/self/entry.ab` into the same LLVM unit as user code. LLVM
can therefore inline and remove unused text/byte algorithms during LTO. This
file intentionally does not reimplement arithmetic or bit operations:
statically typed scalars lower directly to LLVM instructions. Dynamic value
operations remain Abla functions over compiler-provided value-layout
intrinsics; dead runtime functions are removed by LTO and section garbage
collection.

The dynamic backend loads libLLVM; the static Linux compiler embeds LLVM and
its own C-library compatibility routines. With its LLD archives configured,
the x86-64 static compiler also links in process through a small C++ bridge.
Libc-free program links use LLD directly without clang. These checks eliminate
some dynamic dependencies, not LLVM itself. See the exact
[native dependency boundaries](full-self-hosting.md).
