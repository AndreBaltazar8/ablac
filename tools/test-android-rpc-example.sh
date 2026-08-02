#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/examples/android-rpc"
library="$output_directory/src/main/jniLibs/arm64-v8a/libabla_app.so"
server="$output_directory/rpc-server"
action_manifest="$output_directory/rpc-action.txt"
invalid_output="$output_directory/invalid-click"

"$compiler" build \
    "$project_root/examples/android-rpc/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache
"$compiler" build \
    "$project_root/examples/android-rpc/android_build.ab" \
    -o "$output_directory/android-build-driver" --fast --no-cache
"$compiler" build \
    "$output_directory/server.ab" \
    -o "$server" --fast --no-cache

[[ -x $server && -s $library && -s $action_manifest ]]
llvm-readelf -h "$library" | grep -q 'AArch64'
if llvm-nm --defined-only "$library" | grep -q 'incrementCounter'; then
    echo "server action leaked into the Android native slice" >&2
    exit 1
fi
grep -q 'android.permission.INTERNET' \
    "$output_directory/src/main/AndroidManifest.xml"
grep -q 'setOnClickListener' \
    "$output_directory/src/main/kotlin/org/abla/rpc/example/MainActivity.kt"
grep -q '\$androidclick { incrementCounter(initialCounter()) }' \
    "$project_root/examples/android-rpc/main.ab"
action=$(<"$action_manifest")
[[ $action == abla_android_rpc_incrementCounter ]]
grep -q "/rpc/$action" \
    "$output_directory/src/main/kotlin/org/abla/rpc/example/MainActivity.kt"
grep -q 'argument = next' \
    "$output_directory/src/main/kotlin/org/abla/rpc/example/MainActivity.kt"
grep -q "$action(argument)" "$output_directory/server.ab"
if rg -n 'findFunction\("incrementCounter"\)' \
    "$project_root/examples/android-rpc/build.ab" >/dev/null; then
    echo "Android RPC build hard-coded the action lookup" >&2
    exit 1
fi

set +e
"$compiler" run \
    "$project_root/tests/cases/modules/invalid-android-rpc-click.ab" \
    >"$invalid_output.out" 2>"$invalid_output.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -q 'MissingAndroidRpcActionType' "$invalid_output.err"

"$server" &
server_pid=$!
cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

first_response=""
for _ in 1 2 3 4 5; do
    if first_response=$(curl --fail --silent --request POST \
        "http://127.0.0.1:18080/rpc/$action?current=40"); then
        break
    fi
done
[[ $first_response == 41 ]]
second_response=$(curl --fail --silent --request POST \
    "http://127.0.0.1:18080/rpc/$action?current=$first_response")
[[ $second_response == 42 ]]

echo "Android RPC example: typed click-call discovery generated a client and native server passed"
