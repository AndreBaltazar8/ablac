# The Xtensa LLVM

Abla's ESP32 work needs LLVM's experimental Xtensa backend and the patches in
`nix/llvm-xtensa-*.patch`. Compiling that LLVM takes over an hour, so x86_64 Linux
uses a build made once by hand and published as a GitHub release of the fork
[AndreBaltazar8/llvm-project](https://github.com/AndreBaltazar8/llvm-project),
branch `abla/xtensa-23.1.3`: upstream's `llvmorg-23.1.3` with each patch as a commit.
CI never builds it.

`shell.nix` picks:

| Where | LLVM |
| --- | --- |
| x86_64 Linux | `nix/llvm-prebuilt.nix`: fetches the release by URL and sha256 |
| x86_64 Linux, `ABLA_NIX_LLVM_SOURCE=1` or changed patches | `nix/llvm.nix`: builds nixpkgs' LLVM with the patches |
| Other Nix hosts | `nix/llvm.nix` locally; off when `CI` is set |
| `ABLA_NIX_XTENSA=0` | nixpkgs' LLVM, without Xtensa |

`nix/llvm-prebuilt.nix` records a hash of the patches it was built with. If they
change, a local shell builds from source, so the patches being worked on are the
ones in use, and a CI shell stops with an error rather than build for an hour.

macOS doesn't use `shell.nix`: its jobs use Homebrew's LLVM, which has no Xtensa. A
macOS prebuilt would have to be built on a Mac of each architecture.

The packaged `abla-toolchain-x86_64-linux` bundles apt.llvm.org's LLVM on Ubuntu, so
it can't target Xtensa either: the Nix build needs Nix's newer glibc, and can't be
carried to that image. Firmware builds use a Nix shell or a Nix install.

## Adding a patch

1. Write it against `llvm/` as `nix/llvm-xtensa-<name>.patch`, add it to
   `nix/llvm.nix` and to `patchNames` in `nix/llvm-prebuilt.nix`, and develop with
   the local shell, which builds from source once the patches differ.
2. Commit the same change on the fork's branch: `git apply --directory=llvm <patch>`.
3. Point `commit` and `sha256` in `nix/llvm-fork.nix` at it
   (`nix-prefetch-url --unpack <archive url>`).
4. `tools/package-llvm-xtensa.sh llvm-23.1.3-xtensa-<n+1> <directory>`, on this kind
   of machine, not on CI.
5. Compare the new `llc` with the source-built one on Xtensa code, and check the
   archive's contents for local paths and keys.
6. `gh release create` the archive and its `.sha256` on the fork, tagged
   `llvm-23.1.3-xtensa-<n+1>` at the branch's commit.
7. Update `tag`, `sha256` and `patchesSha256` in `nix/llvm-prebuilt.nix`. Moving to a
   new LLVM or nixpkgs repeats this with a new branch.
