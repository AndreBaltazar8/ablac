#!/usr/bin/env bash
# abla/tls/pure against BoringSSL's TLS test suite (BoGo): the Go runner in BoringSSL's ssl/test/runner, at the commit
# pinned below and fetched into build/bogo/boringssl (not vendored), drives tools/tls-bogo/shim.ab as a client and as a
# server through several thousand tests. tools/tls-bogo/config.json disables what abla/tls/pure refuses on purpose
# (TLS 1.0/1.1, CBC and RSA key exchange, TLS 1.2 without the extended master secret, SHA-1, renegotiation, groups
# besides X25519 and P-256, ECH, 0-RTT); the shim exits 89 (unimplemented) on a flag it has no answer for (DTLS, QUIC,
# resumption and the like), which the runner skips. tools/tls-bogo/expected-failures.txt lists the tests that fail
# today, each with the reason: the regression record. The test fails when a test outside that list fails, and when a
# test on it passes (take it off the list).
# Needs go and network access the first time (the BoringSSL checkout and the runner's Go modules are cached).
# BOGO_FILTER passes -test to the runner (patterns separated by ';'); BOGO_WORKERS sets its parallelism (default 8).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
boringssl_commit=148a7b1f361dcf6708e9eb3b7c2134d0c5633e3e
out=$root/build/bogo
checkout=$out/boringssl
command -v go > /dev/null || { echo "tls-bogo: needs go (the BoGo runner is a Go program)" >&2; exit 1; }
mkdir -p "$out"
if [[ $(git -C "$checkout" rev-parse HEAD 2> /dev/null || true) != "$boringssl_commit" ]]; then
    rm -rf "$checkout"
    mkdir -p "$checkout"
    git -C "$checkout" init -q
    git -C "$checkout" remote add origin https://boringssl.googlesource.com/boringssl
    git -C "$checkout" fetch -q --depth 1 origin "$boringssl_commit"
    git -C "$checkout" checkout -q FETCH_HEAD
fi
"$compiler" build tools/tls-bogo/shim.ab -o "$out/shim" --no-cache > "$out/shim.build.log" 2>&1 ||
    { cat "$out/shim.build.log" >&2; exit 1; }
[[ $("$out/shim" -is-handshaker-supported) == No ]] || { echo "tls-bogo: the shim did not answer -is-handshaker-supported" >&2; exit 1; }

rm -f "$out/results.json"
filter=()
[[ -z ${BOGO_FILTER:-} ]] || filter=("-test=$BOGO_FILTER")
# The runner exits non-zero whenever a test fails; the results file is what is judged.
(cd "$checkout/ssl/test/runner" && go test . -shim-path="$out/shim" -shim-config="$root/tools/tls-bogo/config.json" \
    -allow-unimplemented -loose-errors -num-workers="${BOGO_WORKERS:-8}" -json-output="$out/results.json" "${filter[@]}") \
    > "$out/runner.log" 2>&1 || true
[[ -s $out/results.json ]] || { tail -30 "$out/runner.log" >&2; echo "tls-bogo: the runner wrote no results" >&2; exit 1; }

jq -r '.tests | to_entries[] | select(.value.actual == "FAIL") | .key' "$out/results.json" | sort > "$out/failed.txt"
jq -r '.tests | to_entries[] | select(.value.actual == "PASS") | .key' "$out/results.json" | sort > "$out/passed.txt"
grep -v '^#' tools/tls-bogo/expected-failures.txt | awk 'NF { print $1 }' | sort > "$out/expected.txt"
new_failures=$(comm -23 "$out/failed.txt" "$out/expected.txt")
now_passing=$(comm -12 "$out/passed.txt" "$out/expected.txt")
counts=$(jq -r '[.tests[].actual] | group_by(.) | map("\(length) \(.[0])") | join(", ")' "$out/results.json")
status=0
if [[ -n $new_failures ]]; then
    echo "tls-bogo: tests failed that are not on tools/tls-bogo/expected-failures.txt:" >&2
    echo "$new_failures" | sed 's/^/  /' >&2
    echo "  (details in $out/runner.log)" >&2
    status=1
fi
if [[ -n $now_passing ]]; then
    echo "tls-bogo: tests on tools/tls-bogo/expected-failures.txt now pass (take them off the list):" >&2
    echo "$now_passing" | sed 's/^/  /' >&2
    status=1
fi
[[ $status -eq 0 ]] && echo "tls-bogo ok: $counts ($(wc -l < "$out/expected.txt") expected failures, BoringSSL ${boringssl_commit:0:8})"
exit $status
