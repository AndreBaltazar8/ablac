#!/usr/bin/env bash
# The documentation module of the language's built-in types and members (stdlib/abla/builtins/declarations.ab) against the compiler: every
# member it declares is accepted, every member sema accepts on a built-in receiver is declared, and its types are the documented ones
# (tests/builtin-docs/check.mjs). Usage: tools/test-builtin-docs.sh [compiler]
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$root"
node tests/builtin-docs/check.mjs "$compiler"
