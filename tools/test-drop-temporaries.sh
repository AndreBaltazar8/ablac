#!/usr/bin/env bash
# A resource that is only a temporary (the receiver of a method or of a field read, an argument to a borrowing
# parameter) is dropped at the end of its statement, of the condition or `when` subject it is part of, or of the
# short-circuit operand or arm it was made in, newest first. Each case adds every drop's id to a string it prints.
# - positions: every place a temporary can be, and the ones that were always dropped (a discarded result, an `own`
#   parameter, a `?.` chain);
# - branches: an operand or an arm that is not evaluated drops nothing; a loop condition and body drop on each pass;
# - exits: a `return`, `break` or `continue` in the middle of a statement drops the temporaries made so far;
# - owned: what something takes (a constructor argument, an `own` parameter, a `move`, an array element, a bound
#   `val`) is not dropped a second time;
# - viewed: a view of a temporary used within its statement is fine, and the temporary goes after it;
# - contexts: a lambda, an expression-bodied function, a `defer`, a generator and a global's initializer;
# - loops: a `for` with a single-expression body drops on each pass and not at all when it does not run;
# - evaluator: the compile-time evaluator drops the same temporaries in the same order as the compiled program;
# - labeled: a labeled break or continue through statements with temporaries, and a generator given to a borrowing
#   parameter (a `for` over it ends it: only class instances are held as temporaries);
# - alias: a view of a temporary's field kept after its statement sees what the drop did (it is accepted);
# - refused: a view of a temporary kept after its statement is still refused.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/drop-temporaries"
output_directory="$project_root/build/drop-temporaries"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}

runs() { # $1 = case, $2 = the line it must print (exit 42)
    local mode output status
    for mode in "" --fast; do
        "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache $mode
        set +e
        output=$("$output_directory/$1")
        status=$?
        set -e
        [[ $status == 42 && $output == "$2" ]] ||
            { echo "drop-temporaries: $1 ${mode:-release} exited $status and printed:"; echo "$output"; exit 1; }
    done
    # The same in the JIT.
    set +e
    output=$("$compiler" run "$cases/$1.ab")
    status=$?
    set -e
    [[ $status == 42 && $output == "$2" ]] ||
        { echo "drop-temporaries: run $1 exited $status and printed:"; echo "$output"; exit 1; }
}

runs positions ' |receiver 1 body |borrowed argument 2 |discarded result 3 |if condition 4 then |while condition 5 5 5 |when subject 6 six |loop body 7 7 |field of a temporary 8 |early return 30 31 |two arguments 11 10 |receiver and argument 13 12 |own parameter 14 |moved into a val owner-made |interpolation v=16 16 |returned by a call 17 |safe call 18 |array literal |nested 121 21 |end'
runs branches ' |and skipped |or skipped |and taken 3 |or taken 4 |left operand 6 5 |if arms 7 |if arm expression 9 |else arm 12 |condition each pass 20 21 22 23 |body each pass 30 in 31 in 32 in |do while 41 42 |end'
runs exits ' |return 1 |no return 1 |break and continue 10 11 12 13 |end'
runs owned ' |constructor held |holder temporary 2 |own 3 |array |move 5 |bound |end'
runs viewed '10 31 owner1 after10 owner3 owner2'
runs contexts ' 90 |lambda 50 |expression body 51 52 |defer 54 touched55 55 53 deferred |generator 60 61 |generator break 60 61 |end'
runs loops ' |bare body 0 1 2 |no pass |source item20 item21 20 |array |end'
runs labeled ' |nested 0 100 1 10 110 11 111 12 20 120 |or break 200 201 |do continue 310 311 320 321 |generator argument 401 402 403 |end'
runs alias '0'
runs evaluator 'true'
runs affine-projection $'BHI|BHI|BHI|BHI|B|BHI|BHI|HI\nBHI|BHI|BHI|BHI|B|BHI|BHI|HI'

if "$compiler" build "$cases/affine-projection-refused.ab" -o "$output_directory/affine-refused" --no-cache > "$output_directory/affine-refused.err" 2>&1; then
    echo "drop-temporaries: affine projection transfers compiled"; exit 1
fi
for text in "ownership.place-move-required:local.x" "ownership.place-move-required:argument.function.take" "ownership.place-move-required:return" "ownership.place-move-required:assignment.x" "ownership.place-owner:"; do
    grep -qF -- "$text" "$output_directory/affine-refused.err" ||
        { echo "drop-temporaries: affine projection refusal lacks '$text'"; cat "$output_directory/affine-refused.err"; exit 1; }
done

if "$compiler" build "$cases/refused.ab" -o "$output_directory/refused" --no-cache > "$output_directory/refused.err" 2>&1; then
    echo "drop-temporaries: refused compiled"; exit 1
fi
for text in "ownership.borrow-source:kept" "function.result:same:borrow:Owner:Owner"; do
    grep -qF -- "$text" "$output_directory/refused.err" ||
        { echo "drop-temporaries: refused lacks '$text'"; cat "$output_directory/refused.err"; exit 1; }
done

echo "drop temporaries: ok"
