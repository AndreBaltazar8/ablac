#!/usr/bin/env bash
# Exercise the Simulator harness's actual C-control retry helper and boot helper with scripted launch and simctl results.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source=${1:-$root/tools/test-ios-simulator.sh}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
printf '%s\n' 'import assert from "node:assert/strict";' >"$work/check.mjs"
awk '/^\/\/ BEGIN simulatorDeadlineControl / {inside=1; next}
     /^\/\/ END simulatorDeadlineControl/ {inside=0}
     inside {print}' "$source" >>"$work/check.mjs"
awk '/^\/\/ BEGIN simulatorBoot / {inside=1; next}
     /^\/\/ END simulatorBoot/ {inside=0}
     inside {print}' "$source" >>"$work/check.mjs"
cat >>"$work/check.mjs" <<'JS'
// simulatorBoot against a scripted simctl: each call takes the next result for its verb, and every call is recorded.
assert.strictEqual(typeof simulatorBoot, "function");
const udid = "24EF76FE-5F86-46D7-9E85-81B7ACE4C7F0";
const ok = { status: 0, stdout: "", stderr: "" };
const killed = { status: null, signal: "SIGTERM", stdout: "Monitoring boot status for iPad.\n", stderr: "" };
const alreadyBooted = { status: 149, stdout: "", stderr: "Unable to boot device in current state: Booted" };
const bootError = { status: 164, stdout: "", stderr: "Invalid device state" };
const listing = (state) => ({ status: 0, stdout: JSON.stringify({ devices: { "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [{ udid, state }] } }), stderr: "" });
function boot(script) {
  const calls = [], reports = [];
  const queues = Object.fromEntries(Object.entries(script).map(([verb, results]) => [verb, [...results]]));
  const fake = (args, options) => {
    calls.push({ verb: args[0], args, timeout: options && options.timeout });
    assert.ok(queues[args[0]] && queues[args[0]].length, "unscripted simctl " + args.join(" "));
    return queues[args[0]].shift();
  };
  let error = null;
  try { simulatorBoot(fake, udid, (message) => reports.push(message)); } catch (e) { error = e; }
  const count = (verb) => calls.filter((c) => c.verb === verb).length;
  return { calls, reports: reports.join("\n"), error, count };
}
// Ready at once: one boot, one bootstatus with a bound of at least 7 minutes, nothing shut down.
let run = boot({ boot: [ok], bootstatus: [ok] });
assert.strictEqual(run.error, null);
assert.deepStrictEqual([run.count("boot"), run.count("bootstatus"), run.count("shutdown")], [1, 1, 0]);
for (const call of run.calls) assert.ok(call.timeout > 0, "simctl " + call.verb + " has no timeout");
assert.ok(run.calls.find((c) => c.verb === "bootstatus").timeout >= 420000);
// The failure of 2026-11-27: bootstatus killed at its bound; the state and simctl's output are printed, the device is shut
// down and booted once more, and the second boot is ready.
run = boot({ boot: [ok, ok], bootstatus: [killed, ok], list: [listing("Booting")], shutdown: [ok] });
assert.strictEqual(run.error, null);
assert.deepStrictEqual([run.count("boot"), run.count("bootstatus"), run.count("shutdown")], [2, 2, 1]);
assert.match(run.reports, /bootstatus SIGTERM/);
assert.match(run.reports, /Monitoring boot status/);
assert.match(run.reports, /device state Booting/);
assert.ok(run.calls.findIndex((c) => c.verb === "shutdown") < run.calls.map((c) => c.verb).lastIndexOf("boot"), "the retry did not shut down first");
// A device that is already booted goes straight to bootstatus.
run = boot({ boot: [alreadyBooted], bootstatus: [ok] });
assert.strictEqual(run.error, null);
assert.deepStrictEqual([run.count("boot"), run.count("bootstatus")], [1, 1]);
// A boot that fails is printed and retried once without a bootstatus for it.
run = boot({ boot: [bootError, ok], bootstatus: [ok], list: [listing("Shutdown")], shutdown: [ok] });
assert.strictEqual(run.error, null);
assert.deepStrictEqual([run.count("boot"), run.count("bootstatus")], [2, 1]);
assert.match(run.reports, /boot 164[\s\S]*Invalid device state/);
// Two failures fail the step: bounded at two boots, with the state printed after each.
run = boot({ boot: [ok, ok], bootstatus: [killed, killed], list: [listing("Booting"), { status: 1, stdout: "", stderr: "" }], shutdown: [ok] });
assert.match(String(run.error), /did not boot after two attempts/);
assert.deepStrictEqual([run.count("boot"), run.count("bootstatus"), run.count("shutdown")], [2, 2, 1]);
assert.match(run.reports, /device state Booting[\s\S]*device state unknown/);
console.log("Simulator boot: ready at once, a killed bootstatus retried once after a shutdown, already booted, a failed boot, and two failures passed");
JS
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
