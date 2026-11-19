#!/usr/bin/env bash
# A readiness wait that gives up too soon is a flake that only shows under load: `for _ in $(seq 100); do ...; sleep 0.1; done`
# waits 10 s for a server to listen or a marker file to appear, and on a gate running many tests at once a server needs longer
# than that (test-http2-h2o, test-tls-handles and others failed this way; a wait that finds its marker leaves at once, so a
# long cap costs nothing). This guard fails on a `for`/`while` loop over `seq` whose body sleeps and whose cap (iterations times
# the sleep) is under 30 s, in every tracked shell script. Write `seq 600` for a sleep of 0.1 (60 s), or count by the clock
# (`while ((SECONDS < deadline))`, which the guard does not check). A loop that is short on purpose (a timing test, a retry that
# has a fallback) says why with `# wait-ok: <why>` on its line or the line above or in its body. A loop that holds another loop
# or reads the clock (SECONDS, date) is not checked: its cap is set by that.
set -euo pipefail
export LC_ALL=C
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

lint() { # a script on stdin: prints "line: text" for each loop that gives up too soon
    awk '
    { L[NR] = $0 }
    END {
        for (i = 1; i <= NR; i++) {
            if (L[i] !~ /^[ \t]*(for|while)[ \t].*seq[ \t]+[0-9]+([ \t]+[0-9]+)?[ \t]*\)/) continue
            if (L[i] ~ /^[ \t]*#/) continue
            match(L[i], /seq[ \t]+[0-9]+([ \t]+[0-9]+)?/)
            spec = substr(L[i], RSTART + 3, RLENGTH - 3); gsub(/^[ \t]+/, "", spec)
            m = split(spec, nums, /[ \t]+/); count = nums[m] + 0
            body = L[i]; end = i
            if (L[i] !~ /;[ \t]*done/ && L[i] !~ /done[ \t]*$/) {
                for (j = i + 1; j <= NR && j <= i + 10; j++) { body = body " " L[j]; end = j; if (L[j] ~ /(^|[ \t;])done([ \t;)]|$)/) break }
            }
            if (!match(body, /sleep[ \t]+[0-9]*\.?[0-9]+/)) continue
            seconds = substr(body, RSTART, RLENGTH); sub(/sleep[ \t]+/, "", seconds); seconds += 0
            if (body ~ /wait-ok/ || (i > 1 && L[i - 1] ~ /wait-ok/)) continue
            rest = substr(body, length(L[i]) + 1)
            if (rest ~ /(^|[ \t;({])(for|while|until)[ \t]/ || body ~ /SECONDS|\$\(date|date \+/) continue
            if (count * seconds < 30) printf "%d: %s\n", i, L[i]
        }
    }'
}

if [[ ${1:-} == --self-test ]]; then
    good=$(printf '%s\n' \
        'for _ in $(seq 600); do [[ -s $f ]] && break; sleep 0.1; done' \
        'for _ in $(seq 1 3000); do [[ -e $f ]] && break; sleep 0.02; done' \
        'for _ in $(seq 100); do [[ -s $f ]] && break; sleep 0.1; done # wait-ok: the server answers at once' \
        '# wait-ok: a fallback follows' \
        'for _ in $(seq 100); do x; sleep 0.1; done' \
        'for _ in $(seq 100); do echo hi; done' \
        'for _ in $(seq 20); do' \
        '    while ((SECONDS < deadline)); do sleep 0.05; done' \
        'done' \
        'for _ in $(seq 50); do date +%s; sleep 0.1; done' | lint)
    [[ -z $good ]] || { echo "wait guard self-test: flagged what it should accept:" >&2; echo "$good" >&2; exit 1; }
    bad=$(printf '%s\n' \
        'for _ in $(seq 100); do [[ -s $f ]] && break; sleep 0.1; done' \
        'for _ in $(seq 1 500); do' \
        '    [[ -e $f ]] && break' \
        '    sleep 0.02' \
        'done' \
        'while read x; do :; done < f' \
        'for _ in $(seq 29); do ss -ltn | grep LISTEN > /dev/null && break; sleep 1; done' | lint)
    [[ $(wc -l <<<"$bad") -eq 3 ]] || { echo "wait guard self-test: expected 3 offenders, got:" >&2; echo "$bad" >&2; exit 1; }
    echo "wait guard self-test: ok"
    exit 0
fi

failed=0
while IFS= read -r file; do
    [[ $file == tools/test-shell-wait-guard.sh ]] && continue
    offenders=$(lint < "$file")
    if [[ -n $offenders ]]; then
        [[ $failed -eq 1 ]] || echo "wait guard: a readiness wait under 30 s gives up before a loaded machine's server is up; use seq 600 with sleep 0.1 (a cap costs nothing when the wait succeeds), the clock, or \`# wait-ok: why\`:" >&2
        sed "s|^|$file:|" <<<"$offenders" >&2
        failed=1
    fi
done < <(git ls-files -- 'tools/*.sh' 'tests/*.sh' ':!:tools/test-shell-wait-guard.sh')
((failed == 0)) || exit 1
"$0" --self-test
echo "wait guard: no readiness wait of a script gives up under 30 s"
