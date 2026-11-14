#!/usr/bin/env bash
# abla/tls/pure: the TLS 1.3 key schedule, record layer and client state machine against RFC 8448 section 3 (every secret,
# key, IV, Finished value and protected record of the Simple 1-RTT Handshake; tests/cases/tls-pure/
# keysched.ab with tests/vectors/tls/rfc8448-section3.txt), release and --fast, plus a control: with one
# value of the vector file changed the test must fail. tools/tls/extract-rfc8448.sh regenerates the file.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-pure
rm -rf "$out"
mkdir -p "$out/broken"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    for program in keysched client codec retry auth coexist; do
        "$compiler" build "tests/cases/tls-pure/$program.ab" -o "$out/$program.$mode" "${flags[@]}"
        result=$("$root/tools/run-limited.sh" "$out/$program.$mode" tests/vectors/tls) || { echo "tls-pure $program ($mode): $result" >&2; exit 1; }
        [[ $result == "tls-pure $program ok" ]] || { echo "tls-pure $program ($mode): $result" >&2; exit 1; }
    done
done
# Control: the same program must reject a vector file whose server handshake key is wrong.
sed 's/^\({server}  derive write traffic keys for handshake data|key expanded|\)3f/\100/' \
    tests/vectors/tls/rfc8448-section3.txt > "$out/broken/rfc8448-section3.txt"
cmp -s "$out/broken/rfc8448-section3.txt" tests/vectors/tls/rfc8448-section3.txt && { echo "tls-pure: the control did not change the vectors" >&2; exit 1; }
if "$root/tools/run-limited.sh" "$out/keysched.release" "$out/broken" > "$out/broken.log" 2>&1; then
    echo "tls-pure: the control (a wrong vector) passed" >&2
    exit 1
fi
grep -q 'FAIL server handshake key' "$out/broken.log" || { echo "tls-pure: the control failed for another reason: $(head -3 "$out/broken.log")" >&2; exit 1; }
echo "tls-pure ok"
