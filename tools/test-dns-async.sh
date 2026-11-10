#!/usr/bin/env bash
# abla/dns's resolvers against a mock name server in a forked child and
# written resolv.conf/hosts files (tests/cases/modules/dns-async.ab: literals,
# A and AAAA, the resend, stray and spoofed replies, NXDOMAIN, timeouts,
# cancel, an outside poll loop, search domains/ndots, the hosts file, the
# blocking resolver and HttpAsyncClient on top), then the HttpAsyncClient
# conformance case, which resolves through the same resolver.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/dns-async"
mkdir -p "$output_directory"

# Each run's budget is CPU time (ABLA_MAX_CPU_SECONDS), which load does not change; the wall-clock limit only
# ends a hang.
for name in dns-async http-async; do
    "$compiler" build "$project_root/tests/cases/modules/$name.ab" \
        -o "$output_directory/$name"
    set +e
    output=$(ABLA_TEST_DIRECTORY="$output_directory" \
        ABLA_MAX_MEMORY_MB=256 ABLA_MAX_SECONDS=900 \
        ABLA_MAX_CPU_SECONDS=30 \
        "$project_root/tools/run-limited.sh" "$output_directory/$name")
    status=$?
    set -e
    [[ $status -eq 42 && ($name != dns-async || $output == "dns async: ok") ]] ||
        { echo "dns async: $name exited with $status"; echo "$output"; exit 1; }
done

# Keep many port-zero sockets open together and check SO_REUSEADDR directly.
"$compiler" build "$project_root/tests/cases/modules/udp-ephemeral.ab" \
    -o "$output_directory/udp-ephemeral"
status=0
"$output_directory/udp-ephemeral" || status=$?
[[ $status -eq 42 ]] || { echo "dns async: ephemeral socket regression failed ($status)"; exit 1; }

# The original failure appeared under suite contention. Each fixture has its
# own directory; compile once, then run eight copies together. Increase rounds
# for an extended stress run without slowing the normal suite unnecessarily.
rounds=${ABLA_DNS_STRESS_ROUNDS:-2}
for ((round=1; round<=rounds; round++)); do
    pids=()
    for ((worker=1; worker<=8; worker++)); do
        directory="$output_directory/stress-$worker"
        mkdir -p "$directory"
        (
            status=0
            output=$(ABLA_TEST_DIRECTORY="$directory" ABLA_MAX_MEMORY_MB=256 \
                ABLA_MAX_SECONDS=900 ABLA_MAX_CPU_SECONDS=30 \
                "$project_root/tools/run-limited.sh" "$output_directory/dns-async") || status=$?
            [[ $status -eq 42 && $output == "dns async: ok" ]] || {
                echo "dns async stress: round $round worker $worker exited $status: $output" >&2
                exit 1
            }
        ) &
        pids+=("$!")
    done
    failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    [[ $failed -eq 0 ]] || exit 1
done

# The resolver builds for the Linux target too.
"$compiler" build "$project_root/tests/cases/modules/dns-async.ab" \
    --target x86_64-linux --emit object -o "$output_directory/linux.o" \
    2>/dev/null
echo "dns async: literals, A/AAAA, resend, stray replies, NXDOMAIN, timeouts, cancel, outside loop, search/ndots, hosts, blocking, http"
