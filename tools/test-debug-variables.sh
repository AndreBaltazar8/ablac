#!/usr/bin/env bash
# A development build (-g --fast) under a debugger: stopped at a line, the frame is named after its function with
# its parameters, and every parameter and local reads as Abla wrote it (an instance's fields, a string's text, an
# int, a float, a nullable instance, an array's elements), and the backtrace names the callers. gdb where there is
# one (Linux), else lldb (macOS); neither: skipped.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
out="$project_root/build/debug-variables"
rm -rf "$out"
mkdir -p "$out"
(cd "$out" && "$compiler" build "$project_root/tests/cases/debug-variables/probe.ab" -o "$out/probe" -g --fast --no-cache)
[[ $("$out/probe") == pt=5 ]] || { echo 'debug variables: the probe did not run' >&2; exit 1; }
if command -v gdb >/dev/null 2>&1; then
    debugger=gdb
    timeout 120 gdb -q -batch -nx -ex 'set pagination off' -ex 'break probe.ab:18' -ex run -ex 'info args' \
        -ex 'info locals' -ex 'print *maybe' -ex 'print items.data[2]' -ex bt "$out/probe" > "$out/session.txt" 2>&1 || true
elif command -v lldb >/dev/null 2>&1; then
    debugger=lldb
    timeout 120 lldb -b -o 'breakpoint set -f probe.ab -l 18' -o run -o 'frame variable' -o 'frame variable *maybe' \
        -o 'expression -- items->data[2]' -o bt "$out/probe" > "$out/session.txt" 2>&1 || true
else
    echo 'debug variables: skipped (no gdb or lldb)'
    exit 0
fi
session=$(< "$out/session.txt")
missing=()
for expected in 'x = 2' 'y = 3' '"pt"' 'length = 2' 'total = 5' 'ratio = 3.75' '"pt=5"' '= 50' \
    'probe.describe' 'probe.main.lambda' 'probe.main' 'tag = 1' 'word0 =' 'word1 ='; do
    [[ $session == *"$expected"* ]] || missing+=("$expected")
done
# The frame names its parameters (gdb: `probe.describe (p=..., label=...)`; lldb names them in `frame variable`).
[[ $session == *'label'* && $session == *'maybe'* && $session == *'items'* ]] || missing+=('the variable names')
if ((${#missing[@]})); then
    echo "debug variables ($debugger): not shown: ${missing[*]}" >&2
    cat "$out/session.txt" >&2
    exit 1
fi
echo "debug variables ($debugger): parameters, locals, an instance, a string, an array and the backtrace read as written"
