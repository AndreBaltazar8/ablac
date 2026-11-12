#!/usr/bin/env bash
# Offline value/diagnostic corpus. The upstream event stream is the oracle,
# not a parser installed on the test machine. See UPSTREAM.md for provenance.
#
# corpus/NAME.yaml are the sources; expected.txt has one line per case in
# corpus.list order: the probe's canonical one-line output, or `error` for a
# case that must be rejected (exit 1 with an ["error", ...] line). The
# comparison is byte for byte (diff), not a parse of either side.
# Usage: check.sh PROBE OUTPUT-DIRECTORY
set -euo pipefail
# A hung probe must not stall the suite: run each under `timeout 5` where it
# exists (Linux). macOS has no timeout and runs the probes unguarded.
guard=()
if command -v timeout >/dev/null 2>&1; then guard=(timeout 5); fi
probe=$1
output=$2
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$output"
: > "$output/actual.txt"
: > "$output/actual-block.txt"
: > "$output/actual-flow.txt"
: > "$output/expected-styles.txt"
count=0
while IFS= read -r name; do
    source=$here/corpus/$name.yaml
    count=$((count + 1))
    out=$(${guard[@]+"${guard[@]}"} "$probe" "$source"; echo "status=$?")
    status=${out##*status=}; out=${out%status=*}
    [[ $status != 124 ]] || { echo "probe timed out on $source" >&2; exit 1; }
    case $out in
    '["error",'*) [[ $status == 1 ]] && out=error ;;
    esac
    if [[ $out == error ]]; then
        printf 'error\n' >> "$output/actual.txt"
        continue
    fi
    [[ $status == 0 ]] || out="exit $status: $out"
    printf '%s' "$out" >> "$output/actual.txt"
    for style in block flow; do
        out=$(${guard[@]+"${guard[@]}"} "$probe" "$source" "$style"; echo "status=$?")
        status=${out##*status=}; out=${out%status=*}
        [[ $status != 124 ]] || { echo "probe timed out on $source" >&2; exit 1; }
    [[ $status != 124 ]] || { echo "probe timed out on $source" >&2; exit 1; }
        [[ $status == 0 ]] || out="exit $status: $out"
        printf '%s' "$out" >> "$output/actual-$style.txt"
    done
done < "$here/corpus.list"
grep -v '^error$' "$here/expected.txt" > "$output/expected-styles.txt" || true
diff "$here/expected.txt" "$output/actual.txt" > "$output/values.diff" ||
    { head -20 "$output/values.diff" >&2; echo "YAML values differ from expected.txt" >&2; exit 1; }
for style in block flow; do
    diff "$output/expected-styles.txt" "$output/actual-$style.txt" > "$output/$style.diff" ||
        { head -20 "$output/$style.diff" >&2; echo "YAML $style emit differs from expected.txt" >&2; exit 1; }
done
echo "YAML: $count offline parser vectors passed"
