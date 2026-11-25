#!/usr/bin/env bash
# The provider code of a dependency runs while the lock is made, before any pin (#1139 area 2, round 3). `package update` evaluates the `compile fun`s a
# dependency's own source uses as import providers, and gave all of them the root's whole `compileCapabilities`: a dependency that declared nothing ran
# processes and wrote files the first time the root authorized them for itself. A dependency's provider code now has its own manifest's list within the
# root's, and never process.io, network or trusted.native (those are named by the root for a pinned package, and there is no pin yet).
#   - undeclared: the dependency declares nothing, the root authorizes process.io and filesystem.write: nothing runs, the update is refused;
#   - named-only: the dependency declares process.io, the root authorizes it: the process does not run;
#   - declared: the dependency declares filesystem.write, the root authorizes it: the provider's write happens (the control: not everything is denied).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/package-provider-effects"
rm -rf "$out"
mkdir -p "$out"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$out/gitconfig"
fail() { echo "package provider effects: $1" >&2; exit 1; }
g() { git -C "$1" -c user.name=t -c user.email=t@example.invalid "${@:2}"; }
mkrepo() { mkdir -p "$1/src"; git -C "$1" init -q --initial-branch=main; }
next="$out/next"; mkrepo "$next"
printf 'name = "next"\nversion = "0.1.0"\nentry = "src/next.ab"\n' > "$next/abla.toml"
printf 'fun nextValue: string = "n"\n' > "$next/src/next.ab"
g "$next" add -A; g "$next" commit -q -m next
# attempt <case> <root capabilities> <dependency manifest line> <provider body>: prints nothing, leaves $status and the markers
attempt() {
    local dir="$out/$1"; mkdir -p "$dir"
    export ABLA_PACKAGE_CACHE="$dir/cache"
    local hostile="$dir/hostile"; mkrepo "$hostile"
    printf 'name = "hostile"\nversion = "0.1.0"\nentry = "src/hostile.ab"\n%s\n' "$3" > "$hostile/abla.toml"
    cat > "$hostile/src/hostile.ab" <<EOT
import "abla/compiler"
compile fun chain(): ImportSource {
$4
    return gitImportSource("next", "$next", "branch", "main")
}
import chain()
fun dependencyValue: string = "ok"
EOT
    g "$hostile" add -A; g "$hostile" commit -q -m hostile
    local app="$dir/app"; mkdir -p "$app/src"
    printf 'name = "app"\nversion = "0.1.0"\nentry = "src/main.ab"\ncompileCapabilities = [%s]\n' "$2" > "$app/abla.toml"
    printf 'compile fun src(): ImportSource = gitImportSource("hostile", "%s", "branch", "main")\n' "$hostile" > "$app/src/provider.ab"
    printf 'import "abla/io"\nimport "provider.ab"\nimport src()\nfun main { println("v") }\n' > "$app/src/main.ab"
    status=0
    "$compiler" package update --project "$app" > "$dir/update.log" 2>&1 || status=$?
}
mark="$out/MARK"
attempt undeclared '"process.io", "filesystem.write"' '' "    val ran = compilerRunProcess([\"/bin/sh\", \"-c\", \"touch $mark-process\"])
    val wrote = compilerWriteFile(\"$mark-write\", \"x\")"
[[ ! -e $mark-process && ! -e $mark-write ]] || fail "undeclared: the dependency's provider ran with the root's capabilities ($(ls "$mark"* | tr '\n' ' '))"
[[ $status != 0 ]] || fail "undeclared: the update went through"
attempt named-only '"process.io", "filesystem.write"' 'compileCapabilities = ["process.io", "filesystem.write"]' "    val ran = compilerRunProcess([\"/bin/sh\", \"-c\", \"touch $mark-process\"])"
[[ ! -e $mark-process ]] || fail "named-only: a dependency's provider ran a process without a named, pinned grant"
rm -f "$mark-write"
attempt declared '"filesystem.write"' 'compileCapabilities = ["filesystem.write"]' "    val wrote = compilerWriteFile(\"$mark-write\", \"x\")"
[[ -e $mark-write ]] || fail "declared: the provider's declared and authorized write did not happen ($(grep -m2 error "$out/declared/update.log"))"
echo "package provider effects: a dependency's provider code has its own declared capabilities within the root's, never process.io, network or trusted.native, while the lock is made"
