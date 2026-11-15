#!/usr/bin/env bash
# The lowering asks whether a name is a local that shadows a top-level one by the identifier's source, offset and text, and
# since #814 the source in that key is a short per-path key (bootstrapSourceKey) in a build. Two modules whose identifiers have
# equal (offset, text) must stay distinct under it: tests/cases/source-keys has two twin modules (the bytes equal up to
# `val x`/`val z`), where the `x` of `return x` is the local that shadows the module's `val x` in one and that global in the other.
# The program calls both at run time and through a `#` expression (a nested build in the same process): 40 and 1 each time.
# Fast and release builds. A copy that expects the twins to agree must fail.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/source-keys"
mkdir -p "$out"
source="$project_root/tests/cases/source-keys/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program" > "$out/program.log" 2>&1
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "source keys: status $status (mode '$mode'): $(cat "$out/program.log")" >&2; exit 1; }
done
mutated="$out/mutated"
rm -rf "$mutated"
mkdir -p "$mutated"
cp "$project_root/tests/cases/source-keys/a.ab" "$project_root/tests/cases/source-keys/b.ab" "$mutated/"
sed 's|run == 4001 \&\& folded == 4001|run == 4040 \&\& folded == 4040|' "$source" > "$mutated/main.ab"
cmp -s "$mutated/main.ab" "$source" && { echo "source keys: the negative control changed nothing" >&2; exit 1; }
"$compiler" build "$mutated/main.ab" -o "$out/mutated-program" --fast --no-cache
set +e
"$out/mutated-program" > "$out/mutated.log" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] || { echo "source keys: the negative control was not caught (status $status)" >&2; exit 1; }
echo "source keys: twin modules with equal (offset, text) identifiers stay distinct at run time and through #, fast and release"
