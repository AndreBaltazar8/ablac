#!/usr/bin/env bash
# Check scheduler admission at the first wait, with a mocked CPU count.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
work=$(mktemp -d "${TMPDIR:-/tmp}/suite-load.XXXXXX")
trap 'rm -rf -- "$work"' EXIT

mkdir "$work/bin"
cat >"$work/bin/sleep" <<'SH'
#!/usr/bin/env bash
# The scheduler has admitted the whole first wave before its first wait.
# Read its start calls even if the commands have already completed.
if [[ ! -f $wave_dir/first-wave ]]; then
    awk '$1 == "+" && $2 == "start" { n++ } END { print n+0 }' "$wave_dir/trace" > "$wave_dir/first-wave"
fi
exec "$real_sleep" "$@"
SH
chmod +x "$work/bin/sleep"
real_sleep=$(command -v sleep)

check_wave() {
    local cpus=$1 jobs=$2 script=$3 expected=$4
    local dir="$work/$cpus-$jobs-$script"
    mkdir "$dir"
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$cpus" > "$work/bin/nproc"
    chmod +x "$work/bin/nproc"
    printf ': tools/%s.sh\n:\n:\n:\n' "$script" > "$dir/commands"
    PATH="$work/bin:$PATH" JOBS=$jobs RUN_TESTS_MIN_FREE=0 RUN_TESTS_LIST= RUN_TESTS_SHARD= \
        RUN_TESTS_FILTER= RUN_TESTS_EXCLUDE= RUN_TESTS_OUTPUT="$dir/results" \
        RUN_TESTS_COMMANDS="$dir/commands" wave_dir="$dir" real_sleep="$real_sleep" \
        PS4='+ ' bash -x tools/run-tests.sh "$compiler" > "$dir/log" 2> "$dir/trace" || {
        cat "$dir/log" >&2
        exit 1
    }
    local actual
    actual=$(cat "$dir/first-wave")
    [[ $actual == "$expected" ]] || {
        echo "suite load: $script on $cpus CPUs with $jobs jobs admitted $actual commands, expected $expected" >&2
        exit 1
    }
    echo "suite load: $script on $cpus CPUs with $jobs jobs admitted $actual commands"
}
check_wave 2 4 test-playground-build 2
check_wave 2 4 test-analysis-gc-stress 3
check_wave 4 4 test-playground-build 4
check_wave 1 2 test-playground-build 1
