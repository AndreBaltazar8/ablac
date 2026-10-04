#!/usr/bin/env bash
# A module value first demanded while lowering (through an extension method call)
# initializes after the values its initializer reads, not before them.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
output_root=$project_root/build/global-init-order-test
mkdir -p "$output_root"
cd "$project_root/tests/cases/global-init-order"
"$compiler" build main.ab -o "$output_root/global-init-order" --no-cache
"$output_root/global-init-order"
echo "global init order: initializers see the values they read"
