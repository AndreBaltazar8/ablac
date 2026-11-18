#!/usr/bin/env bash
# The compiler's own TLS (abla/platform/host/tls, over abla/tls/pure: no OpenSSL) at compile time and in the program it
# builds with the network grant only (default tier), against `openssl s_server`: a TLS 1.3 and a TLS 1.2 server answer; a host name the certificate does not name
# (the SAN is DNS:localhost; 127.0.0.1 is refused), an expired certificate and a closed port are refused with the stage in
# the error, and nothing hangs. The compile-time and the run-time results are the same. Skipped without openssl.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
out="$root/build/compile-tls"
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null; then
    echo 'compile-tls: no openssl; skipped'
    exit 0
fi
make_certificate() { # <name> [extra req options]
    local name=$1
    shift
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$out/$name.key" -out "$out/$name.pem" \
        -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' "$@" 2> /dev/null
}
make_certificate good -days 2
make_certificate expired -not_before 20200101000000Z -not_after 20200102000000Z
pids=()
trap 'for pid in ${pids[@]+"${pids[@]}"}; do kill "$pid" 2> /dev/null || true; done' EXIT
serve() { # <name> <certificate> <options…>: s_server in $out (-www answers a GET), the port in $openssl_server_port
    local name=$1 certificate=$2
    shift 2
    openssl_server_start "$out/$name.log" 0 -cert "$out/$certificate.pem" -key "$out/$certificate.key" -www "$@" ||
        { echo "compile-tls: s_server $name did not start" >&2; exit 1; }
    pids+=("$openssl_server_pid")
}
serve tls13 good -tls1_3
port13=$openssl_server_port
serve tls12 good -tls1_2
port12=$openssl_server_port
serve expired expired -tls1_3
port_expired=$openssl_server_port
serve closed good -tls1_3
port_closed=$openssl_server_port
kill "${pids[${#pids[@]}-1]}" 2> /dev/null || true
wait "${pids[${#pids[@]}-1]}" 2> /dev/null || true
sed -e "s#@PORT13@#$port13#g; s#@PORT12@#$port12#g; s#@PORTEXPIRED@#$port_expired#g; s#@PORTCLOSED@#$port_closed#g" \
    -e "s#@CA@#$out/good.pem#g; s#@EXPIREDCA@#$out/expired.pem#g" tests/cases/compile-tls/main.ab > "$out/main.ab"
printf 'compileCapabilities = ["network"]\n' > "$out/abla.toml"
"$compiler" build "$out/main.ab" -o "$out/main" --no-cache
status=0
timeout 120 "$out/main" > "$out/run.log" 2>&1 || status=$?
cat "$out/run.log"
[[ $status -eq 42 ]] || { echo "compile-tls: exit $status, expected 42" >&2; exit 1; }
refused='refused: TLS failed at certificate_verification'
expected="HTTP/1.0 200 ok | HTTP/1.0 200 ok | $refused | $refused | refused: TLS failed at tcp_connect"
grep -Fxq "compiled: $expected" "$out/run.log" || { echo 'compile-tls: the compile-time results differ' >&2; exit 1; }
grep -Fxq "running: $expected" "$out/run.log" || { echo 'compile-tls: the run-time results differ' >&2; exit 1; }

# The network grant covers the TLS code's own effects and nothing beside it (docs/compile-time.md, network scopes).
# Without the grant the fetch is denied for network; with it, the program's own clock or environment read next to the
# fetch is still denied for itself.
negative() { # <name> <expected error> <program>
    local name=$1 expected=$2
    mkdir -p "$out/$name"
    printf 'compileCapabilities = ["network"]\n' > "$out/$name/abla.toml"
    cat > "$out/$name/main.ab"
    for tier in interp jit auto; do
    if ABLA_COMPILE_EVAL=$tier "$compiler" build "$out/$name/main.ab" -o "$out/$name/main" --no-cache > "$out/$name.$tier.log" 2>&1; then
        echo "compile-tls: $name was built in tier $tier, expected $expected" >&2
        exit 1
    fi
    grep -Fq "$expected" "$out/$name.$tier.log" || { echo "compile-tls: $name ($tier): expected $expected" >&2; cat "$out/$name.$tier.log" >&2; exit 1; }
    done
}
negative nogrant 'compile.effect-denied:network' << EOF2
import "abla/platform/host"
import "abla/platform/host/tls"
fun fetch(): string {
    val handle = ablaHostTlsOpenWithCa("localhost", $port13, 5000, "$out/good.pem")
    if (handle < 0) "refused" else "open"
}
fun main(): int = if (#fetch() == "open") 42 else 1
EOF2
negative ownclock 'compile.effect-denied:clock' << EOF2
import "abla/compiler"
import "abla/platform/host"
import "abla/platform/host/tls"
import "abla/process/time"
#compilerGrant("network")
fun fetch(): string {
    val started = monotonicMilliseconds()
    val handle = ablaHostTlsOpenWithCa("localhost", $port13, 5000, "$out/good.pem")
    if (handle < 0 || started < 0) "refused" else "open"
}
fun main(): int = if (#fetch() == "open") 42 else 1
EOF2
negative ownenvironment 'compile.effect-denied:environment' << EOF2
import "abla/compiler"
import "abla/platform/host"
import "abla/platform/host/tls"
#compilerGrant("network")
fun fetch(): string {
    val handle = ablaHostTlsOpenWithCa("localhost", $port13, 5000, "$out/good.pem")
    if (handle < 0 || compilerEnvironment("HOME") == "x") "refused" else "open"
}
fun main(): int = if (#fetch() == "open") 42 else 1
EOF2
negative ownfile 'compile.effect-denied:filesystem.read' << EOF2
import "abla/compiler"
import "abla/fs"
import "abla/platform/host"
import "abla/platform/host/tls"
#compilerGrant("network")
fun fetch(): string {
    val handle = ablaHostTlsOpenWithCa("localhost", $port13, 5000, "$out/good.pem")
    if (handle < 0 || path("$out/good.pem").exists()) "refused" else "open"
}
fun main(): int = if (#fetch() == "open") 42 else 1
EOF2
echo 'compile-tls: TLS 1.3 and 1.2 at compile time and run time with the network grant only, a wrong host name and an expired certificate refused, a closed port reported; without the grant, or with its own file, clock or environment read beside it (in each tier), the build is denied'
