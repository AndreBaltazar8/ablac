#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/path-directory-mode-test
mkdir -p "$out"
"$compiler" build tests/cases/path-directory-mode/main.ab -o "$out/main" --fast --no-cache
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/existing"
chmod 711 "$scratch/existing"
(umask 027; ABLA_DIRECTORY_TEST_ROOT="$scratch" "$out/main")
mode_of() {
    if [[ $(uname -s) == Darwin ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}
for path in existing/first existing/first/second; do
    [[ $(mode_of "$scratch/$path") == 700 ]] || { echo "incorrect mode: $path" >&2; exit 1; }
done
for path in default default/child; do
    [[ $(mode_of "$scratch/$path") == 750 ]] || { echo "incorrect mode: $path" >&2; exit 1; }
done
[[ $(mode_of "$scratch/existing") == 711 ]]
echo 'createDirectories: mode applies to all new components under umask; existing unchanged'
