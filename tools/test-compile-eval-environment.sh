#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-environment
mkdir -p "$out/project"
fail() { echo "compile-eval-environment: $1" >&2; exit 1; }
# check_environment_trace SHAPE STATE TIER: the input sidecar records the environment
# variable, a warm build leaves it untouched, a changed value rewrites it, and the
# JIT trace says native or interpreted for the table site as expected.
check_environment_trace() {
    local shape=$1 state=$2 tier=$3 sidecars pos native fallback expression_pos
    local tag="$out/$shape-$state-$tier" first="$out/$shape-first-$tier.snap"
    sidecars=$(find "$out/cache-$tier" -name 'native-wasm32-module-*.inputs')
    [[ -n $sidecars && $(printf '%s\n' "$sidecars" | wc -l) -eq 1 ]] || fail "$tag: expected one input sidecar, found: $sidecars"
    grep -qaF 'abla-input:environment:ABLA_CT_ENV_TEST' "$sidecars" || fail "$tag: sidecar lacks the environment input"
    { printf '%s\n' "$sidecars"; stat -c %y "$sidecars"; sha256sum "$sidecars" | cut -d' ' -f1; } > "$tag.snap"
    if [[ $state == warm ]]; then
        cmp -s "$tag.snap" "$first" || fail "$tag: a warm build rewrote the sidecar"
    elif [[ $state == changed ]]; then
        [[ $(sed -n 1p "$tag.snap") == $(sed -n 1p "$first") && $(sed -n 3p "$tag.snap") != $(sed -n 3p "$first") ]] \
            || fail "$tag: a changed value did not rewrite the same sidecar"
    fi
    [[ $tier != interp ]] || return 0
    pos=$(( $(grep -boa 'val TABLE = #' "$out/project/table.ab" | head -n 1 | cut -d: -f1) + 12 ))
    expression_pos=$((pos + 1))
    [[ $(dd if="$out/project/table.ab" bs=1 skip=$((pos + 1)) count=1 2> /dev/null) != '(' ]] || expression_pos=$((pos + 2))
    native=$(awk -v tail="table.ab:$pos" 'index($0, "note[ct-jit]: native at ") == 1 && substr($0, length($0) - length(tail) + 1) == tail' "$tag.log" | wc -l)
    fallback=$(awk -v p="note[ct-jit]: interpreted at $expression_pos:" 'index($0, p) == 1' "$tag.log")
    if [[ $shape == direct ]]; then
        [[ $native -eq $([[ $state == warm ]] && echo 0 || echo 1) && -z $fallback ]] || fail "$tag: wrong trace for the direct site"
    elif [[ $state != warm ]]; then
        [[ -n $fallback && $(printf '%s\n' "$fallback" | wc -l) -eq 1 && $fallback == *'global ASSET_HOST initializer reaching compilerEnvironment'* && $native -eq 0 ]] \
            || fail "$tag: wrong trace for the global site"
    fi
}
"$compiler" build tests/cases/compile-eval-environment/facts.ab --fast --no-cache -o "$out/facts" >"$out/facts.log" 2>&1
status=0
"$out/facts" || status=$?
[[ $status == 42 ]] || { echo "environment facts failed: $status" >&2; exit 1; }
for shape in direct global global-first; do
    cp "tests/cases/compile-eval-environment/$shape.ab" "$out/project/table.ab"
    printf 'compileCapabilities = ["environment"]\n' >"$out/project/abla.toml"
    for tier in interp jit auto; do rm -rf "$out/cache-$tier"; done
    for state in first warm changed; do
        value=first
        [[ $state != changed ]] || value=second
        for tier in interp jit auto; do
            ABLA_CT_ENV_TEST=$value ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 \
                ABLA_CACHE_DIR="$root/$out/cache-$tier" "$compiler" build \
                tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast \
                >"$out/$shape-$state-$tier.log" 2>&1
            "$out/builder"
            cp "$out/table.wasm" "$out/$shape-$state-$tier.wasm"
            check_environment_trace "$shape" "$state" "$tier"
        done
        cmp "$out/$shape-$state-interp.wasm" "$out/$shape-$state-jit.wasm"
        cmp "$out/$shape-$state-interp.wasm" "$out/$shape-$state-auto.wasm"
        node --input-type=module - "$out/table.wasm" "$shape" "$value" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]));
const e = instance.exports;
let actual = '';
for (let i=0; i<Number(e.tableSize()); ++i) actual += String.fromCharCode(Number(e.tableByte(BigInt(i))));
const value = process.argv[4];
assert.equal(actual, process.argv[3] === 'direct' ? crypto.createHash('sha256').update(value).digest('hex') : `${value}:${value}`);
NODE
    done
    # Same source, cache and output after a successful granted build: revoke authorization.
    printf 'compileCapabilities = []\n' >"$out/project/abla.toml"
    for tier in interp jit auto; do
        if ABLA_CT_ENV_TEST=secret ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 \
            ABLA_CACHE_DIR="$root/$out/cache-$tier" "$compiler" build \
            tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast \
            >"$out/$shape-revoked-$tier.log" 2>&1; then
            echo 'revoked environment grant accepted' >&2; exit 1
        fi
        grep -q 'compile.capability-not-authorized:environment' "$out/$shape-revoked-$tier.log"
    done
    # Manifest authorization alone does not grant the source's environment effect.
    printf 'compileCapabilities = ["environment"]\n' >"$out/project/abla.toml"
    sed '/#compilerGrant("environment")/d' "tests/cases/compile-eval-environment/$shape.ab" >"$out/project/table.ab"
    for tier in interp jit auto; do
        if ABLA_CT_ENV_TEST=secret ABLA_COMPILE_EVAL=$tier "$compiler" build \
            tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast --no-cache \
            >"$out/$shape-denied-$tier.log" 2>&1; then
            echo 'ungranted environment effect accepted' >&2; exit 1
        fi
        grep -q 'compile.effect-denied:environment' "$out/$shape-denied-$tier.log"
    done
done
echo 'compile-time environment bridge: exact prototype, grants, cache invalidation/revocation and three-tier Wasm parity passed'
