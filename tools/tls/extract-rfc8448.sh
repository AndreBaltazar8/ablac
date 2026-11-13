#!/usr/bin/env bash
# Regenerates a tests/vectors/tls/rfc8448-section<N>.txt from the text of RFC 8448 ("Example Handshake
# Traces for TLS 1.3"): one section's trace (3 Simple 1-RTT Handshake, 4 Resumed 0-RTT, 5 HelloRetryRequest,
# 6 Client Authentication, 7 Compatibility Mode), one value per line,
#   heading|name|hex
# where heading is the RFC's own step (for example `{server}  derive secret "tls13 s hs traffic"`) and
# name the value (PRK, hash, info, expanded, key, iv, payload, complete record, ...). Usage:
#   curl -O https://www.rfc-editor.org/rfc/rfc8448.txt
#   tools/tls/extract-rfc8448.sh rfc8448.txt 3 > tests/vectors/tls/rfc8448-section3.txt
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
section=${2:-3}
start=$(grep -n "^${section}\.  " "$1" | tail -1 | cut -d: -f1)
end=$(grep -n "^$((section + 1))\.  " "$1" | tail -1 | cut -d: -f1)
sed -n "${start},$((end - 1))p" "$1" | awk -v section="$section" -f "$here/rfc8448.awk" | cut -d'|' -f2-
