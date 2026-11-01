#!/usr/bin/env bash
# The repository's shell leaves a host's own tools alone: no LD_LIBRARY_PATH of its
# glibc's, and a program linking OpenSSL still finds it, by its runpath.
set -euo pipefail

compiler=${1:-build/ablac}
if [[ -z ${IN_NIX_SHELL:-} || -z ${ABLA_LINUX_OPENSSL_LIB:-} ]]; then
    echo 'shell environment: skipped outside the Nix shell'
    exit 0
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/shell-environment
mkdir -p "$output_directory"

if [[ ${LD_LIBRARY_PATH:-} == *"$ABLA_LINUX_OPENSSL_LIB"* ]]; then
    echo "shell environment: LD_LIBRARY_PATH holds OpenSSL: $LD_LIBRARY_PATH" >&2
    exit 1
fi
cat > "$output_directory/tls.ab" <<'AB'
import "abla/tls/hosted"
fun main: int = if (tlsLastError() == "") 42 else 1
AB
"$compiler" build "$output_directory/tls.ab" -o "$output_directory/tls"
status=0
"$output_directory/tls" || status=$?
[[ $status -eq 42 ]] || { echo "shell environment: a TLS program exited with $status" >&2; exit 1; }
# And the compiler itself, which links it too.
env -u LD_LIBRARY_PATH "$(readlink -f "$compiler.bin" 2>/dev/null || echo "$compiler")" --version >/dev/null
echo 'shell environment: OpenSSL by runpath, no LD_LIBRARY_PATH'
