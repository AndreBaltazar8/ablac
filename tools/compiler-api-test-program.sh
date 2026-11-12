#!/usr/bin/env bash
# Prepare the shared compiler-API client; print only its executable path.
#
# The compiler's own source/toolchain cache validates every request. A
# directory lock coalesces concurrent cold builds (flock is not on macOS),
# with no hand-written stale-input stamp. Every caller still runs its case in
# a separate process.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: compiler-api-test-program.sh COMPILER" >&2
    exit 1
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
requested=$1
if [[ $requested == */* ]]; then
    compiler=$requested
else
    compiler=$(command -v "$requested" || printf '%s' "$requested")
fi
[[ $compiler == /* ]] || compiler=$PWD/$compiler
identity=$compiler
[[ -f $compiler.bin ]] && identity=$compiler.bin
if command -v sha256sum >/dev/null 2>&1; then
    key=$(sha256sum "$identity" | cut -d' ' -f1)
else
    key=$(shasum -a 256 "$identity" | cut -d' ' -f1)
fi
output=$root/build/compiler-api-tests/$key
mkdir -p "$output"
program=$output/program
lock=$output/build.lock.d

# The lock is a directory holding its owner's pid; a lock whose owner is gone
# (killed without a chance to clean up) is taken over.
held=0
release() {
    if [[ $held == 1 ]]; then
        rm -rf "$lock"
        held=0
    fi
}
trap release EXIT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 130' INT
until mkdir "$lock" 2>/dev/null; do
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ -n $owner ]] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$lock"
        continue
    fi
    sleep 0.2
done
held=1
printf '%s\n' "$$" > "$lock/pid"

# No tested state is cached: this is only the executable containing the
# clients. Their tested inputs/effects run at runtime, so each client still
# creates its own compiler/IR caches in a fresh process. Let NativeBuild
# validate sources, compiler identity and native toolchain; a warm request
# skips frontend analysis and LLVM compilation.
# The build runs in the background and is waited for, so a TERM reaches the
# trap while it runs; the trap then stops the compiler child.
(cd "$root" && exec "$compiler" build "$root/tests/cases/compiler-api/main.ab" \
    -o "$program" --fast >&2) &
child=$!
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 143' TERM
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit 129' HUP
status=0
wait "$child" || status=$?
trap 'exit 143' TERM
trap 'exit 129' HUP
if [[ $status -ne 0 ]]; then
    exit "$status"
fi
printf '%s\n' "$program"
