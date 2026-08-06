#!/usr/bin/env bash
set -euo pipefail

memory_mb=${ABLA_MAX_MEMORY_MB:-2048}
wall_seconds=${ABLA_MAX_SECONDS:-600}
cpu_seconds=${ABLA_MAX_CPU_SECONDS:-$wall_seconds}
kill_grace_seconds=${ABLA_KILL_GRACE_SECONDS:-5}

usage() {
    printf '%s\n' \
        'usage: run-limited.sh COMMAND [ARGUMENT ...]' \
        'environment: ABLA_MAX_MEMORY_MB, ABLA_MAX_SECONDS,' \
        '             ABLA_MAX_CPU_SECONDS, ABLA_KILL_GRACE_SECONDS' >&2
    exit 2
}

require_positive_integer() {
    local name=$1
    local value=$2
    if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
        printf '[abla-limit] %s must be a positive integer, got %q\n' \
            "$name" "$value" >&2
        exit 2
    fi
}

(( $# > 0 )) || usage
require_positive_integer ABLA_MAX_MEMORY_MB "$memory_mb"
require_positive_integer ABLA_MAX_SECONDS "$wall_seconds"
require_positive_integer ABLA_MAX_CPU_SECONDS "$cpu_seconds"
require_positive_integer ABLA_KILL_GRACE_SECONDS "$kill_grace_seconds"

if (( memory_mb > 8796093022207 )); then
    printf '[abla-limit] ABLA_MAX_MEMORY_MB is too large: %s\n' "$memory_mb" >&2
    exit 2
fi
memory_bytes=$((memory_mb * 1024 * 1024))

if [[ $(uname -s) == Darwin ]]; then
    ulimit -S -c 0
    ulimit -S -t "$cpu_seconds"
    set +e
    /usr/bin/perl -e \
        'my $seconds = shift;
         my $pid = fork();
         exit 127 unless defined $pid;
         if ($pid == 0) {
             setpgrp(0, 0);
             exec @ARGV;
             exit 127;
         }
         $SIG{ALRM} = sub {
             kill "TERM", -$pid;
             select undef, undef, undef, 0.1;
             kill "KILL", -$pid;
             waitpid($pid, 0);
             exit 124;
         };
         alarm $seconds;
         waitpid($pid, 0);
         alarm 0;
         my $status = $?;
         exit 128 + ($status & 127) if $status & 127;
         exit $status >> 8;' \
        "$wall_seconds" "$@"
    status=$?
    set -e
else
    set +e
    timeout \
        --signal=TERM \
        --kill-after="${kill_grace_seconds}s" \
        "${wall_seconds}s" \
        prlimit \
            --as="${memory_bytes}:${memory_bytes}" \
            --cpu="${cpu_seconds}:${cpu_seconds}" \
            --core=0:0 \
            -- \
            "$@"
    status=$?
    set -e
fi

case $status in
    142)
        printf '[abla-limit] stopped after %s wall-clock second(s)\n' \
            "$wall_seconds" >&2
        ;;
    124)
        printf '[abla-limit] stopped after %s wall-clock second(s)\n' \
            "$wall_seconds" >&2
        ;;
    137)
        printf '[abla-limit] process was killed; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    134)
        printf '[abla-limit] process aborted; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    139)
        printf '[abla-limit] process crashed; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    152)
        printf '[abla-limit] stopped after %s CPU second(s)\n' \
            "$cpu_seconds" >&2
        ;;
esac

exit "$status"
