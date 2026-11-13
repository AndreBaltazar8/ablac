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
xcrun simctl list devices available --json > "$directory/simulators.json"
node - "$directory/simulators.json" "$directory/ios-caller" "$directory/ios-baseline" "$directory/ios-deadline-negative" <<'SIM'
const assert = require("assert");
const { spawnSync } = require("child_process");
const fs = require("fs"), path = require("path");
const [simulators, caller, baseline, negative] = process.argv.slice(2);
const allDevices = JSON.parse(fs.readFileSync(simulators, "utf8")).devices;
const devices = Object.entries(allDevices).filter(([runtime]) => runtime.includes(".iOS-"))
  .flatMap(([, group]) => group.filter((device) => device.isAvailable));
assert.ok(devices.length, "No available iOS Simulator runtime; this gate does not download one");
const rank = (device) => (device.state !== "Booted" ? 1 : 0);
devices.sort((a, b) => rank(a) - rank(b) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0) || (a.udid < b.udid ? -1 : a.udid > b.udid ? 1 : 0));
const device = devices[0];
const udid = device.udid;
const bootedHere = device.state !== "Booted";
console.log("iOS Simulator:", device.name, udid);
const simctl = (args, options) => spawnSync("xcrun", ["simctl", ...args], { encoding: "utf8", ...options });
const checked = (result, what) => { assert.strictEqual(result.status, 0, what + ": " + (result.status === null ? result.signal : result.status) + " " + (result.stderr || "")); return result; };
try {
  if (bootedHere) checked(simctl(["boot", udid], { timeout: 60000 }), "boot");
  checked(simctl(["bootstatus", udid, "-b"], { timeout: 240000, stdio: "inherit" }), "bootstatus");
  // A C-only process separates launch-service readiness from Abla startup.
  console.log("iOS Simulator: launch pure C baseline");
  const base = checked(simctl(["spawn", udid, path.resolve(baseline)], { timeout: 120000, stdio: ["ignore", "pipe", "inherit"] }), "baseline");
  process.stdout.write(base.stdout);
  assert.ok(base.stdout.includes("pure C baseline ready"));
  console.log("iOS Simulator: deliberate execution-deadline control");
  const control = simctl(["spawn", udid, path.resolve(negative)], { timeout: 120000 });
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
  if (bootedHere) simctl(["shutdown", udid], { timeout: 60000 });
}
SIM
