#!/usr/bin/env bash
# Robustness fuzzing of the standard library's parsers that take outside input (tools/robust-fuzz/fuzz.ab): abla/json, abla/yaml, abla/http (request and
# response messages, header ends, chunked bodies), abla/compression/gzip (inflate), abla/regex (compile and match), abla/date and abla/uuid parsing. Each
# target mutates the repository's own inputs (tests/**/*.json, *.yaml, *.gz) and built-in valid samples, in a release build and a --fast build, under
# tools/run-limited.sh's memory and time limits (a hang or runaway growth is the limit being hit). A finding is a panic where an error is due, an input that takes
# over two seconds, or a violated rule (a parsed value that does not round trip, a body over its bound ...) and names its seed: `fuzz <target> <seed> 1 <seed
# files>` repeats it (--dump FILE writes the input; build/robust-fuzz/seeds-*.txt are the seed lists).
#   ROBUST_FUZZ_SEEDS  runs per target and build (default 1500), ROBUST_FUZZ_FIRST the first seed (default 1)
#   ROBUST_FUZZ_TARGETS the targets (default all), ROBUST_FUZZ_MODES "release fast" (default both)
# Usage: tools/test-robust-fuzz.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/robust-fuzz
mkdir -p "$out"
rm -f "$out"/*.log
seeds=${ROBUST_FUZZ_SEEDS:-1500}
first=${ROBUST_FUZZ_FIRST:-1}
targets=${ROBUST_FUZZ_TARGETS:-"json yaml http chunked inflate regex date uuid"}
modes=${ROBUST_FUZZ_MODES:-"release fast"}
# Seed files up to 24 KB, of the kind each target reads.
small() { git ls-files "$@" | while read -r f; do if [[ $(stat -c %s "$f") -le 24576 ]]; then echo "$f"; fi; done; }
small 'tests/*.json' > "$out/seeds-json.txt"
small 'tests/*.yaml' 'tests/*.yml' > "$out/seeds-yaml.txt"
small 'tests/*.gz' > "$out/seeds-inflate.txt"
: > "$out/seeds-none.txt"
seed_list() { # target -> file of seed paths
    case $1 in json|yaml|inflate) echo "$out/seeds-$1.txt" ;; *) echo "$out/seeds-none.txt" ;; esac
}
fail=0
build() {
    local mode=$1 flags=()
    [[ $mode == fast ]] && flags=(--fast)
    "$compiler" build tools/robust-fuzz/fuzz.ab -o "$out/fuzz-$mode" --no-cache "${flags[@]}" > "$out/build-$mode.log" 2>&1 || { cat "$out/build-$mode.log" >&2; exit 1; }
}
for mode in $modes; do
    build "$mode"
    for target in $targets; do
        files=$(tr '\n' ' ' < "$(seed_list "$target")")
        began=$SECONDS
        # shellcheck disable=SC2086
        if ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-2048} "$root/tools/run-limited.sh" "$out/fuzz-$mode" "$target" "$first" "$seeds" $files > "$out/$target-$mode.log" 2>&1; then
            echo "robust-fuzz $target ($mode): $(tail -1 "$out/$target-$mode.log") [$((SECONDS - began)) s]"
        else
            grep -E 'FINDING|panic|limit' "$out/$target-$mode.log" | head -8 >&2 || true
            echo "robust-fuzz $target ($mode): FAILED (log: $out/$target-$mode.log)" >&2
            fail=1
        fi
    done
done
[[ $fail -eq 0 ]] || exit 1
echo "robust-fuzz ok"
