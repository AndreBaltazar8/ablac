#!/usr/bin/env bash
# Opt-in live network test; the normal suite has no network dependency.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) host=x86_64-linux ;;
    Darwin-arm64) host=arm64-macos ;;
    Darwin-x86_64) host=x86_64-macos ;;
    *) echo 'unsupported host' >&2; exit 1 ;;
esac
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-native-download"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/xtensa-native/download.ab" --no-cache -o "$out/test"
"$out/test" "$root/tools/xtensa-companions.json" "$host"
