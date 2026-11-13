#!/usr/bin/env bash
# Regenerates tests/vectors/tls/rfc8448-section3.txt from the text of RFC 8448 ("Example Handshake Traces
# for TLS 1.3"): the Simple 1-RTT Handshake (section 3), one record per line,
#   heading|name|hex
# where heading is the RFC's own step (for example `{server}  derive secret "tls13 s hs traffic"`) and
# name the value (PRK, hash, info, expanded, key, iv, payload, complete record, ...). Usage:
#   curl -O https://www.rfc-editor.org/rfc/rfc8448.txt
#   tools/tls/extract-rfc8448.sh rfc8448.txt > tests/vectors/tls/rfc8448-section3.txt
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
start=$(grep -n '^3\.  Simple 1-RTT Handshake' "$1" | tail -1 | cut -d: -f1)
end=$(grep -n '^4\.  Resumed 0-RTT Handshake' "$1" | tail -1 | cut -d: -f1)
sed -n "${start},$((end - 1))p" "$1" | awk -v section=3 -f "$here/rfc8448.awk" | cut -d'|' -f2-
