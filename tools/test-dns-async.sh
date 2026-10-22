#!/usr/bin/env bash
# abla/dns's nonblocking resolver against a mock name server in a forked child
# (tests/cases/modules/dns-async.ab: literals, A and AAAA, the resend, stray
# replies, timeouts, cancel, an outside poll loop and HttpAsyncClient on top),
# then the HttpAsyncClient conformance case, which now resolves through it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/dns-async"
mkdir -p "$output_directory"

for name in dns-async http-async; do
    "$compiler" build "$project_root/tests/cases/modules/$name.ab" \
        -o "$output_directory/$name" --no-cache
    set +e
    output=$(ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=30 \
        ABLA_MAX_CPU_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$output_directory/$name")
    status=$?
    set -e
    [[ $status -eq 42 && ($name != dns-async || $output == "dns async: ok") ]] ||
        { echo "dns async: $name exited with $status"; echo "$output"; exit 1; }
done

# The resolver builds for the Linux target too.
"$compiler" build "$project_root/tests/cases/modules/dns-async.ab" \
    --target x86_64-linux --emit object -o "$output_directory/linux.o" \
    --no-cache 2>/dev/null
echo "dns async: literals, A/AAAA, resend, stray replies, timeouts, cancel, outside loop, http"
