#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Linux ]] || { echo 'native cache failures: Linux held-LTO case skipped'; exit 0; }
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$project_root"
source tools/compiler-binary.sh
compiler=$(abla_compiler_binary "$compiler")
[[ $compiler == /* ]] || compiler="$project_root/$compiler"
work="$project_root/build/native-cache-failures"
rm -rf "$work"
mkdir -p "$work/shims" "$work/failed-cache" "$work/good-cache"
unset ABLA_SIDECAR ABLA_NO_SIDECAR ABLA_KEEP_LLVM_TEXT ABLA_LLVM_OUT_OF_PROCESS
# Reuse the program that exposed mixed held/text cache results: HTTP runtime
# code plus lambdas after rewritten private names in a standard-library module.
mkdir -p "$work/sysroot"
cp -R "${ABLA_SYSROOT:-$project_root}/stdlib" "${ABLA_SYSROOT:-$project_root}/runtime" "$work/sysroot/"
mkdir -p "$work/sysroot/stdlib/abla/sysroot-path-fixture"
cp tests/cases/sysroot-path-symbols/fixture.ab "$work/sysroot/stdlib/abla/sysroot-path-fixture/entry.ab"
export ABLA_SYSROOT="$work/sysroot"
program="$project_root/tests/cases/sysroot-path-symbols/main.ab"
fail() { echo "native cache failures: $1" >&2; exit 1; }

# Both modes must use the original frontend text emission for a small client
# without LLVM. The sidecar request prevents whole-program holding in both.
ABLA_SIDECAR=1 "$compiler" build "$program" -o "$work/requested" --no-cache
ABLA_SIDECAR=1 ABLA_LLVM_OUT_OF_PROCESS=1 "$compiler" build "$program" \
    -o "$work/disabled" --no-cache
cmp "$work/requested.ll" "$work/disabled.ll"

# A linker failure occurs after the frontend's cache publication point.
# Neither it nor a later tool failure may leave the entry's commit marker.
cat > "$work/shims/clang" <<'CLANG'
#!/usr/bin/env bash
exit 127
CLANG
chmod +x "$work/shims/clang"
status=0
PATH="$work/shims:$PATH" ABLA_LINK_DIRECT=0 ABLA_CACHE_DIR="$work/failed-cache" \
    "$compiler" build "$program" -o "$work/failed" > "$work/failed.log" 2>&1 || status=$?
[[ $status == 127 ]] || fail "injected linker failure returned $status"
! find "$work/failed-cache" -name '*.source' -print -quit | grep -q . ||
    fail 'failed build left a committed native cache record'

ABLA_CACHE_DIR="$work/good-cache" "$compiler" build "$program" -o "$work/cold"
ABLA_CACHE_DIR="$work/good-cache" ABLA_COMPILER_MEMORY_TRACE=1 \
    "$compiler" build "$program" -o "$work/warm" 2> "$work/warm.log"
! grep -q 'frontend.parse.begin' "$work/warm.log" || fail 'ordinary warm build reparsed'
cmp "$work/cold" "$work/warm"
members=$(find "$work/good-cache" -name '*.lto-v2-*.o' -print)
[[ -n $members ]] || fail 'no held-LTO object was cached'
while IFS= read -r member; do rm "$member"; done <<< "$members"
ABLA_CACHE_DIR="$work/good-cache" ABLA_COMPILER_MEMORY_TRACE=1 \
    "$compiler" build "$program" -o "$work/recovered" 2> "$work/recovered.log"
grep -q 'frontend.parse.begin' "$work/recovered.log" || fail 'missing LTO member reused text-only frontend cache'
cmp "$work/cold" "$work/recovered"
ABLA_CACHE_DIR="$work/failed-cache" "$compiler" build "$program" -o "$work/retry"
cmp "$work/cold" "$work/retry"
echo 'native cache failures: unchanged small-client IR, no failed-build record, held-LTO member required, reproducible retry'
