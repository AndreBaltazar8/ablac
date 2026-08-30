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

`ablac` is a clean-room implementation of the original Abla prototype. The
compiler is written entirely in Abla, alongside its runtime, standard library,
and compatibility tests derived from the public behavior of the prototype.

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
import "abla/json"
fun main: int {
    val frozen = #$json {"number": 20, "name": "abla"}
    val runtime = $json {"number": 20}
    frozen.getInt("number") + runtime.getInt("number")
}
```

## GitHub Actions

Use [`setup-abla`](https://github.com/AndreBaltazar8/setup-abla) to install a
checksum-verified released toolchain without rebuilding the compiler in every
workflow:

```yaml
steps:
  - uses: actions/checkout@v6
  - uses: AndreBaltazar8/setup-abla@v1
    with:
      version: '0.2.11'
  - run: ablac build app.ab -o build/app
```

The action supports Linux x86-64 and both Apple Silicon and Intel macOS. Pin it
to a full commit SHA when an immutable action reference is required.

## Development

On Linux, the development shell pins nixpkgs and the native LLVM toolchain.
Install Nix, then enter the environment and build the compiler:

```sh
nix-shell
make
```

On a Mac, install Homebrew LLVM without enabling a blanket package
upgrade, then build directly from the normal shell:

```sh
HOMEBREW_NO_AUTO_UPDATE=1 brew install llvm@21 lld@21 openssl@3
make
```

The macOS host supports Intel and Apple Silicon. `make` downloads the pinned
bootstrap compiler, rebuilds the current Abla sources as a native Mach-O
executable for LLVM's detected host triple, and uses Homebrew LLVM for native
object emission and ORC execution. Each host uses its native compiler artifact
published with `v0.2.10`; no Intel translation is involved on Apple Silicon.
Run `tools/test-macos-host.sh build/ablac` for the focused native host gate.

Linux can also emit and link both macOS architectures. Point
`ABLA_MACOS_SDK` at an extracted Apple SDK and use the repository helper; it
derives target-library `.tbd` stubs from the pinned LLVM/OpenSSL ABIs and
links with LLVM's Mach-O linker:

```sh
ABLA_MACOS_SDK=/path/to/MacOSX.sdk \
  tools/build-macos-from-linux.sh \
  build/ablac src/orc_main.ab build/release/ablac
```

The produced compiler binaries load Homebrew `llvm@21`; programs that import
TLS additionally load Homebrew `openssl@3`. The helper creates only ignored
files under `build/` and never modifies the SDK.

Run the ordinary test suite with:

```sh
make test
```

The suite is scheduled by
[`abla-testrunner`](https://github.com/AndreBaltazar8/abla-testrunner),
pinned as a git submodule at
`tools/abla-test-driver/vendor/abla-testrunner`. `make test` initializes that
checkout, or clones the locked revision when the tree has no git metadata,
then writes package lock markers so the offline build can use it. A dirty
submodule working tree is rejected. Clone with `--recurse-submodules`, or let
the prepare step initialize the submodule. Override the concurrency on a
smaller machine with `ABLA_TEST_JOBS=4 make test`.

The complete test and fixed-point gate is substantially heavier. Each compiler
worker is bounded to 4 GiB; aggregate pressure depends on the selected job
count:

```sh
make check
```

The build has one compiler and a deliberately small target surface:

```sh
make bootstrap     # fetch and verify the pinned published host compiler
make ablac         # rebuild build/ablac from src/*.ab
make test          # run the self-hosted conformance suite
make self-rebuild  # prove a byte-identical compiler fixed point
make check         # test plus fixed point
make clean         # remove generated files
```

On an empty build directory, `make` downloads the checksum-pinned native
compiler for the host from `v0.2.10`, then immediately recompiles the current
`src/` graph.
No C++ compiler implementation or generated-C bootstrap is involved.

## Using the compiler

`make ablac` produces the single compiler interface:

```sh
build/ablac build program.ab -o build/program
build/ablac build program.ab -o build/program --fast
ABLA_MACOS_SDK=/path/to/MacOSX.sdk \
  build/ablac build program.ab --target arm64-macos -o build/program
build/ablac run program.ab
build/ablac repl
build/ablac serve program.ab
```

Projects can import locked packages through typed compile-time source
providers:

```abla
import github("AndreBaltazar8/abla-mvc")
```

Run `build/ablac package update --project .` to resolve/update `abla.lock`;
ordinary and `--offline` builds never change locked revisions. Providers can
use Git or return generated source files directly. See [package
imports](docs/packages.md) for the `ImportSource` protocol, custom providers,
and vendoring.

Hosted LLVM emits native executables, libraries, and Wasm modules. The former
raw x86-64 Linux target was retired with its C/assembly startup; a future
freestanding target must provide startup and allocation from Abla.

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
- [WebSocket echo server](examples/websocket-echo-server.ab) demonstrates
  routed upgrades, bounded messages, ping/pong, and graceful close handling.
- [Event HTTP server](examples/event-http-server.ab) demonstrates the bounded
  persistent-connection manager and output backpressure path.
- [HTTPS client](examples/https-client.ab) demonstrates certificate-verified
  TLS with transparent HTTP response framing.
- [UDP echo](examples/udp-echo-once.ab) demonstrates bounded datagrams and
  source-address replies.

## Project principles

- Use one coherent language model for compile-time and runtime execution.
- Validate compiler-generated syntax and declarations through the ordinary
  parser, resolver, type checker, ownership checker, and IR verifier.
- Make filesystem, environment, network, clock, and native access explicit
  capabilities rather than invisible compiler privileges.
- Keep builds deterministic, bounded, transactional, and reproducible.
- Keep the compiler readable, self-hosted, and fixed-point tested before
  promotion.
- Keep hosted facilities optional and maintain a libc-free production target.

## Documentation

- [Language contract](docs/language.md)
- [Toolchain interface](docs/toolchain.md)
- [Compiler extension API](docs/compiler-api.md)
- [Programmable builds](docs/programmable-builds.md)
- [Package imports](docs/packages.md)
- [Networking, UDP, WebSockets, and realtime RPC](docs/networking.md)
- [Bootstrap and trust model](docs/bootstrap.md)
- [Self-hosting status](docs/self-hosting.md)
- [Standard library](docs/standard-library.md)
- [Compile-time subparsers](docs/subparsers.md)
- [Reliability roadmap](docs/reliability-roadmap.md)
- [Freestanding follow-on work](docs/full-self-hosting.md)
The [original implementation audit](docs/original-audit.md) separates behavior
that was demonstrated by the prototype from incomplete or aspirational design.

## Community

Join the [Abla Discord community](https://discord.gg/qxrQyJBxtK) to ask
questions, share experiments, and discuss the language, compiler, and
ecosystem. Discord is for conversation; bugs and durable design decisions
should remain in the repository.

## Contributing

The language is still defining its safety, bootstrap, package, and extension
contracts. Contributions should include focused positive, negative, and
regression tests and preserve the documented resource and reproducibility
gates.

## License

Abla is licensed under the [Mozilla Public License 2.0](LICENSE).
