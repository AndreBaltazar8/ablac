#!/usr/bin/env bash
# A program's own compile-time code may not name compiler operations through abla/compiler/bridge (ablaCtBridgeInvoke)
# to get effects it was not granted: the call names any operation by a string, so from a program's `#` code it is
# trusted.native (sema.ab), and the native tier's bridge, which lets a network scope's provider calls through under
# network, never lets trusted.native through (ct_native.ab, bootstrapCompileBridgeScopeContains). With only `network`
# granted, one `#` call per effect, in the auto and jit tiers, must fail to build with a trusted.native denial:
#   trusted.native (ablaUnsafeStringAddress), filesystem.read (currentDirectory, abla/sys/linux/fs), environment
#   (ablaLinuxEnvironmentPointer), clock (monotonicMilliseconds, abla/process/time), random (ablaHostSecureRandom,
#   abla/platform/host): each the name a shim of the native tier invokes it by, its module imported so it is declared.
# (Before, in the jit tier each built: the bridge passed every network-scope effect, raw memory included, under network.)
#
#   tools/test-compile-bridge-grants.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/compile-bridge-grants
rm -rf "$out"
mkdir -p "$out"
fail() { echo "compile-bridge-grants: $1" >&2; exit 1; }
ran=0
for case in native:ablaUnsafeStringAddress:string: fs:currentDirectory::abla/sys/linux/fs environment:ablaLinuxEnvironmentPointer:: \
    clock:monotonicMilliseconds::abla/process/time random:ablaHostSecureRandom:integer:abla/platform/host; do
    IFS=: read -r name operation argument module <<< "$case"
    staging=""
    [[ $argument == string ]] && staging='    ablaCtBridgeArgString("abcdefgh")'
    [[ $argument == integer ]] && staging='    ablaCtBridgeArgInteger(16)'
    for tier in auto jit; do
        directory=$out/$name-$tier
        mkdir -p "$directory"
        printf 'compileCapabilities = ["network"]\n' > "$directory/abla.toml"
        imports='import "abla/io"'
        [[ $module == "" ]] || imports=$imports$'\n'"import \"$module\""
        cat > "$directory/main.ab" <<SOURCE
$imports
import "abla/compiler"
import "abla/compiler/bridge"

#compilerGrant("network")

fun reach(): int {
$staging
    ablaCtBridgeInvoke("$operation")
}

fun main {
    println("reached \${#reach()}")
}
SOURCE
        status=0
        (cd "$directory" && ABLA_COMPILE_EVAL=$tier "$compiler" build main.ab -o main --no-cache > build.log 2>&1) || status=$?
        [[ $status != 0 ]] || fail "$name ($tier): # code granted network reached $operation through the bridge: $("$directory/main" 2>&1)"
        grep -F 'trusted.native' "$directory/build.log" > /dev/null ||
            fail "$name ($tier): refused without naming trusted.native: $(head -4 "$directory/build.log")"
        ran=$((ran + 1))
    done
done
echo "compile-bridge-grants: $ran compile-time bridge calls granted only network refused (trusted.native, filesystem.read, environment, clock, random; auto and jit)"
