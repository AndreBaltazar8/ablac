#!/usr/bin/env bash
# A --fast program and its prebuilt runtime object (fast_runtime.ab) define each runtime variable once (#1308). Code on both
# sides of the split uses some: a helper both compile (__ablaRuntimeHostOutOfMemory and its flag) or a module the object
# reaches too (self/stm.ab's shared transaction state). Two definitions are two variables, each side keeping its own
# state, and nothing failed: the symbols are local, so the link took both. The object defines them and exports them hidden;
# the program declares them.
#
#   tools/test-fast-runtime-globals.sh [compiler]
set -euo pipefail

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || exit 0
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$root/build"
scratch=$(mktemp -d "$root/build/fast-runtime-globals.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
export ABLA_CACHE_DIR=$scratch/cache
unset ABLA_FAST_RUNTIME_OBJECT
cat > "$scratch/main.ab" <<'ABLA'
import "abla/io"

fun main: int {
    println("one runtime")
    0
}
ABLA

"$compiler" build "$scratch/main.ab" --fast -o "$scratch/program"
[[ $("$scratch/program") == "one runtime" ]] || { echo "test-fast-runtime-globals: the program printed the wrong text" >&2; exit 1; }
objects=("$ABLA_CACHE_DIR"/fast-runtime-v1/*/runtime.o)
[[ ${#objects[@]} == 1 && -s ${objects[0]} ]] ||
    { echo "test-fast-runtime-globals: the build used no prebuilt runtime object" >&2; exit 1; }
programs=()
for object in "$ABLA_CACHE_DIR"/native-*.o; do
    [[ $object == *.runtime-sidecar-* ]] || programs+=("$object")
done
[[ ${#programs[@]} == 1 ]] || { echo "test-fast-runtime-globals: expected one program object, found ${#programs[@]}" >&2; exit 1; }

# The writable data each object defines (nm: d, D, b, B), runtime variables only.
writable() { nm --defined-only "$1" | awk '$2 ~ /^[dDbB]$/ && $3 ~ /^abla_global_/ { print $3 }' | sort -u; }
writable "${objects[0]}" > "$scratch/object.globals"
writable "${programs[0]}" > "$scratch/program.globals"
[[ -s $scratch/object.globals ]] || { echo "test-fast-runtime-globals: the runtime object defines no runtime variable" >&2; exit 1; }
both=$(comm -12 "$scratch/object.globals" "$scratch/program.globals")
if [[ -n $both ]]; then
    echo "test-fast-runtime-globals: runtime variables defined in both the program and the runtime object:" >&2
    echo "$both" >&2
    exit 1
fi
# The program's references to them resolve to the object's definitions, which it exports.
nm --undefined-only "${programs[0]}" | awk '$2 ~ /^abla_global_/ { print $2 }' | sort -u > "$scratch/program.uses"
[[ -n $(comm -12 "$scratch/object.globals" "$scratch/program.uses") ]] ||
    { echo "test-fast-runtime-globals: the program uses none of the object's runtime variables" >&2; exit 1; }
nm --defined-only "${objects[0]}" | awk '$2 ~ /^[DB]$/ && $3 ~ /^abla_global_/' | grep . > /dev/null ||
    { echo "test-fast-runtime-globals: the object exports none of its runtime variables" >&2; exit 1; }
echo "test-fast-runtime-globals: the program and the runtime object share each runtime variable, defined once"
