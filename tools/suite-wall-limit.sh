#!/usr/bin/env bash
# Shared by compiler-heavy suite tests. Source this file before calling the function.

extend_suite_wall_limit() {
    local test_name=$1 wall_limit=$2 cpu_limit=$3
    local suite_jobs=${ABLA_SUITE_JOBS:-0} cpus
    if [[ -z ${ABLA_MAX_SECONDS:-} && $suite_jobs =~ ^[1-9][0-9]*$ ]]; then
        cpus=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo "$suite_jobs")
        if [[ $cpus =~ ^[1-9][0-9]*$ ]] && (( suite_jobs > cpus )); then
            export ABLA_MAX_SECONDS=$wall_limit
            export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$cpu_limit}
            printf '%s: %s suite jobs on %s CPUs, wall limit %ss, CPU limit %ss per process\n' \
                "$test_name" "$suite_jobs" "$cpus" "$ABLA_MAX_SECONDS" "$ABLA_MAX_CPU_SECONDS"
        fi
    fi
}
