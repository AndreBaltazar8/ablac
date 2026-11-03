#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/path-home-test
mkdir -p "$out"
"$compiler" build tests/cases/path-home/main.ab -o "$out/main" --fast --no-cache
HOME='/tmp/abla custom home' ABLA_EXPECT_HOME='/tmp/abla custom home' "$out/main"
uid=$(id -u)
expected=$(awk -F: -v uid="$uid" '$3 ~ /^[0-9]+$/ && $3 + 0 == uid && $6 != "" { print $6; exit }' /etc/passwd)
expected=${expected:-'<none>'}
env -u HOME ABLA_EXPECT_HOME="$expected" "$out/main"
HOME='' ABLA_EXPECT_HOME="$expected" "$out/main"
echo 'homePath: HOME precedence and effective uid passwd fallback'
