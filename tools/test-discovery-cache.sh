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
objects_cold() {
    python3 - "$ABLA_CACHE_DIR" <<'PY'
import pathlib, shutil, sys
for p in pathlib.Path(sys.argv[1]).iterdir():
    if p.name.startswith('discovery-v1-'): continue
    if p.is_dir(): shutil.rmtree(p)
    else: p.unlink()
PY
}
build > "$work/cold.out" 2> "$work/cold.err" || { cat "$work/cold.err" >&2; fail 'cold build'; }
cp "$work/program" "$work/reference"
cp "$work/program.ll" "$work/reference.ll"
python3 - "$ABLA_CACHE_DIR" "$work/lib.ab" "$work/record-path" "$work/pristine" <<'PY'
import pathlib, struct, sys
found = []
for p in pathlib.Path(sys.argv[1]).glob('discovery-v1-*/*.discovery'):
    b=p.read_bytes(); cursor=0; fields=[]
    for i in range(3):
        n=struct.unpack_from('<I',b,cursor)[0]; cursor+=4
        fields.append(b[cursor:cursor+n]); cursor+=n
    if fields[2]==sys.argv[2].encode(): found.append(p)
assert len(found)==1,found
pathlib.Path(sys.argv[3]).write_text(str(found[0]))
pathlib.Path(sys.argv[4]).write_bytes(found[0].read_bytes())
PY
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
    python3 - "$work/record-path" "$work/pristine" "$mode" <<'PY'
import pathlib, struct, sys
p=pathlib.Path(pathlib.Path(sys.argv[1]).read_text()); b=bytearray(pathlib.Path(sys.argv[2]).read_bytes()); mode=sys.argv[3]
if mode=='corrupt': b[-1]^=1
elif mode=='truncated': b=b[:-3]
elif mode=='version': b[4+len('ABLA-DISCOVERY-1')-1]=ord('9')
elif mode=='image':
    n=struct.unpack_from('<I',b,0)[0]; cursor=4+n
    assert struct.unpack_from('<I',b,cursor)[0]>0
    b[cursor+4]^=1
elif mode=='trailing': b+=b'!'
if mode=='oversized':
    with p.open('wb') as f: f.truncate(67108864)
else: p.write_bytes(b)
PY
    objects_cold
    ABLA_COMPILER_MEMORY_TRACE=1 build > "$work/$mode.out" 2> "$work/$mode.err" || fail "$mode fallback"
    if grep -Fq "discovery.hit:$work/lib.ab" "$work/$mode.err"; then fail "$mode was accepted"; fi
    cmp "$work/program" "$work/reference"
    cmp "$work/program.ll" "$work/reference.ll"
    cmp "$(cat "$work/record-path")" "$work/pristine"
done
# Neither source size nor mtime is a validity proof.
python3 - "$work/lib.ab" <<'PY'
import os,pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.stat(); p.write_bytes(p.read_bytes().replace(b'42',b'43'))
os.utime(p,ns=(s.st_atime_ns,s.st_mtime_ns))
assert p.stat().st_size==s.st_size and p.stat().st_mtime_ns==s.st_mtime_ns
PY
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
