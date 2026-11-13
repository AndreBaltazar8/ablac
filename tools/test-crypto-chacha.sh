#!/usr/bin/env bash
# abla/crypto/chacha20poly1305: RFC 8439's own vectors (tests/cases/crypto-chacha/kat.ab) run natively, on AArch64
# under qemu and on Wasm under Node, and compiled for Xtensa; and every message length from 0 to 200 (and a few
# longer) against Node's ChaCha20-Poly1305 and ChaCha20 (OpenSSL), sealing, opening, refusing a changed tag and the
# raw stream at a random counter. What is read of the code is in tools/test-ct.sh.
# CHACHA_ROUNDS sets the random rounds of the peer check (default 2).
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/crypto-chacha
rounds=${CHACHA_ROUNDS:-2}
rm -rf "$out"
mkdir -p "$out"
cd "$project_root"
cases=tests/cases/crypto-chacha

status=0
fail() { echo "FAIL $*"; status=1; }

pids=()
programs=(vectors tool)
for program in "${programs[@]}"; do
    "$compiler" build "$cases/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
for index in "${!programs[@]}"; do
    wait "${pids[$index]}" || { cat "$out/${programs[$index]}.build.log"; exit 2; }
done

if "$out/vectors" > "$out/vectors.log" 2>&1; then
    echo "ok   vectors: $(cat "$out/vectors.log")"
else
    fail vectors; cat "$out/vectors.log"
fi

if node "$cases/peer.mjs" "$out/tool" "$rounds" > "$out/peer.log" 2>&1; then
    echo "ok   $(cat "$out/peer.log")"
else
    fail "peer"; tail -5 "$out/peer.log"
fi

"$compiler" build "$cases/wasm-build.ab" -o "$out/wasm-driver" --no-cache > "$out/wasm.log" 2>&1 || { cat "$out/wasm.log"; fail "wasm build"; }
"$out/wasm-driver" && node "$cases/run.mjs" "$out/chacha.wasm" && echo "ok   wasm under node: RFC 8439 vectors" || fail "wasm"

"$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver" --no-cache > "$out/aarch64.log" 2>&1 || { cat "$out/aarch64.log"; fail "aarch64 build"; }
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
if qemu-aarch64 -cpu max "$out/aarch64"; then echo "ok   aarch64 under qemu: RFC 8439 vectors"; else fail "aarch64: check $?"; fi

tools_directory="$out/xtensa-tools"
. "$project_root/tools/xtensa-test-tools.sh"
abla_xtensa_test_prepare "$tools_directory"
if abla_xtensa_test_build "$compiler" "$tools_directory" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object > "$out/xtensa.log" 2>&1; then
    echo "ok   xtensa: compiled, not run"
else
    cat "$out/xtensa.log"; fail "xtensa build"
fi

[[ $status -eq 0 ]] && echo "crypto-chacha: ok" || echo "crypto-chacha: FAILED"
exit $status
