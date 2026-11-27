# Push, PR and release CI

[ci.yml](../.github/workflows/ci.yml) runs on pushes to `master`, pull requests
and manual dispatch. It tests without publishing. New revisions cancel older
runs in the same CI ref/PR group; [release.yml](../.github/workflows/release.yml)
has a separate, manually dispatched build/publish workflow. The CI checkout
has no persisted credentials and uses SHA-pinned actions and read-only
repository permissions.

## Required checks on ordinary pushes

| Job ID | Runner and scope |
|---|---|
| `linux` | Ubuntu 24.04, six shards of `make test`, each building the checksum-pinned bootstrap and then rebuilding the compiler with its own backend; job name `Linux suite (shard ${{ matrix.shard }}/6)` |
| `macos` | Native Apple Silicon (`macos-15`) and Intel (`macos-15-intel`) compiler/host checks, each lane building stage 1 and stage 2: on each architecture a host lane and a live lane (`macOS host tests (Apple Silicon)`, `macOS host and compiler fixed point`; `macOS host and compiler fixed point (Intel)`, `macOS live compiler tests (Intel)`), and on Intel a third, `macOS system checks (Intel)`, with the stage-1 BSD calls, the compile-time thread checks, the analyze session and the libSystem import guard (on Apple Silicon these ride the host and live lanes; the matrix flags `bsd`, `ct_threads`, `analyze_session`, `import_guard` place them) |
| `windows-cross`, `windows-run` | Ubuntu cross-builds the Windows x86-64 programs; `windows-latest` runs them (freestanding, hosted, the standard-library programs of `tests/cases/windows/programs.txt`, crash reports) and compares their output with Linux |
| `windows-arm64-cross`, `windows-arm64-run` | The same for Windows ARM64, run on `windows-11-arm` |
| `libc-free-aarch64` | Ubuntu cross-builds the module corpus for AArch64 and guards libc-free links and the explicit exceptions |
| `libc-free-riscv64` | The same for RISC-V 64, in three parts |
| `static-compiler` | Ubuntu builds the x86-64 static compiler; checks no loader/no needed library, a child compile/run and the static compiler fixpoint |
| `static-compiler-aarch64` | Ubuntu cross-builds the static AArch64 compiler on three runners (`STATIC_AARCH64_PART`), each building a third of the module corpus with it under qemu; part 1 also runs its compiler/program/JIT/compile-time checks; no native AArch64 full suite |

The Linux shards are chosen by `RUN_TESTS_SHARD` in `tools/run-tests.sh`, using
checked-in cost history to keep the partition stable across runners. They run
with `JOBS=8`; nested native/codegen builds use their own bounds so workers do
not multiply without limit. The suite-parent stack stays at 8 MiB. Android
NDK and bionic image downloads are checksum-pinned; the suite then executes
Android library exports under qemu with bionic. That is not a device/UI test.

Every Mac entry builds stage 1 and stage 2. The `host` lanes exercise
`test-macos-host.sh`, foreign-thread entry, collection, stack guards and
emulated TLS; the `live` lanes live run, watch mode, test-watch and REPL
sessions; one lane per architecture checks the libSystem import guard. On
Intel, emulated TLS, the import guard, the stage-1 BSD calls, the compile-time
thread checks and the analyze session run in the third, `checks` lane. Only the
Apple Silicon `live` lane runs the compiler fixed-point/native child and iOS
Simulator steps in push CI. These are selected host gates, not the Linux
suite. The REPL's util-linux PTY/editor check skips on
macOS; session coverage alone does not verify interactive editing there.

The configured timeouts are 90 minutes for Linux and Mac jobs, 60 for the
AArch64 module-link job, and 75 for each static compiler job. Those are limits,
not performance estimates. Historical local or hosted timings do not establish
current latency under queueing, runner changes or a growing suite.

## Optional manual checks

The workflow-dispatch inputs can replace normal jobs with targeted probes.
Read their `if:` conditions before interpreting an omitted job as a failure
or a pass. Optional jobs include:

- `macos-published-rebuild`: exact v0.2.47 published rebuild comparison.
- `macos-runtime-bench`: native Mac runtime measurements.
- `android-pointer-tags-control`: tagged-pointer positive and negative controls.
- `xtensa-companion-install` and `xtensa-companion-install-report`: explicit
  installed-companion checks and combined report on all three compiler hosts.
- `xtensa-companion-routing`: installed stock-parent routing checks.

The Linux suite job also has an opt-in frozen Xtensa compiler-memory probe.
These checks are not all exercised by an ordinary push. The separate
[bootstrap convergence workflow](../.github/workflows/bootstrap-convergence.yml)
is another manual check; its route convergence is not an independent compiler
implementation or proof against a compromised shared seed.

## Tests outside the suite

Every test script runs from the suite's recipe (`make test-serial`), a workflow,
`tests/abla-tests.json` or another script, except the few listed with their
reasons in [tests-outside-suite.txt](../tools/tests-outside-suite.txt): tests
that need an AArch64 board, a live network, a Go module from the local cache or
about a quarter of an hour. Run those by hand when their area changes.
`tools/test-test-reachability.sh`, a suite guard, fails on a test script that
has neither a caller nor an entry there. Lists that only select from the suite,
such as `tools/test-quick.txt`, do not count as callers.

## Releases and logs

Release's `compiler` job ([release-compiler.yml](../.github/workflows/release-compiler.yml),
called as `compiler-linux` and as the two-runner `compiler-macos`) builds and packages Linux x86-64, macOS arm64 and
macOS Intel compilers. The static suite (four shards, release mode) needs only `compiler-linux`;
publishing needs all of them. The Linux entry also prepares static x86-64 and AArch64
artifacts; current source promotes static x86-64 to the default raw compiler
name starting with v0.2.65. Source workflow entries are not proof that an older
release published the corresponding files. Packaged-toolchain smoke,
portability, self-rebuild and companion checks have their own scopes; they do
not run the entire push suite. `publish_release: false` exercises preparation
without publishing.

Failure logs are uploaded with short retention (normally three days). The
static jobs include their failure logs explicitly; optional probe jobs can
retain objects and manifests for diagnosis. CI uploads no shared warm compiler
cache. Consult the actual run and retained per-test logs for a verdict. This
page describes source configuration and does not assert a fresh hosted run.
