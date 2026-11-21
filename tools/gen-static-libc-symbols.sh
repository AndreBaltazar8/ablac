#!/usr/bin/env bash
# Regenerate (or check) the static compiler's bootstrap-compatible snapshot.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
compiler=${1:-build/ablac}
mode=${2:---write}
[[ $mode == --write || $mode == --check ]] || { echo 'usage: tools/gen-static-libc-symbols.sh [compiler] [--write|--check]' >&2; exit 2; }
out=build/static-libc-symbols
mkdir -p "$out"
temporary=$(mktemp "$out/generated.XXXXXX")
trap 'rm -f -- "$temporary" "$temporary.err"' EXIT
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
# Compile-time printing has no file/network authority. The LLVM is discarded;
# the source graph, including @export annotations, is the compiler's dependency.
if ! "$compiler" --emit-llvm tools/gen-static-libc-symbols.ab 2> "$temporary.err" |
    sed -n 's@^//static-libc:@@p' > "$temporary"; then
    cat "$temporary.err" >&2
    exit 1
fi
[[ $(wc -l < "$temporary") -gt 300 ]] || { echo 'static libc symbols: reflection produced no table' >&2; exit 1; }
if [[ $mode == --check ]]; then
    if ! cmp -s "$temporary" src/static_libc_symbols.ab; then
        echo "static libc symbols: snapshot is stale; run tools/gen-static-libc-symbols.sh $compiler to regenerate" >&2
        diff -u src/static_libc_symbols.ab "$temporary" >&2 || true
        exit 1
    fi
    echo 'static libc symbols: reflection snapshot matches'
else
    cp "$temporary" src/static_libc_symbols.ab
fi
