#!/usr/bin/env bash
# A thread may reach only globals no other thread can change: `val`s of
# thread-safe types (scalars, strings, functions, Shared/Mutex/Weak handles),
# compile-time values, and the runtime's own; anything else it reaches,
# directly or through what it calls, is thread.shared-global. A task is exempt.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/thread-globals"
output_directory="$project_root/build/thread-globals"
mkdir -p "$output_directory"

"$compiler" build "$cases/ok.ab" -o "$output_directory/ok" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/ok" >"$output_directory/ok.out"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "thread globals: ok expected 42, got $status" >&2; exit 1; }
[[ "$(cat "$output_directory/ok.out")" == "42 9" ]] ||
    { echo "thread globals: ok printed $(cat "$output_directory/ok.out")" >&2; exit 1; }

if "$compiler" build "$cases/shared.ab" -o "$output_directory/shared" --no-cache \
    >"$output_directory/shared.log" 2>&1; then
    echo "thread globals: shared built" >&2; exit 1
fi
for name in registry table hits seen; do
    grep -q "thread.shared-global:$name@" "$output_directory/shared.log" ||
        { echo "thread globals: $name not reported" >&2; cat "$output_directory/shared.log" >&2; exit 1; }
done
grep -q 'wrap it in Shared<T> or Mutex<T>' "$output_directory/shared.log" ||
    { echo "thread globals: no help line" >&2; exit 1; }
if grep -q 'thread.shared-global:__abla' "$output_directory/shared.log"; then
    echo "thread globals: a runtime global reported" >&2; exit 1
fi
if "$compiler" build "$cases/annotation.ab" -o "$output_directory/annotation" --no-cache \
    >"$output_directory/annotation.log" 2>&1; then
    echo "thread globals: @threadShared accepted in a program" >&2; exit 1
fi
grep -q 'threadShared.library:table' "$output_directory/annotation.log" ||
    { echo "thread globals: threadShared.library not reported" >&2; cat "$output_directory/annotation.log" >&2; exit 1; }
echo "thread globals: threads reach only globals no other thread can change"
