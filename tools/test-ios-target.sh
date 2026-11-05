#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
directory="$project_root/build/ios-target-test"
mkdir -p "$directory"

# Object generation uses LLVM's Apple backend, not an installed SDK. The
# archive/Simulator gate separately checks adapter compilation with real SDKs.
env -u ABLA_MACOS_SDK -u ABLA_APPLE_SDK_IPHONEOS \
    -u ABLA_APPLE_SDK_IPHONESIMULATOR \
    "$compiler" build tests/cases/ios-target/objects.ab \
    -o "$directory/driver" --fast --no-cache
"$project_root/tools/run-limited.sh" "$directory/driver"
for slice in device simulator; do
    llvm-objdump --macho --private-headers "$directory/$slice.o" \
        > "$directory/$slice.headers"
    llvm-nm "$directory/$slice.o" > "$directory/$slice.symbols"
    grep -q 'LC_BUILD_VERSION' "$directory/$slice.headers"
    grep -q ' _abla_ios_answer$' "$directory/$slice.symbols"
    llvm-nm --undefined-only "$directory/$slice.o" > "$directory/$slice.undefined"
    if grep -Eq '(^|[[:space:]])_?(LLVM|LLJIT)' "$directory/$slice.undefined"; then
        echo "iOS target: LLVM/JIT reference escaped into $slice object" >&2
        exit 1
    fi
done
grep -Eiq 'platform[[:space:]]+(IOS|2)[[:space:]]*$' "$directory/device.headers"
grep -Eiq 'platform[[:space:]]+(IOSSIMULATOR|7)[[:space:]]*$' "$directory/simulator.headers"
for fixture in unknown-sdk mismatched-sdk; do
    rm -f "$directory/$fixture"
    if "$compiler" build "tests/cases/ios-target/$fixture.ab" \
        -o "$directory/$fixture" --fast --no-cache \
        >"$directory/$fixture.log" 2>&1; then
        echo "iOS target: accepted $fixture" >&2
        exit 1
    fi
    code=E_BUILD_TARGET_SDK
    if [[ $fixture == mismatched-sdk ]]; then code=E_BUILD_TARGET_DEFINITION; fi
    grep -Fq "error[$code]" "$directory/$fixture.log"
    if [[ $fixture == unknown-sdk ]]; then [[ ! -e "$directory/$fixture" ]]; fi
done
echo 'iOS target: SDK-free device/simulator objects and SDK refusals passed'
