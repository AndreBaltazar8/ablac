#!/usr/bin/env bash
# `--wasm-imports` lists a Wasm module's imports, and an abla.toml `wasmHostImports` list makes any import it does not
# cover a warning (an extern nothing defines links as an import of module env).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/wasm-imports"
mkdir -p "$out"
cd "$project_root"

build() {
    "$compiler" build tests/cases/wasm-imports/build.ab -o "$out/driver" --fast "$@" 2>&1 \
        && "$out/driver" 2>&1
}

# The warning: the manifest lists the host's imports and leaves env.env_log out.
build >"$out/warn.txt"
grep -q 'warning: .*imports env.env_log, which wasmHostImports' "$out/warn.txt" || { cat "$out/warn.txt"; exit 1; }
if grep -q 'imports host.now_millis\|imports wasi_snapshot_preview1' "$out/warn.txt"; then
    cat "$out/warn.txt"; echo "listed imports must not warn"; exit 1
fi

# The report lists every import, listed or not.
build --wasm-imports >"$out/report.txt"
for entry in env.env_log host.now_millis wasi_snapshot_preview1.fd_write; do
    grep -q "note:   $entry\$" "$out/report.txt" || { cat "$out/report.txt"; echo "missing $entry"; exit 1; }
done

# Without a wasmHostImports list and without the flag, a build says nothing.
cp -r tests/cases/wasm-imports "$out/plain"
sed -i '/^wasmHostImports/d' "$out/plain/abla.toml"
sed -e "s#tests/cases/wasm-imports/main.ab#build/wasm-imports/plain/main.ab#" -e "s#wasm-imports/wasm-imports.wasm#wasm-imports/plain.wasm#" \
    tests/cases/wasm-imports/build.ab >"$out/plain/build.ab"
"$compiler" build build/wasm-imports/plain/build.ab -o "$out/plain-driver" --fast >"$out/plain.txt" 2>&1
"$out/plain-driver" >>"$out/plain.txt" 2>&1
if grep -q 'imports\|warning' "$out/plain.txt"; then cat "$out/plain.txt"; echo "unexpected note"; exit 1; fi
echo "wasm-imports ok"
