# Abla Test Runner

`abla-test` is a bounded parallel test runner written in Abla. It launches
tests as isolated child processes, gives every step its own combined output
log, enforces timeouts, and keeps command arguments structured instead of
turning them into shell text.

The hosted process adapter uses POSIX facilities available on Linux and macOS.
The manifest and runner code are platform-neutral; Windows will need a hosted
process adapter implementing the same small Abla ABI.

## Why

Large Abla suites have traditionally accumulated shell scripts for compiling
fixtures, checking exit codes, managing parallel jobs, and printing failures.
That makes orchestration difficult to reuse and leaves most suites sequential.
`abla-test` moves those common mechanics into one tested runner:

- up to 64 concurrent test processes, defaulting to the online CPU count;
- sequential steps inside each test and parallel execution across tests;
- expected exit statuses, per-step timeouts, and process-tree termination;
- isolated stdout/stderr logs with failure output surfaced automatically;
- suite and step environment overrides;
- working directories without global `cd` state;
- exclusive barriers for memory-heavy or stateful tests;
- platform selection, name filtering, listing, and fail-fast mode; and
- JSON manifests that can be generated and consumed on any host.

Commands are executed directly. Globbing, pipes, redirects, `$()` and other
shell syntax are never interpreted accidentally. A test that deliberately
needs a shell can declare `sh` and `-c` explicitly.

## Build

```sh
make build
./build/abla-test --help
```

`make check` builds the runner entirely through Abla and exercises manifest
validation, parallel execution, multiple steps, non-zero expected statuses,
exclusive tests, filtering, failure logs, and timeout termination.

## Manifest

Create `abla-tests.json` in the project root:

```json
{
  "version": 1,
  "jobs": 8,
  "timeoutMs": 300000,
  "logDirectory": "build/test-results",
  "environment": {
    "ABLA_MAX_MEMORY_MB": "4096"
  },
  "tests": [
    {
      "name": "crypto",
      "steps": [
        {
          "command": "${root}/../ablac/build/ablac",
          "args": [
            "build", "tests/crypto.ab",
            "-o", "build/crypto-test", "--fast", "--no-cache"
          ]
        },
        {
          "command": "${root}/build/crypto-test",
          "expect": 42,
          "timeoutMs": 20000
        }
      ]
    },
    {
      "name": "database-integration",
      "exclusive": true,
      "platform": "linux",
      "steps": [{
        "command": "docker",
        "args": ["compose", "up", "--abort-on-container-exit"]
      }]
    }
  ]
}
```

Supported substitutions in commands, arguments, directories, and environment
values are `${root}`, `${test}`, and `${log}`. Named `@name@` substitutions can
be supplied with repeatable `--set name=value` options. `platform` may be
`any`, `linux`, or `macos`.

Run it with:

```sh
abla-test
abla-test --jobs 16
abla-test --filter crypto
abla-test --set compiler=/opt/abla/bin/ablac
abla-test --list
abla-test --fail-fast
abla-test --root /path/to/project --file tests/native.json
```

The exit status is `0` when selected tests pass, `1` for test failures, and `2`
for command-line or manifest errors.

## Library use

The scheduling and manifest APIs are also importable:

```abla
import github("AndreBaltazar8/abla-testrunner")

fun main: int = runTestCommand(["--file", "tests/service.json"])
```

## Migration strategy

Start by expressing each existing script as a test with direct command steps.
This immediately centralizes parallelism, timeouts, exit-code checks, and logs.
Then move shell-only setup into explicit Abla fixtures or reusable package APIs.
Keep genuinely platform-specific integration tests marked with `platform`
rather than branching throughout the suite.

Licensed under the MIT License.
