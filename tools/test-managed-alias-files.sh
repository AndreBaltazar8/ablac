#!/usr/bin/env bash
set -euo pipefail

# The analysis records a `val` that aliases a managed value by its offsets;
# lowering matches them together with the file. main.ab declares plain `val`s
# at the offsets of holder.ab's aliases (a function's and a method's local):
# they lower as values of their own file, and the program's code is the same
# as when holder.ab's offsets are elsewhere.
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
cases=$project_root/tests/cases/managed-alias-files
output=$project_root/build/managed-alias-files
rm -rf "$output"
mkdir -p "$output/aligned" "$output/shifted"

# offset FILE TEXT: the byte offset of TEXT in FILE.
offset() {
    grep -bo -- "$2" "$1" | head -1 | cut -d: -f1
}
for pair in 'val itemsOfBox = this.items|val values = this.start + 1' \
    'val items = box.items|val total = x + 1 + 2'; do
    alias=${pair%%|*}
    local=${pair#*|}
    if [[ ${#alias} -ne ${#local} ||
        $(offset "$cases/holder.ab" "$alias") != $(offset "$cases/main.ab" "$local") ]]; then
        echo "managed alias files: \`$local\` no longer sits at \`$alias\`'s offsets" >&2
        exit 1
    fi
done

cp "$cases/main.ab" "$cases/holder.ab" "$output/aligned/"
cp "$cases/main.ab" "$output/shifted/"
{ echo '// Every offset after this line moves.'; cat "$cases/holder.ab"; } \
    > "$output/shifted/holder.ab"

"$compiler" build "$output/aligned/main.ab" -o "$output/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "managed alias files: the program exited $status, expected 42" >&2
    exit 1
fi

for variant in aligned shifted; do
    "$compiler" --emit-llvm "$output/$variant/main.ab" > "$output/$variant.ll"
done
if ! cmp -s "$output/aligned.ll" "$output/shifted.ll"; then
    echo "managed alias files: main.ab's code depends on holder.ab's offsets" >&2
    exit 1
fi
echo 'Managed alias files passed'
