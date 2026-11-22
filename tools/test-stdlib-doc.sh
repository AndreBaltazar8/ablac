#!/usr/bin/env bash
set -euo pipefail
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
cd "$project_root"
out=build/stdlib-doc-test
mkdir -p "$out/stdlib/abla/sample"
cat > "$out/stdlib/abla/sample/entry.ab" <<'AB'
import "abla/compiler"
import "abla/compiler/parser"
export import "abla/text"

/** A documented generic type. */
class Box<T>(val value: T) {
    // The contained value.
    fun get(): T = this.value
}

// Keep line breaks, parameter defaults and ownership spelling.
fun Box<int>.plus(
    amount: int = 3
): int { this.value + amount }

fun undocumented(): int = 17
private fun hidden(): int = 99
private class Hidden {
    fun hiddenMethod(): int = 1
}

// The sealed modifier and its original spacing are retained.
sealed    interface Named {
    fun label(): string
}

// A property receiver.
class Counter(val value: int)
// A mutable extension property; its generated default helper is not public API.
var Counter.tag: int = 0

// An alias.
type Number = int

// The parser handler.
compile fun sampleParser(cursor: ParserCursor): SyntaxExpression = syntaxInteger(7)
// The embedded language.
#compilerRegisterSubparser("sample", sampleParser)
// This must never execute during documentation.
val never = #compilerWriteFile("build/stdlib-doc-test/forbidden", "executed")
AB
cat > "$out/stdlib/abla/sample/helper.ab" <<'AB'
// Extra source file: its own import identity.
fun helper: int = 2
AB
{ printf '/** '; printf '%05000d' 0; printf ' END_OF_LONG_DOCUMENTATION */\nfun longDocs(): int = 0\n'; } > "$out/stdlib/abla/long.ab"
rm -f "$out/forbidden"
"$compiler" doc --stdlib "$out/stdlib/" --output "$out/docs" --coverage-debt "$out/debt.tsv" > "$out/coverage.txt"
[[ ! -e $out/forbidden ]]
page=$(cat "$out/docs/abla/sample.md")
[[ $page == *'class Box<T>(val value: T)'* ]]
[[ $page == *'## `Box.get` (method)'* ]]
[[ $page == *'fun get(): T'* ]]
[[ $page == *$'fun Box<int>.plus(\n    amount: int = 3\n): int\n'* ]]
[[ $page == *'type Number = int'* ]]
[[ $page == *'sealed    interface Named'* && $page == *'The sealed modifier'* ]]
[[ $page == *'var Counter.tag: int'* && $page != *'__abla_default_'* ]]
[[ $page == *'## `$sample` (sub-language)'* ]]
[[ $page == *'#compilerRegisterSubparser("sample", sampleParser)'* ]]
[[ $page == *'A documented generic type.'* ]]
[[ $page == *'The contained value.'* ]]
[[ $page == *'Re-exports `abla/text`.'* ]]
[[ $page != *hidden* && $page != *'this.value + amount'* && $page != *'syntaxInteger(7)'* ]]
[[ $(cat "$out/docs/abla/long.md") == *END_OF_LONG_DOCUMENTATION* ]]
cat > "$out/expected.json" <<'JSON'
{"schemaVersion":1,"modules":[{"module":"abla/long","documented":1,"undocumented":0,"total":1},{"module":"abla/sample","documented":10,"undocumented":2,"total":12},{"module":"abla/sample/helper","documented":1,"undocumented":0,"total":1}],"totals":{"documented":12,"undocumented":2,"total":14}}
JSON
cmp "$out/expected.json" "$out/docs/coverage.json"
[[ $(cut -f 1,2 "$out/debt.tsv") == $'abla/sample\tundocumented\nabla/sample\tNamed.label' ]]
cp "$out/docs/coverage.json" "$out/first.json"
cp "$out/docs/abla/sample.md" "$out/first.md"
"$compiler" doc --stdlib "$out/stdlib" --output "$out/docs" > "$out/coverage.txt"
cmp "$out/first.json" "$out/docs/coverage.json"
cmp "$out/first.md" "$out/docs/abla/sample.md"

# The undocumented count stays the same when one legacy declaration gains a
# comment and a different overload is added without a comment.
sed 's/^fun undocumented/\/\/ Returns seventeen.\nfun undocumented/' "$out/stdlib/abla/sample/entry.ab" > "$out/edited.ab"
mv "$out/edited.ab" "$out/stdlib/abla/sample/entry.ab"
printf '\nfun undocumented(value: int): int = value\n' >> "$out/stdlib/abla/sample/entry.ab"
"$compiler" doc --stdlib "$out/stdlib" --output "$out/docs" --coverage-debt "$out/changed.tsv" > "$out/coverage.txt"
grep -Fq '"totals":{"documented":13,"undocumented":2,"total":15}' "$out/docs/coverage.json"
LC_ALL=C sort "$out/changed.tsv" > "$out/changed.sorted"
LC_ALL=C sort "$out/debt.tsv" > "$out/debt.sorted"
LC_ALL=C comm -23 "$out/changed.sorted" "$out/debt.sorted" > "$out/new.tsv"
[[ $(cut -f 1,2 "$out/new.tsv") == $'abla/sample\tundocumented' ]]
printf 'fun broken(\n' > "$out/stdlib/abla/broken.ab"
if "$compiler" doc --stdlib "$out/stdlib" --output "$out/bad" > "$out/bad.log" 2>&1; then
    echo 'stdlib-doc: malformed module unexpectedly accepted' >&2
    exit 1
fi
rm "$out/stdlib/abla/broken.ab"
if "$compiler" doc --stdlib "$out/missing" --output "$out/bad" > "$out/bad.log" 2>&1; then exit 1; fi
if "$compiler" doc --unknown > "$out/bad.log" 2>&1; then exit 1; fi
echo 'stdlib-doc: exact signatures, public surface, docs, coverage, no evaluation and errors passed'
