#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/wrapper-demand"
mkdir -p "$out"
"$compiler" --emit-llvm tests/cases/wrapper-demand/main.ab > "$out/main.ll"
cat > "$out/wrapper-demand.awk" <<'AWK'
NR == FNR {
    if (match($0, /^attributes #[0-9]+ = /) && match($0, /"abla\.source"="[^"]+"/)) {
        id = $0; sub(/^attributes #/, "", id); sub(/ = .*/, "", id)
        attr[id] = substr($0, RSTART + 15, RLENGTH - 16)
    }
    next
}
/^define / { defines[++count] = $0 }
END {
    for (i = 1; i <= count; i++) {
        line = defines[i]
        if (!match(line, /@abla_fn_[0-9]+_[0-9]+_direct\(/) || line !~ /#[0-9]+[ \t]*\{$/) continue
        wrapper = substr(line, RSTART + 1, RLENGTH - 9)
        id = line; sub(/[ \t]*\{$/, "", id); sub(/.*#/, "", id)
        if (attr[id] != "Counter_unused") continue
        for (j = 1; j <= count; j++)
            if (index(defines[j], "@" wrapper "(")) { print "unused boxed wrapper was emitted"; exit 1 }
        exit 0
    }
    print "fixture did not lower its unused method"; exit 1
}
AWK
awk -f "$out/wrapper-demand.awk" "$out/main.ll" "$out/main.ll" || { echo 'wrapper demand: IR guard failed' >&2; exit 1; }
"$compiler" build tests/cases/wrapper-demand/main.ab -o "$out/main" --fast --no-cache
"$out/main"
"$compiler" build tests/cases/internal-function.ab -o "$out/internal" --fast --no-cache
"$out/internal"
echo 'only demanded boxed wrappers are emitted; callback chain and retained entries work'
