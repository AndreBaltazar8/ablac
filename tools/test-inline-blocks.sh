#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* || $compiler != */* ]] || compiler=$PWD/$compiler
out="$root/build/inline-blocks"
mkdir -p "$out"
cd "$root"

for fixture in main fallback; do
    source="tests/cases/inline-blocks/$fixture.ab"
    "$compiler" --emit-llvm "$source" > "$out/$fixture.ir.ll"
    "$compiler" build "$source" --fast --no-cache -o "$out/$fixture"
    "$out/$fixture" > "$out/$fixture.actual"
done

printf '22 51 18\n' > "$out/main.expected"
printf '9 14 4\n' > "$out/fallback.expected"
cmp "$out/main.expected" "$out/main.actual"
cmp "$out/fallback.expected" "$out/fallback.actual"
test -s "$out/main.ir.ll"
test -s "$out/fallback.ir.ll"

# Check the specialized helpers' own blocks. Their original unspecialized
# bodies may also be present in the module.
if ! awk '
    /^define / {
        attr=""
        if (match($0, /#[0-9]+ \{/)) attr=substr($0,RSTART,RLENGTH-2)
    }
    attr!="" && /call (fastcc )?i64 @abla_fn_.*_direct\(i64/ { ++typed[attr] }
    attr!="" && /call .*@abla_llvm_call_indirect\(/ { ++boxed[attr] }
    /^}/ { attr="" }
    /^attributes / && /"abla.source"="__abla_inline_callback_/ {
        ++specializations
        direct += typed[$2]
        indirect += boxed[$2]
    }
    END { exit !(specializations == 3 && direct == 5 && indirect == 0) }
' "$out/main.ir.ll"; then
    echo 'inline blocks: expected direct typed callback specializations' >&2
    exit 1
fi
if ! grep -E 'call .*@abla_llvm_call_indirect\(' "$out/fallback.ir.ll" >/dev/null ||
    grep -F '__abla_inline_callback_' "$out/fallback.ir.ll" >/dev/null; then
    echo 'inline blocks: capturing, forwarded and ordinary callbacks must retain dispatch' >&2
    exit 1
fi
echo 'inline blocks: typed specializations and ordinary closure dispatch passed'
