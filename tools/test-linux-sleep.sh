#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tools/lib/project-c-platform-symbols.sh
. "$project_root/tools/lib/project-c-platform-symbols.sh"
compiler=$1
output_directory="$project_root/build/linux-sleep-test"
program="$output_directory/program"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/linux-sleep.ab" \
    -o "$program"
if has_project_c_platform_symbol "$program"; then
    echo 'raw Linux sleep linked a project C platform symbol' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
printf '%s\n' 'raw Linux sleep: nanosleep with EINTR continuation'
