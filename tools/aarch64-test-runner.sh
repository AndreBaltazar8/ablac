#!/usr/bin/env bash
# Source this from tests that run an AArch64 Linux executable, or execute it
# when the runner is passed to a process supervisor.
# ABLA_AARCH64_RUN names an optional runner. It receives the qemu fallback
# options followed by --, the executable and its arguments.
abla_aarch64_hook=${ABLA_AARCH64_RUN:-}
if [[ $abla_aarch64_hook == */* && $abla_aarch64_hook != /* ]]; then
    abla_aarch64_hook=$PWD/$abla_aarch64_hook
fi

aarch64_runner_available() {
    [[ -n $abla_aarch64_hook ]] || command -v qemu-aarch64 > /dev/null
}

aarch64_run() {
    if [[ -n $abla_aarch64_hook ]]; then
        "$abla_aarch64_hook" "$@"
    else
        aarch64_qemu "$@"
    fi
}

aarch64_qemu() {
    local duration=
    local -a options=() environment=()
    while [[ $1 != -- ]]; do
        case $1 in
            --timeout) duration=$2 ;;
            --cpu) options+=(-cpu "$2") ;;
            --input) ;; # The relative input already exists in this cwd.
            --collect) ;; # The program already writes here.
            --env) environment+=("$2") ;;
            *) printf 'aarch64 runner: unknown option %s\n' "$1" >&2; return 2 ;;
        esac
        shift 2
    done
    shift
    if [[ -n $duration ]]; then
        env "${environment[@]}" timeout "$duration" qemu-aarch64 "${options[@]}" "$@"
    else
        env "${environment[@]}" qemu-aarch64 "${options[@]}" "$@"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
    aarch64_run "$@"
fi
