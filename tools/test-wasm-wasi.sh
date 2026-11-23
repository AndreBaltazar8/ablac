#!/usr/bin/env bash
# Run Preview 1 commands under an independent WASI host.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
runtime=${ABLA_WASMTIME:-wasmtime}
if ! command -v "$runtime" >/dev/null; then
    echo 'wasm-wasi: skipped (wasmtime not installed)'
    exit 0
fi
out=build/wasm-wasi
mkdir -p "$out"
printf 'input line\n' > "$out/input"
printf 'hello from WASI\n' > "$out/hello.expected"
printf 'return:two words\nfirst:second\n' > "$out/return.expected"
printf 'exit:two words\nfirst:second\n' > "$out/exit.expected"
printf 'input line\n' > "$out/stderr.expected"
printf 'first\nsecond\n' > "$out/files.expected"
printf 'outside the preopen\n' > "$out/outside.txt"
for profile in release fast; do
    flags=()
    [[ $profile == release ]] || flags+=(--fast)
    for program in hello command files; do
        "$compiler" build "tests/cases/wasm-wasi/$program.ab" --target wasm32-wasi \
            --no-debug --no-cache "${flags[@]}" -o "$out/$program-$profile.wasm"
    done
    "$runtime" run "$out/hello-$profile.wasm" > "$out/hello.stdout" 2> "$out/hello.stderr"
    cmp "$out/hello.expected" "$out/hello.stdout"
    [[ ! -s $out/hello.stderr ]] || { cat "$out/hello.stderr" >&2; exit 1; }
    for mode in return exit; do
        arguments=("$mode" 'two words')
        expected=7
        if [[ $mode == exit ]]; then
            arguments+=(extra)
            expected=9
        fi
        actual=0
        "$runtime" run --env ABLA_WASI_FIRST=first --env ABLA_WASI_SECOND=second --env ABLA_WASI_EMPTY= \
            "$out/command-$profile.wasm" "${arguments[@]}" \
            < "$out/input" > "$out/command.stdout" 2> "$out/command.stderr" || actual=$?
        [[ $actual == "$expected" ]] || {
            cat "$out/command.stderr" >&2
            echo "wasm-wasi: $profile $mode exited $actual, expected $expected" >&2
            exit 1
        }
        cmp "$out/$mode.expected" "$out/command.stdout"
        cmp "$out/stderr.expected" "$out/command.stderr"
    done
    rm -rf -- "$out/preopen" "$out/spare"
    mkdir -p "$out/preopen" "$out/spare"
    ln -s ../outside.txt "$out/preopen/escape.txt"
    "$runtime" run "$out/files-$profile.wasm"
    "$runtime" run --dir "$out/spare::x" --dir "$out/preopen::." \
        "$out/files-$profile.wasm" "$PWD/$out/preopen/nested/round-trip.txt" > "$out/files.stdout"
    cmp "$out/files.expected" "$out/files.stdout"
    cmp "$out/files.expected" "$out/preopen/nested/round-trip.txt"
done
echo 'wasm-wasi: startup, args, environment, stdio, clocks, randomness, exit paths and preopen-scoped files pass in release and fast builds'
