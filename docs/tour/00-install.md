# Install and choose your compiler

Abla releases provide toolchains for Linux x86-64, macOS Apple Silicon and
macOS Intel. Start with the matching **toolchain archive** on the
[release page](https://github.com/AndreBaltazar8/ablac/releases), check its
published checksum, extract it, and put its `bin` directory on your `PATH`.
Use the packaged `bin/ablac` wrapper, which locates the toolchain's libraries
and tools. A standalone compiler binary and a complete toolchain archive
serve different purposes; the standalone file is not an installer.

On Linux, the archive is statically linked: it needs no C library or LLVM on the
host ([installation notes](../../README.md)). Current macOS archives bundle
the patched LLVM and LLD. In GitHub Actions,
the README also shows the checksum-verifying `setup-abla` action. Keep the
compiler and its bundled stdlib together.

For development from a clone on Linux with Nix installed:

```sh
nix-shell
make ablac
build/ablac --version
```

For an installed toolchain, run `ablac --version` instead. Inside this repo,
replace that command with `build/ablac` throughout the tour. A repository build
starts from the release pinned by the bootstrap tool; it does not require a
different source language compiler for Abla's implementation.

See [development setup](../../README.md#development) and the
[toolchain reference](../toolchain.md) for troubleshooting, host requirements
and environment overrides. Once the version command works, move to your
first program.

## Start a project

On a compiler that supports `ablac new`, create and run a starter app
from a directory you own:

```sh
ablac new hello-app
cd hello-app
ablac run --project .
ablac test tests/greeting.ab
```

The app prints `Hello, Abla!`. The scaffold includes a manifest, an entry
at `src/main.ab` and a greeting test. Use `ablac new hello-lib --lib` for
a library skeleton. The [scaffold test](../../tools/test-new-project.sh)
checks that both generated projects build, run and pass their tests.

[Tour](README.md) · [Next: Hello, Abla](01-hello.md)
