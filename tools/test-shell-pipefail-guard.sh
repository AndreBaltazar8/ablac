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
        if (text ~ /(\|[ \t]*|\\)$/ && text !~ /\|\|[ \t]*$/ && text !~ /^[ \t]*#/ && text !~ /:[ \t]*\|[-+]?$/) {
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

# Second form: a pipeline that ends in an early-exit reader (head, sed with q, awk with an exit before its END, grep -m) while a producer that can write more
# than a pipe buffer (64 KiB: nm, readelf, objdump, strings, find, cat, tar, git log/diff/grep ...) feeds it gets SIGPIPE when the reader
# leaves, and under pipefail the pipeline (and `set -e`) fails. Producers that write a line or a handful (printf, echo, ls of one directory,
# a version banner, sed or grep of a log) are not flagged, so a small `x=$(producer | head -1)` stays fine. Instead of head -N write
# `sed -n '1,Np'` (reads everything), for find `-print -quit`, for grep `-m` on a file; `|| true` after the pipeline or a
# `# pipefail-ok: <why small>` comment on its line says the SIGPIPE is expected or the output small.
lint_early() {
    awk '
    {
        if (pending != "") { text = pending " " $0; line = pendingLine } else { text = $0; line = NR }
        if (text ~ /(\|[ \t]*|\\)$/ && text !~ /\|\|[ \t]*$/ && text !~ /^[ \t]*#/ && text !~ /:[ \t]*\|[-+]?$/) { sub(/\\$/, "", text); pending = text; pendingLine = line; next }
        pending = ""
        if (text ~ /^[ \t]*#/ || text ~ /pipefail-ok/ || text ~ /\|\|[ \t]*(true|:)([ \t;)]|$)/) next
        copy = text
        gsub(/\|\|/, "\001\001", copy)
        n = split(copy, parts, "|")
        if (n < 2) next
        for (i = 2; i <= n; i++) {
            c = parts[i]; gsub(/\001/, "|", c)
            early = 0
            if (c ~ /^[ \t]*[({]?[ \t]*head([ \t]|$|\))/) early = 1
            else if (c ~ /^[ \t]*sed[ \t]/ && c ~ /(^|[ \t;{'"'"'"])[0-9$]*q([ \t;}'"'"'"]|$)/ && c !~ /^[ \t]*sed[ \t]+[^|]*s\/[^|]*q/) early = 1
            else if (c ~ /^[ \t]*awk[ \t]/ && match(c, /exit/)) { pre = substr(c, 1, RSTART - 1); if (pre !~ /END/) early = 1 }
            else if (c ~ /^[ \t]*grep[ \t]+([^|]* )?-[A-Za-z]*m[0-9]*/) early = 1
            if (!early) continue
            for (j = 1; j < i; j++) {
                p = parts[j]; gsub(/\001/, "|", p)
                if (p ~ /(^|[ \t(`;&{"$])(nm|llvm-nm|readelf|llvm-readelf|objdump|llvm-objdump|llvm-readobj|llvm-dwarfdump|llvm-dis|strings|xxd|od|hexdump|find|tar|unzip|zipinfo|cat|zcat|gzcat|strace|ltrace)([ \t]|$)/ ||
                    p ~ /(^|[ \t(`;&{"$])git[ \t]+(-C[ \t]+[^ \t]+[ \t]+)?(log|diff|ls-files|grep|show|ls-tree)([ \t]|$)/) { print line ": " text; next }
            }
        }
    }
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
    for bad in 'nm x | head -1' 'x=$(readelf -d f | head -n 3)' 'find d -name x | head -1' 'llvm-nm f | awk "{ print \$1 }" | head -5' 'strings f | sed -n 1p;q' 'readelf -d f | awk "\$1 == 1 { print; exit }"' 'git diff | grep x | head -40' 'strings f | grep -m1 x' 'nm f | sed 1q'; do
        [[ -n $(printf '%s\n' "$bad" | lint_early) ]] || { printf 'pipefail guard self-test: early-exit missed: %s\n' "$bad" >&2; exit 1; }
    done
    early_good=$(printf '%s\n' \
        'x=$("$compiler" --version | head -1)' \
        'v=$(printf "%s\n" 3.2.0 "$o" | sort -V | head -1)' \
        'x=$(sed -n "s/a/b/p" log | head -1)' \
        'ls d | head -1' \
        'nm f | awk "END { exit !found }"' \
        'nm f | sed "s/q/x/"' \
        'strings f | grep -m1 x || true' \
        'find d | head -1 # pipefail-ok: one match' \
        'nm f > o; head -1 o' \
        '# nm f | head -1' | lint_early)
    [[ -z $early_good ]] || { printf 'pipefail guard self-test: early-exit false positive: %s\n' "$early_good" >&2; exit 1; }
    echo 'pipefail guard self-test ok'
    exit 0
fi

bash "$0" --self-test >/dev/null
found=""
while IFS= read -r file; do
    [[ -f $file ]] || continue
    # the guard's own self-test lines are examples of what it flags
    [[ $file == tools/test-shell-pipefail-guard.sh ]] && continue
    hits=$(lint < "$file")
    if grep -qE 'pipefail|^[ \t]*shell: bash' "$file"; then
        hits+=$(lint_early < "$file")
    fi
    if [[ -n $hits ]]; then
        found+=$(printf '%s\n' "$hits" | sed "s|^|$file:|")$'\n'
    fi
done < <(git ls-files '*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml' | sort)
if [[ -n $found ]]; then
    printf 'pipefail guard: a pipe whose reader leaves early (grep -q, or head/sed q/awk exit/grep -m after a producer of more than a pipe buffer) gives the producer SIGPIPE; use `grep pattern >/dev/null`, `sed -n 1,Np`, `find -print -quit`, or `# pipefail-ok: why`:\n%s' "$found" >&2
    exit 1
fi
echo 'pipefail guard: no producer is piped into an early-exit reader'
