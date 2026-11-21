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

Local full-suite and stress results are recorded separately once completed.
After the lead's batch ED rebase, local verification uses master `c2e0a4b24fc10c3c9f08204330410ef4383a55c1`
plus the registered soak-tool fixture. No compiler/runtime changes are made by this branch.
Earlier queued gates ran no builds or suites and were stopped before rebasing.
Under the lead's focused-validation rule, the unstarted full self-gate was
cancelled. `cx6-build-focused-v3.service` runs `make ablac` and the focused tooling
checks; its log is `build/flake-audit/build-focused.log`. No claim of local suite
success follows from a queued job or from the historical CI passes above.
The repeated campaign uses slot 4, sixteen disjoint shards per full suite, releasing
and requeuing between shards. Loaded passes start eight busy loops on the same
eight CPUs (24–31) as the eight suite jobs. Quiet means no intentional extra load;
other work on the machine still runs. Each hold is capped below 600 seconds.
