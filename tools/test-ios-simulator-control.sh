#!/usr/bin/env bash
# Exercise the Simulator harness's actual C-control retry helper with scripted launch results.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source=${1:-$root/tools/test-ios-simulator.sh}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '%s\n' 'import assert from "node:assert/strict";' >"$work/check.mjs"
awk '/^\/\/ BEGIN simulatorDeadlineControl / {inside=1; next}
     /^\/\/ END simulatorDeadlineControl/ {inside=0}
     inside {print}' "$source" >>"$work/check.mjs"
cat >>"$work/check.mjs" <<'JS'
assert.strictEqual(typeof simulatorDeadlineControl, "function");
const marker = "ios-deadline-control: waiting for SIGALRM";
const good = { status: null, signal: "SIGALRM", stderr: marker };
const before = { status: null, signal: "SIGTERM", stderr: "", error: { code: "ETIMEDOUT" } };
const enteredTimeout = { ...before, stderr: marker };
const crashed = { status: null, signal: "SIGSEGV", stderr: "" };
const missing = { status: null, signal: null, stderr: "", error: { code: "ENOENT" } };
function check(results, expectedCalls, expectedWaits) {
  let calls = 0, waits = 0, reports = 0;
  const actual = simulatorDeadlineControl(
    () => { assert.ok(calls < results.length, "unbounded retry"); return results[calls++]; },
    () => { waits++; },
    () => { reports++; });
  assert.strictEqual(calls, expectedCalls);
  assert.strictEqual(waits, expectedWaits);
  assert.strictEqual(reports, expectedWaits);
  assert.strictEqual(actual, results[expectedCalls - 1]);
}
check([good], 1, 0);
check([before, good], 2, 1);
check([enteredTimeout], 1, 0);
check([crashed], 1, 0);
check([missing], 1, 0);
check([before, before], 2, 1);
let calls = 0;
assert.throws(() => simulatorDeadlineControl(
  () => { calls++; return before; },
  () => { throw new Error("bootstatus failed"); },
  () => {}), /bootstatus failed/);
assert.strictEqual(calls, 1);
console.log("Simulator C control: success, bounded pre-entry retry, post-entry timeout, crash, non-timeout launch error, repeated timeout and failed readiness checks passed");
JS
node "$work/check.mjs"
