#!/usr/bin/env bash
# `--emit-llvm` and `ablac run` lower what a program reaches, as a build does, so a
# big import graph doesn't cost all of its bodies: `--emit-llvm` still checks every
# body of the file it is given.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$(mktemp -d "$project_root/build/emit-reachable.XXXXXX")
trap 'rm -rf -- "$output_directory"' EXIT

cat > "$output_directory/library.ab" <<'AB'
fun libraryUsed(): int = 42
fun libraryUnreachable(): int = 7
AB
cat > "$output_directory/main.ab" <<'AB'
import "./library.ab"
fun entryUnreachable(): int = 8
fun main: int = libraryUsed()
AB
"$compiler" --emit-llvm "$output_directory/main.ab" > "$output_directory/main.ll"
grep -q 'abla.source"="libraryUsed\|libraryUsed' "$output_directory/main.ll" ||
    { echo 'emit reachable: lost what the program calls' >&2; exit 1; }
grep -q 'entryUnreachable' "$output_directory/main.ll" ||
    { echo "emit reachable: the file's own unreachable function wasn't lowered" >&2; exit 1; }
if grep -q 'libraryUnreachable' "$output_directory/main.ll"; then
    echo 'emit reachable: an imported function nothing reaches was lowered' >&2
    exit 1
fi

# `run` keeps no body it doesn't reach, of any file: a program that imports a big
# module and calls nothing of it lowers about what one without it does.
demanded() { # file
    local status=0
    ABLA_COMPILER_MEMORY_TRACE=1 "$compiler" run "$1" 2> "$output_directory/run.log" || status=$?
    [[ $status -eq 42 ]] || { echo "emit reachable: run exited with $status" >&2; cat "$output_directory/run.log" >&2; exit 1; }
    grep -oE 'lower\.demanded:[0-9]+' "$output_directory/run.log" | tail -1 | cut -d: -f2
}
printf 'fun main: int = 42\n' > "$output_directory/plain.ab"
printf 'import "abla/http"\nfun main: int = 42\n' > "$output_directory/heavy.ab"
plain=$(demanded "$output_directory/plain.ab")
heavy=$(demanded "$output_directory/heavy.ab")
if [[ -z $plain || -z $heavy || $heavy -gt $((plain + 100)) ]]; then
    echo "emit reachable: run lowered ${heavy:-?} declarations with an unused import, ${plain:-?} without" >&2
    exit 1
fi
echo 'emit reachable: emit and run lower what is reached'
