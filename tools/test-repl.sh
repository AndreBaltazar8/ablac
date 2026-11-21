#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
base="$project_root/build/repl-test"

# Feeds standard input to a REPL of its own, with its output in $base.$1.out and .err.
# The time limits only stop a hung REPL: a loaded machine (the suite runs scripts in parallel) slows its compiles
# several times. Where live mode runs (x86-64 Linux, macOS) the REPL is one live program and one compiler for the
# whole session (src/live_repl.ab), whose address space passes 1 GB within a few lines: 3 GB there; elsewhere each
# line compiles in a child compiler of its own, 1 GB.
live=0
[[ $(uname -s) == Darwin || $(uname -m) == x86_64 ]] && live=1
memory=1024
((live)) && memory=3072
session() { # name seconds
    ABLA_MAX_MEMORY_MB=$memory ABLA_MAX_SECONDS=$2 \
        "$project_root/tools/run-limited.sh" "$compiler" repl \
        > "$base.$1.out" 2> "$base.$1.err"
}

# The sessions share nothing, so they run at once.
printf 'missingName\n20 + 21\n20 + 22\n:quit\n' | session recovery 120 &
recovery=$!
printf 'fun add(value: int): int = value + 1\nadd(41)\nval base: int = 40\nbase + 2\n:reset\nbase\n:quit\n' |
    session definitions 120 &
definitions=$!
# An entry continues while a bracket is open ("....> "): a function over four lines, an expression over two; an empty
# line ends one still open (its error is shown, and the session goes on).
printf 'fun add(value: int): int {\n    val one = 1\n    return value + one\n}\nadd(41)\n(1 +\n2)\n(1 +\n\n20 + 22\n:quit\n' |
    session multiline 120 &
multiline=$!
# Commands: :help lists them, an unknown one is refused without a compile (no parser error), and a command may have
# spaces around it (the ":quit " ends the session before the last line).
printf ':help\n:nope 1\n20 + 22\n  :quit \n20 + 1\n' | session commands 120 &
commands=$!
# A diagnostic names its place in the entry (line and column of what was typed), never the session's hidden source
# file: in a declaration over lines, in an expression, and at the end of one cut short.
printf 'fun f(): int {\n    return missing\n}\n1 + nope\n(2 *\n\n:quit\n' | session diagnostics 120 &
diagnostics=$!
# Each line compiles in a child compiler (about half a second, most of it
# the runtime, on an idle machine), so 32 generations stay within the memory
# limit in time.
{
    for _ in $(seq 1 32); do
        printf '20 + 22\n'
    done
    printf ':quit\n'
} | session generations 600 &
generations=$!
# A live session (src/live_repl.ab, where live mode runs): a variable keeps its value across lines, any value
# prints, a line that panics leaves the session and its state as they were, and a redefinition the running code
# cannot take is refused with the old one kept.
if ((live)); then
    printf 'var total = 0\ntotal += 5\ntotal\n"a{" + "c"\n1.5 * 3.0\n[1, 2, 3]\n:quit\n' | session state 300 &
    state=$!
    printf 'val xs = [1, 2]\nxs[5]\nxs.size\n:quit\n' | session panic 300 &
    panicking=$!
    printf 'fun f(): int = 1\nval g = f\nfun f(): string = "x"\nf()\n:quit\n' | session refused 300 &
    refused=$!
    # :type names an expression's type without running it (the println does not print).
    printf 'val xs = [1, 2]\n:type xs\n:type 1.5 * 2.0\n:type println("ran")\n:type\n:type nope\n:quit\n' | session types 300 &
    types=$!
    # Classes: one added applies (and a function taking it), a change of its fields is refused with the instance made
    # before still working, and another class is added after.
    printf 'class P(val a: int)\nP(4).a\nfun twice(p: P): int = p.a * 2\ntwice(P(5))\nval kept = P(7)\nclass P(val a: int, val b: int = 0)\nkept.a\nclass Q(val name: string)\nQ("q").name\n:quit\n' |
        session classes 300 &
    classes=$!
    # :load: a file's declarations (a comment before them left out, its main as loadedMain, which does not run until
    # called), and a file that does not compile leaves the session as it was.
    mkdir -p "$base.load"
    printf '// a library\nimport "abla/io"\nclass Point(val x: int, val y: int)\nfun norm1(p: Point): int =\n    p.x + p.y\nfun main: int {\n    println("main ran")\n    return 0\n}\n' > "$base.load/lib.ab"
    printf 'fun norm1(p: Point): int = missing\n' > "$base.load/broken.ab"
    printf ':load %s\nnorm1(Point(2, 3))\nloadedMain()\n:load %s\nnorm1(Point(2, 3))\n:load %s\n:load\n:quit\n' \
        "$base.load/lib.ab" "$base.load/broken.ab" "$base.load/none.ab" | session load 300 &
    loading=$!
fi
wait "$recovery"
wait "$definitions"
wait "$multiline"
wait "$commands"
wait "$diagnostics"
wait "$generations"
if ((live)); then
    wait "$state"
    wait "$panicking"
    wait "$refused"
    [[ $(< "$base.state.out") == $'abla> defined\nabla> 5\nabla> 5\nabla> a{c\nabla> 4.5\nabla> <array of size 3>\nabla> ' ]] ||
        { echo 'repl (state): a variable did not keep its value, or a value did not print' >&2; cat "$base.state.out" "$base.state.err" >&2; exit 1; }
    [[ $(< "$base.panic.out") == $'abla> defined\nabla> abla> 2\nabla> ' ]] && grep -q 'E_LIVE_PANIC' "$base.panic.err" ||
        { echo 'repl (panic): a line that panics did not leave the session and its state as they were' >&2; cat "$base.panic.out" "$base.panic.err" >&2; exit 1; }
    [[ $(< "$base.refused.out") == $'abla> defined\nabla> defined\nabla> abla> 1\nabla> ' ]] && grep -q 'E_LIVE_SIGNATURE' "$base.refused.err" ||
        { echo 'repl (refused): a refused redefinition did not keep the old one' >&2; cat "$base.refused.out" "$base.refused.err" >&2; exit 1; }
    wait "$types"
    [[ $(< "$base.types.out") == $'abla> defined\nabla> array<int>\nabla> float\nabla> void\nabla> abla> abla> ' ]] &&
        grep -q '^:type needs an expression' "$base.types.err" && grep -q 'identifier:nope' "$base.types.err" &&
        grep -q '^  --> entry:1:1$' "$base.types.err" && ! grep -q 'generic.cannot-infer' "$base.types.err" ||
        { echo 'repl (types): :type did not name a type, or ran the expression' >&2; cat "$base.types.out" "$base.types.err" >&2; exit 1; }
    wait "$classes"
    [[ $(< "$base.classes.out") == $'abla> defined\nabla> 4\nabla> defined\nabla> 10\nabla> defined\nabla> abla> 7\nabla> defined\nabla> q\nabla> ' ]] &&
        grep -q 'E_LIVE_LAYOUT: class P changed' "$base.classes.err" ||
        { echo 'repl (classes): a class could not be added, or a changed one was not refused' >&2; cat "$base.classes.out" "$base.classes.err" >&2; exit 1; }
    wait "$loading"
    [[ $(< "$base.load.out") == "abla> loaded 4 declarations from $base.load/lib.ab (its main is loadedMain())"$'\nabla> 5\nabla> main ran\n0\nabla> abla> 5\nabla> abla> abla> ' ]] &&
        grep -q 'identifier:missing' "$base.load.err" && grep -q "^:load: no such file: $base.load/none.ab\$" "$base.load.err" &&
        grep -q '^:load needs a file' "$base.load.err" ||
        { echo 'repl (load): a file was not loaded as declarations, or a broken one changed the session' >&2; cat "$base.load.out" "$base.load.err" >&2; exit 1; }
fi

[[ $(< "$base.recovery.out") == $'abla> abla> 41\nabla> 42\nabla> ' ]] || exit 1
grep -q 'identifier:missingName' "$base.recovery.err"
[[ $(< "$base.definitions.out") == $'abla> defined\nabla> 42\nabla> defined\nabla> 42\nabla> reset\nabla> abla> ' ]] || exit 1
grep -q 'identifier:base' "$base.definitions.err"
[[ $(< "$base.multiline.out") == $'abla> ....> ....> ....> defined\nabla> 42\nabla> ....> 3\nabla> ....> abla> 42\nabla> ' ]] ||
    { echo 'repl (multiline): an entry over several lines was not read as one' >&2; cat "$base.multiline.out" "$base.multiline.err" >&2; exit 1; }
diagnostics_err=$(< "$base.diagnostics.err")
[[ $diagnostics_err == *$'identifier:missing\n  --> entry:2:12\n'* && $diagnostics_err == *$'identifier:nope\n  --> entry:1:5\n'* &&
    $(grep -c '^  --> entry:1:5$' <<< "$diagnostics_err") -ge 2 ]] &&
    ! grep -qE 'abla-repl-source|^source\[|LLVM compilation failed|@[0-9]+$' <<< "$diagnostics_err" ||
    { echo 'repl (diagnostics): a diagnostic did not name its place in the entry, or showed the session source file' >&2; cat "$base.diagnostics.out" "$base.diagnostics.err" >&2; exit 1; }
commands_out=$(< "$base.commands.out")
[[ $commands_out == 'abla> Commands:'* && $commands_out == *$'\n  :reset '* && $commands_out == *$'\nabla> abla> 42\nabla> ' ]] &&
    [[ $(< "$base.commands.err") == 'unknown command :nope (:help lists them)' ]] ||
    { echo 'repl (commands): :help, an unknown command or a spaced :quit was not handled as a command' >&2; cat "$base.commands.out" "$base.commands.err" >&2; exit 1; }
[[ $(grep -o '42' "$base.generations.out" | wc -l) -eq 32 ]] || exit 1

# The line editor (src/repl_editor.ab), on a terminal: util-linux's script gives the REPL one, and the keys go in
# through a FIFO, each batch only once the REPL has drawn its next prompt (the editor is on only while it reads).
# Left arrow then an insert (24), up twice to the first line (42 again), Ctrl-C drops "999", Backspace (7), Ctrl-D
# ends. Where script is not util-linux's (macOS), the rest of this file is the check.
editor=skipped
if script --version 2>/dev/null | grep util-linux >/dev/null; then
    rm -f "$base.editor.in" "$base.editor.out"
    mkfifo "$base.editor.in"
    # The compiler as given: build/ablac, the launcher, keeps a REPL on a terminal in the terminal's foreground
    # process group (run-limited.sh's timeout --foreground), where the editor is on; timeout bounds script from
    # outside. A bare compiler needs the standard library named.
    TERM=xterm ABLA_SYSROOT=${ABLA_SYSROOT:-$project_root} timeout 300 \
        script -qfec "stty cols 20 rows 24; exec '$compiler' repl" "$base.editor.out" < "$base.editor.in" > /dev/null 2>&1 &
    editor_pid=$!
    exec 3> "$base.editor.in"
    # A fresh prompt; a redraw prints it again after clearing its row (ESC [K).
    prompts() { echo $(($(grep -o 'abla> ' "$base.editor.out" 2>/dev/null | wc -l) - $(grep -o $'\x1b\\[Kabla> ' "$base.editor.out" 2>/dev/null | wc -l))); }
    keys() { # prompts-to-wait-for keys
        local waited=0
        until [[ $(prompts) -ge $1 ]]; do
            sleep 0.2
            waited=$((waited + 1))
            ((waited < 1500)) || { echo 'repl (editor): no prompt came' >&2; cat -v "$base.editor.out" >&2; exit 1; }
        done
        printf "$2" >&3
    }
    keys 1 '20 + 22\r'
    keys 2 '4\033[D2\r'
    keys 3 '\033[A\033[A\r'
    keys 4 '999\003'
    keys 5 '1\1777\r'
    keys 6 '1 + 2 + 3 + 4 + 5 + 6 + 7\001100 + \r'
    keys 7 '\004'
    exec 3>&-
    wait "$editor_pid" || { echo 'repl (editor): the session did not end on Ctrl-D' >&2; cat -v "$base.editor.out" >&2; exit 1; }
    # Each redraw starts with a carriage return: as line breaks, the values are lines of their own.
    values=$(sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$base.editor.out" | tr '\r' '\n' | grep -vx '' | grep -vxF '^C' | grep -v '^abla> \|^Script ')
    [[ $values == $'42\n24\n42\n7\n128' ]] && grep -q '\^C' "$base.editor.out" && grep -q $'\x1b\[1A' "$base.editor.out" ||
        { echo "repl (editor): the keys did not edit the lines (values: $values)" >&2; cat -v "$base.editor.out" >&2; exit 1; }
    editor=checked
fi

printf '%s\n' "persistent REPL: retained definitions + recovery + reclaimed JIT generations + entries over several lines + commands + diagnostics placed in the entry + line editor ($editor); live: state across lines, a contained panic, a refused redefinition, :type, classes added (a changed one refused), :load"
