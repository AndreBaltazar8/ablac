#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
base="$project_root/build/repl-test"

# Feeds standard input to a REPL of its own, with its output in $base.$1.out and .err.
# The time limits only stop a hung REPL: every line compiles in a child compiler,
# which a loaded machine (the suite runs scripts in parallel) slows several times.
session() { # name seconds
    ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=$2 \
        "$project_root/tools/run-limited.sh" "$compiler" repl \
        > "$base.$1.out" 2> "$base.$1.err"
}

# The sessions share nothing, so they run at once.
printf 'missingName\n20 + 21\n20 + 22\n:quit\n' | session recovery 120 &
recovery=$!
printf 'fun add(value: int): int = value + 1\nadd(41)\nval base: int = 40\nbase + 2\n:reset\nbase\n:quit\n' |
    session definitions 120 &
definitions=$!
# Each line compiles in a child compiler (about half a second, most of it
# the runtime, on an idle machine), so 32 generations stay within the memory
# limit in time.
{
    for _ in $(seq 1 32); do
        printf '20 + 22\n'
    done
    printf ':quit\n'
} | session generations 600 &
generations=$!
# A live session (src/live_repl.ab, where live mode runs): a variable keeps its value across lines, any value
# prints, a line that panics leaves the session and its state as they were, and a redefinition the running code
# cannot take is refused with the old one kept.
live=0
[[ $(uname -s) == Darwin || $(uname -m) == x86_64 ]] && live=1
if ((live)); then
    printf 'var total = 0\ntotal += 5\ntotal\n"ab" + "c"\n1.5 * 3.0\n:quit\n' | session state 300 &
    state=$!
    printf 'val xs = [1, 2]\nxs[5]\nxs.size\n:quit\n' | session panic 300 &
    panicking=$!
    printf 'fun f(): int = 1\nval g = f\nfun f(): string = "x"\nf()\n:quit\n' | session refused 300 &
    refused=$!
fi
wait "$recovery"
wait "$definitions"
wait "$generations"
if ((live)); then
    wait "$state"
    wait "$panicking"
    wait "$refused"
    [[ $(< "$base.state.out") == $'abla> defined\nabla> 5\nabla> 5\nabla> abc\nabla> 4.5\nabla> ' ]] ||
        { echo 'repl (state): a variable did not keep its value, or a value did not print' >&2; cat "$base.state.out" "$base.state.err" >&2; exit 1; }
    [[ $(< "$base.panic.out") == $'abla> defined\nabla> abla> 2\nabla> ' ]] && grep -q 'E_LIVE_PANIC' "$base.panic.err" ||
        { echo 'repl (panic): a line that panics did not leave the session and its state as they were' >&2; cat "$base.panic.out" "$base.panic.err" >&2; exit 1; }
    [[ $(< "$base.refused.out") == $'abla> defined\nabla> defined\nabla> abla> 1\nabla> ' ]] && grep -q 'E_LIVE_SIGNATURE' "$base.refused.err" ||
        { echo 'repl (refused): a refused redefinition did not keep the old one' >&2; cat "$base.refused.out" "$base.refused.err" >&2; exit 1; }
fi

[[ $(< "$base.recovery.out") == $'abla> abla> 41\nabla> 42\nabla> ' ]] || exit 1
grep -q 'identifier:missingName' "$base.recovery.err"
[[ $(< "$base.definitions.out") == $'abla> defined\nabla> 42\nabla> defined\nabla> 42\nabla> reset\nabla> abla> ' ]] || exit 1
grep -q 'identifier:base' "$base.definitions.err"
[[ $(grep -o '42' "$base.generations.out" | wc -l) -eq 32 ]] || exit 1

printf '%s\n' 'persistent REPL: retained definitions + recovery + reclaimed JIT generations; live: state across lines, a contained panic, a refused redefinition'
