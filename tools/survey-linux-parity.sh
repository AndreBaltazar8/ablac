#!/usr/bin/env bash
# The module programs (tests/cases/modules/*.ab) built by tools/test-libc-free-programs.sh, run on x86-64 and under QEMU for a Linux cross
# target; one line per program says whether the guest printed and exited what the native program did. This is the survey behind
# tools/linux-parity-blockers.tsv and tests/cases/linux/modules.txt (#1208); tools/test-linux-parity.sh is the CI check.
# Usage: tools/survey-linux-parity.sh <a64|rv64> <image-dir> <result-dir> [program-list]
#   image-dir: build/libc-free-programs of a run with LIBC_FREE_TARGETS="x86 <target>" (images NAME.x86 and NAME.<target>)
# Result lines (<result-dir>/results.tsv): name  verdict  native-status  guest-status  detail
#   match | status (exit codes differ) | output (stdout differs) | timeout (guest only) | flaky (the native program differs from itself)
#   | noimage (no x86 or guest image)
set -euo pipefail
export LC_ALL=C TZ=UTC
target=${1:-}
images=${2:-}
result=${3:-}
list=${4:-}
case $target in
    a64) emulator=qemu-aarch64 ;;
    rv64) emulator=qemu-riscv64 ;;
    *) echo 'usage: tools/survey-linux-parity.sh <a64|rv64> <image-dir> <result-dir> [program-list]' >&2; exit 2 ;;
esac
[[ -d $images && -n $result ]] || { echo 'survey-linux-parity: need an image directory and a result directory' >&2; exit 2; }
command -v "$emulator" > /dev/null || { echo "survey-linux-parity: $emulator is required" >&2; exit 2; }
images=$(cd -- "$images" && pwd)
mkdir -p "$result"
result=$(cd -- "$result" && pwd)
rm -rf -- "$result/runs"
mkdir -p "$result/runs"
if [[ -n $list ]]; then
    sed -e '/^#/d' -e 's/[[:space:]].*$//' -e '/^$/d' "$list" > "$result/names.txt"
else
    { for image in "$images"/*."$target"; do [[ -e $image ]] && basename -- "${image%."$target"}"; done; } | sort > "$result/names.txt"
fi
# json-ascii-spans takes 21 s natively and 39 s under qemu-aarch64 on an idle CPU: the limit leaves room for a loaded runner.
limit=${SURVEY_TIMEOUT:-180}

run_one() {
    local name=$1 dir native guest status_a status_b status_g
    dir="$result/runs/$name"
    mkdir -p "$dir/a/w" "$dir/b/w" "$dir/g/w"
    native="$images/$name.x86"
    guest="$images/$name.$target"
    if [[ ! -x $native || ! -x $guest ]]; then
        printf '%s\tnoimage\t-\t-\t\n' "$name" > "$dir/line"
        return 0
    fi
    status_a=0
    (cd "$dir/a/w" && timeout -k 2 "$limit" "$native" < /dev/null) > "$dir/a.out" 2> "$dir/a.err" || status_a=$?
    status_b=0
    (cd "$dir/b/w" && timeout -k 2 "$limit" "$native" < /dev/null) > "$dir/b.out" 2> "$dir/b.err" || status_b=$?
    if [[ $status_a != "$status_b" ]] || ! cmp -s "$dir/a.out" "$dir/b.out"; then
        printf '%s\tflaky\t%s/%s\t-\t\n' "$name" "$status_a" "$status_b" > "$dir/line"
        return 0
    fi
    status_g=0
    (cd "$dir/g/w" && timeout -k 2 "$limit" "$emulator" "$guest" < /dev/null) > "$dir/g.out" 2> "$dir/g.err" || status_g=$?
    if [[ $status_g == 124 && $status_a != 124 ]]; then
        printf '%s\ttimeout\t%s\t%s\t\n' "$name" "$status_a" "$status_g" > "$dir/line"
    elif [[ $status_g != "$status_a" ]]; then
        printf '%s\tstatus\t%s\t%s\t%s\n' "$name" "$status_a" "$status_g" "$(head -c 160 "$dir/g.err" | tr '\n\t' '  ')" > "$dir/line"
    elif ! cmp -s "$dir/a.out" "$dir/g.out"; then
        printf '%s\toutput\t%s\t%s\t%s\n' "$name" "$status_a" "$status_g" "$(diff "$dir/a.out" "$dir/g.out" | head -c 160 | tr '\n\t' '  ')" > "$dir/line"
    else
        printf '%s\tmatch\t%s\t%s\t\n' "$name" "$status_a" "$status_g" > "$dir/line"
    fi
}
export -f run_one
export images result target emulator limit
workers=${ABLA_TEST_JOBS:-4}
xargs -P "$workers" -I{} bash -c 'run_one {}' < "$result/names.txt"
{ for name in $(cat "$result/names.txt"); do cat "$result/runs/$name/line"; done; } > "$result/results.tsv"
printf 'survey-linux-parity (%s): %s programs' "$target" "$(wc -l < "$result/results.tsv")"
for verdict in match status output timeout flaky noimage; do
    printf ', %s %s' "$(awk -F'\t' -v v="$verdict" '$2 == v' "$result/results.tsv" | wc -l)" "$verdict"
done
printf '\n'
