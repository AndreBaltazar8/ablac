#!/usr/bin/env bash
# Lists the dynamic imports of the small hosted programs in tests/cases/libc-imports
# (built release and --fast) and of the compiler itself on macOS, the start of a
# Darwin guard list like tools/libc-imports-allowlist.txt (#811). Each line is
# "<subject> <symbol>"; a needed library is "needed:<install name>". The compiler's
# libLLVM C API calls are left out, as on Linux. Usage:
#   tools/macos-libsystem-inventory.sh <compiler> [output-directory]
set -euo pipefail
export LC_ALL=C
[[ $(uname -s) == Darwin ]] || { echo 'macos libsystem inventory: Darwin only' >&2; exit 2; }
compiler=${1:?usage: macos-libsystem-inventory.sh <compiler> [output-directory]}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=${2:-build/macos-libsystem-inventory}
rm -rf "$out"; mkdir -p "$out"
imports() { # subject binary
    otool -L "$2" | sed -n '2,$s/^[[:space:]]*\([^ ]*\) (.*/needed:\1/p' | sed "s/^/$1 /"
    nm -u "$2" | awk -v subject="$1" 'NF >= 1 { symbol = $NF
        if (symbol ~ /^_?LLVM/) next
        print subject " " symbol }'
}
actual=$out/actual.txt
: > "$actual"
for program in tests/cases/libc-imports/*.ab; do
    name=$(basename "$program" .ab)
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        if "$compiler" build "$program" -o "$out/$name.$mode" "${flags[@]}" > "$out/$name.$mode.log" 2>&1; then
            imports "$name.$mode" "$out/$name.$mode" >> "$actual"
        else
            echo "$name.$mode BUILD-FAILED" >> "$actual"
            tail -n 8 "$out/$name.$mode.log" >&2
        fi
    done
done
# The compiler: a launcher script is followed to the payload next to it.
binary=$compiler
[[ -f $binary.bin ]] && binary=$binary.bin
imports compiler "$binary" >> "$actual"
sort -u "$actual" -o "$actual"
echo "==== $(wc -l < "$actual" | tr -d ' ') lines; by subject:"
awk '{ count[$1]++ } END { for (s in count) print count[s], s }' "$actual" | sort -k2
echo "==== inventory"
cat "$actual"
