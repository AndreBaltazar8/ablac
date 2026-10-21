#!/usr/bin/env bash
# Interfaces: a class's `: Shape, Named` conformance, the implicit upcast where
# an interface is expected, and the conformance diagnostics.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/interfaces"
output_directory="$project_root/build/interfaces"
mkdir -p "$output_directory"

runs() { # $1 = case, $2 = expected output; the program exits 42
    local name=$1 expected=$2 output status
    "$compiler" build "$cases/$name.ab" -o "$output_directory/$name" --no-cache
    set +e
    output=$("$output_directory/$name")
    status=$?
    set -e
    [[ $status == 42 ]] || { echo "interfaces: $name exited with $status"; exit 1; }
    [[ $output == "$expected" ]] ||
        { echo "interfaces: $name printed:"; echo "$output"; exit 1; }
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
rejected missing-member 'interface.missing-member:Shape.area:Square' 'missing-member.ab:5:1'
rejected member-signature 'interface.member-signature:Shape.scaled:Square:function:(f64)->f64' \
    'member-signature.ab:6:5'
rejected unknown 'interface.unknown:Square:Point' 'interface.unknown:Square:Drawable'
rejected duplicate 'interface.duplicate:Square:Shape'
rejected resource-into-plain 'interface.resource-into-plain:Closer:Ticket'
rejected inheritance 'interface.inheritance:Solid'
rejected not-conforming 'function.argument:measure@'
echo "interfaces: conformance, upcasts, conformance diagnostics"
