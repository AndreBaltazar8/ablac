#!/usr/bin/env bash
# Raw summaries are exact-content parser data, not object/link success records.
set -euo pipefail
compiler=${1:-build/ablac.bin}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case $compiler in /*) ;; *) compiler="$root/$compiler" ;; esac
cd "$root"
work="$root/build/discovery-cache-check"
rm -rf "$work"
mkdir -p "$work/cache"
export ABLA_CACHE_DIR="$work/cache" ABLA_KEEP_LLVM_TEXT=1
unset ABLA_COMPILER_MEMORY_TRACE
fail() { echo "discovery cache: $1" >&2; exit 1; }
cat > "$work/lib.ab" <<'AB'
fun answer(value: int = 42): int = value
AB
cat > "$work/main.ab" <<'AB'
import "lib.ab"
fun main: int = answer()
AB
build() { "$compiler" build "$work/main.ab" -o "$work/program" --o1 "$@"; }
# Little-endian binary helpers for the record bytes (od/dd only, no interpreter).
u32_at() { od -An -tu1 -j "$2" -N4 "$1" | awk '{ print $1 + $2 * 256 + $3 * 65536 + $4 * 16777216 }'; }
byte_at() { od -An -tu1 -j "$2" -N1 "$1" | tr -d ' '; }
set_byte() { printf "\\$(printf '%03o' "$3")" | dd of="$1" bs=1 seek="$2" conv=notrunc 2> /dev/null; }
# record_third_field FILE: the third length-prefixed field of a discovery record.
record_third_field() {
    local file=$1 cursor=0 i n
    for i in 0 1; do n=$(u32_at "$file" "$cursor"); cursor=$((cursor + 4 + n)); done
    n=$(u32_at "$file" "$cursor")
    dd if="$file" bs=1 skip=$((cursor + 4)) count="$n" 2> /dev/null
}
objects_cold() {
    find "$ABLA_CACHE_DIR" -mindepth 1 -maxdepth 1 ! -name 'discovery-v1-*' -exec rm -rf {} +
}
find_record() {
    local found= count=0 p
    for p in "$ABLA_CACHE_DIR"/discovery-v1-*/*.discovery; do
        [[ -e $p ]] || continue
        record_third_field "$p" > "$work/field"
        if [[ $(cat "$work/field") == "$work/lib.ab" ]]; then found=$p; count=$((count + 1)); fi
    done
    [[ $count -eq 1 ]] || fail "expected one discovery record for lib.ab, found $count"
    printf '%s' "$found" > "$work/record-path"
    cp "$found" "$work/pristine"
}
# mutate_record MODE: damage the pristine record in place at the recorded path.
mutate_record() {
    local record size n cursor
    record=$(cat "$work/record-path")
    cp "$work/pristine" "$record"
    size=$(wc -c < "$record" | tr -d ' ')
    case $1 in
        corrupt) set_byte "$record" $((size - 1)) $(( $(byte_at "$record" $((size - 1))) ^ 1 )) ;;
        truncated) dd if=/dev/null of="$record" bs=1 seek=$((size - 3)) 2> /dev/null ;;
        version) set_byte "$record" $((4 + 16 - 1)) 57 ;;
        image)
            n=$(u32_at "$record" 0); cursor=$((4 + n))
            [[ $(u32_at "$record" "$cursor") -gt 0 ]] || fail 'record image is empty'
            set_byte "$record" $((cursor + 4)) $(( $(byte_at "$record" $((cursor + 4))) ^ 1 )) ;;
        trailing) printf '!' >> "$record" ;;
        oversized) : > "$record"; dd if=/dev/null of="$record" bs=1 seek=67108864 2> /dev/null ;;
    esac
    ! cmp -s "$record" "$work/pristine" || fail "$1 left the record unchanged"
}
build > "$work/cold.out" 2> "$work/cold.err" || { cat "$work/cold.err" >&2; fail 'cold build'; }
cp "$work/program" "$work/reference"
cp "$work/program.ll" "$work/reference.ll"
find_record
objects_cold
ABLA_COMPILER_MEMORY_TRACE=1 build > "$work/hit.out" 2> "$work/hit.err" || fail 'summary hit'
grep -Fq "discovery.hit:$work/lib.ab" "$work/hit.err" || fail 'no raw summary hit'
cmp "$work/program" "$work/reference"
cmp "$work/program.ll" "$work/reference.ll"
# No-cache bypasses even an already populated discovery directory.
ABLA_COMPILER_MEMORY_TRACE=1 build --no-cache > "$work/direct.out" 2> "$work/direct.err" || fail 'no-cache with populated records'
if grep -Fq 'discovery.hit:' "$work/direct.err"; then fail 'no-cache read a populated summary'; fi
# Cache policy may select a different native link path. The raw frontend
# IR must match; executable identity is checked between compilers per mode.
cmp "$work/program.ll" "$work/reference.ll"
set +e
"$work/program"; direct_result=$?
set -e
[[ $direct_result -eq 42 ]] || fail "no-cache returned $direct_result"
cmp "$(cat "$work/record-path")" "$work/pristine"
for mode in corrupt truncated version image trailing oversized; do
    mutate_record "$mode"
    objects_cold
    ABLA_COMPILER_MEMORY_TRACE=1 build > "$work/$mode.out" 2> "$work/$mode.err" || fail "$mode fallback"
    if grep -Fq "discovery.hit:$work/lib.ab" "$work/$mode.err"; then fail "$mode was accepted"; fi
    cmp "$work/program" "$work/reference"
    cmp "$work/program.ll" "$work/reference.ll"
    cmp "$(cat "$work/record-path")" "$work/pristine"
done
# Neither source size nor mtime is a validity proof.
size=$(wc -c < "$work/lib.ab"); mtime=$(stat -c %y "$work/lib.ab")
touch -r "$work/lib.ab" "$work/lib.stamp"
sed 's/42/43/g' "$work/lib.ab" > "$work/lib.edited" && cat "$work/lib.edited" > "$work/lib.ab"
touch -r "$work/lib.stamp" "$work/lib.ab"
[[ $(wc -c < "$work/lib.ab") -eq $size && $(stat -c %y "$work/lib.ab") == "$mtime" ]] || fail 'the edit changed the size or mtime'
grep -q 43 "$work/lib.ab" || fail 'the edit did not change lib.ab'
objects_cold
build > "$work/edit.out" 2> "$work/edit.err" || fail 'restored-mtime edit'
set +e
"$work/program"; status=$?
set -e
[[ $status -eq 43 ]] || fail "stale source returned $status"
# No-cache never creates, reads or writes discovery records.
ABLA_CACHE_DIR="$work/disabled" ABLA_COMPILER_MEMORY_TRACE=1 build --no-cache > "$work/disabled.out" 2> "$work/disabled.err" || fail 'no-cache build'
if grep -Fq 'discovery.hit:' "$work/disabled.err"; then fail 'no-cache hit'; fi
[[ -z $(find "$work/disabled" -name '*.discovery' -print 2>/dev/null) ]] || fail 'no-cache published a summary'
# An invalid runtime body must keep its full parser diagnostics.
printf '%s\n' 'fun answer(value: int = 43): int { if ( }' > "$work/lib.ab"
set +e
build > "$work/invalid.out" 2> "$work/invalid.err"; cached_status=$?
build --no-cache > "$work/invalid-direct.out" 2> "$work/invalid-direct.err"; direct_status=$?
set -e
[[ $cached_status -ne 0 && $cached_status -eq $direct_status ]] || fail 'invalid parse status'
cmp "$work/invalid.err" "$work/invalid-direct.err"
"$compiler" build tests/cases/bootstrap/discovery-codec.ab -o "$work/codec" --fast --no-cache
"$work/codec"
ABLA_GC_STRESS=1 ABLA_MAX_SECONDS=120 tools/run-limited.sh "$work/codec"
echo 'discovery cache: exact hits, corruption/version/image/size fallback, preserved-mtime edits, no-cache and parser diagnostics'
