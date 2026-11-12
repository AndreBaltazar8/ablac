#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-directory
mkdir -p "$out/project" "$out/input"
cp tests/cases/compile-eval-directory/lookup.ab "$out/project/lookup.ab"
printf 'compileCapabilities = ["filesystem.read"]\n' > "$out/project/abla.toml"
rm -f "$out/input/"*
fail() { echo "compile-eval-directory: $1" >&2; exit 1; }
# apply_state STATE: mutate the watched directory and write the expected table bytes.
apply_state() {
    local d="$out/input" name
    case $1 in
        initial)
            # Create in reverse order, including a non-ASCII filename/content.
            printf zz > "$d/z.txt"; printf π > "$d/α.txt"; printf aa > "$d/a.txt" ;;
        create) printf mm > "$d/m.txt" ;;
        remove) rm "$d/z.txt" ;;
        rename) mv "$d/m.txt" "$d/n.txt" ;;
        content)
            # Same byte length and modification time.
            touch -r "$d/a.txt" "$out/a.stamp"
            printf bb > "$d/a.txt"
            touch -r "$out/a.stamp" "$d/a.txt"
            rm "$out/a.stamp" ;;
    esac
    : > "$out/expected.txt"
    for name in $(cd "$d" && LC_ALL=C ls); do
        printf '%s:%s\n' "$name" "$(cat "$d/$name")" >> "$out/expected.txt"
    done
}
# check_journal STATE MODE: the input journal names the directory and its entries, is a
# single file across states, is reused as is by a warm build and changes otherwise.
check_journal() {
    local state=$1 mode=$2 journals previous tag="$out/$1-$2-journal"
    journals=$(find "$out/cache-$mode" -name 'native-wasm32-module-*.inputs')
    [[ -n $journals && $(printf '%s\n' "$journals" | wc -l) -eq 1 ]] || fail "$tag: expected one journal, found: $journals"
    grep -qaF 'abla-input:entries:build/compile-eval-directory/input' "$journals" || fail "$tag: no directory input"
    grep -qaF 'build/compile-eval-directory/input/a.txt' "$journals" || fail "$tag: no entry input"
    { printf '%s\n' "$journals"; stat -c %y "$journals"; sha256sum "$journals" | cut -d' ' -f1; } > "$tag.snap"
    [[ $state != initial ]] || return 0
    case $state in warm) previous=initial ;; create) previous=warm ;; remove) previous=create ;;
        rename) previous=remove ;; content) previous=rename ;; esac
    [[ $(sed -n 1p "$tag.snap") == $(sed -n 1p "$out/$previous-$mode-journal.snap") ]] || fail "$tag: the journal path changed"
    if [[ $state == warm ]]; then
        cmp -s "$tag.snap" "$out/$previous-$mode-journal.snap" || fail "$tag: a warm build did not reuse the journal"
    else
        [[ $(sed -n 3p "$tag.snap") != $(sed -n 3p "$out/$previous-$mode-journal.snap") ]] || fail "$tag: the journal did not change"
    fi
}
# check_native_trace STATE LOG: the lookup site is native on every build but a warm one,
# and nothing is interpreted.
check_native_trace() {
    local position native
    position=$(grep -boa '#lookup()' "$out/project/lookup.ab" | head -n 1 | cut -d: -f1)
    native=$(awk -v tail="lookup.ab:$position" 'index($0, "note[ct-jit]: native at ") == 1 && substr($0, length($0) - length(tail) + 1) == tail' "$2" | wc -l)
    [[ $native -eq $([[ $1 == warm ]] && echo 0 || echo 1) ]] || fail "$2: $native native notes for $1"
    ! grep -qF 'interpreted at' "$2" || fail "$2: a site was interpreted"
}
# Each mode has a separate cache; every mutation reuses that mode's source,
# output and cache paths. Do not add --no-cache to these builds.
for mode in interp jit auto; do
    rm -rf "$out/cache-$mode"
done

for state in initial warm create remove rename content; do
    apply_state "$state"
    for mode in interp jit auto; do
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 \
            ABLA_CACHE_DIR="$root/$out/cache-$mode" "$compiler" build \
            tests/cases/compile-eval-directory/build.ab -o "$out/builder" --fast \
            > "$out/$state-$mode.log" 2>&1
        "$out/builder"
        cp "$out/table.wasm" "$out/$state-$mode.wasm"
        node --input-type=module - "$out/table.wasm" "$out/expected.txt" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]));
const e = instance.exports;
const bytes = Buffer.alloc(Number(e.tableSize()));
for (let i = 0; i < bytes.length; ++i) bytes[i] = Number(e.tableByte(BigInt(i)));
assert.deepEqual(bytes, fs.readFileSync(process.argv[3]));
NODE
        check_journal "$state" "$mode"
        if [[ $mode != interp ]]; then
            check_native_trace "$state" "$out/$state-$mode.log"
        fi
    done
    cmp "$out/$state-interp.wasm" "$out/$state-jit.wasm"
    cmp "$out/$state-interp.wasm" "$out/$state-auto.wasm"
done
cmp "$out/initial-jit.wasm" "$out/warm-jit.wasm"
for pair in create:warm remove:create rename:remove content:rename; do
    state=${pair%:*}
    previous=${pair#*:}
    if cmp -s "$out/$previous-jit.wasm" "$out/$state-jit.wasm"; then
        echo "directory mutation $state did not change the module" >&2; exit 1
    fi
done

# Revoke the same child source's filesystem grant with caches still populated.
printf 'compileCapabilities = []\n' > "$out/project/abla.toml"
if ABLA_COMPILE_EVAL=jit ABLA_CACHE_DIR="$root/$out/cache-jit" "$compiler" build \
    tests/cases/compile-eval-directory/build.ab -o "$out/builder" --fast \
    > "$out/denied.log" 2>&1; then
    echo 'directory table reused a revoked filesystem grant' >&2; exit 1
fi
grep -q 'compile.capability-not-authorized:filesystem.read' "$out/denied.log"
echo 'directory compile-time table: native parity, stable sorting, journal invalidation and revocation passed'
