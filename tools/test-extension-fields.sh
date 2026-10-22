#!/usr/bin/env bash
# Extension fields (`var Point.label: string = ""`): reads, writes, defaults,
# mutations through them, `val`, other modules, drops, `#` in both tiers, the
# compiler API, the diagnostics, and the reserved syntax beside them.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/extension-fields"
output_directory="$project_root/build/extension-fields"
mkdir -p "$output_directory"

runs() { # $1 = case, $2 = expected output; $3 = ABLA_COMPILE_EVAL (optional)
    local name=$1 expected=$2 mode=${3:-interp}
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/$name.ab" \
        -o "$output_directory/$name-$mode" --no-cache
    local output
    output=$("$output_directory/$name-$mode") ||
        { echo "extension fields: $name ($mode) exited with $?"; exit 1; }
    [[ $output == "$expected" ]] ||
        { echo "extension fields: $name ($mode) printed:"; echo "$output"; exit 1; }
}
rejected() { # $1 = case, then the texts its diagnostics must contain; ABLA_COMPILE_EVAL from $mode
    local name=$1; shift
    if ABLA_COMPILE_EVAL=${mode:-interp} "$compiler" build "$cases/$name.ab" \
        -o "$output_directory/invalid" --no-cache > "$output_directory/$name.err" 2>&1; then
        echo "extension fields: $name compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$name.err" ||
            { echo "extension fields: $name lacks '$text'"; cat "$output_directory/$name.err"; exit 1; }
    done
}

runs basic $'none 30\nnamed 31\n0\n2\n0\n7\nnone 50 0'
runs modules/main $'t4!\nt4+ t4+!\n2'
runs drops $'drop ticket 1\nbefore drop\ndrop holder h\ndrop ticket 2\ndrop ticket 3'
"$compiler" build "$cases/words.ab" -o "$output_directory/words" --no-cache
set +e
"$output_directory/words"
status=$?
"$compiler" build "$cases/reassign.ab" -o "$output_directory/reassign" --no-cache
"$output_directory/reassign" 2> "$output_directory/reassign.err"
reassigned=$?
set -e
[[ $status == 42 ]] || { echo "extension fields: words exited with $status"; exit 1; }
[[ $reassigned != 0 ]] && grep -qF 'field.extension-reassigned:Point.born' "$output_directory/reassign.err" ||
    { echo "extension fields: a second assignment of a val wasn't stopped"; exit 1; }

# (Under a memory limit the interpreter caches each class's field names: an
# instance that gains a field mustn't change them for the next one.)
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
for mode in interp jit; do
    runs compile-time $'none 30|named 31|0|2|0|7|50\nnone 30|named 31|0|2|0|7|50' "$mode"
    runs lift "2 lifted" "$mode"
    rejected compile-time-reassigned E_EVAL_EXTENSION_REASSIGNED \
        'field.extension-reassigned:Point.born'
done
runs api $'30 false e\n level tag maxHp seen | level'

rejected invalid field.extension-default:Point.missing field.extension-owner:int \
    field.extension-owner:Meters field.extension-owner:Nowhere field.extension-owner:Shape \
    field.extension-shadows:Point.area field.extension-shadows:Point.x \
    field.extension-untyped:Point.untyped field.extension-type:Point.wrong \
    symbol.duplicate:Point.label
[[ $(grep -c 'symbol.duplicate' "$output_directory/invalid.err") == 1 ]] ||
    { echo "extension fields: a duplicate reported more than once"; exit 1; }
rejected invalid-resource field.extension-resource:Plain.t
rejected reserved E_PARSE_NOT_YET_SUPPORTED
[[ $(grep -c 'E_PARSE_NOT_YET_SUPPORTED' "$output_directory/reserved.err") == 4 ]] ||
    { echo "extension fields: reserved syntax:"; cat "$output_directory/reserved.err"; exit 1; }
echo "extension fields: reads, writes, defaults, mutations, val, modules, drops, # (both tiers), compiler API, diagnostics, reserved syntax"
