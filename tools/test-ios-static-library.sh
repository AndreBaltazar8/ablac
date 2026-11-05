#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
if [[ $(uname -s) == Darwin ]]; then
    ABLA_APPLE_SDK_IPHONEOS=${ABLA_APPLE_SDK_IPHONEOS:-$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}
    ABLA_APPLE_SDK_IPHONESIMULATOR=${ABLA_APPLE_SDK_IPHONESIMULATOR:-$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)}
fi
if [[ -z ${ABLA_APPLE_SDK_IPHONEOS:-} || -z ${ABLA_APPLE_SDK_IPHONESIMULATOR:-} ]]; then
    echo 'iOS static libraries: skipped (configure both Apple SDKs; SDK-free object checks always run)'
    exit 0
fi
export ABLA_APPLE_SDK_IPHONEOS ABLA_APPLE_SDK_IPHONESIMULATOR
directory="$project_root/build/ios-target-test"
mkdir -p "$directory"
"$compiler" build tests/cases/ios-target/archives.ab \
    -o "$directory/archive-driver" --fast --no-cache
"$project_root/tools/run-limited.sh" "$directory/archive-driver"
for slice in device simulator; do
    library="$directory/$slice/libabla_app.a"
    llvm-ar t "$library" > "$directory/$slice.members"
    member=$(grep -E '\.host\.o$' "$directory/$slice.members")
    [[ -n $member ]]
    llvm-ar p "$library" "$member" > "$directory/$slice.adapter.o"
    llvm-objdump --macho --private-headers "$directory/$slice.adapter.o" > "$directory/$slice.adapter.headers"
    if [[ $slice == device ]]; then
        grep -Eiq 'platform[[:space:]]+(IOS|2)[[:space:]]*$' "$directory/$slice.adapter.headers"
    else
        grep -Eiq 'platform[[:space:]]+(IOSSIMULATOR|7)[[:space:]]*$' "$directory/$slice.adapter.headers"
    fi
    llvm-nm --defined-only "$library" > "$directory/$slice.defined"
    grep -q ' _abla_ios_answer$' "$directory/$slice.defined"
    llvm-nm --undefined-only "$library" > "$directory/$slice.undefined"
    if grep -Eq '(^|[[:space:]])_?(LLVM|LLJIT)' "$directory/$slice.undefined"; then
        echo "iOS static library: LLVM/JIT escaped into $slice archive" >&2
        exit 1
    fi
done
echo 'iOS static libraries: both archives contain same-platform Darwin adapters and C exports'
