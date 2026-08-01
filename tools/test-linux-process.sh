#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/linux-process-test"
program="$directory/program"
mkdir -p "$directory"
"$compiler" build "$project_root/tests/cases/modules/linux-process.ab" \
    -o "$program"
if nm --defined-only "$program" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_platform_'; then
    echo 'raw Linux process linked a project C platform symbol' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=15 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]
printf '%s\n' 'raw Linux process: PATH + fork/exec + wait + capture + graceful stop'
