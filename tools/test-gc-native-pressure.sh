#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'gc native pressure: x86-64 Linux only'; exit 0; }
out=build/gc-native-pressure
mkdir -p "$out"
"$compiler" --emit-llvm tests/cases/gc-native-pressure/main.ab > "$out/main.ll"

# Match by the native call inside each body, independent of the generated function names.
awk '
    /^define / { native = ""; entry = 0; loop = 0 }
    /call .*@fixture_scalar\(/ { native = "scalar" }
    /call .*@fixture_escaping\(/ { native = "escaping" }
    /call .*@fixture_blocking\(/ { native = "blocking" }
    /call .*@fixture_pointer\(/ { native = "pointer" }
    /call .*@fixture_cstring\(/ { native = "cstring" }
    /call .*@abla_string_concat\(/ { native = "heap" }
    /call .*@abla_runtime_memory_pressure\(/ { entry = 1 }
    /call .*@abla_runtime_memory_pressure_loop\(/ { loop = 1 }
    /^}/ && native != "" {
        seen[native]++
        if (native == "scalar" ? (entry || loop) : !entry) {
            printf "gc native pressure: unexpected poll placement for %s (entry=%d loop=%d)\n", native, entry, loop
            failure = 1
        }
    }
    END {
        if (!seen["scalar"] || !seen["escaping"] || !seen["blocking"] ||
            !seen["pointer"] || !seen["cstring"] || !seen["heap"]) {
            print "gc native pressure: missing fixture call in generated IR"
            failure = 1
        }
        exit failure
    }
' "$out/main.ll"
echo 'gc native pressure: scalar loop omits polls; escaping, blocking, pointer, cstring and heap-returning calls retain them'
