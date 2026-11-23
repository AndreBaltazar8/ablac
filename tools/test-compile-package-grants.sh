#!/usr/bin/env bash
# Compile capabilities are granted per package, not per program (#1142 F1; module.ab, bootstrapPlanCompilePackageGrants;
# ct_native.ab, ctNativeGrantsAt). Before, the grants were the union of every module's #compilerGrant ∩ the root's
# compileCapabilities, so a dependency that declared nothing and wrote `#compilerGrant("environment")` read the
# compiler's environment whenever the root granted `environment` to its own code; the same held for filesystem access,
# processes, the network and trusted.native. Each case is a root project that authorizes a capability for itself and
# a git dependency (direct, or a dependency of a dependency) whose `#` code uses it:
#   - direct, transitive: the dependency requests `environment` without declaring it: refused
#     (E_COMPILE_CAPABILITY_UNDECLARED), and the probe variable's value is in no output;
#   - declared, transitive-declared: the dependency declares it in its abla.toml: granted, the value is read;
#   - native: a dependency declaring trusted.native gets it only by name ([dependencyCompileCapabilities]): refused
#     without the line, granted with it while abla.lock pins the package;
#   - unpinned: a named grant for a package abla.lock doesn't lock is refused (E_PACKAGE_CAPABILITY_UNPINNED);
#   - path-import: a module the project imports by path from outside its tree is the project's own code, granted;
#   - path-callee: a dependency's site calling into such a module is judged by the dependency's grants: refused;
#   - path-escape: a file only a dependency reaches (a path out of its copy) is the dependency's: refused as undeclared;
#   - jit-reader, jit-native: with the root's environment and trusted.native in the native tier's generation, a
#     dependency's site that reads the environment or calls C is refused in analysis, before anything runs.
#   - process, network: process.io and network are named-only too (#112 A): declared and authorized, still refused
#     without the named line; process.io granted with it;
#   - absolute, own-tree: a dependency's filesystem.read reads its own tree; an absolute path outside it is
#     E_BUILD_PATH_OUTSIDE unless the root names filesystem.read for it.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/compile-package-grants"
rm -rf "$out"
mkdir -p "$out"
export ABLA_PACKAGE_CACHE="$out/cache"
export ABLA_GRANT_PROBE=probe-value-7c1
fail() { echo "compile-package-grants: $1" >&2; exit 1; }

# repository <directory> <name> <declared capabilities, a TOML array's inside> <source of src/<name>.ab>
repository() {
    local directory=$1 name=$2 declared=$3 source=$4
    mkdir -p "$directory/src"
    git -C "$directory" init --quiet --initial-branch=main
    git -C "$directory" config user.name 'Abla package test'
    git -C "$directory" config user.email 'abla-package-test@example.invalid'
    printf 'name = "%s"\nversion = "0.1.0"\nentry = "src/%s.ab"\n' "$name" "$name" > "$directory/abla.toml"
    [[ -z $declared ]] || printf 'compileCapabilities = [%s]\n' "$declared" >> "$directory/abla.toml"
    printf '%s\n' "$source" > "$directory/src/$name.ab"
}
commit() { git -C "$1" add -A && git -C "$1" commit --quiet -m "$2"; }
# provider <file> <function> <name> <repository>: a compile function naming the git dependency.
provider() {
    printf 'compile fun %s(): ImportSource = gitImportSource("%s", "%s", "branch", "main")\n' "$2" "$3" "$4" > "$1"
}
# application <case> <compileCapabilities inside> <dependency name> <extra manifest lines>: the root project, whose main
# prints what the dependency's `dependencyValue()` holds.
application() {
    local case=$1 capabilities=$2 dependency=$3 extra=${4:-}
    local project="$out/$case/application"
    mkdir -p "$project/src"
    printf 'name = "grants-app"\nversion = "0.1.0"\nentry = "src/main.ab"\ncompileCapabilities = [%s]\n%s\n' \
        "$capabilities" "$extra" > "$project/abla.toml"
    provider "$project/src/provider.ab" dependencySource "$dependency" "$out/$case/$dependency"
    cat > "$project/src/main.ab" <<'EOF'
import "abla/io"
import "provider.ab"
import dependencySource()
fun main { println("dependency value: '${dependencyValue()}'") }
EOF
}
# build <case>: package update, then the build, its status in $status and everything they printed in $out/<case>.log.
build() {
    local project="$out/$1/application"
    status=0
    { "$compiler" package update --project "$project" &&
      "$compiler" build --project "$project" --fast --no-cache --offline &&
      "$project/build/grants-app"; } > "$out/$1.log" 2>&1 || status=$?
}
refused() {
    local case=$1 code=$2
    build "$case"
    [[ $status != 0 ]] && grep -q "$code" "$out/$case.log" ||
        fail "$case: not refused with $code (status $status): $(grep -m3 'error\|value' "$out/$case.log")"
    ! grep -rq "$ABLA_GRANT_PROBE" "$out/$case.log" "$out/$case/application/build" 2>/dev/null ||
        fail "$case: the dependency read the probe variable"
}
granted() {
    local case=$1 expected=$2
    build "$case"
    [[ $status == 0 ]] || fail "$case: refused (status $status): $(grep -m3 'error' "$out/$case.log")"
    grep -q "dependency value: '$expected'" "$out/$case.log" ||
        fail "$case: the dependency's value is not '$expected': $(grep -m2 'value' "$out/$case.log")"
}

reader='import "abla/compiler"
#compilerGrant("environment")
val taken = #compilerEnvironment("ABLA_GRANT_PROBE")
fun dependencyValue: string = taken'

# A direct dependency that requests what it doesn't declare.
repository "$out/direct/quiet-dep" quiet-dep '' "$reader"
commit "$out/direct/quiet-dep" dependency
application direct '"environment"' quiet-dep
refused direct E_COMPILE_CAPABILITY_UNDECLARED
grep -q "dependency 'quiet-dep'" "$out/direct.log" || fail "direct: the refusal doesn't name the dependency"

# The same, declared: the root allows it what it declares.
repository "$out/declared/quiet-dep" quiet-dep '"environment"' "$reader"
commit "$out/declared/quiet-dep" dependency
application declared '"environment"' quiet-dep
granted declared "$ABLA_GRANT_PROBE"

# A dependency of a dependency: the middle one declares and requests nothing, the leaf reads without declaring.
middle_source() {
    provider "$1/src/leaf-provider.ab" leafSource deep-dep "$2"
    printf '%s\n' 'import "leaf-provider.ab"' 'import leafSource()' 'fun dependencyValue: string = leafValue()' \
        > "$1/src/middle-dep.ab"
}
leaf_reader='import "abla/compiler"
#compilerGrant("environment")
val taken = #compilerEnvironment("ABLA_GRANT_PROBE")
fun leafValue: string = taken'
repository "$out/transitive/deep-dep" deep-dep '' "$leaf_reader"
commit "$out/transitive/deep-dep" leaf
repository "$out/transitive/middle-dep" middle-dep '' ''
middle_source "$out/transitive/middle-dep" "$out/transitive/deep-dep"
commit "$out/transitive/middle-dep" middle
application transitive '"environment"' middle-dep
refused transitive E_COMPILE_CAPABILITY_UNDECLARED
grep -q "dependency 'deep-dep'" "$out/transitive.log" || fail "transitive: the refusal doesn't name the leaf dependency"

repository "$out/transitive-declared/deep-dep" deep-dep '"environment"' "$leaf_reader"
commit "$out/transitive-declared/deep-dep" leaf
repository "$out/transitive-declared/middle-dep" middle-dep '' ''
middle_source "$out/transitive-declared/middle-dep" "$out/transitive-declared/deep-dep"
commit "$out/transitive-declared/middle-dep" middle
application transitive-declared '"environment"' middle-dep
granted transitive-declared "$ABLA_GRANT_PROBE"

# trusted.native only by name, and only for a pinned package.
native='import "abla/compiler"
#compilerGrant("trusted.native")
noescape extern:"c" fun strlen(text: cstring): int
val measured = #strlen("four")
fun dependencyValue: string = "${measured}"'
repository "$out/native/native-dep" native-dep '"trusted.native"' "$native"
commit "$out/native/native-dep" dependency
application native '"trusted.native"' native-dep
build native
[[ $status != 0 ]] && grep -q 'trusted.native' "$out/native.log" ||
    fail "native: a dependency got trusted.native without a named grant (status $status)"
cp -r "$out/native" "$out/native-named"
rm -rf "$out/native-named/application/.abla" "$out/native-named/application/abla.lock"
application native-named '"trusted.native"' native-dep "$(printf '[dependencyCompileCapabilities]\nnative-dep = ["trusted.native"]')"
granted native-named 4

application unpinned '"trusted.native"' native-dep "$(printf '[dependencyCompileCapabilities]\nother-dep = ["trusted.native"]')"
cp -r "$out/native/native-dep" "$out/unpinned/native-dep"
refused unpinned E_PACKAGE_CAPABILITY_UNPINNED

# A sibling checkout the project imports by path (outside its tree, no package's copy) is the project's own code: its
# #compilerGrant counts as the root's, and its sites get the root's grants (as abla-mobile's android_build.ab, imported
# by path by its users).
mkdir -p "$out/path-import/application/src" "$out/path-import/shared"
printf 'name = "grants-app"\nversion = "0.1.0"\nentry = "src/main.ab"\ncompileCapabilities = ["environment"]\n' \
    > "$out/path-import/application/abla.toml"
cat > "$out/path-import/shared/reader.ab" <<'EOF'
import "abla/compiler"
#compilerGrant("environment")
val taken = #compilerEnvironment("ABLA_GRANT_PROBE")
fun dependencyValue: string = taken
EOF
cat > "$out/path-import/application/src/main.ab" <<'EOF'
import "abla/io"
import "../../shared/reader.ab"
fun main { println("dependency value: '${dependencyValue()}'") }
EOF
status=0
{ "$compiler" build --project "$out/path-import/application" --fast --no-cache &&
  "$out/path-import/application/build/grants-app"; } > "$out/path-import.log" 2>&1 || status=$?
[[ $status == 0 ]] && grep -q "dependency value: '$ABLA_GRANT_PROBE'" "$out/path-import.log" ||
    fail "path-import: a module the project imports by path didn't get the project's grants (status $status): $(grep -m3 'error\|value' "$out/path-import.log")"

# Such a module is the root's, but a dependency's own site that calls into it is judged by the dependency's grants:
# the root grants filesystem.write and imports the writer, the dependency (which declares nothing) calls it at compile
# time: refused at the dependency's site, nothing written.
mkdir -p "$out/path-callee/shared"
cat > "$out/path-callee/shared/writer.ab" <<'EOF'
import "abla/compiler"
import "abla/fs"
#compilerGrant("filesystem.write")
fun writeMark(name: string): string {
    path(name).writeText("x")
    name
}
EOF
repository "$out/path-callee/quiet-dep" quiet-dep '' "import \"$out/path-callee/shared/writer.ab\"
val taken = #writeMark(\"dependency-mark.txt\")
fun dependencyValue: string = taken"
commit "$out/path-callee/quiet-dep" dependency
application path-callee '"filesystem.write"' quiet-dep
sed -i '1i import "../../shared/writer.ab"' "$out/path-callee/application/src/main.ab"
refused path-callee compile.effect-denied
[[ -z $(find "$out/path-callee" -name dependency-mark.txt) ]] || fail "path-callee: the dependency's site wrote through the root's module"

# A file only a dependency reaches, by a path out of its copy, is that dependency's code, never the root's: its request
# is the dependency's, refused as undeclared. (The path is absolute: a relative one out of the copy is read against the
# cache's copy at `package update`, another directory, and refused there when nothing is at it.)
mkdir -p "$out/path-escape/elsewhere"
cat > "$out/path-escape/elsewhere/tool.ab" <<'EOF'
import "abla/compiler"
#compilerGrant("environment")
val toolValue = #compilerEnvironment("ABLA_GRANT_PROBE")
fun dependencyValue: string = toolValue
EOF
repository "$out/path-escape/quiet-dep" quiet-dep '' "import \"$out/path-escape/elsewhere/tool.ab\""
commit "$out/path-escape/quiet-dep" dependency
application path-escape '"environment"' quiet-dep
refused path-escape E_COMPILE_CAPABILITY_UNDECLARED
grep -q "tool.ab' of dependency 'quiet-dep'" "$out/path-escape.log" ||
    fail "path-escape: the escaped module wasn't counted as the dependency's: $(grep -m2 error "$out/path-escape.log")"
# The native tier: the root grants itself environment and trusted.native, so the JIT's generation gets the compiler's
# environment and the root's libraries (ct_jit.ab, bootstrapCtSetEnvironment, bootstrapCtNativeLibraries). A dependency
# that requests nothing can't use either: its sites are refused in analysis (compile.effect-denied), before any runs,
# whether they read the environment through the library or call C directly.
jit_reader='import "abla/sys/linux/process"
val taken = #linuxEnvironment("ABLA_GRANT_PROBE").value
fun dependencyValue: string = taken'
jit_native='noescape extern:"c" fun getenv(name: cstring): cstring
noescape extern:"c" fun strlen(text: cstring): int
val taken = #strlen(getenv("ABLA_GRANT_PROBE"))
fun dependencyValue: string = "${taken}"'
for kind in reader native; do
    case=jit-$kind
    source=$jit_reader
    [[ $kind == native ]] && source=$jit_native
    repository "$out/$case/quiet-dep" quiet-dep '' "$source"
    commit "$out/$case/quiet-dep" dependency
    application "$case" '"environment", "trusted.native"' quiet-dep
    # The root's own site holds both grants, so the generation is made with them.
    cat >> "$out/$case/application/src/main.ab" <<'EOF'
import "abla/compiler"
#compilerGrant("environment")
#compilerGrant("trusted.native")
noescape extern:"c" fun strlen(text: cstring): int
val own = #strlen(compilerEnvironment("HOME"))
EOF
    ABLA_COMPILE_EVAL=jit refused "$case" compile.effect-denied
done

# process.io and network, like trusted.native, only by name (#112 A): declared by the dependency and authorized by the
# root, still refused without the named line; process.io granted with it.
runner='import "abla/compiler"
#compilerGrant("process.io")
val status = #compilerRunProcess(["true"])
fun dependencyValue: string = "ran ${status}"'
repository "$out/process/process-dep" process-dep '"process.io"' "$runner"
commit "$out/process/process-dep" dependency
application process '"process.io"' process-dep
build process
[[ $status != 0 ]] && grep -q 'effect-denied:process.io' "$out/process.log" ||
    fail "process: a dependency got process.io without a named grant (status $status)"
cp -r "$out/process" "$out/process-named"
rm -rf "$out/process-named/application/.abla" "$out/process-named/application/abla.lock"
application process-named '"process.io"' process-dep "$(printf '[dependencyCompileCapabilities]\nprocess-dep = ["process.io"]')"
granted process-named 'ran 0'

caller='import "abla/compiler"
#compilerGrant("network")
val reply = #compilerTcpExchange("127.0.0.1", 9, "probe", 16, 100)
fun dependencyValue: string = "called"'
repository "$out/network/network-dep" network-dep '"network"' "$caller"
commit "$out/network/network-dep" dependency
application network '"network"' network-dep
build network
[[ $status != 0 ]] && grep -q 'effect-denied:network' "$out/network.log" ||
    fail "network: a dependency got network without a named grant (status $status)"

# A dependency's filesystem.read reaches its own tree; an absolute path outside it only by name (#112 A). The secret is
# a file of the machine outside every project here; the dependency also reads its own src/own.txt by a relative path.
printf 'absolute-secret-5d2' > "$out/absolute-secret.txt"
reader_of() {
    printf 'import "abla/compiler"\nimport "abla/fs"\n#compilerGrant("filesystem.read")\ncompile fun take(): string = path("own.txt").readText() + "+" + path("%s").readText()\nval taken = #take()\nfun dependencyValue: string = taken\n' "$1"
}
repository "$out/absolute/read-dep" read-dep '"filesystem.read"' "$(reader_of "$out/absolute-secret.txt")"
printf 'own' > "$out/absolute/read-dep/src/own.txt"
commit "$out/absolute/read-dep" dependency
application absolute '"filesystem.read"' read-dep
build absolute
[[ $status != 0 ]] && grep -q 'E_BUILD_PATH_OUTSIDE' "$out/absolute.log" && grep -q 'dependencyCompileCapabilities' "$out/absolute.log" ||
    fail "absolute: a dependency read an absolute path without a named filesystem.read (status $status): $(grep -m3 'error\|value' "$out/absolute.log")"
! grep -rq 'absolute-secret-5d2' "$out/absolute.log" "$out/absolute/application/build" 2>/dev/null ||
    fail "absolute: the secret reached the build"
cp -r "$out/absolute" "$out/absolute-named"
rm -rf "$out/absolute-named/application/.abla" "$out/absolute-named/application/abla.lock"
application absolute-named '"filesystem.read"' read-dep "$(printf '[dependencyCompileCapabilities]\nread-dep = ["filesystem.read"]')"
granted absolute-named 'own+absolute-secret-5d2'
# Its own tree without a name: the relative read alone is granted.
repository "$out/own-tree/read-dep" read-dep '"filesystem.read"' 'import "abla/compiler"
import "abla/fs"
#compilerGrant("filesystem.read")
compile fun take(): string = path("own.txt").readText()
val taken = #take()
fun dependencyValue: string = taken'
printf 'own' > "$out/own-tree/read-dep/src/own.txt"
commit "$out/own-tree/read-dep" dependency
application own-tree '"filesystem.read"' read-dep
granted own-tree own

echo "compile-package-grants: a dependency's compile capabilities are its own package's (direct and transitive, declared or refused); process.io, network and trusted.native only by a named, pinned grant; a dependency's absolute reads only by a named filesystem.read"
