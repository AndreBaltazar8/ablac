#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/path-file-mode-test
mkdir -p "$out"
"$compiler" build tests/cases/path-file-mode/main.ab -o "$out/main" --fast --no-cache
mode_of() {
    if [[ $(uname -s) == Darwin ]]; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}
prepare() {
    mkdir -p "$1"
    printf old > "$1/existing"
    printf old > "$1/existing-atomic"
    chmod 640 "$1/existing" "$1/existing-atomic"
    printf old > "$1/recreated"
    chmod 640 "$1/recreated"
}
check() {
    local dir=$1 default=$2
    for name in secret atomic; do [[ $(mode_of "$dir/$name") == 600 ]]; done
    [[ $(mode_of "$dir/default") == "$default" ]]
    for name in existing existing-atomic; do
        [[ $(mode_of "$dir/$name") == 640 ]]
        [[ $(cat "$dir/$name") == new ]]
    done
    [[ ! -e "$dir/invalid" && ! -e "$dir/invalid-atomic" ]]
    [[ $(cat "$dir/secret") == secret && $(cat "$dir/atomic") == atomic ]]
}
for mask in 000 022 077; do
    dir="$out/native-$mask"
    rm -rf "$dir"
    prepare "$dir"
    (umask "$mask"; ABLA_FILE_MODE_ROOT="$dir" "$out/main")
    default=666
    [[ $mask != 022 ]] || default=644
    [[ $mask != 077 ]] || default=600
    check "$dir" "$default"
    [[ $(mode_of "$dir/zero") == 0 ]]
    all=777
    [[ $mask != 022 ]] || all=755
    [[ $mask != 077 ]] || all=700
    [[ $(mode_of "$dir/all") == "$all" ]]
done
# The staged provider must retain mode through rewrites/moves, and preserve
# existing modes even when publication runs with a more restrictive umask.
dir="$out/staged"
rm -rf "$dir"
prepare "$dir"
printf 'compileCapabilities = ["filesystem.read", "filesystem.write"]\n' > "$out/abla.toml"
cat > "$out/staged.ab" <<'ABLA'
import "abla/fs"
import "abla/compiler"
#compilerGrant("filesystem.read")
#compilerGrant("filesystem.write")
compile fun writeFiles(): bool {
    val root = Path("build/path-file-mode-test/staged")
    val secret = root.child("secret")
    if (!secret.writeText("first", mode = 0o600)) return false
    if (!secret.writeText("secret", mode = 0o666)) return false
    if (!root.child("move-source").writeText("atomic", mode = 0o600)) return false
    if (!root.child("move-source").moveTo(root.child("atomic"))) return false
    if (!root.child("default").writeText("default")) return false
    if (!root.child("existing").writeText("new", mode = 0o600)) return false
    if (!root.child("existing-atomic").writeTextAtomic("new", mode = 0o600)) return false
    if (root.child("existing").writeText("bad", mode = -1)) return false
    if (root.child("existing-atomic").writeTextAtomic("bad", mode = 0o1000)) return false
    if (root.child("invalid/child").writeText("bad", mode = 0o4000)) return false
    if (root.child("invalid-atomic/child").writeTextAtomic("bad", mode = 0o2000)) return false
    val recreated = root.child("recreated")
    if (!recreated.writeText("old", mode = 0o666)) return false
    if (!recreated.remove()) return false
    if (!recreated.writeText("private", mode = 0o600)) return false
    true
}
val staged = #writeFiles()
fun main: int = if (staged) 0 else 1
ABLA
for evaluator in interp jit; do
  for mask in 000 077; do
    rm -rf "$dir"
    prepare "$dir"
    (umask "$mask"; ABLA_COMPILE_EVAL=$evaluator "$compiler" build "$out/staged.ab" -o "$out/staged-main" --fast --no-cache)
    "$out/staged-main"
    default=666
    [[ $mask != 077 ]] || default=600
    check "$dir" "$default"
    [[ ! -e "$dir/move-source" ]]
    [[ $(mode_of "$dir/recreated") == 600 && $(cat "$dir/recreated") == private ]]
  done
done
# A later compile-time error must discard a staged secret.
cat > "$out/failed.ab" <<'ABLA'
import "abla/fs"
import "abla/compiler"
#compilerGrant("filesystem.write")
val staged = #Path("build/path-file-mode-test/not-published").writeText("secret", mode = 0o600)
fun fail(zero: int): int = 10 / zero
val broken = #fail(0)
fun main: int = 0
ABLA
rm -f "$out/not-published"
if "$compiler" build "$out/failed.ab" -o "$out/failed" --fast --no-cache > "$out/failed.log" 2>&1; then
    echo 'failed staged write unexpectedly built' >&2; exit 1
fi
grep -q 'E_EVAL_DIVISION_BY_ZERO' "$out/failed.log"
[[ ! -e "$out/not-published" ]]
# Host staging remains available while the Wasm runtime has no filesystem.
"$compiler" build tests/cases/path-file-mode/wasm-build.ab -o "$out/wasm-build" --fast --no-cache
"$out/wasm-build"
[[ $(mode_of "$out/wasm-host") == 600 && $(cat "$out/wasm-host") == 'host secret' ]]
node --disable-wasm-trap-handler --input-type=module - "$out/mode.wasm" <<'JS'
import { readFileSync } from 'node:fs';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = WebAssembly.Module.imports(module);
if (imports.some(x => /file|open|chmod/.test(x.name))) throw Error('unexpected filesystem import');
const { exports } = new WebAssembly.Instance(module, { abla_host: { write: () => { throw Error("unexpected host write"); } } });
if (exports.check() !== 42n) throw Error('Wasm filesystem behavior changed');
JS
echo 'file creation modes: native, staged interp/JIT, failed build discard and Wasm; umask, rewrites, moves and existing targets'
