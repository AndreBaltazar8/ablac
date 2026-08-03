# Abla

Abla is an experimental programming language whose mission is to **make
compile time as important as runtime**.

Complex systems often begin with simple application code supported by complex
generators, build scripts, and framework tooling written in other languages.
Abla explores a different model: ordinary language code can also run during
compilation, build constant values, inspect the program being compiled, and
request validated program transformations.

The long-term vision extends the same model from compilation into execution,
allowing programs to be deliberately inspected, extended, and replaced across
their lifecycle. This is powerful, advanced functionality rather than a goal of
being a beginner-oriented language. Kotlin strongly influenced the surface
syntax, but the language remains free to evolve while it is experimental.

`ablac` is a clean-room implementation of the original Abla prototype. It
contains a C++20 bootstrap seed, a self-hosted compiler written in Abla, the
runtime and standard library, and compatibility tests derived from the public
behavior of the prototype.

## Status

Abla is pre-release software under active compiler and language development.
It is not ready for production use, and syntax, APIs, bootstrap stages, and
toolchain behavior may change before a stable release.

The current engineering state and known blockers are recorded in
[docs/status.md](docs/status.md). A release candidate must pass the clean
bootstrap, fixed-point, native conformance, cache, ownership, and libc-free
gates listed there.

## Example

The `#` prefix evaluates an expression during compilation. The result becomes a
normal value in the generated program:

```abla
fun square(value: int): int = value * value

compile fun compileAdd(left: int, right: int): int = left + right

fun main: int {
    val generated = #square(6)
    generated + #compileAdd(2, 2)
}
```

Both compile-time expressions are evaluated by the compiler, so `main` returns
`40`. Compile-time execution uses the same checked language model as runtime
execution and is subject to explicit capabilities and resource limits.

Abla also supports library-provided compile-time subparsers. For example, JSON
can be constructed in either phase with the same source form:

```abla
#import("abla/json")

fun main: int {
    val frozen = #$json {"number": 20, "name": "abla"}
    val runtime = $json {"number": 20}
    frozen.getInt("number") + runtime.getInt("number")
}
```

## Development

The development shell pins nixpkgs and the complete compiler toolchain. Install
Nix, then enter the environment and build the seed compiler:

```sh
nix-shell
make
```

Run the ordinary test suite with:

```sh
make test
```

The complete bootstrap and fixed-point gate is substantially heavier and may
use up to 4 GiB of memory:

```sh
make check
```

Useful focused targets include:

```sh
make bootstrap-check          # validate Abla compiler components and emitted C
make bootstrap-stage1         # build the native self-host subset compiler
make bootstrap-selfhost       # prove the C bootstrap fixed point
make bootstrap-llvm-selfhost  # prove the LLVM-native compiler fixed point
make ablac                    # fast incremental rebuild of the user compiler
make ablac-force              # rerun the complete fixed-point/conformance gate
make sanitize                 # run the seed suite with ASan and UBSan
make clean
```

`make compat-original` additionally checks the original prototype examples
when that repository is available at `../abla-original`.

## Using the compilers

The seed compiler is built as `build/ablac0`:

```sh
build/ablac0 tokens program.ab
build/ablac0 parse program.ab
build/ablac0 check program.ab
build/ablac0 ir program.ab
build/ablac0 emit-c program.ab
build/ablac0 run program.ab
```

After `make ablac`, the self-hosted compiler provides the main user interface:

```sh
build/ablac build program.ab -o build/program
build/ablac build program.ab -o build/program --fast
build/ablac build program.ab --target x86_64-linux-raw -o build/program.raw
build/ablac run program.ab
build/ablac repl
build/ablac serve program.ab
```

Projects can import locked Git packages through compile-time source providers:

```abla
#import(github("AndreBaltazar8/abla-mvc"))
```

Run `build/ablac package update --project .` to resolve/update `abla.lock`;
ordinary and `--offline` builds never change locked revisions. See
[package imports](docs/packages.md) for custom provider functions and
vendoring.

The raw x86-64 Linux target emits a static executable with its own startup,
allocator, and system-call boundary, without a C runtime, libc, ELF interpreter,
or dynamic dependency. Hosted LLVM remains available for development, JIT
execution, and C interoperability.

Generated files are not committed. Build products and compiler caches stay
under `build/`.

## Examples

- [Android hello world](examples/android/README.md) compiles Abla to an arm64
  `libabla_app.so`, generates its JNI/Kotlin project, and produces a runnable
  debug APK and release AAB with a pinned Nix/Gradle/Android toolchain.
- [Android RPC counter](examples/android-rpc/README.md) reflects one `@rpc`
  action into a generated click client and a separately compiled native server.
- [Versioned HTTP server](examples/versioned-http-server.ab) demonstrates
  header-selected endpoint versions on the hosted server stack.

## Project principles

- Use one coherent language model for compile-time and runtime execution.
- Validate compiler-generated syntax and declarations through the ordinary
  parser, resolver, type checker, ownership checker, and IR verifier.
- Make filesystem, environment, network, clock, and native access explicit
  capabilities rather than invisible compiler privileges.
- Keep builds deterministic, bounded, transactional, and reproducible.
- Preserve a readable source bootstrap and prove fixed points before promotion.
- Keep hosted facilities optional and maintain a libc-free production target.

## Documentation

- [Language contract](docs/language.md)
- [Toolchain interface](docs/toolchain.md)
- [Compiler extension API](docs/compiler-api.md)
- [Programmable builds](docs/programmable-builds.md)
- [Package imports](docs/packages.md)
- [Bootstrap architecture](docs/bootstrap.md)
- [Self-hosting status](docs/self-hosting.md)
- [Standard library](docs/standard-library.md)
- [Compile-time subparsers](docs/subparsers.md)
- [Reliability roadmap](docs/reliability-roadmap.md)
- [Full self-hosting plan](docs/full-self-hosting.md)
The [original implementation audit](docs/original-audit.md) separates behavior
that was demonstrated by the prototype from incomplete or aspirational design.

## Contributing

The language is still defining its safety, bootstrap, package, and extension
contracts. Contributions should include focused positive, negative, and
regression tests and preserve the documented resource and reproducibility
gates.

## License

Abla is licensed under the [Mozilla Public License 2.0](LICENSE).
