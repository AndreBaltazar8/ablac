#!/usr/bin/env bash
# ablaCompileTimeNativeHost (abla/bytes) is true only in compile-time code the host's native tier runs
# (tests/cases/ct-native-host): host.ab's site answers 1 under jit, 2 in the evaluator and 3 at run time. In a slice
# built for another target it is false, and the walker proving that slice portable skips its `then`: module.ab, built
# for WebAssembly from build.ab, keeps its site native although that `then` calls a C function, and its module is the
# one the evaluator builds.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-native-host
rm -rf "$out"; mkdir -p "$out"
fail() { echo "ct native host: $1" >&2; [[ -z ${2:-} ]] || tail -8 "$2" >&2; exit 1; }
cd "$project_root/tests/cases/ct-native-host"
for pair in jit:13 interp:23; do
    tier=${pair%%:*} want=${pair##*:}
    ABLA_COMPILE_EVAL=$tier timeout 300 "$compiler" build host.ab -o "$out/host-$tier" \
        --fast --no-cache > "$out/host-$tier.log" 2>&1 || fail "host $tier: the build failed" "$out/host-$tier.log"
    status=0; "$out/host-$tier" || status=$?
    [[ $status == "$want" ]] || fail "host $tier: exited $status, not $want (the site's answer, then run time's 3)"
done
echo "ok   host: 1 natively, 2 in the evaluator, 3 at run time"
cd "$project_root"
for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 timeout 300 "$compiler" build tests/cases/ct-native-host/build.ab \
        -o "$out/builder-$tier" --fast --no-cache > "$out/build-$tier.log" 2>&1 ||
        fail "build $tier: the builder didn't build" "$out/build-$tier.log"
    "$out/builder-$tier" || fail "build $tier: the module wasn't built" "$out/build-$tier.log"
    cp "$out/module.wasm" "$out/module-$tier.wasm"
done
grep -q '^note\[ct-jit\]: native at .*module.ab:' "$out/build-jit.log" ||
    fail "module: the cross-target site wasn't native" "$out/build-jit.log"
! grep -q 'cross-target site reaches abs' "$out/build-jit.log" || fail "module: the walker reached the then" "$out/build-jit.log"
cmp "$out/module-interp.wasm" "$out/module-jit.wasm" || fail "module: the native slice's module differs from the evaluator's"
echo "ok   module: the cross-target site stays native, takes the portable arm, and builds the evaluator's module"
echo "ct native host: true only in host native code; a cross-target slice skips its then"
