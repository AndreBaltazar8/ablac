# Checks LLVM IR text (usage: awk -v names="A B" -v forbidden="X Y" -v maxslots=N -f this IR IR).
# The first definition of every named function (its abla.source attribute) must contain none
# of the space-separated forbidden substrings and at most maxslots `alloca %AblaValue` slots
# (-1: unlimited); each name must be defined. Prints each violation; exit status 1 if any.
BEGIN {
    n = split(names, list, " "); for (i = 1; i <= n; i++) want[list[i]]
    nf = split(forbidden, bad, " ")
}
NR == FNR {
    if (match($0, /^attributes #[0-9]+ = /) && match($0, /"abla\.source"="[^"]+"/)) {
        id = $0; sub(/^attributes #/, "", id); sub(/ = .*/, "", id)
        attr[id] = substr($0, RSTART + 15, RLENGTH - 16)
    }
    next
}
/^define / && /\{$/ && !inside {
    line = $0; id = ""
    while (match(line, / #[0-9]+/)) { id = substr(line, RSTART + 2, RLENGTH - 2); line = substr(line, RSTART + RLENGTH) }
    if (id != "") { inside = 1; name = attr[id]; slots = 0; hit = "" }
}
inside {
    for (i = 1; i <= nf; i++) if (index($0, bad[i])) hit = bad[i]
    rest = $0
    while (match(rest, /alloca %AblaValue([^A-Za-z0-9_]|$)/)) { slots++; rest = substr(rest, RSTART + RLENGTH) }
    if ($0 == "}") {
        inside = 0
        if ((name in want) && !(name in seen)) {
            seen[name] = 1
            if (hit != "") { print name ": contains " hit; failed = 1 }
            if (maxslots >= 0 && slots > maxslots) { print name ": " slots " value slots"; failed = 1 }
        }
    }
}
END {
    for (n in want) if (!(n in seen)) { print n ": definition not found"; failed = 1 }
    exit failed
}
