#!/usr/bin/env bash
# The hosted network API on loopback: an IPv6 TCP listener and client, UDP and
# the socket poller (on macOS through the Linux syscall layer, whose socket
# addresses must read like Linux's).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/hosted-network"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/hosted-network.ab" \
    -o "$output_directory/hosted-network" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/hosted-network"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "hosted network: exited $status, expected 42" >&2; exit 1; }
echo "hosted network: IPv6 loopback TCP, UDP and the poller work"
