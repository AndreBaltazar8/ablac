# Push and PR CI

[ci.yml](../.github/workflows/ci.yml) runs tests on every push to `master` and on
pull requests. It only tests: it never tags, packages or publishes. Releases stay
in the hand-started [release workflow](../.github/workflows/release.yml).
André approved it for tests only on 2026-11-05.

The triggers are every push to `master` and the default PR events
(opened, synchronize and reopened). No source-path filter can accidentally miss
a stdlib, test or build-script change. New commits cancel the older CI run for
the same PR/ref; the group does not overlap release CI. Only the latest state is
promised coverage during a rapid sequence of pushes.

Linux uses the existing pinned Nix shell and `make ablac` (which verifies and
bootstraps the pinned compiler, then builds current source), followed by `make
test` with `JOBS=8`. Nested native/codegen builds default to one worker, and the
nested self-hosted runner defaults to one test, to avoid multiplying eight suite
commands into many LLVM workers. The initial standalone compiler build can use
four workers. Individual concurrency fixtures retain their explicit overrides.
There is no warm compiler/object cache across CI runs to conceal missing inputs.
The 8 MiB suite-parent stack avoids the capped-thread failures caused by an
inherited 128 MiB stack; compiler launchers set their own larger stack.

One standard `macos-15` Apple Silicon job installs bottled LLVM 23, LLD, OpenSSL
and Binaryen, fetches the checksum-pinned bootstrap, builds stage 1 and stage 2,
runs `test-macos-host.sh`, then `test-pure-self-rebuild.sh` with stage 2. That last
script builds stage 3, compares retained or freshly emitted IR, checks the Darwin
adapter/program object and runs a newly compiled child. It exercises the
relative/absolute compiler-entry paths that exposed the private-symbol release
regression. The native host script covers Mach-O/IO, filesystem/home, process
pipelines/capture, Unix sockets, HTTP peer metadata, UUID and JIT paths. This is
a targeted macOS gate, not the full Linux suite. The development runner requires
Python 3 on `PATH` on macOS. Its standard-library kqueue supervisor watches the
runner shell's lifetime and stops the detached payload group even if the caller's
whole process group is killed. Python is not added to released compiler packages.
The host gate tests caller-group SIGKILL with both ordinary and TERM-ignoring
descendants. Intel macOS, all packaging,
release publication and the broader platform matrix remain in release CI.

Both jobs use SHA-pinned existing actions, read-only repository permissions and
checkout without persisted credentials. There is no `pull_request_target`,
publishing permission, secret-dependent step or paid larger
runner. Missing Homebrew bottles fail rather than build LLVM from source. Only
failure logs are uploaded, retained for three days; compiler IR, binaries and
whole build directories are excluded. No new Actions cache is allocated.

## Runtime and cost estimate

These are estimates, not a dispatched validation. Public read-only job metadata
from the successful [release run 41764608014](https://github.com/AndreBaltazar8/ablac/actions/runs/41764608014)
provided the following timings on 2026-11-04:

| Existing step | Linux | Apple Silicon macOS |
| --- | ---: | ---: |
| Toolchain installation | Nix preparation separate | 50 s |
| Checksum-pinned bootstrap | 1 s | 1 s |
| Stage 1 | 129 s | 89 s |
| Stage 2 | 90 s | 81 s |
| macOS host test | — | 4 s |
| Pure self-rebuild | 123 s | 92 s |

The earlier host-test duration predates the expanded current script. The proposed
macOS compiler chain costs roughly 5–6 minutes on that reference; budget **6–12
minutes** including setup and expanded host checks, with a **25-minute job
limit** and 20-minute per-stage build bound. Bottles/network/runners can vary;
the first approved CI run must establish the actual baseline.

For Linux, a prior local 8-job suite measurement was about 240 seconds on a
faster workstation, before later test optimizations; this is a conservative
planning input, not a fresh suite or GitHub measurement. A standard public Ubuntu runner currently
has four CPUs/16 GB, versus three CPUs/7 GB on Apple Silicon macOS according to
[GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Allow **10–20 minutes** for pinned Nix downloads, the current compiler build and
the 8-job suite, with a **40-minute job limit**. The two jobs run in parallel:
expected elapsed feedback is roughly **10–20 minutes**, or **16–32 total runner
minutes** per uncancelled revision, without queue time. No claim that local
performance scales linearly to hosted CPUs.

The repository was verified public via the read-only repository API on
2026-11-04. [GitHub's billing documentation](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
says standard hosted runners for public repos are free and do not consume
included compute; larger runners are billed. Artifact/cache storage is separate,
which is why this draft keeps only short-lived failure logs. Recheck the budget
if repository visibility or runner choice changes; do not apply the old macOS
minute-multiplier calculation to this public-repo proposal.

## Local review and remaining validation

Local validation passed: actionlint 1.7.12 including embedded ShellCheck 0.11.0,
plus `git diff --check`. Command interfaces were compared against the current
release workflow, Makefile and test/build scripts. The draft suffix leaves only
Release as an active workflow. No compiler rebuild, full suite or hosted runner
was started for this review. Linux job execution, macOS execution, hosted
timing, Homebrew availability and cancellation/artifact behavior remain
unverified until André authorizes activation. Static validation cannot establish
that the platform tests pass.
