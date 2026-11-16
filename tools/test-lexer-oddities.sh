#!/usr/bin/env bash
# Odd source text the lexer and parser used to take badly: a malformed string escape is reported over the whole escape (it
# covered two bytes), a block comment that is never closed is E_PARSE_UNTERMINATED_COMMENT at its `/*`.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/lexer-oddities
rm -rf "$out"
mkdir -p "$out"

# $1 = file text; prints the diagnostics of a build that must fail
fails() {
    printf '%s' "$1" > "$out/case.ab"
    if "$compiler" build "$out/case.ab" -o "$out/case" --fast --no-cache > "$out/case.log" 2>&1; then
        echo "lexer oddities: accepted: $1" >&2; exit 1
    fi
}

# A malformed escape at the start of a string's text: the span is the backslash up to the end of the escape.
escape_span() { # $1 = escape text, $2 = its length in bytes
    fails $'fun main: int {\n    val s = "'"$1"$'|"\n    0\n}\n'
    grep -Fq 'error[E_PARSE_INVALID_ESCAPE]' "$out/case.log" || { echo "lexer oddities: $1 lacks E_PARSE_INVALID_ESCAPE" >&2; cat "$out/case.log" >&2; exit 1; }
    grep -Fq "case.ab:29:$((29 + $2))" "$out/case.log" || { echo "lexer oddities: $1 span is not 29:$((29 + $2))" >&2; cat "$out/case.log" >&2; exit 1; }
}
escape_span '\u{110000}' 10
escape_span '\u{D800}' 8
escape_span '\xZZ' 4
escape_span '\x4' 3
escape_span '\u12' 4
escape_span '\u{}' 4
escape_span '\q' 2

# A block comment that is never closed: one error, at its `/*` (it said "expected token `}`, found `end`").
unterminated() { # $1 = text after the first 24 bytes
    fails $'fun main: int {\n    0\n}\n'"$1"
    grep -Fq 'error[E_PARSE_UNTERMINATED_COMMENT]' "$out/case.log" || { echo "lexer oddities: unterminated comment lacks E_PARSE_UNTERMINATED_COMMENT" >&2; cat "$out/case.log" >&2; exit 1; }
    grep -Fq "case.ab:24:26" "$out/case.log" || { echo "lexer oddities: unterminated comment is not at 24:26" >&2; cat "$out/case.log" >&2; exit 1; }
    [[ $(grep -c '^error\[' "$out/case.log") -eq 1 ]] || { echo "lexer oddities: more than one error for an unterminated comment" >&2; cat "$out/case.log" >&2; exit 1; }
}
unterminated '/* never closed'
unterminated $'/* outer /* inner */ still open\n'
unterminated '/*'
# One that is inside a function body, with code after it.
fails $'fun main: int {\n    /* open\n    0\n}\n'
grep -Fq 'error[E_PARSE_UNTERMINATED_COMMENT]' "$out/case.log" || { echo "lexer oddities: a comment open in a body lacks E_PARSE_UNTERMINATED_COMMENT" >&2; cat "$out/case.log" >&2; exit 1; }
grep -Fq "case.ab:20:22" "$out/case.log" || { echo "lexer oddities: a comment open in a body is not at 20:22" >&2; cat "$out/case.log" >&2; exit 1; }

echo "lexer oddities: malformed escapes are reported over the whole escape, an unterminated comment at its start"
