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

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
    -keyout "$output_directory/key.pem" -out "$output_directory/certificate.pem" 2>/dev/null || exit 2
"$compiler" build tests/cases/tls-faults/faults.ab -o "$output_directory/faults" --fast --no-cache || exit 2

status=0
for stage in mask \
    https-reset-read https-reset-write https-stall-read https-stall-write \
    http-reset-read http-reset-write http-stall-read http-stall-write \
    http-kept http-long-timeout \
    async-reset-write async-stall async-retry; do
    SSL_CERT_FILE="$output_directory/certificate.pem" timeout 40 \
        "$output_directory/faults" "$output_directory/certificate.pem" "$output_directory/key.pem" "$stage" \
        > "$output_directory/$stage.log" 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "ok   $stage"
    else
        case $rc in
            124) why='hung' ;;
            141) why='died of SIGPIPE' ;;
            *) why="exit $rc" ;;
        esac
        echo "FAIL $stage: $why"
        sed 's/^/     /' "$output_directory/$stage.log"
        status=1
    fi
done
[[ -n ${TLS_FAULTS_FAULTS_ONLY:-} ]] && exit "$status"

"$compiler" build tests/cases/tls-faults/timeouts.ab -o "$output_directory/timeouts" --fast --no-cache || exit 2
timeout 60 "$output_directory/timeouts" "$output_directory/certificate.pem" "$output_directory/key.pem" \
    > "$output_directory/timeouts.log" 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    echo "FAIL timeouts: exit $rc"
    sed 's/^/     /' "$output_directory/timeouts.log"
    status=1
else
    echo "ok   timeouts"
fi
[[ $status -eq 0 ]] && echo 'TLS faults: passed'
exit "$status"
