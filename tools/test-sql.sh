#!/usr/bin/env bash
# Quoted PostgreSQL subset: runtime bindings, compile-time rejection, and editor expansion.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export ABLA_SYSROOT="$root"
cd "$root"
out="$root/build/sql-test"
mkdir -p "$out"
for name in smoke values grammar bounds stable; do
    "$compiler" build "tests/cases/sql/$name.ab" -o "$out/$name" --fast --no-cache
    "$out/$name"
done
# Values must also survive optimized lowering and collection of temporary owners.
"$compiler" build tests/cases/sql/values.ab -o "$out/values-release" --no-cache
ABLA_GC_STRESS=1 "$out/values-release"
for tier in interp jit bridge; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build tests/cases/sql/staged.ab -o "$out/staged-$tier" --fast --no-cache
    "$out/staged-$tier"
done
# Cached source must still be checked after an edit at the same path.
cat > "$out/cache.ab" <<'ABLA'
import "abla/sql"
fun main: int { val q = $sql("SELECT 1"); 0 }
ABLA
"$compiler" build "$out/cache.ab" -o "$out/cache" --fast
sed -i 's/SELECT 1/SELECT FROM t/' "$out/cache.ab"
if "$compiler" build "$out/cache.ab" -o "$out/cache" --fast > "$out/cache.log" 2>&1; then
    echo 'SQL source edit reused a stale expansion' >&2; exit 1
fi
grep -F 'SQL at template byte' "$out/cache.log" >/dev/null
if [[ $(uname -s) == Linux ]]; then
    if readelf -d "$out/values-release" | grep NEEDED > /dev/null; then
        echo 'SQL runtime unexpectedly requires a shared library' >&2; exit 1
    fi
fi
rejected=0
reject() {
    local name=$1 expected=$2
    { echo 'import "abla/sql"'; cat; } > "$out/$name.ab"
    if "$compiler" build "$out/$name.ab" -o "$out/rejected" --no-cache --fast > "$out/$name.log" 2>&1; then
        echo "SQL unexpectedly accepted $name" >&2; exit 1
    fi
    grep -F "$expected" "$out/$name.log" >/dev/null || { cat "$out/$name.log"; exit 1; }
    rejected=$((rejected + 1))
}
reject cast 'each SQL value hole needs' <<'ABLA'
fun main: int { val q = $sql("SELECT ${1}"); 0 }
ABLA
reject multiple 'only one statement' <<'ABLA'
fun main: int { val q = $sql("SELECT 1; SELECT 2"); 0 }
ABLA
reject malformed 'SQL at template byte' <<'ABLA'
fun main: int { val q = $sql("SELECT FROM missing"); 0 }
ABLA
reject ddl 'outside the subset' <<'ABLA'
fun main: int { val q = $sql("DROP TABLE important"); 0 }
ABLA
reject manual 'manual positional parameters' <<'ABLA'
fun main: int { val q = $sql("SELECT \$1::integer, ${2}::integer"); 0 }
ABLA
reject identifier 'SQL at template byte' <<'ABLA'
fun main: int { val q = $sql("SELECT * FROM ${"table"}::text"); 0 }
ABLA
reject quoted 'not used as a typed expression' <<'ABLA'
fun main: int { val q = $sql("SELECT '${"unsafe"}::text'"); 0 }
ABLA
reject dollar_quoted 'not used as a typed expression' <<'ABLA'
fun main: int { val q = $sql("SELECT \$body\$${1}::integer\$body\$"); 0 }
ABLA
reject comment 'not used as a typed expression' <<'ABLA'
fun main: int { val q = $sql("SELECT 1 -- ${1}::integer\n"); 0 }
ABLA
reject dynamic 'expects a quoted string' <<'ABLA'
fun main: int { val text = "SELECT 1"; val q = $sql(text); 0 }
ABLA
reject boolean_uuid 'ablaSqlBindString' <<'ABLA'
fun main: int { val q = $sql("SELECT ${true}::uuid"); 0 }
ABLA
reject string_integer 'ablaSqlBindInteger' <<'ABLA'
fun main: int { val q = $sql("SELECT ${"3"}::integer"); 0 }
ABLA
reject array 'SQL at template byte' <<'ABLA'
fun main: int { val q = $sql("SELECT ${1}::integer[]"); 0 }
ABLA
reject unsupported 'unsupported SQL parameter type' <<'ABLA'
fun main: int { val q = $sql("SELECT ${1}::money"); 0 }
ABLA
reject comparison 'parenthesize chained SQL comparisons' <<'ABLA'
fun main: int { val q = $sql("SELECT 1=2=3"); 0 }
ABLA
reject default_value 'SQL at template byte' <<'ABLA'
fun main: int { val q = $sql("SELECT DEFAULT"); 0 }
ABLA
reject empty_identifier 'empty SQL identifier' <<'ABLA'
fun main: int { val q = $sql("SELECT \"\""); 0 }
ABLA
reject unterminated 'unterminated SQL quote' <<'ABLA'
fun main: int { val q = $sql("SELECT 'unfinished"); 0 }
ABLA
reject bad_part_index 'E_STRING_TEMPLATE_PART' <<'ABLA'
import "abla/compiler/parser"
compile fun badSqlPart(cursor: ParserCursor): SyntaxExpression {
    parserExpect(cursor, "(")
    val template = parserParseAblaExpression(cursor)
    parserExpect(cursor, ")")
    val bad = parserTemplatePartIsText(cursor, template, 999)
    syntaxBoolean(bad)
}
#compilerRegisterSubparser("badpart", badSqlPart)
fun main: int { val bad = $badpart("a${"literal"}b"); 0 }
ABLA
printf 'sql: 6 runtime checks, %s rejection checks passed\n' "$rejected"
ANALYSIS_TEST_FILTER=sql node tests/analysis-graph/session.mjs "$compiler"
