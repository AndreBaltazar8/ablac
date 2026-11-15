#!/usr/bin/env bash
# A project's compileCapabilities authorize its compile-time code when the program is built or run. `ablac build` always read the
# entry's abla.toml, but the host graph of `run` loaded the runtime first and so took the manifest of the standard library's
# directory: a program that reads a file at compile time stopped with compile.capability-not-authorized. Here the same program (a
# `#` read of a file under `#compilerGrant`) is run with the manifest (it works: the file's text is printed) and without its entry
# (the denial stays). --emit-llvm, the IR view, does not read the manifest (it must not run a program's processes or read its
# files): it says so in a note when compile-time code is denied.
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

set +e
ABLA_MAX_SECONDS=120 "$limited" "$compiler" --emit-llvm main.ab > /dev/null 2> "$work/emit.err"
status=$?
set -e
[[ $status -ne 0 ]] && grep -q "note: --emit-llvm does not read the project's compileCapabilities" "$work/emit.err" ||
    { echo "emit capabilities: --emit-llvm of a project with a compile-time read neither failed nor said why" >&2; cat "$work/emit.err" >&2; exit 1; }

cd "$work/denied"
set +e
ABLA_MAX_SECONDS=120 "$limited" "$compiler" run main.ab > /dev/null 2> "$work/denied.err"
status=$?
set -e
[[ $status -ne 0 ]] && grep -q 'compile.capability-not-authorized:filesystem.read' "$work/denied.err" ||
    { echo "emit capabilities: run of a project that does not authorize filesystem.read was not denied" >&2; cat "$work/denied.err" >&2; exit 1; }
echo "emit capabilities: run honours the entry's compileCapabilities and still denies without them; --emit-llvm denies and says why"
