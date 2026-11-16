#!/usr/bin/env bash
# A project's compileCapabilities authorize its compile-time code however the program is compiled. `ablac build` always read the entry's
# abla.toml, but the host graph of `run` and --emit-llvm loaded the runtime first and so took the manifest of the standard library's
# directory: a program that reads a file at compile time stopped with compile.capability-not-authorized. Here the same program (a `#`
# read of a file under `#compilerGrant`) is emitted and run with the manifest (it works: the file's text is in the IR and printed) and
# without its entry (the denial stays), by both.
set -euo pipefail
unset ABLA_CACHE_DIR
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
work=$(mktemp -d /tmp/emit-capabilities.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/granted" "$work/denied"
for project in granted denied; do
    echo "hello from a file" > "$work/$project/greeting.txt"
    cat > "$work/$project/main.ab" <<'ABLA'
import "abla/io"
import "abla/fs"
import "abla/compiler"

#compilerGrant("filesystem.read")

val greeting = #path("greeting.txt").readText()

fun main {
    print(greeting)
}
ABLA
done
printf 'name = "emit-capabilities"\nentry = "main.ab"\ncompileCapabilities = ["filesystem.read"]\n' > "$work/granted/abla.toml"
printf 'name = "emit-capabilities"\nentry = "main.ab"\n' > "$work/denied/abla.toml"
limited="$project_root/tools/run-limited.sh"

cd "$work/granted"
output=$(ABLA_MAX_SECONDS=120 "$limited" "$compiler" run main.ab 2> "$work/run.err") ||
    { echo "emit capabilities: ablac run of a project that authorizes filesystem.read failed" >&2; cat "$work/run.err" >&2; exit 1; }
[[ $output == *'hello from a file'* ]] ||
    { echo "emit capabilities: run printed '$output'" >&2; exit 1; }

ABLA_MAX_SECONDS=120 "$limited" "$compiler" --emit-llvm main.ab > "$work/granted.ll" 2> "$work/emit.err" ||
    { echo "emit capabilities: --emit-llvm of a project that authorizes filesystem.read failed" >&2; cat "$work/emit.err" >&2; exit 1; }
grep -q 'hello from a file' "$work/granted.ll" ||
    { echo "emit capabilities: the file's text is not in the emitted IR" >&2; exit 1; }

cd "$work/denied"
for mode in "run" "--emit-llvm"; do
    set +e
    ABLA_MAX_SECONDS=120 "$limited" "$compiler" $mode main.ab > /dev/null 2> "$work/denied.err"
    status=$?
    set -e
    [[ $status -ne 0 ]] && grep -q 'compile.capability-not-authorized:filesystem.read' "$work/denied.err" ||
        { echo "emit capabilities: '$mode' of a project that does not authorize filesystem.read was not denied" >&2; cat "$work/denied.err" >&2; exit 1; }
done
echo "emit capabilities: run and --emit-llvm honour the entry's compileCapabilities, and still deny without them"
