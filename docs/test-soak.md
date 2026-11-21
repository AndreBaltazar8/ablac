# Repeated test runs

`tools/soak-tests.sh N FILTER [compiler] [new-output-directory]` repeats a selection
from `tools/run-tests.sh` and reports failures per command. `FILTER` is an extended
regular expression over the suite's command text; `''` selects everything. The
compiler defaults to `build/ablac`. `RUN_TESTS_FULL=1` selects the release builds,
and `JOBS`, `RUN_TESTS_COMMANDS`, `RUN_TESTS_EXCLUDE` and `RUN_TESTS_SHARD` retain
their normal runner meanings.

Run in the worktree's `nix-shell shell.nix`, through a systemd user unit and the
shared fair-flock worker build slot. If taking both a full-test and build slot,
take full-test first; avoid spending a hold waiting for another slot. Pin the command and any
intentional CPU load to the slot's CPUs. Choose a batch that fits the slot hold
limit and release/requeue between batches; the soak tool does not acquire slots.
For example, inside an admitted shell:

```sh
RUN_TESTS_FULL=1 JOBS=8 taskset -c 16-23 \
    tools/soak-tests.sh 5 'test-(mutex|stm)\.sh' build/ablac build/test-results/mutex-soak
```

Every invocation creates a new directory (by default `build/test-results/soak.*`).
An existing output directory is refused, so a retry cannot overwrite evidence.
Each iteration uses its own runner output directory, with all command logs, and
also saves the runner's console output in `run-N.log`.

The output files use tab-separated columns:

| File | Columns |
| --- | --- |
| `manifest.tsv` | Key/value rows: source commit, requested runs, filter, compiler, full-build setting, jobs, exclusion, shard, command file |
| `source-diff.txt` | Tracked source changes at invocation, as `git diff --stat` |
| `runs.tsv` | Iteration, runner exit status |
| `results.tsv` | Iteration, command ID, exit status, wall seconds, command, CPU seconds |
| `summary.tsv` | Completed runs, failures, failure percentage, command |
| `failures.tsv` | Iteration, command ID, exit status, command, absolute log path |

`summary.tsv` updates after every complete iteration. It counts observed command
failures, including a consistently failing command; a nonzero rate alone does
not establish that a test is flaky. Compare conditions and diagnose the failure.
The selected command IDs must all appear in each iteration, and command text
must stay the same. Empty selections and incomplete results exit 2. Any observed
test failure exits 1 after all requested iterations; an entirely passing campaign
exits 0. Keep the per-run logs when reporting rates.

The suite runner retains only the output each test writes to its command log.
A test may also write diagnostic files elsewhere under `build/`; preserve those
before the next iteration if they are needed to diagnose a failure.

`tools/test-soak-tests.sh` checks rates against deterministic commands that pass,
fail once then recover, and always fail. It also checks selection, per-failure
logs, evidence preservation, invalid inputs, and refusal of missing results. It
runs the actual suite runner in a private fixture tree, without touching the
worktree's compiler or build cache. It also checks that inherited selection
variables cannot shrink the whole-recipe assertions in `test-shards.sh`, and
that bare compiler binaries retain caches between identical runs while changed
payloads invalidate them. A launcher's text does not replace its companion
payload as the fingerprint.
