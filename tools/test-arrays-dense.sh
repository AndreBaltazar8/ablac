#!/usr/bin/env bash
# Arrays of numbers and bools are stored densely and box on demand.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/arrays-dense"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/arrays-dense.ab" \
    -o "$output_directory/program"
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "dense arrays: numbers and bools in 8-byte words, boxed on demand"

# Native scalar stores and boxed-storage fallback preserve every payload bit.
for profile in release fast o1; do
    flags=()
    [[ $profile == release ]] || flags=(--"$profile")
    "$compiler" build "$project_root/tests/cases/modules/scalar-array-setters.ab" \
        --no-cache -o "$output_directory/scalars-$profile" "${flags[@]}"
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$output_directory/scalars-$profile" || status=$?
        [[ $status == 42 ]] || exit 1
    done
    "$compiler" build "$project_root/tests/cases/modules/scalar-array-set-trap.ab" \
        --no-cache -o "$output_directory/trap-$profile" "${flags[@]}"
    for kind in i64 bool f64 f32; do
        for bound in upper negative; do
            arguments=("$kind")
            index=2
            if [[ $bound == negative ]]; then arguments+=(negative); index=-1; fi
            status=0
            "$output_directory/trap-$profile" "${arguments[@]}" \
                > "$output_directory/trap.out" 2> "$output_directory/trap.err" || status=$?
            [[ $status == 101 ]] || { cat "$output_directory/trap.err"; exit 1; }
            IFS= read -r message < "$output_directory/trap.err"
            [[ $message == "panic: index $index out of bounds for array of size 2" ]] || exit 1
        done
    done
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/scalar-array-setters/staged.ab" \
        --no-cache -o "$output_directory/staged-$mode"
    status=0
    "$output_directory/staged-$mode" || status=$?
    [[ $status == 42 ]] || exit 1
done

"$compiler" --emit-llvm "$project_root/tests/cases/modules/scalar-array-setters.ab" \
    > "$output_directory/scalars.ll"
cat > "$output_directory/scalars.awk" <<'AWK'
# Scalar array setters must lower to the word store with at most one value slot.
BEGIN { want["scalarI64Store"]; want["scalarBoolStore"]; want["scalarF64Store"]; want["scalarF32Store"] }
NR == FNR {
    if (match($0, /^attributes #[0-9]+ = /)) {
        id = substr($0, 13, RLENGTH - 15)
        if (match($0, /"abla\.source"="[^"]+"/)) {
            s = substr($0, RSTART + 15, RLENGTH - 16)
            attr[id] = s
        }
    }
    next
}
/^define / && /\{$/ && !inside {
    line = $0; id = ""
    while (match(line, / #[0-9]+/)) { id = substr(line, RSTART + 2, RLENGTH - 2); line = substr(line, RSTART + RLENGTH) }
    if (id != "") { inside = 1; name = attr[id]; hasword = 0; hasgeneric = 0; slots = 0 }
}
inside {
    if (index($0, "call void @abla_array_set_word(i64 ")) hasword = 1
    if (index($0, "call void @abla_array_set(")) hasgeneric = 1
    rest = $0
    while (match(rest, /alloca %AblaValue([^A-Za-z0-9_]|$)/)) { slots++; rest = substr(rest, RSTART + RLENGTH) }
    if ($0 == "}") {
        inside = 0
        if ((name in want) && !(name in seen)) {
            if (!hasword) { print name ": no word store"; bad = 1 }
            if (hasgeneric) { print name ": generic store call"; bad = 1 }
            if (slots > 1) { print name ": " slots " value slots"; bad = 1 }
            seen[name] = 1
        }
    }
}
END {
    for (n in want) if (!(n in seen)) { print n ": definition not found"; bad = 1 }
    exit bad
}
AWK
awk -f "$output_directory/scalars.awk" "$output_directory/scalars.ll" "$output_directory/scalars.ll" || { echo 'scalar arrays: scalar store lowering guard failed' >&2; exit 1; }
echo "scalar arrays: native words, exact float bits, boxed fallback, checked bounds and staged stores"
