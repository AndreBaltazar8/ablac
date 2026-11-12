#!/usr/bin/env bash
# Formatter CLI, syntax-field drift guards and deliberate preservation failures.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/formatter-tests"
rm -rf "$out"
mkdir -p "$out"
cases="$root/tests/cases/formatter"
CR=$(printf '\r')

fail() { echo "formatter: $*" >&2; exit 1; }

# fmt STATUS STDIN OUTPUT ARGS...: run `fmt`, require the exit status, keep stdout.
fmt() {
    local want=$1 input=$2 output=$3 status=0
    shift 3
    "$compiler" fmt "$@" < "$input" > "$output" 2> "$out/stderr" || status=$?
    [[ $status -eq $want ]] || { cat "$out/stderr" >&2; fail "fmt $* returned $status, expected $want"; }
}
is() { printf "%b" "$2" > "$out/is.expected"; cmp -s "$1" "$out/is.expected" || fail "$3"; }
same() { cmp -s "$1" "$2" || fail "$3"; }
mode() { ls -l "$1" | cut -c1-10; }

for fixture in "$cases"/*.input.ab; do
    name=${fixture##*/}
    expected="$cases/${name/.input./.expected.}"
    fmt 0 "$fixture" "$out/formatted" -
    same "$out/formatted" "$expected" "$name: output differs from golden"
    fmt 0 "$out/formatted" "$out/again" -
    same "$out/again" "$out/formatted" "$name: formatting is not idempotent"
    differs=0
    cmp -s "$fixture" "$out/formatted" || differs=1
    fmt "$differs" "$fixture" "$out/check" --check -
    if [[ $differs -eq 1 ]]; then [[ -s "$out/check" ]] || fail "$name: --check - printed no diff"
    else [[ ! -s "$out/check" ]] || fail "$name: --check - printed a diff for formatted input"; fi
    target="$out/$name"
    cp "$fixture" "$target"
    chmod 600 "$target"
    fmt "$differs" /dev/null "$out/diff" --check "$target"
    if [[ -s "$out/diff" ]]; then
        git apply --check --unsafe-paths -p0 - < "$out/diff" || fail "$name: --check diff does not apply"
    elif [[ $differs -eq 1 ]]; then
        fail "$name: --check on a file printed no diff"
    fi
    same "$target" "$fixture" "$name: --check modified the file"
    fmt 0 /dev/null "$out/none" "$target"
    same "$target" "$expected" "$name: in-place format differs from golden"
    [[ $(mode "$target") == -rw------- ]] || fail "$name: mode changed to $(mode "$target")"
    fmt 0 /dev/null "$out/check2" --check "$target"
    [[ ! -s "$out/check2" ]] || fail "$name: --check printed a diff after formatting"
    echo "formatter: ${name%.input.ab} golden, stdin, check, idempotence and mode passed"
done

# Formatting is a parser-only command, independent of an installed sysroot.
printf 'fun main:int=0\n' > "$out/short.ab"
status=0
(cd "$out" && env -u ABLA_SYSROOT -u ABLA_STDLIB "$compiler" fmt - < short.ab > sysroot.out 2> sysroot.err) || status=$?
[[ $status -eq 0 ]] || { cat "$out/sysroot.err" >&2; fail "fmt without a sysroot returned $status"; }
is "$out/sysroot.out" 'fun main: int = 0\n' "fmt without a sysroot printed the wrong output"

# One width setting, stable break priority, all breakable lines within width.
wide='fun main(): int = value0'
for ((i = 1; i < 40; i++)); do wide+=" + value$i"; done
printf '%s\n' "$wide" > "$out/wide.ab"
for width in 40 60 100 240; do
    fmt 0 "$out/wide.ab" "$out/w1" --width "$width" -
    LC_ALL=C awk -v w="$width" 'length($0) > w { exit 1 }' "$out/w1" || fail "width $width: a line is too long"
    fmt 0 "$out/w1" "$out/w2" --width "$width" -
    same "$out/w2" "$out/w1" "width $width: not idempotent"
done
printf '// %s\n' "$(printf 'unbreakable-comment-%.0s' {1..15})" > "$out/comment.ab"
fmt 0 "$out/comment.ab" "$out/w1" --width 40 -
same "$out/w1" "$out/comment.ab" "an unbreakable comment changed"
items='0'
for ((i = 1; i < 1000; i++)); do items+=", $i"; done
printf 'fun main(): int { val xs = [%s]; xs.size }\n' "$items" > "$out/array.ab"
fmt 0 "$out/array.ab" "$out/w1" --width 60 -
fmt 0 "$out/w1" "$out/w2" --width 60 -
same "$out/w2" "$out/w1" "long array: not idempotent"
# Generic type commas are not parameter separators and must remain on their line.
printf 'fun choose(first: Map<string, array<int>>, second: Map<string, array<int>>, third: int): int = third\n' > "$out/signature.ab"
fmt 0 "$out/signature.ab" "$out/w1" --width 40 -
grep -qF 'Map<string, array<int>>' "$out/w1" || fail "a generic type was split"
fmt 0 "$out/w1" "$out/w2" --width 40 -
same "$out/w2" "$out/w1" "generic signature: not idempotent"
echo 'formatter: width limits, long arrays, generic roles and unbreakable comments passed'

# Comment and raw-literal bytes must survive CRLFs exactly.
printf '/* exact\r\n  body */\r\nval x = """\r\n  raw\r\n  """\r\n' > "$out/raw.ab"
fmt 0 "$out/raw.ab" "$out/raw.out" -
# CR -> '<', LF -> '>' so the multi-line spans can be matched as one line.
tr '\r\n' '<>' < "$out/raw.out" > "$out/raw.flat"
grep -qF '/* exact<>  body */' "$out/raw.flat" || fail "CRLF comment bytes changed"
grep -qF '"""<>  raw<>  """' "$out/raw.flat" || fail "CRLF raw literal bytes changed"

# Build API modules are source, while generated build output stays untouched.
selection="$out/selection"
mkdir -p "$selection/stdlib/abla/build" "$selection/build"
printf 'fun main:int=0\n' > "$selection/stdlib/abla/build/entry.ab"
printf 'fun main:int=0\n' > "$selection/build/generated.ab"
fmt 0 /dev/null "$out/none" "$selection"
is "$selection/stdlib/abla/build/entry.ab" 'fun main: int = 0\n' "a build API module was not formatted"
is "$selection/build/generated.ab" 'fun main:int=0\n' "generated build output was touched"

# Newline-at-EOF diffs and exact opaque bytes, including CRLF raw/comment text.
eof=0
for text in '' '\n\n' 'fun main:int=0' '// comment\r\nfun main:int=0\r\n' \
            '/* exact\r\n  body */\r\nfun main:int=0\r\n'; do
    eof=$((eof + 1))
    printf "$text" > "$out/eof$eof.ab"
    fmt 0 "$out/eof$eof.ab" "$out/w1" -
    fmt 0 "$out/w1" "$out/w2" -
    same "$out/w2" "$out/w1" "newline case $eof: not idempotent"
done

valid="$out/000-valid.ab"
invalid="$out/999-invalid.ab"
printf 'fun main:int=0\n' > "$valid"
printf 'fun broken( {\n' > "$invalid"
fmt 2 /dev/null "$out/w1" "$valid" "$invalid"
[[ ! -s "$out/w1" ]] || fail "invalid input produced stdout"
fmt 2 "$invalid" "$out/w1" -
[[ ! -s "$out/w1" ]] || fail "invalid stdin produced stdout"
is "$valid" 'fun main:int=0\n' "a valid file was written beside an invalid one"
is "$invalid" 'fun broken( {\n' "an invalid file was written"
fmt 2 /dev/null "$out/w1" --width 0 "$valid"
fmt 2 /dev/null "$out/w1" --unknown "$valid"
: > "$out/empty"
fmt 2 "$out/empty" "$out/w1" - "$valid"
ln -s 000-valid.ab "$out/symbolic.ab"
fmt 2 /dev/null "$out/w1" "$out/symbolic.ab"
[[ -L "$out/symbolic.ab" ]] || fail "a symbolic link was replaced"
is "$valid" 'fun main:int=0\n' "a symbolic link target was rewritten"

# This guard fails when a new parser field has no explicit comparison policy.
# check_fields PARSER FORMATTER: print every field with no comparison policy.
check_fields() {
    local parser=$1 formatter=$2 cls function positions field
    while IFS='|' read -r cls function positions; do
        awk -v cls="$cls" '
            $0 ~ "^class " cls "\\(" { inside = 1; next }
            inside && /^\)/ { exit }
            inside && match($0, /^[ \t]*(val|var)[ \t]+[A-Za-z0-9_]+:/) {
                s = substr($0, RSTART, RLENGTH); sub(/^[ \t]*(val|var)[ \t]+/, "", s); sub(/:$/, "", s); print s
            }' "$parser" > "$out/fields"
        [[ -s "$out/fields" ]] || echo "$cls: no fields found"
        awk -v f="fun $function(" '
            !started && index($0, f) { started = 1; print; next }
            started && /^fun / { exit }
            started { print }' "$formatter" > "$out/function-body"
        [[ -s "$out/function-body" ]] || echo "$function: body not found"
        while read -r field; do
            case " $positions " in *" $field "*) continue ;; esac
            grep -qF "left.$field" "$out/function-body" && grep -qF "right.$field" "$out/function-body" \
                || echo "$cls.$field"
        done < "$out/fields"
    done <<'LIST'
BootstrapExpression|bootstrapFormatExpressionEqual|begin end
BootstrapDeclaration|bootstrapFormatDeclarationEqual|begin end generatedOriginBegin generatedOriginEnd annotationBegins annotationEnds
BootstrapParseResult|bootstrapFormatAstEqual|stackDepthStoppedSources
LIST
}
unguarded=$(check_fields "$root/src/parser.ab" "$root/src/formatter.ab")
[[ -z $unguarded ]] || fail "parser fields without a formatter comparison policy: $unguarded"
# Negative control: a parser copy with one extra field must be reported.
sed 's/^class BootstrapExpression(/&\n    val driftProbe: int,/' "$root/src/parser.ab" > "$out/parser-drift.ab"
[[ $(check_fields "$out/parser-drift.ab" "$root/src/formatter.ab") == 'BootstrapExpression.driftProbe' ]] \
    || fail "the parser-field guard missed an added field"

program="$out/guard"
"$compiler" build "$cases/guard.ab" -o "$program" --fast --no-cache
expected_files=$(find "$root/src" "$root/stdlib" -name '*.ab' | wc -l | tr -d ' ')
status=0
ABLA_FORMATTER_EXPECTED_FILES=$expected_files "$program" || status=$?
[[ $status -eq 42 ]] || fail "preservation negatives returned $status"
echo 'formatter: token/AST/comment/idempotence negative controls and invalid-input no-write passed'

# Execute both sides of the newline-sensitive control fixture too.
for suffix in input expected; do
    "$compiler" build "$cases/control.$suffix.ab" -o "$out/control-$suffix" --fast --no-cache
    status=0
    "$out/control-$suffix" > "$out/control-$suffix.out" 2> "$out/control-$suffix.err" || status=$?
    [[ $status -eq 2 && ! -s "$out/control-$suffix.out" && ! -s "$out/control-$suffix.err" ]] \
        || fail "control $suffix returned $status or printed output"
done
echo 'formatter: original/formatted control-flow executions agree'
