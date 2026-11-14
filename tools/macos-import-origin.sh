#!/usr/bin/env bash
# Which functions of a Mach-O binary call the given libSystem imports (#811): disassembles the
# binary with otool and prints, for each symbol, the functions whose code branches to its stub,
# so a guard-list entry can be traced to the code that keeps it. Darwin only, diagnostic (it never fails).
# Usage: tools/macos-import-origin.sh <binary> <symbol>...   (symbols with their underscore, e.g. _malloc)
set -uo pipefail
export LC_ALL=C
[[ $(uname -s) == Darwin ]] || { echo 'macos import origin: Darwin only'; exit 0; }
binary=${1:?usage: macos-import-origin.sh <binary> <symbol>...}
shift
for symbol in "$@"; do
    echo "== $symbol"
    otool -tvV "$binary" 2>/dev/null | awk -v symbol="$symbol" '
        /^[^ \t].*:$/ { function_name = $0; next }
        $0 ~ "(bl|b|jmp|call|callq)[ \t]+" symbol "(\\$stub)?[ \t]*$" || index($0, symbol "$stub") { seen[function_name]++ }
        END { for (name in seen) print seen[name], name }' | sort -rn | head -n 20
done
