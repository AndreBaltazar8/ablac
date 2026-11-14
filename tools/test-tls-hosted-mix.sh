#!/usr/bin/env bash
# abla/tls/hosted and the modules built on abla/tls/pure in one program. A module that imports abla/tls/pure unqualified
# brings a second TlsConnection, TlsListener and tlsServerUpgrade into the program, and the compiler matches
# declarations by name: v0.2.60's first candidate failed NovaKind's signer with `constructor.arity:TlsConnection`.
# The modules import abla/tls/pure under an alias (as abla/http/tls does); each program in tests/cases/tls-mix must build.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/tls-hosted-mix"
mkdir -p "$output_directory"
for program in "$project_root"/tests/cases/tls-mix/*.ab; do
    name=$(basename "$program" .ab)
    log="$output_directory/$name.log"
    if ! "$compiler" build "$program" -o "$output_directory/$name" --fast --no-cache > "$log" 2>&1; then
        cat "$log" >&2
        echo "tls hosted mix: $name does not build" >&2
        exit 1
    fi
done
echo "tls hosted mix: abla/tls/hosted builds with abla/http/async, abla/websocket/server/tls, abla/http/tls and abla/websocket/tls"
