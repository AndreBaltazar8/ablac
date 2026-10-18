#!/usr/bin/env bash
# JSON literals nested 150 deep (a compile-time `#$json` object, a `#$jsons`
# array, a runtime `$json` object) compile on the default 8 MB stack: the
# subparser, the compile-time evaluator, semantic analysis and lowering each
# hold a few small frames per level. The hard limit is lowered too, so neither
# the launcher nor the compiler can raise the stack again.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/deep-json"
mkdir -p "$output_directory"
depth=150

object=1
array=1
for ((level = 0; level < depth; level++)); do
    object="{\"a\": $object}"
    array="[$array]"
done
cat > "$output_directory/deep.ab" <<EOF
import "abla/json"
import "abla/io"

fun depth(value: Json): int {
    var current = value
    var levels = 0
    while (current.isObject() || current.isArray()) {
        current = if (current.isObject()) current.get("a") else current.at(0)
        levels = levels + 1
    }
    levels
}

fun main: int {
    val frozen = #\$json $object
    val encoded = #\$jsons $array
    val built = \$json $object
    println("\${depth(frozen)} \${encoded.size} \${depth(built)}")
    0
}
EOF

(
    ulimit -s 8192
    ABLA_MAX_STACK_KB=8192 "$compiler" build "$output_directory/deep.ab" \
        -o "$output_directory/deep" --no-cache
)
output=$("$output_directory/deep")
[[ $output == "$depth $((2 * depth + 1)) $depth" ]] || {
    printf 'deep json: %s\n' "$output" >&2
    exit 1
}
# The depth guard firing inside `#$jsons` (here at a lowered level cap) is one
# error: the syntax built from the failed evaluation reads no handle past the
# evaluator's table.
cat > "$output_directory/guarded.ab" <<EOF
import "abla/json"
import "abla/io"

fun main: int {
    val encoded = #\$jsons [[[[[[[[[[1]]]]]]]]]]
    println(encoded)
    0
}
EOF
set +e
ABLA_EVAL_DEPTH_LIMIT=5 "$compiler" build "$output_directory/guarded.ab" \
    -o "$output_directory/guarded" --no-cache > "$output_directory/guarded.log" 2>&1
guarded_status=$?
set -e
if [[ $guarded_status -eq 0 || $guarded_status -ge 100 ]] ||
    [[ $(grep -c '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/guarded.log") -ne 1 ]] ||
    [[ $(grep -c '^error\[' "$output_directory/guarded.log") -ne 1 ]]; then
    printf 'deep json: the guarded #$jsons gave status %s\n' "$guarded_status" >&2
    cat "$output_directory/guarded.log" >&2
    exit 1
fi
# 1000 levels on a plain 8 MB stack: the build succeeds, or stops with exactly
# one error, the evaluator's depth guard (no cascade from the levels it
# unwinds, no parse of the literal it gave up on), and never crashes.
deep=1000
nested=1
for ((level = 0; level < deep; level++)); do nested="[$nested]"; done
cat > "$output_directory/deepest.ab" <<EOF
import "abla/json"
import "abla/io"

fun main: int {
    val encoded = #\$jsons $nested
    println("\${encoded.size}")
    0
}
EOF
set +e
(
    ulimit -s 8192
    ulimit -H -s 8192
    ABLA_MAX_STACK_KB=8192 "$compiler" build "$output_directory/deepest.ab" \
        -o "$output_directory/deepest" --no-cache
) > "$output_directory/deepest.log" 2>&1
deepest_status=$?
set -e
deepest_errors=$(grep -c '^error\[' "$output_directory/deepest.log" || true)
if [[ $deepest_status -ge 100 ]] || { [[ $deepest_status -ne 0 ]] &&
    { [[ $deepest_errors -ne 1 ]] ||
      ! grep -q '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/deepest.log"; }; }; then
    printf 'deep json: %s levels gave status %s with %s errors\n' \
        "$deep" "$deepest_status" "$deepest_errors" >&2
    sed -n '1,20p' "$output_directory/deepest.log" >&2
    exit 1
fi
echo "deep json: $depth levels compile on an 8 MB stack; the depth guard in #\$jsons is one error, and $deep levels never crash"
