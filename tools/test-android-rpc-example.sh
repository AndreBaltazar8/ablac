#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/examples/android-rpc"
library="$output_directory/src/main/jniLibs/arm64-v8a/libabla_app.so"
server="$output_directory/rpc-server"

"$compiler" build \
    "$project_root/examples/android-rpc/build.ab" \
    -o "$output_directory/build-driver" --fast --no-cache

[[ -x $server && -s $library ]]
llvm-readelf -h "$library" | grep -q 'AArch64'
if llvm-nm --defined-only "$library" | grep -q 'incrementCounter'; then
    echo "server action leaked into the Android native slice" >&2
    exit 1
fi
grep -q 'android.permission.INTERNET' \
    "$output_directory/src/main/AndroidManifest.xml"
grep -q 'setOnClickListener' \
    "$output_directory/src/main/kotlin/org/abla/rpc/example/MainActivity.kt"
grep -q '/rpc/incrementCounter' \
    "$output_directory/src/main/kotlin/org/abla/rpc/example/MainActivity.kt"
grep -q 'incrementCounter(current, amount)' "$output_directory/server.ab"

"$server" &
server_pid=$!
cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

response=""
for _ in 1 2 3 4 5; do
    if response=$(curl --fail --silent --request POST \
        'http://127.0.0.1:18080/rpc/incrementCounter?current=40&amount=2'); then
        break
    fi
done
[[ $response == 42 ]]

echo "Android RPC example: reflected action generated a click client and native server passed"
