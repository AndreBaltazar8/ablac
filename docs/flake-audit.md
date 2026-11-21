# Flake audit evidence

CI audit source: `8b069114febef2595bdd00647a5169d1f37e57c0` (master before batch ED).
The initial CI sample is the 100 most recent master runs of the `CI` workflow:
52 succeeded, 29 failed, 18 were cancelled and one was still running when queried.
These are **workflow outcomes, not a flake rate**: commits and platforms differ,
and a failed workflow can contain multiple failed jobs.
The initially running workflow subsequently succeeded: [44925159998](https://github.com/AndreBaltazar8/ablac/actions/runs/44925159998)
checks the exact baseline source on Linux, both Macs and the static compiler
targets. Its two Linux shards report 264/264 and 280/280 passing commands (544 in
total). The final sample therefore has 53 successes, 29 failures and 18 cancellations.

The local evidence directory is `build/flake-audit/ci/`: `runs.json` records the
sample, `<run-id>.jobs.json` records failed steps, and `<run-id>.log` contains
`gh run view --log-failed` output. `44912242520.success.log` is the complete later
successful run at `7b17d8a5a719b899634338fb0486e74e5f041d4a`. It includes passing
results for every Linux test listed below and the macOS capture, emutls and
Simulator checks. Local logs are evidence artifacts, not committed source.
`44925159998.success.log` and `44925159998.current.json` preserve the exact-baseline
workflow's complete log and terminal job states too.

| Test or check | Failed run(s) | Cause and state on baseline master |
| --- | --- | --- |
| `test-ct-bridge.sh` | [43918141314](https://github.com/AndreBaltazar8/ablac/actions/runs/43918141314), 43939540016, 43974380493 | One JSON compile-time tier hit its 120-second wall guard while the other completed. The bridge checker now reports exhausted budgets separately from semantic mismatches, gives known long cases a larger budget, and normalizes timing-dependent diagnostics (`19f70d55f` and later changes). A timeout is not proof of parity. |
| `test-compiler-memory-peak.sh` | [44071842937](https://github.com/AndreBaltazar8/ablac/actions/runs/44071842937), 44141352785, 44159978805, 44227899028 | Measured 1,705,204–1,732,496 kB exceeded the old 1,550,000 kB record's 10% bound. A measured baseline update and minimum of five rounds landed in `d8347f690`; the current test also compares absolute and relative source paths. These failures alone do not demonstrate a runtime race. |
| `test-gc-stress-io.sh` (`http-event.ab`) | [44635216315](https://github.com/AndreBaltazar8/ablac/actions/runs/44635216315) | Product race: GC stop used shared clock scratch, leaving a stress run hung until the 600-second guard. Thread-local scratch fixed in `6377c1774` (#1040). |
| `test-compiler-capture-process.sh` on macOS | [43963577023](https://github.com/AndreBaltazar8/ablac/actions/runs/43963577023), 44648075656, 44865623174 | Run 44865623174 diagnoses a product race between parent and child process-group setup: child `setpgid` reported EPERM although the requested group was already established. `c5d8346a5` verifies the achieved group before accepting that result, with a session-leader regression control. The two older launch failures lack step/errno diagnostics; attributing them to the same cause remains an inference. |
| `test-emutls.sh` on macOS | [44159978805](https://github.com/AndreBaltazar8/ablac/actions/runs/44159978805), 44250191803, 44254460587, 44442501935, 44515218684, 44526433591 | Several distinct product/integration failures: foreign-thread table reclamation (reworked in `a6abc238d`/`db7b84f80`), dylib debug-printer reference to executable-only `_mh_execute_header` (`36c7ede1a`), C driver feature macro, then concurrent pthread-key initialization (`aeb8a65a6`). The last is a confirmed race: a competing thread used the in-progress sentinel as a pthread key. Current control starts foreign threads together in fresh processes. |
| `test-ios-simulator.sh` | [44686270210](https://github.com/AndreBaltazar8/ablac/actions/runs/44686270210) | Infrastructure readiness: a pure C baseline timed out before Abla ran while Simulator launch services were starting. `5fa014849` adds one baseline retry after another `bootstatus`; a second failure still fails the gate. |
| `test-live-jit.sh` on macOS | [44790466020](https://github.com/AndreBaltazar8/ablac/actions/runs/44790466020) | Deterministic IR-check mismatch: the thread-local assertion counted one LLVM TLS form and missed macOS's general-dynamic form (10 reload modules, zero matched declarations). `93d1fbba4` accepts both forms. |
| `test-release-after.sh` | [44508261484](https://github.com/AndreBaltazar8/ablac/actions/runs/44508261484) | Deterministic fixture dependency on the caller's Git identity. Fixture-local identity fixed in `7b27afafc`. |
| `test-libc-functions.sh` / `libc-spawn` | [44837861069](https://github.com/AndreBaltazar8/ablac/actions/runs/44837861069) | Deterministic shell difference: dash rejects a multi-digit redirection descriptor. `4fe7c1058` keeps ten dup2 actions but redirects through descriptor 9. |

Additional failed workflow steps were compiler/bootstrap setup, rather than
intermittent test assertions: missing `libLLVM.so.23.1`, missing compiler artifacts
after failed installation, static compiler allocation limits, and AArch64 LLVM
half-float linker symbols (`415ba0ca3` removes the latter dependency). They are
retained in the CI evidence and excluded from test-flake counts. A missing
compiler also explains the `test-ct-stop-threads.sh` failure in run 44244744710;
it is not evidence that its threading assertion failed.

Focused validation exposed one additional test-isolation defect locally:
`test-shards.sh` inherited the parent's `RUN_TESTS_FILTER`, exclusions and custom
recipe, while asserting properties of the complete suite. A private fixture
passed with the default selection, failed with `RUN_TESTS_FILTER=tools/test-shards\.sh`,
and passed with that same filter after the helper cleared the three selectors.
The before/after logs are `build/flake-audit/shard-filter-{before,after}.log`.
The soak fixture now poisons all three selectors and checks that the actual
shard helper still verifies the whole recipe. This is a deterministic context
leak, distinct from a runtime race.

The runner also accepted a nonexistent `compiler.bin` as the fingerprint path
when given a bare compiler binary: `readlink -f` succeeds for a missing final
component. That produced an empty stamp and discarded the cache every run. The
runner now selects a companion only when it exists. Private controls fail with
the original runner and pass with the fix, checking both cache reuse and
invalidation for direct binaries and launcher payloads.

The expanded audit inspected job/step metadata for all 100 workflows, including
cancelled/successful workflows, and earlier attempts for all four rerun workflows:

| Check | Failed then passed on the same commit | Finding |
| --- | --- | --- |
| Published Xtensa catalog | [43861818000](https://github.com/AndreBaltazar8/ablac/actions/runs/43861818000), attempts 1/2 | Three curl connection timeouts, exit 28; the rerun's published-checksum step passed. External network availability. |
| macOS `unix-stream` fixture | [44459677615](https://github.com/AndreBaltazar8/ablac/actions/runs/44459677615), attempts 1/2 | Exit 4 identifies `httpOnce`; the rerun passed. The current fixture retries fork EAGAIN (`42f21c766`, #1032), though the old failure lacks an errno. |
| Simulator C deadline control | [44586994389](https://github.com/AndreBaltazar8/ablac/actions/runs/44586994389), attempts 1/2 | The C baseline passed, but the negative control's entry marker was absent after a long spawn. The Mac owner identified Simulator launch/readiness; the old log does not print the spawn's error/status. |

The Simulator harness now reports that status and retries once after `bootstatus`
only for `ETIMEDOUT` before the C entry marker. Post-entry failures, crashes and
other launch errors are still failures; actual Abla processes get no retry.
`tools/test-ios-simulator-control.sh` exercises seven portable scenarios, including
the retry bound and failed readiness. Removing the retry or retrying after entry
both fail those controls. Real Simulator execution remains a separate Mac CI check.

The fourth rerun, 44480305169, had an unnamed emutls SIGILL in attempt 1 and a
cancelled attempt 2; it is not counted as a successful rerun. Cancelled workflows
also exposed more existing emutls failures and a `dylib-plain.release _fork`
allowlist gap (`3fb6828b3`). Missing compiler artifacts after cancelled setup
remain infrastructure failures. Some cancelled-job downloads are partial; raw
logs and metadata are retained rather than counting unavailable logs as passes.

One pre-EF quiet sweep completed on compiler core `c2e0a4b2` with tooling at
`716402c8`: **546 unique commands, 546 passed, 0 failed**, with
`RUN_TESTS_FULL=1`. Individual checks retain any explicit `--fast` smoke builds.
The partial second sweep was retired at the EF rebase and
is not a completed sweep. Its evidence is archived under
`~/archive/ablac-cx6-flakes/retired-716402c8/`.

Subsequent campaign inputs use a detached snapshot of master `9b47085b`, isolated
from the follow-up branch. Each full sweep uses sixteen disjoint shards with an
exact recipe-union check. Worker build-slot holds are capped below 600 seconds
and requeued between shards. Loaded passes add eight busy loops on the same
eight CPUs (24–31) as the eight suite jobs; quiet means no intentional extra
load, while other work on the machine still runs. Keep results from different
compiler snapshots separate; a queued or partial run is never a full-suite pass.

The first `9b47085b` quiet sweep exposed a `test-tls-session.sh` failure at
its first IPv6 TLS 1.3 connection: `result failed connect`, while the server
log reported `ACCEPT [::]:44289`. That is OpenSSL's startup marker, not proof
of a completed client handshake. The failed command and server log are retained
in `~/archive/ablac-cx6-flakes/tls-9b-first-failure/`. Fifty fresh-server sessions
using the same binary passed under syscall tracing. With additional failure
diagnostics, five quiet and five loaded full test executions also passed. This
does not establish a cause or justify retrying failed connections. The fixture
now reports the failed connection descriptor and captures the server log and
socket state on an unexpected positive-case failure. Full sweep rates must come
from completed campaign unions, separately from these diagnostic reproductions.

The first loaded sweep on `9b47085b` also failed `test-ct-bridge.sh` for
`ct-site-errors/late.ab`. This fixture polled the clock for a minute; its own
diagnostic harness supplied a one-second deadline, but the bridge loopback did
not. The slower bridge tier completed the minute, while the interpreter later
spent its 50-million-step budget in 33.3 seconds. The resulting success/error
mismatch depended on execution speed. Raw outputs are retained in the campaign's
`loaded-1/part-4/` logs and diagnostic archive.

The fixture now blocks in `sleep`, and the bridge harness supplies and asserts
its intended one-second deadline in both tiers. The diagnostic harness lowers
this case's step budget to 100,000 and requires `E_CT_TIME_LIMIT`, so a clock loop
cannot silently replace the wait. `ct-time-limit/clock.ab` separately retains
the regression for an interrupt inside a clock-provider call. No step budget
is increased.

Focused validation also exposed the diagnostic harness's one-second timer
pre-empting the recursion fixture's stack-depth guard in the interpreter, while
native code reached the intended guard. The timer now applies only to `late`;
other fixtures retain their own error guards and the outer 120-second hang
guard. The recursion case explicitly requires `E_EVAL_STACK_DEPTH` in both tiers.
