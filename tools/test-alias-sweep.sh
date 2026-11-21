#!/usr/bin/env bash
# A standard-library module imported under an alias must build like the module imported plainly. tests/cases/alias-stdlib-json runs abla/json
# under an alias (its method `string` once gave the type `string` the module's prefix: ~1000 errors), and the modules listed below are built
# plainly and as `import "<module>" as q` (front end and object only). `--all` does it for every stdlib module (about 140, several minutes).
# Known failing under an alias (todo #1083, each also listed in the waiver below): abla/serial (a name reached through two `export import`
# levels), abla/runtime/self (the runtime's intrinsics are not meant to be imported by a program).
# Usage: tools/test-alias-sweep.sh [compiler] [--all]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
all=${2:-}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/alias-sweep
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/alias-stdlib-json/main.ab -o "$out/json" --fast --no-cache > "$out/json.build.log" 2>&1 ||
    { echo 'alias sweep: tests/cases/alias-stdlib-json did not build' >&2; head -20 "$out/json.build.log" >&2; exit 1; }
code=0
"$out/json" > "$out/json.out" 2>&1 < /dev/null || code=$?
[[ $code == 42 ]] || { echo "alias sweep: alias-stdlib-json exited $code" >&2; cat "$out/json.out" >&2; exit 1; }
waived=" abla/serial abla/runtime/self abla/io "
if [[ $all == --all ]]; then
    modules=$(cd stdlib && find abla -name entry.ab | sed 's#/entry.ab##' | sort)
else
    modules='abla/json abla/http/h2/hpack abla/text abla/bytes abla/math abla/yaml abla/regex'
fi
failed=0
for module in $modules; do
    [[ $waived == *" $module "* ]] && continue
    name=${module//\//_}
    printf 'import "abla/io"\nimport "%s" as q\n\nfun main: int {\n    println("x")\n    0\n}\n' "$module" > "$out/$name.ab"
    if ! "$compiler" build "$out/$name.ab" --emit object -o "$out/$name.o" --fast --no-cache > "$out/$name.log" 2>&1; then
        echo "alias sweep: $module fails under an alias:" >&2
        grep -a '^error' "$out/$name.log" | sed 's/__abla_module_[0-9a-f]*__/M__/g' | sort | uniq -c | sort -rn | head -5 >&2
        failed=1
    fi
done
[[ $failed == 0 ]] || exit 1
echo 'alias sweep: abla/json under an alias runs, and the modules listed build under an alias'
