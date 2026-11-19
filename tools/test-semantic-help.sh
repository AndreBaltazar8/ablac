#!/usr/bin/env bash
# Everyday semantic errors come with a `help:` line, under the machine-readable line they always had (sema.ab:
# bootstrapEverydayHelp, suggestVisibleName, suggestMember): a mismatched argument, result, assignment or initializer
# names both types and the usual conversion; a wrong argument count, a constructor argument and a mixed array literal
# say what is wrong; a misspelled function, local, method or field suggests the one close name code here can reach.
# The suggestion is conservative: one name, within 1 edit (2 past four characters), none on a tie, and never a name
# strict imports hide from the module (tests/cases/semantic-help/hidden.ab: helperOne is declared in a module it
# doesn't import).
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
output_directory="$project_root/build/semantic-help"
mkdir -p "$output_directory"

build() { # case: builds tests/cases/semantic-help/<case>.ab, which must fail, into <case>.log
    if "$compiler" build "$project_root/tests/cases/semantic-help/$1.ab" -o "$output_directory/$1" --fast \
        > "$output_directory/$1.log" 2>&1; then
        echo "semantic-help: tests/cases/semantic-help/$1.ab built; it is all mistakes" >&2
        exit 1
    fi
}
expect() { # case line
    grep -qxF "$2" "$output_directory/$1.log" || {
        echo "semantic-help: $1: no line \"$2\"" >&2
        cat "$output_directory/$1.log" >&2
        exit 1
    }
}
absent() { # case text
    if grep -qF "$2" "$output_directory/$1.log"; then
        echo "semantic-help: $1: \"$2\" should not be there" >&2
        cat "$output_directory/$1.log" >&2
        exit 1
    fi
}

build everyday
# The machine-readable lines are as they were.
for line in 'method.unknown:Point.lenght@' 'member:Point.lenght' 'function.argument:area@' 'assignment.type:d@' \
    'call.target:aera' 'identifier:widht@' 'function.arity:area' 'constructor.argument:Point' 'array.element-type' \
    'local.initializer:n' 'function.result:half:i64:string'; do
    grep -qF "error[E_SEMANTIC]: $line" "$output_directory/everyday.log" ||
        { echo "semantic-help: everyday: no error line \"$line\"" >&2; exit 1; }
done
expect everyday 'help: `Point` has no method `lenght`; did you mean `length`?'
expect everyday 'help: `Point` has no field `lenght`; did you mean `length`?'
expect everyday 'help: `area` takes `int` there, and this argument is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
expect everyday 'help: the value'"'"'s type isn'"'"'t the declared type of `d`'
expect everyday 'help: no function or class named `aera` is visible here; did you mean `area`?'
expect everyday 'help: nothing named `widht` is visible here; did you mean `width`?'
expect everyday 'help: the call gives `area` another number of arguments than it declares (a parameter with a default may be left out)'
expect everyday 'help: an argument of `Point(...)` has a type its constructor parameter doesn'"'"'t take'
expect everyday 'help: an array literal'"'"'s elements all have the array'"'"'s element type, and one of these doesn'"'"'t'
expect everyday 'help: the initializer'"'"'s type isn'"'"'t the declared type of `n`'
expect everyday 'help: `half` is declared to return `int`, and this value is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
absent everyday 'named `completelyUnrelatedName`'

build hidden
expect hidden 'help: no function or class named `helperTwp` is visible here; did you mean `helperTwo`?'
absent hidden 'did you mean `helperOne`'
echo "semantic-help: 11 everyday errors have their help line; a far name and a name strict imports hide are not suggested"
