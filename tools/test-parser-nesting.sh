#!/usr/bin/env bash
# The parser is recursive: a file of thousands of open parentheses, nested blocks or `else if` links used to end the compiler with "panic: stack overflow",
# and an editor's analysis service with it (#1139 programme, hostile project opened in an editor). Past 1000 levels of nesting or 2500 links of an else-if
# chain the parser now reports one E_PARSE_NESTING error; below them the files build, and the analysis service answers either way.
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
build() { (cd "$t/$1" && "$compiler" build --project . -o out --fast --no-cache > build.log 2>&1); }
service() { # service NAME: initialize, analyze, shutdown; true when it answered all three
    printf '%s\n%s\n%s\n' "{\"schema\":1,\"id\":1,\"method\":\"initialize\",\"params\":{\"workspaceRoots\":[\"$t/$1\"],\"clientName\":\"t\",\"clientVersion\":\"1\",\"analysisMode\":\"graph-v2\"}}" '{"schema":1,"id":2,"method":"analyze","params":{}}' '{"schema":1,"id":3,"method":"shutdown","params":{}}' |
        (cd "$t/$1" && timeout 120 "$compiler" analyze --stdio > service.json 2> service.err) || true
    [ "$(wc -l < "$t/$1/service.json")" = 3 ]
}
refused() { # refused NAME: the build says E_PARSE_NESTING (and does not crash), and the service answers
    if build "$1"; then fail "$1: built"; return; fi
    grep -q 'E_PARSE_NESTING' "$t/$1/build.log" || fail "$1: no E_PARSE_NESTING: $(head -c 150 "$t/$1/build.log" | tr '\n' ' ')"
    service "$1" || fail "$1: the analysis service did not answer: $(head -c 100 "$t/$1/service.err")"
}
accepted() { build "$1" || fail "$1: did not build: $(head -c 150 "$t/$1/build.log" | tr '\n' ' ')"; }
chain() { printf 'fun f(x: int): int {\n    if (x == 0) 0\n'; local i; for ((i = 1; i <= $1; i++)); do printf '    else if (x == %s) %s\n' "$i" "$i"; done; printf '    else -1\n}\nfun main: int = f(3)\n'; }

{ printf 'fun main: int = '; rep '(' 900; printf 1; rep ')' 900; echo; } | project parens-900
{ printf 'fun main: int = '; rep '(' 1100; printf 1; rep ')' 1100; echo; } | project parens-1100
{ printf 'fun main: int = '; rep '(' 100000; printf 1; rep ')' 100000; echo; } | project parens-100000
{ printf 'fun main: int {\n'; rep 'if (true) {\n' 400; printf '1\n'; rep '}\n' 400; printf '0\n}\n'; } | project blocks-400
{ printf 'fun main: int {\n'; rep 'if (true) {\n' 5000; printf '1\n'; rep '}\n' 5000; printf '0\n}\n'; } | project blocks-5000
chain 2000 | project chain-2000
chain 2600 | project chain-2600
chain 20000 | project chain-20000
accepted parens-900
accepted blocks-400
accepted chain-2000
refused parens-1100
refused parens-100000
refused blocks-5000
refused chain-2600
refused chain-20000
service parens-900 || fail "parens-900: the analysis service did not answer"

[ "$failures" = 0 ] || { printf 'parser nesting: %d failure(s)\n' "$failures" >&2; exit 1; }
echo "parser nesting: deep nesting and long else-if chains are one E_PARSE_NESTING error, not a stack overflow; the service answers"
