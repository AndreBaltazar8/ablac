#!/usr/bin/env bash
# Independent parser API coverage: syntaxCompile freezes compile-only calls,
# object fields, nested arrays, and arithmetic in each evaluator tier.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/syntax-compile
for tier in interp jit bridge; do
    trace="build/syntax-compile/main-$tier.trace"
    ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build tests/cases/syntax-compile/main.ab \
        --no-cache --fast -o "build/syntax-compile/main-$tier" 2>"$trace" || { cat "$trace"; exit 1; }
    if [[ $tier == jit ]]; then
        probe=$(LC_ALL=C awk 'BEGIN {n=0} /val nativeKind = #/ {print n+index($0,"#")-1; exit} {n+=length($0)+1}' tests/cases/syntax-compile/main.ab)
        grep -E "^note\[ct-jit\]: native at .*main.ab:$probe$" "$trace" >/dev/null || { cat "$trace"; echo 'syntaxCompile: probe was not native' >&2; exit 1; }
    fi
    result=$("build/syntax-compile/main-$tier")
    [[ $result == $'18 frozen\n42\n7 19\ncompile' ]] || { echo "syntaxCompile ($tier): $result" >&2; exit 1; }
done
for tier in interp jit bridge; do
    log="build/syntax-compile/origin-$tier.log"
    if ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/syntax-compile/invalid-origin.ab \
        --no-cache --fast -o build/syntax-compile/invalid >"$log" 2>&1; then
        echo "syntaxCompile ($tier): missing origin accepted" >&2; exit 1
    fi
    grep -Fx 'error[E_SYNTAX_COMPILE_ORIGIN]: syntaxCompile requires a source origin for synthesized syntax' "$log" >/dev/null || { cat "$log"; exit 1; }
    [[ $(grep -c '^error\[' "$log") == 1 ]] || { cat "$log"; exit 1; }
done

echo 'syntaxCompile: ok'
