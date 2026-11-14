#!/usr/bin/env bash
# `producer | grep -q pattern` under `set -o pipefail` is a flaky failure: grep -q exits at its first match, the producer
# (nm, readelf, llvm-nm, a test program, printf of a large string) then writes into a closed pipe, gets SIGPIPE, and the
# pipeline's status is the producer's 141, not grep's 0. Linux CI failed test-macho-section that way ("LLVM ERROR: IO failure on
# output stream: Broken pipe"). Write `producer | grep pattern >/dev/null` (grep reads everything), or grep a file
# (`grep -q pattern file`, `grep -q pattern <<<"$text"`). This guard fails on a pipe into grep -q (also -qE, -qx, -Eq, --quiet,
# a `\` or `|` continuation line included) in every tracked shell script and workflow, with no allowlist: it may not grow.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

# The lint itself, on stdin lines of one file: prints "line: text" for each offender.
lint() {
    awk '
    { raw = $0 }
    # a line ending in "|" or a backslash continues into the next one (the offender is reported at its first line)
    {
        if (pending != "") { text = pending " " $0; line = pendingLine } else { text = $0; line = NR }
        if (text ~ /(\|[ \t]*|\\)$/ && text !~ /\|\|[ \t]*$/ && text !~ /^[ \t]*#/) {
            sub(/\\$/, "", text); pending = text; pendingLine = line; next
        }
        pending = ""
        if (text ~ /^[ \t]*#/) next
        # a pipe (not ||) whose next command is grep with a quiet option
        copy = text
        while (match(copy, /(^|[^|])\|[ \t]*(grep|egrep|fgrep|ugrep)[ \t]+/)) {
            rest = substr(copy, RSTART + RLENGTH)
            copy = rest
            if (match(rest, /^(-[A-Za-z]+[ \t]+|--[a-z-]+(=[^ \t]*)?[ \t]+)*/)) {
                options = substr(rest, 1, RLENGTH)
                if (options ~ /(^|[ \t])-[A-Za-z]*q[A-Za-z]*([ \t]|$)/ || options ~ /--(quiet|silent)/) { print line ": " text; break }
            }
        }
    }
    END { if (pending != "") print pendingLine ": " pending }
    '
}

if [[ ${1:-} == --self-test ]]; then
    good=$(printf '%s\n' \
        'nm x | grep foo >/dev/null' \
        'grep -q foo file' \
        'grep -q foo <<<"$text"' \
        'a || grep -q foo file' \
        'x | grep -c foo' \
        '# nm x | grep -q foo' | lint)
    [[ -z $good ]] || { printf 'pipefail guard self-test: false positive: %s\n' "$good" >&2; exit 1; }
    for bad in 'nm x | grep -q foo' 'nm x | grep -qE foo' 'nm x | grep -Eq foo' 'nm x | grep -E -q foo' 'nm x | grep -qx foo' \
        'nm x | grep --quiet foo' 'if a | b | grep -q x; then' 'echo "$t" | grep -qF x || exit 1' 'a || b | grep -q x'; do
        [[ -n $(printf '%s\n' "$bad" | lint) ]] || { printf 'pipefail guard self-test: missed: %s\n' "$bad" >&2; exit 1; }
    done
    [[ -n $(printf '%s\n' 'file x |' '    grep -q foo' | lint) ]] || { echo 'pipefail guard self-test: missed a continuation' >&2; exit 1; }
    [[ -n $(printf '%s\n' 'nm x \' '  | grep -q foo' | lint) ]] || { echo 'pipefail guard self-test: missed a backslash continuation' >&2; exit 1; }
    echo 'pipefail guard self-test ok'
    exit 0
fi

bash "$0" --self-test >/dev/null
found=""
while IFS= read -r file; do
    [[ -f $file ]] || continue
    hits=$(lint < "$file")
    if [[ -n $hits ]]; then
        found+=$(printf '%s\n' "$hits" | sed "s|^|$file:|")$'\n'
    fi
done < <(git ls-files '*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort)
if [[ -n $found ]]; then
    printf 'pipefail guard: a pipe into grep -q (the producer may get SIGPIPE; use `grep pattern >/dev/null`):\n%s' "$found" >&2
    exit 1
fi
echo 'pipefail guard: no producer is piped into grep -q'
