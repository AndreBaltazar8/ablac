#!/usr/bin/env bash
# JSON literals nested 200 deep (a compile-time `#$json` object, a `#$jsons`
# array, a runtime `$json` object) compile on the default 8 MB stack: the
# subparser, the compile-time evaluator, semantic analysis and lowering each
# hold a few small frames per level. The hard limit is lowered too, so neither
# the launcher nor the compiler can raise the stack again.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/deep-json"
mkdir -p "$output_directory"
depth=200

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
echo "deep json: $depth levels compile on an 8 MB stack"
