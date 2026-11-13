#!/usr/bin/env bash
# Cuts tests/cases/x509/limbo from C2SP/x509-limbo's limbo.json (https://github.com/C2SP/x509-limbo, 42 MB): the server validation
# cases without CRLs, ML-DSA or denial-of-service features, with only the fields tests/cases/x509/limbo.ab reads;
# and every 25th of the 9,491 BetterTLS name-constraint cases. known.tsv (the cases this code answers differently, and why) is kept by hand.
#   tools/gen-x509-limbo.sh [limbo.json]    (downloaded when not given)
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source=${1:-}
if [[ -z $source ]]; then
    source=$(mktemp)
    trap 'rm -f "$source"' EXIT
    curl -sfL -o "$source" https://raw.githubusercontent.com/C2SP/x509-limbo/main/limbo.json
fi
out=$root/tests/cases/x509/limbo
mkdir -p "$out"
fields='{id, features, trusted_certs, untrusted_intermediates, peer_certificate, validation_time, expected_result, expected_peer_name, expected_peer_names, max_chain_depth, extended_key_usage, key_usage, validation_kind}'
jq -c "{version, testcases: [.testcases[] | select(.validation_kind==\"SERVER\") | select((.id|startswith(\"bettertls::nameconstraints\"))|not) | select([.features[] | select(. == \"has-crl\" or . == \"has-mldsa\" or . == \"denial-of-service\")] | length == 0) | $fields]}" "$source" > "$out/limbo-core.json"
jq -c "{version, testcases: [.testcases | to_entries[] | select(.value.validation_kind==\"SERVER\" and (.value.id|startswith(\"bettertls::nameconstraints\")) and (.key % 25 == 0)) | .value | $fields]}" "$source" > "$out/limbo-bettertls-nc.json"
ls -l "$out"
