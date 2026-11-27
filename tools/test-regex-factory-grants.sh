#!/usr/bin/env bash
# A `$regex` literal with named captures generates a capture module whose factory, `ablaRegexMakeNamed_<module>_<site>`, has a name any module
# can declare (#1139 area 1, round 5). The literal's `#` site used to call that factory by name, so a dependency whose transform generated a
# function of the same name had it reached from the root's site, with the root's grants; only the duplicate-name error stopped the build
# before it ran. Now only the stdlib Regex constructor runs at compile time and the factory is called at run time:
#   - forged: a dependency that declares and is granted nothing generates `compile fun ablaRegexMakeNamed_<key>` running a process; the
#     root grants itself nothing. The root's `#` site must not reach it (no compile.effect-denied naming it), and nothing runs;
#   - forged-granted: the same with the root granting itself process.io: nothing runs;
#   - plain: the literal without a forged factory still projects its captures (the control).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/regex-factory-grants"
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
fail() { echo "regex factory grants: $1" >&2; exit 1; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
mark="$out/MARK"
# dependency <case> <source of src/dep.ab>
dependency() {
    local directory="$out/$1/dep"
    mkdir -p "$directory/src"
    git -C "$directory" init --quiet --initial-branch=main
    git -C "$directory" config user.name 'Abla package test'
    git -C "$directory" config user.email 'abla-package-test@example.invalid'
    printf 'name = "dep"\nversion = "0.1.0"\nentry = "src/dep.ab"\n' > "$directory/abla.toml"
    printf '%s\n' "$2" > "$directory/src/dep.ab"
    git -C "$directory" add -A && git -C "$directory" commit --quiet -m dep
}
# application <case> <lines before main>: the root authorizes process.io in its manifest; `$regex` sits at offset 23 of `main`.
application() {
    local project="$out/$1/application"
    mkdir -p "$project/src"
    printf 'name = "grants-app"\nversion = "0.1.0"\nentry = "src/main.ab"\ncompileCapabilities = ["process.io"]\n' > "$project/abla.toml"
    printf 'compile fun dependencySource(): ImportSource = gitImportSource("dep", "%s", "branch", "main")\n' "$out/$1/dep" \
        > "$project/src/provider.ab"
    cat > "$project/src/main.ab" <<EOF
import "abla/io"
import "abla/regex"
import "provider.ab"
import dependencySource()
$2
fun main {
    val r = \$regex("(?<x>a+)b")
    val m = r.matchFull("aab")
    val x = m?.x ?? "none"
    println("value \${dependencyValue()} capture \$x")
}
EOF
}
build() {
    local project="$out/$1/application"
    status=0
    { "$compiler" package update --project "$project" &&
      "$compiler" build --project "$project" --fast --no-cache --offline &&
      "$project/build/grants-app"; } > "$out/$1.log" 2>&1 || status=$?
}
# forger <case>: the dependency's transform generates the factory's name for <case>'s root.
forger() {
    local name
    name="ablaRegexMakeNamed_$(hex "$out/$1/application/src/main.ab")_$(hex main_23)"
    printf '%s\n' 'import "abla/compiler"' 'compile fun configure(): void {' \
        "    compilerGenerateModule(\"forged\", \"import \\\"abla/compiler\\\"\\nimport \\\"abla/regex\\\"\\ncompile fun $name(regex: Regex): Regex {\\n    compilerRunProcess([\\\"/bin/sh\\\", \\\"-c\\\", \\\"touch $mark\\\"])\\n    regex\\n}\\n\")" \
        '    return' '}' '#compiler.transform(configure)' 'fun dependencyValue(): string = "d"'
}

dependency forged "$(forger forged)"
application forged ''
build forged
[[ ! -e $mark ]] || fail "forged: the dependency's factory ran"
! grep -q 'ablaRegexMakeNamed_[0-9a-f_]*->compilerRunProcess' "$out/forged.log" ||
    fail "forged: the root's \$regex site reaches the dependency's function: $(grep -m1 'effect-denied' "$out/forged.log")"
grep -q 'ablaRegexMakeNamed_' "$out/forged.log" ||
    fail "forged: the build did not see the forged name (status $status): $(head -c 600 "$out/forged.log")"

dependency forged-granted "$(forger forged-granted)"
application forged-granted $'import "abla/compiler"\n#compilerGrant("process.io")'
build forged-granted
[[ ! -e $mark ]] || fail "forged-granted: the dependency's factory ran with the root's process.io"

dependency plain 'fun dependencyValue(): string = "d"'
application plain ''
build plain
[[ $status == 0 ]] && grep -q 'value d capture aa' "$out/plain.log" ||
    fail "plain: the literal did not project its capture (status $status): $(head -c 600 "$out/plain.log")"
echo "regex factory grants: a dependency's function of the factory's name is not reached from the root's \$regex site"
