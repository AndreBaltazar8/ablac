#!/usr/bin/env bash
# Run a Linux AArch64 executable over SSH. Set ABLA_AARCH64_HOSTS to the
# space-separated SSH destinations for the board pool (e.g. user@test-pi).
# ABLA_AARCH64_REQUIRE_REMOTE=1 turns an unavailable board pool into a failure.
# ABLA_AARCH64_RUN_LOG records the selected backend without changing output.
# --input copies one cwd-relative file, --env forwards one variable, and
# --collect copies the resulting cwd to a local directory after execution.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/aarch64-test-runner.sh"

fail() { printf 'aarch64 remote runner: %s\n' "$*" >&2; exit 1; }

options=()
inputs=()
environment=()
duration=300
collect=
while [[ ${1:-} == --?* ]]; do
    case $1 in
        --timeout)
            [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || fail '--timeout requires positive seconds'
            duration=$2 ;;
        --cpu) [[ -n ${2:-} ]] || fail '--cpu requires a model' ;;
        --input)
            [[ -n ${2:-} && $2 != /* && /$2/ != */../* && -f $2 && ! -L $2 ]] ||
                fail '--input requires a regular file relative to the current directory'
            inputs+=("$2") ;;
        --env)
            [[ ${2:-} =~ ^[a-zA-Z_][a-zA-Z_0-9]*= ]] || fail '--env requires NAME=VALUE'
            environment+=("$2") ;;
        --collect)
            [[ -d ${2:-} ]] || fail '--collect requires an existing local directory'
            collect=$2 ;;
        *) fail "unknown option $1" ;;
    esac
    options+=("$1" "$2")
    shift 2
done
[[ ${1:-} == -- && $# -ge 2 ]] || fail 'usage: aarch64-remote-run.sh [--timeout seconds] [--cpu qemu-model] [--input file] [--env NAME=VALUE] [--collect directory] -- executable [args...]'
shift
[[ -f $1 && -x $1 ]] || fail "not an executable file: $1"

tmp=$(mktemp -d)
ssh_pid=
input_pid=
error_pid=
cleanup() {
    if [[ -n $input_pid ]]; then kill "$input_pid" 2>/dev/null || :; wait "$input_pid" 2>/dev/null || :; fi
    if [[ -n $ssh_pid ]]; then kill "$ssh_pid" 2>/dev/null || :; wait "$ssh_pid" 2>/dev/null || :; fi
    if [[ -n $error_pid ]]; then wait "$error_pid" 2>/dev/null || :; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$tmp/payload/cwd"
cp -- "$1" "$tmp/payload/program"
for file in "${inputs[@]}"; do
    mkdir -p -- "$tmp/payload/cwd/$(dirname -- "$file")"
    cp -- "$file" "$tmp/payload/cwd/$file"
done
tar -cf "$tmp/payload.tar" -C "$tmp/payload" program cwd
size=$(stat -c %s "$tmp/payload.tar")
mkfifo "$tmp/to-pi" "$tmp/from-pi" "$tmp/errors"

# The first stdout line is a reservation result. Only send the archive and
# then the caller's stdin after a Pi has locked its runner directory.
remote_script=$(cat <<'REMOTE'
set -euo pipefail
[[ $(uname -s)/$(uname -m) == Linux/aarch64 ]]
umask 077
base=$HOME/abla-runner
mkdir -p -- "$base"
exec 9< "$base"
if ! flock -n 9; then
    printf 'busy\n'
    exit 0
fi
work=$(mktemp -d "$base/run.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
cd "$work"
ulimit -c 0
printf 'ready\n'
head -c "$1" > archive.tar
[[ $(stat -c %s archive.tar) == "$1" ]]
tar -xf archive.tar
rm archive.tar
cd cwd
duration=$2
environment_count=$3
collect=$4
shift 4
environment=("${@:1:environment_count}")
shift "$environment_count"
# Retain the program's stderr and suppress the shell diagnostic about its
# signal. timeout keeps even a run with a dropped SSH session bounded.
status=0
run_program() {
    { timeout --kill-after=5 "$duration" env "${environment[@]}" ../program "$@" 2>&3 9<&- || status=$?; } 3>&2 2>/dev/null
}
if ((collect)); then
    # With file collection enabled, frame stdout and the result archive after
    # the program exits. The exec status is still the SSH session's status.
    run_program "$@" > "$work/stdout"
    tar -cf "$work/results.tar" .
    printf '%s %s\n' "$(stat -c %s "$work/stdout")" "$(stat -c %s "$work/results.tar")"
    cat "$work/stdout" "$work/results.tar"
else
    run_program "$@"
fi
exit "$status"
REMOTE
)
collect_flag=0
if [[ -n $collect ]]; then collect_flag=1; fi
printf -v remote 'bash -c %q _ %q %q %q %q' "$remote_script" "$size" "$duration" "${#environment[@]}" "$collect_flag"
for arg in "${environment[@]}" "${@:2}"; do
    printf -v remote '%s %q' "$remote" "$arg"
done

record_backend() {
    if [[ -n ${ABLA_AARCH64_RUN_LOG:-} ]]; then
        printf '%s\t%s\n' "$1" "$2" >> "$ABLA_AARCH64_RUN_LOG"
    fi
}

# Rotate the first choice so independent invocations spread across idle boards.
read -r -a hosts <<< "${ABLA_AARCH64_HOSTS:-}"
if (( ${#hosts[@]} == 0 )); then
    [[ ${ABLA_AARCH64_REQUIRE_REMOTE:-0} != 1 ]] || fail 'ABLA_AARCH64_HOSTS is empty'
    record_backend qemu "$1"
    aarch64_qemu "${options[@]}" -- "$@"
    exit $?
fi
for host in "${hosts[@]}"; do
    [[ $host =~ ^[[:alnum:]_][[:alnum:]_@.-]*$ ]] || fail "invalid SSH destination: $host"
done
first=$((RANDOM % ${#hosts[@]}))
deadline=$((SECONDS + 300))
exec {caller_input}<&0
while :; do
    busy=0
    for offset in "${!hosts[@]}"; do
        host=${hosts[(first+offset)%${#hosts[@]}]}
        ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=3 \
            -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o LogLevel=ERROR \
            "$host" "$remote" < "$tmp/to-pi" > "$tmp/from-pi" 2> "$tmp/errors" &
        ssh_pid=$!
        exec {remote_in}> "$tmp/to-pi"
        exec {remote_out}< "$tmp/from-pi"
        exec {remote_err}< "$tmp/errors"
        state=
        if IFS= read -r -t 12 state <&"$remote_out" && [[ $state == ready ]]; then
            record_backend "$host" "$1"
            cat <&"$remote_err" >&2 {remote_in}>&- &
            error_pid=$!
            exec {remote_err}<&-
            cat "$tmp/payload.tar" >&"$remote_in"
            cat <&"$caller_input" >&"$remote_in" &
            input_pid=$!
            exec {remote_in}>&-
            if [[ -n $collect ]]; then
                IFS=' ' read -r stdout_size archive_size <&"$remote_out" || fail 'missing result archive header'
                [[ $stdout_size =~ ^[0-9]+$ && $archive_size =~ ^[1-9][0-9]*$ ]] || fail 'invalid result archive header'
                head -c "$stdout_size" <&"$remote_out"
                head -c "$archive_size" <&"$remote_out" > "$tmp/results.tar"
                [[ $(stat -c %s "$tmp/results.tar") == "$archive_size" ]] || fail 'incomplete result archive'
                tar --no-overwrite-dir -xf "$tmp/results.tar" -C "$collect"
            else
                cat <&"$remote_out"
            fi
            status=0
            wait "$ssh_pid" || status=$?
            ssh_pid=
            wait "$error_pid"
            error_pid=
            exit "$status"
        fi
        exec {remote_in}>&-
        exec {remote_out}<&-
        exec {remote_err}<&-
        kill "$ssh_pid" 2>/dev/null || :
        wait "$ssh_pid" 2>/dev/null || :
        ssh_pid=
        if [[ $state == busy ]]; then busy=1; fi
    done
    ((busy)) || break
    ((SECONDS < deadline)) || fail 'all reachable boards remained busy'
    sleep 1
done
[[ ${ABLA_AARCH64_REQUIRE_REMOTE:-0} != 1 ]] || fail 'no board answered'
record_backend qemu "$1"
aarch64_qemu "${options[@]}" -- "$@"
