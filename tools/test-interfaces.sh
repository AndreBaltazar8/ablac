#!/usr/bin/env bash
# Interfaces: a class's `: Shape, Named` conformance and `extend`, inheritance,
# resource interfaces (dropped through their class), the implicit
# upcast, calls through an interface value (the class's method, an extension
# function or the interface's default body), `as?`, other modules, `#` in both
# tiers (the same results at compile time, and lifted values), the compiler
# API, and the diagnostics.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/interfaces"
output_directory="$project_root/build/interfaces"
mkdir -p "$output_directory"

runs() { # $1 = case, $2 = expected output; $3 = ABLA_COMPILE_EVAL; exit 42 unless $4
    local name=$1 expected=$2 mode=${3:-interp} want=${4:-42} output status
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$cases/$name.ab" \
        -o "$output_directory/${name//\//-}-$mode" --no-cache
    set +e
    output=$("$output_directory/${name//\//-}-$mode")
    status=$?
    set -e
    [[ $status == "$want" ]] || { echo "interfaces: $name ($mode) exited with $status"; exit 1; }
    [[ $output == "$expected" ]] ||
        { echo "interfaces: $name ($mode) printed:"; echo "$output"; exit 1; }
}
rejected() { # $1 = case, then the texts its diagnostics must contain
    local name=$1; shift
    if "$compiler" build "$cases/$name.ab" -o "$output_directory/invalid" \
        --no-cache > "$output_directory/$name.err" 2>&1; then
        echo "interfaces: $name compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/$name.err" ||
            { echo "interfaces: $name lacks '$text'"; cat "$output_directory/$name.err"; exit 1; }
    done
}

runs conformance "3 true false"
runs modules/main "shape of 12 true shape of 12"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
dispatched="14 shape of 4 circle square 2 circle square 3 true true true"
for mode in interp jit; do
    runs dispatch "$dispatched"$'\n'"$dispatched" "$mode"
    runs extend " (1, 2)! #abla! true"$'\n'" (1, 2)! #abla! true" "$mode"
    runs lift "shape of 12 21 true" "$mode"
    runs inheritance "45 24 cube of 8 shape of 9 cube of 8 cube true"$'\n'"45 24 cube of 8 shape of 9 cube of 8 cube true" "$mode"
    runs api $'shape of 4\npoint\nsquare 3\n Shape Labeled | Square Point | area:method describe:default | area:extension describe:extension | false' "$mode" 0
done
runs resource $'peek 3\nfinishing 80\nclose socket 80\nfinishing 3\nclose file 3\nsum 83\nkept 22\nmany 16\nclose file 7\nclose socket 9\nclose socket 22'
rejected missing-member 'interface.missing-member:Shape.area:Square' 'missing-member.ab:5:1'
rejected member-signature 'interface.member-signature:Shape.scaled:Square:function:(f64)->f64' \
    'member-signature.ab:6:5'
rejected inferred-result 'interface.member-signature:Counter.count:Words'
rejected member-untyped 'interface.member-untyped:Closer.close' 'member-untyped.ab:2:5'
rejected unknown 'interface.unknown:Square:Point' 'interface.unknown:Square:Drawable'
rejected duplicate 'interface.duplicate:Square:Shape'
rejected resource-into-plain 'interface.resource-into-plain:Closer:Ticket'
rejected inheritance-cycle 'interface.inheritance-cycle:A' 'interface.inheritance-cycle:B'
rejected inheritance-resource 'interface.inheritance-resource:Labeled:Handle'
rejected member-conflict 'interface.member-conflict:Solid.area:Shape' 'member-conflict.ab:6:5'
rejected default-ambiguous 'interface.default-ambiguous:hello:Both'
[[ $(grep -c 'interface.default-ambiguous' "$output_directory/default-ambiguous.err") == 1 ]] ||
    { echo "interfaces: default-ambiguous reported more than once"; exit 1; }
rejected plain-into-resource 'interface.plain-into-resource:Handle:Plain'
rejected drop-member 'interface.drop-member:Handle'
rejected cast-resource 'interface.cast-resource@'
rejected not-conforming 'function.argument:measure@'
rejected cast-impossible 'interface.cast@' ':Shape:Label' 'cast-impossible.ab:19:17'
rejected extend-unknown 'interface.extend-unknown:Missing'
rejected extend-missing 'interface.missing-member:Shape.area:Square' 'extend-missing.ab:7:1'
echo "interfaces: conformance, extend, inheritance, resource interfaces, dispatch, defaults, as?, modules, # (both tiers), lift, compiler API, diagnostics"
