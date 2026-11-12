#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/http-client"
program="$output_directory/program"
ready="$output_directory/ready"
mkdir -p "$output_directory"
rm -f "$ready"

# The peer (an Abla program speaking literal HTTP bytes over a raw socket: it shares
# nothing with the HTTP client under test but the socket layer) listens on a port the
# system picks (tests run in parallel) and publishes it in $ready; the client program
# is built with that port. The client under test is the portable Abla HTTP client over
# plain TCP; its TLS transport here is a stub, so no TLS library is involved.
"$compiler" build "$project_root/tests/cases/http-client-peer/peer.ab" -o "$output_directory/peer" --fast
peer_pid=
trap 'if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" 2>/dev/null || true; fi' EXIT
# start_peer [wrong]: run a peer under a hard timeout and set $port once it is ready.
start_peer() {
    rm -f "$ready"
    timeout 60 "$output_directory/peer" "$ready" "$@" &
    peer_pid=$!
    for _ in $(seq 1 500); do
        [[ -e $ready ]] && break
        sleep 0.02
    done
    [[ -e $ready ]] || { echo 'HTTP client: the peer did not publish its port' >&2; exit 1; }
    port=$(<"$ready")
    sed "s/39092/$port/g" "$project_root/tests/cases/http-client-ipv4.ab" \
        > "$output_directory/http-client-ipv4.ab"
    "$compiler" build "$output_directory/http-client-ipv4.ab" -o "$program" --fast
}
# Control: a peer that always answers "bad" must make the client program fail.
start_peer wrong
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
wait "$peer_pid" || true
[[ $status -ne 42 ]] || { echo 'HTTP client: the program passed against a peer that answers bad' >&2; exit 1; }
start_peer
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
wait "$peer_pid"
peer_pid=
[[ $status -eq 42 ]] || exit 1

# The same exchanges against the program's own loopback listener.
"$compiler" build "$project_root/tests/cases/modules/http-client.ab" \
    -o "$output_directory/loopback" --fast
set +e
"$project_root/tools/run-limited.sh" "$output_directory/loopback"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

printf '%s\n' 'HTTP client: bounded raw IPv4 exchange + pluggable TLS transport passed'
