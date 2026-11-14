#!/usr/bin/env bash
# Which functions of a Mach-O binary call the given libSystem imports (#811): disassembles the
# binary with otool and prints, for each symbol, the functions whose code calls its stub (otool -tvV
# annotates a call as "bl 0x... ; symbol stub for: _malloc" on arm64, "callq 0x... ## symbol stub
# for: _malloc" on x86-64), so a guard-list entry can be traced to the code that keeps it. It prints
# the binary it read and that binary's undefined symbols among the given ones first, so an empty
# result can be told from a wrong binary. Darwin only, diagnostic (it never fails).
# Usage: tools/macos-import-origin.sh <binary> <symbol>...   (symbols with their underscore, e.g. _malloc)
set -uo pipefail
export LC_ALL=C
[[ $(uname -s) == Darwin ]] || { echo 'macos import origin: Darwin only'; exit 0; }
binary=${1:?usage: macos-import-origin.sh <binary> <symbol>...}
shift
echo "binary: $binary ($(file -b "$binary" 2>&1 | cut -c1-80), $(wc -c < "$binary" | tr -d ' ') bytes)"
undefined=$(nm -u "$binary" 2>&1)
for symbol in "$@"; do
    if grep -qx -- "[[:space:]]*$symbol" <<< "$undefined"; then echo "nm -u: $symbol imported"; else echo "nm -u: $symbol NOT imported"; fi
done
disassembly=$(mktemp)
trap 'rm -f "$disassembly"' EXIT
otool -tvV "$binary" > "$disassembly" 2>&1
echo "otool -tvV: $(wc -l < "$disassembly" | tr -d ' ') lines, $(grep -c 'symbol stub for:' "$disassembly") calls through stubs"
for symbol in "$@"; do
    echo "== $symbol"
    awk -v symbol="$symbol" '
        /^[^ \t].*:$/ { function_name = $0; next }
        index($0, "symbol stub for: " symbol) {
            tail = substr($0, index($0, "symbol stub for: ") + 17)
            if (tail == symbol) seen[function_name]++
        }
        END { for (name in seen) print seen[name], name }' "$disassembly" | sort -rn | head -n 20
done
