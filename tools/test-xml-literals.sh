#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
compiler=${1:-build/ablac}
out=build/xml-literals
mkdir -p "$out"
source=tests/cases/xml-literal/main.ab
for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$source" --fast --no-cache -o "$out/$tier"
    [[ $("$out/$tier") == ok ]]
done
while IFS=$'\t' read -r markup diagnostic; do
    cat > "$out/invalid.ab" <<ABLA
import "abla/xml"
fun main {
    val invalid = \$xml $markup
}
ABLA
    if "$compiler" build "$out/invalid.ab" --fast --no-cache -o "$out/invalid" > "$out/error.log" 2>&1; then
        printf 'Invalid XML accepted: %s\n' "$markup" >&2
        exit 1
    fi
    rg -Fqx "error[E_SUBPARSER_FAILURE]: $diagnostic" "$out/error.log" || { cat "$out/error.log"; exit 1; }
    rg -q 'source\[subparser\]:.*invalid\.ab:[0-9]+:[0-9]+' "$out/error.log" || { cat "$out/error.log"; exit 1; }
done <<'CASES'
<a></b>	XML closing tag 'b' does not match 'a'
<p:a/>	undeclared or reserved XML element prefix 'p'
<a p:arg="v"/>	undeclared XML attribute prefix 'p'
<a p:id="1" q:id="2" xmlns:p="urn:test" xmlns:q="urn:test"/>	duplicate XML attribute 'q:id'
<a xmlns:xml="urn:wrong"/>	invalid XML namespace declaration: reserved_namespace_prefix
<a xmlns={value}/>	expected a quoted XML attribute value
<a>&other;</a>	unknown XML entity '&other;'
<a>&#0;</a>	invalid XML numeric character reference
<a><![CDATA[unfinished	expected ']]>' in XML literal
CASES
printf 'xml literals: ok\n'
