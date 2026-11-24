#!/usr/bin/env bash
# One `ablac analyze --stdio` session as abla-lsp's compiler integration test drives it ("advanced refactors pass the real
# compiler prospective validator", test/compiler-refactors.test.ts): initialize (graph-v2), analyze, six refactor/validate
# requests and shutdown, recorded from that test (tests/cases/analysis-service/refactor-session/session.jsonl, its fixture
# root written @ROOT@). v0.2.68 died with SIGBUS in that session on both macOS runners and passed on Linux.
# Usage: tools/test-analysis-refactor-session.sh [compiler] [rounds]
#   rounds (default 1): the six validations are sent that many times in the one session, a longer session for the same
#   requests (the macOS crash came about 11 s into it).
# Every request must have its reply, each validation `"valid":true`, and the service must exit 0.
set -euo pipefail
compiler=${1:-build/ablac}
rounds=${2:-1}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
case_dir=tests/cases/analysis-service/refactor-session
out=build/analysis-refactor-session
rm -rf "$out"
mkdir -p "$out/fixtures"
fail() { echo "analysis-refactor-session: $1" >&2; exit 1; }
cp "$case_dir/refactor.ab" "$case_dir/debug-app.ab" "$out/fixtures/"
fixtures=$(cd "$out/fixtures" && pwd)
# The session: its first two requests, the six validations `rounds` times (numbered on), its shutdown.
template=$(sed "s|@ROOT@|$fixtures|g" "$case_dir/session.jsonl")
{
    sed -n 1,2p <<< "$template"
    id=3
    for ((round = 0; round < rounds; round++)); do
        while IFS= read -r line; do
            sed -E "s/\"id\":[0-9]+,/\"id\":$id,/" <<< "$line"
            id=$((id + 1))
        done < <(sed -n 3,8p <<< "$template")
    done
    sed -n 9p <<< "$template" | sed "s|\"id\":9,|\"id\":$id,|"
} > "$out/session.jsonl"
requests=$(wc -l < "$out/session.jsonl")
status=0
started=$SECONDS
"$compiler" analyze --stdio < "$out/session.jsonl" > "$out/replies.jsonl" 2> "$out/stderr.txt" || status=$?
seconds=$((SECONDS - started))
[[ $status == 0 ]] ||
    fail "the service exited with status $status after $seconds s ($(wc -l < "$out/replies.jsonl") of $requests replies; $(tail -3 "$out/stderr.txt"))"
[[ $(wc -l < "$out/replies.jsonl") == "$requests" ]] ||
    fail "$(wc -l < "$out/replies.jsonl") replies to $requests requests"
id=1
while IFS= read -r reply; do
    [[ $reply == "{\"schema\":1,\"id\":$id,\"result\":"* ]] || fail "reply $id is not a result: ${reply:0:300}"
    if ((id >= 3 && id < requests)); then
        [[ $reply == *'"valid":true'* ]] || fail "validation $id was refused: ${reply:0:300}"
    fi
    id=$((id + 1))
done < "$out/replies.jsonl"
echo "analysis-refactor-session: $requests requests ($rounds rounds of six validations) answered in $seconds s"
