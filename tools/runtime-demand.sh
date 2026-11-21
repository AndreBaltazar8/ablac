#!/usr/bin/env bash
# Which declarations of the runtime modules (abla/runtime/platform/host.ab, abla/runtime/self/entry.ab) each program's lowering demands, from the compiler's
# ABLA_COMPILER_DEMAND_TRACE=1 (src/ir.ab). Writes build/runtime-demand/<program>.txt (one `<module> <kind> <name>` line each: functions, globals, externs;
# sorted) and prints, per program, how many functions and how many other declarations of each module it demands, then the core (demanded by every program)
# and the union over the programs.
# Usage: tools/runtime-demand.sh <compiler> <program.ab>...
set -euo pipefail
export LC_ALL=C
compiler=${1:?usage: tools/runtime-demand.sh <compiler> <program.ab>...}
shift
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/runtime-demand
rm -rf "$out"
mkdir -p "$out"
count() { # file pattern -> number of lines matching (0 when none)
    grep -c -- "$2" "$1" || true
}
summary() { # label file
    printf '%-24s host: %4d functions %4d others   self: %4d functions %4d others\n' "$1" \
        "$(count "$2" '^host fun ')" "$(( $(count "$2" '^host ') - $(count "$2" '^host fun ') ))" \
        "$(count "$2" '^self fun ')" "$(( $(count "$2" '^self ') - $(count "$2" '^self fun ') ))"
}
names=()
for program in "$@"; do
    name=$(basename -- "$program" .ab)
    ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$program" -o "$out/$name.exe" --fast --no-cache 2> "$out/$name.trace" > /dev/null || true
    # `abla-demanded <identity> <kind> <receiver>.<name> <up front>`
    awk '$1 == "abla-demanded" && ($2 ~ /abla\/runtime\/platform\/host\.ab$/ || $2 ~ /abla\/runtime\/self\/entry\.ab$/) {
        module = ($2 ~ /host\.ab$/) ? "host" : "self"; declaration = $4; sub(/^\./, "", declaration); print module, $3, declaration }' "$out/$name.trace" | sort -u > "$out/$name.txt"
    names+=("$name")
    summary "$name" "$out/$name.txt"
done
cat "$out"/*.txt | sort -u > "$out/union.txt"
cp "$out/${names[0]}.txt" "$out/core.txt"
for name in "${names[@]:1}"; do
    comm -12 "$out/core.txt" "$out/$name.txt" > "$out/core.next"
    mv "$out/core.next" "$out/core.txt"
done
summary core "$out/core.txt"
summary union "$out/union.txt"
