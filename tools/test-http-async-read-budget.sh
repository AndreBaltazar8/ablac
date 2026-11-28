#!/usr/bin/env bash
# One read of an async HTTP connection stops at httpAsyncReadBudget and the next step reads the rest without waiting
# (tests/cases/http-async/read-budget.ab). Usage: tools/test-http-async-read-budget.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http-async-read-budget
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/http-async/read-budget.ab -o "$out/read-budget" --no-cache
result=$("$root/tools/run-limited.sh" "$out/read-budget") || { echo "http-async-read-budget: $result" >&2; exit 1; }
[[ $result == 'http-async read budget ok' ]] || { echo "http-async-read-budget: $result" >&2; exit 1; }
echo "$result"
