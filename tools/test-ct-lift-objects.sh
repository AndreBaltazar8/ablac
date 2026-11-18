#!/usr/bin/env bash
# A `#` site whose result is 60,000 objects (tests/cases/ct-lift-objects) builds within a bound and runs under the
# default 8 MB stack, agreeing with run time (#1029). Built one object at a time, the global initializer's frame was
# about 144 bytes per object (8.6 MB: a stack overflow) and LLVM's fast register allocator took minutes; as an
# object table its frame and size don't depend on the count. The codegen cache is off: a warm one hides the cost.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-lift-objects"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-lift-objects"
fail() { echo "ct lift objects: $*" >&2; exit 1; }
status=0
ABLA_CODEGEN_CACHE=0 ABLA_COMPILE_EVAL=jit timeout 120 "$compiler" build main.ab -o "$out/p" --fast --no-cache \
    > "$out/build.log" 2>&1 || status=$?
[[ $status -ne 124 ]] || fail "the build didn't finish within 120 s"
[[ $status -eq 0 ]] || { cat "$out/build.log" >&2; fail "the build failed"; }
# No frame grows with the count (x86-64: a `sub $N, %rsp` of 256 KB or more fails; one object at a time was 8.6 MB).
if command -v llvm-objdump > /dev/null; then
    llvm-objdump -d --no-show-raw-insn "$out/p" > "$out/p.s"
    while read -r name size; do
        (( 16#$size < 262144 )) || fail "$name has a frame of $(( 16#$size )) bytes"
    done < <(awk '/^[0-9a-f]+ <.*>:$/ { name = $2 }
        /sub[a-z]*[ \t]+\$0x[0-9a-f]+, *%rsp/ { match($0, /\$0x[0-9a-f]+/); print name, substr($0, RSTART + 3, RLENGTH - 3) }' \
        "$out/p.s")
fi
status=0
output=$(ulimit -s 8192; "$out/p" 2>&1) || status=$?
[[ $status -eq 0 ]] || fail "the program exited $status under an 8 MB stack: $output"
read -r runtime compiled focus <<<"$output"
[[ $runtime == 60000:* && $compiled == "$runtime" ]] || fail "run time '$runtime', under # '$compiled'"
[[ $focus == -1 ]] || fail "the scene's focus is not the array's element (element 30000's id is '$focus')"
echo "ct lift objects: 60000 lifted objects build within the bound, run under the default stack and agree with run time"
