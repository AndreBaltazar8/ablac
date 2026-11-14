#!/usr/bin/env bash
# The HTTP clients and abla/tls/hosted against forked peers that reset or go
# quiet (tests/cases/tls-faults). Each stage has a time limit: without socket
# timeouts and the SIGPIPE guard a stage hangs or the process dies of SIGPIPE.
# TLS_FAULTS_FAULTS_ONLY=1 builds only the stages that use the older API, so
# they can show that on an older compiler.
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=${TLS_FAULTS_OUTPUT:-$project_root/build/tls-faults}
mkdir -p "$output_directory"
cd "$project_root"

# The clients trust the test certificate through SSL_CERT_FILE. Nixpkgs' OpenSSL
# reads NIX_SSL_CERT_FILE before it, and a Nix install sets that to the system
# bundle (CI does), so it would not see the certificate.
unset NIX_SSL_CERT_FILE
# (These programs are built in release mode, not --fast: their stages time the exchange against budgets of 300 ms and
# up, and the pure TLS handshake of an unoptimised build costs hundreds of milliseconds on a slow or loaded machine
# (the Linux CI runner, one busy CPU here), which is not what they measure. An Ed25519 key keeps the server's
# signature cheap too.)
openssl genpkey -algorithm ED25519 -out "$output_directory/key.pem" || exit 2
openssl req -x509 -new -key "$output_directory/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
    -out "$output_directory/certificate.pem" 2>/dev/null || exit 2
"$compiler" build tests/cases/tls-faults/faults.ab -o "$output_directory/faults" || exit 2

# The time limits here (`timeout`, the bounds in the programs) are hang guards, far above what the stages take: the
# stages' own timeouts (a second or less) are what they test, and a loaded machine must not turn into a failure.
# Each stage forks its own peers on ports of its own: most of each is waiting for
# a limit, so they wait together.
report() { # name rc
    if [[ $2 -eq 0 ]]; then
        echo "ok   $1"
    else
        case $2 in
            124) why='hung' ;;
            141) why='died of SIGPIPE' ;;
            *) why="exit $2" ;;
        esac
        echo "FAIL $1: $why"
        sed 's/^/     /' "$output_directory/$1.log"
        status=1
    fi
}
# Every peer ends with its client (peer.ab): none may outlive the run.
check_peers() {
    local left=() attempt process
    for attempt in $(seq 1 1200); do
        left=()
        for process in /proc/[0-9]*; do
            case $(readlink "$process/exe" 2>/dev/null) in
                "$output_directory"/faults | "$output_directory"/timeouts | "$output_directory"/deadlines)
                    left+=("${process#/proc/}") ;;
            esac
        done
        [[ ${#left[@]} -eq 0 ]] && break
        sleep 0.1
    done
    if [[ ${#left[@]} -gt 0 ]]; then
        echo "FAIL a peer outlived its client: ${left[*]}"
        kill -9 "${left[@]}" 2>/dev/null
        status=1
    fi
}
status=0
stages=(mask
    https-reset-read https-reset-write https-stall-read https-stall-write
    http-reset-read http-reset-write http-stall-read http-stall-write
    http-kept http-long-timeout read-long-timeout
    async-reset-write async-stall async-retry)
pids=()
for stage in "${stages[@]}"; do
    SSL_CERT_FILE="$output_directory/certificate.pem" timeout 600 \
        "$output_directory/faults" "$output_directory/certificate.pem" "$output_directory/key.pem" "$stage" \
        > "$output_directory/$stage.log" 2>&1 &
    pids+=($!)
done
for index in "${!stages[@]}"; do
    rc=0
    wait "${pids[$index]}" || rc=$?
    report "${stages[$index]}" "$rc"
done
if [[ -n ${TLS_FAULTS_FAULTS_ONLY:-} ]]; then
    check_peers
    exit "$status"
fi

"$compiler" build tests/cases/tls-faults/timeouts.ab -o "$output_directory/timeouts" || exit 2
"$compiler" build tests/cases/tls-faults/deadlines.ab -o "$output_directory/deadlines" || exit 2
timeout 600 "$output_directory/timeouts" "$output_directory/certificate.pem" "$output_directory/key.pem" \
    > "$output_directory/timeouts.log" 2>&1 &
timeouts=$!
SSL_CERT_FILE="$output_directory/certificate.pem" timeout 600 \
    "$output_directory/deadlines" "$output_directory/certificate.pem" "$output_directory/key.pem" \
    > "$output_directory/deadlines.log" 2>&1 &
deadlines=$!
rc=0
wait "$timeouts" || rc=$?
report timeouts "$rc"
rc=0
wait "$deadlines" || rc=$?
report deadlines "$rc"
check_peers
[[ $status -eq 0 ]] && echo 'TLS faults: passed'
exit "$status"
