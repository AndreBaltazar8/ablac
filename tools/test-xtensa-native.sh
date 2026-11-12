#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-native-test"
if [[ -d $out ]]; then chmod -R u+w "$out"; rm -rf "$out"; fi
mkdir -p "$out"
"$compiler" build "$root/tools/xtensa-native/main.ab" --fast --no-cache -o "$out/installer"
mkdir -p "$out/slow/bin" "$out/flood/bin"
printf '#!/bin/sh\nsleep 5\n' > "$out/slow/bin/opt"
chmod +x "$out/slow/bin/opt"
printf '#!/bin/sh\nhead -c 1100000 /dev/zero\n' > "$out/flood/bin/opt"
chmod +x "$out/flood/bin/opt"
"$compiler" build "$root/tests/cases/xtensa-native/unit.ab" --fast --no-cache -o "$out/unit"
"$out/unit" "$out/slow" "$out/flood"
python3 "$root/tests/cases/xtensa-native/test.py" "$out/installer" "$out/fixtures"
