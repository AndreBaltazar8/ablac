#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/regex-literals
mkdir -p "$out"
for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/regex/literal.ab \
        --no-cache --fast -o "$out/main-$tier"
    [[ $("$out/main-$tier") == ok ]]
    ABLA_GC_STRESS=1 "$out/main-$tier" | grep -x ok >/dev/null
    for name in invalid-literal invalid-literal-expression invalid-literal-interpolation invalid-literal-named invalid-literal-escape invalid-literal-multiline; do
        log="$out/$name-$tier.log"
        if ABLA_COMPILE_EVAL=$tier "$compiler" build "tests/cases/regex/$name.ab" \
            --no-cache --fast -o "$out/invalid" >"$log" 2>&1; then
            echo "$name ($tier): unexpectedly compiled" >&2; exit 1
        fi
        message='expected a plain string literal in $regex'
        [[ $name != invalid-literal ]] || message='invalid $regex at pattern byte 0: missing ]'
        [[ $name != invalid-literal-named ]] || message="invalid \$regex at pattern byte 13: duplicate capture name 'name'"
        if [[ $name == invalid-literal-escape || $name == invalid-literal-multiline ]]; then
            message='invalid $regex at pattern byte 2: unknown escape'
        fi
        grep -Fx "error[E_SUBPARSER_FAILURE]: $message" "$log" >/dev/null || { cat "$log"; exit 1; }
        grep -F 'E_SUBPARSER_FAILURE' "$log" >/dev/null || { cat "$log"; exit 1; }
        [[ $(grep -c 'E_SUBPARSER_FAILURE' "$log") == 1 ]]
        # parserFail is at the closing parenthesis, inside the literal site.
        position=$(LC_ALL=C awk '
            index($0, "$regex(") {literal=1}
            literal && /\)$/ {print n+length($0)-1; exit}
            {n+=length($0)+1}
        ' "tests/cases/regex/$name.ab")
        grep -E "source\[subparser\]:.*$name.ab:$position:$position$" "$log" >/dev/null || { cat "$log"; exit 1; }
    done
done
"$compiler" build tests/cases/regex/literal.ab --no-cache -o "$out/main-release"
[[ $("$out/main-release") == ok ]]
echo 'regex literals: ok'
