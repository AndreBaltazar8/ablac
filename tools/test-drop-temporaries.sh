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
# - extensions, interfaces, generics, call-forms: the receiver and arguments of an extension function or operator, of
#   interface dispatch, default bodies and interface extensions, of generic instances, and of named, default,
#   overloaded and indirect calls; each case also compares its order under `#` with the run's (it prints "# differs"
#   otherwise).
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
runs extensions " |receiver 1 |argument of another type's extension 2 |receiver and argument 4 3 |operator 6 5 |in an interpolation v=7 7 |string receiver 8 |condition 9 then |end"
runs interfaces ' |dispatch receiver 1 |default body receiver 2 |default body through the class 3 |dispatch argument 5 4 |default body argument 7 6 |interface extension receiver 8 |plain interface argument 10 |plain default body argument 11 |plain interface extension argument 12 |interface parameter 13 |end'
runs generics ' |generic function 1 |generic class method 2 |returns T 3 4 |T is the resource 5 6 |bounded 7 |generic extension 8 |end'
runs call-forms " |named 1 |default 2 |overloads 3 4 |function value 5 |lambda 6 |when arm 7 |callee's lambda 9 |for over a method's array x10 x11 10 |array append of a field 11 |map key from a method 12 |end"
runs nested-order $'B2HI2HI1|B4HI4HI3|B6HI6HI5|B8HI8HI7|B10HI10HI9Y1|F12HI12HI11|B14HI14HI13|B19HI19,B18HI18HI17,|\nB2HI2HI1|B4HI4HI3|B6HI6HI5|B8HI8HI7|B10HI10HI9Y1|F12HI12HI11|B14HI14HI13|B19HI19,B18HI18HI17,|'
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
