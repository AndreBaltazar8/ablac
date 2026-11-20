#!/usr/bin/env bash
# The ownership audit (todo #1039's kin): a value that has one owner must not get a second one. tests/cases/ownership-audit/refused/*.ab are programs
# that must not compile, each with the refusal it must give on its `// refused:` line: a loop's element of an array (or of a map's values) stored,
# bound or returned (it stayed the array's and was dropped twice). drops/*.ab are the
# accepted forms (reads of the loop element, element and field stores with `move`): each drops its resources exactly once
# (release and --fast). The table of every position the audit tried is in TODO.md.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ownership-audit
rm -rf "$out"
mkdir -p "$out"
cases=tests/cases/ownership-audit
for file in "$cases"/refused/*.ab; do
    name=$(basename "$file" .ab)
    expected=$(sed -n 's#^// refused: ##p' "$file" | head -1)
    if "$compiler" build "$file" -o "$out/$name" --fast --no-cache > "$out/$name.log" 2>&1; then
        echo "ownership-audit: $name compiled, and must be refused with $expected" >&2
        exit 1
    fi
    grep -q "$expected" "$out/$name.log" || { cat "$out/$name.log" >&2; echo "ownership-audit: $name is refused, but not with $expected" >&2; exit 1; }
done
for file in "$cases"/drops/*.ab; do
    name=$(basename "$file" .ab)
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        "$compiler" build "$file" -o "$out/$name.$mode" "${flags[@]}" > "$out/$name.$mode.log" 2>&1 || { cat "$out/$name.$mode.log" >&2; echo "ownership-audit: $name ($mode) did not build" >&2; exit 1; }
        result=$("$out/$name.$mode" 2>&1) || { echo "ownership-audit: $name ($mode): $result" >&2; exit 1; }
        [[ $result == *"ownership audit ok"* ]] || { echo "ownership-audit: $name ($mode): $result" >&2; exit 1; }
    done
done
echo "ownership audit: $(ls "$cases"/refused | wc -l) refusals, $(ls "$cases"/drops | wc -l) programs that drop each resource once"
