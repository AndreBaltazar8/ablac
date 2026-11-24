#!/usr/bin/env bash
# No extern of the hosted Windows runtime is declared wider than its C function returns. A C function that returns a 32-bit type (BOOL,
# DWORD, int) leaves the upper half of rax (x0 on ARM64) undefined, and a failure's -1 arrived as 4294967295 when ws2_32's calls were
# declared as 64-bit ints (read(2) on a socket that would block answered 4 GiB: tests/cases/windows/socket-failure.ab). The C return type of
# every extern is in tools/windows-extern-returns.tsv; this fails on an extern missing there, on a 32-bit (or 8-bit) one declared int, and
# on a line of the table that no extern has. The control declares one BOOL as int and must be refused.
# Usage: tools/test-windows-extern-widths.sh
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
runtime=stdlib/abla/runtime/platform/windows/entry.ab
table=tools/windows-extern-returns.tsv
out=build/windows-extern-widths
mkdir -p "$out"

# check <runtime source>: prints each problem, returns 1 when there is one.
check() {
    grep -E 'extern:"c" fun ' "$1" | sed -E 's/.*fun ([A-Za-z0-9_]+)\(.*\): ([A-Za-z0-9*]+)$/\1\t\2/' > "$out/declared.tsv"
    grep -v '^#' "$table" | awk -F '\t' 'NF >= 3 { print $1 "\t" $3 }' > "$out/table.tsv"
    awk -F '\t' -v table="$out/table.tsv" '
        BEGIN { while ((getline line < table) > 0) { split(line, part, "\t"); bits[part[1]] = part[2] } }
        { seen[$1] = 1 }
        !($1 in bits) { print "not in " "tools/windows-extern-returns.tsv: " $1; bad = 1; next }
        bits[$1] == 0 && $2 != "void" { print $1 " returns void in C and is declared " $2; bad = 1 }
        (bits[$1] == 8 || bits[$1] == 32) && $2 != "i32" { print $1 " returns " bits[$1] " bits in C and is declared " $2 ": declare it i32 and widen at the use"; bad = 1 }
        bits[$1] == 64 && $2 != "int" && $2 != "i64" && $2 != "i64*" { print $1 " returns 64 bits in C and is declared " $2; bad = 1 }
        END {
            for (name in bits) if (!(name in seen)) { print "in the table, no such extern: " name; bad = 1 }
            exit bad
        }' "$out/declared.tsv"
}

if ! check "$runtime"; then
    echo "windows extern widths: see above" >&2
    exit 1
fi
# The control: BOOL CloseHandle declared as a 64-bit int.
sed -E 's/^(.*extern:"c" fun CloseHandle\(.*\)): i32$/\1: int/' "$runtime" > "$out/control.ab"
if check "$out/control.ab" > "$out/control.log" 2>&1; then
    echo "windows extern widths: the control (CloseHandle declared int) was not refused" >&2
    exit 1
fi
grep -q '^CloseHandle returns 32 bits in C and is declared int' "$out/control.log" || {
    echo "windows extern widths: the control was refused for something else:" >&2
    cat "$out/control.log" >&2
    exit 1
}
echo "windows extern widths: $(wc -l < "$out/declared.tsv") externs, none declared wider than its C return type; the control is refused"
