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
python3 - "$directory" <<'CLEAN'
from pathlib import Path
import shutil, sys
root = Path(sys.argv[1])
assert root.name == 'ios-target-test' and root.parent.name == 'build'
for name in ['device', 'simulator', 'App.xcframework']:
    path = root / name
    if path.is_symlink(): path.unlink()
    elif path.is_dir(): shutil.rmtree(path)
    elif path.exists(): path.unlink()
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
python3 - "$directory/xcframework.json" <<'PLIST'
import json, sys
libraries = json.load(open(sys.argv[1]))['AvailableLibraries']
assert len(libraries) == 2, libraries
assert {item.get('SupportedPlatformVariant', '') for item in libraries} == {'', 'simulator'}, libraries
for item in libraries:
    assert item['SupportedPlatform'] == 'ios', item
    assert item['SupportedArchitectures'] == ['arm64'], item
    assert item['LibraryPath'].endswith('.a'), item
    assert item['HeadersPath'], item
print('iOS XCFramework: separate arm64 device and Simulator libraries with headers')
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
python3 - "$directory/simulators.json" "$directory/ios-caller" "$directory/ios-baseline" "$directory/ios-deadline-negative" <<'SIM'
import json, subprocess, sys
from pathlib import Path
all_devices = json.load(open(sys.argv[1]))['devices']
devices = [device for runtime, group in all_devices.items()
           if '.iOS-' in runtime for device in group if device.get('isAvailable')]
assert devices, 'No available iOS Simulator runtime; this gate does not download one'
devices.sort(key=lambda item: (item['state'] != 'Booted', item['name'], item['udid']))
device = devices[0]
udid = device['udid']
booted_here = device['state'] != 'Booted'
print('iOS Simulator:', device['name'], udid, flush=True)
try:
    if booted_here:
        subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True, timeout=60)
    subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True, timeout=240)
    # A C-only process separates launch-service readiness from Abla startup.
    print('iOS Simulator: launch pure C baseline', flush=True)
    baseline = subprocess.run(['xcrun', 'simctl', 'spawn', udid, str(Path(sys.argv[3]).absolute())],
                              check=True, text=True, stdout=subprocess.PIPE, timeout=120)
    print(baseline.stdout, end='', flush=True)
    assert 'pure C baseline ready' in baseline.stdout
    print('iOS Simulator: deliberate execution-deadline control', flush=True)
    negative = subprocess.run(['xcrun', 'simctl', 'spawn', udid, str(Path(sys.argv[4]).absolute())],
                              text=True, capture_output=True, timeout=120)
    print(negative.stdout, end='', flush=True)
    print(negative.stderr, end='', file=sys.stderr, flush=True)
    assert 'ios-deadline-control: waiting for SIGALRM' in negative.stderr
    assert negative.returncode in (-14, 14, 142), negative.returncode
    print('iOS Simulator: stalled C process stopped by SIGALRM', flush=True)
    for attempt in range(3):
        print('iOS Simulator: fresh Abla process', attempt + 1, flush=True)
        # Launch may be slow before C main; the C watchdog bounds execution
        # to 15 s. Keep stderr live to identify the last entered export.
        result = subprocess.run(['xcrun', 'simctl', 'spawn', udid, str(Path(sys.argv[2]).absolute())],
                                check=True, text=True, stdout=subprocess.PIPE, timeout=120)
        print(result.stdout, end='', flush=True)
        assert 'Abla C export returned 42' in result.stdout

finally:
    if booted_here:
        subprocess.run(['xcrun', 'simctl', 'shutdown', udid], timeout=60, check=False)
SIM
