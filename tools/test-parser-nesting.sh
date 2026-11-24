#!/usr/bin/env bash
# The parser is recursive: a file of thousands of open parentheses, nested blocks or `else if` links used to end the compiler with "panic: stack overflow",
# and an editor's analysis service with it (#1139 programme, hostile project opened in an editor). Past 1000 levels of nesting or 2500 links of an else-if
# chain the parser now reports one E_PARSE_NESTING error; the depths used by real code (here 900, 400 and 2000) are analyzed in one service session.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$project_root/build"
t=$(mktemp -d "$project_root/build/parser-nesting.XXXXXX")
trap 'rm -rf -- "$t"' EXIT
export ABLA_SYSROOT=$project_root
failures=0
fail() { printf 'parser nesting: %s\n' "$1" >&2; failures=$((failures + 1)); }
rep() { local i; for ((i = 0; i < $2; i++)); do printf "$1"; done; }
project() { mkdir -p "$t/$1"; printf 'name = "t"\nentry = "main.ab"\n' > "$t/$1/abla.toml"; cat > "$t/$1/main.ab"; }
chain() { printf 'fun f(x: int): int {\n    if (x == 0) 0\n'; local i; for ((i = 1; i <= $1; i++)); do printf '    else if (x == %s) %s\n' "$i" "$i"; done; printf '    else -1\n}\n'; }
parens() { printf 'fun g: int = '; rep '(' "$1"; printf 1; rep ')' "$1"; echo; }
blocks() { printf 'fun h: int {\n'; rep 'if (true) {\n' "$1"; printf '1\n'; rep '}\n' "$1"; printf '0\n}\n'; }
service() { # service NAME: initialize, analyze, shutdown; the replies are in service.json
    printf '%s\n%s\n%s\n' "{\"schema\":1,\"id\":1,\"method\":\"initialize\",\"params\":{\"workspaceRoots\":[\"$t/$1\"],\"clientName\":\"t\",\"clientVersion\":\"1\",\"analysisMode\":\"graph-v2\"}}" '{"schema":1,"id":2,"method":"analyze","params":{}}' '{"schema":1,"id":3,"method":"shutdown","params":{}}' |
        (cd "$t/$1" && timeout 120 "$compiler" analyze --stdio > service.json 2> service.err) || true
    [ "$(wc -l < "$t/$1/service.json")" = 3 ]
}
refused() { # refused NAME: the build says E_PARSE_NESTING, without crashing
    if (cd "$t/$1" && "$compiler" build --project . -o out --fast --no-cache > build.log 2>&1); then fail "$1: built"; return; fi
    grep 'E_PARSE_NESTING' "$t/$1/build.log" > /dev/null || fail "$1: no E_PARSE_NESTING: $(head -c 150 "$t/$1/build.log" | tr '\n' ' ')"
}

# What real code nests, all in one file: analyzed, with no nesting error, in one session.
{ parens 900; blocks 400; chain 2000; echo 'fun main: int = 0'; } | project under
service under || fail "under: the analysis service did not answer"
if grep 'E_PARSE_NESTING\|NESTING' "$t/under/service.json" > /dev/null; then fail "under: depths below the limits were refused"; fi
# Just over each limit, one file per construct, and the extreme that used to overflow the stack.
{ parens 1100; echo 'fun main: int = 0'; } | project over-parens
{ blocks 1100; echo 'fun main: int = 0'; } | project over-blocks
{ chain 2600; echo 'fun main: int = 0'; } | project over-chain
{ parens 100000; echo 'fun main: int = 0'; } | project extreme
refused over-parens
refused over-blocks
refused over-chain
refused extreme
service extreme || fail "extreme: the analysis service did not answer"

[ "$failures" = 0 ] || { printf 'parser nesting: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "parser nesting: deep nesting and long else-if chains are one E_PARSE_NESTING error, not a stack overflow; the service answers"
