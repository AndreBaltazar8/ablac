#!/usr/bin/env bash
# The browser compiler as a build product (#1138): the compiler's front end as a release wasm32 module (src/browser_main.ab), the standard
# library bundle, and the page's host (tools/playground), packed in abla-playground-<version>.tar.gz with a manifest. Built from a checkout
# with the compiler given, byte for byte the same each time: names carry content hashes, the manifest holds no dates, the archive no owners
# or times. abla.dev unpacks it; the release workflow attaches it.
#
#   tools/build-playground.sh <compiler> <output directory inside the checkout> [version]
#
# The version defaults to the compiler's own. Prints the archive's path.
set -euo pipefail
export LC_ALL=C

compiler=${1:?usage: build-playground.sh <compiler> <output directory> [version]}
output=${2:?usage: build-playground.sh <compiler> <output directory> [version]}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$output"
output=$(cd "$output" && pwd)
case $output in "$root"/*) ;; *) echo "build-playground: the output directory must be inside the checkout ($root)" >&2; exit 2 ;; esac
version=${3:-$("$compiler" --version | awk '{print $2}')}
[[ -n $version ]] || { echo "build-playground: no version" >&2; exit 2; }

stage="$output/stage"
package="abla-playground-$version"
rm -rf "$stage" "$output/$package" "$output/$package.tar.gz"
mkdir -p "$stage" "$output/$package"

# 1. The front end as a release wasm32 module. The build file sits in the stage, inside the checkout, so its paths reach src/.
entry=$(realpath --relative-to="$stage" "$root/src/browser_main.ab")
cat > "$stage/abla.toml" <<'TOML'
compileCapabilities = ["filesystem.write"]
TOML
cat > "$stage/build.ab" <<ABLA
import "abla/wasm/build"

val module = #wasmBuildModule("browser-compiler", "$entry", "browser-compiler.wasm", false, false)

fun main: int = if (module) 0 else 1
ABLA
(cd "$root" && "$compiler" build "$stage/build.ab" -o "$stage/build-driver" --no-cache)
(cd "$root" && "$stage/build-driver")
[[ -s $stage/browser-compiler.wasm ]] || { echo "build-playground: the module was not built" >&2; exit 1; }
wasm_hash=$(sha256sum "$stage/browser-compiler.wasm" | cut -d' ' -f1)
wasm_name="compiler-${wasm_hash:0:16}.wasm"
cp "$stage/browser-compiler.wasm" "$output/$package/$wasm_name"

# 2. The standard library as one brotli bundle, and the page's host files.
stdlib_name=$(node "$root/tools/playground/pack-stdlib.mjs" "$root/stdlib" "$output/$package")
for file in host.mjs vfs.mjs stdlib-bundle.mjs; do cp "$root/tools/playground/$file" "$output/$package/$file"; done

# 3. The manifest: what the page fetches, with sizes and hashes (no dates).
node - "$output/$package" "$version" "$wasm_name" "$stdlib_name" <<'JS'
const [directory, version, wasm, stdlib] = process.argv.slice(2);
const { readFileSync, statSync, writeFileSync } = await import("node:fs");
const { createHash } = await import("node:crypto");
const { join } = await import("node:path");
const describe = (file) => ({
    file,
    bytes: statSync(join(directory, file)).size,
    sha256: createHash("sha256").update(readFileSync(join(directory, file))).digest("hex"),
});
const manifest = {
    format: 1,
    version,
    compiler: describe(wasm),
    stdlib: describe(stdlib),
    host: ["host.mjs", "stdlib-bundle.mjs", "vfs.mjs"].map(describe),
};
writeFileSync(join(directory, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
JS

# 4. The archive: sorted, no owners, no times, no gzip name or date.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu -C "$output" -cf - "$package" |
    gzip -n -9 > "$output/$package.tar.gz"
echo "$output/$package.tar.gz"
