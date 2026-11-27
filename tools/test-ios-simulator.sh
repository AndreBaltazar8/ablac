#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Darwin ]]; then
    echo 'iOS Simulator: macOS/Xcode only (SDK-free object checks run separately)'
    exit 0
fi
if [[ $(uname -m) != arm64 ]]; then
    echo 'iOS Simulator: this arm64 slice requires an Apple Silicon Mac' >&2
    exit 1
fi
cd "$project_root"
directory="$project_root/build/ios-target-test"
mkdir -p "$directory"
export ABLA_APPLE_SDK_IPHONEOS=${ABLA_APPLE_SDK_IPHONEOS:-$(xcrun --sdk iphoneos --show-sdk-path)}
export ABLA_APPLE_SDK_IPHONESIMULATOR=${ABLA_APPLE_SDK_IPHONESIMULATOR:-$(xcrun --sdk iphonesimulator --show-sdk-path)}

# Prove the package step runs after the child builds: no old archives or
# framework may make an incorrectly ordered implementation pass.
node - "$directory" <<'CLEAN'
const fs = require("fs"), path = require("path");
const root = process.argv[2];
if (path.basename(root) !== "ios-target-test" || path.basename(path.dirname(root)) !== "build") throw new Error("unexpected directory " + root);
for (const name of ["device", "simulator", "App.xcframework"]) {
  fs.rmSync(path.join(root, name), { recursive: true, force: true });
}
CLEAN
"$compiler" build tests/cases/ios-target/archives-package.ab \
    -o "$directory/archive-driver" --fast --no-cache
"$project_root/tools/run-limited.sh" "$directory/archive-driver"
for slice in device simulator; do
    llvm-ar t "$directory/$slice/libabla_app.a" > "$directory/$slice.members"
    grep -Eq '\.host\.o$' "$directory/$slice.members"
    member=$(grep -E '\.host\.o$' "$directory/$slice.members")
    llvm-ar p "$directory/$slice/libabla_app.a" "$member" > "$directory/$slice.adapter.o"
    llvm-objdump --macho --private-headers "$directory/$slice.adapter.o" > "$directory/$slice.adapter.headers"
    if [[ $slice == device ]]; then
        grep -Eiq 'platform[[:space:]]+(IOS|2)[[:space:]]*$' "$directory/$slice.adapter.headers"
    else
        grep -Eiq 'platform[[:space:]]+(IOSSIMULATOR|7)[[:space:]]*$' "$directory/$slice.adapter.headers"
    fi
    llvm-nm --undefined-only "$directory/$slice/libabla_app.a" > "$directory/$slice.undefined"
    if grep -Eq '(^|[[:space:]])_?(LLVM|LLJIT)' "$directory/$slice.undefined"; then
        echo "iOS Simulator: LLVM/JIT escaped into $slice archive" >&2
        exit 1
    fi
done
plutil -convert json -o "$directory/xcframework.json" "$directory/App.xcframework/Info.plist"
node - "$directory/xcframework.json" <<'PLIST'
const assert = require("assert");
const libraries = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8")).AvailableLibraries;
assert.strictEqual(libraries.length, 2, JSON.stringify(libraries));
assert.deepStrictEqual(new Set(libraries.map((item) => item.SupportedPlatformVariant || "")), new Set(["", "simulator"]), JSON.stringify(libraries));
for (const item of libraries) {
  assert.strictEqual(item.SupportedPlatform, "ios", JSON.stringify(item));
  assert.deepStrictEqual(item.SupportedArchitectures, ["arm64"], JSON.stringify(item));
  assert.ok(item.LibraryPath.endsWith(".a"), JSON.stringify(item));
  assert.ok(item.HeadersPath, JSON.stringify(item));
}
console.log("iOS XCFramework: separate arm64 device and Simulator libraries with headers");
PLIST
xcrun --sdk iphonesimulator clang \
    --target=arm64-apple-ios17.0-simulator \
    -isysroot "$ABLA_APPLE_SDK_IPHONESIMULATOR" -O2 \
    -Itests/cases/ios-target/include tests/cases/ios-target/caller.c \
    "$directory/simulator/libabla_app.a" -pthread -o "$directory/ios-caller"
xcrun --sdk iphonesimulator clang \
    --target=arm64-apple-ios17.0-simulator \
    -isysroot "$ABLA_APPLE_SDK_IPHONESIMULATOR" -O2 \
    tests/cases/ios-target/baseline.c -o "$directory/ios-baseline"
xcrun --sdk iphonesimulator clang \
    --target=arm64-apple-ios17.0-simulator \
    -isysroot "$ABLA_APPLE_SDK_IPHONESIMULATOR" -O2 \
    -DABLA_IOS_DEADLINE_NEGATIVE tests/cases/ios-target/baseline.c \
    -o "$directory/ios-deadline-negative"
# Ad-hoc signing needs no provisioning profile or extended-address entitlement.
codesign --force --sign - "$directory/ios-caller"
codesign --force --sign - "$directory/ios-baseline"
codesign --force --sign - "$directory/ios-deadline-negative"
xcrun simctl list runtimes available --json > "$directory/runtimes.json"
node - "$directory/runtimes.json" "$directory/ios-caller" "$directory/ios-baseline" "$directory/ios-deadline-negative" <<'SIM'
const assert = require("assert");
const { spawnSync } = require("child_process");
const fs = require("fs"), path = require("path");
const [runtimesFile, caller, baseline, negative] = process.argv.slice(2);
// A device of our own on the newest iOS runtime, created, booted and deleted here: a stock device the runner image left
// in an unknown state sat in bootstatus for 240 s twice on 2026-11-27 (runs 46017227075, 46057162825).
const runtimes = JSON.parse(fs.readFileSync(runtimesFile, "utf8")).runtimes
  .filter((runtime) => runtime.isAvailable && (runtime.platform === "iOS" || runtime.identifier.includes(".iOS-")));
assert.ok(runtimes.length, "No available iOS Simulator runtime; this gate does not download one");
const versionKey = (runtime) => runtime.version.split(".").map(Number);
runtimes.sort((a, b) => { const x = versionKey(a), y = versionKey(b); for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (y[i] || 0) - (x[i] || 0); return 0; });
const runtime = runtimes[0];
const types = (runtime.supportedDeviceTypes || []);
const type = types.find((t) => t.productFamily === "iPhone") || types[0];
assert.ok(type, "iOS Simulator runtime " + runtime.identifier + " lists no device type");
const simctl = (args, options) => spawnSync("xcrun", ["simctl", ...args], { encoding: "utf8", ...options });
const outcome = (result) => (result.status === null ? (result.signal || (result.error && result.error.code) || "no status") : String(result.status));
const checked = (result, what) => { assert.strictEqual(result.status, 0, what + ": " + outcome(result) + " " + (result.stderr || "")); return result; };
const created = checked(simctl(["create", "abla-ios-test-" + process.pid, type.identifier, runtime.identifier], { timeout: 120000 }), "create");
const udid = created.stdout.trim();
assert.match(udid, /^[0-9A-F-]{36}$/, "simctl create printed " + JSON.stringify(created.stdout));
console.log("iOS Simulator:", type.name, runtime.name, udid);
// BEGIN simulatorBoot (also exercised without a Simulator by tools/test-ios-simulator-control.sh)
// Boots the device and waits until it is ready, within bounds: at most two boots, each waited for by bootstatus for at
// most readyTimeout. A failed boot or wait prints simctl's output and the device's state, shuts the device down and
// boots once more; a second failure throws.
function simulatorBoot(simctl, udid, report, bootTimeout = 120000, readyTimeout = 420000) {
  const outcome = (result) => (result.status === null ? (result.signal || (result.error && result.error.code) || "no status") : String(result.status));
  const tail = (result) => ((result.stdout || "") + (result.stderr || "")).trim().split("\n").slice(-8).join("\n");
  const state = () => {
    const list = simctl(["list", "devices", "--json"], { timeout: 60000 });
    try {
      const device = Object.values(JSON.parse(list.stdout).devices).flat().find((d) => d.udid === udid);
      return device ? device.state : "not listed";
    } catch (error) { return "unknown (simctl list: " + outcome(list) + ")"; }
  };
  for (let attempt = 1; attempt <= 2; attempt++) {
    const boot = simctl(["boot", udid], { timeout: bootTimeout });
    // simctl refuses to boot a device that is already booted; bootstatus then decides.
    const booted = boot.status === 0 || /current state: Booted/.test(boot.stderr || "");
    if (booted) {
      const ready = simctl(["bootstatus", udid], { timeout: readyTimeout });
      if (ready.status === 0) { report("iOS Simulator: booted (attempt " + attempt + ")"); return; }
      report("iOS Simulator: bootstatus " + outcome(ready) + " (attempt " + attempt + "):\n" + tail(ready));
    } else {
      report("iOS Simulator: boot " + outcome(boot) + " (attempt " + attempt + "):\n" + tail(boot));
    }
    report("iOS Simulator: device state " + state());
    if (attempt === 1) {
      report("iOS Simulator: shutting the device down and booting it once more");
      simctl(["shutdown", udid], { timeout: bootTimeout });
    }
  }
  throw new Error("iOS Simulator: the device did not boot after two attempts (simctl's output and state are above)");
}
// END simulatorBoot
// BEGIN simulatorDeadlineControl (also exercised without a Simulator by the fixture test)
function simulatorDeadlineControl(spawn, waitForReady, report) {
  const marker = "ios-deadline-control: waiting for SIGALRM";
  let result = spawn();
  if (result.error && result.error.code === "ETIMEDOUT" && !(result.stderr || "").includes(marker)) {
    report("iOS Simulator: deadline control timed out before entry; waiting for the Simulator and trying once more");
    waitForReady();
    result = spawn();
  }
  return result;
}
// END simulatorDeadlineControl
try {
  simulatorBoot(simctl, udid, (message) => console.log(message));
  // A C-only process separates launch-service readiness from Abla startup.
  console.log("iOS Simulator: launch pure C baseline");
  // A C process that does nothing can still time out while the Simulator's launch services finish starting ("Waiting on
  // System App": master 1cdcdc60 and one run before it, both green on the next push), so the first failure is retried once
  // after another bootstatus. Nothing of Abla runs here: a second failure is the Simulator's and fails the step.
  const spawnBaseline = () => simctl(["spawn", udid, path.resolve(baseline)], { timeout: 120000, stdio: ["ignore", "pipe", "inherit"] });
  let first = spawnBaseline();
  if (first.status !== 0) {
    console.log("iOS Simulator: pure C baseline failed (" + (first.status === null ? first.signal : first.status) + "); waiting for the Simulator and trying once more");
    checked(simctl(["bootstatus", udid, "-b"], { timeout: 240000, stdio: "inherit" }), "bootstatus after a failed baseline");
    first = spawnBaseline();
  }
  const base = checked(first, "baseline");
  process.stdout.write(base.stdout);
  assert.ok(base.stdout.includes("pure C baseline ready"));
  console.log("iOS Simulator: deliberate execution-deadline control");
  const control = simulatorDeadlineControl(
    () => simctl(["spawn", udid, path.resolve(negative)], { timeout: 120000 }),
    () => checked(simctl(["bootstatus", udid, "-b"], { timeout: 240000, stdio: "inherit" }), "bootstatus after an unstarted deadline control"),
    message => console.log(message));
  console.log("iOS Simulator: deadline control status=" + control.status + " signal=" + control.signal + " error=" + (control.error ? control.error.code : "none"));
  process.stdout.write(control.stdout || "");
  process.stderr.write(control.stderr || "");
  assert.ok((control.stderr || "").includes("ios-deadline-control: waiting for SIGALRM"));
  // Killed by SIGALRM (Python's -14), or simctl reporting it as 14 or 142.
  assert.ok(control.signal === "SIGALRM" || [14, 142].includes(control.status), String(control.status) + " " + control.signal);
  console.log("iOS Simulator: stalled C process stopped by SIGALRM");
  for (let attempt = 0; attempt < 3; attempt++) {
    console.log("iOS Simulator: fresh Abla process", attempt + 1);
    // Launch may be slow before C main; the C watchdog bounds execution to 15 s. Keep stderr live to identify the last
    // entered export.
    const result = checked(simctl(["spawn", udid, path.resolve(caller)], { timeout: 120000, stdio: ["ignore", "pipe", "inherit"] }), "abla caller");
    process.stdout.write(result.stdout);
    assert.ok(result.stdout.includes("Abla C export returned 42"));
  }
} finally {
  simctl(["shutdown", udid], { timeout: 60000 });
  simctl(["delete", udid], { timeout: 60000 });
}
SIM
