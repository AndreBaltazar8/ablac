#!/usr/bin/env bash
# Project-private names survive checkout relocation and entry path aliases.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$root/build/ablac}
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
work=$(mktemp -d "$root/build/project-path-symbols-XXXXXX")
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
unset ABLA_KEEP_LLVM_TEXT ABLA_LLVM_OUT_OF_PROCESS
trap 'if [[ $? -ne 0 ]]; then echo "project path symbols: artifacts and logs: $work" >&2; fi' EXIT
fail() { echo "project path symbols: $1" >&2; exit 1; }
macos_sdk=1
[[ $(uname -s) == Darwin || -n ${ABLA_MACOS_SDK:-} ]] || macos_sdk=0

# invoke LABEL CWD [MISSING_SDK] -- ARG...: run the compiler there with its own cache
# directory; stdout is $work/LABEL.out and stderr $work/LABEL.log.
invoke() {
    local label=$1 cwd=$2 missing_sdk=$3 status=0
    shift 4
    (cd "$cwd" && ABLA_CACHE_DIR="$work/cache/$label" "$compiler" "$@" > "$work/$label.out" 2> "$work/$label.log") || status=$?
    if [[ $missing_sdk == 1 ]]; then
        [[ $status -eq 159 ]] && grep -qF 'error[E_MACOS_SDK]' "$work/$label.log" \
            || { cat "$work/$label.log" >&2; fail "$label: expected the missing-SDK refusal, got $status"; }
    else
        [[ $status -eq 0 ]] || { cat "$work/$label.log" >&2; fail "$label returned $status"; }
    fi
}

# check_artifacts LABEL CWD ENTRY REFDIR: build IR and objects for the entry and require
# them to equal the first set recorded in REFDIR. The IR file is left in $work/LABEL.ll.
check_artifacts() {
    local label=$1 cwd=$2 entry=$3 refdir=$4 target flags missing kind
    local artifacts="$work/artifacts-$label"
    mkdir -p "$artifacts" "$refdir"
    invoke "$label-ir" "$cwd" 0 -- --emit-llvm "$entry"
    cp "$work/$label-ir.out" "$artifacts/ir"
    cp "$work/$label-ir.out" "$work/$label.ll"
    for target in native fast macos; do
        case $target in
            native) flags='' ;;
            fast) flags='--fast --no-debug' ;;
            macos) flags='--target arm64-macos' ;;
        esac
        missing=0
        [[ $target == macos && $macos_sdk -eq 0 ]] && missing=1
        rm -f "$work/program.o" "$work/program.o.ll"
        # shellcheck disable=SC2086
        invoke "$label-$target" "$cwd" "$missing" -- build "$entry" -o "$work/program.o" --emit object --no-cache $flags
        if [[ $target == macos ]]; then
            grep -qaF 'arm64-apple-macosx' "$work/program.o.ll" || fail "$label: the macOS IR has no arm64-apple-macosx triple"
            cp "$work/program.o.ll" "$artifacts/macos-ir"
        fi
        [[ $missing -eq 1 ]] || cp "$work/program.o" "$artifacts/$target"
    done
    if [[ ! -e $refdir/ir ]]; then
        cp "$artifacts"/* "$refdir/"
    else
        for kind in $(ls "$artifacts"); do
            cmp -s "$artifacts/$kind" "$refdir/$kind" || fail "$label: $kind differs"
        done
    fi
}

run_entry() {
    local label=$1 cwd=$2 entry=$3 status=0
    invoke "$label" "$cwd" 0 -- build "$entry" -o "$work/program" --fast --no-cache
    (cd "$cwd" && "$work/program") || status=$?
    [[ $status -eq 42 ]] || fail "$label: wrong lexical sibling ($status, expected 42)"
}

# private_symbols IR VALUE: the abla_fn_* functions whose body returns VALUE.
private_symbols() {
    awk -v value="$2" '
        /^define / && match($0, /@abla_fn_[^(]+\(/) && /\{$/ { name = substr($0, RSTART + 1, RLENGTH - 2); inside = 1; next }
        inside && /^\}/ { inside = 0 }
        inside && $0 ~ ("(^|[^A-Za-z0-9_])ret i64 " value "([^A-Za-z0-9_]|$)") { print name }
    ' "$1" | sort -u
}

n=0
for name in s a-much-longer-checkout-directory; do
    checkout="$work/$name"
    source="$checkout/src"
    mkdir -p "$source"
    printf 'name = "project-path-symbols"\nentry = "src/main.ab"\n' > "$checkout/abla.toml"
    for pair in left:190001 right:230003; do
        printf 'private fun secret(): int = %s\nfun read(): int {\n    val callback: () -> int = secret\n    callback()\n}\n' \
            "${pair#*:}" > "$source/${pair%%:*}.ab"
    done
    cat > "$source/main.ab" <<'AB'
import "left.ab" as left
import "right.ab" as right
private fun secret(): int = 0
fun main: int {
    val callback: () -> int = { left.read() + right.read() + secret() }
    if (callback() == 420004) 42 else 1
}
AB
    # A directory alias preserves the lexical package structure. A file
    # alias beside src/ would intentionally have a different import base.
    link="$work/checkout-link-$n"
    ln -s "$checkout" "$link"
    spelling=0
    for entry in src/main.ab "$source/main.ab" ./src/./main.ab "$link/src/main.ab"; do
        label="$n-$spelling"
        check_artifacts "$label" "$checkout" "$entry" "$work/reference"
        # Same spelling/signature in two different modules remains distinct.
        left_symbols=$(private_symbols "$work/$label.ll" 190001)
        right_symbols=$(private_symbols "$work/$label.ll" 230003)
        [[ -n $left_symbols && -n $right_symbols ]] || fail "$label: a private function is missing from the IR"
        [[ -z $(printf '%s\n%s\n' "$left_symbols" "$right_symbols" | sort | uniq -d) ]] \
            || fail "$label: the two private functions share a symbol"
        spelling=$((spelling + 1))
    done
    invoke "$n-run" "$checkout" 0 -- build "$source/main.ab" -o "$work/program" --fast --no-cache
    status=0
    (cd "$checkout" && "$work/program") || status=$?
    [[ $status -eq 42 ]] || fail "$n: the program returned $status"
    for scenario in entry-directory dependency-directory entry-manifest; do
        # Keep manifest-less layouts outside the normal fixture package;
        # otherwise an unrelated ancestor abla.toml changes their identity root.
        case_dir="$work/lexical/$name/$scenario"
        tree="$case_dir/tree"
        real="$case_dir/real"
        mkdir -p "$tree/app" "$tree/lib" "$real/app/server" "$real/app/deps" "$real/lib"
        printf 'private fun secret(): int = 42\nfun read(): int = secret()\n' > "$tree/lib/lib.ab"
        printf 'private fun secret(): int = 13\nfun read(): int = secret()\n' > "$real/lib/lib.ab"
        if [[ $scenario == dependency-directory ]]; then
            printf 'import "../../lib/lib.ab" as sibling\nfun read(): int = sibling.read()\n' > "$real/app/deps/dependency.ab"
            ln -s "$real/app/deps" "$tree/app/deps"
            printf 'import "deps/dependency.ab" as dependency\nfun main: int = dependency.read()\n' > "$tree/app/main.ab"
            relative=main.ab
        else
            printf 'import "../../lib/lib.ab" as sibling\nfun main: int = sibling.read()\n' > "$real/app/server/main.ab"
            ln -s "$real/app/server" "$tree/app/server"
            relative=server/main.ab
        fi
        if [[ $scenario == entry-manifest ]]; then
            # Only the lexical root is valid. Looking up the physical
            # manifest must fail independently of import-base selection.
            printf 'name = "lexical-root"\n' > "$tree/app/abla.toml"
            printf 'name = "physical-root"\n[imports]\n"./absent.ab" = "./also-absent.ab"\n' > "$real/app/abla.toml"
        fi
        cwd="$tree/app"
        tree_link="$work/tree-link-$n-$scenario"
        ln -s "$tree" "$tree_link"
        spelling=0
        for entry in "$relative" "$cwd/$relative" "./$relative" "$tree_link/app/$relative"; do
            label="$n-$scenario-$spelling"
            run_entry "$label-run" "$cwd" "$entry"
            check_artifacts "$label" "$cwd" "$entry" "$work/lexical-reference-$scenario"
            spelling=$((spelling + 1))
        done
    done
    n=$((n + 1))
done
trap - EXIT
rm -rf "$work"
echo "project path symbols: exact IR, native release/fast-no-debug objects and arm64-macOS IR at two checkout lengths, relative/absolute/./directory-alias entries; distinct private symbols, lexical entry/dependency symlinks and root manifest selection passed$([[ $macos_sdk -eq 1 ]] || echo ' (published Mach-O objects skipped: no SDK)')"
