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
directory="$project_root/build/linux-process-test"
program="$directory/program"
mkdir -p "$directory"
"$compiler" build "$project_root/tests/cases/modules/linux-process.ab" \
    -o "$program"
if has_project_c_platform_symbol "$program"; then
    echo 'raw Linux process linked a project C platform symbol' >&2
    exit 1
fi
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=15 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
printf '%s\n' 'raw Linux process: PATH + fork/exec + wait + capture + graceful stop'

"$compiler" build "$project_root/tests/cases/modules/tool-support.ab" \
    -o "$directory/tool-support"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=15 \
    "$project_root/tools/run-limited.sh" "$directory/tool-support"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
printf '%s\n' 'tools: command environment, directory, redirects; exclusive files, links, locks'

for fixture in signal-watch signal-watch-failure; do
    "$compiler" build "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$directory/$fixture"
    set +e
    if [[ $fixture == signal-watch-failure ]]; then
        (ulimit -n 32; ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=15 \
            "$project_root/tools/run-limited.sh" "$directory/$fixture")
    else
        ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=15 \
            "$project_root/tools/run-limited.sh" "$directory/$fixture"
    fi
    status=$?
    set -e
    [[ $status -eq 42 ]] || exit 1
done
printf '%s\n' 'signal watches: restore preblocked masks and overlapping watches'
