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
# 1000 levels on a plain 8 MB stack (and on a few smaller ones, so the guard
# stops at other points of a JSON level): the build succeeds, or stops with
# exactly one error, the evaluator's depth guard (no cascade from the levels it
# unwinds, no parse of the literal's rest on the little stack the guard left),
# and never crashes.
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
for stack in 8192 7808 7424 7260 6656; do
    set +e
    (
        ulimit -s $stack
        ulimit -H -s $stack
        ABLA_MAX_STACK_KB=$stack "$compiler" build "$output_directory/deepest.ab" \
            -o "$output_directory/deepest" --no-cache
    ) > "$output_directory/deepest-$stack.log" 2>&1
    deepest_status=$?
    set -e
    deepest_errors=$(grep -c '^error\[' "$output_directory/deepest-$stack.log" || true)
    if [[ $deepest_status -ge 100 ]] || { [[ $deepest_status -ne 0 ]] &&
        { [[ $deepest_errors -ne 1 ]] ||
          ! grep -q '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/deepest-$stack.log"; }; }; then
        printf 'deep json: %s levels on a %s KB stack gave status %s with %s errors\n' \
            "$deep" "$stack" "$deepest_status" "$deepest_errors" >&2
        sed -n '1,20p' "$output_directory/deepest-$stack.log" >&2
        exit 1
    fi
done
# Wherever the guard stops the descent (here at caps in a range of levels,
# and at each of seven consecutive ones, which covers every point of one JSON
# level), the levels it unwinds evaluate nothing more: one error, never a loop
# that descends again until the step limit, nor a cascade from what was lost.
for cap in 37 50 64 101 330 331 332 333 334 335 336 4879; do
    set +e
    ABLA_EVAL_DEPTH_LIMIT=$cap "$compiler" build "$output_directory/deepest.ab" \
        -o "$output_directory/capped" --no-cache > "$output_directory/capped-$cap.log" 2>&1
    capped_status=$?
    set -e
    if [[ $capped_status -eq 0 || $capped_status -ge 100 ]] ||
        [[ $(grep -c '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/capped-$cap.log") -ne 1 ]] ||
        [[ $(grep -c '^error\[' "$output_directory/capped-$cap.log") -ne 1 ]]; then
        printf 'deep json: capped at %s levels, status %s\n' "$cap" "$capped_status" >&2
        grep '^error' "$output_directory/capped-$cap.log" >&2 || true
        exit 1
    fi
done
# The JIT run frontend goes through the same staged parser and semantic analysis.
set +e
ABLA_EVAL_DEPTH_LIMIT=4879 "$compiler" run "$output_directory/deepest.ab" \
    > "$output_directory/run.log" 2>&1
run_status=$?
set -e
if [[ $run_status -eq 0 || $run_status -ge 100 ]] ||
    [[ $(grep -c '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/run.log") -ne 1 ]] ||
    [[ $(grep -c '^error\[' "$output_directory/run.log") -ne 1 ]]; then
    printf 'deep json: JIT run guard status %s\n' "$run_status" >&2
    grep '^error' "$output_directory/run.log" >&2 || true
    exit 1
fi
# A genuine array error outside the abandoned subparser in the same file survives.
{ cat "$output_directory/deepest.ab"; printf '\nfun badArray(): int { val invalid: array<int> = [true]; invalid.size }\n'; } > "$output_directory/same-file.ab"
set +e
ABLA_EVAL_DEPTH_LIMIT=4879 "$compiler" build "$output_directory/same-file.ab" \
    -o "$output_directory/same-file" --no-cache > "$output_directory/same-file.log" 2>&1
same_status=$?
set -e
if [[ $same_status -eq 0 || $same_status -ge 100 ]] ||
    [[ $(grep -c '^error\[' "$output_directory/same-file.log") -ne 2 ]] ||
    ! grep -q '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/same-file.log" ||
    ! grep -q '^error\[E_SEMANTIC\]: array.element-type' "$output_directory/same-file.log"; then
    printf 'deep json: same-file error lost or extra diagnostic, status %s\n' "$same_status" >&2
    grep '^error' "$output_directory/same-file.log" >&2 || true
    exit 1
fi
# A stopped subparser must not hide an unrelated error in another module.
cat > "$output_directory/unrelated.ab" <<'EOF'
fun unrelated(): int {
    val invalid: array<int> = [true]
    invalid.size
}
EOF
{ printf 'import "unrelated.ab"\n'; cat "$output_directory/deepest.ab"; } > "$output_directory/multi.ab"
set +e
ABLA_EVAL_DEPTH_LIMIT=4879 "$compiler" build "$output_directory/multi.ab" \
    -o "$output_directory/multi" --no-cache > "$output_directory/multi.log" 2>&1
multi_status=$?
set -e
if [[ $multi_status -eq 0 || $multi_status -ge 100 ]] ||
    [[ $(grep -c '^error\[' "$output_directory/multi.log") -ne 2 ]] ||
    ! grep -q '^error\[E_EVAL_STACK_DEPTH\]' "$output_directory/multi.log" ||
    ! grep -q '^error\[E_SEMANTIC\]: array.element-type' "$output_directory/multi.log" ||
    ! grep -q "source\[semantic\]:.*unrelated.ab:" "$output_directory/multi.log"; then
    printf 'deep json: unrelated module error lost or extra diagnostic, status %s\n' "$multi_status" >&2
    grep '^error' "$output_directory/multi.log" >&2 || true
    exit 1
fi
# A cached module parse retains the stopped span on a second graph build.
"$compiler" build "$project_root/tests/cases/modules/module-depth-stop-cache.ab" \
    --fast --no-cache -o "$output_directory/cache-test"
cache_output=$(ABLA_EVAL_DEPTH_LIMIT=4879 "$output_directory/cache-test")
if [[ $cache_output != 'cache depth stop: reused with one error' ]]; then
    printf 'deep json: cached parse: %s\n' "$cache_output" >&2
    exit 1
fi
echo "deep json: $depth levels compile on an 8 MB stack; the depth guard in #\$jsons is one error, and $deep levels never crash"
